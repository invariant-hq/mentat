(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Server = Mentat_server
module Client = Mentat_client
module Driver = Client.Driver
module Store = Mentat_store
module Session = Mentat_session
module Command = Mentat_protocol.Command
module Error = Mentat_protocol.Error
module Discovery = Server.Discovery

(* The handshake floor recorded in the discovery file — the wire version
   [Mentat_server] negotiates. It is diagnostic/gate display; the handshake
   itself enforces the version. *)
let protocol_version = 1

(* A release carries its version; a dev build does not, and "dev" == "dev"
   would attach a fresh client to any stale daemon from an older build —
   whose wire may have moved — leaving surfaces silently empty. The
   executable's own identity (device, inode, mtime, size — a rebuild mints
   a fresh inode) makes the gate mean what it says for dev builds too. *)
let binary_version =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> (
      match Unix.stat Sys.executable_name with
      | { Unix.st_dev; st_ino; st_mtime; st_size; _ } ->
          Printf.sprintf "dev-%d:%d:%.0f:%d" st_dev st_ino st_mtime st_size
      | exception Unix.Unix_error _ -> "dev")

(* Render a boot/staging failure as a message for the wire. *)
let exit_message = function
  | Exit_status.Runtime_error m
  | Exit_status.Usage_error m
  | Exit_status.Blocked m
  | Exit_status.Internal m ->
      m
  | Exit_status.Success -> "ok"
  | Exit_status.Failed -> "the workspace instance failed to boot"
  | Exit_status.Interrupted -> "interrupted"

(* ---- Path policy ---- *)

(* Readers never recompute the socket path — they read it from [daemon.json] —
   so this is a default, not a protocol. The path itself is
   {!User_dirs.daemon_socket_dir}, which the sandbox also has to see. *)
let socket_dir_default = User_dirs.daemon_socket_dir

let resolve_socket_dir ~socket_override dirs =
  match socket_override with Some dir -> dir | None -> socket_dir_default dirs

let daemon_dir_abs dirs = Lpath.Abs.of_string_exn (User_dirs.daemon_dir dirs)

let daemon_log_path dirs =
  Filename.concat (User_dirs.daemon_dir dirs) "daemon.log"

let ensure_daemon_dir dirs =
  try Unix.mkdir (User_dirs.daemon_dir dirs) 0o700
  with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

(* ---- The instance registry ---- *)

(* One workspace instance, held alive by a fiber that keeps its switch open until
   [release] fires. [bound] counts connections handshaked to this workspace;
   [inflight] counts session-routed calls in progress; [lease] is the
   reserve-at-boot pin held under the registry mutex so a fresh instance never
   shows three zeros before its first binding lands. *)
type entry = {
  instance : Composition.t;
  driver : Driver.t;
  mutable bound : int;
  mutable inflight : int;
  mutable lease : int;
  release : unit -> unit;
  settled : unit Eio.Promise.t;
      (* Resolved by the boot fiber after its [Composition.shutdown] completes —
         the daemon teardown awaits it so the claim stays held until every
         instance settled durable-first. *)
}

type registry = {
  shared : Composition.shared;
  store : Store.t;
  parent_sw : Eio.Switch.t;
  mutex : Eio.Mutex.t;
  entries : (string, entry) Hashtbl.t;
  (* Live bound connections across all instances — the idle watchdog's zero
     measure. Distinct from per-entry [bound] so the watchdog reads one
     atomic without walking the table. *)
  active : int Atomic.t;
}

let make_registry ~shared ~parent_sw =
  {
    shared;
    store = shared.Composition.store;
    parent_sw;
    mutex = Eio.Mutex.create ();
    entries = Hashtbl.create 16;
    active = Atomic.make 0;
  }

(* Boot one instance under a fiber that holds the instance switch open until the
   returned [release] runs — the detached scope eviction closes. Runs the
   staging and driver assembly synchronously and reports the ready entry (or the
   staging failure) back to the caller. *)
