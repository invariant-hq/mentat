(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The run fence — one driver per session.

    The fence's OS half is an advisory lock on [sessions/<id>/run.lock] that
    owner death releases. Its same-process half is an atomic pending-then-held
    reservation in the opened root's registry, taken under one Stdlib mutex
    {e before} any descriptor is opened: POSIX record locks never conflict
    between two fibers of one process, and closing any descriptor to the inode
    drops every lock the process holds on it, so at most one same-process
    contender ever opens a descriptor and the owning process holds exactly one
    descriptor for the fence's lifetime.

    The primitive is POSIX [lockf] on purpose, not an open-file-description
    lock: macOS has no [F_OFD_SETLK], so per-process, close-any-descriptor
    semantics are the real contract on a first-class target — the reservation
    discipline above is what makes the portable primitive safe, not a
    per-descriptor lock macOS cannot provide.

    The lock descriptor is opened through the root capability and is
    [O_CLOEXEC]: processes spawned under the fence must not inherit it, or an
    inherited copy would keep the advisory lock alive past the driver's own exit
    and defeat the owner-death release.

    The store never waits on the fence and never decides policy: [`Held] is an
    expected outcome the caller acts on, and the engine maps it to protocol
    [Busy]. *)

module Owner = Owner
(** Ephemeral driver identities. *)

type guard = Handle.guard
(** The type for a held run lock: one close-on-exec descriptor plus one
    confirmed registry reservation, matched by the witness token the guard
    carries. Releasing it, or this process exiting, frees the fence. Re-exported
    abstractly as [Mentat_store.Run_lock.guard]: no mutable cell and no fence
    internals leak to a caller. *)

type acquire_error = [ `Held of Owner.t option | `Io of Io.t ]
(** The type for acquisition outcomes that are not the fence. [`Held None] means
    the fence is held but its owner line was unreadable (torn or
    pre-owner-line) — the exclusion is real, only the display is absent — or
    that a same-process {!holder} probe had its descriptor open at that
    instant, a transient refusal a retry finds gone: a lock taken during the
    probe's window would be dropped when the probe descriptor closes, so the
    contender is turned away instead. *)

val try_acquire :
  sw:Eio.Switch.t ->
  Handle.t ->
  session:Mentat_session.Id.t ->
  owner:Owner.t ->
  (guard, acquire_error) result
(** [try_acquire ~sw root ~session ~owner] is the fence for [session] over the
    opened [root], without blocking or waiting — whether to wait, and how, is
    caller policy. The guard's sole descriptor is registered on [sw]: the switch
    is the normal release path, and exceptions or cancellation cannot leak the
    fence. Assumes [sessions/<id>/] exists — a session is created by
    {!Session.create} before it is ever driven, and the lock never creates the
    session directory. On success the owner line is rewritten under the held
    lock; on [`Held] the holder's line is read best-effort.

    {b Switch nesting.} [sw]'s finish releases the fence, so every operation
    performed under the guard must run within [sw]'s lifetime — nest any switch
    that scopes fenced work {e inside} [sw], never the reverse. Store operations
    re-check the guard's liveness inside their critical sections, but a release
    concurrent with an operation already past its check is excluded only by this
    nesting discipline. *)

val release : guard -> unit
(** [release guard] releases early, before the switch does. Idempotent; a
    released guard is inert, and using one where a live fence is required raises
    [Invalid_argument].

    Release closes the descriptor {e before} cancelling the registry reservation
    — the reservation must outlive the descriptor. In the reverse order a
    same-process contender admitted between the two steps could open and
    [F_TLOCK] a second descriptor to the still-locked inode (record locks never
    conflict within one process), and closing either descriptor would then
    silently drop the fence. *)

val holder :
  Handle.t ->
  session:Mentat_session.Id.t ->
  [ `Free | `Held of Owner.t option | `Io of Io.t ]
(** [holder root ~session] probes the fence for [session] without contending
    for it: it never creates [run.lock], never writes the owner line, and never
    acquires anything — the observation {!try_acquire} cannot make, because a
    free fence would be created and rewritten by it. [`Held display] names the
    holder from the owner line when it is readable ([None] when it is not — the
    exclusion is real, only the display is absent); [`Free] means no lock is
    held on the file, or the file does not exist. The lock, not the file, is
    the truth: a [run.lock] left behind by a crashed driver reads [`Free].

    {b Same-process visibility.} A fence held or being acquired by {e this}
    process is answered from the root's reservation registry with no
    descriptor touched — POSIX record locks never conflict within one process,
    so the OS probe cannot see them, and a probe descriptor opened onto an
    inode this process holds locked would drop the lock at close. The probe
    and same-process acquisition are mutually exclusive per key: while the
    probe descriptor is open no acquisition is admitted (it is turned away
    with a transient [`Held None]), so the no-same-process-lock premise holds
    across the probe's own suspension points, not merely at its first check.
    What the OS probe observes is then exactly the cross-process contract:
    [`Held] iff {e another} process holds the lock. *)

val session : guard -> Mentat_session.Id.t
(** [session guard] is the fenced session. *)

val owner : guard -> Owner.t
(** [owner guard] is the identity the fence was acquired with. *)
