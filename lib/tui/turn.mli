(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure presentation state for one in-flight turn.

    This module is the TUI side of the render seam. Committed
    {!Mentat_protocol.Fact.t} values are the only source of settled transcript
    blocks. Droppable {!Mentat_protocol.Progress.t} values may animate the live
    tail, but never append to the transcript. In particular, assistant and
    reasoning deltas are discarded when their authoritative durable assistant
    fact arrives.

    The fold owns only per-turn presentation state: optimistic submit echo,
    streaming model text, open tool rows, the pending decision which drives
    the waiting line, and the live task-board mirror.
    Queue, delegation, and decision-dialog presentation remain dedicated
    surface folds over their exact fact payloads; this module neither mirrors
    nor re-encodes them.

    The reducer reads no clock. Callers pass [~now], in seconds from one finite
    monotonic clock, so a scripted fact/progress stream is deterministic. *)

(** {1:errors Transition errors} *)

module Error : sig
  (** Structured failures from an invalid committed-fact sequence.

      A decoded feed is runtime data, so ordering and correlation failures are
      recoverable values rather than exceptions. IDs remain owner types; no
      parallel string identity is introduced. *)
  type t =
    | No_active_turn
        (** A turn-scoped fact arrived before its {!Fact.Turn_started}. *)
    | Turn_already_active of {
        active : Mentat_session.Turn.Id.t;
        incoming : Mentat_session.Turn.Id.t;
      }  (** A second turn started before the first settled. *)
    | Pending_turn_mismatch of {
        pending : Mentat_session.Turn.Id.t;
        incoming : Mentat_session.Turn.Id.t;
      }  (** The durable start did not match the locally submitted turn. *)
    | Turn_mismatch of {
        active : Mentat_session.Turn.Id.t;
        incoming : Mentat_session.Turn.Id.t;
      }  (** A correlated fact named a turn other than the active one. *)
    | Duplicate_tool_claim of Mentat_session.Tool_claim.Id.t
    | Unknown_tool_claim of Mentat_session.Tool_claim.Id.t
    | Wrong_tool_stage of {
        claim : Mentat_session.Tool_claim.Id.t;
        expected : Mentat_tool.Stage.t;
        actual : Mentat_tool.Stage.t;
      }
        (** A prepared settlement named a claim that was not in Prepare stage.
        *)
    | Decision_already_pending of {
        pending : Mentat_session.Decision.Id.t;
        incoming : Mentat_session.Decision.Id.t;
      }
    | Unknown_decision of {
        pending : Mentat_session.Decision.Id.t option;
        incoming : Mentat_session.Decision.Id.t;
      }
    | Open_state_at_settlement of {
        turn : Mentat_session.Turn.Id.t;
        tool_claims : int;
        decision_pending : bool;
      }
        (** The terminal turn fact arrived while a tool or decision still
            appeared open. A valid session projection cannot produce this. *)
    | Assistant_message
        (** [Fact.Turn_message] illegally carried an assistant message. The
            durable assistant lane is [Fact.Turn_assistant]. *)

  val message : t -> string
  (** [message error] is a human-readable diagnostic. Callers must branch on
      [error], not parse this text. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [message error]. *)
end

(** {1:state State} *)

type t
(** The abstract, ephemeral projection for the current turn. *)

val idle : t
(** [idle] has no pending or active turn and no live tail. *)

val in_flight : t -> bool
(** [in_flight t] is [true] after local submission and remains true through the
    matching durable turn settlement. *)

val active_turn : t -> Mentat_session.Turn.t option
(** [active_turn t] is the exact sealed turn from the latest durable
    [Fact.Turn_started], or [None] while idle or awaiting that fact. *)

val pending_decision : t -> Mentat_session.Decision.Requested.t option
(** [pending_decision t] is the exact unresolved decision request. It is the
    same value a dialog consumes; this accessor does not define a second
    decision shape. *)

val todo_board : t -> Mentat_session.Task.Board.t option
(** [todo_board t] is the latest whole-board fact in the current turn. Each such
    fact also produces a settled {!Transcript.board} block. The accessor is only
    the status-strip mirror and clears when the turn settles. *)

(** {1:local-actions Local actions} *)

val request :
  now:float -> turn:Mentat_session.Turn.Id.t -> prompt:string -> t -> t
(** [request ~now ~turn ~prompt t] records a locally accepted submission before
    its durable start reaches the feed. The live tail optimistically displays
    [prompt] with {!Transcript.user_block}; the matching start replaces that
    echo with its authoritative accepted input without a visual jump.

    Raises [Invalid_argument] if [now] is not finite, [prompt] has no visible
    grapheme, or [t] is already in flight. These are local shell-construction
    errors, not runtime feed failures. *)

