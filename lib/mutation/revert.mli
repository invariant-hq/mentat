(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Revert selection, pure preparation, and lifecycle evidence.

    Every fact the revert safety argument rests on is durable before the IO it
    describes: {!prepare} is pure and all-or-nothing; the started fact freezes
    exactly what will be attempted, {e before} any filesystem IO occurs; the
    settled fact records per-path outcomes classified by [Mentat_edit]'s
    structural {!Mentat_edit.Apply_error.Phase} guarantee; crash recovery reads
    only the frozen record.

    The vocabulary lives in {!Revert_data}; this module re-exports it by alias
    and adds the operations that consume {!State}. *)

module Id = Revert_data.Id
(** Stable revert identifiers. *)

module Selection = Revert_data.Selection
(** Canonical selections over recorded history. *)

module Evidence = Revert_data.Evidence
(** Already-performed reads and already-resolved blobs. *)

module Override = Revert_data.Override
(** Explicit consent to unrecorded-edit loss. *)

module Problem = Revert_data.Problem
(** Structured preparation refusals. *)

module Target = Revert_data.Target
(** Frozen revert transitions. *)

module Started = Revert_data.Started
(** The durable started fact. *)

module Plan = Revert_data.Plan
(** Ready revert plans. *)

module Edit_failure = Revert_data.Edit_failure
(** The persisted edit-error form. *)

module Settled = Revert_data.Settled
(** The durable settlement fact. *)

(** The high-level revert selector a frontend names, above {!Selection} (which
    is the canonical resolution against recorded history). A driver resolves a
    scope to a selection with the session's loaded state; the wire carries the
    scope. *)
module Scope : sig
  type t =
    | Latest  (** The most recent revertable turn. *)
    | Change of Change.Id.t  (** One recorded change by id. *)
    | Path of Mentat_workspace.Path.t
        (** Every recorded change touching this workspace path. *)

  val resolve : State.t -> t -> Selection.t option
  (** [resolve state scope] is the canonical selection [scope] names against
      [state]'s recorded history, or [None] when [Latest] finds no editing turn
      ({!State.latest_edit_turn}). [Change] and [Path] resolve structurally;
      whether they name recorded work is preparation's question, not
      resolution's. *)

  val jsont : t Jsont.t
  (** [jsont] maps a scope to a tagged JSON object ([type] =
      latest/change/path). *)
end

(** The outcome of an applied revert (the online twin of {!Mentat_store}'s
    revert result): the settlement when work applied, a clean no-op when the
    selection was empty, or the projected refusal messages when preparation
    refused before touching a file. The refusal is display-only (it mints no
    fact), so it crosses as the messages {!Problem.message} renders — the same
    content the offline path prints. *)
module Outcome : sig
  type t =
    | Applied of Settled.t
        (** The revert applied; the settlement is durable. *)
    | Nothing_to_revert  (** The selection resolved to no revertable work. *)
    | Refused of string list
        (** Preparation refused; no file changed. The strings are the
            preparation problems' rendered messages. *)

  val jsont : t Jsont.t
  (** [jsont] maps an outcome to a tagged JSON object ([type] =
      applied/nothing_to_revert/refused). *)
end

val prepare :
  ?merge:bool ->
  ?override:Override.t ->
  id:Id.t ->
  evidence:Evidence.t ->
  State.t ->
  Selection.t ->
  (Plan.t, Problem.t list) result
(** [prepare ?merge ?override ~id ~evidence state selection] resolves
    [selection] against [state], nets it, checks each target's current read
    against the recorded net-after, resolves each restore image's bytes, and
    lowers the all-or-nothing [Mentat_edit.t] — or refuses with every problem
    found. Refusal changes no file and mints no fact.

    {b The merge gate.} [merge] defaults to [true]. When set, a superseded entry
    — a later recorded change moved the path's head past the selection's
    net-after — whose current read is still that recorded head is not refused
    but three-way merged ({!Textdiff.Merge}): [base] the net-after, [ours] the
    current file, [theirs] the net-before. A clean merge yields a target that
    rewrites the current file to the merged image, its fresh bytes carried in
    {!Plan.merge_blobs}; a conflict refuses with a {!Problem.Conflict} carrying
    the whole merge, for the caller to render its markers. A missing base blob,
    an unrecorded writer (current read not the head), a non-contiguous entry, or
    an override all fall through to the ordinary superseded refusal. When
    [merge] is [false] the superseded arm refuses exactly as before, byte for
    byte.

    Preparation refuses while {!State.unresolved_reverts} is non-empty
    ({!Problem.Unresolved_revert}): no new plan is resolved against a history in
    an unknown intermediate state.

    {b The override ruling.} A non-contiguous target is never silently planned:
    without an override covering it, preparation refuses with
    {!Problem.Needs_override}. Only an {!Override.t} naming exactly the
    non-contiguous paths lets preparation mint the plan; an override naming a
    path that is not non-contiguous is itself refused
    ({!Problem.Unmatched_override}). The override is frozen into the started
    fact so the audit trail carries the consent. For an overridden target,
    [expected] is the plan-time read (the unrecorded writer's text), not any
    recorded image, and a target whose plan-time read already equals its restore
    image is dropped — nothing would change and nothing is lost. The frozen
    consent is narrowed to the paths that survived into targets: a dropped path
    is untouched by the plan, so the started fact never carries consent for it
    (and {!Started.t}'s invariant — every override path a target path — holds).
*)

val settle :
  Started.t ->
  (Mentat_edit.Result.t, Mentat_edit.Apply_error.t) result ->
  Settled.t
(** [settle started outcome] is the pure classification of an apply outcome,
    driven by {!Mentat_edit.Apply_error.Phase}:

    - [Ok result]: every target {!Settled.Confirmed}, with restoration rows
      lowered from the result's entries.
    - [Error e] with [Phase.Preflight]: every target {!Settled.Not_attempted} —
      the phase guarantees no mutation was attempted anywhere — and the
      plan-level failure has phase [Preflight]. No restoration rows.
    - [Error e] with [Phase.Commit { target }]: the confirmed prefix
      ({!Mentat_edit.Apply_error.applied}) is {!Settled.Confirmed} with
      restoration rows; the stopping target is {!Settled.Ambiguous} — mutation
      of it was attempted and did not confirm, and its on-disk state is
      uncertain unless the error proves otherwise, which no current upstream
      error does; every target after it is {!Settled.Not_attempted}. The
      plan-level failure has phase [Commit { target }].

    Raises [Invalid_argument] if [outcome] does not pair with the started
    targets positionally: an [Ok] result's entries must match the targets path
    for path with each confirmed entry's before and after images equal to the
    frozen [expected] and [restore] images, a preflight failure must carry no
    applied entries, and a commit failure's applied prefix must pair the same
    way with the stopping target the first unconfirmed one — an upstream
    contract breach (or an outcome from a different apply), not a recoverable
    state. *)

val settle_ambiguous : Started.t -> Settled.t
(** [settle_ambiguous started] marks every started target {!Settled.Ambiguous},
    with no restoration rows and disposition {!Settled.Recovered}. This is the
    only settlement crash recovery may mint, and it is a function of the durable
    started record alone: recovery never re-resolves the selection against the
    post-crash ledger, because re-resolution would describe what recovery now
    sees, not what the crashed process attempted. *)
