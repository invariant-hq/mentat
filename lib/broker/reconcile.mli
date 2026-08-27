(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The child broker's pure reconciliation tables — every process-level
    decision the broker makes, expressed over probe thunks so the full tables
    are unit-testable with no process, socket, or store behind them. The
    broker's fibers interpret the decisions; nothing here performs an
    effect. *)

type fence =
  [ `Free  (** No process holds the child's run fence. *)
  | `Held_self
    (** This process holds it — an in-process driver is the materialization;
        the broker stands down. *)
  | `Held of int option
    (** Another process holds it; [Some pid] iff the owner line names a
        same-host per-session child server the escalation ladder may signal.
        Any other holder — an interactive CLI that resumed the child, an
        unreadable owner line, a foreign host — is [None] and is never
        preempted. *)
  | `Custodial
    (** A brief labeled custodial hold — a send appending mail, the store
        removing the session — that releases on its own within moments. Never
        a driver: the probe re-fires shortly rather than preempting or
        failing. *)
  | `Io of string  (** The fence could not be probed. *) ]
(** The type for a fence probe's answer, in the table's vocabulary — the probe
    owns identity mapping (host comparison, self-detection, the owner labels),
    the table owns the decision. *)

type head =
  [ `Unfinished
    (** No turn yet, an active turn, or an unreadable journal — work is (or
        must be presumed) outstanding. *)
  | `Terminal  (** The last turn settled and nothing is active. *)
  | `Absent  (** No session document exists. *) ]
(** The type for a child journal head's summary. *)

type action =
  | Observe  (** A live server holds the fence: watch it, spawn nothing. *)
  | Preempt of int
      (** A same-host child server holds the fence but serves no endpoint:
          ladder [pid], then spawn. *)
  | Respawn  (** The fence is free and work is outstanding: spawn. *)
  | Dispose
      (** The fence is free and nothing is outstanding: integrate from the
          journal and clear the residue — no process needed. *)
  | Stand_down
      (** This process already drives the child in-process; the broker has no
          role. *)
  | Reprobe
      (** A custodial hold is in flight: re-run the table after a short
          backoff — never preempt it, never fail over it. *)
  | Fail of string
      (** No safe move exists (an unprobeable fence, a holder the broker may
          not preempt): fail the delegation loudly. *)
(** The type for the materialization decision. *)

val decide :
  fence:(unit -> fence) ->
  reachable:(unit -> bool) ->
  head:(unit -> head) ->
  action
(** [decide ~fence ~reachable ~head] is the materialization table over lazy
    probes — [reachable] (the endpoint answers a handshake) is consulted only
    under a foreign-held fence, [head] only under a free one, so a probe is
    never spent on an arm that cannot use it. *)

type boot =
  [ `Adopt
    (** The fence is free and work is outstanding: adopt the parent, whose
        recovery re-drives the edge into the ordinary materialize. *)
  | `Adopt_and_watch
    (** A live child whose parent still waits: adopt the parent so its
        settlement has a waker, and watch the child so its exit re-drives
        anything its fence shadowed. *)
  | `Watch
    (** A live child nobody waits for: watch it without touching its idle
        parent — adoption would pin a fence no one asked this node to hold. *)
  | `Adopt_and_dispose
    (** A settled child whose parent still waits: adopt the parent (the
        buffered result wakes it) and remove the stale endpoint directory. *)
  | `Dispose
    (** A settled or vanished child nobody waits for: remove the stale
        endpoint directory and nothing else. *)
  | `Skip of string
    (** Leave the candidate untouched for the stated reason. *) ]
(** The type for the node-boot decision for one rediscovered candidate. *)

val boot_action :
  fence:[ `Free | `Held | `Io ] ->
  head:head ->
  parent:[ `Waiting | `Idle | `Absent ] ->
  boot
(** [boot_action ~fence ~head ~parent] is the rediscovery table. [parent]
    summarizes the parent journal's head: [`Waiting] iff it holds an active
    turn (its wait may be parked in it), [`Absent] when no parent document
    resolves — an orphan with no parent integrates nowhere and is skipped
    loudly rather than re-driven. *)
