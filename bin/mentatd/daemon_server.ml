(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Server = Mentat_server
module Session = Mentat_session
module Discovery = Server.Discovery

(* The handshake floor recorded in the discovery file — the wire version
   [Mentat_server] negotiates on the ingress listener. It is diagnostic/gate
   display; the handshake itself enforces the version. *)
let protocol_version = 1

(* Render a staging failure as a message for the boot narration. *)
let exit_message = function
  | Exit_status.Runtime_error m
  | Exit_status.Usage_error m
  | Exit_status.Blocked m
  | Exit_status.Internal m ->
      m
  | Exit_status.Success -> "ok"
  | Exit_status.Failed -> "the workspace instance failed to stage"
  | Exit_status.Interrupted -> "interrupted"

(* ---- The browser frontend ---- *)

(* The client-minted id sources the web [Env] needs, minted through the shared
   {!Session_meta.fresh_id} so a new session and a prompt turn read the same
   shape a CLI or TUI mint. *)
let web_new_session () = Session.Id.of_string (Session_meta.fresh_id ())

let web_new_turn () =
  Session.Turn.Id.of_string (Session_meta.fresh_id ~prefix:"t" ())

(* Adapt [mentat.web]'s routes and feed to the transport-light [Web.handler] the
   server's edge drives: [respond] renders a request to HTTP through
   [Routes.to_http]; [stream] follows a session's live render, translating each
   [Routes.Frame.t] to the edge's frame. A feed fault is [mentat.web]'s to own —
   the daemon logs it and lets the stream end, so the browser's [EventSource]
   re-attaches and catches up from [Last-Event-ID]; no frame is fabricated.

   [active] brackets each held stream: an open feed is the daemon's only held
   connection, so it is what the idle watchdog counts — and, dialed onward to
   the session's agent by the client behind [env], it is also that agent's
   lease.

   The routines dashboard is the daemon's own page, routed before the
   library's table: its inputs — the roster, the receipt logs, the run
   fences — live outside the one client [mentat.web] is allowed to reach. *)
let web_handler ~routines ~active env : Server.Web.handler =
  {
    Server.Web.respond =
      (fun ~meth ~path ~query ~body ->
        let response =
          match (meth, path) with
          | ("GET" | "HEAD"), [ "routines" ] ->
              Mentat_web.Routes.Html (routines ())
          | _ -> Mentat_web.Routes.handle env ~meth ~path ~query ~body
        in
        let { Mentat_web.Routes.Http.status; headers; body } =
          Mentat_web.Routes.to_http response
        in
        { Server.Web.status; headers; body });
    stream =
      (fun ~sw ~session ~from ~emit ->
        Atomic.incr active;
        Fun.protect
          ~finally:(fun () -> Atomic.decr active)
          (fun () ->
            match
              Mentat_web.Routes.feed env ~sw ~session ~from
                ~emit:(fun { Mentat_web.Routes.Frame.id; html } ->
                  emit { Server.Web.id; html })
            with
            | Ok () -> Ok ()
            | Error (Mentat_web.Routes.Attach e) ->
                (* No frame was emitted for it: surface it as the terminal SSE
                   error event so the browser re-attaches. *)
                Error (Format.asprintf "%a" Mentat_protocol.Error.pp e)
            | Error (Mentat_web.Routes.Render_fault _) ->
                (* A committed fact was inconsistent with the fold — a projector
                   or firewall bug. Abort the stream, logged; the frames already
                   emitted stand. *)
                Eio.traceln "mentat web: render fault (projector inconsistency)";
                Ok ()));
  }

(* Build the browser edge over the daemon's cwd workspace, returning a serve
   branch plus the URL to open. The daemon is the owner's frontend here: its
   client is the same spawn-and-dial client every frontend holds
   ({!Agent_client}) — the engine-free cones answered in this process over the
   one shared store, and every session-scoped call routed over the wire to the
   target session's own agent, attach-or-start through the daemon's broker. The
   daemon assembles no engine: a browser action against a dormant session
   starts the session's agent and dials its derived socket, and the SSE feed
   rides the held connection. A session recorded in another workspace lists
   and renders from the store but refuses the dial — its agent's handshake
   echoes the session's own root, not this daemon's — exactly as [mentat run]
   refuses a cross-workspace resume; a per-workspace (URL-scoped) web binding
   is a named future. *)
let start_web shared ~sw ~net ~broker ~active ~web_port ~token ~routines =
  match Composition.instance shared ~sw ~cwd:None ~overrides:[] ~broker () with
  | Error status -> Error (exit_message status)
  | Ok instance -> (
      match Agent_client.client instance with
      | Error status -> Error (exit_message status)
      | Ok client ->
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
          let branch ~sw ~clock ~on_url () =
            Server.Web.serve ~sw ~clock ~token
              ~on_rotate:(fun successor -> on_url (url_of successor))
              ~origins
              (web_handler ~routines ~active env)
              listener
          in
          Ok (branch, url_of token))

(* ---- The serve body ---- *)

(* A7: MENTAT_DAEMON_MAX_IDLE (test-only) stops the daemon after [max_idle]
   continuous seconds with zero held connections, so a background daemon a
   blackbox test spawns cannot outlive the test. Absent, the daemon runs until
   signalled. *)
let max_idle_seconds environment =
  Option.bind
    (List.assoc_opt "MENTAT_DAEMON_MAX_IDLE" environment)
    float_of_string_opt

(* An enabled webhook routine is a standing commission: its node must stay
   resident to answer deliveries, and an idle-stop would be a clean exit —
   which the service manager never restarts — so every later webhook would
   bounce until the owner intervened. Ingress traffic deliberately does not
   refresh the idle clock: a quiet repository is exactly when the commission
   still stands. Consulted only at the stop threshold, so the roster fold
   costs one read per idle window; a daemon with no routines keeps
   the backstop. *)
let routine_resident dirs () =
  match Routine_store.ingress_index dirs with
  | Error e ->
      (* An unreadable roster must fail safe for a stop decision: stopping
         a daemon that may hold an enabled webhook routine bounces every
         later delivery, and the manager never restarts a clean exit. *)
      Eio.traceln "mentatd: idle stop deferred, the roster is unreadable: %s"
        (Routine_store.Error.message e);
      true
  | Ok (bindings, _failures) ->
      List.exists
        (fun (b : Routine_store.Binding.t) -> b.Routine_store.Binding.enabled)
        bindings

(* [active] counts the daemon's held connections — the web frontend's open
   feed streams; the sessions' agents account for their own. *)
let idle_watchdog clock ~max_idle ~resident ~active stop =
  let idle_since = ref (Eio.Time.now clock) in
  let rec loop () =
    Eio.Time.sleep clock 0.5;
    if Atomic.get active > 0 then idle_since := Eio.Time.now clock
    else if Eio.Time.now clock -. !idle_since >= max_idle then
      if resident () then idle_since := Eio.Time.now clock
      else Stop_signal.request stop;
    if Stop_signal.requested stop then () else loop ()
  in
  loop ()

(* The routine node is always assembled — routines register by file, so one
   installed while the daemon runs is in force at its next delivery without
   a restart, and an empty roster costs nothing (the resolver and the
   reconcile passes re-read it per event). A daemon that cannot resolve its
   [mentat] sibling serves without the node — loudly, since installed
   routines will not run — unless the webhook ingress was explicitly
   requested, which it could never honor. *)
let stage_node shared ~broker ~stop ~github_base_url ~routine_git_base
    ~ingress_port =
  match
    Node.create shared ~broker ~stop ?github_base_url
      ?git_base:routine_git_base ()
  with
  | Ok node -> Ok (Some node)
  | Error message when Option.is_some ingress_port ->
      Error (Printf.sprintf "cannot serve the webhook ingress: %s" message)
  | Error message ->
      Eio.traceln "mentatd: routines will not run: %s" message;
      Ok None

(* The tunnel-facing ingress bind: loopback only — the owner points whatever
   tunnel they already trust at it, and every delivery is authenticated
   end-to-end by its body HMAC, so the tunnel is untrusted transport by
   construction. The listener carries the pre-auth ingress family and
   nothing else: its bearer token is generated and never disclosed, and its
   handshake refuses every workspace, so a whole-port tunnel exposes
   delivery custody, never a driver. The bound port is printed for the
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
   pre-auth serve loop, the node's pump and reconcile beat, and the stop
   wait, which always runs. *)
let serve_branches ~sw ~clock ~stop ~dirs ~environment ~active ~node ~ingress
    ~ingress_listener ~web_branch ~republish_web_url =
  List.concat
    [
      (match web_branch with
      | Some branch ->
          [ (fun () -> branch ~sw ~clock ~on_url:republish_web_url ()) ]
      | None -> []);
      (match max_idle_seconds environment with
      | Some max_idle ->
          [
            (fun () ->
              idle_watchdog clock ~max_idle ~resident:(routine_resident dirs)
                ~active stop);
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
         their dispositions — re-entering the reaped routine's reconcile
         over a fresh load of the routine by name, so a disable or edit
         during the run governs the new work the re-entry can commit,
         while the admitted event itself ran under its admission-time
         closure — and the reconcile beat keeps every routine's record
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
                  let name = loaded.Routine_store.Loaded.name in
                  match Routine_store.load dirs ~name with
                  | Ok fresh ->
                      Routine_reconcile.reconcile (Node.reconcile_env node)
                        ~repo_for:(Node.repo node) fresh
                  | Error e ->
                      Eio.traceln
                        "mentatd: routine %s: skipping the after-reap \
                         re-entry: %s"
                        name
                        (Routine_store.Error.message e)));
            (fun () ->
              Routine_reconcile.loop (Node.reconcile_env node)
                ~repo_for:(Node.repo node));
          ]
      | None -> []);
      [ (fun () -> Stop_signal.wait ~clock stop) ];
    ]