let boot registry ~root ~environment =
  let ready, set_ready = Eio.Promise.create () in
  let released, do_release = Eio.Promise.create () in
  let settled, set_settled = Eio.Promise.create () in
  let release () = ignore (Eio.Promise.try_resolve do_release ()) in
  Eio.Fiber.fork ~sw:registry.parent_sw (fun () ->
      Eio.Switch.run @@ fun instance_sw ->
      match
        Composition.instance registry.shared ~sw:instance_sw ~cwd:(Some root)
          ~overrides:[] ?environment ()
      with
      | Error status -> Eio.Promise.resolve set_ready (Error status)
      | Ok instance -> (
          match Composition.driver instance with
          | Error status -> Eio.Promise.resolve set_ready (Error status)
          | Ok driver ->
              let entry =
                {
                  instance;
                  driver;
                  bound = 0;
                  inflight = 0;
                  lease = 1;
                  release;
                  settled;
                }
              in
              Eio.Promise.resolve set_ready (Ok entry);
              (* Hold the switch open until eviction, then settle durable-first
                 before the switch (watch lane, dune-RPC producer) closes. *)
              Eio.Promise.await released;
              Composition.shutdown instance;
              Eio.Promise.resolve set_settled ()));
  Eio.Promise.await ready

(* Get-or-boot under the mutex, establishing a non-zero lease before releasing
   it: a fresh entry is inserted with [lease = 1]; an existing one has its lease
   bumped. The caller converts the lease to a [bound] or an [inflight] and drops
   it.

   The mutex is held across the {b entire} boot — [Composition.instance] and
   [Composition.driver] staging included — a deliberate no-double-boot trade: two
   racing get-or-boots of the same root can never both stage an instance, at the
   cost of serializing concurrent boots of {e distinct} workspaces behind one
   mutex. Acceptable for a single-user daemon where boots are rare; a per-root
   lock would lift the cross-workspace serialization if it ever bites. *)
(* A live instance keeps the environment it booted with: [environment] binds
   only the handshake whose boot it is. Two clients attaching the same root
   from different shells share the first binder's resolution — the instance is
   one engine, one run lock, one sealed sandbox. *)
let get_or_boot registry ~root ?environment () =
  Eio.Mutex.use_rw ~protect:true registry.mutex @@ fun () ->
  match Hashtbl.find_opt registry.entries root with
  | Some entry ->
      entry.lease <- entry.lease + 1;
      Ok entry
  | None -> (
      match boot registry ~root ~environment with
      | Error status -> Error status
      | Ok entry ->
          Hashtbl.replace registry.entries root entry;
          Ok entry)

(* The three-zeros eviction sweep: an entry with no bound connection, no
   in-flight call, no held lease, and no retained hub is idle — shut it down and
   drop it. Event-driven (called after every close/finish), no timers. *)
let sweep registry =
  Eio.Mutex.use_rw ~protect:true registry.mutex @@ fun () ->
  let evictable =
    Hashtbl.fold
      (fun root entry acc ->
        if
          entry.bound = 0 && entry.inflight = 0 && entry.lease = 0
          && Composition.retained_hub_count entry.instance = 0
        then (root, entry) :: acc
        else acc)
      registry.entries []
  in
  List.iter
    (fun (root, entry) ->
      Hashtbl.remove registry.entries root;
      entry.release ())
    evictable

(* Resolve a session to its owning workspace root through the shared store's
   metadata: the routing that lets a connection bound to one workspace reach
   a session recorded in another. *)
