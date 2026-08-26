(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The daemon's child broker: the process half of brokered delegation.

    One broker per node, shared by every workspace instance. The engine keeps
    everything semantic — the durable edge, the child document, the capacity
    permit — and hands this broker a child's identity; the broker owns the
    processes: it spawns the detached per-session server, watches the child's
    feed over its endpoint, reaps exits, re-materializes a child that died
    mid-work, escalates a cancel, and at node boot re-adopts the parents of
    orphans a previous node life left running. Every observation reports back
    through the owning instance's engine seam, and every path terminates in
    either an integrated settlement or a parent-visible failure — a parked
    wait is never abandoned silently.

    Two honest floors, by design: a child whose journal never settles (a
    corrupt store, a wedged callback) is observed for as long as its fence is
    held — stopping it is {!Mentat_agent.Ports.child_ops.cancel}'s escalation,
    not a broker timeout; and the final rung of that escalation kills only the
    child's own process, so tool descendants the child could not stop may
    survive it, exactly as the engine's honesty laws state for any fence
    released by death. *)

type t
(** The type for a node's child broker: the child table, the reaper, and the
    observers, under the node's switch. *)

val create : sw:Eio.Switch.t -> Composition.shared -> t
(** [create ~sw shared] is a broker over the node's [shared] state (its store
    handle, user directories, and stdenv). Its reaper fiber starts under [sw]
    immediately; observers fork under [sw] as children materialize. The broker
    stops with {!stop} — its fibers end promptly — while the children
    themselves are deliberately not bound to [sw]: a delegated child outlives
    the node that spawned it. *)

val ops : t -> Composition.t -> Mentat_agent.Ports.child_ops
(** [ops t instance] is the ops record [instance]'s engine consumes for its
    brokered children. [materialize] is idempotent per child — a re-drive of a
    child this broker already runs or observes is a no-op — and non-blocking:
    the probe-spawn-observe work runs on a forked fiber. A child found already
    fenced by a live per-session server is observed rather than re-spawned; a
    child whose fence holder cannot be identified or signalled fails the
    delegation loudly through the engine seam. [cancel] delivers the semantic
    interrupt over the child's endpoint first and escalates — SIGTERM, a
    bounded grace, SIGKILL, to the child's own process only, never a process
    group — when the child cannot hear it. *)

val rediscover :
  t ->
  instance_for:(root:string -> (Composition.t, string) result) ->
  release:(Composition.t -> unit) ->
  unit
(** [rediscover t ~instance_for ~release] is the node-boot orphan sweep, run
    before serving. Candidates come from two sources, because neither alone
    sees every orphan: the per-session endpoint directories left under the
    socket tree (a digest leaf cannot be inverted, so leaves resolve against
    the store's session index), and every delegated child session whose run
    fence is held (a live child whose endpoint directory was lost). For each
    candidate the pure {!Reconcile.boot_action} table decides: an unfinished
    child — running or dead — has its parent adopted through [instance_for]'s
    instance, whose recovery re-drives the edge into {!ops}'s materialize (the
    single probe-and-spawn path); a live child is additionally watched, so its
    exit re-drives whatever its held fence shadowed; a settled child with a
    still-waiting parent is adopted so the buffered result wakes the wait; a
    settled or vanished child nobody waits for has its stale endpoint
    directory removed and nothing else — leftover directories after a forced
    kill are expected. [release] returns the instance reference [instance_for]
    took once the candidate's action has been issued. Failures are logged and
    skip the candidate; they never abort the sweep or the boot. *)

val stop : t -> unit
(** [stop t] ends the broker's fibers promptly: the reaper exits, observers
    are released, and no further materialization is accepted. Running children
    are left running — their journals are durable and a successor node's
    {!rediscover} re-adopts them. Idempotent. *)

(** The pure reconciliation tables — every process-level decision the broker
    makes, expressed over probe thunks so the full tables are unit-testable
    with no process, socket, or store behind them. *)
module Reconcile : sig
  type fence =
    [ `Free  (** No process holds the child's run fence. *)
    | `Held_self
      (** This process holds it — an in-process driver is the
          materialization; the broker stands down. *)
    | `Held of int option
      (** Another process holds it; [Some pid] iff the owner line names a
          same-host process a signal from here can reach. *)
    | `Io of string  (** The fence could not be probed. *) ]
  (** The type for a fence probe's answer, in the table's vocabulary — the
      probe owns identity mapping (host comparison, self-detection), the table
      owns the decision. *)

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
        (** A same-host process holds the fence but serves no endpoint:
            ladder [pid], then spawn. *)
    | Respawn  (** The fence is free and work is outstanding: spawn. *)
    | Dispose  (** The fence is free and nothing is outstanding. *)
    | Stand_down
        (** This process already drives the child in-process; the broker has
            no role. *)
    | Fail of string
        (** No safe move exists (an unprobeable fence, an unidentifiable
            holder): fail the delegation loudly. *)
  (** The type for the materialization decision. *)

  val decide :
    fence:(unit -> fence) ->
    reachable:(unit -> bool) ->
    head:(unit -> head) ->
    action
  (** [decide ~fence ~reachable ~head] is the materialization table over lazy
      probes — [reachable] (the endpoint answers a handshake) is consulted
      only under a foreign-held fence, [head] only under a free one, so a
      probe is never spent on an arm that cannot use it. *)

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
          parent — adoption would pin a fence no one asked this node to hold.
      *)
    | `Adopt_and_dispose
      (** A settled child whose parent still waits: adopt the parent (the
          buffered result wakes it) and remove the stale endpoint directory.
      *)
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
end
