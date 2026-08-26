(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Executable-private filesystem primitives.

    The charter assigns file location, byte-capped reads, atomic writes,
    parent-directory creation, and cross-process locks to the executable — not
    to [mentat.config] (its pure core only parses and plans) and not to
    [mentat.store] (its lock is session-document-keyed by contract and
    deliberately private). This module is that assignment, shared by
    {!Config_io}, {!Trust_store}, and {!Composition}'s store staging.

    Every function renders IO failures as a clean [string] — no raw [Unix_error]
    or [Eio.Io] repr and no internal path beyond the one the caller passed.
    Absent is distinguished from unreadable ({!read_capped} returns [Ok None]
    only for a genuinely missing file). *)

val default_max_bytes : int
(** A generous cap for the small user-side documents this executable owns
    (config, trust). *)

val read_capped : max_bytes:int -> string -> (string option, string) result
(** [read_capped ~max_bytes path] is [Ok (Some bytes)] with the whole file,
    [Ok None] if [path] does not exist, or [Error message] on any other IO
    failure or if the file exceeds [max_bytes]. The cap replaces an unbounded
    [In_channel.input_all]; absent and malformed are never conflated. *)

val mkdir_p : string -> (unit, string) result
(** [mkdir_p path] creates [path] and every missing ancestor with [0o700],
    catching {e every} [Unix_error] — not only [EEXIST] — into an [Error] at the
    source. A path component that is a regular file surfaces as a rendered
    [Error] rather than an uncaught exception. *)

val remove_tree : string -> unit
(** [remove_tree path] removes [path] and everything under it, best-effort:
    entries are examined with [lstat], so a symlink is unlinked — never
    followed into its target — and failures are swallowed rather than rendered
    (the tree may be half-gone already, and the caller can do nothing about
    leftovers a race keeps alive). *)

val atomic_write : perms:int -> string -> string -> (unit, string) result
(** [atomic_write ~perms path bytes] writes [bytes] to [path] atomically: create
    the parent chain, write a sibling temporary at [perms], [chmod] it to
    [perms] (defeating a restrictive umask on the secret-adjacent files), then
    rename over [path]. [Error message] on any IO failure, temporary cleaned up
    on the failure path. *)

val write_new :
  perms:int -> string -> string -> ([ `Written | `Exists ], string) result
(** [write_new ~perms path bytes] creates [path] exclusively ([O_CREAT] with
    [O_EXCL]) at [perms] and writes [bytes] to it. [`Exists] when an entry —
    a dangling symlink included — already occupies [path], so a caller's
    refusal to overwrite cannot race a concurrent creator the way a
    check-then-write would. [Error message] on any other IO failure, with the
    partial file removed. *)

val append : string -> string -> (unit, string) result
(** [append path record] durably appends [record] plus a ['\n'] frame to the
    line-framed ledger at [path], creating it (and its parent chain) at
    [0o600] if missing. The append follows the store's ledger discipline: any
    torn, newline-less tail left by an interrupted writer is first truncated
    to the last record boundary, then the framed record is written at the end
    and fsynced, then the parent directory is fsynced. Once the write begins,
    a failure restores the pre-append boundary best-effort, so a caller's
    retry cannot duplicate records.

    Concurrent appenders in {e separate processes} are serialized by an
    advisory lock on the ledger itself, so one writer's boundary repair cannot
    truncate another's in-flight record. The lock does not exclude fibers of
    one process (POSIX record locks are per-process); in-process callers
    serialize themselves. A [record] containing a raw ['\n'] would forge a
    record boundary and is refused. [Error message] on any IO failure. *)

val require_private : string -> (unit, string) result
(** [require_private path] is [Ok ()] when the entry at [path] is accessible
    by its owner alone — no group or world permission bit set — and [Error]
    otherwise, naming the loose mode, the way sshd refuses a loose key file. A
    missing or unstattable entry is also an [Error]: the caller asks because
    the entry guards a secret, and an absent guard is not a private one.
    Symlinks are followed — the verdict is about the entry that would actually
    be read. *)

val with_lock : string -> (unit -> ('a, string) result) -> ('a, string) result
(** [with_lock lock_path f] runs [f] holding the advisory lock at [lock_path]:
    an in-process [Eio.Mutex] keyed by [lock_path] (so a second fiber in this
    process waits) plus a cross-process [Unix.lockf F_TLOCK] retried on a
    cancellable [Eio_unix.sleep] backoff (so a second process waits without an
    uncancellable blocking [F_LOCK]) — the two-level pattern the session store
    uses. Must run inside an Eio fiber. The lock file's parent chain is created
    first; [Error] if the lock cannot be taken, otherwise [f]'s own result. *)
