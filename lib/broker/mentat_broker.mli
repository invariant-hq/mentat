(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The child broker: the process half of brokered delegation, root
    supervision, and the send.

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

    {!val-supervise} is the same machinery with a root shape: a session with
    no delegation edge — a charter run, any owned root — is made to run and
    observed to its conclusion, and the outcome lands in the caller's own
    sinks instead of an engine seam. {!val-watch} observes a session without
    owning it, and {!val-children} is the supervised table as data.

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

(** The type for supervision failures. The arm, not its prose, is the
    contract: a caller that classifies an outcome matches the arm, and
    {!failure_message} renders the one diagnostic wording. *)
type failure =
  | Deadline of float
      (** The supervision's one clock ([deadline_s], in seconds) fired and
          the escalation ladder ended whatever still ran. *)
  | Gave_up of string
      (** Respawn exhaustion, a refusal, or an unreachable holder; the
          reason is diagnostic prose. *)

type failure_sink = failure -> unit
(** The type for the place a given-up supervision's failure lands. Every
    {!val-supervise} names its sink, so a silent failure arm is
    unrepresentable: exhaustion, the deadline, and every refusal all end
    here when they do not end in the settled callback. *)

val failure_message : failure -> string
(** [failure_message failure] is the one diagnostic wording for [failure] —
    what the broker's own traces print, and what a caller narrates. *)

val supervise :
  t ->
  session:Mentat_session.Id.t ->
  environment:(string * string) list ->
  ?deadline_s:float ->
  ?respawns:int ->
  on_settled:(unit -> unit) ->
  on_failure:failure_sink ->
  unit ->
  [ `Supervising | `Already_governed | `Stopped ]
(** [supervise t ~session ~environment ~on_settled ~on_failure ()] makes
    the root session [session] run to its conclusion. [`Supervising]: this
    call owns the outcome and answers exactly one of the two sinks, exactly
    once. [`Already_governed]: an entry — delegated or root — already
    governs the session and owns the outcome; this call's sinks never
    fire — observe with {!watch} instead. [`Stopped]: the broker accepts no
    further supervision and this call's sinks never fire; a successor
    process supervises afresh.

    The activation's working directory is the session's recorded cwd, read
    from the session document exactly as the send's dial reads it — the
    store, not the caller, owns that fact, and the activation's own boot
    asserts it again. A document that cannot be read fails the supervision
    loudly through [on_failure]. [environment] is rendered whole as a
    spawned activation's environment. Non-blocking: the probe-spawn-observe
    work runs on forked fibers.

    The fence decides, through the one owner classification the send loop
    uses: a holder serving the session's endpoint is adopted and observed to
    its conclusion; a custodial hold is a transient, re-probed briefly; a
    free fence over unfinished work — an unfinished head {e or} unconsumed
    queue entries — spawns the activation, so mail must be sent before
    supervising (the activation holds a workless virgin root open
    indefinitely); a free fence over concluded work answers [on_settled]
    directly; a same-host child server holding the fence but serving no
    endpoint is escalated and replaced. A holder that is none of these — an
    interactive driver, an unreadable owner line, a foreign host — is never
    signalled: it is observed for a bounded patience, settling if the head
    concludes under it, and past the bound the supervision fails naming the
    holder.

    [on_settled] fires on a head-and-queue read — the session's work is
    concluded — never on an exit code, and possibly while a serving holder
    still lingers. A spawned activation that dies unsettled is respawned at
    most [respawns] times (default 2; a caller whose runs must not re-fire
    passes 0); exhaustion fires [on_failure]. [deadline_s], when given, is
    the supervision's one clock: at its firing the escalation ladder — the
    wire interrupt, a grace, then the signals, against an own process or a
    same-host child server only — ends whatever still runs, and the outcome
    is [on_failure] with {!failure.Deadline} (a head found already terminal
    at the firing settles instead). Without a deadline, a serving holder
    that never concludes is observed for as long as it holds the fence. *)

val watch :
  t ->
  session:Mentat_session.Id.t ->
  on_terminal:([ `Settled | `Holder_died | `Gone ] -> unit) ->
  unit
(** [watch t ~session ~on_terminal] observes [session] without owning it —
    the run fence and the journal head on a poll, holding no table entry, no
    fence, and no connection — and fires [on_terminal] once with the terminal
    observation: [`Settled] when the head-and-queue read concludes (whether
    or not a holder lingers), [`Holder_died] when the fence is free with work
    outstanding — whoever ran the session stopped without settling it, or
    nothing runs it at all — and [`Gone] when the session document no longer
    exists. A held fence keeps the watch alive, whatever the label: a watch
    never signals, never spawns, and never preempts, so a holder that never
    concludes is watched for as long as it holds. Watches end, without
    firing, when the broker stops. *)

val children :
  t ->
  (Mentat_session.Id.t * [ `Spawned of int | `Observed | `Laddering ]) list
(** [children t] is the supervised table as data, one row per session this
    broker currently runs or observes — delegated and root alike:
    [`Spawned pid] for a process this broker spawned and reaps, [`Observed]
    for a session watched through its fence and endpoint, [`Laddering] while
    a cancel escalation is in flight. A read-only snapshot; rows leave the
    table as their sessions settle or are abandoned. *)

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
  ?supervise:
    (session:Mentat_session.Id.t ->
    environment:(string * string) list ->
    deadline_s:float option ->
    respawns:int ->
    [ `Settled | `Failed of failure ]) ->
  send:
    (origin:Mentat_session.Origin.t option ->
    target:Mentat_session.Id.t ->
    id:Mentat_session.Queue.Id.t ->
    input:Mentat_llm.Content.t list ->
    [ `Delivered | `Undelivered of string ]) ->
  unit ->
  t
(** [for_tests ~send ()] is a mocked broker for unit-tier tests of the engines
    and callers that hold one: {!val-send}'s fence, append, and dial effects
    are replaced by the given function, which answers the outcome the test
    scripts and may record what crossed. The stub keeps the real send's
    per-target serialization — concurrent sends to one target reach the given
    function one at a time, in arrival order — so ordering-sensitive tests
    observe the primitive's contract.

    [supervise], when given, scripts {!val-supervise}: each call hands the
    full supervision request to the script, fires exactly one of the
    caller's sinks with its answer, and returns [`Supervising] — the real
    verb's outcome contract. The stub holds no table, so a re-supervision
    reaches the script again, exactly as the real broker re-governs a
    session whose previous supervision has drained. {!val-children} answers
    the empty list: the stub supervises no process.

    Every process-facing operation left unstubbed — {!materialize},
    {!val-watch}, {!cancel}, {!rediscover}, and {!val-supervise} without a
    script — raises [Invalid_argument]: the stub performs no process work,
    and a test that reaches one of those has wired the wrong seam. *)