let resolve_session_root registry session =
  match Store.Session.load registry.store session with
  | Error e ->
      (* Only an actual absence is [Session_not_found]; transient IO or corruption
         is [Unavailable] — via the one shared store-error classifier, so the
         routing seam and the offline twins agree (#7). *)
      Error (Session_meta.session_store_error_to_protocol session e)
  | Ok doc ->
      let s = Store.Session.Document.session doc in
      Ok (Lpath.Abs.to_string (Session.Metadata.cwd (Session.metadata s)))

(* Run a session-cone call against the instance owning [session], counting it as
   in-flight so the sweep cannot evict the instance under it. The lease
   get-or-boot took is converted to the in-flight count under the mutex before
   the call and released after (the lease hand-off), then the sweep runs — a follow's
   open feed keeps its hub retained, so the instance stays put past the
   in-flight decrement. *)
let route_session registry ~environment session ~on_error f =
  match resolve_session_root registry session with
  | Error e -> on_error e
  | Ok root -> (
      match get_or_boot registry ~root ?environment () with
      | Error status -> on_error (Error.unavailable (exit_message status))
      | Ok entry ->
          Eio.Mutex.use_rw ~protect:true registry.mutex (fun () ->
              entry.inflight <- entry.inflight + 1;
              entry.lease <- entry.lease - 1);
          Fun.protect
            ~finally:(fun () ->
              Eio.Mutex.use_rw ~protect:true registry.mutex (fun () ->
                  entry.inflight <- entry.inflight - 1);
              sweep registry)
            (fun () -> f entry.driver))

(* The composite driver a connection binds to: the Global cones come from
   the bound instance's driver; every session-carrying call — the session cone,
   and the lifecycle and settings entries labelled [~session] — routes per call
   to the session's owning instance, so a session in another workspace reaches
   its own engine. *)
let composite_driver registry ~environment (bound : Driver.t) : Driver.t =
  (* Session routing may boot the owning instance, and the boot follows the
     same first-binder rule a direct handshake gets: the calling connection's
     environment is the one the instance resolves against — the shell that
     asked for the effect, never the shell that spawned the daemon. *)
  let route_session registry session ~on_error f =
    route_session registry ~environment session ~on_error f
  in
  let session : Driver.Session.t =
    {
      Driver.Session.submit =
        (fun command ->
          route_session registry (Command.session command)
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.submit command));
      follow =
        (fun session ~from ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.follow session ~from));
      answer_unattended =
        (fun ~session ~decision ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.session.Driver.Session.answer_unattended ~session
                ~decision));
      possibly_mutating =
        (fun ~session ->
          route_session registry session
            ~on_error:(fun _ -> false)
            (fun d ->
              d.Driver.session.Driver.Session.possibly_mutating ~session));
      faulted =
        (fun ~session ->
          route_session registry session
            ~on_error:(fun _ -> None)
            (fun d -> d.Driver.session.Driver.Session.faulted ~session));
      fork =
        (fun ~session ~into ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.fork ~session ~into));
      rewind =
        (fun ~session ~into ~anchor ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.session.Driver.Session.rewind ~session ~into ~anchor));
      compact =
        (fun ~session ~turn ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.compact ~session ~turn));
      pending_decision =
        (fun session ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.pending_decision session));
      change_diff =
        (fun ~session ~change ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.session.Driver.Session.change_diff ~session ~change));
      tail =
        (fun ?n session ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.tail ?n session));
      page =
        (fun ?n session ~before ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.page ?n session ~before));
      running_processes =
        (fun session ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.running_processes session));
      revert =
        (fun ~session ~scope ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.revert ~session ~scope));
      undo =
        (fun ~session ~op ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.undo ~session ~op));
      export =
        (fun ~session ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.export ~session));
    }
  in
  (* The session-scoped lifecycle writes route by the session's {b owner}
     instance too (the W3 gate catch), not the bound instance: once the metadata
     commit is engine-first (4a), a rename/archive/restore/delete for a session
     driven by another workspace's engine must reach that engine, or it would
     always miss it and silently fall back to the offline twin. [create]/
     [sessions] are Global and [session] is a fence-free read, so they stay on the
     bound instance. *)
  let lifecycle : Driver.Lifecycle.t =
    {
      Driver.Lifecycle.create = bound.Driver.lifecycle.Driver.Lifecycle.create;
      rename =
        (fun ~session ~title ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.lifecycle.Driver.Lifecycle.rename ~session ~title));
      archive =
        (fun ~session ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.lifecycle.Driver.Lifecycle.archive ~session));
      restore =
        (fun ~session ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.lifecycle.Driver.Lifecycle.restore ~session));
      delete =
        (fun ~session ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.lifecycle.Driver.Lifecycle.delete ~session));
      sessions = bound.Driver.lifecycle.Driver.Lifecycle.sessions;
      session = bound.Driver.lifecycle.Driver.Lifecycle.session;
    }
  in
  (* The session-scoped settings writes route by the owner instance for the same
     reason: the overlays they install are per-instance state the owning engine
     consults at the session's next turn, so a write landing on the bound
     instance would validate against the shared store, return [Ok] — and be
     silently ignored. [configuration] and [set_default_model] are genuinely
     sessionless (the resolved snapshot and the user config layer) and stay on
     the bound instance. *)
  let settings : Driver.Settings.t =
    {
      Driver.Settings.set_model =
        (fun ~session ?reasoning_effort selector ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.settings.Driver.Settings.set_model ~session
                ?reasoning_effort selector));
      set_permission_review =
        (fun ~session review ->
          route_session registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.settings.Driver.Settings.set_permission_review ~session
                review));
      configuration = bound.Driver.settings.Driver.Settings.configuration;
      set_default_model =
        bound.Driver.settings.Driver.Settings.set_default_model;
      set_ui_theme = bound.Driver.settings.Driver.Settings.set_ui_theme;
    }
  in
  { bound with Driver.session; lifecycle; settings }

