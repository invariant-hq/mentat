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
  Exit_status.t
(** [serve ~socket_override ~spawned ~web ~web_port] runs the foreground daemon
    and blocks until a signal stops it. It stages the shared per-user state,
    takes the [daemon.lock] claim (returning a {!Exit_status.Runtime_error}
    "already running" when it is held — the serialisation that collapses racing
    starts to one), binds the unix socket (default [/tmp/mentat-<uid>-<key>],
    overridden by [socket_override] = the [--socket] flag), writes [daemon.json]
    atomically, and serves. The registry get-or-boots a workspace instance per
    connection and hands the wire a composite driver whose session-cone calls
    route by session id to the owning instance, evicting idle instances by the
    three-zeros rule.

    [web] additionally binds a loopback listener serving the [mentat.web]
    browser frontend behind [Mentat_server.Web]'s shared edge (the cookie
    exchange, the [Origin]/[Host] checks, the strict CSP), over the daemon's own
    working-directory workspace. [web_port] pins the loopback port ([None] takes
    an ephemeral one); the URL to open — carrying the bootstrap token — is
    printed to stdout. A web frontend whose client cannot assemble is a loud
    warning that skips the browser listener, leaving the wire serving.

    [spawned] is the hidden [--spawned] flag: when set the daemon calls [setsid]
    at startup so it outlives the terminal. A first SIGTERM/SIGINT stops
    accepting, clears the discovery file, shuts every instance down
    durable-first, and exits 0.

    The test-only environment variable [MENTAT_DAEMON_MAX_IDLE] (seconds) stops
    the daemon after that many continuous seconds with zero bound connections,
    so a background daemon a blackbox test spawns cannot outlive the test. *)
