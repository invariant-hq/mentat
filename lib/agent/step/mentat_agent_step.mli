(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The pure step — one checked transition per drive.

    This private unit is the effect-free core of [mentat.agent]. It maps
    replayed session state plus resolved configuration to one checked
    transition: an event suffix to commit paired with the single action to take,
    returned as data ({!Step.t}). The driver persists {!Step.events} as one
    store append before taking {!Step.action}; the ordering law holds
    structurally because every claim an action acts on rides the suffix.

    The firewall: every event the step emits goes through the session's checked
    constructors and is validated by [State.apply] before the step returns — the
    step never hand-builds an event beyond what the session API mints, and the
    driver appends nothing beyond the two driver-owned facts (interrupt
    request, queue), each minted by the same checked constructors and
    validated by the same replay. Journal verbs, permission review, decision
    routing, admission, and compaction policy are all evaluated here; the driver
    only ever sees the action sum.

    Determinism: claim and decision identifiers derive inside the session
    library's constructors from stable inputs the step supplies, and the child
    session identifiers the step itself mints are digests of stable inputs (the
    source turn and call); the step mints no entropy, reads no clock, and
    performs no IO — the library's dependency set contains no effect library.
*)

module Catalog = Catalog
(** The one dispatch surface. *)

module Env = Env
(** Immutable per-drive inputs. *)

(** {1:errors Errors} *)

