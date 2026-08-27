(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** One session driver — the controller/worker topology behind the fence.

    A driver is one controller fiber that owns the fence guard, the single
    drain, the cancellation flag, and the feed head. It obeys the operational
    law: commit one transition, perform at most one claimed external effect in a
    child worker fiber, commit only that effect's settlement under bounded
    cancellation protection, leave protection, then advance. Protection covers
    exactly the settlement — close the claim scope, append the mutation
    evidence, compute the feed-back step, commit it — and returns the next step;
    the loop re-enters in the normal cancellation context, so the next effect is
    cancellable. The controller stays live while an effect runs — the
    durable-first interrupt (commit the request, acknowledge, set the atomic
    flag, fail the worker switch, await quiescence, settle under protection)
    depends on it.

    The single linearization point is the store commit: an interrupt request and
    a result settlement order at the session journal. Settlement first, and the
    interrupt applies to the post-settlement state; interrupt first, and the
    result can no longer settle as ordinary success — the worker is cancelled,
    quiescence awaited, and the reconcile settles the claim honestly. Exactly
    one settlement per claim, always. The head the driver holds between commits
    is the one the store returned: the adapter re-folds the suffix through the
    session's checked append, and the driver adopts that result rather than
    re-validating it.

    A driver contains its own faults. No exception escapes a driver fiber into
    the shared runtime switch, where it would cancel every sibling driver; a
    faulted driver keeps its fence and its captured result and never takes an
    unrelated session down. A settlement save that fails after its effect ran
    stops admission and retains both the fence and the held result: nothing more
    is written through the failing store, an explicit later retry persists the
    held result, and process death degrades it to the [Ambiguous] a successor's
    recovery mints. Two supervision verbs name this discipline: to {e contain} a
    fault is to be the supervisor boundary — it halts at the driver fiber and
    never reaches a sibling; to {e recover} is the total
    restart-with-recovered-state a successor performs, rebuilding from the
    journal and minting [Ambiguous] for any settlement the dead process left in
    doubt. Every driver operation — submit routing, interrupt, feed-head
    advance, fence release — runs on the runtime's owning domain; a cross-domain
    caller enqueues to it rather than calling in place, because Eio forbids
    touching a cancellation context from another domain.

    The runtime supplies the world as closures: {!type:io} is the three ports
    narrowed to one fenced session (the fence guard and CAS document live inside
    the closures — the driver never sees a revision), and {!type:hooks} is the
    scheduler seam. The driver appends session events only through the step,
    plus the two driver-owned facts (interrupt request, queue), all validated
    by the session's checked constructors and replay. *)

type io = {
  session_id : Mentat_session.Id.t;  (** The fenced session. *)
  commit :
    Mentat_session.Event.t list ->
    (Mentat_session.t, Ports.Store_error.t) result;
      (** The one commit point under the fence; returns the committed head. *)
  commit_metadata :
    Mentat_session.t -> (Mentat_session.t, Ports.Store_error.t) result;
      (** A whole-document CAS of a metadata-transformed session under the
          fence, no journal append; returns the committed head and adopts the
          new revision so the next {!commit} is coherent. *)
  append_edit :
    entries:Mentat_edit.Result.Entry.t list ->
    Mentat_mutation.Event.t ->
    (Mentat_mutation.State.t, Ports.Store_error.t) result;
      (** The edit half of a mutation commit: the confirmed entries carry the
          bytes; blobs and event durable before return. On [Ok state], [state]
          is the advanced mutation state the driver adopts as its store-fed
          cache. *)
  append_mutation :
    Mentat_mutation.Event.t list ->
    (Mentat_mutation.State.t, Ports.Store_error.t) result;
      (** The rest of a mutation commit: checkpoint facts and observation
          attributions. On [Ok state], [state] is the advanced mutation state
          the driver adopts as its store-fed cache. *)
  put_attachment :
    string -> (Mentat_digest.Content_ref.t, Ports.Store_error.t) result;
      (** Externalize inline media: store bytes into the session's attachment
          namespace, fence-free, returning their content reference. *)
  attachment :
    Mentat_digest.Content_ref.t -> (string option, Ports.Store_error.t) result;
      (** Read an attachment blob by reference, fence-free; [None] when absent.
          Validates an incoming [`Ref] at admission and resolves it at the
          provider-call boundary. *)
  fork :
    events:Mentat_mutation.Event.t list ->
    Mentat_session.t ->
    (unit, Ports.Store_error.t) result;
      (** Persists a fork or rewind target with its copied mutation ledger:
          [events] — the retained prefix of this driver's history — and their
          blobs are seeded before the child document, so the child's diff and
          revert see the same edits its inherited turns authored. *)
  revert :
    scope:Mentat_mutation.Revert.Scope.t ->
    ( Mentat_mutation.Revert.Outcome.t * Mentat_mutation.State.t,
      Ports.Store_error.t )
    result;
      (** The whole fenced revert lifecycle for [scope] — resolve, capture,
          freeze, apply, settle — returning the outcome paired with the
          {b re-read post-revert mutation state}. The driver adopts that state
          as its ledger mirror, so a subsequent turn's checkpoint and a branch's
          copied prefix see the revert facts the port just appended. *)
  undo_revert :
    Mentat_mutation.Revert.Selection.t ->
    ( Mentat_mutation.Revert.Outcome.t * Mentat_mutation.State.t,
      Ports.Store_error.t )
    result;
      (** {!revert} for a full {!Mentat_mutation.Revert.Selection.t} — the
          multi-turn boundary revert and the multi-change un-revert the undo
          flow drives. Same lifecycle and adoption as {!revert}. *)
  truncate :
    keep:(Mentat_session.Turn.Id.t -> bool) ->
    Mentat_session.t ->
    (Mentat_session.t * Mentat_mutation.State.t, Ports.Store_error.t) result;
      (** Commit an armed undo: drop the crossed turns from both durable halves
          under one document lock, ledger-first, and return the truncated head
          session paired with its post-truncate mutation state. The engine holds
          the surviving-prefix document and [keep] selects the surviving turns'
          ledger. *)
  export : unit -> (string, Ports.Store_error.t) result;
      (** The fenced session's complete export bundle buffered into one value —
          a read that mints no fact. The engine bounds the value with a size
          guard before it crosses the wire. *)
  release : unit -> unit;  (** Releases the fence — driver teardown only. *)
  provider_call :
    Mentat_llm.Request.t ->
    on_event:(Mentat_llm.Event.t -> unit) ->
    on_download:(Mentat_protocol.Progress.Model_download.t -> unit) ->
    cancelled:(unit -> bool) ->
    (Mentat_llm.Response.t, Mentat_llm.Error.t) result;
      (** {!Ports.provider_call}, verbatim. *)
}
(** The type for the driver's static port reach, narrowed to its fenced session.
    Turn-scoped workspace authority is selected with the catalog and policy by
    {!create}. *)

type hooks = {
  try_reserve :
    Mentat_agent_step.Step.Reservation.t ->
    [ `Granted | `Refused of Mentat_agent_step.Step.Reservation.Refusal.t ];
      (** The scheduler's capacity permit, keyed by the reservation's delegation
          edge. *)
  release_permit : delegation:Mentat_session.Delegation.Id.t -> unit;
      (** Returns [delegation]'s granted permit when its edge commit failed. *)
  observe_delegation : Mentat_session.Delegation.t -> unit;
      (** Fired after a [Delegation_recorded] commit and before the hub
          publishes that commit's facts; idempotent. Registering the child ahead
          of the publish is what makes the edge unobservable until the child it
          names is resolvable: a feed subscriber that attaches to the child on
          seeing the [Journal_delegation] fact never races the child's creation.
      *)
  deliver_message : Mentat_agent_step.Step.Mail.t -> unit;
      (** Fired after a settled [send]/[follow_up] receipt commits: the
          runtime routes the recorded message to its target — a child edge,
          or the recording session's parent. Fire-and-forget from the
          controller's perspective; delivery is idempotent on the id derived
          from the message's [(turn, call_id)], so a re-fire (recovery's
          re-drive) cannot deliver twice. *)
  settled_children :
    Mentat_session.Delegation.Id.t list ->
    (Mentat_session.Delegation.Id.t * Scheduler.child_result) list;
      (** The known-settled subset for a pending wait. *)
  cancel_children : Mentat_session.Delegation.Id.t list -> unit;
      (** Semantic cascade: interrupt each named child and await its committed
          terminal fact. The cascade walks the delegation graph depth-first and
          interrupts each child through its own durable path, never by failing a
          switch across sessions. May block on a stuck descendant. *)
  on_turn_settled :
    turn:Mentat_session.Turn.Id.t -> Mentat_session.Turn.Outcome.t -> unit;
      (** Fired after a terminal turn fact commits — the runtime's
          child-settlement notification seam. *)
}
(** The type for the scheduler seam. *)

type t
(** The type for a session driver. *)

val create :
  sw:Eio.Switch.t ->
  io:io ->
  hooks:hooks ->
  resolve:
    (latest_model:Mentat_llm.Model.t option ->
    (Config.t, Mentat_diagnostic.t) result) ->
  execution_for_mode:Execution.factory ->
  now:(unit -> Mentat_session.Time.t) ->
  depth:int ->
  session:Mentat_session.t ->
  mutation:Mentat_mutation.State.t ->
  hub:Feed.Hub.t ->
  t
(** [create ~sw ~io ~hooks ~resolve ~execution_for_mode ~now ~depth ~session
     ~mutation ~hub] is a driver over one fenced session. [hub] is the
    runtime-owned per-session feed hub: observation opened before this driver
    attached already subscribes to it, and the driver publishes its commits
    there. [resolve] runs at each turn boundary to produce the effective
    configuration; it receives [latest_model] — the session's most recently
    started model as recorded in its own journal
    ({!Mentat_session.State.latest_model}) — so the resolver can prefer the
    durable per-session model over a global default when no process-local
    override is in force. [execution_for_mode] already incorporates the
    session's durable delegation authority. At a new turn it receives the
    freshly resolved [configured] value, [model:configured.model], and
    [sealed_declarations:None]. Active-turn recovery receives the sealed
    contract's [model] and [sealed_declarations], which remain authoritative
    even if configuration or host facts changed after admission. The selected
    {!Execution.t} — catalog, workspace port, effective policy, and context
    prelude — is stored together before an accepted step can run. Recovery
    retains the policy in its durable contract. An idle head runs scalar
    admission directly and selects no execution unless that admission starts a
    turn. It runs nothing until {!start}, so the runtime can register it before
    its first drive fires hooks.

    [execution_for_mode] is a factory: {!start} opens a nested [Eio.Switch.run]
    (a child of [sw]) at the controller, held across every turn, and applies
    [execution_for_mode ~background:] to it {e once} to obtain a pair — the
    per-turn execution selector and a live {!running_processes} view — over one
    session-scoped resource (a background-process registry) the executable
    builds over that switch. The registry is created once and shared by all
    turns and the view. The nested switch is released in {!close}'s quiescent
    teardown, after [serve] returns and before the fence releases: a background
    process spawned under it is then killed and reaped leader-only, so a
    session's background processes die when the session closes, on every exit
    path including a fault that cancels [sw]. *)

val start : t -> unit
(** [start t] forks the controller fiber under the creation switch — a sibling
    of every other driver. Call it exactly once, after registering [t] wherever
    the hooks resolve drivers: the first drive fires hooks that look [t] up. An
    active loaded session first runs [Step.recover]: open claims settle
    Ambiguous and the drive continues. An idle loaded session first runs
    admission directly, preserving queued recovery without constructing a
    speculative Build execution. *)

val hub : t -> Feed.Hub.t
(** [hub t] is the driver's feed hub. *)

val submit :
  t -> Mentat_protocol.Command.t -> (unit, Mentat_protocol.Error.t) result
(** [submit t command] enqueues [command] on the drain and returns only after
    its durable admission — the fact is committed when [Ok] returns. An
    interrupt is acknowledged only after its request committed. *)

val deliver : t -> unit
(** [deliver t] pokes the driver's drain: a named child settled, so a parked
    wait may now be answerable. Non-blocking; idempotent. *)

val enqueue :
  t -> Mentat_session.Queue.Entry.t -> (unit, Mentat_protocol.Error.t) result
(** [enqueue t entry] appends the caller-minted [entry] to the driven session's
    next-turn queue, returning after durable admission — the message-delivery
    path, which derives [entry]'s id from the recording turn and call.
    Idempotent on that id: an id whose [Enqueued] fact is already in the journal
    (pending or consumed) is [Ok ()] without a second fact; the session's own
    [Queue.Duplicate] rejection backstops only the still-pending window, because
    queue-id uniqueness is a property of the resulting queue, not of an id's
    whole history. *)

val answer_unattended :
  t ->
  decision:Mentat_session.Decision.Id.t ->
  (unit, Mentat_protocol.Error.t) result
(** [answer_unattended t ~decision] submits the unattended permission denial for
    [decision], attributed [Unattended_policy] — the only answer that principal
    may give; the engine-side restriction no shell can widen. *)

val fork : t -> id:Mentat_session.Id.t -> (Mentat_session.Id.t, Error.t) result
(** [fork t ~id] executes the fork flow under the fence at a quiescent point: a
    new session [id] with the current journal as its copied prefix. *)

val rewind :
  t ->
  id:Mentat_session.Id.t ->
  anchor:Mentat_session.Anchor.t ->
  (Mentat_session.Id.t, Error.t) result
(** [rewind t ~id ~anchor] executes the rewind flow under the fence at a
    quiescent point. *)

val compact :
  t ->
  turn:Mentat_session.Turn.Id.t ->
  (Mentat_client.Driver.compaction_result, Mentat_protocol.Error.t) result
(** [compact t ~turn] executes the manual compaction flow on the client-minted
    compaction [turn] id. Requires an idle head: it admits a compaction-only
    [Origin.Compaction] turn whose single body is one billable summary provider
    claim, and installing the summary settles that turn. [Installed] returns
    after the [Compaction] fact is durable; [Skipped] when the model view is
    empty or already fully summarized; operational failure — a failed or
    interrupted summary — is a structured {!Mentat_protocol.Error.t}.

    Find-or-create on [turn] (as a prompt's client-minted turn): a wire retry
    replays the same id. When [turn] already names this session's installed
    compaction it returns [Installed] without a second summary call; when it
    named nothing (a prior [Skipped] mints no turn) the idle head is
    re-evaluated, re-deriving [Skipped] with no provider call; when it names a
    non-compaction turn it is {!Mentat_protocol.Error.Turn_id_reused}. The flow
    is asynchronous over the summary call, so it returns only once the
    compaction turn settles. *)

val commit_metadata :
  t ->
  transform:
    (Mentat_session.t -> (Mentat_session.t, Mentat_protocol.Error.t) result) ->
  (unit, Mentat_protocol.Error.t) result
(** [commit_metadata t ~transform] applies the pure metadata [transform]
    (rename/archive/restore/delete) to the driven session and CAS-saves it under
    the held fence, at an {b idle} point of the controller. Unlike {!compact} it
    is {b synchronous}: it does the store IO inline and returns immediately — no
    provider call, no async resolver. A running turn returns the structured
    active-turn error ([Active_turn_exists]) rather than committing mid-turn,
    which would fault the next journal commit on a stale revision. On success
    the controller adopts the new store revision, so a subsequent turn's journal
    commit CASes against the fresh head. A [transform] that returns an error is
    surfaced unchanged. *)

val revert :
  t ->
  scope:Mentat_mutation.Revert.Scope.t ->
  (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result
(** [revert t ~scope] executes the revert flow under the held fence at an
    {b idle} point: it resolves [scope], applies the all-or-nothing plan, and
    settles, returning the {!Mentat_mutation.Revert.Outcome.t} — the settlement,
    a clean no-op, or the refusal messages. Like {!commit_metadata} it is
    {b synchronous} and refuses a running turn with the active-turn error rather
    than mutate mid-turn. On success the driver adopts the re-read mutation
    state, so its ledger mirror carries the revert facts. A store [Conflict]
    under the fence surfaces as [Unavailable] — loudly, never a silent retry. *)

(** The undo operations the TUI drives at an idle head, reversible until submit.
*)
type undo_op =
  | Undo  (** Step the boundary back one user turn, reverting its files. *)
  | Redo  (** Step it forward one, past the last undone turn it releases. *)
  | Cancel  (** Un-revert the files and clear the boundary. *)

val undo :
  t ->
  op:undo_op ->
  (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result
(** [undo t ~op] runs one undo step under the held fence at an {b idle} point:
    it re-derives the working tree from the arm-time baseline (un-revert the
    current armed revert, then revert the new crossed selection) and appends the
    durable undo boundary, adopting the re-read mutation state. Like {!revert}
    it is {b synchronous} and refuses a running turn. The result is the file
    revert's {!Mentat_mutation.Revert.Outcome.t}: [Applied]/[Nothing_to_revert]
    on a step, or [Refused] carrying a drift refusal or a "nothing to undo/redo"
    message the TUI flashes. The armed state and seam are pure functions of the
    projected [Fact.Undo] the boundary append emits. *)

val export : t -> (string, Mentat_protocol.Error.t) result
(** [export t] buffers the driven session's complete export bundle into one
    value under the held fence, at an idle point. A read that mints no fact; a
    running turn refuses with the active-turn error so the bundle is a quiescent
    snapshot. The engine caller bounds the value with a size guard before it
    crosses the wire. *)

val faulted : t -> Mentat_diagnostic.t option
(** [faulted t] is [Some diagnostic] iff this driver has contained a fault — its
    phase is terminal and every command answers [Unavailable] — and [None] while
    it is live. A same-process client polls it to surface the fault without
    first submitting work that would only be refused. It reads the phase; it
    publishes nothing, so a follower blocked in a pull [next] is not woken by
    it. *)

val possibly_mutating : t -> bool
(** [possibly_mutating t] is [true] iff recovery settled an open tool claim
    ambiguously and no conservative checkpoint has covered the condition since —
    the possibly-still-mutating condition, surfaced to frontends as
    [Client.possibly_mutating].

    A recovered turn never trusts its pre-crash [Before_turn_tools] capture (the
    crash window may hold writes completed after it). The next workspace effect
    captures fresh at the distinct [After_recovery] boundary — a checkpoint
    whose identity is the recovery point, not the pre-crash boundary — and
    clears this flag if and only if that boundary carries an [Available]
    snapshot. A replayed boundary obeys the same rule as a freshly captured one;
    a [Degraded] capture is recorded but leaves the condition visible. (A turn
    re-recovered a second time reuses its already-recorded [After_recovery]
    capture, since one such boundary per turn is representable.) A clean turn
    takes its [Before_turn_tools] capture as usual. *)

val running_processes : t -> Mentat_protocol.Process.View.t list
(** [running_processes t] is a live snapshot of the background processes spawned
    under this session's nested switch — projected on demand from the
    driver-local registry, derived, never persisted. Empty before {!start} binds
    the session execution, and empty for a subagent. *)

val close : t -> unit
(** [close t] stops admission and releases the fence once the driver is
    quiescent. Active provider/tool work and child waits use the durable-first
    cancellation path; [close] may therefore block indefinitely on a callback
    that ignores cancellation, while the fence stays held and a second attach
    gets [Busy].

    An already parked {!Mentat_session.Decision.Requested.t} is itself a durable
    quiescent boundary: [close] preserves the request without appending an
    interrupt or terminal fact, then releases the fence. A successor
    reconstructs the same pending decision. An explicit command constructed by
    {!Mentat_protocol.Command.interrupt} remains the operation that terminally
    abandons a parked decision. *)
