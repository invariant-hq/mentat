(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Resolved per-session engine configuration.

    The values the engine reads at each turn boundary, sealed by the executable:
    the model and request options the turn contract freezes, the effective
    permission posture, and the exact knobs the step's pure policies read. The
    engine never parses configuration: a resolved-config carrier's model field
    is a [provider/model] selector string whose resolution needs the provider
    catalog, a library the engine's ports-only dune dependency list excludes, so
    the executable resolves once and hands the engine these owner values. *)

type t = private {
  model : Mentat_llm.Model.t;  (** The model new turn contracts seal. *)
  options : Mentat_llm.Request.Options.t;
      (** Default request options; a prompt command's options override them. *)
  policy : Mentat_permission.Policy.t;
      (** The effective permission policy the contract freezes; session grants
          are layered over it by replay, never stored here. *)
  review : Mentat_permission.Review_behavior.t;
      (** The review behaviour the contract freezes. *)
  max_steps : int;
      (** Model-response limit per turn; positive. A backstop against a turn
          that has stopped making progress, not a bound on how much work one
          turn may do: reaching it settles the turn
          {!Mentat_session.Turn.Outcome.Step_limit}, which the engine answers
          with one wrap-up turn rather than a stop. *)
  compaction_pressure_tokens : int option;
      (** Projected replay tokens above which a request boundary compacts;
          [None] disables automatic compaction. *)
  max_spawn_depth : int;
      (** Delegation depth cap: a session at this depth cannot spawn. *)
  max_exchanges : int;
      (** Model-origin child messages per delegation edge (child-addressed
          [send] and [follow_up] receipts both count). *)
}
(** The type for resolved per-session engine configuration. *)

val make :
  model:Mentat_llm.Model.t ->
  ?options:Mentat_llm.Request.Options.t ->
  ?policy:Mentat_permission.Policy.t ->
  ?review:Mentat_permission.Review_behavior.t ->
  ?max_steps:int ->
  ?compaction_pressure_tokens:int ->
  ?max_spawn_depth:int ->
  ?max_exchanges:int ->
  unit ->
  t
(** [make ~model ()] is a resolved configuration.

    [options] defaults to {!Mentat_llm.Request.Options.default}; [policy] to
    {!Mentat_permission.Policy.default}; [review] to
    {!Mentat_permission.Review_behavior.Enforce}; [max_steps] to [500];
    [compaction_pressure_tokens] to [None]; [max_spawn_depth] to [1];
    [max_exchanges] to [8].

    Raises [Invalid_argument] if [max_steps], [compaction_pressure_tokens],
    [max_spawn_depth], or [max_exchanges] is not positive. *)
