(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The engine — the one effectful side of [mentat.agent].

    The engine drives sessions through the pure step: every transition is
    computed by the private effect-free step unit and committed before its
    single claimed effect runs. Public users see three concepts — {!type:t},
    {!Catalog.t}, {!Error.t} — and then take the client-facing {!driver}. The
    engine owns exactly this: the catalog (re-exposed from the step unit, where
    its validation and dispatch are pure), the scheduler (subagents as
    eagerly-driven sibling sessions behind immutable delegation edges, with an
    atomic capacity permit and no sidecar ledger), the driver (one controller
    fiber per session obeying the operational law — commit one transition,
    perform at most one claimed effect, settle it under bounded cancellation
    protection, advance outside protection), and the single-writer fence (one
    driver per session, acquired at first admission, held across turns).

    Resources reach the engine only through the three {!Ports} — this library
    links no store backend, no provider transport, no filesystem library, no UI.
    The engine never parses configuration, performs credential IO, or prompts
    for trust: context arrives as sealed data ({!Config.t}), notices drain
    through the workspace port.

    {b The honesty laws.} Crash-time recovery is the sole minter of an
    [Ambiguous] settlement for a claim a dead process left open, and a live
    callback exception also settles [Ambiguous] — an exception does not prove
    the callback produced no effects. Fence release never proves effect
    quiescence: workspace cleanup signals a cancelled tool's process group but
    reaps only the process, so a descendant that left that group or outlived the
    signal may survive it, and recovery treats an open workspace claim as
    possibly still mutating. A tool's [Returned] outcome proves only that its
    callback returned and an [Interrupted] one that its worker scope closed;
    neither proves a spawned tree exited. {!shutdown} is stop admission, cancel
    active effects and child waits, then await quiescence — it may block forever
    on a callback that ignores cancellation, and process death is the
    escalation: the OS releases the fence and the successor's recovery mints the
    [Ambiguous] the live process honestly could not. An already parked human
    decision is quiescent durable state, so shutdown preserves it for a
    successor rather than interpreting process lifetime as a user interrupt.

    The engine fills the session half of the client's construction seam:
    {!driver} returns the {!Mentat_client.Driver.Session.t} whose field closures
    submit commands, follow pull feeds of {!Mentat_protocol.Update.t} values,
    run the fenced fork/rewind/compact flows, and serve the session-scoped
    queries. Frontends never hold it — the executable's composition root
    assembles the full {!Mentat_client.Driver.t} from this value plus its own
    account/settings/lifecycle responders and hands frontends the resulting
    {!Mentat_client.t}. *)

module Catalog = Mentat_agent_step.Catalog
(** The one dispatch surface — the validated executable tool set plus the exact
    engine verbs supplied by its caller. *)

module Config = Config
(** Resolved per-session engine configuration, sealed by the executable. *)

