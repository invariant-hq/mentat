(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The opened store root, the per-root lock registry, and the run-fence guard.

    Internal to the store handles. One [open_] opens the store root once and
    returns the single capability every domain — {!Session}, {!Mutation},
    {!Review}, {!Run_lock}, {!Export} — is a view over. The root is identified
    by the opened directory's [(st_dev, st_ino)]; a process-local intern table
    maps that identity to the one shared {!Registry.t}, so two opens of the same
    physical root (reached by different paths) serialize through the same
    registry. The intern entry is reference-counted and removed when the last
    open over that root is released, so the table stays proportional to live
    roots and a recycled inode pair never inherits a dead root's registry. There
    is no canonical-path-string cache: a memoized realpath key outlives
    namespace changes, while device/inode identity cannot split or falsely merge
    a lock domain.

    The run-fence guard is defined here, not in {!Run_lock}, so its liveness
    check and validation anchor stay library-private: {!Run_lock} exposes only
    acquisition and release, while {!Mutation} and {!Export} reach the fence
    precondition through {!check_live} — a function no code outside the library
    can name or compose.

    {b Single-domain contract.} The store's own rule, not an Eio-mutex property:
    a root and its registry are used from the single Eio domain that opened the
    root. The keyed [Eio.Mutex.t] values in the registry are scheduler-bound and
    are not shared across domains; the intern table and the run-lock reservation
    table use Stdlib mutexes and are safe regardless of domain. The dir
    capability and the guard anchor are guarded only by this single-domain rule.
    Cross-domain use of a root is a programmer error. *)

module Registry : sig
  (** The per-root lock registry: keyed intra-process mutexes and the run-lock
      reservation table. *)

  type t
  (** The type for one physical root's registry. *)

  val with_keyed : t -> string -> (unit -> 'a) -> 'a
  (** [with_keyed t key f] runs [f] holding the [Eio.Mutex] for [key], creating
      and reference-counting the entry so the table stays proportional to live
      critical sections. *)

  type token
  (** The type for a reservation witness: minted by {!try_reserve} and carried
      by the guard whose acquisition it admitted. A reservation is matched only
      by its own witness, so a guard can never pass a liveness check against a
      reservation another acquisition minted — even one made with an equal, or
      the very same, {!Owner.t}. *)

  val try_reserve :
    t -> string -> Owner.t -> (token, [ `Reserved of Owner.t | `Probing ]) result
  (** [try_reserve t key owner] atomically reserves [key], minting its witness.
      [`Reserved holder] names the existing reservation's owner — this process
      is already acquiring or holding the session's fence. [`Probing] means a
      read-only fence probe ({!probe}) has a descriptor open on the inode: an
      acquisition admitted now would take a lock that closing the probe's
      descriptor silently drops, so the reserver is turned away for the
      probe's — bounded, descriptor-lifetime — duration instead. On [Ok] the
      reserver is exclusive within the process and must {!confirm} or
      {!cancel}. *)

  val confirm : t -> token -> unit
  (** [confirm t token] marks [token]'s reservation held — the OS lock is
      acquired and the owner line written. Only {!try_reserve} mints tokens, so
      no other acquisition path can confirm a reservation it does not hold. *)

  val cancel : t -> string -> token -> unit
  (** [cancel t key token] removes [key]'s reservation iff it is the one [token]
      witnessed, whatever its confirmation state. A reservation another
      acquisition minted is left in place, so a stale guard's release can never
      evict a successor's fence. *)

  val holds : t -> string -> token -> bool
  (** [holds t key token] is [true] iff [key]'s current reservation is the one
      [token] witnessed and it has been confirmed. *)

  val probe : t -> string -> (unit -> 'a) -> ('a, Owner.t) result
  (** [probe t key f] runs [f] with same-process acquisition of [key] excluded,
      and is the read-only fence probe's one entry: [f] opens, tests, and
      closes a probe descriptor on the fence inode, which is safe only while
      this process can hold no lock on it — closing {e any} descriptor drops
      every record lock the process holds on the inode, and POSIX record locks
      are invisible to a same-process test anyway. If [key] is reserved —
      pending or confirmed, this process is acquiring or holding the session's
      fence — [f] never runs and the reservation's owner is returned; the
      answer is the registry's, no descriptor is touched. Otherwise
      acquisitions of [key] are excluded ({!try_reserve} answers [`Probing])
      until [f] returns or raises. Probes coexist with each other: two open
      probe descriptors hold no locks to drop. *)
end

type t
(** The type for an opened store root: the directory capability, a root label
    for diagnostics, and the interned registry. *)

val open_ :
  sw:Eio.Switch.t ->
  Eio.Fs.dir_ty Eio.Path.t ->
  children:string list ->
  (t, [ `Layout of string * string | `Io of Io.t ]) result
(** [open_ ~sw path ~children] opens the existing directory capability [path]
    under [sw] and interns its registry by [(st_dev, st_ino)]. Each layout
    [child] the store owns is validated and created if absent: a child that
    exists and is not a directory is [`Layout (child, message)] — leftover or
    foreign state adopted as a store child would silently misplace every op
    under it. On success every created child's entry is synced in the root. The
    intern reference is released when [sw] finishes. *)

val path : t -> string -> Eio.Fs.dir_ty Eio.Path.t
(** [path t rel] is the capability for [rel] under the opened root — an
    [openat]-based path that names the same inode after a root rename. *)

val native : t -> string -> string
(** [native t rel] is the native path of [rel] under the root, as the root was
    opened. Unlike {!path} it is a plain string, so a root rename staleness is
    possible: it is only for external tooling that stats a sidecar artifact by
    absolute path (a "would-be location" probe), never for a store operation,
    which always goes through {!path}. *)

val registry : t -> Registry.t
(** [registry t] is the shared registry for [t]'s physical root. *)

(** {1:guards Run-fence guards} *)

type guard = {
  session : Mentat_session.Id.t;
  owner : Owner.t;
  fd : Eio_unix.Fd.t;
      (** The sole [O_CLOEXEC] descriptor to [run.lock]; closing it drops the OS
          lock. *)
  root_registry : Registry.t;
      (** The root registry the reservation lives in. *)
  key : string;  (** The reservation key: the session id. *)
  token : Registry.token;  (** The witness matching this acquisition's entry. *)
  anchor : Mentat_mutation.State.t option ref;
      (** The per-fence-tenure mutation validation anchor, acquisition-fresh and
          dying with the guard: {!Mutation.append} establishes it at the first
          append under the guard and advances it on each success. *)
  released : bool Atomic.t;
}
(** The type for a held run lock. Concrete within the library so {!Run_lock}
    builds and releases it and {!Mutation}/{!Export} read its anchor and check
    its liveness; re-exported abstractly as [Run_lock.guard] so no product
    concept and no mutable cell leaks to a caller. *)

val check_live : t -> guard -> unit
(** [check_live t guard] raises [Invalid_argument] unless [guard] is unreleased
    and holds the run lock in [t]'s registry — the typed precondition of every
    mutation append and of export capture. The reservation is matched by the
    witness token the acquisition minted, and [guard]'s registry must be [t]'s,
    so a guard cannot pass against another root or another acquisition's
    reservation — even one made with an equal, or the very same, {!Owner.t}. *)