module Error : sig
  (** Structured step errors, composed from owner categories. These fold into
      [Agent.Error] at the facade; there is no second generic taxonomy and no
      free-string branch. Model-visible failures — unknown names, decode
      failures, refused spawns, resume drift — are never errors: they lower into
      failed tool results batched as micro-steps. *)

  type t =
    | No_active_turn
        (** The operation requires an active unfinished turn. Only {!recover} is
            total over idle heads. *)
    | No_pending_wait
        (** {!deliver_child} found no pending [wait] call to answer. *)
    | Call_not_pending of { call_id : string; name : string }
        (** A feed-back referenced a model tool call that is no longer pending
            in the transcript. *)
    | Session of Mentat_session.Error.t
        (** A checked append was refused — a step or driver bug, surfaced loudly
            with the session's own vocabulary. *)
    | Request of Mentat_llm.Request.Error.t
        (** The model transcript could not become a model request. *)
    | Decision of Mentat_session.Decision.Resolve_error.t
        (** A decision answer failed [Decision.resolve]'s validation — this is
            the structured unattended-may-only-deny surface, never an exception.
        *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. *)
end

(** {1:steps Steps} *)

module Step : sig
  type t
  (** The type for one checked transition. Opaque; constructed only inside this
      unit, so no driver can hold an action without holding the commit that
      claims it. The driver persists {!events} as ONE store append before taking
      {!action}, so a permission denial and its paired synthetic tool result —
      and a task-board replacement and its result — commit atomically or not at
      all; neither can half-happen. *)

  val events : t -> Mentat_session.Event.t list
  (** [events t] is the exact event suffix to commit, in application order. *)

  (** The two claimed external effect kinds. The staged tool lifecycle folds
      into one {!Effect.Tool} arm via the stage; compaction folds into
      {!Effect.Model} via the purpose. A submodule because [effect] is a keyword
      on this toolchain — a bare [type effect] does not compile. *)
  module Effect : sig
    type t =
      | Model of {
          claim : Mentat_session.Provider_request.Started.t;
              (** Committed by the same {!events} — persisted before the call is
                  issued; carried so the feed-back targets the settlement
                  without re-derivation. *)
          request : Mentat_llm.Request.t;
              (** Derived from transcript and contract, never stored. *)
          purpose :
            [ `Turn
            | `Compaction of Mentat_session.Compaction.Reason.t * int ];
              (** Why the call is issued. The driver calls the provider the same
                  way for both; the purpose routes the feed-back — a [`Turn]
                  response feeds {!accept_response}, a [`Compaction] response
                  feeds {!install_summary}. *)
        }
      | Tool of {
          claim : Mentat_session.Tool_claim.Started.t;
              (** Stage [Direct], [Prepare], or [Run]; committed by the same
                  step, before the callback. *)
          call : Mentat_tool.Call.t;
              (** The decoded, permission-cleared boundary; [Call.run] yields
                  [Finished] or [Prepared]. *)
        }
  end

  module Reservation : sig
    type t
    (** A pending spawn's decoded identity and inputs: the delegation payload
        (which carries the deterministic child id [H(source_turn, source_call)])
        plus the spawn call it answers. Private scheduler coordination, never a
        durable or protocol value. *)

    val delegation : t -> Mentat_session.Delegation.Id.t
    (** [delegation t] is the pending edge's identity — the key the scheduler's
        per-edge permit reserves and releases under. *)

    module Refusal : sig
      (** Why the scheduler refused the permit. Step-owned: the step lowers it
          into the model-visible failed spawn result; nothing durable carries
          this type. Depth is refused before any reservation, so it is not an
          arm here. *)
      type t = Capacity of { limit : int }
    end
  end

  module Children_wait : sig
    type t = private {
      turn : Mentat_session.Turn.Id.t;
      wait_call : string;
          (** The model tool-call id the answer must pair with. *)
      children : Mentat_session.Delegation.Id.t list;
          (** The named children, exactly as the wait call's input names them.
          *)
    }
    (** The children park, derived from dispatch knowledge — the pending wait
        call's own decoded input — never from a journal heuristic. *)
  end

  module Mail : sig
    (** Whom a recorded message addresses, resolved from the recording
        session's own facts. *)
    type target =
      | Child of Mentat_session.Delegation.Id.t
          (** One of the session's own recorded delegation edges. *)
      | Parent
          (** The session's recorded delegation parent — its
              [delegated_from] lineage. *)

    type t = private {
      turn : Mentat_session.Turn.Id.t;
          (** The turn whose verb call recorded the message. *)
      call_id : string;  (** The recording model tool-call id. *)
      kind : [ `Context | `Follow_up ];
          (** [`Context] is [send] (and the retired [send_message]
              spelling); [`Follow_up] is [follow_up], always to a
              {!Child}. *)
      target : target;  (** Whom the message addresses. *)
      message : string;  (** The message text, non-empty. *)
    }
    (** A recorded model-origin message, decoded from the verb call whose
        successful receipt is durable in the recording transcript — the
        delivery carrier. [(turn, call_id)] is the stable key delivery
        derives its idempotency id from. *)
  end

  (** The type for the single action after a commit. *)
  type action =
    | Perform of Effect.t
        (** At most one claimed external effect; the claim is in {!events}. *)
    | Reserve_child of Reservation.t
        (** Ask the scheduler for a tree-capacity permit; the answer feeds
            {!reserve_result}. No durable event yet — the delegation edge
            commits only after the permit is granted. *)
    | Await_decision of Mentat_session.Decision.Requested.t
        (** A typed decision is pending; a client command resolves it. The
            driver persists, publishes, and parks — no effect. *)
    | Await_children of Children_wait.t
        (** The active turn called [wait] on named children that have not all
            settled. The scheduler — never a human — resolves it. *)
    | Settled of {
        turn : Mentat_session.Turn.Id.t;
        outcome : Mentat_session.Turn.Outcome.t;
      }
        (** The turn reached a terminal outcome; {!events} carries the
            [Turn_finished] fact, so settling is itself a commit. Terminal: the
            driver runs admission next. *)
    | Idle
        (** The session is quiescent with no active turn — {!recover} over an
            idle or empty head. The driver runs admission next. This arm is an
            implementation completion for recovery's totality: a recovered head
            with no active turn has no other answer. *)

  val action : t -> action
  (** [action t] is the single action the driver takes after persisting
      {!events}. *)
end

(** {1:admission Admission policy} *)

module Admission : sig
  (** What the driver admits after a settle. *)
  type t =
    | Queued of Mentat_session.Queue.Entry.t
        (** Admit this queued entry; admission consumes it. *)
    | Step_limit_wind_down of Mentat_session.Turn.Input.t
        (** The last turn settled {!Mentat_session.Turn.Outcome.Step_limit}. The
            driver admits one wrap-up turn with [input] under the
            {!Mentat_session.Turn.Origin.Step_limit_wind_down} origin, which is
            what keeps a wind-down that spends its own budget from admitting
            another. *)
    | Idle  (** Nothing to admit; park. *)
end

val next_admission : Mentat_session.State.t -> Admission.t
(** [next_admission state] is what the driver admits at an idle boundary: Queued
    beats a step-limit wind-down beats Idle. The driver consumes a pending exact
    plan approval as a [Plan_build] Build turn before consulting this, so the
    effective admission order is Plan_build, then Queued, then a step-limit
    wind-down, then Idle. Pure; the driver enacts it by calling {!start} with
    the origin the arm names and a host-minted id. *)

(** {1:entry Entry points} *)

val start :
  ?notices:Mentat_session.Notice.t list ->
  Env.t ->
  Mentat_session.Contract.t ->
  id:Mentat_session.Turn.Id.t ->
  input:Mentat_session.Turn.Input.t ->
  origin:Mentat_session.Turn.Origin.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [start ?notices env contract ~id ~input ~origin session] seals [contract]
    into a turn-started fact and self-drives to the first action. [id] is
    client-minted for a [User] turn and host-minted by the driver for other
    admissions; the step mints nothing. An [Origin.Queued] admission consumes
    its queue entry in the same commit. An [Origin.Plan_build] admission
    requires an [Input.Plan_build] exactly equal to the pending typed approval;
    replay rejects a missing or altered value before {!Step.Effect.Model} can be
    produced.

    [notices] (default [[]]) are the workspace observations the turn starts
    with. Each is recorded as a durable {!Mentat_session.Event.Workspace_notice}
    against the new turn, so replay reconstructs the turn's context, and the
    turn's continuation requests carry them — never a later turn's. The driver
    records further observations against the turn as it runs; every continuation
    request states all of the turn's observations in the order they arrived. A
    compaction request carries the summarizer prelude alone — never the acting
    agent's — and states none. *)

(** The type for the manual-compaction admission decision. *)
type compaction_start =
  | Nothing_to_compact
      (** No compaction was needed: the model view is empty or already a prior
          summary with no new transcript. The driver reports [Skipped]. *)
  | Compact_step of Step.t
      (** The compaction-only turn's first step: its {!Step.events} carry the
          [Origin.Compaction] [Turn_started] and the summary provider claim, and
          its {!Step.action} performs the summary [`Compaction] model effect. *)

val compact :
  Env.t ->
  Mentat_session.Contract.t ->
  id:Mentat_session.Turn.Id.t ->
  Mentat_session.t ->
  (compaction_start, Error.t) result
(** [compact env contract ~id session] is the manual boundary mark: it admits a
    compaction-only turn (host-minted [id], [Origin.Compaction],
    [Input.Continue]) whose single body is one billable summary provider claim
    over the model view up to the summary boundary — the most recent turns that
    fit the tail budget stay verbatim behind the summary rather than in it (see
    {!install_summary}). Its response feeds {!install_summary}, which —
    seeing the [Compaction] origin — installs the fact and settles the turn
    [Completed] in one suffix; a failed or ambiguous summary settles the turn
    without a fact, exactly like any provider claim. The summary reason is
    {!Mentat_session.Compaction.Reason.User_requested}.

    A compaction turn is transparent to admission ({!next_admission} skips it)
    and projects only the [Compaction] fact it installs, never its own
    turn-boundary facts. This keeps the manual and automatic paths one path:
    nothing about the automatic prelude changes.

    Requires an idle head. Returns {!Nothing_to_compact} when the model view is
    empty or already fully summarized; an operational build failure is an
    [Error]. *)

val recover : Env.t -> Mentat_session.t -> Step.t
(** [recover env session] is TOTAL over recovered states and the only crash-time
    minter of [Ambiguous] (the live mints are the explicit ambiguous feed-backs
    below). For a head showing in-flight effects from a dead process: settle the
    open provider claim [Ambiguous] and finish the turn [Interrupted] (never
    re-issued), or settle the open tool claim [Ambiguous] and continue the turn
    — even when an interrupt request is recorded, recovery stays [Ambiguous]. A
    pending decision survives; a staged [Prepared] settlement survives with its
    run-stage decision answerable (recovery never re-runs preparation); a
    delegation edge with an absent child is left for the scheduler's idempotent
    re-drive. A quiescent active turn advances directly (the empty-batch drive);
    an idle or empty head is {!Step.Idle}. If the post-settlement advance cannot
    continue, the turn is finished [Failed] rather than left active.

    Totality rests on the session's replay invariants (at most one open
    suspension, every suspension with a determined settlement); a violated
    invariant raises [Invalid_argument] rather than returning. *)

(** {1:feedbacks Typed feed-backs}

    Each appends the settlement and self-drives to the next action. Raw runtime
    data in, step out: the driver never constructs a session value. *)

val accept_response :
  Env.t ->
  Mentat_session.Provider_request.Id.t ->
  Mentat_llm.Response.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [accept_response env id response session] settles the provider claim [id] as
    responded and appends the assistant message; if it carries no tool calls,
    also settles the turn [Completed].

    One exception: a response stopped at the output limit while the context
    reading meets the pressure threshold keeps the turn active — the window,
    not the model, ended the answer — so the next request boundary compacts
    under pressure and re-issues over the reduced view. At most one such
    recovery per turn; a repeat length stop after a compaction settles the turn
    [Completed] with what the model produced. *)

val install_summary :
  Env.t ->
  Mentat_session.Provider_request.Id.t ->
  summary:Mentat_llm.Message.t list ->
  reason:Mentat_session.Compaction.Reason.t ->
  summarized_upto:int ->
  ?usage:Mentat_llm.Usage.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [install_summary env id ~summary ~reason ~summarized_upto ?usage session]
    installs the compaction fact for a [`Compaction] response.
    [summarized_upto] is the cut decided when the summary request was built,
    carried on the [`Compaction] purpose — never recomputed at install: the
    claim's own request may have frozen a pending notices batch into the
    transcript since, and a recomputed cut could cover messages the
    summarizer never saw. The fact carries the claim and
    CLOSES it — "summarized-but-not-installed" is unrepresentable; a duplicate
    [(request digest, reason)] key is refused at replay. [usage] is the
    summarizer response's provider-reported usage, folded into session metrics.

    The fact's boundary keeps a verbatim tail: the most recent turns that fit
    the tail budget — a tenth of the pressure threshold — survive the boundary
    as-is, and the summary replaces only the messages before them, always
    strictly more than any prior summary replaced. When no whole turn fits the
    budget, or automatic compaction is disabled, the summary replaces the whole
    transcript and the resume notice trails it instead.

    The active turn's origin routes what follows the install: an
    [Origin.Compaction] turn (a manual {!compact}) also settles [Completed] in
    the same suffix — its whole body was the one summary; every other origin (an
    automatic prelude) continues the requesting turn on the reduced model view.

    The driver validates the summary first (13.7: a failed or empty summary is a
    flow failure, never a durable fact); an unusable [summary] raises
    [Invalid_argument] here. *)

val settle_provider_failed :
  Mentat_session.Provider_request.Id.t ->
  Mentat_llm.Error.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [settle_provider_failed id error session] settles a KNOWN provider failure:
    the call finished and did not succeed. The claim closes through the
    structured [Failed] arm carrying [error] — the smallest durable diagnostic
    the LLM layer owns — and the turn settles [Failed] in the same suffix. Never
    [Ambiguous] (the outcome is proven) and never [Interrupted]. Remaining
    unanswered calls receive reconciliation results naming the failure.

    The driver routes a [Context_overflow] failure of a [`Turn] request to
    {!settle_provider_overflow} instead; every other failure — and any failure
    of a [`Compaction] request — closes here. *)

val settle_provider_overflow :
  Env.t ->
  Mentat_session.Provider_request.Id.t ->
  Mentat_llm.Error.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [settle_provider_overflow env id error session] settles a [`Turn] request's
    [Context_overflow] failure under the per-turn recovery bound: the claim [id]
    closes [Failed] carrying [error]. If the active turn has NOT yet installed a
    [Context_overflow] compaction, the turn stays ACTIVE — a [Failed] settlement
    clears the suspension and appends nothing, so the model view is still
    request-ready — and the next boundary compacts (reason [Context_overflow])
    and re-issues the request once over the reduced view. If the turn already
    spent its one overflow compaction, the retry overflowed again: the turn
    finishes [Failed] carrying [error]. The bound is a replay fold over the
    active turn's events — at most one overflow compaction per turn — with no
    new durable state; the automatic pressure path is unchanged. *)

val settle_provider_ambiguous :
  Mentat_session.Provider_request.Id.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [settle_provider_ambiguous id session] is the live ambiguous mint for a
    provider claim — the driver's callback-exception path. The settlement
    appends nothing and forces the turn to finish [Interrupted] in the same
    suffix; nothing re-bills. *)

val settle_tool :
  Env.t ->
  Mentat_session.Tool_claim.Id.t ->
  Mentat_tool.Call.outcome ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [settle_tool env id outcome session] settles tool claim [id]. [Prepared p]
    settles a Prepare claim — terminal for the claim; the model call stays
    pending and the run-stage permission decision opens: allowed resumes into
    the claimed Run effect, review parks a decision, denial answers the call.
    [Finished r] settles a Run or Direct claim as returned, lowering the
    model-visible result at replay. Resume drift — declaration, identity,
    reconstruction, or recomputed-request drift — settles as a model-visible
    failed result naming the drift, never an error. The same declaration check
    runs at every dispatch, live or recovered: the current declaration is
    composed against the sealed contract's, and a missing or unequal declaration
    lowers to that same model-visible failure — there is no dedicated drift fact
    or protocol arm. *)

val settle_tool_ambiguous :
  Env.t ->
  Mentat_session.Tool_claim.Id.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [settle_tool_ambiguous env id session] is the live ambiguous mint for a tool
    claim — a callback exception does not prove the callback produced no
    effects. The call is consumed with the session's synthetic ambiguous answer
    and the turn continues. [env] computes the post-settlement action only; it
    never decides the settlement. *)

val resolve_decision :
  Env.t ->
  Mentat_session.Decision.Id.t ->
  answered_by:Mentat_session.Principal.t ->
  Mentat_session.Decision.Answer.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [resolve_decision env id ~answered_by answer session] is the one decision
    resolver; kind and pairing are checked by [Decision.resolve]. [answered_by]
    names the honest actor; an [Unattended_policy] principal may only deny — a
    structured {!Error.Decision}, re-checked at replay, so no shell can widen
    it. A permission allow re-decides into the claimed Tool effect (for a staged
    run stage, via [Call.resume] — codec reconstruction and equality, never
    re-preparation). A plan Approve settles the Plan turn [Completed]; the
    driver admits the Build turn. *)