(* [driver_for] the wire calls at each handshake: bind the requested workspace's
   instance (lease → bound), hand back the composite, and decrement on close
   then sweep. An absent workspace is refused: Stage 2 binds no unbound
   connection. *)
let driver_for registry ~workspace ~environment =
  match workspace with
  | None ->
      Error
        (Error.unavailable
           "bind a workspace: this daemon serves only workspace-bound \
            connections")
  | Some root -> (
      match get_or_boot registry ~root ?environment () with
      | Error status -> Error (Error.unavailable (exit_message status))
      | Ok entry ->
          Eio.Mutex.use_rw ~protect:true registry.mutex (fun () ->
              entry.bound <- entry.bound + 1;
              entry.lease <- entry.lease - 1);
          Atomic.incr registry.active;
          let on_close () =
            Eio.Mutex.use_rw ~protect:true registry.mutex (fun () ->
                entry.bound <- entry.bound - 1);
            Atomic.decr registry.active;
            sweep registry
          in
          Ok
            {
              Server.workspace = Some root;
              driver = composite_driver registry ~environment entry.driver;
              on_close;
            })

(* ---- The browser frontend ---- *)

(* The client-minted id sources the web [Env] needs, minted through the shared
   {!Session_meta.fresh_id} so a new session and a prompt turn read the same
   shape a CLI or TUI mint. *)
let web_new_session () = Session.Id.of_string (Session_meta.fresh_id ())

let web_new_turn () =
  Session.Turn.Id.of_string (Session_meta.fresh_id ~prefix:"t" ())

(* The canonical cwd root, mirroring [Composition.resolve_root ~cwd:None] so the
   web binds the {b same} registry instance a wire connection or a session route
   for this workspace resolves to — one engine, one run-lock reservation. *)
let web_cwd_root () =
  try Unix.realpath (Sys.getcwd ()) with Unix.Unix_error _ -> Sys.getcwd ()

(* Adapt [mentat.web]'s routes and feed to the transport-light [Web.handler] the
   server's edge drives: [respond] renders a request to HTTP through
   [Routes.to_http]; [stream] follows a session's live render, translating each
   [Routes.Frame.t] to the edge's frame. A feed fault is [mentat.web]'s to own —
   the daemon logs it and lets the stream end, so the browser's [EventSource]
   re-attaches and catches up from [Last-Event-ID]; no frame is fabricated. *)
let web_handler env : Server.Web.handler =
  {
    Server.Web.respond =
      (fun ~meth ~path ~query ~body ->
        let { Mentat_web.Routes.Http.status; headers; body } =
          Mentat_web.Routes.to_http
            (Mentat_web.Routes.handle env ~meth ~path ~query ~body)
        in
        { Server.Web.status; headers; body });
    stream =
      (fun ~sw ~session ~from ~emit ->
        match
          Mentat_web.Routes.feed env ~sw ~session ~from
            ~emit:(fun { Mentat_web.Routes.Frame.id; html } ->
              emit { Server.Web.id; html })
        with
        | Ok () -> Ok ()
        | Error (Mentat_web.Routes.Attach e) ->
            (* No frame was emitted for it: surface it as the terminal SSE error
               event so the browser re-attaches. *)
            Error (Format.asprintf "%a" Error.pp e)
        | Error (Mentat_web.Routes.Render_fault _) ->
            (* A committed fact was inconsistent with the fold — a projector or
               firewall bug. Abort the stream, logged; the frames already emitted
               stand. *)
            Eio.traceln "mentat web: render fault (projector inconsistency)";
            Ok ());
  }

