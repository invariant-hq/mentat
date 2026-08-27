(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The child broker: the process half of brokered delegation, and the send.

    One broker per process, shared by every workspace instance that process
    hosts. The engine keeps everything semantic — the durable edge, the child
    document, the capacity permit — and hands this broker a child's identity;
    the broker owns the processes: it spawns the detached per-session server,
    watches the child's feed over its endpoint, reaps exits, re-materializes a
    child that died mid-work, escalates a cancel, and at boot re-adopts the
    parents of orphans a previous process life left running. Every observation
    reports back through the owning engine's {!Engine} seam, and every path
    terminates in either an integrated settlement or a parent-visible
    failure — a parked wait is never abandoned silently.

    The broker is also every process's one way to mail another agent:
    {!val-send} lands an input in a target session's durable queue — over the
    target's socket when a per-session server drives it, by a brief labeled
    fence-held append when it is dormant — and never wakes anything. Waking is
    a separate supervision act.

    Deployment facts are construction arguments: how the activation executable
    resolves, the socket base, the log directory, and the clock all arrive
    through {!create}. The library names no binary of its own and reads no
    ambient environment. The vocabulary both halves of a delegation must agree
    on is exported rather than configured: the socket layout beneath the base
    ({!socket_dir}) and the fence owner labels ({!serve_owner_label},
    {!send_owner_label}).

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

val serve_owner_label : string
(** The run-fence owner label a per-session child server acquires its fence
    under — the serving label a server passes when it stages its instance, and
    the one label this broker reads back from a fence's owner line as
    preemptable: only a same-host holder carrying it is a child server the
    escalation ladder may signal. Any other holder — an interactive driver
    that resumed the child, an unreadable owner line, a foreign host — is
    never preempted. One constant, shared through this library, because the
    two sides must agree or the ladder never fires. *)

val send_owner_label : string
(** The custodial run-fence owner label {!send} appends mail to a dormant
    session under. A custodial hold is a brief labeled hold that releases on
    its own — never a driver — so every fence probe treats it as a transient
    to re-probe shortly, never a holder to preempt or fail over. Exported for
    the same reason as {!serve_owner_label}: the two sides of the fence must
    spell it identically. *)

val serve_mount_owner_label : string
(** Transitional (it dies with the in-process drivers it labels): the serving
    run-fence owner label an in-process driver host — an interactive process,
    or a daemon hosting engines — acquires its fences under while it also
    serves each driven session's derived socket beside the driver. {!send}
    dials a holder carrying it exactly as it dials a per-session child
    server; unlike {!serve_owner_label} it is never preemptable — the holder
    is a live host no escalation ladder may signal. *)

val custodial_label : string -> bool
(** [custodial_label label] is [true] iff [label] is a custodial run-fence
    owner label: {!send_owner_label}, or the store's removal label
    ({!Mentat_store.Run_lock.remove_owner_label}). The one judgment "this
    holder is a brief hold that releases on its own, never a driver", shared
    so every consumer — the broker's own probes and send loop, and a child
    activation's first attach, which retries briefly instead of refusing the
    session — classifies the same labels the same way. *)

(** The engine-reach seam for one workspace instance. *)
module Engine : sig
  type t = {
    root : Lpath.Abs.t;
        (** The canonical workspace root: the spawned child's working
            directory, and the workspace identity of every endpoint
            handshake. *)
    environment : (string * string) list;
        (** The engine's process-environment snapshot, rendered whole as a
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
  (** The type for the broker's reach back into the engine hosting a
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
  now:(unit -> Mentat_session.Time.t) ->
  t
(** [create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now] is a
    broker over the process's one opened [store] and its ambient [stdenv]. Its
    reaper fiber starts under [sw] with the first spawned child — a broker
    that only ever sends runs no fiber at all — and observers fork under [sw]
    as children materialize. The broker stops with {!stop} — its fibers end
    promptly — while the children themselves are deliberately not bound to
    [sw]: a delegated child outlives the process that spawned it.

    The deployment facts: [resolve_bin] resolves the executable a spawn
    launches, and is consulted at each spawn — a resolution failure fails
    that one delegation loudly, never the broker. [socket_base] is the
    per-user directory child endpoints derive under ({!socket_dir}).
    [log_dir] is where a spawned child's stdio log lands, created [0700] on
    first use. [now] stamps the sessions this broker itself commits to — a
    {!send}'s appended mail — the injected clock every library receives
    rather than a clock read of its own. *)

val materialize : t -> Engine.t -> child:Mentat_session.Id.t -> unit
(** [materialize t engine ~child] makes the recorded child run. Idempotent
    per child — a re-drive of a child this broker already runs or observes is
    a no-op — and non-blocking: the probe-spawn-observe work runs on a forked
    fiber. The call carries one identity and nothing else — the child's own
    boot re-derives its delegation edge from its document's lineage backlink
    and re-reads the task and role from that durable edge. A child found
    already fenced by a live per-session server is observed rather than
    re-spawned; a child whose fence holder cannot be identified or signalled
    fails the delegation loudly through [engine]'s seam. *)

val send :
  t ->
  ?origin:Mentat_session.Origin.t ->
  ?budget_s:float ->
  target:Mentat_session.Id.t ->
  id:Mentat_session.Queue.Id.t ->
  input:Mentat_llm.Content.t list ->
  unit ->
  [ `Delivered | `Undelivered of string ]
(** [send t ~target ~id ~input ()] mails [input] to [target] as the queue entry
    [id], attributed to [origin] (absent means the owner sent it,
    {!Mentat_session.Origin}). [`Delivered] means exactly one thing: the
    enqueued fact is durable in [target]'s journal — there is no weaker
    success. Sending never wakes a dormant target; a delivered entry waits for
    whatever next runs the session, and waking is {!materialize} — a distinct
    act by whoever holds supervision authority.

    Delivery is one bounded fence-first loop decided by the fence owner's
    label. Acquiring the fence under {!send_owner_label} is itself the
    liveness probe: acquired, the entry is admitted exactly as the target's
    own driver would admit it — the recorded-enqueue dedup, the admit
    judgment ({!Mentat_session.admits_mail}: the sender's standing and its
    unconsumed backlog both), the committed fact — and
    released. A fence held under a serving label — a per-session child
    server's, or a live host's serve-mount — is dialable: the entry crosses
    its socket as a queue command on a short-lived
    connection, and the driver's dedup makes redelivery idempotent. A fence
    held under another custodial label is a transient, re-probed on a short
    backoff, never dialed and never preempted. The loop is symmetric — a
    holder that exits mid-pass is caught by the next pass's acquire — and
    [budget_s] (default: the grace bound; a supervisor delivering as part of
    a wake may pass more) bounds the whole loop in wall time, a single wire
    dial capped at what remains of it: spent with nothing delivered, the
    answer is [`Undelivered] with the reason, against the sender's own
    durable record.

    {b Ordering is this primitive's contract.} Sends to one target are
    serviced one at a time, in arrival order: the delivery loop runs under a
    per-target ordering lock whose waiters are served FIFO, so a caller that
    issues two sends to one target in sequence knows they land in that order
    with no discipline of its own — per-sender FIFO holds for every caller.
    The wait for the lock spends the sender's own [budget_s]; a budget spent
    entirely behind earlier sends is an [`Undelivered] like any other.

    [id] is the sender's derived idempotency key: the same send retried lands
    the same entry once (at-least-once mechanics, exactly-once effect).
    [input] must not carry inline or referenced media — inline bytes would
    enter the journal unexternalized, and a content reference names the
    sender's namespace, not the target's; such a send is refused loudly. *)

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
  engine_for:(root:string -> (Engine.t * (unit -> unit), string) result) ->
  unit
(** [rediscover t ~engine_for] is the boot orphan sweep, run before serving.
    Candidates come from two sources, because neither alone sees every
    orphan: the per-session endpoint directories left under the socket tree
    (a digest leaf cannot be inverted, so leaves resolve against the store's
    session index), and every delegated child session whose run fence is held
    (a live child whose endpoint directory was lost). For each candidate the
    pure {!Reconcile.boot_action} table decides: an unfinished child —
    running or dead — has its parent adopted through [engine_for]'s engine,
    whose recovery re-drives the edge into {!materialize} (the single
    probe-and-spawn path); a live child is additionally watched, so its exit
    re-drives whatever its held fence shadowed; a settled child with a
    still-waiting parent is adopted so the buffered result wakes the wait; a
    settled or vanished child nobody waits for has its stale endpoint
    directory removed and nothing else — leftover directories after a forced
    kill are expected. [engine_for ~root] stages the engine hosting the
    workspace at [root] and pairs it with the release of whatever lease the
    staging took; the sweep calls that release exactly once, after the
    candidate's action has been issued. Failures are logged and skip the
    candidate; they never abort the sweep or the boot. *)

val stop : t -> unit
(** [stop t] ends the broker's fibers promptly: the reaper exits, observers
    are released, and no further materialization is accepted. Running children
    are left running — their journals are durable and a successor process's
    {!rediscover} re-adopts them. Idempotent. *)

val for_tests :
  send:
    (origin:Mentat_session.Origin.t option ->
    target:Mentat_session.Id.t ->
    id:Mentat_session.Queue.Id.t ->
    input:Mentat_llm.Content.t list ->
    [ `Delivered | `Undelivered of string ]) ->
  t
(** [for_tests ~send] is a mocked broker for unit-tier tests of the engines
    that hold one: {!val-send}'s fence, append, and dial effects are replaced
    by the given function, which answers the outcome the test scripts and may
    record what crossed. The stub keeps the real send's per-target
    serialization — concurrent sends to one target reach the given function
    one at a time, in arrival order — so ordering-sensitive tests observe the
    primitive's contract. Every process-facing operation — {!materialize},
    {!cancel}, {!rediscover} — raises [Invalid_argument]: the stub performs no
    process work, and a test that reaches one of those has wired the wrong
    seam. *)
