(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Whole-document CAS persistence for session documents.

    A session is a journal semantically and a whole document on disk: every
    write encodes the exact supplied {!Mentat_session.t} — the store keeps no
    clock and authors no metadata — and lands by atomic rename, so a torn
    document is unrepresentable. The compare-and-set token is the SHA-256
    identity of the exact persisted bytes, held privately by the loaded
    {!Document.t}: two writers racing from one revision produce exactly one
    commit and one {!Error.Conflict}, across fibers and across processes.

    These are views over one opened store root ({!Mentat_store.open_}); every
    operation takes that root. Writers serialize on a sibling
    [sessions/<id>.lock] advisory lock across processes and on the opened root's
    keyed registry across fibers. Durable syncs run in a systhread the calling
    fiber owns until completion, and the short read-compare-replace critical
    section runs under cancellation protection once the comparison has
    succeeded.

    Corruption is isolated, structural, and loud: a decode failure is a located,
    typed error, and one corrupt session never hides the healthy rest of a
    {!scan}. *)

(** {1:corruption Corruption} *)

module Corrupt : sig
  type t = private {
    id : Mentat_session.Id.t option;
        (** The session the fact locates: present whenever the op addressed a
            known session — always for {!create}, {!load}, and {!commit} — and
            parsed from the store path during {!scan}, where it is absent for
            the [sessions/] root and for unparseable directory names. *)
    path : string;
    message : string;
  }
  (** The type for corrupt persisted data: a decode failure (including an
      unsupported document version) or a non-file where a file was expected,
      located at a path. Never a caller/domain error. *)

  val id : t -> Mentat_session.Id.t option
  (** [id t] is the session id [t] locates, when available. *)

  val path : t -> string
  (** [path t] is the offending document path. *)

  val message : t -> string
  (** [message t] is the decode or validation diagnostic. *)

  val diagnostic : t -> Mentat_diagnostic.t
  (** [diagnostic t] is the reportable presentation of [t]. It keeps the
      addressed session id in the subject when present and the exact path and
      decoder detail in context. Store-owning callers keep [t] for control flow;
      protocol responders use this conversion when returning partial listing
      diagnostics. *)
end

(** {1:errors Errors} *)

