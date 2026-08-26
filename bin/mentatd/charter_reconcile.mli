(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The node's charter reconcile fold — the decisions a resident pass owes a
    charter's durable record, as pure tables over probe thunks, so the full
    tables are unit-testable with no store, fence, or child behind them.

    A charter's record is its receipt log plus the per-session run fence;
    the fold holds no state of its own and reads both fresh on every pass,
    so running it twice is running it once. Its unit of judgment is one
    event identity's record, split across two tables:

    - {!run_action} judges a {e pending} run — a spawned disposition with
      no reaped line, the record left behind whenever the reaping process
      is stopped, killed, or crashes while a run child lives. The row is
      total: free, held, and unprobeable fences each have a decision, so
      the process driving the pipeline may be cancelled at any instant and
      the next pass settles whatever was left open.
    - {!sweep_action} states the sweep's law over an identity's receipts:
      drive it through the pipeline, re-enter the publisher, or leave the
      completed record alone. Its interpreter is [Charter_fire.fire_sweep]'s
      own fold; it is stated and tested here so the node's whole decision
      surface is enumerable in one place. *)

type fence =
  [ `Free  (** No process holds the run fence — the child is gone. *)
  | `Held
    (** Some process holds it: the run child, or the owner resuming the
        session interactively. The node never signals a holder — a run
        driver's owner line cannot be told apart from the owner's own
        resume, and killing the owner's session to enforce a budget is a
        worse failure than narrating an overdue run. *)
  | `Io of string  (** The fence could not be probed. *) ]
(** The type for a run-fence probe's answer, in the table's vocabulary. The
    fence, never a stored pid, is the liveness truth: fences release on
    holder death, so a free fence over a spawned-but-unreaped run means no
    process anywhere is left to write the record's reaped line. *)

type run =
  [ `Settle
    (** The fence is free: the child is gone, no reaper survives it, and
        the record owes its one honest reaped line
        ([Charter_fire.settle_recovered]). *)
  | `Leave
    (** A live holder within the run's wall-clock budget: its own reaper —
        or a later pass — owes the record; touch nothing. *)
  | `Overdue
    (** A live holder past the run's wall-clock budget, with no reaper
        left to enforce it: say so loudly and keep leaving it — the run's
        own step bound still limits it, and the record settles when the
        fence frees. *)
  | `Skip of string
    (** The fence was unprobeable: never settle over a fence that may
        still be held; say why and leave the record for the next pass. *)
  ]
(** The type for the pending-run decision. *)

val run_action : fence:(unit -> fence) -> overdue:(unit -> bool) -> run
(** [run_action ~fence ~overdue] is the pending-run table over lazy
    probes — [overdue] (the clock read against the spawned receipt's
    timestamp) is consulted only under a held fence, so the clock is never
    spent on an arm that cannot use it. *)

type sweep =
  [ `Drive
    (** Commit the identity through the fire pipeline: it never claimed,
        or its claim has no spawned line — a committer that died between
        claim and spawn — which the pipeline's admission adopts. *)
  | `Republish of string
    (** The named session ran to a publishable settle and no egress line
        exists: re-enter the publisher only — the upsert is idempotent, so
        finishing an interrupted publication spends nothing and mints no
        run. *)
  | `Done  (** The record is complete; nothing is owed. *) ]
(** The type for the sweep decision over one identity's receipts. *)

val sweep_action :
  claimed:bool ->
  spawned:(unit -> bool) ->
  egress:(unit -> bool) ->
  settled:(unit -> string option) ->
  sweep
(** [sweep_action ~claimed ~spawned ~egress ~settled] is the sweep table
    over lazy probes: [spawned] (whether the log carries the claim's
    spawned line) is consulted only under a held claim, [egress] only under
    a committed spawn, and [settled] (the publishable session, if any) only
    when no egress line exists. A pending run answers [`Done] here — its
    fate belongs to {!run_action}, never to the sweep. *)

(** One spawned run with no reaped line. *)
module Pending : sig
  type t = {
    identity : string;  (** The triggering event's identity string. *)
    digest : string;
        (** The charter policy digest the run was spawned under. *)
    session : string;  (** The run's derived session id. *)
    spawned_at : float;
        (** The spawned receipt's timestamp, seconds since the epoch — what
            a pass re-arms the wall-clock judgment from. *)
  }
  (** The type for pending runs. *)
end

val pending_runs : Mentat_charter.Receipt.t list -> Pending.t list
(** [pending_runs receipts] is the runs whose record is open: every spawned
    disposition in [receipts] with no reaped disposition under the same
    charter digest and event identity, in log order. Pairing is by digest
    and identity together — never by session — so each policy's record is
    whole on its own: a policy edit's re-run neither adopts nor closes an
    earlier policy's run. *)

(** {1:drivers Drivers}

    The thin interpreters over the tables. All of them narrate refusals and
    failures through the environment's line sink and never raise: a broken
    charter or an unreachable remote must not stop the resident, and the
    next beat retries for free. Passes must not run concurrently with one
    another — the honest settle itself is serialized under the charter's
    fire lock, so a concurrent pass costs duplicate narration at worst, but
    the caller keeps one pass in flight at a time. *)

val reconcile :
  Charter_fire.env ->
  repo_for:(Charter_store.Loaded.t -> (Charter_fire.Repo.t, string) result) ->
  Charter_store.Loaded.t ->
  unit
(** [reconcile env ~repo_for loaded] is one charter's pass. Every pending
    run ({!pending_runs} over a fresh receipt read) is judged by
    {!run_action} and interpreted: the honest settle for a freed fence
    ([Charter_fire.settle_recovered]), narration for an overdue or
    unprobeable one, silence for a live run within budget. Then, for an
    enabled charter, [repo_for loaded] builds the repository connection —
    fresh on every pass, so an owner's credential or configuration edit is
    in force at the next beat — and [Charter_fire.fire_sweep] drives the
    sweep half of the fold. A disabled charter still settles its pending
    runs — the money is already spent and the record is owed — but sweeps
    nothing and publishes nothing. This is also the re-entry a caller runs
    for one charter after reaping one of its runs. *)

val pass :
  Charter_fire.env ->
  repo_for:(Charter_store.Loaded.t -> (Charter_fire.Repo.t, string) result) ->
  unit
(** [pass env ~repo_for] reconciles every installed charter, reading the
    roster fresh; a charter that fails to load is narrated and passed over,
    never a stop. This is the boot fold: run it before serving deliveries,
    so the records a previous life left open are settled before new ones
    are admitted. *)

val reconcile_interval_s : float
(** The seconds between periodic passes of {!loop} — ten minutes: a
    backstop's cadence, behind webhook deliveries and the after-reap
    re-entry, that keeps a lost delivery, an interrupted publication, or an
    orphaned run converging without redelivery. *)

val loop :
  Charter_fire.env ->
  repo_for:(Charter_store.Loaded.t -> (Charter_fire.Repo.t, string) result) ->
  unit
(** [loop env ~repo_for] runs {!pass} now, then again every
    {!reconcile_interval_s}, until the environment's stop seam asks for a
    stop or the fiber is cancelled — the sleep is cancellable, so teardown
    never waits on the beat. Running the first pass immediately is
    deliberate: the fold is idempotent, so a caller that already ran its
    boot pass merely buys a cheap re-read. *)
