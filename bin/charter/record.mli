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
    so running it twice is running it once. {!sweep_action} states the
    sweep's law over an identity's receipts: drive it through the pipeline,
    re-enter the publisher, or leave the completed record alone. The
    sweep's own fold interprets it, so the tested statement and the
    executed one are one value. A {e pending} run — a spawned disposition
    with no reaped line ({!Receipt.pending_runs}) — answers [`Done] here:
    its fate belongs to the reconcile's broker watch, whose terminal
    observation drives the honest settle. *)

type fence =
  [ `Free  (** No process holds the run fence — the run is not driven. *)
  | `Held
    (** Some process holds it: the run's activation, or the owner resuming
        the session interactively. A pass never signals a holder — a run
        driver's owner line cannot be told apart from the owner's own
        resume, and killing the owner's session to enforce a budget is a
        worse failure than narrating an open run. *)
  | `Io of string  (** The fence could not be probed. *) ]
(** The type for a run-fence probe's answer — the vocabulary the honest
    settle and the dashboard read a probe in. The fence, never a stored
    pid, is the liveness truth: fences release on holder death, so a free
    fence over a spawned-but-unreaped run means no process anywhere is left
    to write the record's reaped line. *)

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
    fate belongs to the reconcile's broker watch, never to the sweep. *)