val reserve_result :
  Env.t ->
  Step.Reservation.t ->
  [ `Granted | `Refused of Step.Reservation.Refusal.t ] ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [reserve_result env reservation answer session] is the scheduler's capacity
    answer. [`Granted] commits the delegation edge with its receipt output in
    one suffix — the edge is durable before any child exists. [`Refused] commits
    the model-visible structured refusal instead: no edge, no child. *)

val deliver_child :
  Env.t ->
  wait:Step.Children_wait.t ->
  settled:
    (Mentat_session.Delegation.Id.t
    * (Mentat_llm.Content.t list * Mentat_llm.Usage.t option))
    list ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [deliver_child env ~wait ~settled session] is the scheduler's wait
    feed-back: every named child's known final result so far — plain owner
    values the scheduler derives from the child journal. The answer pairs with
    [wait.wait_call] against the pending set; a missing pending call is
    {!Error.No_pending_wait}. When [wait]'s set completes, appends ONE ordinary
    tool-result message answering the wait call and advances. An incomplete set
    returns an empty-commit step re-reporting the same [Await_children ~wait]
    (idempotent). *)

(** {1:messages Recorded mail}

    The durable carrier of a recorded message is the recording transcript:
    the [send]/[follow_up] call's decoded input plus its successful receipt.
    The step records honestly — the receipt promises delivery at
    settlement — and the driver detects each settled receipt and routes
    delivery; recovery re-drives receipts whose delivery never reached the
    target journal. Receipts recorded under the retired [send_message]
    spelling decode forever — old journals redrive through the same path. *)

