(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The mentat daemon's client seam: path policy, discovery, and attach.

    The client-side machinery behind [--attach], in one place (multi-consumer:
    [cli_run], [cli_tui], [cli_session]). It owns the {b path policy} for the
    per-user daemon (the [daemon.json]/[daemon.lock]/[daemon.log] home under the
    data home) and the client-side {b find-or-spawn} that attaches to — or
    launches — the daemon. The foreground serve body (claim → bind → write
    discovery → an instance registry serving a session-routing composite driver
    → signalled teardown) lives with the server, which consumes the shared path
    policy exposed here ({!daemon_dir_abs}, {!ensure_daemon_dir}) and the
    identity string ({!binary_version}).

    No dependency cycle: [cli_* → daemon → composition]; [composition] never
    names [daemon]. *)

val binary_version : string
(** [binary_version] is the version string stamped into this binary. The server
    records it in [daemon.json]; {!find_or_spawn} compares it against the
    record, so a daemon built from a different binary is refused loudly rather
    than attached. *)

val daemon_dir_abs : User_dirs.t -> Lpath.Abs.t
(** [daemon_dir_abs dirs] is the per-user daemon home — where [daemon.json] and
    [daemon.lock] live — as an absolute path. *)

val ensure_daemon_dir : User_dirs.t -> unit
(** [ensure_daemon_dir dirs] creates the per-user daemon home ([0700]) if it
    does not exist; an existing one is left untouched. *)

val stop : unit -> Exit_status.t
(** [stop ()] stops the running per-user daemon: it reads [daemon.json], and —
    if the claim is held (the daemon is live) — sends the recorded pid a SIGTERM
    and waits, bounded, for the claim to release. A free claim with a stale
    [daemon.json] is unlinked. No daemon running is a clean success-shaped no-op
    (idempotent stop); a wedged daemon that never releases is a
    {!Exit_status.Runtime_error} naming the pid. Uses no store — it resolves the
    directories from the environment and speaks only the claim and the signal.
*)

val is_running : User_dirs.t -> bool
(** [is_running dirs] is whether a per-user daemon is live for [dirs]: its
    discovery file is present {b and} its claim is held. A present file whose
    claim is free is a dead daemon (a stale file), so [false]. The offline
    session verbs consult it to add the "re-run with --attach" hint to a [Busy];
    it takes and immediately releases the claim, so it is safe to call from a
    non-daemon process. *)

val find_or_spawn :
  Composition.t -> (Mentat_client.Driver.t, Exit_status.t) result
(** [find_or_spawn t] returns a driver attached to the per-user daemon for [t]'s
    workspace, spawning the daemon if none is reachable. It reads [daemon.json];
    a {b live} daemon (its socket answers a handshake) whose recorded binary or
    config home differs from [t]'s is a loud {!Exit_status.Runtime_error} naming
    [mentatd stop] (never auto-killed); a matching live daemon is attached. A
    stale file (free claim, dead socket) or an absent file spawns
    [mentatd --spawned] detached — stdio to [daemon.log], the current
    environment inherited so the daemon opens the same store — then polls
    discovery on a fixed cadence (re-read + re-connect every ~50 ms up to a
    bounded budget, then one full retry) until it answers. The returned driver
    is handed to {!Mentat_client.make}; everything downstream is
    transport-neutral.

    The daemon binary is resolved as [mentatd] next to the running executable
    (every release installs the pair side by side); the environment variable
    [MENTATD_BIN] overrides the sibling resolution for layouts where the two
    binaries do not share a directory. A resolution that finds no binary is an
    immediate {!Exit_status.Runtime_error} naming the expected path — never a
    poll that times out on a daemon that was never started. *)