let serve ~web ~web_port ~ingress_port ~github_base_url ~routine_git_base =
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
              (* Standard output may BE daemon.log — a service manager's
                 unit — and the daemon's boot is the one point every such
                 writer passes: rotate now that the claim says this process
                 is the daemon. *)
              Daemon.rotate_owned_log dirs;
              let net = Eio.Stdenv.net stdenv in
              let clock = Eio.Stdenv.clock stdenv in
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
              (* The daemon's held-connection count — the web frontend's open
                 feed streams — read by the idle watchdog. *)
              let active = Atomic.make 0 in
              (* The stop seam is created before the branches so the resident
                 routine node can thread it into its pipeline; the signal
                 handlers are installed further down, around the serve
                 races. *)
              let stop = Stop_signal.create () in
              match
                stage_node shared ~broker ~stop ~github_base_url
                  ~routine_git_base ~ingress_port
              with
              | Error message -> Exit_status.runtime message
              | Ok node ->
                let ingress = Option.map Node.ingress node in
                let ingress_listener =
                  stage_ingress_listener ~sw ~net ~ingress ~ingress_port
                in
                (* The per-daemon bootstrap token: the browser edge's
                   entry credential, regenerated on every start. The web
                   branch is computed before the discovery write so its URL
                   is recorded in daemon.json, which is where every re-entry
                   reads it from. *)
                (* The dashboard's reads happen per request inside the
                   closure — never here — so a routine installed while the
                   daemon runs renders at its next request. *)
                let routines_page () =
                  Routine_dashboard.page ~now:(Unix.gettimeofday ())
                    ~ingress:(Option.map snd ingress_listener)
                    (Routine_dashboard.observe ~dirs
                       ~store:shared.Composition.store)
                in
                let web_branch, web_url =
                  if web then (
                    let token = Server.Token.generate () in
                    match
                      start_web shared ~sw ~net ~broker ~active ~web_port
                        ~token ~routines:routines_page
                    with
                    | Ok (branch, url) ->
                        (* Only a foreground daemon has a reader. A
                           service-managed daemon's stdout is daemon.log — a
                           file a user may hand over with a bug report, so
                           printing a URL carrying a live token there would
                           persist a credential for no one's benefit.
                           Re-entry is daemon.json (the 0600 trust root),
                           which records the URL either way. *)
                        if not (Daemon.stdout_is_daemon_log dirs) then
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
                    Discovery.pid = Unix.getpid ();
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
                    (* The boot residue sweep: clear the endpoint leaves of
                       removed sessions before serving. Nothing running needs
                       this daemon — every live agent holds its own fence and
                       endpoint, a parent agent's recovery re-drives its
                       unfinished delegations, and the reconcile pass below
                       settles orphaned routine runs. *)
                    Mentat_broker.sweep_endpoints broker;
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
                        Routine_reconcile.pass_settle (Node.reconcile_env node)
                    | None -> ());
                    Eio.Fiber.any
                      (serve_branches ~sw ~clock ~stop ~dirs
                         ~environment:shared.Composition.environment ~active
                         ~node ~ingress ~ingress_listener ~web_branch
                         ~republish_web_url);
                    (* Teardown: stop accepting, clear discovery, stop the
                       broker's fibers. The daemon holds no engine, so there
                       is nothing to settle: the sessions' agents keep
                       running detached and account for themselves. *)
                    Discovery.clear ~dir:ddir ~pid:(Unix.getpid ());
                    Mentat_broker.stop broker);
                Exit_status.Success))
