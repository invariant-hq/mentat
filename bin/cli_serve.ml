(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Server = Mentat_server
module Store = Mentat_store
module Session = Mentat_session
module Command = Mentat_protocol.Command
module Driver = Mentat_client.Driver
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Session_endpoint = Mentat_boot.Session_endpoint
module Stop_signal = Mentat_boot.Stop_signal

(* How long a settled session lingers before its server's clean exit — the
   shared [Mentat_broker.serve_linger_s], which the offline fence patience is
   derived from. MENTAT_CHILD_LINGER (test-only, seconds) shortens it so a
   blackbox stage is not paced by the default. *)
let linger_seconds environment =
  match
    Option.bind
      (List.assoc_opt "MENTAT_CHILD_LINGER" environment)
      float_of_string_opt
  with
  | Some s when s >= 0. -> s
  | Some _ | None -> Mentat_broker.serve_linger_s

(* The boot's shape, derived from the session document — no mode flags. *)
type shape =
  | Delegated of Session.Delegation.t
      (* A delegated child: the immutable edge that created it, re-read from
         the parent journal. *)
  | Root  (* A session with no lineage, served plainly. *)

(* The recorded run policy's config half, lowered onto the instance overlay
   before the engine is built — the third boot shape in effect: a
   trigger-born session's document carries the contract its creator granted
   (sandbox posture, model, reasoning, unattended permission, step cap,
   instruction toggle), and every activation of it — first or successor —
   re-derives the same overrides from the document alone. The admission half
   (mode, output schema) is the driver's to read at each queue admission.
   The lowering itself is [Run_policy_overlay] — one home, shared with the
   routine fire's pre-flight — and a member the configuration layer refuses
   (an unknown sandbox spelling, a malformed selector) refuses the boot
   loudly rather than serving the session under defaults the grant never
   named. A load failure lowers nothing: the instance stages plainly and
   [resolve_shape]'s own load produces the canonical error. *)
let recorded_overrides store served =
  match Store.Session.load store served with
  | Error _ -> Ok []
  | Ok doc -> (
      match
        Session.Metadata.run_policy
          (Session.metadata (Store.Session.Document.session doc))
      with
      | None -> Ok []
      | Some policy -> (
          match Mentat_boot.Run_policy_overlay.of_policy policy with
          | Ok None -> Ok []
          | Ok (Some overlay) -> Ok [ overlay ]
          | Error message ->
              Error
                (Printf.sprintf "session %s: recorded run policy: %s"
                   (Session.Id.to_string served)
                   message)))

(* Derive the shape this boot serves from the session document. The [--cwd]
   assertion holds for every shape: the session's recorded cwd must equal the
   resolved workspace root, so a stale or wrong [--cwd] refuses rather than
   serving against an arbitrary directory. A delegation backlink names the
   parent journal and edge id, and the edge itself is re-read from the parent
   — so only identity ever reaches this process's argv, and the task,
   description, and role stay authoritative in the store. A document with no
   lineage is a root session. *)
let resolve_shape store ~root served =
  let ( let* ) = Result.bind in
  let id = Session.Id.to_string served in
  let* doc =
    Result.map_error
      (fun e ->
        Printf.sprintf "session %s: %s" id (Store.Session.Error.message e))
      (Store.Session.load store served)
  in
  let metadata = Session.metadata (Store.Session.Document.session doc) in
  let* () =
    let recorded = Session.Metadata.cwd metadata in
    if Lpath.Abs.equal recorded root then Ok ()
    else
      Error
        (Printf.sprintf
           "session %s was recorded in %s, not %s; serve it from its workspace"
           id
           (Lpath.Abs.to_string recorded)
           (Lpath.Abs.to_string root))
  in
  match Session.Metadata.delegated_from metadata with
  | None -> Ok Root
  | Some lineage -> (
      let parent = Session.Metadata.Delegated_from.parent lineage in
      let delegation = Session.Metadata.Delegated_from.delegation lineage in
      let* parent_doc =
        Result.map_error
          (fun e ->
            Printf.sprintf "parent session %s: %s"
              (Session.Id.to_string parent)
              (Store.Session.Error.message e))
          (Store.Session.load store parent)
      in
      let edges =
        Session.State.delegations
          (Session.state (Store.Session.Document.session parent_doc))
      in
      match
        List.find_opt
          (fun edge ->
            Session.Delegation.Id.equal (Session.Delegation.id edge) delegation)
          edges
      with
      | Some edge -> Ok (Delegated edge)
      | None ->
          Error
            (Printf.sprintf "parent session %s records no delegation %s"
               (Session.Id.to_string parent)
               (Session.Delegation.Id.to_string delegation)))

(* The idle predicate over durable heads, read fence-free so observation
   never contends with this process's own driver. It builds on the shared
   finished judgment ({!Mentat_session.State.finished}) and is deliberately
   stronger: every delegation edge the session recorded must also name a
   session idle by the same measure — exiting abandons no obligation. The
   [seen] set bounds the walk: ids are parent-minted, so an uncorrupted tree
   is finite, and a corrupt journal naming an ancestor edge must not recurse
   forever. *)
let idle store cache served =
  let rec go seen session =
    let id = Session.Id.to_string session in
    if Hashtbl.mem seen id then true
    else begin
      Hashtbl.replace seen id ();
      match Session_endpoint.Heads.summary ~store cache session with
      | None -> false
      | Some (settled, children) -> settled && List.for_all (go seen) children
    end
  in
  go (Hashtbl.create 8) served

(* Stop once the session has been continuously idle — and every connection
   closed — for the linger window. A session that has never run a turn is
   never idle (no settled head yet): a delegated boot cannot exit before its
   first-turn submit lands, and a root session with no work keeps serving
   until mail or a connection drives it.

   The gone backstop: a served session whose document stays unreadable is a
   session this server can never again do useful work for — its store was
   removed out from under it (a reclaimed harness sandbox, a deleted
   ephemeral home). Without the backstop the idle predicate presumes
   outstanding work forever and the server becomes immortal; with it, a
   document continuously gone for a few seconds ends the serve. A transient
   read failure resets the clock like any other sign of life. *)
let gone_backstop_s = 5.0

let idle_watchdog clock ~linger store cache served active stop =
  let idle_since = ref None in
  let gone_since = ref None in
  let rec loop () =
    Eio.Time.sleep clock 0.25;
    (match Store.Session.stamp store served with
    | Some _ -> gone_since := None
    | None -> (
        (* [stamp] maps every failure to [None]; only proven absence feeds
           the gone clock. A transient EMFILE/EIO flap during a heavy turn
           is a sign of life, not of removal — the idle predicate's own
           "unreadable presumes outstanding work" posture. *)
        match Store.Session.load store served with
        | Error (Store.Session.Error.Not_found _) -> (
            match !gone_since with
            | None -> gone_since := Some (Eio.Time.now clock)
            | Some since ->
                if Eio.Time.now clock -. since >= gone_backstop_s then
                  Stop_signal.request stop)
        | Error _ | Ok _ -> gone_since := None));
    (if Atomic.get active > 0 || not (idle store cache served) then
       idle_since := None
     else
       match !idle_since with
       | None -> idle_since := Some (Eio.Time.now clock)
       | Some since ->
           if Eio.Time.now clock -. since >= linger then
             Stop_signal.request stop);
    if Stop_signal.requested stop then () else loop ()
  in
  loop ()

let serve_run ~session ~socket_dir_override ~spawned ~interrupted ~cwd =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  match Composition.stage_shared ~stdenv ~sw () with
  | Error status -> status
  | Ok shared -> (
      if spawned then ignore (Unix.setsid ());
      let store = shared.Composition.store in
      let served = Session.Id.of_string session in
      match recorded_overrides store served with
      | Error message -> Exit_status.runtime message
      | Ok overrides -> (
      match
        (* The labeled owner is what lets the broker tell this server's fence
           hold apart from an interactive one it must never preempt. *)
        Composition.instance shared ~sw ~cwd ~overrides ~owner:`Serve ()
      with
      | Error status -> status
      | Ok instance -> (
          match
            resolve_shape store ~root:(Composition.root instance) served
          with
          | Error message -> Exit_status.runtime message
          | Ok Root when interrupted ->
              (* The interrupt carry belongs to the delegated shape: it is
                 the broker's re-materialization of a cancelled child, and a
                 root session has no parent whose interrupt it could carry. *)
              Exit_status.runtime
                (Printf.sprintf
                   "session %s has no delegation lineage; --interrupted \
                    applies only to a delegated child"
                   session)
          | Ok shape -> (
              match Composition.driver instance with
              | Error status -> status
              | Ok driver ->
                  (* The durable-head cache behind the idle watchdog's
                     subtree walk, decoding each journal once per stamp. *)
                  let heads = Session_endpoint.Heads.create () in
                  let driver =
                    Session_endpoint.confined ~served driver
                  in
                  let socket_dir =
                    match socket_dir_override with
                    | Some dir -> dir
                    | None ->
                        let dir =
                          Mentat_boot.User_dirs.child_socket_dir
                            shared.Composition.dirs ~session
                        in
                        Session_endpoint.ensure_socket_parents dir;
                        dir
                  in
                  let net = Eio.Stdenv.net stdenv in
                  let clock = Eio.Stdenv.clock stdenv in
                  (* Every shape attaches its driver at boot, and the fence
                     is taken lazily inside that attach — never pre-acquired.
                     A delegated child attaches through its deterministic
                     first-turn submit: the turn id is derived from the
                     durable edge and the task submitted byte-identically.
                     The driver's own prompt admission is the started guard: a
                     prompt whose turn already exists with equal input settles
                     [Ok] without a new fact, so a re-spawn of a running or
                     settled child re-attaches (running its recovery) and
                     mints nothing. A root session attaches with no
                     accompanying command — fence, load, recovery to
                     quiescence — and the attach's own queue admission
                     consumes mail already durable in the journal as the
                     first turn; nothing is minted for it here. *)
                  let cone = driver.Driver.session in
                  let attach () =
                    match shape with
                    | Delegated edge -> (
                        let turn =
                          Mentat_agent.child_first_turn
                            (Session.Delegation.id edge)
                        in
                        match
                          Command.prompt ~session:served ~turn
                            ~input:(Session.Delegation.task edge) ()
                        with
                        | Error invalid ->
                            Error (Command.Invalid.message invalid)
                        | Ok command -> (
                            match cone.Driver.Session.submit command with
                            | Ok () -> Ok ()
                            | Error e ->
                                Error
                                  (Format.asprintf "%a" Mentat_protocol.Error.pp
                                     e)))
                    | Root -> (
                        match Composition.adopt_session instance served with
                        | Ok () -> Ok ()
                        | Error e ->
                            Error
                              (Format.asprintf "%a" Mentat_protocol.Error.pp e))
                  in
                  (* The first attach tolerates a custodial hold: a fence
                     held under a custodial label (a send appending mail,
                     the store removing a session) is a brief hold that
                     releases on its own, never a foreign driver, so the
                     boot retries briefly instead of refusing the session. *)
                  let custodial_hold () =
                    match Store.Run_lock.holder store ~session:served with
                    | `Held (Some owner) -> (
                        match Store.Run_lock.Owner.label owner with
                        | Some label -> Mentat_broker.custodial_label label
                        | None -> false)
                    | `Free | `Held None | `Io _ -> false
                  in
                  let rec attach_with_patience elapsed =
                    match attach () with
                    | Ok () -> Ok ()
                    | Error _ as error ->
                        if elapsed >= 5.0 || not (custodial_hold ()) then error
                        else begin
                          Eio.Time.sleep clock 0.1;
                          attach_with_patience (elapsed +. 0.1)
                        end
                  in
                  (match attach_with_patience 0. with
                  | Error message ->
                      Exit_status.runtime
                        (Printf.sprintf "session %s: %s: %s" session
                           (match shape with
                           | Delegated _ -> "first turn"
                           | Root -> "attach")
                           message)
                  | Ok () ->
                      (* A carried interrupt intent (a cancelled child killed
                         at the escalation's final rung and re-materialized):
                         interrupt right behind the idempotent first-turn
                         submit, before the recovered work gets anywhere, so
                         the journal ends in its own terminal interrupted
                         fact. On a child that already settled, or never
                         started a turn the prompt admission refused, the
                         interrupt finds no active turn and is refused —
                         exactly the no-op it should be. *)
                      (if interrupted then
                         match
                           Command.interrupt ~session:served
                             ~reason:"parent interrupted" ()
                         with
                         | Error _ -> ()
                         | Ok command ->
                             ignore (cone.Driver.Session.submit command));
                      (* The shared stop seam: a first SIGTERM/SIGINT requests
                         a graceful stop; a second — while a wedged teardown
                         holds — forces immediate exit and the OS releases
                         the fence. *)
                      let stop = Stop_signal.create () in
                      let active = Atomic.make 0 in
                      Stop_signal.with_signals stop (fun () ->
                          let linger =
                            linger_seconds shared.Composition.environment
                          in
                          (* The endpoint lives on its own switch, closed
                             before the durable close below: its LIFO
                             teardown unlinks the listener's socket, then
                             removes the directory — all while the fence is
                             still held (the engine releases it only in the
                             shutdown). A gone socket directory is the
                             visible sign of a cleanly exited server, and no
                             window exists where a freed fence coexists with
                             a live-looking socket a successor could be
                             severed through. *)
                          Eio.Switch.run (fun serve_sw ->
                              Eio.Switch.on_release serve_sw (fun () ->
                                  Session_endpoint.remove_socket socket_dir);
                              (* The listener binds only after the attach
                                 holds the fence: the bind unlinks whatever
                                 stale socket a killed predecessor left, so
                                 a boot that would lose the fence race must
                                 never reach it — a loser that bound first
                                 would sever the winner's live endpoint and
                                 then remove the directory on its way out.
                                 The fence is the exclusivity; the endpoint
                                 follows it. *)
                              let listener =
                                Server.listen ~sw:serve_sw ~net
                                  (Server.Bind.unix
                                     ~dir:(Lpath.Abs.of_string_exn socket_dir))
                              in
                              if not spawned then
                                Printf.printf
                                  "mentat serve: serving %s at %s\n%!" session
                                  (Server.Bind.socket_path
                                     ~dir:(Lpath.Abs.of_string_exn socket_dir));
                              Eio.Fiber.any
                                [
                                  (fun () ->
                                    (* A short keep-alive: an idle stream
                                       notices its peer's disconnect only at
                                       the next heartbeat write, and a
                                       settled session may not exit until
                                       its last observer's connection is
                                       seen closed — the default 15s pace
                                       would hold an idle server open that
                                       long past the broker's close. *)
                                    Server.serve ~sw:serve_sw ~clock
                                      ~heartbeat_s:1.0
                                      ~driver_for:
                                        (Session_endpoint.driver_for
                                           ~root:
                                             (Lpath.Abs.to_string
                                                (Composition.root instance))
                                           ~driver ~active)
                                      listener);
                                  (fun () -> Stop_signal.wait ~clock stop);
                                  (fun () ->
                                    idle_watchdog clock ~linger store heads
                                      served active stop);
                                ]);
                          (* Durable-first close, behind the endpoint's
                             removal; the fence releases here. *)
                          Composition.shutdown instance);
                      Exit_status.Success)))))

let serve ~session ~socket_dir_override ~spawned ~interrupted ~cwd =
  if String.length session = 0 then
    Exit_status.usage "serve requires a non-empty --session id"
  else serve_run ~session ~socket_dir_override ~spawned ~interrupted ~cwd

let session_opt =
  Arg.(
    required
    & opt (some string) None
    & info [ "session" ] ~docv:"SESSION"
        ~doc:"The session this process serves — its own.")

let socket_dir_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "socket-dir" ] ~docv:"DIR"
        ~doc:
          "Bind the session's unix socket under DIR instead of the derived \
           per-session directory. For harnesses; the broker derives the \
           default path from the session id.")

let spawned_flag =
  Arg.(
    value & flag
    & info [ "spawned" ]
        ~doc:
          "Internal: mark this server as detached-spawned, so it calls \
           $(b,setsid) at startup to survive its spawner. Set by the broker; \
           not for direct use.")

let interrupted_flag =
  Arg.(
    value & flag
    & info [ "interrupted" ]
        ~doc:
          "Internal: carry a standing interrupt intent across the spawn — the \
           boot submits an interrupt right after its idempotent first-turn \
           submit, so a cancelled child re-materialized after a kill mints \
           its terminal interrupted fact instead of resuming the cancelled \
           work. Set by the broker; not for direct use.")

let man =
  [
    `S "DESCRIPTION";
    `P
      "Internal: launched by the broker; not for direct use. $(b,mentat \
       serve) serves exactly one session — its own — over the same \
       wire the daemon speaks, on a per-session unix socket derived from the \
       session id. It takes no mode flags: the boot reads the durable \
       session document and derives its shape from the recorded lineage.";
    `P
      "A delegated child (its document records a delegation backlink) is \
       served from its durable edge: the boot re-reads the task and role \
       from the edge and submits the child's deterministic first turn \
       (idempotently — a re-spawn of a running or settled child mints \
       nothing). A session with no lineage is a root, served plainly: \
       nothing is minted for it — the boot attaches its driver, and mail \
       already durable in the journal starts the first turn.";
    `P
      "Every shape serves feed and commands while the work runs and exits \
       cleanly once the session has settled idle with an empty queue and \
       every connection closed, after a short linger for follow-up \
       deliveries.";
    `P
      "The endpoint is confined to its one purpose: the session cone answers \
       only for the served session (every other session is its own agent's) and the \
       session-scoped settings writes (model, permission review) pass under \
       the same guard — their overlays live in this driving process. The \
       accounts, lifecycle, review, and workspace cones and the sessionless \
       settings are refused whole.";
  ]

let cmd =
  let doc = "Serve one session over its per-session socket (internal)." in
  Cmd.v
    (Cmd.info "serve" ~doc ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const (fun session socket_dir_override spawned interrupted cwd ->
             serve ~session ~socket_dir_override ~spawned ~interrupted ~cwd)
         $ session_opt $ socket_dir_opt $ spawned_flag $ interrupted_flag
         $ Cli_common.cwd))
