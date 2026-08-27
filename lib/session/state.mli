(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The pure replay projection.

    A state is the deterministic, total fold of an {!Event.t} list. It
    reconstructs the full display transcript, the derived model-visible
    transcript across compaction, accepted turns, the single open suspension,
    provider and tool claims, decisions, runtime permission grants, the goal
    projection, the task board, the next-turn queue, and delegation edges.

    {!apply} is the sole authority for cross-event invariants: id uniqueness,
    turn ownership, single suspension, single close, staged-claim ordering,
    decision validation, compaction boundary and idempotency, goal transition
    legality, and grants reconstruction. A mismatch is a hard located error,
    never a silent skip. State is inert data: no session id, no metadata, no
    clock, no IO, no callbacks.

    Two cross-event lifecycles carried in the fold are worth naming:
    - {b Plan-build admission.} A [Turn.Origin.Plan_build] turn is admitted only
      when the previous turn {e completed} with an approved plan and its
      {!Turn.Input.Plan_build} value is exactly equal to that approval. A
      resolved plan Approve retains the typed approval on the active turn; a
      [Completed] {!Event.Turn_finished} makes it admitting; the next turn's
      admission consumes it, and any other turn start clears it. Other terminal
      outcomes after approval are replay errors.
    - {b Fresh plan context.} A [`Fresh] plan-build input retains the full
      display transcript but advances the derived model-context boundary and
      seeds the new view with the exact approved plan and feedback. Compactions
      before that boundary are ignored; a later compaction that covers fresh
      input becomes the new model prefix.
    - {b Compaction closure.} {!Event.Compaction_installed} is the
      honest-success closer of the summary call's provider claim: it must name
      the open provider suspension and clears it.

    A {!Event.Message_appended} tool result that bypasses the open claim or
    decision (answering the call it holds) is rejected; every other tool result
    is an ordinary append. Live child scheduling is {b not} tracked here — an
    await-children boundary is [mentat.turn]'s, not a session replay guess. *)

(** {1:errors Errors} *)

module Error : sig
  (** State reconstruction errors. *)

  module Undo : sig
    (** Undo-boundary errors. Defined before {!Turn} so its reasons name the
        session {!Turn} module, which a later same-named error submodule would
        shadow. *)
    type t =
      | Active_turn of Turn.Id.t
          (** An [Armed] update arrived while a turn was active; undo requires
              an idle head. *)
      | Unknown_anchor of Turn.Id.t
          (** The armed anchor names a turn absent from the history prefix. *)
      | Anchor_not_user of Turn.Id.t
          (** The armed anchor is a turn that appended no user message (a
              [Continue] or a plan-build), so it cannot bound a suffix cut. *)
      | Anchor_before_context of Turn.Id.t
          (** The armed anchor's first message is before the model-context head
              (a compaction retained-tail start or a Fresh plan-build reset), so
              the suffix cut would reach into summarized or reset history. *)
  end

  module Turn : sig
    (** Turn state errors. *)
    type t =
      | Active of Turn.Id.t
          (** An event requiring no active turn ran while [turn] was active. *)
      | No_active  (** An event requiring an active turn ran while none was. *)
      | Duplicate of Turn.Id.t  (** A turn start reused an existing turn id. *)
      | Open_suspension of Turn.Id.t
          (** An event requiring no open suspension ran while [turn] had one. *)
      | Response_model_mismatch of {
          turn : Turn.Id.t;
          expected : Mentat_llm.Model.t;
          actual : Mentat_llm.Model.t;
        }  (** A response's model differed from the turn's contract model. *)
      | Interrupted of Turn.Id.t
          (** An inadmissible event ran after [turn] was interrupt-requested. *)
      | Unknown_queue_entry of Queue.Id.t
          (** A [Queued] origin named a queue entry that is not pending. *)
      | Not_plan_build of Turn.Id.t
          (** A [Plan_build] origin was admitted without a preceding approved
              plan. *)
      | Plan_build_mismatch of Turn.Id.t
          (** A [Plan_build] origin did not carry typed input exactly equal to
              the preceding approved plan. *)
      | Unexpected_plan_build_input of Turn.Id.t
          (** Typed plan-build input appeared under an origin other than
              [Plan_build]. *)
      | Unexpected_compaction_input of Turn.Id.t
          (** A [Compaction] origin carried input other than [Continue]. *)
      | Plan_approval_outcome of { turn : Turn.Id.t; outcome : Turn.Outcome.t }
          (** A turn resolved a plan approval but attempted to settle with an
              outcome other than [Completed]. *)
  end

  module Provider : sig
    (** Provider-claim state errors. *)
    type t =
      | Duplicate of Provider_request.Id.t
      | Unknown of Provider_request.Id.t
      | Not_pending of Provider_request.Id.t
  end

  module Tool_claim : sig
    (** Tool-claim state errors. *)
    type t =
      | Duplicate of Tool_claim.Id.t
      | Unknown of Tool_claim.Id.t
      | Not_pending of Tool_claim.Id.t
      | Missing_prepare of Tool_claim.Id.t
          (** A [Run] claim had no prepared [Prepare] sibling. *)
      | Stage_mismatch of Tool_claim.Id.t
          (** A settlement is not compatible with the claim's stage. *)
      | Illegal_sequence of Tool_claim.Id.t
          (** The claim breaks a call's stage discipline: a call's claims must
              be a single [Direct], or a [Prepare] followed by a [Run]. *)
      | Call_not_pending of { claim : Tool_claim.Id.t; call_id : string }
          (** A claim referenced no pending call equal to its retained source,
              including the provider signature and original input. *)
      | Result_mismatch of { claim : Tool_claim.Id.t; call_id : string }
          (** A settlement's lowered result did not answer the exact source call
              retained by the claim. *)
  end

  module Decision : sig
    (** Decision state errors. *)
    type t =
      | Duplicate of Decision.Id.t
      | Unknown of Decision.Id.t
      | Not_pending of Decision.Id.t
      | Resolve of Decision.Resolve_error.t
          (** The resolution failed {!Decision.resolve}'s validation. *)
      | Call_not_pending of { decision : Decision.Id.t; call_id : string }
          (** The blocked call is no longer pending in the transcript. *)
  end

  module Compaction : sig
    (** Compaction state errors. *)
    type t =
      | Bad_boundary of { summarized_upto : int; length : int }
          (** [summarized_upto] was out of range for the full transcript. *)
      | Duplicate_key of { reason : Compaction.Reason.t }
          (** A [(request_digest, reason)] key was reused. *)
      | Dropped_pending_call of { call_id : string }
          (** The compaction would summarize away the opener of a still-pending
              call, so a later result for it would orphan the model view. *)
  end

  module Goal : sig
    (** Goal state errors. *)
    type t =
      | Unfinished of Goal.Id.t
          (** A [Declare] ran while a goal was unfinished. *)
      | Unknown of Goal.Id.t
          (** An update targeted a goal that is not current. *)
      | Illegal_transition of { id : Goal.Id.t; from_status : string }
          (** The update was inadmissible from the current status. *)
  end

  module Delegation : sig
    (** Delegation state errors. *)
    type t =
      | Duplicate of Delegation.Id.t
          (** A delegation edge reused an existing delegation id. *)
      | Duplicate_child of Delegation.session_id
          (** A delegation edge reused an existing child session id. *)
  end

  module Queue : sig
    (** Next-turn queue state errors. *)
    type t =
      | Duplicate of Queue.Id.t
          (** An enqueue or replacement reused a queue entry id already pending.
          *)
  end

  type t =
    | Turn of Turn.t
    | Provider of Provider.t
    | Tool_claim of Tool_claim.t
    | Decision of Decision.t
    | Compaction of Compaction.t
    | Goal of Goal.t
    | Delegation of Delegation.t
    | Queue of Queue.t
    | Undo of Undo.t
    | Result_bypass of string
        (** A [Message_appended] tool result for this call id bypasses the open
            claim or decision that holds it; the proper closer is [Tool_settled]
            or [Decision_resolved]. *)
    | Transcript of Mentat_llm.Transcript.Error.t
        (** Applying the event would violate transcript grammar. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. It is suitable for
      display and logs, not stable machine-readable syntax. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. *)
end

module Replay_error : sig
  (** Located batch replay failures. *)

  type t
  (** The type for the first invalid event encountered during batch replay. *)

  val index : t -> int
  (** [index e] is the zero-based index of the invalid event in the batch. *)

  val event : t -> Event.t
  (** [event e] is the event that failed semantic validation. *)

  val cause : t -> Error.t
  (** [cause e] is the structured semantic failure. *)

  val shift : by:int -> t -> t
  (** [shift ~by e] adds non-negative [by] to {!index}.

      Raises [Invalid_argument] if [by] is negative. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic with the event index and cause.
  *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)
end

(** {1:states States} *)

type t
(** The type for a pure reconstructed session state.

    {!apply} maintains the invariants below; each is enforced in exactly one
    place, and a violation is a located {!Error.t}, never a silent skip:

    - {b Turns.} Turn ids are unique; at most one turn is active; a turn start
      appends its user input to the full transcript; an [Origin.Queued]
      admission requires and removes the named pending queue entry; a
      [Plan_build] admission consumes the exact preceding approval and a
      [`Fresh] approval advances the model-only context boundary; a terminal
      outcome requires a request-ready model transcript and no open suspension,
      and a turn carrying an approval may settle only [Completed].
    - {b Single suspension.} At most one of a provider claim, a tool claim, or a
      decision is open at a time. An opener installs it and its closer clears
      it; a second closer is a not-pending error.
    - {b Provider claims.} A settlement names the open provider claim; a
      responded settlement's model must equal the turn's contract model and
      appends the response; an interrupted settlement appends retained prose; a
      failed settlement — a known provider failure — appends nothing and closes
      the claim without forcing an interrupt, the turn then settling [Failed];
      an ambiguous settlement appends nothing and forces the turn to finish
      interrupted, admitting no further openers.
    - {b Tool claims.} Stage and outcome are compatible — [Prepared] only from a
      [Prepare] claim, a [Run] claim only after its [Prepare] sibling settled
      [Prepared]. A call's claim sequence is a single [Direct], or a [Prepare]
      then a [Run]; any other sequence is rejected. A returned settlement
      consumes the model call with a result lowered from the stored erased
      result; an ambiguous settlement consumes it with the synthetic error
      result ["tool result ambiguous after crash recovery"], a version-pinned
      spelling. Either way a mismatch against the claimed source call is
      rejected, including a changed provider signature or original input.
    - {b Decisions.} The answer tag, blocked call, choice bounds, and principal
      restriction are re-checked at resolution (see {!Decision.resolve}); the
      first valid resolution wins; a consuming resolution must answer the exact
      blocked call. A claim is admitted only against its exact pending source
      call; a decision is admitted only when its pending call id and name match,
      so neither closer can strand the suspension. A plan approval consumes its
      call with {!Plan.Approval.to_model_text} while retaining the typed
      approval separately as the only Build-admission authority.
    - {b Grants.} Only [Exact_for_conversation] permission allowances add
      runtime grants; conversation-family answers append visible rules. Grants
      are reconstructed even when the request came from a review rule, while
      policy evaluation retains rule precedence. Deny answers add no grant.
    - {b Compaction.} An install names the currently open provider suspension —
      the summary call's claim — and clears it; [summarized_upto] is within the
      full transcript; the derived model view is a valid transcript that keeps
      the opener of every still-pending call, so no later result orphans it; a
      duplicate [(request_digest, reason)] key is rejected.
    - {b Goals.} A declare requires no unfinished goal; every transition must be
      admissible from the current status; accounting is derived, never stored,
      and windowed at the goal's own declaration so a later goal never inherits
      an earlier goal's continuation spend.
    - {b Delegations.} A delegation edge's source turn is the active turn; the
      edge is immutable; its delegation id and child session id are each unique
      within the live ownership projection. A branch reset clears that
      projection without deleting historical transcript or facts.
    - {b Queue.} The pending queue never holds two entries with the same id. A
      failed turn clears it; an interrupted turn preserves it so the scheduler
      can admit the user's queued correction at the next idle boundary.
    - {b Interrupt.} Once the active turn is interrupt-forced — an interrupt
      request or an ambiguous provider settlement — only settlements, an
      interrupted terminal outcome, a repeated (idempotent) interrupt request,
      and non-bypassing reconciliation tool results are admissible; every opener
      is rejected. One reconciliation result is admitted despite bypassing: a
      result answering the call an open decision holds abandons that parked ask
      — it is appended and clears the suspension, but writes no
      [Decision_resolved] fact, so the decision is terminal-by-interrupt and any
      later resolution is [Not_pending]. Absent the interrupt, that same result
      is still a [Result_bypass].

    State is inert data: no session id, no metadata, no clock, no IO, no
    callbacks. Every derived view — the model transcript, grants, goal
    accounting — is projected on demand and never stored. *)

