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
  (* Every daemon-hosted instance delegates through the node's one child
     broker; the ops close over the instance at boot. *)
  broker : Mentat_broker.t;
  mutex : Eio.Mutex.t;
  entries : (string, entry) Hashtbl.t;
  (* Live bound connections across all instances — the idle watchdog's zero
     measure. Distinct from per-entry [bound] so the watchdog reads one
     atomic without walking the table. *)
  active : int Atomic.t;
}

let make_registry ~shared ~parent_sw ~broker =
  {
    shared;
    store = shared.Composition.store;
    parent_sw;
    broker;
    mutex = Eio.Mutex.create ();
    entries = Hashtbl.create 16;
    active = Atomic.make 0;
  }

(* The broker's engine-reach seam for one instance: the workspace identity a
   child is spawned and dialed under, and the engine wrappers every
   observation reports through. *)
let broker_engine instance =
  {
    Mentat_broker.Engine.root = Composition.root instance;
    environment = Composition.environment instance;
    adopt_session = Composition.adopt_session instance;
    integrate_child =
      (fun ~child -> Composition.integrate_child instance ~child);
    fail_child =
      (fun ~child ~message -> Composition.fail_child instance ~child ~message);
  }

let broker_ops broker instance =
  let engine = broker_engine instance in
  {
    Mentat_agent.Ports.materialize =
      (fun ~child -> Mentat_broker.materialize broker engine ~child);
    cancel = (fun ~child -> Mentat_broker.cancel broker ~child);
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
          ~overrides:[] ?environment
          ~child_backend:(fun instance ->
            Mentat_agent.Ports.Brokered (broker_ops registry.broker instance))
          ~broker:registry.broker
            (* The transitional serve-mount: a session this instance's engine
               drives — a brokered child's parent above all — is dialable
               over its derived socket, so a child's reply crosses the wire
               instead of dying against the daemon's held fence. *)
          ~serve_mount:true ()
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

(* The session-keyed child arm — RFC 0018's registration rule made literal: a
   delegated child's endpoint is derived from its session id, so "registered"
   means "the socket answers a handshake". A session-cone call routed here
   reaches the live driver inside the child's own server — a live tail, a
   Busy that tells the truth — instead of the frozen fence-free view the
   root-keyed lookup would resolve (the child's recorded cwd is its parent's,
   so that lookup lands on the parent's instance, which drives no child).
   Only the session cone routes here: the lifecycle and settings writes keep
   their owner-instance routing (the child server refuses those cones), and a
   grandchild — delegated by a brokered child and driven in-process inside
   that child's server — answers no endpoint of its own and falls through to
   the root-keyed view. *)
let child_endpoint registry session =
  match Store.Session.load registry.store session with
  | Error _ -> None
  | Ok doc -> (
      let metadata =
        Session.metadata (Store.Session.Document.session doc)
      in
      match Session.Metadata.delegated_from metadata with
      | None -> None
      | Some _ ->
          let dir =
            User_dirs.child_socket_dir registry.shared.Composition.dirs
              ~session:(Session.Id.to_string session)
          in
          Some
            ( Lpath.Abs.of_string_exn dir,
              Lpath.Abs.to_string (Session.Metadata.cwd metadata) ))

(* One handshaked connection to a child endpoint, bounded so a wedged child
   costs the caller a short probe, not a park: an endpoint that does not
   answer within the bound is treated as absent and the caller falls back. *)
let connect_child registry ~sw (dir, root) =
  let stdenv = registry.shared.Composition.stdenv in
  match
    Eio.Time.with_timeout (Eio.Stdenv.clock stdenv) 2.0 @@ fun () ->
    Ok
      (Server.connect ~sw ~net:(Eio.Stdenv.net stdenv)
         ~clock:(Eio.Stdenv.clock stdenv) ~workspace:root
         (Server.Bind.unix ~dir))
  with
  | Ok (Ok driver) -> Some driver
  | Ok (Error _) | Error `Timeout -> None
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> None

(* A single-shot session-cone call against a live child endpoint, falling back
   to the ordinary root-keyed routing when the session is not a delegated
   child or its endpoint does not answer. The connection lives exactly as long
   as the call — a delivery-shaped exchange, never a held stream. *)
let route_child_session registry ~environment session ~on_error f =
  let fallback () = route_session registry ~environment session ~on_error f in
  match child_endpoint registry session with
  | None -> fallback ()
  | Some target -> (
      match
        Eio.Switch.run @@ fun sw ->
        match connect_child registry ~sw target with
        | None -> None
        | Some driver -> Some (f driver)
      with
      | Some result -> result
      | None -> fallback ()
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception _ ->
          on_error
            (Error.unavailable "the child session's server failed mid-call"))

(* A followed child feed must outlive its routing call: the connection is held
   open by a fiber under the registry's switch and torn down when the seam
   closes — the wire layer releases a mid-stream disconnect's seam promptly,
   so the child's connection never outlives the caller's own, and a child
   that exits mid-stream surfaces as the seam's own error, never a hang.
   [None] — no endpoint answered — sends the caller to the root-keyed view. *)
let follow_child registry target session ~from =
  let ready, set_ready = Eio.Promise.create () in
  Eio.Fiber.fork ~sw:registry.parent_sw (fun () ->
      try
        Eio.Switch.run @@ fun sw ->
        match connect_child registry ~sw target with
        | None -> ignore (Eio.Promise.try_resolve set_ready None)
        | Some driver -> (
            match
              driver.Driver.session.Driver.Session.follow session ~from
            with
            | Error _ as refused ->
                ignore (Eio.Promise.try_resolve set_ready (Some refused))
            | Ok seam ->
                let closed, set_closed = Eio.Promise.create () in
                let wrapped =
                  {
                    Client.Feed.next = seam.Client.Feed.next;
                    close =
                      (fun () ->
                        seam.Client.Feed.close ();
                        ignore (Eio.Promise.try_resolve set_closed ()));
                  }
                in
                ignore (Eio.Promise.try_resolve set_ready (Some (Ok wrapped)));
                Eio.Promise.await closed)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> ignore (Eio.Promise.try_resolve set_ready None));
  Eio.Promise.await ready

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
  (* The session cone tries the session-keyed child arm first; the follow
     entry routes through the stream-holding variant of the same arm. *)
  let route_live registry session ~on_error f =
    route_child_session registry ~environment session ~on_error f
  in
  let session : Driver.Session.t =
    {
      Driver.Session.submit =
        (fun command ->
          route_live registry (Command.session command)
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.submit command));
      follow =
        (fun session ~from ->
          let fallback () =
            route_session registry session
              ~on_error:(fun e -> Error e)
              (fun d -> d.Driver.session.Driver.Session.follow session ~from)
          in
          match child_endpoint registry session with
          | None -> fallback ()
          | Some target -> (
              match follow_child registry target session ~from with
              | Some result -> result
              | None -> fallback ()));
      answer_unattended =
        (fun ~session ~decision ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.session.Driver.Session.answer_unattended ~session
                ~decision));
      possibly_mutating =
        (fun ~session ->
          route_live registry session
            ~on_error:(fun _ -> false)
            (fun d ->
              d.Driver.session.Driver.Session.possibly_mutating ~session));
      faulted =
        (fun ~session ->
          route_live registry session
            ~on_error:(fun _ -> None)
            (fun d -> d.Driver.session.Driver.Session.faulted ~session));
      fork =
        (fun ~session ~into ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.fork ~session ~into));
      rewind =
        (fun ~session ~into ~anchor ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.session.Driver.Session.rewind ~session ~into ~anchor));
      compact =
        (fun ~session ~turn ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.compact ~session ~turn));
      pending_decision =
        (fun session ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.pending_decision session));
      change_diff =
        (fun ~session ~change ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d ->
              d.Driver.session.Driver.Session.change_diff ~session ~change));
      tail =
        (fun ?n session ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.tail ?n session));
      page =
        (fun ?n session ~before ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.page ?n session ~before));
      running_processes =
        (fun session ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.running_processes session));
      revert =
        (fun ~session ~scope ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.revert ~session ~scope));
      undo =
        (fun ~session ~op ->
          route_live registry session
            ~on_error:(fun e -> Error e)
            (fun d -> d.Driver.session.Driver.Session.undo ~session ~op));
      export =
        (fun ~session ->
          route_live registry session
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
   re-attaches and catches up from [Last-Event-ID]; no frame is fabricated.

   The charters dashboard is the daemon's own page, routed before the
   library's table: its inputs — the roster, the receipt logs, the run
   fences — live outside the one client [mentat.web] is allowed to reach. *)
let web_handler ~charters env : Server.Web.handler =
  {
    Server.Web.respond =
      (fun ~meth ~path ~query ~body ->
        let response =
          match (meth, path) with
          | ("GET" | "HEAD"), [ "charters" ] ->
              Mentat_web.Routes.Html (charters ())
          | _ -> Mentat_web.Routes.handle env ~meth ~path ~query ~body
        in
        let { Mentat_web.Routes.Http.status; headers; body } =
          Mentat_web.Routes.to_http response
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
let start_web registry ~sw ~net ~clock ~web_port ~token ~charters =
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
          ~origins
          (web_handler ~charters env)
          listener
      in
      Ok (branch, url_of token)

(* ---- The serve body ---- *)

(* A7: MENTAT_DAEMON_MAX_IDLE (test-only) stops the daemon after [max_idle]
   continuous seconds with zero bound connections, so a background daemon a
   blackbox test spawns cannot outlive the test. Absent, the daemon runs until
   signalled. *)
let max_idle_seconds environment =
  Option.bind
    (List.assoc_opt "MENTAT_DAEMON_MAX_IDLE" environment)
    float_of_string_opt

(* An enabled webhook charter is a standing commission: its node must stay
   resident to answer deliveries, and an idle-stop would be a clean exit —
   which the service manager never restarts — so every later webhook would
   bounce until the owner intervened. Ingress traffic deliberately does not
   refresh the idle clock: a quiet repository is exactly when the commission
   still stands. Consulted only at the stop threshold, so the roster fold
   costs one read per idle window; a charterless daemon keeps the
   backstop. *)
let charter_resident dirs () =
  match Charter_store.ingress_index dirs with
  | Error e ->
      (* An unreadable roster must fail safe for a stop decision: stopping
         a daemon that may hold an enabled webhook charter bounces every
         later delivery, and the manager never restarts a clean exit. *)
      Eio.traceln "mentatd: idle stop deferred, the roster is unreadable: %s"
        (Charter_store.Error.message e);
      true
  | Ok (bindings, _failures) ->
      List.exists
        (fun (b : Charter_store.Binding.t) -> b.Charter_store.Binding.enabled)
        bindings

let idle_watchdog clock ~max_idle ~resident registry stop =
  let idle_since = ref (Eio.Time.now clock) in
  let rec loop () =
    Eio.Time.sleep clock 0.5;
    if Atomic.get registry.active > 0 then idle_since := Eio.Time.now clock
    else if Eio.Time.now clock -. !idle_since >= max_idle then
      if resident () then idle_since := Eio.Time.now clock
      else Stop_signal.request stop;
    if Stop_signal.requested stop then () else loop ()
  in
  loop ()

(* The charter node is always assembled — charters register by file, so one
   installed while the daemon runs is in force at its next delivery without
   a restart, and an empty roster costs nothing (the resolver and the
   reconcile passes re-read it per event). A daemon that cannot resolve its
   [mentat] sibling serves without the node — loudly, since installed
   charters will not run — unless the webhook ingress was explicitly
   requested, which it could never honor. *)
let stage_node shared ~stop ~github_base_url ~charter_git_base ~ingress_port =
  match
    Node.create shared ~stop ?github_base_url ?git_base:charter_git_base ()
  with
  | Ok node -> Ok (Some node)
  | Error message when Option.is_some ingress_port ->
      Error (Printf.sprintf "cannot serve the webhook ingress: %s" message)
  | Error message ->
      Eio.traceln "mentatd: charters will not run: %s" message;
      Ok None

(* The tunnel-facing ingress bind: loopback only — the owner points whatever
   tunnel they already trust at it, and every delivery is authenticated
   end-to-end by its body HMAC, so the tunnel is untrusted transport by
   construction. The listener carries the pre-auth ingress family and
   nothing else: its bearer token is generated and never disclosed, and its
   handshake refuses every workspace, so a whole-port tunnel exposes
   delivery custody, never the wire. The bound port is printed for the
   owner (and the test harness) — an ingress URL's capability is its path
   id, never the port. *)
let stage_ingress_listener ~sw ~net ~ingress ~ingress_port =
  match (ingress, ingress_port) with
  | Some _, Some port ->
      let token = Server.Token.generate () in
      let bind =
        Server.Bind.loopback ~port:(if port = 0 then None else Some port) ~token
      in
      let ingress_listener = Server.listen ~sw ~net bind in
      let bound = Option.value (Server.port ingress_listener) ~default:port in
      let address = Printf.sprintf "127.0.0.1:%d" bound in
      Printf.printf "mentatd ingress: %s\n%!" address;
      Some (ingress_listener, address)
  | _ -> None

(* The racing fibers, assembled in one list (start order): the configured
   web branch and test-only idle watchdog, the ingress listener's own
   pre-auth serve loop, the node's pump and reconcile beat, then the wire
   serve loop and the stop wait, which always run. *)
let serve_branches ~sw ~clock ~registry ~stop ~dirs ~environment ~listener
    ~node ~ingress ~ingress_listener ~web_branch ~republish_web_url =
  List.concat
    [
      (match web_branch with
      | Some branch -> [ (fun () -> branch ~on_url:republish_web_url ()) ]
      | None -> []);
      (match max_idle_seconds environment with
      | Some max_idle ->
          [
            (fun () ->
              idle_watchdog clock ~max_idle ~resident:(charter_resident dirs)
                registry stop);
          ]
      | None -> []);
      (match (ingress, ingress_listener) with
      | Some ingress, Some (ingress_listener, _) ->
          [
            (fun () ->
              Server.serve ~sw ~clock ~ingress
                ~driver_for:(fun ~workspace:_ ~environment:_ ->
                  Error
                    (Mentat_protocol.Error.unavailable
                       "this listener serves the webhook ingress only"))
                ingress_listener);
          ]
      | _ -> []);
      (* The node's two fibers: the pump drives admitted deliveries to
         their dispositions — re-entering the reaped charter's reconcile
         over a fresh load of the charter by name, so a disable or edit
         during the run governs the new work the re-entry can commit,
         while the admitted event itself ran under its admission-time
         closure — and the reconcile beat keeps every charter's record
         converging. The re-entry yields to a pass holding the fold's
         one-pass gate rather than parking the pump behind it. Both fibers
         are cancellable at any instant — anything caught between receipt
         and disposition is the next boot pass's to finish. *)
      (match node with
      | Some node ->
          [
            (fun () ->
              Node.pump node
                ~after_reap:(fun loaded ->
                  let name = loaded.Charter_store.Loaded.name in
                  match Charter_store.load dirs ~name with
                  | Ok fresh ->
                      Charter_reconcile.reconcile (Node.reconcile_env node)
                        ~repo_for:(Node.repo node) fresh
                  | Error e ->
                      Eio.traceln
                        "mentatd: charter %s: skipping the after-reap \
                         re-entry: %s"
                        name
                        (Charter_store.Error.message e)));
            (fun () ->
              Charter_reconcile.loop (Node.reconcile_env node)
                ~repo_for:(Node.repo node));
          ]
      | None -> []);
      [
        (fun () ->
          Server.serve ~sw ~clock ?ingress ~driver_for:(driver_for registry)
            listener);
        (fun () -> Stop_signal.wait ~clock stop);
      ];
    ]

let serve ~socket_override ~spawned ~web ~web_port ~ingress_port
    ~github_base_url ~charter_git_base =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  match Composition.stage_shared ~stdenv ~sw () with
  | Error status -> status
  | Ok shared -> (
      let dirs = shared.Composition.dirs in
      Daemon.ensure_daemon_dir dirs;
      let ddir = Daemon.daemon_dir_abs dirs in
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
              (* Standard output may BE daemon.log — a [--spawned] start, a
                 service manager's unit — and the daemon's boot is the one
                 point every such writer passes: rotate now that the claim
                 says this process is the daemon. *)
              Daemon.rotate_owned_log dirs;
              let socket_dir = resolve_socket_dir ~socket_override dirs in
              let socket_dir_abs = Lpath.Abs.of_string_exn socket_dir in
              let net = Eio.Stdenv.net stdenv in
              let clock = Eio.Stdenv.clock stdenv in
              let listener =
                Server.listen ~sw ~net (Server.Bind.unix ~dir:socket_dir_abs)
              in
              (* [mentat] lives beside [mentatd] in every release artifact;
                 the shared sibling policy — including the loud refusal of a
                 path that would only fail inside the forked child — lives
                 with [Daemon.resolve_sibling], consulted at each spawn. *)
              let broker =
                Mentat_broker.create ~sw ~stdenv
                  ~store:shared.Composition.store
                  ~resolve_bin:(fun () ->
                    Daemon.resolve_sibling ~env:"MENTAT_BIN" ~name:"mentat"
                      ~beside:"mentatd")
                  ~socket_base:(User_dirs.daemon_socket_dir dirs)
                  ~log_dir:(User_dirs.daemon_dir dirs)
                  ~now:(fun () ->
                    (* The same clock pin every composition honors, so the
                       stamps a send's append writes stay deterministic under
                       a pinned test clock. *)
                    match
                      Option.bind
                        (List.assoc_opt "MENTAT_NOW"
                           shared.Composition.environment)
                        Int64.of_string_opt
                    with
                    | Some ms -> Mentat_session.Time.of_unix_ms ms
                    | None ->
                        Mentat_session.Time.of_unix_seconds_float
                          (Eio.Time.now clock))
              in
              let registry = make_registry ~shared ~parent_sw:sw ~broker in
              (* The stop seam is created before the branches so the resident
                 charter node can thread it into its pipeline; the signal
                 handlers are installed further down, around the serve
                 races. *)
              let stop = Stop_signal.create () in
              match
                stage_node shared ~stop ~github_base_url ~charter_git_base
                  ~ingress_port
              with
              | Error message -> Exit_status.runtime message
              | Ok node ->
                let ingress = Option.map Node.ingress node in
                let ingress_listener =
                  stage_ingress_listener ~sw ~net ~ingress ~ingress_port
                in
                (* The per-daemon bootstrap token: the wire has none for a unix bind
                   (filesystem auth), but the browser edge needs one, regenerated on
                   every start. The web branch is computed before the discovery
                   write so its URL is recorded in daemon.json, which is where every
                   client reads it from. *)
                (* The dashboard's reads happen per request inside the
                   closure — never here — so a charter installed while the
                   daemon runs renders at its next request. *)
                let charters_page () =
                  Charter_dashboard.page ~now:(Unix.gettimeofday ())
                    ~ingress:(Option.map snd ingress_listener)
                    (Charter_dashboard.observe ~dirs
                       ~store:shared.Composition.store)
                in
                let web_branch, web_url =
                  if web then (
                    let token = Server.Token.generate () in
                    match
                      start_web registry ~sw ~net ~clock ~web_port ~token
                        ~charters:charters_page
                    with
                    | Ok (branch, url) ->
                        (* Only a foreground daemon has a reader. A spawned
                           daemon's stdout is daemon.log — and so is a
                           service-managed one's, which never passes
                           [--spawned] — a file a user may hand over with a
                           bug report, so printing a URL carrying a live
                           token there would persist a credential for no
                           one's benefit. Re-entry is daemon.json (the 0600
                           trust root), which records the URL either way. *)
                        if
                          (not spawned)
                          && not (Daemon.stdout_is_daemon_log dirs)
                        then Printf.printf "mentat web: open %s\n%!" url;
                        (Some branch, Some url)
                    | Error message ->
                        Printf.eprintf "mentat web: could not start: %s\n%!"
                          message;
                        (None, None))
                  else (None, None)
                in
                let record =
                  {
                    Discovery.socket = Server.Bind.socket_path ~dir:socket_dir_abs;
                    pid = Unix.getpid ();
                    protocol = protocol_version;
                    binary = Daemon.binary_version;
                    config_home = User_dirs.config_home dirs;
                    started_at = int_of_float (Unix.gettimeofday () *. 1000.);
                    web_url;
                    ingress = Option.map snd ingress_listener;
                  }
                in
                (match Discovery.write ~dir:ddir record with
                | Ok () -> ()
                | Error message ->
                    Eio.traceln "mentatd: writing discovery failed: %s"
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
                      Eio.traceln "mentatd: rewriting discovery failed: %s"
                        message
                in
                (* D7 escalation (F3): the shared stop seam — a first
                   SIGTERM/SIGINT requests a graceful stop, a second while a
                   wedged teardown holds forces immediate exit and the OS
                   releases every fence. *)
                Stop_signal.with_signals stop (fun () ->
                    (* Re-adopt what a previous node life left running or
                       unfinished, before the first connection is served: the
                       broker enumerates orphaned children and adopts their
                       parents through the ordinary get-or-boot, whose recovery
                       re-drives each edge into the broker's own materialize. *)
                    Mentat_broker.rediscover broker
                      ~engine_for:(fun ~root ->
                        match get_or_boot registry ~root () with
                        | Error status -> Error (exit_message status)
                        | Ok entry ->
                            let release () =
                              Eio.Mutex.use_rw ~protect:true registry.mutex
                                (fun () ->
                                  match
                                    Hashtbl.find_opt registry.entries root
                                  with
                                  | Some entry ->
                                      entry.lease <- entry.lease - 1
                                  | None -> ());
                              sweep registry
                            in
                            Ok (broker_engine entry.instance, release));
                    (* The boot reconcile, settle-only: whatever record a
                       previous life left open is settled before the first
                       delivery is admitted — locally, with no network — so
                       the already-bound, already-advertised sockets answer
                       promptly on a busy first boot. The reconcile loop's
                       immediate first pass is the boot's one full fold:
                       re-drives, sweep, and GitHub listings belong to that
                       fiber, behind the serve races. *)
                    (match node with
                    | Some node ->
                        Charter_reconcile.pass_settle (Node.reconcile_env node)
                    | None -> ());
                    Eio.Fiber.any
                      (serve_branches ~sw ~clock ~registry ~stop ~dirs
                         ~environment:shared.Composition.environment ~listener
                         ~node ~ingress ~ingress_listener ~web_branch
                         ~republish_web_url);
                    (* D7: stop accepting, clear discovery, settle every instance
                       durable-first before the claim releases. Shutdown has one
                       implementation — the boot fiber's, behind [release] (the
                       path eviction takes) — so teardown resolves each release
                       and awaits the fiber's [settled]; calling
                       [Composition.shutdown] here directly would leave the boot
                       fiber parked on its release promise forever, wedging the
                       switch (the first-SIGINT hang a live web pin exposed). *)
                    Discovery.clear ~dir:ddir ~pid:(Unix.getpid ());
                    (* Stop the broker's fibers before the instances settle: the
                       children themselves keep running detached, and a
                       successor's rediscovery re-adopts them. *)
                    Mentat_broker.stop broker;
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
