(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The mentat daemon's serve body.

    The foreground machinery behind [mentatd], consumed by its [main]. The
    daemon hosts the standing surfaces — the browser frontend and the webhook
    ingress — around sessions that are driven by their own agents; it stages
    {!Mentat_boot.Composition.stage_shared} once, holds no engine and serves
    no wire driver, and spawns and dials agents exactly as any frontend does
    ({!Mentat_boot.Agent_client}). *)

val serve :
  web:bool ->
  web_port:int option ->
  ingress_port:int option ->
  github_base_url:string option ->
  routine_git_base:string option ->
  Mentat_boot.Exit_status.t
(** [serve ~web ~web_port ~ingress_port ~github_base_url ~routine_git_base]
    runs the foreground daemon and blocks until a signal stops it. It stages
    the shared per-user state, takes the [daemon.lock] claim (returning a
    {!Mentat_boot.Exit_status.Runtime_error} "already running" when it is held
    — the serialisation that collapses racing starts to one), writes
    [daemon.json] atomically, sweeps the endpoint residue of removed sessions
    ({!Mentat_broker.sweep_endpoints}), and serves.

    The daemon is also the resident routine node ({!Node}): assembled at every
    boot — routines register by file, so one installed while the daemon runs is
    in force at its next event — with its pump and the reconcile beat
    ({!Routine_reconcile.loop}) racing beside the listeners, and the
    settle-only boot pass ({!Routine_reconcile.pass_settle}) run before the
    first delivery is admitted, so an interrupted routine run a previous life
    left behind is settled honestly; the beat's immediate first pass is the
    boot's one full fold. A daemon that cannot resolve its [mentat] sibling
    serves without the node, narrating that routines will not run — unless
    [ingress_port] was given, which it could never honor: a loud refusal to
    start. [github_base_url] and [routine_git_base] are the node's validated
    configuration seams (the [--github-base-url] and [--routine-git-base]
    flags), threaded to {!Node.create}; the ambient [MENTAT_GITHUB_BASE_URL]
    is deliberately never read.

    [ingress_port] binds a loopback listener carrying only the pre-auth
    webhook ingress family ([0] takes an ephemeral port; the bound address is
    printed to stdout) — the bind a webhook tunnel points at. Its bearer
    token is generated and never disclosed and its handshake refuses every
    workspace, so the listener exposes signature-verified delivery custody
    and nothing else.

    [web] additionally binds a loopback listener serving the [mentat.web]
    browser frontend behind [Mentat_server.Web]'s shared edge (the cookie
    exchange, the [Origin]/[Host] checks, the strict CSP), over the daemon's
    own working-directory workspace. The daemon is the owner's frontend here:
    a browser action against a dormant session starts the session's agent
    through the daemon's broker and dials its derived socket, and the SSE
    feed rides the held connection. [web_port] pins the loopback port ([None]
    takes an ephemeral one); the URL to open — carrying the bootstrap token —
    is printed to stdout. A web frontend whose client cannot assemble is a
    loud warning that skips the browser listener, leaving the daemon serving.
    The same mount serves the routines dashboard ({!Routine_dashboard}) at
    [/routines], read fresh per request from the roster, the receipt logs,
    and the run fences.

    A first SIGTERM/SIGINT stops accepting, clears the discovery file, stops
    the broker's fibers, and exits 0 — the sessions' agents keep running
    detached and account for themselves.

    The test-only environment variable [MENTAT_DAEMON_MAX_IDLE] (seconds)
    stops the daemon after that many continuous seconds with zero held
    connections (the web frontend's open feed streams), so a background
    daemon a blackbox test spawns cannot outlive the test — unless at least
    one enabled webhook routine is installed: the routine is a standing
    commission, an idle-stop is a clean exit the service manager never
    restarts, and a stopped node would bounce every later delivery, so such
    a daemon never stops itself as idle. *)
