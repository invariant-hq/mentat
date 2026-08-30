(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The two byte-relocation passes over model-visible media.

    The journal holds only [`Ref] (content-addressed); the wire holds [`Base64].
    Attachment blobs hold the decoded image bytes, so base64 is decoded on the
    way in and re-encoded on the way out.

    {!externalize} runs at admission, before any media-bearing fact is
    committed: an inline [`Base64] block is decoded, stored as an attachment
    blob, and rewritten to [`Ref]; an incoming [`Ref] is validated to resolve to
    a present blob, rejecting a fabricated reference. {!resolve_request} runs at
    the provider-call boundary, strictly after {!Mentat_llm.Request.digest} —
    every [`Ref] in the request's transcript is loaded and rewritten back to
    [`Base64], so the provider adapters never see an unresolved reference.

    Both channels are relocated: {!externalize} operates on any media-bearing
    [Mentat_llm.Content.t list] — a prompt's user content at admission and a
    returned tool output's media at settlement — and {!resolve_request} rewrites
    every [`Ref] in the whole request transcript, user-message and tool-result
    media alike. *)

type error =
  | Malformed_base64  (** An inline [`Base64] block's payload did not decode. *)
  | Missing_attachment of Mentat_digest.Content_ref.t
      (** A [`Ref] resolved to no stored blob: a fabricated reference at
          admission, or a lost blob at the provider-call boundary. *)
  | Store of Mentat_diagnostic.t  (** The attachment store failed. *)
  | Rebuild of string
      (** The resolved request failed reconstruction — structurally impossible
          (only a media source tag changes), retained as a loud fault. *)

val message : error -> string
(** [message error] is the user-facing diagnostic for [error]. The provider path
    prefixes a {!Rebuild} with its own context at the call site; the other arms
    are shared verbatim. *)

val externalize :
  put_attachment:
    (string -> (Mentat_digest.Content_ref.t, Mentat_diagnostic.t) result) ->
  attachment:
    (Mentat_digest.Content_ref.t -> (string option, Mentat_diagnostic.t) result) ->
  Mentat_llm.Content.t list ->
  (Mentat_llm.Content.t list, error) result
(** [externalize ~put_attachment ~attachment content] rewrites each inline
    [`Base64] media block of [content] to a [`Ref] by decoding it and storing
    the bytes with [put_attachment], and validates each incoming [`Ref] against
    [attachment], failing {!Missing_attachment} on a reference with no blob.
    [`Uri] and text blocks pass through. The result holds only [`Ref]/[`Uri]
    media and is safe to commit into the journal. *)

val resolve_request :
  attachment:
    (Mentat_digest.Content_ref.t -> (string option, Mentat_diagnostic.t) result) ->
  Mentat_llm.Request.t ->
  (Mentat_llm.Request.t, error) result
(** [resolve_request ~attachment request] rewrites every [`Ref] media block in
    [request]'s transcript back to [`Base64] by loading the blob with
    [attachment]. A request with no reference is returned unchanged. Must run
    strictly after {!Mentat_llm.Request.digest}. *)