val interrupting : t -> t
(** [interrupting t] marks the in-flight turn as cooperatively interrupting. RFC
    0016 deliberately has no forced-interrupt rung.

    Raises [Invalid_argument] if [t] is not in flight. Reapplying it is
    idempotent. *)

(** {1:fold Fact and progress fold} *)

val fact :
  now:float ->
  show_reasoning:bool ->
  Mentat_protocol.Fact.t ->
  t ->
  (t * Transcript.block list, Error.t) result
(** [fact ~now ~show_reasoning fact t] folds one committed fact and returns any
    settled transcript blocks in display order.

    A durable assistant fact clears both streaming buffers before returning its
    reasoning and assistant blocks. [show_reasoning = false] prevents the
    reasoning block from entering the transcript at all; it is not appended and
    hidden later. Tool settlements resolve the exact started claim and use
    {!Tool_distill}; task-board facts append their own board block. A compaction
    is a session-scoped boundary and appends its seam in both running and idle
    turn phases, so manual compaction never fabricates a missing-turn failure.
    Mutation evidence is accumulated into exactly one authoritative turn
    trailer: the latest run-cumulative exact totals, the union of observed
    paths, and every incomplete or unavailable revert-safety answer remain
    visible. The original fact still owns the exact change rows a caller retains
    for [Mentat_client.change_diff]; this reducer neither copies nor hides those
    rows. Ambient progress never contributes a block here.

    [now] must be finite. An invalid committed-fact order returns a structured
    [Error]; it never guesses a missing claim, decision, or turn. *)

val progress : now:float -> Mentat_protocol.Progress.t -> t -> t
(** [progress ~now pulse t] folds one droppable pulse. Model deltas and usage
    update only the matching active turn; compaction pulses drive only its live
    verb; notices update the ambient tail by their owner key. A pulse for an
    inactive or different turn is stale and is ignored.

    [Fact.Turn_assistant], [Fact.Turn_assistant_interrupted],
    [Fact.Turn_provider_failed], and [Fact.Compaction] discard the progress they
    supersede. [Fact.Turn_settled] discards every remaining pulse. No call to
    [progress] can create a settled transcript block.

    Raises [Invalid_argument] if [now] is not finite. *)

(** {1:views Views} *)

val tail :
  palette:Theme.Palette.t ->
  now:float ->
  show_reasoning:bool ->
  expanded:bool ->
  t ->
  'msg Mosaic.t option
(** [tail ~now ~show_reasoning ~expanded t] is the live material below the
    settled transcript: optimistic prompt, reasoning ticker, streaming assistant
    prose, running or prepared tools, and ambient workspace notices. Top-level
    parts have exactly one blank row between them. [None] means there is no live
    material; the caller therefore adds no transcript/tail gap.

    Collapsed reasoning is a three-visual-line rolling window. [expanded]
    reveals its complete wrapped body. Running tool rows include elapsed
    time; prepared rows remain visibly awaiting approval. Workspace notices
    render once, as their durable transcript blocks — no live-tail glance
    duplicates them.

    Mosaic owns allocation, wrapping, and overflow. The collapsed reasoning body
    is a bottom-sticky three-row scroll viewport; expansion replaces it with the
    complete intrinsically wrapped body. Raises [Invalid_argument] if [now] is
    not finite. *)

val working_line :
  palette:Theme.Palette.t ->
  now:float ->
  spinner:int ->
  t ->
  'msg Mosaic.t option
(** [working_line ~now ~spinner t] is the one-row live status, or [None] when no
    turn is in flight. Its priority is interrupting, waiting for the exact
    pending decision, compacting, then thinking/working. The ordinary line shows
    elapsed time and the current turn's live-plus-durable output token spend. No
    unavailable download, forced-interrupt, or subagent-runtime state is
    fabricated.

    Mosaic truncates the lower-priority detail and label before the leading
    state glyph, which remains visible whenever the row receives a column.
    Raises [Invalid_argument] if [now] is not finite. *)

val compacting_line :
  palette:Theme.Palette.t ->
  now:float ->
  spinner:int ->
  started:float ->
  'msg Mosaic.t
(** [compacting_line ~now ~spinner ~started] is the one-row live status shown
    while a manual compaction issued from the composer is in flight. A manual
    compaction runs as an [Origin.Compaction] turn that is transparent on the
    feed, so no turn projection is active and {!working_line} yields [None]; the
    app drives this row from the outstanding compaction request instead. It
    shows the spinner and elapsed time. A manual compaction is not interruptible
    from here, so the row advertises no interrupt affordance. Raises
    [Invalid_argument] if [now] is not finite. *)
