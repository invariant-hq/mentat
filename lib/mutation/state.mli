(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The sole replay fold.

    Every consumer — CLI, TUI, protocol projection, crash recovery, revert
    planning — reads this fold's projections; none interprets the raw event
    list. The protocol projects wire summaries directly from {!changes} and,
    through {!at_claim}, the settlement-time {!revertability}; this library
    exposes no protocol-shaped view. *)

type t
(** The type for one session's validated mutation history: the events, their
    indices, and the derived per-claim, per-turn, per-path projections. *)

module Error : sig
  (** Replay rejection. *)

  (** The type for cross-event invariant violations. *)
  type reason =
    | Duplicate_checkpoint of Checkpoint.Id.t
    | Invalid_ordinal of {
        claim : Mentat_session.Tool_claim.Id.t;
        ordinal : int;
        expected : int;
      }
        (** An [Edit] event whose ordinal is not the claim's next dense ordinal
            — a repeat of a recorded apply ([ordinal < expected]) or a gap
            ([ordinal > expected]). The density law: the claim's k-th recorded
            apply event carries ordinal k. *)
    | Turn_conflict of Mentat_session.Tool_claim.Id.t
        (** An [Edit] or [Tool_observed] event names a different turn than the
            claim's first referencing event — one claim's evidence spans one
            turn. *)
    | Duplicate_change of Change.Id.t
    | Invalid_transition of { path : Mentat_workspace.Path.t }
        (** An image pair no constructor can produce (decode-level checks re-run
            cross-event). *)
    | Dangling_checkpoint of Checkpoint.Id.t
    | Checkpoint_mismatch of Checkpoint.Id.t
        (** The referenced checkpoint is not the turn's [Available] conservative
            capture — its [Before_turn_tools] one, or the fresh [After_recovery]
            one a recovered turn takes rather than reusing a pre-crash capture.
        *)
    | Duplicate_revert of Revert_data.Id.t
    | Missing_revert_checkpoint of Revert_data.Id.t
        (** A [Revert_started] has no matching earlier [Before_revert]
            checkpoint. A checkpoint without a later start remains valid crash
            residue; only the start requires the prefix. *)
    | Unknown_selected_change of Change.Id.t
        (** [Selection.Changes] names an id absent from the exact history
            prefix. Every selected id is an ownership claim, even when the
            remaining ids would resolve to the same targets. *)
    | Invalid_start of Revert_data.Id.t
        (** A [Revert_started] no planner could have minted at its prefix: its
            selection resolves to nothing, a target's restore/sources (or a
            plain target's expected) differ from the netted entries, a plain
            contiguous entry lacks a target, an older revert is unresolved, or
            the frozen consent is not exactly the non-contiguous target paths.
            Two images are trusted, not validated against history because they
            are not replayable from it: an overridden target's [expected] (a
            plan-time read) and a clean merge's [restore] (the merged image,
            frozen once at preparation). A superseded path is therefore not
            rejected outright — a superseded, contiguous, non-overridden entry
            is a valid merge, whose target carries the recorded head as
            [expected] and may be absent only on the merge's own equals-current
            drop. *)
    | Unmatched_settlement of Revert_data.Id.t
        (** [Revert_settled] with no prior unsettled [Revert_started]. *)
    | Settlement_mismatch of Revert_data.Id.t
        (** Settled outcomes do not cover the started targets exactly, or
            confirmed outcomes and restoration rows do not correspond. *)

  type t = private { index : int; reason : reason }
  (** The type for a located replay failure. [index] is the zero-based offending
      event position. *)

  val message : t -> string
  (** [message t] is a human-readable diagnostic. Presentation only. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats {!message} output. *)
end

val of_events : Event.t list -> (t, Error.t) result
(** [of_events events] is the only replay entry point. It rejects the first
    event that violates a cross-event invariant, reporting its index and a
    structured reason. Deterministic: byte-identical event lists fold to equal
    projections, live and replayed. *)

val append : t -> Event.t list -> (t, Error.t) result
(** [append t batch] extends [t] by folding [batch] with the same validation as
    a full replay. The law: [append t batch] equals
    [of_events (events t @ batch)] — equal projections on success, and on
    rejection the same located error, with [Error.index] continuing from [t]'s
    events. {!of_events} remains the sole replay entry point; [append] exists so
    an appender that already holds the validated state can validate just the
    batch instead of refolding the whole ledger. *)

val events : t -> Event.t list
(** [events t] is the validated event list, in application order. *)

(** {1:projections Projections} *)

