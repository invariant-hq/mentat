(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Server = Mentat_server
module Store = Mentat_store
module Session = Mentat_session
module Command = Mentat_protocol.Command

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

(* The child idle predicate over durable heads, read fence-free so observation
   never contends with this process's own driver: the session has run (its
   first turn exists), nothing is active, nothing is queued, and every
   delegation edge it recorded names a session that is idle by the same
   measure — so exiting abandons no obligation. The tree is finite (ids are
   parent-minted), so the recursion terminates. *)
let rec idle store child =
  match Store.Session.load store child with
  | Error _ -> false
  | Ok doc ->
      let state = Session.state (Store.Session.Document.session doc) in
      Session.State.turns state <> []
      && Option.is_none (Session.State.active_turn state)
      && Session.State.pending_queue state = []
      && List.for_all
           (fun edge -> idle store (Session.Delegation.child edge))
           (Session.State.delegations state)

(* Stop once the child has been continuously idle — and every connection closed
   — for the linger window. A fresh boot on an unstarted child is never idle
   (no turn yet), so the watchdog cannot fire before the first-turn submit
   lands. *)
let idle_watchdog clock ~linger store child active stop_requested =
  let idle_since = ref None in
  let rec loop () =
    Eio.Time.sleep clock 0.25;
    (if Atomic.get active > 0 || not (idle store child) then idle_since := None
     else
       match !idle_since with
       | None -> idle_since := Some (Eio.Time.now clock)
       | Some since ->
           if Eio.Time.now clock -. since >= linger then
             Atomic.set stop_requested true);
    if Atomic.get stop_requested then () else loop ()
  in
  loop ()

(* Poll an atomic the signal handler sets, so a first SIGTERM/SIGINT stops the
   serve loop cooperatively (the Eio-safe signal path the daemon uses). *)
let wait_for_stop clock stop_requested =
  let rec loop () =
    if Atomic.get stop_requested then ()
    else (
      Eio.Time.sleep clock 0.1;
      loop ())
  in
  loop ()

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
   earlier unlink here would make that teardown fail on the missing entry. The
   unlink below is the backstop for a teardown that could not run. *)
let remove_socket dir =
  (try Unix.unlink (Filename.concat dir "mentat.sock")
   with Unix.Unix_error _ -> ());
  try Unix.rmdir dir with Unix.Unix_error _ -> ()

let serve_run ~session ~socket_dir_override ~spawned ~cwd ~bound_socket_dir =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  match Composition.stage_shared ~stdenv ~sw () with
  | Error status -> status
  | Ok shared -> (
      if spawned then ignore (Unix.setsid ());
      match Composition.instance shared ~sw ~cwd ~overrides:[] () with
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
                      (Filename.concat socket_dir "mentat.sock");
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
                  let submit =
                    match
                      Command.prompt ~session:child ~turn
                        ~input:(Session.Delegation.task edge) ()
                    with
                    | Error invalid -> Error (Command.Invalid.message invalid)
                    | Ok command -> (
                        let cone = driver.Mentat_client.Driver.session in
                        match
                          cone.Mentat_client.Driver.Session.submit command
                        with
                        | Ok () -> Ok ()
                        | Error e ->
                            Error
                              (Format.asprintf "%a" Mentat_protocol.Error.pp e))
                  in
                  (match submit with
                  | Error message ->
                      Exit_status.runtime
                        (Printf.sprintf "session %s: first turn: %s" session
                           message)
                  | Ok () ->
                      let stop_requested = Atomic.make false in
                      let active = Atomic.make 0 in
                      (* First SIGTERM/SIGINT requests a graceful stop; a
                         second — while a wedged teardown holds — forces
                         immediate exit and the OS releases the fence. *)
                      let request_stop _ =
                        if Atomic.exchange stop_requested true then
                          Stdlib.exit 130
                      in
                      let previous_term =
                        Sys.signal Sys.sigterm (Sys.Signal_handle request_stop)
                      in
                      let previous_int =
                        Sys.signal Sys.sigint (Sys.Signal_handle request_stop)
                      in
                      Fun.protect
                        ~finally:(fun () ->
                          Sys.set_signal Sys.sigterm previous_term;
                          Sys.set_signal Sys.sigint previous_int)
                        (fun () ->
                          let linger =
                            linger_seconds shared.Composition.environment
                          in
                          Eio.Fiber.any
                            [
                              (fun () ->
                                Server.serve ~sw ~clock
                                  ~driver_for:
                                    (driver_for
                                       ~root:
                                         (Lpath.Abs.to_string
                                            (Composition.root instance))
                                       ~driver ~active)
                                  listener);
                              (fun () -> wait_for_stop clock stop_requested);
                              (fun () ->
                                idle_watchdog clock ~linger store child active
                                  stop_requested);
                            ];
                          (* Durable-first close; the endpoint itself is
                             removed by {!serve} once the Eio run — whose
                             switch teardown unlinks the socket — has
                             completed. *)
                          Composition.shutdown instance);
                      Exit_status.Success))))

let serve ~session ~socket_dir_override ~spawned ~cwd =
  if String.length session = 0 then
    Exit_status.usage "serve-session requires a non-empty --session id"
  else (
    let bound_socket_dir = ref None in
    let status =
      serve_run ~session ~socket_dir_override ~spawned ~cwd ~bound_socket_dir
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
  ]

let cmd =
  let doc =
    "Serve one delegated session over its per-session socket (internal)."
  in
  Cmd.v
    (Cmd.info "serve-session" ~doc ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const (fun session socket_dir_override spawned cwd ->
             serve ~session ~socket_dir_override ~spawned ~cwd)
         $ session_opt $ socket_dir_opt $ spawned_flag $ Cli_common.cwd))