(* Build the browser edge over the daemon's cwd workspace, returning a serve
   branch plus the URL to open. The cwd instance is pinned {b bound} for the
   daemon's life so the eviction sweep never pulls it out from under the web
   client, and the loopback origins the edge allow-lists are derived from the
   bound port. *)
let start_web registry ~sw ~net ~clock ~web_port ~token =
  let root = web_cwd_root () in
  match get_or_boot registry ~root () with
  | Error status -> Error (exit_message status)
  | Ok entry ->
      (* Pin the cwd instance bound for the daemon's life (the boot lease → a
         permanent binding), so the eviction sweep never pulls it out from under
         the web client. The instance's engine and driver were built at boot. *)
      Eio.Mutex.use_rw ~protect:true registry.mutex (fun () ->
          entry.bound <- entry.bound + 1;
          entry.lease <- entry.lease - 1);
      (* The web Env's client is the daemon's OWN composite driver (Ruling Q1),
         wrapped in-process with the cwd instance's local command expansion: the
         Global cones (listing, create, settings) read the bound cwd instance, and
         session-scoped ops route by session→cwd→owner instance — so a session in
         another workspace renders and drives cross-workspace with no wire hop. A
         per-workspace (URL-scoped) web binding is a named future. *)
      let client =
        Composition.attach_client entry.instance
          (composite_driver registry ~environment:None entry.driver)
      in
      let env =
        Mentat_web.Routes.Env.make ~client ~now:Unix.gettimeofday
          ~new_session:web_new_session ~new_turn:web_new_turn
      in
      let listener =
        Server.listen ~sw ~net (Server.Bind.loopback ~port:web_port ~token)
      in
      let port = Option.value (Server.port listener) ~default:0 in
      let origins =
        List.map Server.Origin.of_string
          [
            Printf.sprintf "http://127.0.0.1:%d" port;
            Printf.sprintf "http://localhost:%d" port;
          ]
      in
      let url_of token =
        Printf.sprintf "http://127.0.0.1:%d/?t=%s" port
          (Server.Token.to_string token)
      in
      let branch ~on_url () =
        Server.Web.serve ~sw ~clock ~token
          ~on_rotate:(fun successor -> on_url (url_of successor))
          ~origins (web_handler env) listener
      in
      Ok (branch, url_of token)

(* ---- The serve body ---- *)

(* Poll an atomic the signal handler sets, so a first SIGTERM/SIGINT stops the
   accept loop cooperatively (the Eio-safe signal path the run surface uses). *)
let wait_for_stop clock stop_requested =
  let rec loop () =
    if Atomic.get stop_requested then ()
    else (
      Eio.Time.sleep clock 0.1;
      loop ())
  in
  loop ()

(* A7: MENTAT_DAEMON_MAX_IDLE (test-only) stops the daemon after [max_idle]
   continuous seconds with zero bound connections, so a background daemon a
   blackbox test spawns cannot outlive the test. Absent, the daemon runs until
   signalled. *)
let max_idle_seconds environment =
  Option.bind
    (List.assoc_opt "MENTAT_DAEMON_MAX_IDLE" environment)
    float_of_string_opt

let idle_watchdog clock ~max_idle registry stop_requested =
  let idle_since = ref (Eio.Time.now clock) in
  let rec loop () =
    Eio.Time.sleep clock 0.5;
    if Atomic.get registry.active > 0 then idle_since := Eio.Time.now clock
    else if Eio.Time.now clock -. !idle_since >= max_idle then
      Atomic.set stop_requested true;
    if Atomic.get stop_requested then () else loop ()
  in
  loop ()

