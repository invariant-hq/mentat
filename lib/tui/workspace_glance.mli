(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Ambient status rows for the wide-terminal activity pane.

    Four independent groups: the session goal, the workspace state — the git
    worktree diff, this session's tool-mutation diff, and the dune build verdict
    — the current model-context usage, and the session's live background
    processes. Each renders status lines under its own section header; the goal
    objective is the only default-styled text, and the diffs' additions and
    deletions, a failing build, and a failed background process carry the only
    colour. It never reads the filesystem or invents a value. *)

val worktree :
  palette:Theme.Palette.t ->
  worktree:Textdiff.stats option ->
  'msg Mosaic.t list
(** [worktree ~worktree] is the git worktree-diff row (against the review base),
    prefixed [worktree] to tell it apart from the session diff. The single row —
    the file count with the summed additions and deletions — is emitted only
    when the stats cover at least one file; absent or empty yields [[]]. *)

val changed :
  palette:Theme.Palette.t -> changed:Textdiff.stats option -> 'msg Mosaic.t list
(** [changed ~changed] is this session's tool-mutation diff row, prefixed
    [session]. It has the same shape and emptiness rule as {!worktree}; the
    distinct prefix is what disambiguates the two same-shaped rows. *)

val tooling :
  palette:Theme.Palette.t ->
  tooling:Mentat_workspace.Health.t ->
  'msg Mosaic.t list
(** [tooling ~tooling] is the dune watch row. A build verdict exists only
    inside a settled phase; the status itself is a fact about the watch and
    renders in every state but [Off Disabled] (nothing was attempted, no row).
    Muted status words: [dune · starting], [dune · building],
    [dune · off · no watch] and its siblings; warnings:
    [dune · hung · restarting], [dune · unresponsive]. A settled verdict is
    [dune · clean] muted, [dune · n errors] in the error style, or
    [dune · n warnings] warned when a failed build printed warnings alone,
    with a [· n lint] suffix when the lint lane holds findings. A foreign
    watch's rows carry a muted [theirs ·] prefix. *)

val goal :
  palette:Theme.Palette.t ->
  labelled:bool ->
  objective:string option ->
  'msg Mosaic.t list
(** [goal ~labelled ~objective] is the session-goal objective row: the objective
    in the default text style, word-wrapped by Mosaic. [labelled] prefixes a
    muted [goal] tag with the shared separator — the pane's section header
    already names the group, so the tag is for the narrow strip, which has no
    headers. [None] yields [[]], so the enclosing section is omitted. Rows carry
    the pane's two-column content inset; the caller supplies no width. *)

val context :
  palette:Theme.Palette.t ->
  context:(int * int option) option ->
  spent:float option ->
  'msg Mosaic.t list
(** [context ~context ~spent] is the model-context rows, in display order.

    [context] is [Some (used, percent)] where [used] is the current context
    occupancy in tokens — the latest turn's whole-response usage, not cumulative
    spend — and [percent] is its share of the active model's context window when
    that window is known. It yields an exact ["N tokens"] row (digit-grouped)
    and, when [percent] is [Some], a ["p% used"] row. It is emitted only when
    [used] is positive.

    [spent] is the session's cumulative monetary spend under the model's
    pricing, when the catalog carries a rate; its ["$d.dd spent"] row is omitted
    entirely when [spent] is [None] rather than shown as a fabricated zero.

    [context] absent or non-positive yields [[]], so the enclosing section is
    omitted. Rows carry the pane's two-column content inset; the caller supplies
    no width. *)

val running :
  palette:Theme.Palette.t ->
  running:Mentat_protocol.Process.View.t list ->
  'msg Mosaic.t list
(** [running ~running] is one status row per live background process, in the
    given order: the [bg_N] handle, the command (the sole variable-width field,
    truncated by Mosaic to the column), the liveness keyword, and a compact age.
    A nonzero exit or a killing signal renders the keyword in {!Theme.error}; a
    clean exit, a running child, and a terminated child stay muted. An empty
    list yields [[]], so the enclosing section is omitted. Rows carry the pane's
    two-column content inset; the caller supplies no width. *)
