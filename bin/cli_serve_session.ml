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

(* How long a settled child lingers before its clean exit, so a follow-up
   delivery landing just after settlement still finds a live server.
   MENTAT_CHILD_LINGER (test-only, seconds) shortens it so a blackbox stage is
   not paced by the default. *)
let default_linger_s = 3.0

let linger_seconds environment =
  match
    Option.bind
      (List.assoc_opt "MENTAT_CHILD_LINGER" environment)
      float_of_string_opt
  with
  | Some s when s >= 0. -> s
  | Some _ | None -> default_linger_s

(* Resolve the durable delegation edge behind [child]: the child document's
   lineage backlink names the parent journal and edge id, and the edge itself is
   re-read from the parent — so only identity ever reaches this process's argv,
   and the task, description, and role stay authoritative in the store. *)
let resolve_edge store ~root child =
  let ( let* ) = Result.bind in
  let id = Session.Id.to_string child in
  let* doc =
    Result.map_error
      (fun e ->
        Printf.sprintf "session %s: %s" id (Store.Session.Error.message e))
      (Store.Session.load store child)
  in
  let metadata = Session.metadata (Store.Session.Document.session doc) in
  let* () =
    (* [--cwd] is an assertion — the session's recorded cwd must equal the
       resolved workspace root, so a stale or wrong [--cwd] refuses rather than
       serving against an arbitrary directory. *)
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
  let* lineage =
    Option.to_result
      ~none:
        (Printf.sprintf
           "session %s is not a delegated child (no delegation lineage)" id)
      (Session.Metadata.delegated_from metadata)
  in
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
  | Some edge -> Ok edge
  | None ->
      Error
        (Printf.sprintf "parent session %s records no delegation %s"
           (Session.Id.to_string parent)
           (Session.Delegation.Id.to_string delegation))

(* One cached, stamp-elided, fence-free read of a session's durable head:
   whether it is settled with an empty queue, and its recorded delegation
   children. [None] when the stamp or the journal cannot be read —
   outstanding work is presumed. The stamp elision means the polls built on
   this decode a journal only when its persisted bytes have changed. *)
let head_summary store cache child =
  let id = Session.Id.to_string child in
  match Store.Session.stamp store child with
  | None -> None
  | Some stamp -> (
      match Hashtbl.find_opt cache id with
      | Some (cached, settled, children) when String.equal cached stamp ->
          Some (settled, children)
      | Some _ | None -> (
          match Store.Session.load store child with
          | Error _ -> None
          | Ok doc ->
              let state = Session.state (Store.Session.Document.session doc) in
              let settled =
                Option.is_some (Session.State.settled_head state)
                && Session.State.pending_queue state = []
              in
              let children =
                List.map Session.Delegation.child
                  (Session.State.delegations state)
              in
              Hashtbl.replace cache id (stamp, settled, children);
              Some (settled, children)))

(* The child idle predicate over durable heads, read fence-free so observation
   never contends with this process's own driver. It builds on the shared
   settled-head judgment ({!Mentat_session.State.settled_head}) and is
   deliberately stronger: the head must be settled, nothing may be queued, and
   every delegation edge the session recorded must name a session idle by the
   same measure — exiting abandons no obligation. The [seen] set bounds the
   walk: ids are parent-minted, so an uncorrupted tree is finite, and a
   corrupt journal naming an ancestor edge must not recurse forever. *)
let idle store cache child =
  let rec go seen child =
    let id = Session.Id.to_string child in
    if Hashtbl.mem seen id then true
    else begin
      Hashtbl.replace seen id ();
      match head_summary store cache child with
      | None -> false
      | Some (settled, children) -> settled && List.for_all (go seen) children
    end
  in
  go (Hashtbl.create 8) child

(* Whether [target] lies in the served child's delegation subtree: [root]
   itself, or a session reachable from it through recorded delegation edges.
   Journal truth decides — an edge not yet durable is not yet served, and the
   caller retries once it is. The [seen] set bounds the walk as [idle]'s
   does. *)
let member store cache ~root target =
  let rec go seen id =
    Session.Id.equal id target
    || (not (Hashtbl.mem seen (Session.Id.to_string id))
       && begin
            Hashtbl.replace seen (Session.Id.to_string id) ();
            match head_summary store cache id with
            | None -> false
            | Some (_, children) -> List.exists (go seen) children
          end)
  in
  go (Hashtbl.create 8) root

(* Stop once the child has been continuously idle — and every connection closed
   — for the linger window. A fresh boot on an unstarted child is never idle
   (no turn yet), so the watchdog cannot fire before the first-turn submit
   lands. *)