let serve ~socket_override ~spawned ~web ~web_port =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  match Composition.stage_shared ~stdenv ~sw () with
  | Error status -> status
  | Ok shared -> (
      let dirs = shared.Composition.dirs in
      ensure_daemon_dir dirs;
      let ddir = daemon_dir_abs dirs in
      match Discovery.Claim.try_acquire ~dir:ddir with
      | Error `Held ->
          Exit_status.runtime
            "a mentat daemon is already running for this store (see \
             daemon.json)"
      | Error (`Io message) -> Exit_status.runtime message
      | Ok claim ->
          Fun.protect
            ~finally:(fun () -> Discovery.Claim.release claim)
            (fun () ->
              if spawned then ignore (Unix.setsid ());
              let socket_dir = resolve_socket_dir ~socket_override dirs in
              let socket_dir_abs = Lpath.Abs.of_string_exn socket_dir in
              let net = Eio.Stdenv.net stdenv in
              let clock = Eio.Stdenv.clock stdenv in
              let listener =
                Server.listen ~sw ~net (Server.Bind.unix ~dir:socket_dir_abs)
              in
              let registry = make_registry ~shared ~parent_sw:sw in
              (* The per-daemon bootstrap token: the wire has none for a unix bind
                 (filesystem auth), but the browser edge needs one, regenerated on
                 every start. The web branch is computed before the discovery
                 write so its URL is recorded in daemon.json, which is where every
                 client reads it from. *)
              let web_branch, web_url =
                if web then (
                  let token = Server.Token.generate () in
                  match start_web registry ~sw ~net ~clock ~web_port ~token with
                  | Ok (branch, url) ->
                      (* Only a foreground daemon has a reader. A spawned one's
                         stdout is daemon.log, which is never rotated and which a
                         user may hand over with a bug report — so printing a URL
                         carrying a live token there would persist a credential
                         for no one's benefit. *)
                      if not spawned then
                        Printf.printf "mentat web: open %s\n%!" url;
                      (Some branch, Some url)
                  | Error message ->
                      Printf.eprintf "mentat web: could not start: %s\n%!"
                        message;
                      (None, None))
                else (None, None)
              in
              let record =
                {
                  Discovery.socket = Filename.concat socket_dir "mentat.sock";
                  pid = Unix.getpid ();
                  protocol = protocol_version;
                  binary = binary_version;
                  config_home = User_dirs.config_home dirs;
                  started_at = int_of_float (Unix.gettimeofday () *. 1000.);
                  web_url;
                }
              in
              (match Discovery.write ~dir:ddir record with
              | Ok () -> ()
              | Error message ->
                  Eio.traceln "mentat serve: writing discovery failed: %s"
                    message);
              (* Consume-and-rotate: each exchange invalidates the presented
                 token and mints a successor, and republishing the successor's
                 URL keeps [web_url] a live entry point for the daemon's whole
                 life — re-entry after cookie loss is reading daemon.json (the
                 0600 trust root), while a browser history only ever holds
                 consumed tokens. *)
              let republish_web_url url =
                match
                  Discovery.write ~dir:ddir
                    { record with Discovery.web_url = Some url }
                with
                | Ok () -> ()
                | Error message ->
                    Eio.traceln "mentat serve: rewriting discovery failed: %s"
                      message
              in
              let stop_requested = Atomic.make false in
              (* D7 escalation (F3): the first SIGTERM/SIGINT requests a graceful
                 stop; a second — arriving while a graceful teardown is wedged —
                 forces immediate exit (the OS then releases every fence). Without
                 this a repeat signal would be swallowed. *)
              let request_stop _ =
                if Atomic.exchange stop_requested true then Stdlib.exit 130
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
                  let branches =
                    [
                      (fun () ->
                        Server.serve ~sw ~clock
                          ~driver_for:(driver_for registry) listener);
                      (fun () -> wait_for_stop clock stop_requested);
                    ]
                  in
                  let branches =
                    match max_idle_seconds shared.Composition.environment with
                    | Some max_idle ->
                        (fun () ->
                          idle_watchdog clock ~max_idle registry stop_requested)
                        :: branches
                    | None -> branches
                  in
                  let branches =
                    match web_branch with
                    | Some branch ->
                        branch ~on_url:republish_web_url :: branches
                    | None -> branches
                  in
                  Eio.Fiber.any branches;
                  (* D7: stop accepting, clear discovery, settle every instance
                     durable-first before the claim releases. Shutdown has one
                     implementation — the boot fiber's, behind [release] (the
                     path eviction takes) — so teardown resolves each release
                     and awaits the fiber's [settled]; calling
                     [Composition.shutdown] here directly would leave the boot
                     fiber parked on its release promise forever, wedging the
                     switch (the first-SIGINT hang a live web pin exposed). *)
                  Discovery.clear ~dir:ddir ~pid:(Unix.getpid ());
                  let settling =
                    Eio.Mutex.use_rw ~protect:true registry.mutex (fun () ->
                        Hashtbl.fold
                          (fun _ entry acc ->
                            entry.release ();
                            entry.settled :: acc)
                          registry.entries [])
                  in
                  List.iter Eio.Promise.await settling);
              Exit_status.Success))

