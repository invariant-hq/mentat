(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The node's routine reconcile drivers — the thin interpreters that read
    a routine's durable record fresh and drive the pure reconcile tables
    ({!Mentat_routine.Record}, the receipt folds) through the fire
    pipeline.

    One routine's pass owes its record four things, judged in order: every
    pending run — a spawned disposition with no reaped line
    ({!Mentat_routine.Receipt.pending_runs}) — gains one broker watch
    ({!Mentat_broker.watch}, deduplicated across passes), whose terminal
    observation drives the honest settle
    ([Mentat_boot.Routine_fire.settle_recovered]) — a run younger than the
    spawn grace is not watched at all (its activation may still be staging,
    and a free fence over an unfinished head would read holder-died either
    way), and a run observed settled while its activation still lingers
    holding the fence is left to the next pass, which re-watches; every
    reaped disposition still owed
    its alert re-fires it — the reap and the alert are two appends with an
    external hook between them, so a crash window between them is repaired
    here, idempotently, off the receipt-log dedup; every delivery receipt
    with no disposition — an acknowledged arrival a dead process never
    decided, which the sender will not redeliver — is rebuilt from its own
    members and re-driven through the ordinary dispose, or closed with a
    skipped line when it cannot be rebuilt; and, for an enabled routine,
    [Mentat_boot.Routine_fire.fire_sweep] drives the sweep half of the fold.
    A disabled routine still settles pending runs, repairs alerts, and closes
    its open deliveries as skipped-disabled — the money is already spent and
    the record is owed — but sweeps nothing and publishes nothing.

    All drivers narrate refusals and failures through the environment's
    line sink and never raise: a broken routine or an unreachable remote
    must not stop the resident, and the next beat retries for free. Every
    line one routine's pass speaks — the drivers' own and the fire
    pipeline's — is prefixed with that routine's name: one pass speaks for
    many routines, so the prefix is the line's provenance. Passes never run
    concurrently: {!pass} and {!pass_settle} serialize under one
    module-level gate — one node runs per process — while {!reconcile}, the
    after-reap re-entry, {e tries} the gate and yields to a pass in flight
    rather than parking its caller behind a full roster pass. *)

val reconcile :
  Mentat_boot.Routine_fire.env ->
  repo_for:
    (Mentat_boot.Routine_store.Loaded.t ->
    (Mentat_boot.Routine_fire.Repo.t, string) result) ->
  Mentat_boot.Routine_store.Loaded.t ->
  unit
(** [reconcile env ~repo_for loaded] is one routine's pass — the re-entry a
    caller runs for one routine after reaping one of its runs, so a
    publication that failed after the reap, or a delivery refused at a full
    intake queue, converges now instead of waiting out the periodic beat.
    [repo_for loaded] builds the repository connection fresh, so an owner's
    credential or configuration edit is in force at the next entry. The
    re-entry never waits: when the module gate is already held — a full
    roster pass in flight — it returns at once, because the holder's own
    pass re-reads this routine's record anyway and the beat backstops
    whatever it misses, while parking the caller (the node's pump fiber)
    would stall every queued delivery for the pass's whole length. *)

val pass :
  Mentat_boot.Routine_fire.env ->
  repo_for:
    (Mentat_boot.Routine_store.Loaded.t ->
    (Mentat_boot.Routine_fire.Repo.t, string) result) ->
  unit
(** [pass env ~repo_for] reconciles every installed routine, reading the
    roster fresh; a routine that fails to load is narrated and passed over,
    never a stop. The environment's stop seam is consulted before each
    routine and before each fresh run the fold would commit: a requested
    stop ends the pass without driving further work — provisioning and
    spawning under a stop would spend money the requester asked not to
    spend — and whatever it leaves is the next pass's to finish. *)

val pass_settle : Mentat_boot.Routine_fire.env -> unit
(** [pass_settle env] is the settle-only half of {!pass}: every installed
    routine's pending runs gain their watches, and nothing else — no
    repository connection, no network, no re-drive, no sweep. This is the
    boot fold's first step: an already-dead orphan's watch observes its
    terminal state on its first poll, so the settle lands moments after the
    boot without gating the daemon's serve surfaces on GitHub, and the
    loop's own immediate first {!pass} is the boot sweep. *)

val loop :
  Mentat_boot.Routine_fire.env ->
  repo_for:
    (Mentat_boot.Routine_store.Loaded.t ->
    (Mentat_boot.Routine_fire.Repo.t, string) result) ->
  unit
(** [loop env ~repo_for] runs {!pass} now, then again every ten minutes,
    until the environment's stop seam asks for a stop or the fiber is
    cancelled — the sleep is cancellable, so teardown never waits on the
    beat. The cadence is a backstop's, behind webhook deliveries and the
    after-reap re-entry: long enough that a beat's open-PR listings stay a
    rounding error against API budgets, short enough that a lost delivery,
    an interrupted publication, or an orphaned run converges well inside a
    reviewer's patience. Running the first pass immediately is deliberate:
    the boot sequence runs only {!pass_settle} synchronously, so this first
    pass is the boot's one full fold — not a repeat of it. *)
