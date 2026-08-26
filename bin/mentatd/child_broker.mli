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
    released by death.

    {b Reaper discipline.} The reaper fiber never suspends: its sweep clears
    a reaped pid in the same non-suspending step that observes the exit, and
    each exit's settlement — integration, or a bounded re-materialization —
    runs on its own forked fiber whose guard routes an unexpected raise to a
    loud parent-visible failure. The reaper can therefore never be captive to
    a successor child's lifetime, and no raise mid-batch can silently park
    the remaining exited delegations. The pure decision tables live in
    {!Reconcile}. *)

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
    delegation loudly through the engine seam. [deliver] submits a
    parent-recorded message over the held child's endpoint on short-lived,
    grace-bounded connections — retrying a booting child's endpoint within the
    boot budget, answering [`Gone] for a child this broker no longer holds —
    and never follows the feed or pins the child's connection count. [cancel]
    delivers the semantic interrupt over the child's endpoint first and
    escalates — SIGTERM, a bounded grace, SIGKILL, to the child's own process
    only, never a process group — when the child cannot hear it; a cancelled
    child re-materialized after a kill is spawned with the interrupt intent
    carried, so its successor mints the terminal interrupted fact instead of
    resuming the cancelled work. *)

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