(* ---- Client attach: find-or-spawn ---- *)

(* [daemon.log] captures the daemon's whole standard output and error, not just
   its diagnostics records, so nothing inside the logging system bounds it. Left
   alone it grows for the life of the data home. Spawn is the moment to rotate:
   the successor is about to start writing, and daemons are spawned per need and
   idle out, so restarts are frequent enough for this to bound growth in
   practice. A single daemon living for weeks still grows between spawns. *)
let daemon_log_cap = 8 * 1024 * 1024
let daemon_logs_kept = 5

let rotate_daemon_log dirs log =
  match Unix.stat log with
  | stat when stat.Unix.st_size >= daemon_log_cap ->
      let stamp = Int64.of_float (Unix.gettimeofday () *. 1_000_000.) in
      let rotated =
        Filename.concat
          (User_dirs.daemon_dir dirs)
          (Printf.sprintf "daemon-%Ld.log" stamp)
      in
      (try Unix.rename log rotated with Unix.Unix_error _ -> ());
      Log_setup.retain_logs ~keep:daemon_logs_kept
        ~dir:(User_dirs.daemon_dir dirs)
        ~current:log
  | _ | (exception Unix.Unix_error _) -> ()

let spawn dirs =
  ensure_daemon_dir dirs;
  let log = daemon_log_path dirs in
  rotate_daemon_log dirs log;
  let fd =
    Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      (* Detached fork+exec (never an Eio-managed spawn, whose switch would kill
         the daemon with the CLI); the child [setsid]s under [--spawned]. The
         current environment is inherited, so the daemon opens the same store.

         Single fork, not a double-fork: the spawning CLI stays the daemon's
         parent, so a daemon that dies while this long-lived CLI still runs stays
         a zombie until the CLI reaps it or exits. The worst case is one
         process-table entry after a daemon crash — not worth the double-fork
         re-parent-to-init machinery for a single-user Stage 2. *)
      ignore
        (Unix.create_process Sys.executable_name
           [| "mentat"; "serve"; "--spawned" |]
           Unix.stdin fd fd))

(* Whether a per-user daemon is live for these dirs (a discovery file present
   and its claim held) — the signal the offline Busy hint keys on (4e). A free
   claim under a present file is a dead daemon (a stale file), so not running. *)