val claims : t -> Mentat_session.Tool_claim.Id.t list
(** [claims t] is the claims with recorded evidence — exact or observed — in
    first-seen order. The protocol projector intersects this with the session's
    settled claims; the orphan-ignore rule is the projector's. *)

val changes : t -> claim:Mentat_session.Tool_claim.Id.t -> Change.t list
(** [changes t ~claim] is [claim]'s exact change rows across its recorded
    applies, concatenated in ordinal order with each apply's rows in mutation
    order, or [[]] when the claim recorded none.

    {b The within-claim per-path law.} One claim may record the same path in
    several applies — the ids differ by ordinal, so nothing collides. Rows enter
    netting and the ledger head in this ledger order, so for one path the
    {e last} apply's row is the head and {!Change.net} joins the applies'
    transitions like any other adjacent deltas: a later apply whose before
    equals the earlier apply's after nets contiguously; one that does not marks
    the entry non-contiguous. Later applies supersede earlier ones per path by
    position in the fold, never by overwrite — every row stays recorded. *)

val change : t -> Change.Id.t -> Change.t option
(** [change t id] is the recorded change with id [id], if any. Change ids are
    unique within a ledger — replay rejects duplicates — so at most one exists.
*)

val observed :
  t -> claim:Mentat_session.Tool_claim.Id.t -> Mentat_workspace.Path.t list
(** [observed t ~claim] is the paths observed changed while [claim]'s window was
    active — deduplicated and sorted — or [[]]. Uncertain stopping targets are
    not included: they are apply-level facts, carried into the safety answer as
    {!Revertability.Uncertain} reasons. *)

val at_claim : t -> claim:Mentat_session.Tool_claim.Id.t -> t option
(** [at_claim t ~claim] is the validated ledger prefix through the last event
    referencing [claim] — the projector computes settlement revertability from
    this prefix, live and replayed — or [None] if no event references [claim].
    The prefix ends at [claim]'s last ledger event, which precedes the
    settlement's journal commit; live/replay identity holds because both run
    this same fold, not because the prefix reproduces a moment of live state.
    The law: a prefix of a validated ledger is itself valid, because every
    cross-event invariant is an ordering or uniqueness fact, so serving the
    prefix cannot reject. *)

val checkpoint_at : t -> Checkpoint.boundary -> Checkpoint.t option
(** [checkpoint_at t boundary] is the recorded capture at [boundary], if any.
    Identity is the boundary, so at most one exists — the driver looks up a
    turn's conservative capture by the boundary it captures at, never by an id
    it would have to hold first. *)

val prefix_for_turns :
  t -> keep:(Mentat_session.Turn.Id.t -> bool) -> Event.t list
(** [prefix_for_turns t ~keep] is the maximal prefix of [t]'s events that
    references no turn for which [keep] is [false] — the mutation ledger a
    branch or rewind child copies, where [keep] holds for exactly the turns the
    child's document retains.

    The turn an event references is the same correlation coordinate the store
    joins against a document: an [Edit] or [Tool_observed] names its [turn]; a
    [Before_turn_tools], [After_recovery], or [After_turn] checkpoint names its
    turn; a [Revert_started] with a {!Revert.Selection.Turns} selection names
    each selected turn. A [Before_revert] checkpoint, a revert over
    {!Revert.Selection.All}, {!Revert.Selection.Changes}, or
    {!Revert.Selection.Paths}, and every [Revert_settled] reference no turn, so
    they ride the prefix when they precede the first dropped-turn event.

    A prefix — not a filter — because a prefix of a validated ledger is itself
    valid (every cross-event invariant is an ordering or uniqueness fact) and
    correlates against the child document (whose turns are exactly the kept
    ones), while a mid-ledger filter could sever a revert's start from its
    settlement. The rewind anchor cuts the document at a turn boundary and turns
    are chronological, so the first event naming a dropped turn is where the
    kept prefix ends; a revert performed in the gap after the last kept turn but
    before the first dropped one is retained, the well-defined choice a
    turn-granular anchor admits. When [keep] holds for every turn — a fork, or a
    rewind to the last boundary — the whole ledger is returned. *)

val head : t -> Mentat_workspace.Path.t -> Change.t option
(** [head t path] is the ledger's last recorded change for [path], if any — the
    net-after a later selection is superseded against. *)

val net : t -> Revert_data.Selection.t -> Change.Net.entry list
(** [net t selection] is {!Change.net} of the selection's resolved changes, in
    ledger order. *)

val unresolved_reverts : t -> Revert_data.Started.t list
(** [unresolved_reverts t] is the started-and-not-settled reverts, oldest first.
    Non-empty means a revert began IO and no settlement was recorded: crash
    recovery must settle each from its frozen record
    ({!Revert.settle_ambiguous}) before any new revert can be prepared. *)

val settled_revert : t -> Revert_data.Id.t -> Revert_data.Settled.t option
(** [settled_revert t id] is the recorded settlement of revert [id], or [None]
    when [id] is unknown or its revert started but has not settled. The undo
    flow resolves an armed revert's settlement — its per-path outcomes and
    restoration rows — by id when a widen, narrow, or cancel must un-revert it,
    and resume reconciliation uses it to tell a settled arm from an unsettled
    one. *)

val revertability : t -> Revert_data.Selection.t -> Revertability.t
(** [revertability t selection] is the single-owner revert-safety answer for
    [selection]: a superseded path proves [Unavailable]; a non-contiguous entry,
    an overlapping observation window, an uncertain apply target, or an
    unresolved revert leaves the evidence [Incomplete]; otherwise [Available]. A
    degraded conservative checkpoint does not, by itself, degrade an exact
    continuous selection: a successful [Mentat_edit] transition carries complete
    before and after states, and the snapshot never enters that restoration. An
    observation — and an uncertain stopping target, which follows the same
    window rules while keeping its per-path causal tie — is in scope when its
    paths intersect the resolved paths, its turn is within a selected turn
    scope, or its paths are members of a paths selection. An empty resolution is
    vacuously [Available] only when the selection contains no observation and no
    uncertain target either — a turn or paths scope whose only activity is
    observed or unconfirmed answers [Incomplete] — and preparation separately
    refuses to mint an empty plan. *)

(** {1:resolution Selection resolution} *)

val resolve : t -> Revert_data.Selection.t -> Change.t list
(** [resolve t selection] is the selection's resolved change rows in ledger
    order — the shared input of {!net}, {!revertability}, and {!Revert.prepare}.
    Restoration rows carry no turn, so a turns selection never resolves them. *)

val latest_edit_turn : t -> Mentat_session.Turn.Id.t option
(** [latest_edit_turn t] is the most recent turn that recorded an exact change,
    or [None] when no turn has — observations and reverts carry no turn, so
    only an editing turn qualifies. The one resolver behind every
    latest-revertable-work selection (a wire [Latest] revert scope, an offline
    [--latest] flag), so its consumers cannot drift. *)
