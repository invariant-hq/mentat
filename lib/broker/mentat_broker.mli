(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The child broker: the process half of brokered delegation.

    One broker per process, shared by every workspace instance that process
    hosts. The engine keeps everything semantic — the durable edge, the child
    document, the capacity permit — and hands this broker a child's identity;
    the broker owns the processes: it spawns the detached per-session server,
    watches the child's feed over its endpoint, reaps exits, re-materializes a
    child that died mid-work, escalates a cancel, and at boot re-adopts the
    parents of orphans a previous process life left running. Every observation
    reports back through the owning instance's {!Instance} seam, and every
    path terminates in either an integrated settlement or a parent-visible
    failure — a parked wait is never abandoned silently.

    Deployment facts are construction arguments: how the activation executable
    resolves, the socket base, the log directory, and the fence label a
    per-session server acquires under all arrive through {!create}. The
    library names no binary of its own and reads no ambient environment.

    Two honest floors, by design: a child whose journal never settles (a
    corrupt store, a wedged callback) is observed for as long as its fence is
    held — stopping it is {!cancel}'s escalation, not a broker timeout; and
    the final rung of that escalation kills only the child's own process, so
    tool descendants the child could not stop may survive it, exactly as the
    engine's honesty laws state for any fence released by death.

    {b Reaper discipline.} The reaper fiber never suspends: its sweep clears
    a reaped pid in the same non-suspending step that observes the exit, and
    each exit's settlement — integration, or a bounded re-materialization —
    runs on its own forked fiber whose guard routes an unexpected raise to a
    loud parent-visible failure. The reaper can therefore never be captive to
    a successor child's lifetime, and no raise mid-batch can silently park
    the remaining exited delegations. The pure decision tables live in
    {!Reconcile}. *)

module Reconcile = Reconcile
(** The pure reconciliation tables the broker's fibers interpret. *)

val socket_dir : base:string -> session:string -> string
(** [socket_dir ~base ~session] is the directory a per-session child server
    binds its socket in: [s/<leaf>] under [base]. The [session] id is admitted
    verbatim as the leaf only when it is short (at most 40 bytes),
    filename-plain, and not dot-led; anything else is keyed to a 16-character
    digest. Both forms are pure functions of the id, and both keep the socket
    path inside the [sun_path] budget for any [base] that respects it. *)

(** The engine-reach seam for one workspace instance. *)
module Instance : sig
  type t = {
    root : Lpath.Abs.t;
        (** The canonical workspace root: the spawned child's working
            directory, and the workspace identity of every endpoint
            handshake. *)
    environment : (string * string) list;
        (** The instance's process-environment snapshot, rendered whole as a
            spawned child's environment — the child's own composition
            re-resolves everything else from it. *)
    adopt_session :
      Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
        (** Attach a session's driver with no accompanying command — fence,
            load, recovery to quiescence. {!rediscover}'s verb for re-adopting
            the parent of an orphaned child: recovery reconstructs the parked
            wait and re-drives unfinished edges into {!materialize}. *)
    integrate_child :
      child:Mentat_session.Id.t -> [ `Integrated | `Not_settled | `Unbound ];
        (** Fold [child]'s journal-settled result into its parent's scheduler
            and wake the parked wait. [`Unbound] when the hosting engine holds
            no parent binding — the journals still integrate at the parent's
            next attach. *)
    fail_child : child:Mentat_session.Id.t -> message:string -> unit;
        (** Settle the parent's wait for [child] with a spawn-failure carrying
            [message] — the loud floor for a child the broker has
            abandoned. *)
  }
  (** The type for the broker's reach back into the process hosting a
      delegation: the workspace identity a child is spawned and dialed under,
      and the engine wrappers every observation reports through. The broker
      only ever holds the record it was handed; it never builds one. *)
end