val settled_message :
  Mentat_session.t -> Mentat_session.Event.t -> Step.Mail.t option
(** [settled_message session event] is the recorded message when [event] is a
    successful [send]/[follow_up] receipt, paired with its call in
    [session]'s journal (the committed head containing [event]); [None]
    otherwise. The driver's per-commit delivery detector. *)

val settled_messages : Mentat_session.t -> Step.Mail.t list
(** [settled_messages session] is every recorded message in [session]'s
    journal, in journal order — the recovery scan's input and the exchange
    cap's per-edge count. *)

val queued_input :
  Mentat_session.t ->
  Mentat_session.Queue.Entry.t ->
  Mentat_llm.Content.t list
(** [queued_input session entry] is the turn input admission mints when it
    consumes [entry] from [session]'s queue. An owner entry (no origin) is
    its content verbatim — today's queued input, unchanged. An origin-bearing
    entry is framed: a leading text block names the sender from the typed
    origin alone — [session]'s own recorded lineage and edges name a parent
    or child where they can, the raw id otherwise — and fences the body as
    material from that sender, never as the owner's instructions; the body
    blocks follow unchanged. The body never influences the framing, so a
    hostile body cannot imitate a better sender. *)

val interrupt :
  ?reason:string ->
  ?assistant_text:string ->
  ?usage:Mentat_llm.Usage.t ->
  Mentat_session.t ->
  (Step.t, Error.t) result
(** [interrupt ?reason ?assistant_text ?usage session] is the live cooperative
    interrupt: an open provider claim settles [Interrupted] retaining non-empty
    streamed prose and, when [usage] is given, the last provider-reported usage
    snapshot ([Ambiguous] without prose, which forces the same terminal);
    an open tool claim settles with a synthesized interrupted result; every
    remaining unanswered call receives a synthesized interrupted tool result;
    the turn settles [Interrupted]. The crash path is {!recover}, which settles
    [Ambiguous] instead.

    A turn parked on a pending decision requires the durable interrupt request
    to be committed first: the reconciliation result answering the decision-held
    call is admissible only on an interrupt-forced turn. The suspension clears
    while the abandoned decision stays durably unresolved; a later answer finds
    it not pending. Without the recorded interrupt the attempt is a [Session]
    error.

    Raises [Invalid_argument] if [reason] is present and empty. *)
