(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The mentat daemon's serve body: registry, instancing, and the wire.

    The foreground machinery behind [mentatd], consumed by its [main]. It
    sequences {!Composition.stage_shared} once, then one
    {!Composition.instance} per workspace over it (the per-user vs
    per-workspace split); [mentat.server] provides the wire, [composition] the
    instances, and this module the registry and process lifecycle. The client
    side — path policy, discovery, and find-or-spawn — is {!Daemon}'s. *)

val serve :
  socket_override:string option ->
  spawned:bool ->
  web:bool ->
  web_port:int option ->
  ingress_port:int option ->
  github_base_url:string option ->
  routine_git_base:string option ->
  Exit_status.t
(** [serve ~socket_override ~spawned ~web ~web_port ~ingress_port
    ~github_base_url ~routine_git_base] runs the foreground daemon
    and blocks until a signal stops it. It stages the shared per-user state,
    takes the [daemon.lock] claim (returning a {!Exit_status.Runtime_error}
    "already running" when it is held — the serialisation that collapses racing
    starts to one), binds the unix socket (default [/tmp/mentat-<uid>-<key>],
    overridden by [socket_override] = the [--socket] flag), writes [daemon.json]
    atomically, and serves. The registry get-or-boots a workspace instance per
    connection and hands the wire a composite driver whose session-cone calls
    route by session id: a delegated child whose derived endpoint answers a
    handshake is proxied to the live driver in its own server — the
    session-keyed child arm; a followed child feed is a live tail whose
    connection lives only as long as the caller's own — and every other
    session reaches its owning instance, with idle instances evicted by the
    three-zeros rule.

    The daemon is also the resident routine node ({!Node}): assembled at every
    boot — routines register by file, so one installed while the daemon runs is
    in force at its next event — with its ingress mounted on the wire listener,
    its pump and the reconcile beat ({!Routine_reconcile.loop}) racing beside
    the serve loop, and the settle-only boot pass
    ({!Routine_reconcile.pass_settle}) run before the first delivery is
    admitted, beside the child broker's rediscovery — settle-only, so a busy
    first boot never leaves the bound sockets unanswered behind GitHub
    listings; the beat's immediate first pass is the boot's one full fold. A
    daemon that cannot resolve its [mentat] sibling serves without the node,
    narrating that routines will not run — unless [ingress_port] was given,
    which it could never honor: a loud refusal to start. [github_base_url]
    and [routine_git_base] are the node's validated configuration seams (the
    [--github-base-url] and [--routine-git-base] flags), threaded to
    {!Node.create}; the ambient [MENTAT_GITHUB_BASE_URL] is deliberately
    never read.

    [ingress_port] additionally binds a loopback listener carrying only the
    pre-auth webhook ingress family ([0] takes an ephemeral port; the bound
    address is printed to stdout) — the bind a webhook tunnel points at. Its
    bearer token is generated and never disclosed and its handshake refuses
    every workspace, so the listener exposes signature-verified delivery
    custody and nothing else.

    [web] additionally binds a loopback listener serving the [mentat.web]
    browser frontend behind [Mentat_server.Web]'s shared edge (the cookie
    exchange, the [Origin]/[Host] checks, the strict CSP), over the daemon's own
    working-directory workspace. [web_port] pins the loopback port ([None] takes
    an ephemeral one); the URL to open — carrying the bootstrap token — is
    printed to stdout. A web frontend whose client cannot assemble is a loud
    warning that skips the browser listener, leaving the wire serving. The
    same mount serves the routines dashboard ({!Routine_dashboard}) at
    [/routines], read fresh per request from the roster, the receipt logs,
    and the run fences.

    [spawned] is the hidden [--spawned] flag: when set the daemon calls [setsid]
    at startup so it outlives the terminal. A first SIGTERM/SIGINT stops
    accepting, clears the discovery file, shuts every instance down
    durable-first, and exits 0.

    The test-only environment variable [MENTAT_DAEMON_MAX_IDLE] (seconds) stops
    the daemon after that many continuous seconds with zero bound connections,
    so a background daemon a blackbox test spawns cannot outlive the test —
    unless at least one enabled webhook routine is installed: the routine is a
    standing commission, an idle-stop is a clean exit the service manager never
    restarts, and a stopped node would bounce every later delivery, so such a
    daemon never stops itself as idle. *)
