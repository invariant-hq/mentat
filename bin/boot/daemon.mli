(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The mentat daemon's home policy and lifecycle verbs.

    Consumed by [mentatd] alone: the path policy for the per-user daemon home
    (the [daemon.json]/[daemon.lock]/[daemon.log] directory under the data
    home), the daemon-log rotation its boot runs, the sibling-binary
    resolution the two executables share, and the [mentatd stop] verb.
    [mentat] itself never names the daemon: a frontend reaches a session by
    starting and dialing the session's own agent, not by attaching to a
    daemon.

    No dependency cycle: [mentatd → daemon → composition]; [composition]
    never names [daemon]. *)

val binary_version : string
(** [binary_version] is the version string stamped into this binary. The
    server records it in [daemon.json] as the discovery record's identity. *)

val daemon_dir_abs : User_dirs.t -> Lpath.Abs.t
(** [daemon_dir_abs dirs] is the per-user daemon home — where [daemon.json] and
    [daemon.lock] live — as an absolute path. *)

val ensure_daemon_dir : User_dirs.t -> unit
(** [ensure_daemon_dir dirs] creates the per-user daemon home ([0700]) if it
    does not exist; an existing one is left untouched. *)

val stdout_is_daemon_log : User_dirs.t -> bool
(** [stdout_is_daemon_log dirs] is whether this process's standard output
    {e is} the daemon log file — inode identity with [daemon.log], the
    shape of a [--spawned] start and of a service-manager start alike. A
    foreground daemon on a terminal, and any process whose output was
    redirected elsewhere, answers [false]. What lands on standard output
    persists in the log for the life of the data home and may ride a bug
    report, so anything credential-bearing consults this before
    printing. *)

val rotate_owned_log : User_dirs.t -> unit
(** [rotate_owned_log dirs] rotates [daemon.log] when this process's own
    standard output {e is} that file — the [--spawned] path and a
    service-manager start both open it over fds 1 and 2, and the daemon's
    boot is the one point every such writer passes, so the cap holds for a
    manager-kept daemon too. Rotation renames an over-cap log aside,
    retains a bounded set of predecessors, and lays a fresh append-only
    open over standard output and error; a foreground daemon on a terminal
    matches nothing and is untouched. Failures are swallowed: rotation is
    hygiene, never worth refusing a boot over. *)

val resolve_sibling :
  env:string -> name:string -> beside:string -> (string, string) result
(** [resolve_sibling ~env ~name ~beside] is the sibling-binary policy shared
    by the pair of executables that ship side by side: the program [name] next
    to the running executable, unless the environment variable [env] names one
    to run from elsewhere. A path that is absent, a directory, or not
    executable is refused loudly here — [Unix.create_process] reports an exec
    failure only inside the forked child, invisibly — with a message naming
    the expected path, [beside] (the binary the caller is running as), and
    [env] as the escape. *)

val stop : unit -> Exit_status.t
(** [stop ()] stops the running per-user daemon: it reads [daemon.json], and —
    if the claim is held (the daemon is live) — sends the recorded pid a SIGTERM
    and waits, bounded, for the claim to release. A free claim with a stale
    [daemon.json] is unlinked. No daemon running is a clean success-shaped no-op
    (idempotent stop); a wedged daemon that never releases is a
    {!Exit_status.Runtime_error} naming the pid. Uses no store — it resolves the
    directories from the environment and speaks only the claim and the signal.
*)