let idle_watchdog clock ~linger store cache child active stop =
  let idle_since = ref None in
  let rec loop () =
    Eio.Time.sleep clock 0.25;
    (if Atomic.get active > 0 || not (idle store cache child) then
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

(* The one-session confinement, making the man page's claim a code fact. The
   session cone answers only for the served child's own delegation subtree —
   the only sessions this process can speak for, and the only ones its two
   legitimate peers (the daemon's broker and its child-routing proxy) ever ask
   about; a foreign session id is refused, never resolved against the shared
   store. Every other cone — accounts, settings, lifecycle, review, workspace
   — is refused whole: this endpoint exists to drive one delegated session,
   not to reach the user's accounts, configuration, or session index. *)
let confined ~store ~cache ~child (driver : Driver.t) : Driver.t =
  let foreign session =
    Mentat_protocol.Error.unavailable
      (Printf.sprintf "this server serves session %s and its delegation \
                       subtree, not %s"
         (Session.Id.to_string child)
         (Session.Id.to_string session))
  in
  let admit session k =
    if member store cache ~root:child session then k () else Error (foreign session)
  in
  let cone_refused () =
    Error
      (Mentat_protocol.Error.unavailable
         "this server serves one delegated session; accounts, settings, \
          lifecycle, review, and workspace operations belong to the daemon")
  in
  let s = driver.Driver.session in
  let session : Driver.Session.t =
    {
      Driver.Session.submit =
        (fun command ->
          let session = Command.session command in
          admit session (fun () -> s.Driver.Session.submit command));
      follow =
        (fun session ~from ->
          admit session (fun () -> s.Driver.Session.follow session ~from));
      answer_unattended =
        (fun ~session ~decision ->
          admit session (fun () ->
              s.Driver.Session.answer_unattended ~session ~decision));
      possibly_mutating =
        (fun ~session ->
          member store cache ~root:child session
          && s.Driver.Session.possibly_mutating ~session);
      faulted =
        (fun ~session ->
          if member store cache ~root:child session then
            s.Driver.Session.faulted ~session
          else None);
      fork =
        (fun ~session ~into ->
          admit session (fun () -> s.Driver.Session.fork ~session ~into));
      rewind =
        (fun ~session ~into ~anchor ->
          admit session (fun () ->
              s.Driver.Session.rewind ~session ~into ~anchor));
      compact =
        (fun ~session ~turn ->
          admit session (fun () -> s.Driver.Session.compact ~session ~turn));
      pending_decision =
        (fun session ->
          admit session (fun () -> s.Driver.Session.pending_decision session));
      running_processes =
        (fun session ->
          admit session (fun () -> s.Driver.Session.running_processes session));
      change_diff =
        (fun ~session ~change ->
          admit session (fun () ->
              s.Driver.Session.change_diff ~session ~change));
      tail =
        (fun ?n session ->
          admit session (fun () -> s.Driver.Session.tail ?n session));
      page =
        (fun ?n session ~before ->
          admit session (fun () -> s.Driver.Session.page ?n session ~before));
      revert =
        (fun ~session ~scope ->
          admit session (fun () -> s.Driver.Session.revert ~session ~scope));
      undo =
        (fun ~session ~op ->
          admit session (fun () -> s.Driver.Session.undo ~session ~op));
      export =
        (fun ~session ->
          admit session (fun () -> s.Driver.Session.export ~session));
    }
  in
  let accounts : Driver.Accounts.t =
    {
      Driver.Accounts.login = (fun ~provider:_ ~method_:_ -> cone_refused ());
      save_api_key = (fun ~provider:_ ~key:_ -> cone_refused ());
      logout = (fun ?revoke:_ _ -> cone_refused ());
      account_readiness = (fun () -> cone_refused ());
      model_readiness = (fun ?refresh:_ () -> cone_refused ());
    }
  in
  let settings : Driver.Settings.t =
    {
      Driver.Settings.set_model =
        (fun ~session:_ ?reasoning_effort:_ _ -> cone_refused ());
      set_permission_review = (fun ~session:_ _ -> cone_refused ());
      configuration = (fun () -> cone_refused ());
      set_default_model = (fun ?reasoning_effort:_ _ -> cone_refused ());
      set_ui_theme = (fun ~theme:_ -> cone_refused ());
    }
  in
  let lifecycle : Driver.Lifecycle.t =
    {
      Driver.Lifecycle.create = (fun ~id:_ ~title:_ -> cone_refused ());
      rename = (fun ~session:_ ~title:_ -> cone_refused ());
      archive = (fun ~session:_ -> cone_refused ());
      restore = (fun ~session:_ -> cone_refused ());
      delete = (fun ~session:_ -> cone_refused ());
      sessions = (fun ~listing:_ -> cone_refused ());
      session = (fun _ -> cone_refused ());
    }
  in
  let review : Driver.Review.t =
    {
      Driver.Review.apply = (fun _ -> cone_refused ());
      state = (fun ~scope:_ -> cone_refused ());
      diff = (fun ~path:_ -> cone_refused ());
      crs = (fun () -> cone_refused ());
      compose = (fun _ -> cone_refused ());
    }
  in
  let workspace : Driver.Workspace.t =
    { Driver.Workspace.glance = (fun () -> cone_refused ()) }
  in
  { Driver.session; accounts; settings; lifecycle; review; workspace }

(* One session, one workspace: a handshake binds only this instance's root, and
   the offered environment is ignored — the instance keeps the environment it
   booted with, exactly as a live daemon instance does. *)
let driver_for ~root ~driver ~active ~workspace ~environment:_ =
  match workspace with
  | Some w when String.equal w root ->
      Atomic.incr active;
      Ok
        {
          Server.workspace = Some root;
          driver;
          on_close = (fun () -> Atomic.decr active);
        }
  | Some w ->
      Error
        (Mentat_protocol.Error.unavailable
           (Printf.sprintf "this server serves %s, not %s" root w))
  | None ->
      Error
        (Mentat_protocol.Error.unavailable
           "bind a workspace: this server serves one session's workspace")

(* The per-session socket home is two levels below [/tmp]; the server's listen
   hardens only its leaf, so the parents are created (0700) here. *)
let ensure_socket_parents dir =
  let mkdir path =
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  in
  let parent = Filename.dirname dir in
  mkdir (Filename.dirname parent);
  mkdir parent

(* Endpoint removal runs after the Eio run has completed: the listening
   socket's own teardown (at switch close) unlinks the socket path, so an
   earlier removal here would make that teardown fail on the missing entry.
   This is the backstop for a teardown that could not run. *)
let remove_socket dir =
  Server.Bind.remove_endpoint ~dir:(Lpath.Abs.of_string_exn dir)

let serve_run ~session ~socket_dir_override ~spawned ~interrupted ~cwd
    ~bound_socket_dir =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  match Composition.stage_shared ~stdenv ~sw () with
  | Error status -> status
  | Ok shared -> (
      if spawned then ignore (Unix.setsid ());
      match
        (* The labeled owner is what lets the broker tell this server's fence
           hold apart from an interactive one it must never preempt. *)
        Composition.instance shared ~sw ~cwd ~overrides:[]
          ~owner_label:Mentat_broker.serve_owner_label ()
      with
      | Error status -> status
      | Ok instance -> (
          let store = shared.Composition.store in
          let child = Session.Id.of_string session in
          match resolve_edge store ~root:(Composition.root instance) child with
          | Error message -> Exit_status.runtime message
          | Ok edge -> (
              match Composition.driver instance with
              | Error status -> status
              | Ok driver ->
                  (* One durable-head cache behind both consumers of the
                     subtree walk — the idle watchdog and the confinement's
                     membership — so each journal decodes once per stamp. *)
                  let heads = Hashtbl.create 8 in
                  let driver = confined ~store ~cache:heads ~child driver in
                  let socket_dir =
                    match socket_dir_override with
                    | Some dir -> dir
                    | None ->
                        let dir =
                          User_dirs.child_socket_dir shared.Composition.dirs
                            ~session
                        in
                        ensure_socket_parents dir;
                        dir
                  in
                  let net = Eio.Stdenv.net stdenv in
                  let clock = Eio.Stdenv.clock stdenv in
                  let listener =
                    Server.listen ~sw ~net
                      (Server.Bind.unix
                         ~dir:(Lpath.Abs.of_string_exn socket_dir))
                  in
                  bound_socket_dir := Some socket_dir;
                  if not spawned then
                    Printf.printf "mentat serve-session: serving %s at %s\n%!"
                      session
                      (Server.Bind.socket_path
                         ~dir:(Lpath.Abs.of_string_exn socket_dir));
                  (* The first-turn submit, relocated from the runtime's
                     in-process materialization: the deterministic turn id is
                     derived from the durable edge and the task submitted
                     byte-identically, and the fence is taken lazily inside
                     this submit's attach — never pre-acquired at boot. The
                     driver's own prompt admission is the started guard: a
                     prompt whose turn already exists with equal input settles
                     [Ok] without a new fact, so a re-spawn of a running or
                     settled child re-attaches (running its recovery) and
                     mints nothing. *)
                  let turn =
                    Mentat_agent.child_first_turn (Session.Delegation.id edge)
                  in
                  let cone = driver.Driver.session in
                  let submit () =
                    match
                      Command.prompt ~session:child ~turn
                        ~input:(Session.Delegation.task edge) ()
                    with
                    | Error invalid -> Error (Command.Invalid.message invalid)
                    | Ok command -> (
                        match cone.Driver.Session.submit command with
                        | Ok () -> Ok ()
                        | Error e ->
                            Error
                              (Format.asprintf "%a" Mentat_protocol.Error.pp e))
                  in
                  (* The first attach tolerates a custodial hold: a fence
                     held under the send label is a brief mail append in
                     flight, never a foreign driver, so the boot retries
                     briefly instead of refusing the session. *)
                  let send_hold () =
                    match Store.Run_lock.holder store ~session:child with
                    | `Held (Some owner) ->
                        Option.equal String.equal
                          (Store.Run_lock.Owner.label owner)
                          (Some Mentat_broker.send_owner_label)
                    | `Free | `Held None | `Io _ -> false
                  in
                  let rec submit_with_patience elapsed =
                    match submit () with
                    | Ok () -> Ok ()
                    | Error _ as error ->
                        if elapsed >= 5.0 || not (send_hold ()) then error
                        else begin
                          Eio.Time.sleep clock 0.1;
                          submit_with_patience (elapsed +. 0.1)
                        end
                  in
                  (match submit_with_patience 0. with
                  | Error message ->
                      Exit_status.runtime
                        (Printf.sprintf "session %s: first turn: %s" session
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
                           Command.interrupt ~session:child
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
                          Eio.Fiber.any
                            [
                              (fun () ->
                                (* A short keep-alive: an idle stream notices
                                   its peer's disconnect only at the next
                                   heartbeat write, and a settled child may
                                   not exit until its last observer's
                                   connection is seen closed — the default
                                   15s pace would hold an idle child open
                                   that long past the broker's close. *)
                                Server.serve ~sw ~clock ~heartbeat_s:1.0
                                  ~driver_for:
                                    (driver_for
                                       ~root:
                                         (Lpath.Abs.to_string
                                            (Composition.root instance))
                                       ~driver ~active)
                                  listener);
                              (fun () -> Stop_signal.wait ~clock stop);
                              (fun () ->
                                idle_watchdog clock ~linger store heads child
                                  active stop);
                            ];
                          (* Durable-first close; the endpoint itself is
                             removed by {!serve} once the Eio run — whose
                             switch teardown unlinks the socket — has
                             completed. *)
                          Composition.shutdown instance);
                      Exit_status.Success))))

let serve ~session ~socket_dir_override ~spawned ~interrupted ~cwd =
  if String.length session = 0 then
    Exit_status.usage "serve-session requires a non-empty --session id"
  else (
    let bound_socket_dir = ref None in
    let status =
      serve_run ~session ~socket_dir_override ~spawned ~interrupted ~cwd
        ~bound_socket_dir
    in
    (* A gone socket directory is the visible sign of a cleanly exited child. *)
    Option.iter remove_socket !bound_socket_dir;
    status)

let session_opt =
  Arg.(
    required
    & opt (some string) None
    & info [ "session" ] ~docv:"SESSION"
        ~doc:"The delegated child session this process serves — its own.")

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
       serve-session) serves exactly one delegated session — its own — over \
       the same wire the daemon speaks, on a per-session unix socket derived \
       from the session id.";
    `P
      "The child session document and its delegation edge must already be \
       durable: the boot re-reads the task and role from the edge, submits \
       the child's deterministic first turn (idempotently — a re-spawn of a \
       running or settled child mints nothing), serves feed and commands \
       while the work runs, and exits cleanly once the session has settled \
       idle with an empty queue, after a short linger for follow-up \
       deliveries.";
    `P
      "The endpoint is confined to its one purpose: the session cone answers \
       only for the served session and its own delegation subtree, and the \
       accounts, settings, lifecycle, review, and workspace cones are \
       refused whole.";
  ]

let cmd =
  let doc =
    "Serve one delegated session over its per-session socket (internal)."
  in
  Cmd.v
    (Cmd.info "serve-session" ~doc ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const (fun session socket_dir_override spawned interrupted cwd ->
             serve ~session ~socket_dir_override ~spawned ~interrupted ~cwd)
         $ session_opt $ socket_dir_opt $ spawned_flag $ interrupted_flag
         $ Cli_common.cwd))