let is_running dirs =
  let ddir = daemon_dir_abs dirs in
  match Discovery.read ~dir:ddir with
  | `Found _ | `Foreign _ -> (
      match Discovery.Claim.try_acquire ~dir:ddir with
      | Ok claim ->
          Discovery.Claim.release claim;
          false
      | Error `Held -> true
      | Error (`Io _) -> false)
  | `Absent -> false

let connect_to t ~socket =
  let net = Eio.Stdenv.net (Composition.stdenv t) in
  let clock = Eio.Stdenv.clock (Composition.stdenv t) in
  let sw = Composition.sw t in
  let root = Lpath.Abs.to_string (Composition.root t) in
  let dir = Lpath.Abs.of_string_exn (Filename.dirname socket) in
  match
    Server.connect ~sw ~net ~clock ~workspace:root
      ~environment:(Composition.environment t)
      (Server.Bind.unix ~dir)
  with
  | Ok driver -> Some driver
  | Error _ -> None

let find_or_spawn t =
  let dirs = Composition.dirs t in
  let ddir = daemon_dir_abs dirs in
  let clock = Eio.Stdenv.clock (Composition.stdenv t) in
  (* The real effects behind the library's convergence state machine. *)
  let read () = Discovery.read ~dir:ddir in
  let claim_free () =
    match Discovery.Claim.try_acquire ~dir:ddir with
    | Ok claim ->
        Discovery.Claim.release claim;
        true
    | Error `Held -> false
    | Error (`Io _) -> false
  in
  let probe record = connect_to t ~socket:record.Discovery.socket in
  let identity_ok record =
    String.equal record.Discovery.binary binary_version
    && String.equal record.Discovery.config_home (User_dirs.config_home dirs)
  in
  let spawn () = spawn dirs in
  let sleep () = Eio.Time.sleep clock 0.05 in
  (* MENTAT_DAEMON_SOCKET beats discovery: connect straight to the named socket
     (its [mentat.sock] path), no daemon.json read and no spawn. A named socket
     that does not answer is a definite failure, not a fallback that spawns. *)
  let socket_override () =
    match Sys.getenv_opt "MENTAT_DAEMON_SOCKET" with
    | None | Some "" -> `Unset
    | Some socket -> (
        match connect_to t ~socket with
        | Some driver -> `Reached driver
        | None -> `Set_unreachable)
  in
  match
    Discovery.locate_with_override ~socket_override ~read ~claim_free ~probe
      ~identity_ok ~spawn ~sleep ~poll_budget:100
  with
  | `Attached driver -> Ok driver
  | `Mismatch _ ->
      Error
        (Exit_status.runtime
           "the running mentat daemon was built from a different binary or \
            config home; run `mentat serve --stop` to replace it")
  | `Foreign_held ->
      Error
        (Exit_status.runtime
           "an unrecognized mentat daemon file is present and its claim is \
            held; run `mentat serve --stop`")
  | `Timeout ->
      Error
        (Exit_status.runtime
           (match Sys.getenv_opt "MENTAT_DAEMON_SOCKET" with
           | Some socket when not (String.equal socket "") ->
               Printf.sprintf
                 "the mentat daemon named by MENTAT_DAEMON_SOCKET (%s) did not \
                  answer"
                 socket
           | _ ->
               Printf.sprintf "the mentat daemon did not come up; see %s"
                 (daemon_log_path dirs)))

(* ---- Stop ---- *)

let stop () =
  match User_dirs.resolve ~getenv:Sys.getenv_opt with
  | Error message -> Exit_status.runtime message
  | Ok dirs -> (
      let ddir = daemon_dir_abs dirs in
      (* Poll the claim — the truth — for release, briefly. *)
      let released_within tenths =
        let rec loop budget =
          if budget <= 0 then false
          else
            match Discovery.Claim.try_acquire ~dir:ddir with
            | Ok claim ->
                Discovery.Claim.release claim;
                true
            | Error `Held ->
                Unix.sleepf 0.1;
                loop (budget - 1)
            | Error (`Io _) -> false
        in
        loop tenths
      in
      (* Signal the daemon holding the claim and wait for it to release. The
         discovery file may transiently name a dead predecessor while a live
         successor already holds the claim but has not yet rewritten the file (a
         reclaimed daemon claims first, then writes discovery), so each round
         re-reads the {b current} file and re-signals its pid — a stale pid can
         never leave a live successor running. Bounded (~10s across rounds); a
         claim still held after the budget is a wedged daemon. *)
      let stop_claim_holder ~first_pid =
        let signal pid =
          try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ()
        in
        let rec drive round =
          let named =
            match Discovery.read ~dir:ddir with
            | `Found current -> Some current.Discovery.pid
            | `Absent | `Foreign _ -> None
          in
          Option.iter signal named;
          if released_within 10 then Exit_status.Success
          else if round >= 9 then
            Exit_status.runtime
              (Printf.sprintf
                 "the mentat daemon (pid %d) did not stop; it may be wedged"
                 (Option.value named ~default:first_pid))
          else drive (round + 1)
        in
        signal first_pid;
        if released_within 10 then Exit_status.Success else drive 1
      in
      match Discovery.read ~dir:ddir with
      | `Absent -> Exit_status.Success
      | `Foreign _ -> (
          match Discovery.Claim.try_acquire ~dir:ddir with
          | Ok claim ->
              Discovery.Claim.release claim;
              Exit_status.Success
          | Error `Held ->
              Exit_status.runtime
                "an unrecognized mentat daemon file is present and its claim \
                 is held"
          | Error (`Io message) -> Exit_status.runtime message)
      | `Found record -> (
          match Discovery.Claim.try_acquire ~dir:ddir with
          | Ok claim ->
              (* Claim free: already dead — unlink the stale file. *)
              Discovery.Claim.release claim;
              Discovery.clear ~dir:ddir ~pid:record.Discovery.pid;
              Exit_status.Success
          | Error `Held -> stop_claim_holder ~first_pid:record.Discovery.pid
          | Error (`Io message) -> Exit_status.runtime message))
