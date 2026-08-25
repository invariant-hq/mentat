(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure presentation grammar for tool transcript blocks.

    A block has one outcome-colored [⏺] header, one durable [⎿] result, and an
    optional viewport-bounded text preview. {!make} is the common floor for live
    and replayed tool facts. The distiller supplies a typed compact summary for
    built-ins and may place durable output rows in {!preview}; missing compact
    facts never become a loading state or an empty block.

    Task boards and mutation evidence are deliberately outside this module. Full
    boards are rendered from their own journal facts by {!Todo_board}; change
    summaries and diffs are rendered from mutation facts and the change-diff
    query. Tool output must not duplicate either source of truth. *)

(** {1:types Types} *)

(** The type for the stable user-facing classification of a tool call.

    Tool-name and protocol translation belongs to the distiller. This type is
    only presentation vocabulary; it carries no executable tool value.

    Every distinct tool has a distinct verb, so two different tools never share
    a transcript label. Tools that operate on OCaml source through the toolchain
    carry an [Ocaml_] verb, and their labels lead with "OCaml", so a reader can
    always tell a language-aware call from a plain workspace call. *)
type verb =
  | Read  (** Reading file content. *)
  | List  (** Listing names or entries. *)
  | Search  (** Searching workspace text. *)
  | Glob  (** Searching file paths by pattern. *)
  | Edit  (** Editing an existing file in place. *)
  | Patch  (** Applying a patch. *)
  | Create  (** Creating new content. *)
  | Shell  (** Running a shell command. *)
  | Shell_output  (** Reading a background command's captured output. *)
  | Shell_kill  (** Stopping a background command. *)
  | Fetch  (** Fetching one web resource. *)
  | Web_search  (** Searching the web. *)
  | Task  (** Delegating work to a child agent. *)
  | Todo  (** Updating the task board. The board itself renders separately. *)
  | Diagnostics  (** Reading compiler diagnostics. *)
  | Ocaml_search  (** Searching OCaml source structurally. *)
  | Ocaml_edit  (** Editing OCaml source through its syntax tree. *)
  | Ocaml_replace  (** Replacing matched OCaml expressions. *)
  | Ocaml_rename  (** Renaming an OCaml identifier across files. *)
  | Ocaml_eval  (** Evaluating an OCaml phrase. *)
  | Ocaml_docs  (** Reading OCaml interface documentation. *)
  | Ocaml_type  (** Looking up an OCaml expression's type. *)
  | Ocaml_definition  (** Looking up an OCaml definition. *)
  | Ocaml_references  (** Looking up OCaml references. *)
  | Skill  (** Loading a skill. *)
  | Plan  (** Proposing a plan. *)
  | Message  (** Sending an agent message. *)
  | Follow_up  (** Sending a follow-up message to a child agent. *)
  | Cancel  (** Cancelling child-agent work. *)
  | Wait  (** Waiting for child-agent work. *)
  | Question  (** Asking the user a question. *)
  | Other of string
      (** An unclassified tool. The string is its registered display name. *)

(** The type for the lifecycle verdict encoded by the header dot. *)
type dot =
  | Running
      (** The call is executing. The header dot uses the accent colour. *)
  | Awaiting
      (** The prepared call is waiting for approval and has not executed. The
          header dot stays muted so it cannot be mistaken for active work. *)
  | Succeeded  (** The call settled successfully. The header dot is green. *)
  | Failed  (** The call settled with a known failure. The header dot is red. *)
  | Warned
      (** The call settled without success but with a known, non-ambiguous
          outcome, such as interruption. The header dot is amber. *)
  | Ambiguous
      (** The callback may have run but no terminal outcome was recorded. The
          header dot is amber and remains semantically distinct from both
          {!Failed} and {!Succeeded}. *)

type detail
(** The type for clamped tool-owned presentation detail.

    A detail retains every normalized display row but renders at most a bounded
    window of them as plain rows, marking any elided rows with a faint count.
    Mutation diffs and task boards cannot be constructed as details because
    their owning facts render elsewhere. *)

type t
(** The type for a complete tool transcript block.

    Values have a nonblank display summary. All text contains valid UTF-8. The
    argument, facts, and preview contain no terminal controls or line breaks;
    the summary may contain line-feed boundaries but contains no other terminal
    control character. *)

(** {1:constructors Constructors} *)

val preview : take:[ `First | `Last ] -> max_rows:int -> string list -> detail
(** [preview ~take ~max_rows lines] is a one-row-per-item preview of [lines],
    clamped to at most [max_rows] rows. [`First] keeps the first [max_rows] rows
    and marks the hidden tail below; [`Last] keeps the last [max_rows] rows and
    marks the hidden head above.

    When [lines] has more than [max_rows] elements, a single faint overflow
    marker on the elided edge reports the number of undisplayed rows. The
    preview is static: it holds no viewport, acquires no focus, and shows no
    selection or scroll region, because a settled result scrolls with the whole
    transcript. A [max_rows] of [0] keeps only the marker, discarding no row.
    Invalid UTF-8 is repaired, and line breaks or terminal controls inside an
    element become inert inline text.

    Raises [Invalid_argument] if [max_rows < 0]. *)

val make :
  verb ->
  argument:string ->
  dot:dot ->
  summary:string ->
  ?facts:string list ->
  ?detail:detail ->
  unit ->
  t
(** [make verb ~argument ~dot ~summary ?facts ?detail ()] is a tool block.

    [summary] is concise result wording. It preserves line boundaries and wraps
    in the result body. If it contains no visible character, a stable status
    text is substituted: [running], [waiting for approval], [done], [failed],
    [warning], or [outcome unknown], according to [dot]. Thus a replayed or
    remote result is always settled and legible, never falsely loading.

    [argument] and each fact are normalized to one row. Empty facts are omitted.
    Invalid UTF-8 becomes [U+FFFD]; carriage-return/line-feed pairs are one line
    break in [summary], tabs become two spaces, and terminal controls become
    [U+FFFD]. [facts] defaults to [[]]; [detail] defaults to no preview. *)

(** {1:queries Queries} *)

val label : verb -> string
(** [label verb] is the non-empty display label for [verb]. Known verbs use
    title case. [Other name] uses [name] with its first ASCII letter capitalized
    after inline normalization; an empty or whitespace-only name falls back to
    ["Tool"]. *)

(** {1:rendering Rendering} *)

val header :
  palette:Theme.Palette.t -> verb -> argument:string -> dot:dot -> 'msg Mosaic.t
(** [header verb ~argument ~dot] is the one-row [⏺ Verb(argument)] header. The
    outcome mark and verb have higher shrink priority than [argument]. Mosaic
    truncates overflowing text to the space allocated by the containing layout.
*)

val view : palette:Theme.Palette.t -> t -> 'msg Mosaic.t
(** [view block] is [block]'s header, durable result body, and optional preview.
    The result preserves explicit line boundaries and word-wraps. Preview rows
    start at the established six-column inset, truncate as single rows, and are
    clamped to the detail's height cap with a faint overflow marker on the
    elided edge. Mosaic owns the block's width and per-row truncation. *)
