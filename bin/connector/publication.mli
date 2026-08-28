(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The review publication renderer.

    A publication decides how one review run lands on a pull request: each
    blocking finding whose claimed location is verified against the reviewed
    diff becomes one review-comment thread, and every other finding becomes a
    row of the single summary comment. {!of_findings} derives the whole
    publication from values alone and {!requests} projects it as the ordered
    HTTP requests a workflow executes; the module is pure — no I/O — and
    stands alone from the rest of the executable. *)

(** Publication errors. *)
module Error : sig
  type t
  (** The type for errors: which part of an input is unacceptable, and why. *)

  val message : t -> string
  (** [message e] is [e]'s one-line diagnostic. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

(** The reviewed diff, reduced to what anchoring needs. *)
module Diff : sig
  type t
  (** The type for diffs: for every new-side file, the commentable new-side
      lines — the lines a pull-request review thread can attach to — and
      their text. A line is commentable iff a hunk shows it as added or as
      context. *)

  val of_unified : string -> (t, Error.t) result
  (** [of_unified bytes] reads [bytes] as [git diff] output. Hunk headers and
      hunk bodies are read strictly — a malformed hunk header, a hunk line
      outside the header's counts, or a truncated hunk is an [Error] naming
      the offending line — while unrecognized lines between hunks (extended
      headers, mode changes, binary-file stanzas and their payloads) are
      skipped, so a binary or metadata-only file simply contributes no
      commentable lines. A deleted file has no new side, and a rename
      contributes its new-side path. The tab git suffixes to a target name
      containing a space is stripped. *)

  val line_text : t -> path:string -> line:int -> string option
  (** [line_text t ~path ~line] is the text of commentable line [line] of the
      new-side file [path], without its one-character diff prefix, or [None]
      when no hunk shows that line. *)

  val commentable_lines : t -> path:string -> int list
  (** [commentable_lines t ~path] are the commentable new-side lines of
      [path], ascending; the empty list when the diff does not touch
      [path]. *)
end

(** Findings whose claimed location is verified against the diff. *)
module Anchored : sig
  type t = {
    finding : Review_finding.t;
    fingerprint : Review_finding.Fingerprint.t;
        (** The finding's stable identity. Fingerprints exist only for
            anchored findings. *)
    matched_line : int;
        (** The commentable line whose text matched the finding's [anchor] —
            the line the thread attaches to. It may differ from the finding's
            claimed [line]: the quote is the primary key and the claimed line
            only disambiguates between multiple occurrences. *)
    end_line : int option;
        (** The last line of a multi-line thread, clamped to the hunk holding
            {!matched_line}; [None] when the clamped range collapses to
            {!matched_line}. *)
  }
  (** The type for anchored findings: the finding's [anchor], trimmed, equals
      the trimmed text of a commentable line of its claimed [path] — at
      exactly one line, or at the occurrence nearest the claimed [line] when
      several match (an exact tie stays unanchored). The claimed line is a
      tiebreak, never a gate: a right quote with a wrong line still anchors,
      while a quote found nowhere among the file's commentable lines — a
      hallucinated location above all — never becomes a thread. Context lines
      are commentable, so a finding may deliberately thread on an unchanged
      line inside a hunk. *)
end

(** Findings published as summary rows. *)
module Unanchored : sig
  type t = {
    finding : Review_finding.t;
    permalink : string;
        (** A permanent link to the finding's claimed location in the
            reviewed head tree. *)
  }
  (** The type for summary-row findings — every finding that does not get its
      own thread: non-blocking findings, blocking findings the diff does not
      corroborate, and blocking findings demoted by the per-run thread
      cap. *)
end

(** Publication policies. *)
module Policy : sig
  type badge = Red | Yellow | Green
  (** The type for review badges: [Red] when any blocking finding exists,
      [Yellow] when only non-blocking findings exist, [Green] when there are
      none. *)

  type t = { block_on : Review_finding.Severity.t list }
  (** The type for policies. [block_on] lists the severities that block: a
      blocking finding colors the badge [Red] and, when anchored, gets its
      own thread. *)

  val default : t
  (** [default] blocks on {!Review_finding.Severity.P0} and
      {!Review_finding.Severity.P1}. *)

  val blocks : t -> Review_finding.Severity.t -> bool
  (** [blocks t severity] is [true] iff [severity] is in [t.block_on]. *)

  val badge : t -> Review_finding.t list -> badge
  (** [badge t findings] is the badge [findings] earn under [t]. *)
end

(** Machine-readable comment markers.

    Markers are HTML comments — invisible in rendered comments — that let a
    later run recognize its own output. This module is the only emitter of
    HTML comments in a publication, and every model-authored string is
    rendered with its comment delimiters neutralized, so a marker found in a
    posted comment was necessarily written by a publisher. *)
module Marker : sig
  val summary : origin:string -> string
  (** [summary ~origin] tags the summary comment, naming the publishing
      [origin] — a non-empty token of lowercase letters, digits, [-], and [:]
      that lets coexisting publishers tell their comments apart. Raises
      [Invalid_argument] on any other [origin]. *)

  val finding : origin:string -> Review_finding.Fingerprint.t -> string
  (** [finding ~origin fp] tags a finding thread with the fingerprint [fp],
      rendered as its 16 hexadecimal characters, and the publishing [origin]
      (same token grammar and raise as {!summary}). *)

  val origin_of_name : string -> string
  (** [origin_of_name name] folds an arbitrary name onto the origin token
      grammar: uppercase letters fold down, and every other byte outside
      lowercase letters, digits, and [-] becomes [-] — [:] included, since
      it is a composer's separator, never the folded name's. The result is
      empty exactly when [name] is; a composer prefixing its own non-empty
      token (["routine:" ^ ...]) always builds a valid origin. *)

  val marks : string -> bool
  (** [marks body] is [true] iff [body] carries a marker of this grammar —
      a finding marker or a summary marker, bare or origin-bearing. Comment
      listings are filtered on it (with an author check: marker presence
      alone is forgeable), so the filter can never drift from the grammar
      the markers are written in. *)
end

(** The publisher's comments already on the pull request. *)
module Posted : sig
  type t
  (** The type for posted state: the finding fingerprints already carried by
      a comment on the pull request, and the summary comment's id when one
      exists. *)

  val decode : string -> (t, Error.t) result
  (** [decode bytes] reads posted comments from [bytes]: a JSON array of
      comment objects, each carrying at least an [id] member (a positive
      integer) and a [body] member (a string); other members are ignored. The
      caller feeds it the publisher's own comments — review threads and issue
      comments merged — already filtered by author. Fingerprints are
      extracted from bodies by the {!Marker} grammar, accepting both the
      origin-bearing form and the bare form without an origin token; a
      marker-like fragment with a malformed fingerprint or a missing closer
      is ignored. *)

  val mem : t -> Review_finding.Fingerprint.t -> bool
  (** [mem t fp] is [true] iff a posted comment carries [fp]'s marker. *)

  val summary_id : t -> int option
  (** [summary_id t] is the id of the first posted comment carrying the
      summary marker, if any. *)
end

(** Publication requests. *)
module Request : sig
  type t = {
    label : string option;
        (** The posted finding's fingerprint in hexadecimal; [None] for the
            summary request. *)
    method_ : [ `POST | `PATCH ];
    path : string;  (** The request path under the API host. *)
    body : Jsont.json;  (** The request's JSON body. *)
  }
  (** The type for publication requests. *)

  val to_json : t -> Jsont.json
  (** [to_json t] is [t] as the wire object {!Envelope.to_json} embeds: the
      members [label] (string or null), [method], [path], and [body]. *)

  val of_json : context:string -> Jsont.json -> (t, Error.t) result
  (** [of_json ~context json] reads a request back from its {!to_json}
      shape; [context] prefixes error diagnostics. The read is strict where
      it matters: [method] must be [POST] or [PATCH], and [path] must be a
      [/]-leading string of [/]-separated segments drawn from
      [A-Za-z0-9._~%-], none of them empty, ["."], or [".."] — the paths
      GitHub's REST surface needs, and nothing a tampered envelope could
      use to point the caller's credential outside them (GitHub's edge
      normalizes dot-segments) or to cut the path short with [?] or
      [#]. *)
end

(** The review envelope — the one wire format between [github review] and
    [github publish]. Encode and decode live together here so the pipe's two
    ends cannot drift. *)
module Envelope : sig
  type t = {
    threads : Request.t list;
        (** The thread requests, in posting order. *)
    summary : Request.t;  (** The single sticky summary request. *)
    threads_safe : bool;
        (** Whether the thread requests are safe to send; see
            {!threads_safe}. *)
  }
  (** The type for review envelopes. *)

  val to_json : t -> Jsont.json
  (** [to_json t] is the envelope object: [schema_version] (always [1]),
      [type] (always ["github.review"]), [review] (the thread requests),
      [summary], and [threads_safe], in that order. *)

  val decode : string -> (t, Error.t) result
  (** [decode bytes] reads an envelope back from [bytes]. A missing or
      foreign [type], a malformed member, or a request that fails
      {!Request.of_json} is an [Error] naming the offending part; unknown
      members are ignored. *)
end

(** The poster's per-request outcome line — the one wire format between
    [github publish]'s output and whatever reaps it. Emit and fold live
    together here so the pipe's two ends cannot drift. *)
module Outcome : sig
  type t = {
    label : string option;
        (** The posted finding's fingerprint in hexadecimal; [None] for the
            summary request. *)
    status : int;  (** The HTTP status the request was answered with. *)
    error : string option;
        (** A short excerpt of a non-[2xx] answer's body, when one was
            kept. *)
  }
  (** The type for outcome lines. *)

  val to_json : t -> Jsont.json
  (** [to_json t] is the outcome line's wire object: [schema_version]
      (always [1]), [type] (always ["github.publish"]), [label] (string or
      null), [status], and [error] when present, in that order. *)

  val threads_posted : string -> int
  (** [threads_posted bytes] counts the thread requests the poster output
      [bytes] reports answered [2xx] — the labeled lines; the summary line
      carries a null label and is not a thread. Lines that are not outcome
      lines are passed over. *)

  val summary_ok : string -> bool
  (** [summary_ok bytes] is [true] iff the poster output [bytes] reports
      the summary request — the null-labeled line — answered [2xx]. *)
end

type t
(** The type for publications: the derived badge, the threads to post, and
    the summary comment to write. *)

val of_findings :
  diff:Diff.t ->
  policy:Policy.t ->
  posted:Posted.t ->
  origin:string ->
  owner_repo:string ->
  number:int ->
  head:string ->
  base_label:string ->
  Review_finding.Document.t ->
  t
(** [of_findings ~diff ~policy ~posted ~origin ~owner_repo ~number ~head
    ~base_label document] is the publication of [document] on pull request
    [number] of the [owner_repo] repository (["owner/repo"]), whose reviewed
    head commit is [head] — a full hash; [base_label] names what the head was
    reviewed against, for display only, and [origin] is the token stamped
    into the emitted {!Marker}s. The derivation is total:

    - A finding threads iff its severity blocks under [policy] and it anchors
      in [diff] (see {!Anchored.t}); every other finding is a summary row.
    - A thread is posted only when its fingerprint is not in [posted];
      already-posted findings are left exactly as they are — never edited,
      deleted, or resolved. Findings sharing one fingerprint within the
      document post one thread: the first in posting order.
    - At most 20 threads are posted per run, gravest severity first, then
      path and line. Findings beyond the cap demote to summary rows, and the
      summary notes how many were not threaded this run. *)

val badge : t -> Policy.badge
(** [badge t] is the publication's badge. *)

val threads : t -> Anchored.t list
(** [threads t] are the findings posted as new threads this run, in posting
    order. *)

val summary_rows : t -> Unanchored.t list
(** [summary_rows t] are the summary table's rows, gravest severity first,
    then path and line. *)

val overflow : t -> int
(** [overflow t] is the number of blocking anchored findings demoted to
    summary rows by the per-run thread cap. *)

val threads_safe : t -> bool
(** [threads_safe t] is [false] exactly when the document carries a blocking
    finding, yet no thread is posted this run and no blocking finding's
    fingerprint is already on the pull request — the signature of a diff that
    does not correspond to the head the findings were produced at. When it is
    false, {!requests} carries no thread requests; the flag names why that
    list is empty. A fully converged re-run — every blocking finding already
    posted — stays [true]. *)

type requests = {
  threads : Request.t list;
      (** One [`POST] per fresh thread, in posting order. *)
  summary : Request.t;  (** The single sticky summary upsert. *)
}
(** The type for a publication's requests. *)

val requests : t -> requests
(** [requests t] are the requests that publish [t]: one [`POST] to
    [/repos/OWNER/REPO/pulls/N/comments] per thread — its body carries
    [body], [commit_id], [path], [line], and [side] (always ["RIGHT"]:
    threads anchor on new-side lines), plus [start_line] and [start_side]
    (also ["RIGHT"]) when the thread spans lines — and exactly one summary
    request, a [`PATCH] of the posted
    summary comment when {!Posted.summary_id} knows one and a [`POST] to
    [/repos/OWNER/REPO/issues/N/comments] otherwise. A thread body renders
    the severity, title, and finding body — model text is fenced so it cannot
    ping mentions — and ends with the finding's marker; the summary body
    renders the badge, the reviewed head and base, the summary-row table with
    permalinks, and the summary marker. *)
