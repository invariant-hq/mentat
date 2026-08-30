(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The per-session attachment blob store: content-addressed, write-once,
    fence-free image bytes under [sessions/<id>/attachments/].

    A namespace distinct from the mutation blob store ({!Mutation}). Attachment
    bytes are model-visible media the engine externalizes out of the transcript
    (a pasted or [-i] image, a read-tool image), keyed by their content
    reference; they carry no file-change evidence, so they never share the
    mutation store's sole-owner, blobs-before-event discipline. The store is
    {e fence-free}: an attachment write is a boundary observation, not a session
    write — a headless [-i] attach happens before the run fence exists, and a
    TUI attach happens with no active turn — so no operation takes a fence
    guard. Every blob is written temp-then-fsync-then-rename-then-dir-fsync, so
    a returned reference names only durable bytes.

    Write-once and idempotent: identical bytes converge to a no-op, and a
    pre-existing blob is verified against its reference — never trusted — so an
    externally damaged blob is a {!Error.Blob_mismatch}, not silently returned.
*)

module Error : sig
  (** A filesystem or integrity failure in the attachment store. *)
  type t =
    | Blob_mismatch of {
        expected : Mentat_digest.Content_ref.t;
        actual : Mentat_digest.Content_ref.t;
      }  (** A pre-existing blob's bytes do not hash to its reference. *)
    | Non_regular_file of string  (** A blob path is not a regular file. *)
    | Io of Io.t  (** A filesystem primitive failed. *)

  val message : t -> string
  (** [message t] is a human-readable diagnostic. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats {!message} output. *)

  val diagnostic : session:Mentat_session.Id.t -> t -> Mentat_diagnostic.t
  (** [diagnostic ~session t] renders [t] as a structured diagnostic naming
      [session]. *)
end

val put :
  Handle.t ->
  session:Mentat_session.Id.t ->
  string ->
  (Mentat_digest.Content_ref.t, Error.t) result
(** [put root ~session bytes] writes [bytes] into [session]'s attachment
    namespace, content-addressed and write-once, keyed by
    [Content_ref.of_contents bytes]; durable on return. Idempotent — a
    pre-existing blob with the same reference is verified, not rewritten; an
    externally damaged pre-existing blob is [Error.Blob_mismatch]. *)

val get :
  Handle.t ->
  session:Mentat_session.Id.t ->
  Mentat_digest.Content_ref.t ->
  (string option, Error.t) result
(** [get root ~session reference] is the attachment bytes for [reference], or
    [None] when absent — a fence-free read verified against [reference] before
    return (a mismatch is [Error.Blob_mismatch]). *)
