(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Immutable per-drive inputs.

    An environment composes the resolved owner values one drive of the step
    reads: the catalog view, the current sealed sandbox identity (the resume
    drift input), the request prelude, and the exact resolved configuration
    values the pure policies read. The driver re-resolves configuration at turn
    boundaries and builds one [Env.t]; the step never resolves, reads files, or
    mints entropy.

    Deliberately absent: a running-children count — capacity is not a pure
    decision over a sampled integer; the step emits a reservation and the
    scheduler's atomic permit decides. The active turn's permission policy and
    review behavior are read from its sealed contract, not from here. *)

type t = private {
  catalog : Catalog.t;  (** The dispatch surface for this drive. *)
  sandbox : Mentat_sandbox.Identity.t;
      (** The current sealed confinement identity, compared against the
          contract's at resume boundaries. *)
  prelude : Mentat_llm.Request.Prelude.t;
      (** Host request context; request-scoped, never transcript state. *)
  max_steps : int;
      (** The accepted model-response limit for a new turn; positive. *)
  denial_message : Mentat_permission.Policy.Denial.t -> string;
      (** Renders the model-visible text of a policy denial. Deterministic,
          total, non-empty: the result becomes durable transcript state. *)
  compaction_pressure_tokens : int option;
      (** The context reading above which a request boundary compacts with
          reason [Context_pressure]: provider-reported replay usage when a
          response supplied it, byte-estimated from the model view otherwise.
          A tenth of the threshold also budgets the verbatim tail a summary
          leaves in place: the most recent turns that fit it stay behind the
          summary rather than in it. [None] disables automatic compaction, and
          with it the tail. *)
  max_spawn_depth : int;
      (** Delegation depth cap: a session at this depth cannot spawn. *)
  max_exchanges : int;
      (** Model-origin child messages per delegation edge — child-addressed
          [send] and [follow_up] receipts both count; the cap refuses the
          next one. *)
  depth : int;  (** This session's delegation depth; the root is [0]. *)
}
(** The type for per-drive step inputs. *)

val make :
  catalog:Catalog.t ->
  sandbox:Mentat_sandbox.Identity.t ->
  ?prelude:Mentat_llm.Request.Prelude.t ->
  ?denial_message:(Mentat_permission.Policy.Denial.t -> string) ->
  max_steps:int ->
  compaction_pressure_tokens:int option ->
  max_spawn_depth:int ->
  max_exchanges:int ->
  depth:int ->
  unit ->
  t
(** [make ~catalog ~sandbox ~depth ()] is a per-drive environment. The scalar
    policy knobs are required: configuration defaults live in one place — the
    driver's resolved {e Config} — and this constructor resolves nothing.

    [prelude] defaults to {!Mentat_llm.Request.Prelude.empty}. [denial_message]
    defaults to a stable generic message.

    Raises [Invalid_argument] if [max_steps], [compaction_pressure_tokens],
    [max_spawn_depth], or [max_exchanges] is not positive, or [depth] is
    negative. *)