type t
(** The type for a process's child broker: the child table, the reaper, and
    the observers, under the process's switch. *)

val create :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  store:Mentat_store.t ->
  resolve_bin:(unit -> (string, string) result) ->
  socket_base:string ->
  log_dir:string ->
  serve_owner_label:string ->
  t
(** [create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir
    ~serve_owner_label] is a broker over the process's one opened [store] and
    its ambient [stdenv]. Its reaper fiber starts under [sw] immediately;
    observers fork under [sw] as children materialize. The broker stops with
    {!stop} — its fibers end promptly — while the children themselves are
    deliberately not bound to [sw]: a delegated child outlives the process
    that spawned it.

    The deployment facts: [resolve_bin] resolves the executable a spawn
    launches, and is consulted at each spawn — a resolution failure fails
    that one delegation loudly, never the broker. [socket_base] is the
    per-user directory child endpoints derive under ({!socket_dir}).
    [log_dir] is where a spawned child's stdio log lands, created [0700] on
    first use. [serve_owner_label] is the run-fence owner label a per-session
    child server acquires under — the only label the escalation ladder may
    signal; any other holder (an interactive driver that resumed the child,
    an unreadable owner line, a foreign host) is never preempted. *)

val materialize : t -> Instance.t -> child:Mentat_session.Id.t -> unit
(** [materialize t instance ~child] makes the recorded child run. Idempotent
    per child — a re-drive of a child this broker already runs or observes is
    a no-op — and non-blocking: the probe-spawn-observe work runs on a forked
    fiber. The call carries one identity and nothing else — the child's own
    boot re-derives its delegation edge from its document's lineage backlink
    and re-reads the task and role from that durable edge. A child found
    already fenced by a live per-session server is observed rather than
    re-spawned; a child whose fence holder cannot be identified or signalled
    fails the delegation loudly through [instance]'s seam. *)

val deliver :
  t ->
  command:Mentat_protocol.Command.t ->
  [ `Delivered | `Refused | `Gone ]
(** [deliver t ~command] submits [command] — a parent-recorded message,
    already carrying its derived idempotency id — to the live child the
    command's own session id names, over short-lived, grace-bounded
    connections that never follow the feed or pin the child's connection
    count. Blocking, but bounded: a child whose materialized process has not
    yet bound its endpoint is retried within the boot budget. [`Delivered]
    means the child durably admitted the command; the ids it carries make a
    repeat delivery idempotent. [`Refused] means the child answered and
    refused (a busy child refusing an immediate turn), or could not be
    reached within the budget — the caller decides whether a refusal has a
    fallback, and an undeliverable message stays covered by the parent's
    durable receipt. [`Gone] means the broker holds no materialization for
    the child — delivery is the caller's own in-process story. *)

val cancel : t -> child:Mentat_session.Id.t -> unit
(** [cancel t ~child] asks the broker to stop [child]'s work: the semantic
    interrupt delivered over the child's endpoint first, then an escalation —
    SIGTERM, a bounded grace, SIGKILL, to the child's own process only, never
    a process group — when the child cannot hear it. A cancelled child
    re-materialized after a kill is spawned with the interrupt intent
    carried, so its successor mints the terminal interrupted fact instead of
    resuming the cancelled work. Non-blocking; completion is observed through
    the child's journal, not through this call. *)

val rediscover :
  t ->
  instance_for:(root:string -> (Instance.t, string) result) ->
  release:(Instance.t -> unit) ->
  unit
(** [rediscover t ~instance_for ~release] is the boot orphan sweep, run
    before serving. Candidates come from two sources, because neither alone
    sees every orphan: the per-session endpoint directories left under the
    socket tree (a digest leaf cannot be inverted, so leaves resolve against
    the store's session index), and every delegated child session whose run
    fence is held (a live child whose endpoint directory was lost). For each
    candidate the pure {!Reconcile.boot_action} table decides: an unfinished
    child — running or dead — has its parent adopted through [instance_for]'s
    instance, whose recovery re-drives the edge into {!materialize} (the
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
    are left running — their journals are durable and a successor process's
    {!rediscover} re-adopts them. Idempotent. *)