module Ports = Ports
(** The store interface, provider function, and workspace capability value — the
    engine's whole reach into the world. *)

module Execution = Execution
(** The per-turn execution selection an execution callback returns: catalog,
    workspace, policy, and the model-visible context prelude, sealed together.
*)

module Error = Error
(** Structured engine errors. *)

(** {1:agents Agents} *)

type t
(** The type for the process runtime: the driver registry, the scheduler, and
    the client bridge, under one switch. *)

val create :
  sw:Eio.Switch.t ->
  store:(module Ports.STORE) ->
  provider:Ports.provider_call ->
  config:
    (Mentat_session.Id.t ->
    latest_model:Mentat_llm.Model.t option ->
    (Config.t, Mentat_diagnostic.t) result) ->
  now:(unit -> Mentat_session.Time.t) ->
  ?max_children:int ->
  ?child_backend:Ports.child_backend ->
  execution_for_mode:Execution.factory ->
  delegated_execution:Execution.delegated_factory ->
  unit ->
  t
(** [create ~sw ~store ~provider ~config ~now ~execution_for_mode
     ~delegated_execution ()] is the process runtime. Drivers run as sibling
    fibers under [sw]. [config] runs at each turn boundary — settings changes
    take effect at the next turn. It receives [latest_model], the session's most
    recently started model as recorded in its own journal, so the executable can
    prefer that durable per-session fact over a global default when no
    process-local override applies. [now] is the injected clock for the session
    values the engine itself constructs (children, fork and rewind targets); the
    engine reads no clock. [execution_for_mode] is a factory: the driver applies
    it to its own nested per-session switch ([~background]) once, yielding a
    pair — a per-turn selector and a live background-process view (backing
    {!Mentat_client.running_processes}). The selector, at each new turn,
    [~configured ~model:configured.model ~sealed_declarations:None mode],
    receives the freshly resolved per-session configuration and selects the
    exact root-session {!Execution.t} — catalog, workspace port, effective
    policy, and model-visible context prelude — as one value. The executable
    builds any session-scoped runtime resource its catalog needs (a
    background-process registry) over [~background], so it is created once,
    shared by the selector and the view, and dies with the session's switch.
    Recovery passes the sealed contract's [model] and [sealed_declarations];
    they remain authoritative if configuration or host facts changed after
    admission. [delegated_execution] is the same kind of factory for a delegated
    session, applied to the child driver's own [~background] switch. Its [role]
    is the child's {!Mentat_session.Delegation.Role.t option}, resolved from the
    immutable edge and fixed for the child's lifetime, and it decides the
    child's authority: a roleless (generic) delegate is a peer of a root Build
    session — the same write-capable catalog, sealed workspace capability, and
    configured permission policy, over its own per-child background-process
    registry — while a role delegate (explore/review/verify) is a read-only
    specialist with its subagent prompt slotted into the delegated prelude and
    an empty background-process view. Independently attached children verify
    their metadata backlink against the parent delegation edge before a driver
    is created. [max_children] bounds the scheduler's tree-wide capacity permit
    (default [4]). [child_backend] names where a delegated child session
    materializes once its edge and document are durable
    ({!Ports.child_backend}, default {!Ports.In_process}): under [In_process]
    the runtime attaches the child as a sibling driver and submits its
    deterministic first turn ({!child_first_turn}) itself; the [Brokered] arm
    is the reserved seam for an executable-owned broker, and this runtime does
    not consume it — [create] refuses it with [Invalid_argument] at
    construction, before any durable edge exists. A broker implementation must
    replace that refusal with a real materialization rather than inherit it: a
    raise deferred to delegation time would re-fire on every recovery re-drive
    of a durable edge, wedging attachment.

    Raises [Invalid_argument] on [child_backend = Brokered _]. *)

val child_first_turn :
  Mentat_session.Delegation.Id.t -> Mentat_session.Turn.Id.t
(** [child_first_turn delegation] is the deterministic id of a delegated
    child's first turn: a keyed digest over [delegation] alone. It is the one
    cross-backend mint rule — every child backend submits the child's first
    turn under this id, so a crash re-drive or a re-materialization resubmits
    the same turn and the byte-identical task prompt is idempotent rather
    than duplicated. *)

val shutdown : t -> unit
(** [shutdown t] stops admission and closes every driver, then returns. It has
    no failure path: closing is total. Each driver cancels active work through
    the durable-first interrupt, preserves an already parked decision without a
    new journal fact, awaits quiescence, and releases its fence. Drivers close
    concurrently so one blocked on a cancellation-ignoring callback never holds
    the others open. [shutdown] returns once every driver is quiescent, so it
    blocks for as long as the slowest such callback does — no terminal fact is
    fabricated for work that cannot be proven quiescent. A command built by
    {!Mentat_protocol.Command.interrupt}, not shutdown, terminally abandons a
    parked decision. It is idempotent. *)

(** {1:client The client-facing session driver} *)

val driver : t -> Mentat_client.Driver.Session.t
(** [driver t] is the engine's session half of the client's multi-source
    construction seam: the {!Mentat_client.Driver.Session.t} record whose field
    closures

    - {b submit} a {!Mentat_protocol.Command.t}, routing it to its session's
      driver — attaching one on demand (acquire the fence, load, recover to
      quiescence) — and returning only after durable admission; a session driven
      by another process is [Error (Busy _)];
    - {b follow} a session with a three-case [from] ([`Beginning] replays the
      whole journal, [`Now] tails from the current head, [`After] resumes
      strictly after a delivered position), yielding the raw
      {!Mentat_client.Feed.seam} the client wraps; a driven session's feed
      advances live, a non-driven one is a fence-free read-only view over the
      session's runtime-owned hub, and a feed opened before this process drives
      the session transitions to live tailing when a driver attaches. A threaded
      [`After] position naming no committed fact of the session's feed surfaces
      as [Error (Invalid_position _)] at the first pull, by the one membership
      check. The runtime retains a session's hub while its driver is attached or
      a feed is open on it, and releases it once both cease; because the hub is
      a pure fold of the journal, a later follow rebuilds a byte-identical head,
      so release loses nothing and a long-lived process holds hubs only for the
      sessions it currently drives or observes (see {!retained_hub_count});
    - {b answer_unattended} the unattended permission denial, attributed
      [Unattended_policy] — engine-enforced and replay-checked;
    - read {b possibly_mutating} — [true] iff this process drives the session
      and recovery settled an open tool claim ambiguously with no covering
      checkpoint since; [false] for a session this process does not drive;
    - read {b faulted} — [Some diagnostic] iff this process drives the session
      and its driver has contained a fault; [None] for a live session or one
      this process does not drive. Like {b possibly_mutating} it is a
      same-process pull query: it reads the driver's phase and publishes
      nothing, so it never wakes a follower blocked in a pull, and the
      remote-reach endpoint is deferred;
    - run the fenced {b fork}/{b rewind}/{b compact} flows on the client-minted
      target id, each at a quiescent point under the session's fence; and
    - serve the session-scoped {b pending_decision} and {b change_diff} queries
      over the driven head or a fence-free view; and
    - serve the bounded {b tail} first paint and {b page} scroll-up over the
      same one projection ({!Mentat_protocol.Transcript}) — O(page) from a
      driven session's materialized hub, or one O(J) journal fold when the
      session is not driven — with [page]'s [before] membership-checked exactly
      as the feed resumes, so a forged position is [Error (Invalid_position _)],
      never a truncated page.

    Every field returns {!Mentat_protocol.Error.t}, the one-error-type law: the
    bridge maps each engine {!Error.t} arm onto a protocol arm totally, so a
    frontend never observes the engine error and the firewall holds as a
    compiler fact. The executable's composition root assembles the full
    {!Mentat_client.Driver.t} from this value plus its own
    account/settings/lifecycle responders and calls {!Mentat_client.make};
    frontends hold only the resulting {!Mentat_client.t}. *)

val commit_metadata :
  t ->
  Mentat_session.Id.t ->
  transform:
    (Mentat_session.t -> (Mentat_session.t, Mentat_protocol.Error.t) result) ->
  [ `Committed of (unit, Mentat_protocol.Error.t) result | `Not_driven ]
(** [commit_metadata t id ~transform] runs the pure metadata [transform]
    (rename/archive/restore/delete) on [id] and CAS-saves it under the held
    fence, at an idle point of the driven session's controller — the online
    lifecycle cone. [`Committed r] when {b this} engine drives [id] ([r] carries
    the store outcome, or the structured active-turn error if a turn is
    running); [`Not_driven] when no live driver holds [id], the signal the
    composition root falls back to the offline metadata twin on. The transform
    is opaque to the engine (it stays policy-free); the commit is synchronous
    store IO that touches nothing under the execution layer's background switch,
    and on success the controller adopts the new revision so the next journal
    commit is coherent. *)

val retained_hub_count : t -> int
(** [retained_hub_count t] is the number of sessions for which [t] currently
    retains a feed hub — the sessions it drives or observes. It is the
    observable of the hub-retention rule: a hub is retained exactly while its
    session's driver is attached or a feed is open on it, and released once both
    cease, so this count does not grow with sessions merely touched and then
    left idle. Exposed for operational introspection of a long-lived process and
    to pin the eviction law in tests. *)
