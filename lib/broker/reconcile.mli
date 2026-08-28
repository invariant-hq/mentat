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

type root_action =
  | Adopt
      (** A holder serves the session's endpoint: observe it, spawn
          nothing. *)
  | Preempt_stale of int
      (** A same-host child server holds the fence but serves no endpoint:
          ladder [pid], then spawn. *)
  | Spawn  (** The fence is free and work is outstanding: spawn. *)
  | Settle
      (** The fence is free and the work is concluded: answer the settled
          sink directly — no process needed. *)
  | Reprobe_hold
      (** A custodial hold is in flight: re-run the table after a short
          backoff — never preempt it, never fail over it. *)
  | Hold
      (** An unpreemptable holder — unlabeled, foreign-host, self-held, or a
          serving label with a dead endpoint that may not be signalled — sits
          on the fence over outstanding work. The interpreter observes it for
          a bounded patience, settling early if the head concludes, and past
          the bound fails loudly naming the holder. Never a signal. *)
  | Refuse of string
      (** No safe move exists (an unprobeable fence, a missing session):
          refuse the supervision loudly. *)
(** The type for the root-supervision decision. *)

val supervise_action :
  fence:(unit -> fence) ->
  reachable:(unit -> bool) ->
  head:(unit -> head) ->
  root_action
(** [supervise_action ~fence ~reachable ~head] is the root-supervision table
    over the same lazy probes as {!decide}, differing on the arms the two
    verbs must rule differently: a holder the supervisor may neither adopt
    nor preempt is [Hold] — a bounded observation, never the delegated
    table's immediate failure — because an interactive driver may settle the
    work under the supervisor's watch; a free fence over a missing session is
    [Refuse], because settling a session that does not exist would lie to the
    caller's sink. [`Held_self] takes the [Hold] arm: whatever holds the
    fence, this table never rules a signal against a holder that is not a
    stale same-host child server. *)
