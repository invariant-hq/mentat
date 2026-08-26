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

val with_lock : string -> (unit -> ('a, string) result) -> ('a, string) result
(** [with_lock lock_path f] runs [f] holding the advisory lock at [lock_path]:
    an in-process [Eio.Mutex] keyed by [lock_path] (so a second fiber in this
    process waits) plus a cross-process [Unix.lockf F_TLOCK] retried on a
    cancellable [Eio_unix.sleep] backoff (so a second process waits without an
    uncancellable blocking [F_LOCK]) — the two-level pattern the session store
    uses. Must run inside an Eio fiber. The lock file's parent chain is created
    first; [Error] if the lock cannot be taken, otherwise [f]'s own result. *)
