(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The drain-time dune notice producer.

    This is one of [drain_notices]' two v1 sources, alongside
    {!Workspace_watch}. It reads the shared attach observer's settled reading
    — a memory read, never IO on the drain path — and lowers the change law's
    verdicts into {!Mentat_workspace.Notice.t}: what the last settled build
    says that the model has not heard, per lane, and nothing when the finding
    set is unchanged, the watch is mid-build, or nothing is attached.

    Notices are deduplicated in the producer because the port has no queue:
    the law's baseline advances only when a change is stated, so a producer
    drained many times within one turn repeats nothing, and lost visibility
    neither states nor forgets anything. *)

type t
(** A stateful producer: the shared observer and the change law's stated
    baseline. *)

val make : instance:Mentat_ocaml_dune_rpc.Instance.t -> unit -> t
(** [make ~instance ()] is a producer over [instance]'s attach observer.
    Construction performs no IO; {!drain} reads the observer's snapshot. *)

val drain : t -> Mentat_workspace.Notice.t list
(** [drain t] is the changes the current settled reading states over the
    baseline, as notices — build lane first, then lint — advancing the
    baseline exactly by what it returns. No settled reading is the empty
    list. *)

val health_of : Mentat_ocaml_dune_rpc.Instance.t -> Mentat_workspace.Health.t
(** [health_of instance] is the watch status a frontend glances at, projected
    from [instance]'s snapshot without IO: nothing attached is
    {!Mentat_workspace.Health.Off} [No_server], a connection in flight is
    {!Mentat_workspace.Health.Probing}, and an attached watch is
    {!Mentat_workspace.Health.Live} with a foreign owner — mid-build or
    unsettled as [Building], at rest as [Settled] with the reading's verdict
    and lint count. The caller owes the tooling gate: a disabled or untrusted
    workspace never reaches this projection. *)

val health : t -> Mentat_workspace.Health.t
(** [health t] is {!health_of} over [t]'s observer. *)