module Error : sig
  (** Session store errors. *)

  type t =
    | Not_found of Mentat_session.Id.t
        (** No document exists for the requested session. *)
    | Already_exists of Mentat_session.Id.t
        (** {!create} found an existing document for the id. *)
    | Conflict of {
        id : Mentat_session.Id.t;
        expected : Mentat_digest.t;
        actual : Mentat_digest.t;
      }
        (** The document changed after [expected] was observed; [actual] is the
            revision currently on disk. Digests identify exact bytes; they are
            diagnostic, never a caller-composable token. *)
    | Locked of { id : Mentat_session.Id.t; holder : Owner.t option }
        (** {!remove} could not acquire the session's run fence: a driver is
            active, so the physical removal is refused rather than unlinking a
            live lock. [holder] names the driver when its owner line was
            readable. *)
    | Corrupt of Corrupt.t
        (** Persisted data is not valid: a located {!Corrupt.t} fact. The fact
            carries the session id whenever the op addressed a known session —
            always for {!create}, {!load}, and {!commit} — and omits it only for
            {!scan}'s [sessions/] root and unparseable directory names. *)
    | Io of Io.t  (** A filesystem or lock primitive failed. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. Callers that need
      stable control flow inspect [e] directly. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats {!message} output. *)

  val diagnostic : t -> Mentat_diagnostic.t
  (** [diagnostic e] is the user-facing diagnostic for [e]. A corrupt document
      renders "session <id> is invalid" when the fact carries an id and names
      the persisted path otherwise, with the path and decoder detail in the
      context. *)
end

(** {1:documents Documents} *)

module Document : sig
  type t
  (** The type for a loaded or saved document: a {!Mentat_session.t} paired
      privately with the {!Mentat_digest.t} of its exact persisted bytes — the
      CAS token. Only store operations mint one, so its revision always matches
      its bytes; it goes stale the instant another write replaces the same
      session. *)

  val id : t -> Mentat_session.Id.t
  (** [id t] is the id of [t]'s session. *)

  val session : t -> Mentat_session.t
  (** [session t] is [t]'s session. *)

  val revision : t -> Mentat_digest.t
  (** [revision t] is the content identity of [t]'s persisted bytes — for
      diagnostics and conflict reporting only. There is no way to build a
      [Document.t] from a session plus a digest, which is the whole invariant.
  *)
end

(** {1:operations Operations} *)

val create : Handle.t -> Mentat_session.t -> (Document.t, Error.t) result
(** [create root session] creates and saves a new document encoding exactly
    [session], failing rather than replacing an existing document. This is
    unfenced: the session does not exist yet, so there is no fence to take.
    Durable on return: file data, [sessions/<id>/], and the [sessions/] parent
    entry — the parent sync is unconditional, so an entry inherited unsynced
    from a crashed predecessor is also made durable. A leftover [sessions/<id>/]
    without a document is adopted only when empty (a crashed create's own
    residue): a non-empty one is damaged or foreign state and is refused as
    {!Error.Corrupt} naming the directory. {!Error.Already_exists} if a document
    for the id exists; {!Error.Corrupt} if the target path is a non-file;
    {!Error.Io} on filesystem failure.

    Raises [Invalid_argument] if [session] will not encode — an unencodable
    value is the caller's bug, not disk corruption. *)

val create_seeded :
  Handle.t ->
  Mentat_session.t ->
  seed:(unit -> (unit, Error.t) result) ->
  (Document.t, Error.t) result
(** [create_seeded root session ~seed] is {!create} with a durable seeding hook
    for a branch: after the fresh empty session directory is ensured and before
    the document — the commit point — is written, [seed ()] runs. [seed]
    populates the session's sibling durable state (its mutation ledger and
    blobs) durably. If [seed] fails the document is not written and the session
    does not exist, so an aborted branch never leaves a document whose settled
    claims reference facts the seed did not finish writing; its partial ledger
    and blob residue makes a retry refuse with {!Error.Corrupt}, exactly as any
    other document-less non-empty directory does. {!create} is
    [create_seeded ~seed:(fun () -> Ok ())].

    Errors are {!create}'s, plus whatever [seed] returns. Raises
    [Invalid_argument] as {!create}. *)

val on_disk_dir : Handle.t -> Mentat_session.Id.t -> string
(** [on_disk_dir root id] is the native path of [id]'s session directory under
    [root] — the one place the [sessions/<escaped id>] layout, its
    percent-escaping included, is resolved for a caller. It is a "would-be
    location" probe: the directory need not exist, and the string is the root as
    opened (so a root rename can stale it), so it is only for external tooling
    that stats a sidecar artifact ([session.json], [ledger.jsonl]) by absolute
    path — never a store operation, which always addresses the opened root
    capability. A mismatch degrades a probe to "missing", never a wrong claim.
*)

val stamp : Handle.t -> Mentat_session.Id.t -> string option
(** [stamp root id] is a cheap identity of [id]'s persisted document bytes,
    derived from the document file's metadata (device, inode, size,
    modification time) — one [stat] where {!load} is a read and a decode, for
    consumers that poll a journal they do not drive. Every commit replaces the
    document onto a fresh inode, so in practice equal stamps mean unchanged
    bytes; the equality is metadata, not content, so a stamp only elides a
    reload on a poll — it never stands in for a read whose value a caller acts
    on. [None] when the document is missing or unreadable. *)

val load : Handle.t -> Mentat_session.Id.t -> (Document.t, Error.t) result
(** [load root id] loads and decodes the document for [id] through
    {!Mentat_session.jsont} — semantic replay is validated before [Ok].
    {!Error.Not_found} if absent; {!Error.Corrupt} if the path is a non-file,
    the bytes are not a valid document (including an unsupported version or a
    history that does not replay), or the embedded id differs; {!Error.Io}
    otherwise. This is how a successor re-reads the journal head after acquiring
    the fence, and how observation reads without one. *)

val commit :
  Handle.t ->
  fence:Run_lock.guard ->
  Document.t ->
  Mentat_session.t ->
  (Document.t, Error.t) result
(** [commit root ~fence doc session] replaces the saved document iff [doc]'s
    revision is still current, encoding exactly [session] — the store authors
    nothing. [fence] is the committed session's run fence — the proof that this
    process is its sole driver. An existing session is only committed under the
    fence, so the coherence {!Export} documents is type-enforced rather than
    assumed. The bytes are written by atomic rename and the returned document
    carries the new revision. {!Error.Not_found}, {!Error.Conflict} (carrying
    the expected and actual byte digests), {!Error.Corrupt}, and {!Error.Io} as
    their names say.

    Raises [Invalid_argument] if [session]'s id differs from [doc]'s, if [fence]
    is not the live fence for that id, or if [session] will not encode. *)

val remove : Handle.t -> Document.t -> (unit, Error.t) result
(** [remove root doc] physically removes a document iff its revision is current
    — the rollback primitive for a newly created document whose wider operation
    could not commit. User-facing deletion is a lifecycle tombstone recorded
    through {!commit}, not this op. A physical remove deletes [sessions/<id>/]
    recursively — document, event log, blobs — the one blob reclamation point.

    Because the removal unlinks [run.lock] with the rest of the tree, [remove]
    first acquires the session's run fence and holds it through the [rmtree]: if
    a driver holds the fence the removal is refused with {!Error.Locked} rather
    than unlinking a live lock and admitting a second driver over a recreated
    inode. The sibling [sessions/<id>.lock] doc-lock file is unlinked
    best-effort after the removal — it is coordination residue, not session
    state, so a failure to unlink leaves an inert empty file, never an error.
    {!Error.Not_found}, {!Error.Conflict}, {!Error.Locked}, {!Error.Corrupt},
    {!Error.Io}. *)

val scan : Handle.t -> (Document.t list * Corrupt.t list, Error.t) result
(** [scan root] is an exact full scan: every document under [sessions/] is
    decoded; good documents are returned in directory-name order and corrupt
    ones as located {!Corrupt.t} facts that never hide the healthy rest. A
    non-empty session directory without a document is such a fact too — damaged
    state is surfaced, never silently skipped; only an empty document-less
    directory (a crashed create's residue) is invisible, and a non-directory
    entry under [sessions/] is skipped after its kind is checked, so a stat
    failure (EACCES/ENOTDIR) surfaces as {!Error.Io} rather than escaping.
    Missing store directories are [Ok ([], [])].

    There is no persisted index, no summary cache, and no rebuild op: lifecycle
    filtering, recency ordering, text search, and limits are query policy
    composed above this exact result, never store-side defaults the scan cannot
    keep coherent. *)
