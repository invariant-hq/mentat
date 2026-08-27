(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The reconcile fold over a charter record — the decisions a pass owes
    one event identity, as pure tables over probe thunks, so
    the full tables are unit-testable with no store, fence, or child behind
    them.

    A charter's record is its receipt log plus the per-session run fence;
    the fold holds no state of its own and reads both fresh on every pass,
    so running it twice is running it once. Its unit of judgment is one
    event identity's record, split across two tables:

    - {!run_action} judges a {e pending} run — a spawned disposition with
      no reaped line ({!Receipt.pending_runs}), the record left behind
      whenever the reaping process is stopped, killed, or crashes while a
      run child lives. The row is total: free, held, and unprobeable
      fences each have a decision, so the process driving the pipeline may
      be cancelled at any instant and the next pass settles whatever was
      left open.
    - {!sweep_action} states the sweep's law over an identity's receipts:
      drive it through the pipeline, re-enter the publisher, or leave the
      completed record alone. The sweep's own fold interprets it, so the
      tested statement and the executed one are one value. *)

type fence =
  [ `Free  (** No process holds the run fence — the child is gone. *)
  | `Held
    (** Some process holds it: the run child, or the owner resuming the
        session interactively. A pass never signals a holder — a run
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
        the record owes its one honest reaped line. *)
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