val empty : t
(** [empty] is the state before any event has been applied. *)

val apply : Event.t -> t -> (t, Error.t) result
(** [apply event t] is [t] after applying [event], or [Error e] if [event] would
    violate a state invariant. The input state is immutable and reusable. *)

val apply_all : Event.t list -> t -> (t, Replay_error.t) result
(** [apply_all events t] applies [events] in list order, returning the first
    error with its zero-based index relative to [events]. *)

val of_events : Event.t list -> (t, Replay_error.t) result
(** [of_events events] is [apply_all events empty]. *)

(** {1:transcript Transcripts} *)

val full_transcript : t -> Mentat_llm.Transcript.t
(** [full_transcript t] is [t]'s complete display history — every message,
    across compaction boundaries. *)

val model_transcript : t -> Mentat_llm.Transcript.t
(** [model_transcript t] is the model view the provider sees: the latest
    applicable compaction's summary followed by the retained tail, the full
    transcript when no boundary exists, or the tail beginning at the latest
    [`Fresh] plan-build input. A compaction predating that Fresh boundary is not
    applicable; a later compaction covering fresh input supersedes it. The view
    is always a valid transcript; replay keeps every pending call's opener in
    it, so it is request-ready exactly when no call is pending. *)

val final_text : t -> string option
(** [final_text t] is the last model-authored prose anywhere in the full
    transcript, recomputed from it on each call — the session-wide view. Text
    blocks are joined with newlines and trimmed. Contrast {!turn_final_text},
    which reads one turn's own record.

    Owed consumer: the deferred [sessions]/[session] summary queries (the client
    driver's deferred surface). *)

val replay_usage : t -> (Mentat_llm.Usage.t * Mentat_llm.Message.t list) option
(** [replay_usage t] is the most recent response usage together with the model
    messages appended after it — the suffix the usage does not yet cover.
    Cleared by compaction. *)

val latest_compaction : t -> Compaction.t option
(** [latest_compaction t] is the most recently installed compaction, if any. *)

(** {1:undo Undo boundary} *)

type undo = { anchor : Turn.Id.t; revert : string option }
(** The type for the folded undo boundary: the armed anchor turn and the stable
    string id of the ledger revert that took the working tree back, or [None]
    for that id when the crossed turns recorded no edits. *)

val undo : t -> undo option
(** [undo t] is the armed undo boundary, or [None] when none is armed. While
    armed, {!model_transcript} excludes every message from the anchor turn's
    first message onward — the mirror of a compaction's prefix cut. A commit
    truncates the boundary events out of the journal, so a committed session
    folds to [None]. *)

(** {1:turns Turns} *)

val turns : t -> Turn.t list
(** [turns t] is [t]'s accepted turns in start order. *)

val turn : Turn.Id.t -> t -> Turn.t option
(** [turn id t] is the turn identified by [id], if any. *)

val turn_first_message_index : Turn.Id.t -> t -> int option
(** [turn_first_message_index id t] is the absolute index in the full transcript
    of turn [id]'s appended user input, or [None] when [id] is unknown or is a
    non-user turn (a [Continue] or a plan-build) that appended none. This is the
    first message an undo boundary anchored at [id] excludes. *)

val can_undo_anchor : Turn.Id.t -> t -> bool
(** [can_undo_anchor id t] is [true] iff an undo boundary may arm at turn [id]:
    it is a user turn whose first message is at or after the model-context head
    (a compaction retained-tail start or a Fresh plan-build reset). The undo
    driver checks it before reverting files so an arm that the fold would reject
    ({!Error.Undo.Anchor_before_context}) never leaves the working tree reverted
    with no boundary recorded. *)

val active_turn : t -> Turn.t option
(** [active_turn t] is the active unfinished turn, if any. *)

val active_turn_id : t -> Turn.Id.t option
(** [active_turn_id t] is the active unfinished turn's id, if any. *)

(** {2 Workspace observations in the model view}

    A {!Event.Workspace_notice} is one durable fact with two projections:
    the human transcript's notice row, and an {e ordinary user-role entry}
    in the model view — a [Workspace notices:] header then each pending
    notice's rendered line and body, one entry per pending batch. The entry
    joins the durable transcript at the next request-ready seam (a user
    message cannot sit between a tool call and its result) and its bytes
    and position freeze the moment a request shows them, so the request
    prefix never moves and replay reconstructs exactly what the model was
    shown, where it was shown it. A still-open batch rides the model view's
    tail until its freezing [Provider_requested]; a batch a dying turn
    recorded stays pending for the next request by construction. The
    structured-output whiff reminder follows the same law: it is appended
    as an ordinary entry directly after a schema turn's response that
    carried no tool call, derived from the settled event. *)

val turn_outcome : Turn.Id.t -> t -> Turn.Outcome.t option
(** [turn_outcome id t] is the terminal outcome of turn [id], if finished. *)

val turn_response_count : Turn.Id.t -> t -> int option
(** [turn_response_count id t] is the number of provider responses for turn
    [id], if known. *)

val turn_final_text : Turn.Id.t -> t -> string option
(** [turn_final_text id t] is the last non-empty assistant text recorded for
    turn [id] specifically, held in that turn's record rather than scanned from
    the transcript. Contrast {!final_text}, the session-wide latest prose: the
    two coincide only when [id] is the turn that produced that prose. *)

val latest_model : t -> Mentat_llm.Model.t option
(** [latest_model t] is the active turn's model, or the most recently started
    turn's model when none is active.

    Owed consumer: the deferred [sessions]/[session] summary queries (the client
    driver's deferred surface). *)

(** {1:suspension Suspension} *)

(** The type for the active turn's single open suspension. *)
type suspension =
  | Provider of Provider_request.Started.t
      (** The turn is waiting for a provider response. *)
  | Tool of Tool_claim.Started.t
      (** The turn is waiting for an executable tool result. *)
  | Decision of Decision.Requested.t
      (** The turn is waiting for a decision answer. *)

val suspension : t -> suspension option
(** [suspension t] is the active turn's single open suspension, if any. Because
    at most one is ever open, this is the one honest read; live child scheduling
    ([mentat.turn]'s await-children boundary) is not a session projection. *)

val interrupt_requested : t -> bool
(** [interrupt_requested t] is [true] iff the active turn has a recorded
    interrupt request. *)

val approved_plan : t -> Plan.Approval.t option
(** [approved_plan t] is the exact resolved plan approval that has settled and
    not yet been consumed, if any — the plan-build admission value. A
    [Turn.Origin.Plan_build] turn is admissible only when its
    {!Turn.Input.Plan_build} value is equal to this approval. The next accepted
    turn start consumes it. *)

(** {1:tool_claims Tool claims} *)

val tool_claims : t -> (Tool_claim.Started.t * Tool_claim.Settled.t option) list
(** [tool_claims t] is every tool claim and its optional settlement, in start
    order (history and audit). *)

val decision :
  Decision.Id.t ->
  t ->
  (Decision.Requested.t * Decision.Resolved.t option) option
(** [decision id t] is the decision identified by [id] and its optional
    resolution, if any. *)

(** {1:permissions Permissions} *)

val grants : t -> Mentat_permission.Policy.Grants.t
(** [grants t] is the runtime grants reconstructed from decision resolutions.
    Only [Exact_for_conversation] permission allowances add grants; a
    conversation grant recorded through a review-rule prompt is retained, but
    does not override an explicit matching policy rule. *)

val permission_rules : t -> Mentat_permission.Policy.Rule.t list
(** [permission_rules t] is the visible conversation-lifetime family rules
    reconstructed from decision resolutions, in installation order. *)

(** {1:goal Goal} *)

val goal : t -> Goal.t option
(** [goal t] is the current goal projection with derived accounting, if a goal
    is declared. *)

val goal_objective_edit_pending : t -> bool
(** [goal_objective_edit_pending t] is [true] iff the current goal is
    {!Goal.Status.Active} and its objective was edited more recently than the
    last {!Turn.Origin.Goal_continuation} turn — that is, no goal-continuation
    turn has yet re-entered on the edited objective. Derived from the goal's
    edit epoch and the turn order, never stored; the next goal-continuation turn
    consumes it. A fresh {!Goal.Update.Declare} clears the epoch. *)

(** {1:tasks Tasks} *)

val tasks : t -> Task.Board.t
(** [tasks t] is the current task board, empty until first replaced. *)

(** {1:queue Queue} *)

val pending_queue : t -> Queue.Entry.t list
(** [pending_queue t] is the next-turn queue entries in order. *)

val enqueue_recorded : Queue.Id.t -> t -> bool
(** [enqueue_recorded id t] is [true] iff some [Enqueued] update named [id]
    anywhere in the session's history — a durable delivery receipt that outlives
    the entry being consumed or [Cleared]. Only an explicit [Enqueued] records
    the receipt: an id introduced solely by a [Replaced] batch is not recorded.
*)

(** {1:delegations Delegations} *)

val delegations : t -> Delegation.t list
(** [delegations t] is the live delegation ownership set in record order. A
    branch's [Delegations_detached] reset clears inherited edges; later edges
    belong to the branch. *)
