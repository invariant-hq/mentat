(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The typed review-findings document.

    A review run reports its outcome as one JSON document — a summary and a
    list of findings, each locating one issue in the reviewed tree.
    {!Document.decode} is the strict reader for that payload and
    {!Document.schema} states the same contract as a JSON Schema value for
    constraining the model's structured output. {!Fingerprint} derives the
    stable identity a publisher uses to recognize a finding across runs. The
    module is pure — no I/O — and stands alone from the rest of the
    executable. *)

(** Finding severities, gravest first. *)
module Severity : sig
  type t =
    | P0  (** Gravest. *)
    | P1
    | P2
    | P3  (** Mildest. *)

  val of_string : string -> t option
  (** [of_string s] is the severity named [s] (["P0"] to ["P3"]), or [None]. *)

  val to_string : t -> string
  (** [to_string t] is ["P0"], ["P1"], ["P2"], or ["P3"]. *)

  val compare : t -> t -> int
  (** [compare a b] orders severities gravest first: {!P0} sorts before
      {!P3}. *)
end

(** Finding bodies — model text with HTML comment delimiters neutralized. *)
module Body : sig
  type t
  (** The type for finding bodies. Constructed only by {!of_model_text}, so a
      body's {!text} never contains the substring ["<!--"] or ["-->"]. *)

  val of_model_text : string -> t
  (** [of_model_text s] is [s] with every HTML comment delimiter neutralized:
      a U+200B ZERO WIDTH SPACE is inserted between the two hyphens of each
      ["<!--"] and ["-->"] occurrence, scanning left to right without skipping
      any potential start, so overlapping occurrences are all broken. The text
      looks unchanged when rendered, but no rendering of a body can ever open
      or close an HTML comment — a publisher that brackets bodies with HTML
      comment markers keeps those markers unforgeable. The insertion drops no
      visible content, but is not undone by {!text}. *)

  val text : t -> string
  (** [text t] is the neutralized body text. *)
end

(** Decode errors. *)
module Error : sig
  type t
  (** The type for strict-decode errors: which member of the document is
      unacceptable, and why. *)

  val message : t -> string
  (** [message e] is [e]'s one-line diagnostic, naming the offending member —
      with its finding index where one applies — and the reason. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

type t = {
  severity : Severity.t;
  path : string;  (** Root-relative path of the file the finding is about. *)
  line : int;  (** 1-based line the finding starts on. *)
  end_line : int option;
      (** Inclusive last line of a multi-line finding, at least {!line}. *)
  anchor : string;  (** The exact source line text the finding is about. *)
  title : string;
      (** One-line summary, with HTML comment delimiters neutralized (see
          {!Body.of_model_text}). *)
  body : Body.t;  (** Full explanation. *)
}
(** The type for review findings. Values built by {!Document.decode} satisfy:
    [line >= 1], [end_line] is at least [line] when present, [path] and
    [title] are non-empty, and [anchor] is non-blank. *)

(** Stable finding identities.

    A fingerprint identifies a finding across runs by what it is about — its
    path, anchor, and title — not by its position in the document or its body
    wording. *)
module Fingerprint : sig
  type t
  (** The type for fingerprints. *)

  val of_finding : path:string -> anchor:string -> title:string -> t
  (** [of_finding ~path ~anchor ~title] is the fingerprint of the finding with
      those members: the first 16 lowercase hexadecimal characters of the
      SHA-256 of the [mentat.github.finding.v1] domain and the three members,
      each length-framed, with [anchor] trimmed of leading and trailing
      whitespace first — a publisher matches anchors by their trimmed quote,
      and hashing the same normal form keeps a re-padded quote naming the same
      line from minting a second identity. The framing is injective over
      arbitrary strings — no separator byte lives in-band, so no choice of
      members collides with another by shifting bytes across a member
      boundary. Callers pass a decoded finding's members; the neutralized
      [title] a decode produces is a pure function of the model's text, so the
      fingerprint is deterministic across runs. *)

  val to_hex : t -> string
  (** [to_hex t] is [t]'s 16 lowercase hexadecimal characters. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] identify the same finding. *)
end

(** The findings document — a review run's whole structured output. *)
module Document : sig
  type nonrec t = {
    summary : string;  (** The run's overall summary; may be empty. *)
    findings : t list;  (** The findings, in document order. *)
  }
  (** The type for findings documents. *)

  val decode : string -> (t, Error.t) result
  (** [decode bytes] is the document [bytes] denotes. The read is strict:
      malformed JSON, an unknown member at either level, a missing required
      member, a wrongly-typed member, an unrecognized severity, a [line] below
      1, an [end_line] below [line], an empty [path] or [title], or an
      [anchor] that is empty or only whitespace is an [Error] naming the
      offending member and finding index. Finding bodies and titles pass
      through {!Body.of_model_text}. *)

  val schema : Jsont.json
  (** [schema] is the document contract as a JSON Schema object using the
      [type], [properties], [required], [additionalProperties], [items], and
      [enum] keywords only. Every finding member is required except
      [end_line]; [additionalProperties] is [false] at both object levels. The
      bounds {!decode} puts on [line], [end_line], and emptiness are beyond
      this vocabulary, so {!decode} remains the authority. *)
end
