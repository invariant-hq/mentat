(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The engine's whole reach into the world.

    Three ports, each mapping to exactly one adapter the executable supplies: a
    store signature because its abstract types enforce preconditions, a provider
    function, and a workspace capability record. The ports-only law: the
    engine's stanza links no resource library — no store backend, no provider
    transport, no filesystem or watch library — so resources reach the engine
    only through these values. They are also the fault-injection seam: crash and
    fault tests inject failing adapters; production callers pass owner-backed
    adapters built in the executable.

    Every port-crossing type is an owner value the engine already links, a store
    abstract instantiated with the owner's exact type, or a declared error
    mirror the adapter maps losslessly. No parallel store, provider, or
    workspace type system is published.

    Process spawn is deliberately not a port: the engine never spawns — tools
    close over the workspace-IO spawn boundary at construction, and a call's
    cancellation is a read-only predicate. A delegated child session keeps
    that law: the engine records the edge and creates the child document,
    then hands one identity to the process broker it holds — the child's
    process belongs to the broker, never to the engine. *)

(** {1:store The store port} *)

(** Store failures crossing the port. *)
module Store_error : sig
  (** The type for store failures — the store's failure arms, minus ids the call
      site already holds; the adapter maps the store's errors onto these
      losslessly (each diagnostic carries path and detail). *)
  type t =
    | Not_found  (** No document exists for the requested session. *)
    | Conflict
        (** The CAS lost. Under the fence this proves a fence violation or an
            adapter bug; the driver faults — it never retries silently. *)
    | Rejected of Mentat_session.Error.t
        (** A semantic append was refused — a step or driver bug, surfaced
            loudly. *)
    | Corrupt of Mentat_diagnostic.t  (** Persisted data will not decode. *)
    | Io of Mentat_diagnostic.t  (** A filesystem or lock primitive failed. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats {!message} output. *)
end

(** The session and mutation persistence, adapter-backed.

    The commit composition is the adapter's: fold the suffix through the
    session's checked append, stamp metadata, and perform the CAS save — the
    engine sees only the validated result. Time is likewise the adapter's: the
    engine mints no clock reads. *)
module type STORE = sig
  type guard
  (** The single-writer fence guard — instantiated with the store's run-lock
      guard, never re-implemented. Owner death releases it; driver teardown is
      the normal release path. Threaded through every commit and mutation append
      below: the fence is a type-level precondition, not prose. *)

  type loaded
  (** The store's session document: the replayed, validated session paired
      privately with the revision of its exact persisted bytes. The engine reads
      {!session_of}; it never sees a revision — CAS bookkeeping is the
      document's own. *)

  val session_of : loaded -> Mentat_session.t
  (** [session_of l] is the loaded session value. *)

  val try_acquire :
    Mentat_session.Id.t ->
    [ `Acquired of guard | `Held of string option | `Io of Mentat_diagnostic.t ]
  (** [try_acquire id] is the non-blocking fence acquisition for [id]:
      [`Acquired guard] took the fence; [`Held display] found it held and admits
      nothing. [`Held display] names the holder via the store's owner rendering
      when its owner line was readable ([None] when it was not — the exclusion
      is authoritative, only the display is unknown); the engine threads that
      display string straight into protocol [Busy] without the protocol taking a
      store dependency. [`Io] is a fault, not [Busy]. Whether to wait on [`Held]
      is caller policy. *)

  val release : guard -> unit
  (** [release guard] releases the fence early. Idempotent. *)

  val create : Mentat_session.t -> (loaded, Store_error.t) result
  (** [create session] persists a new session document, failing rather than
      replacing an existing one ([Conflict]). Its consumer is the runtime, which
      creates delegated child sessions through it before any child driver
      exists. A branch instead goes through {!fork}, which seeds the child's
      mutation sibling in the same atomic act. *)

  val fork :
    from:Mentat_session.Id.t ->
    events:Mentat_mutation.Event.t list ->
    Mentat_session.t ->
    (loaded, Store_error.t) result
  (** [fork ~from ~events session] persists the branch target [session] together
      with its copied mutation history: [events] — the ledger prefix the child
      retains, which the driver derives from its own replayed history through
      {!Mentat_mutation.State.prefix_for_turns} — and every blob they reference
      are copied from [from] and made durable before [session]'s document, the
      commit point. So a forked or rewound child carries the same file-change
      evidence its inherited turns authored: diff and revert over the child see
      exactly what the retained prefix recorded, never an empty ledger. A seed
      failure persists no document ([Conflict] as {!create} for a taken id;
      [Corrupt]/[Io] for unreadable parent history). *)

  val load : guard -> (loaded, Store_error.t) result
  (** [load guard] re-reads the journal head under the fence — what a successor
      does after acquiring it. *)

  val view : Mentat_session.Id.t -> (loaded, Store_error.t) result
  (** [view id] is a fence-free read-only load, for observation only (feeds and
      on-demand child views). Observation never acquires the fence. *)

  val commit :
    guard ->
    loaded ->
    Mentat_session.Event.t list ->
    (loaded, Store_error.t) result
  (** [commit guard loaded events] is the one commit point: semantic append plus
      whole-document CAS save, durable on return. Ordering-law role: every claim
      rides the suffix committed here before its effect runs. *)

  val commit_metadata :
    guard -> loaded -> Mentat_session.t -> (loaded, Store_error.t) result
  (** [commit_metadata guard loaded session] CAS-saves a metadata-transformed
      [session] (a rename/archive/restore/delete of [loaded]'s session) under
      the held fence — the whole-document replace {!commit} performs, but with
      {b no event append}: metadata is not journal state. The engine runs it at
      a driven session's idle point (the R6 online lifecycle cone); the offline
      twin commits the same way through its own acquire. *)

  val append_edit :
    guard ->
    loaded ->
    entries:Mentat_edit.Result.Entry.t list ->
    Mentat_mutation.Event.t ->
    (Mentat_mutation.State.t, Store_error.t) result
  (** [append_edit guard loaded ~entries event] is the edit half of a mutation
      append: the authoritative {!Mentat_edit.Result.Entry.t} list [entries] —
      the confirmed transitions that still hold the before/after bytes — crosses
      together with the mutation [event] derived from them. [entries] is the
      byte carrier, not a {!Mentat_edit.Result.t}: a failed apply's confirmed
      prefix is a list of entries and asserts no successful whole-plan apply, so
      both a successful apply's result entries and a commit-phase attempt's
      confirmed prefix cross the same seam. The adapter persists the blobs
      first, then the event, durable before return; the settlement commit that
      references them follows. On [Ok state], [state] is the advanced mutation
      state — the anchor the driver adopts as its store-fed cache. *)

  val append_mutation :
    guard ->
    loaded ->
    Mentat_mutation.Event.t list ->
    (Mentat_mutation.State.t, Store_error.t) result
  (** [append_mutation guard loaded events] is the rest of a mutation append:
      checkpoint facts and observation attributions — mutation-owned [events]
      with no blob payload. Takes the guard for the same reason every write
      does: the append itself enforces its serialization precondition. On
      [Ok state], [state] is the advanced mutation state the driver adopts as
      its store-fed cache. *)

  val mutation_events :
    loaded -> (Mentat_mutation.Event.t list, Store_error.t) result
  (** [mutation_events loaded] is [loaded]'s mutation ledger in append order,
      validated against that exact session document. Its two consumers: the feed
      seam folds it into the mutation state the {!Mentat_protocol.Projection}
      fold joins at tool settlements, and driver attachment folds it into the
      initial mutation state a recovering driver seeds its store-fed cache with
      (thereafter the cache is fed by the store's own append returns, not
      re-folded here). *)

  val blob :
    Mentat_session.Id.t ->
    Mentat_digest.Content_ref.t ->
    (string option, Store_error.t) result
  (** [blob id ref] is the bytes of the content-addressed image [ref] under
      [id]'s blob store, or [None] when no such blob exists — a fence-free
      observation read, verified against [ref] before return (a mismatch is
      [Corrupt]). Its one consumer is the [change_diff] read, which resolves a
      recorded change's before/after image references through it to compute
      {!Mentat_mutation.Change.hunks}. The change-diff read needs the image
      bytes, which the mutation ledger references but does not carry. *)

  val put_attachment :
    Mentat_session.Id.t ->
    string ->
    (Mentat_digest.Content_ref.t, Store_error.t) result
  (** [put_attachment id bytes] writes [bytes] into [id]'s attachment namespace
      ([sessions/<id>/attachments/]), content-addressed and write-once, keyed by
      [Content_ref.of_contents bytes]; durable on return. Fence-free: an
      attachment write is a boundary observation, not a session write (like the
      capture store) — headless [-i] attaches before the run fence exists, and a
      TUI attach happens with no active turn. Idempotent; a pre-existing blob is
      verified against its reference, not rewritten (a mismatch is [Corrupt]).
      The engine calls it to externalize inline [`Base64] media to a [`Ref]
      before committing any media-bearing fact. *)

  val attachment :
    Mentat_session.Id.t ->
    Mentat_digest.Content_ref.t ->
    (string option, Store_error.t) result
  (** [attachment id ref] is the bytes of the content-addressed media [ref]
      under [id]'s attachment namespace, or [None] when absent — a fence-free
      read verified against [ref] before return (a mismatch is [Corrupt]).
      Distinct from {!blob}, which reads the mutation namespace. The engine
      calls it at the provider-call boundary to resolve a [`Ref] back to
      [`Base64], strictly after {!Mentat_llm.Request.digest}; a missing
      referenced blob there is a loud fault, never a silent empty image. *)

  val revert :
    guard ->
    loaded ->
    scope:Mentat_mutation.Revert.Scope.t ->
    (Mentat_mutation.Revert.Outcome.t, Store_error.t) result
  (** [revert guard loaded ~scope] runs the whole fenced revert lifecycle for
      [scope] against [loaded]'s session under the held fence: it re-reads the
      live history, resolves [scope] to a selection, prepares the all-or-nothing
      plan, captures a [Before_revert] checkpoint, and appends the started and
      settled facts around the workspace apply — the composition
      [Mentat_store.Mutation.revert_apply] performs, closed over the adapter's
      workspace-write capability, checkpoint, and revert-id minter.
      [Mentat_mutation.Revert.Outcome.Nothing_to_revert] when [scope] named no
      revertable work; [Refused] with the preparation problems' rendered
      messages (no fact minted) when preparation refused before any file
      changed; [Applied] with the durable settlement otherwise. The engine runs
      it at a driven session's idle point (the R6 online revert cone); the
      offline twin composes the same assembly through its own acquire — one
      implementation, two consumers. *)

  val revert_selection :
    guard ->
    loaded ->
    selection:Mentat_mutation.Revert.Selection.t ->
    (Mentat_mutation.Revert.Outcome.t, Store_error.t) result
  (** [revert_selection guard loaded ~selection] is {!revert} for a full
      {!Mentat_mutation.Revert.Selection.t} rather than a singleton
      {!Mentat_mutation.Revert.Scope.t} — the multi-turn ([Selection.turns]) and
      multi-change ([Selection.changes]) selections the undo flow needs for its
      boundary revert and its widen/narrow un-revert, which a scope cannot
      express. Same fenced lifecycle, same outcomes. *)

  val truncate :
    guard ->
    loaded ->
    keep:(Mentat_session.Turn.Id.t -> bool) ->
    Mentat_session.t ->
    (loaded * Mentat_mutation.State.t, Store_error.t) result
  (** [truncate guard loaded ~keep session] commits an undo by dropping the
      crossed turns from both durable halves of the fenced session under one
      document lock: the mutation ledger is rewritten in place to the
      surviving-turn prefix (derived here from the live history through
      {!Mentat_mutation.State.prefix_for_turns} and [keep]), then [session] —
      the surviving-prefix document the caller computed — is committed by
      whole-document CAS. Ledger-first ordering keeps the session loadable
      across a crash between the two writes. On [Ok (loaded', mstate)] both
      halves are durable and coherent, [loaded'] carries the truncated
      document's new revision, and [mstate] is the post-truncate mutation anchor
      the engine adopts. The engine runs it at a driven session's idle point
      when a submit commits an armed undo. *)

  val export : guard -> (string, Store_error.t) result
  (** [export guard] is the fenced session's complete export bundle as one
      string — the versioned, self-describing stream [Mentat_store.Export.write]
      produces (a header line, the document line, one line per mutation event,
      one line per referenced blob, and a terminal manifest whose digest covers
      the exact preceding bytes), buffered whole. A read that mints no fact and
      re-verifies every blob against its content reference as it streams. The
      engine runs it at a driven session's idle point (the R6 online export
      cone) under a bundle-size guard; the offline twin streams the same bytes
      straight to its own sink. *)
end

(** {1:provider The provider port} *)

(** The provider runtime through the selected model, adapter-backed. *)
type provider_call =
  Mentat_llm.Request.t ->
  on_event:(Mentat_llm.Event.t -> unit) ->
  on_download:(Mentat_protocol.Progress.Model_download.t -> unit) ->
  cancelled:(unit -> bool) ->
  (Mentat_llm.Response.t, Mentat_llm.Error.t) result
(** [provider_call request ~on_event ~on_download ~cancelled] interprets one
    claimed request — issued only after the provider claim is durable.
    [on_event] must only enqueue a bounded progress value; it never invokes a
    frontend. [on_download] receives model-artifact preparation progress while a
    local provider transparently fetches the selected model's weights before the
    call; like [on_event] it must only enqueue a bounded value, and a provider
    with nothing to prepare never invokes it. [cancelled] reads the controller's
    atomic flag; cancellation is dual — the cooperative flag and the worker's
    Eio scope, and a cooperative stop returns the {!Mentat_llm.Error.Cancelled}
    kind as a value, never an exception. Cancellation reaches an in-flight
    artifact fetch through the same flag, so pressing interrupt during a
    download stops it at the next transfer boundary. A claimed request with no
    recorded response settles Ambiguous at recovery and is never re-issued. *)

val script :
  (Mentat_llm.Request.t -> (Mentat_llm.Response.t, Mentat_llm.Error.t) result) ->
  provider_call
(** [script call] adapts a request-only interpreter into a {!provider_call},
    ignoring the streaming, download-progress, and cancellation channels because
    a whole-response computation has no partial output to stream, no model
    artifact to fetch, and no in-flight work to cancel. It is the shape a fake
    or scripted provider wants; a live transport, which streams deltas and
    honors cancellation, implements {!provider_call} directly. *)

(** {1:workspace The workspace port}

    Port-crossing-type convention: a port operation's payload is the owner's
    pure type; when the owner type would live in an effect library, the pure
    data moves upstream and the port names it directly — it is never re-declared
    structurally at the port. The attribution window's yield follows the rule:
    the closer returned by [open_scope] yields {!Mentat_edit.Apply_evidence.t},
    the pure owner type homed in [mentat.edit] (which names both
    {!Mentat_edit.Result.t} and {!Mentat_edit.Result.Entry.t}), not a structural
    mirror the adapter would map field-for-field. *)

type workspace = {
  identity : Mentat_sandbox.Identity.t;
      (** The sealed confinement identity the turn contract records and the
          drift input at resume. *)
  checkpoint :
    boundary:Mentat_mutation.Checkpoint.boundary -> Mentat_mutation.Checkpoint.t;
      (** [checkpoint ~boundary] is the one conservative capture at [boundary] —
          before the turn's first tool callback, regardless of declared
          permissions. Degradation is a value: a failed capture returns a
          [Degraded] fact, execution continues, and "revert unavailable" is
          recorded durably. The adapter owns the snapshot backend and captured
          root; the engine appends the fact through {!STORE.append_mutation}
          before the callback runs. *)
  drain_notices : unit -> Mentat_workspace.Notice.t list;
      (** Transactional notice intake, wherever a turn resumes from waiting on
          the outside world: turn preparation, each tool claim settling, and
          delegated children delivering. Each drained notice becomes a durable,
          turn-scoped [Workspace_notice] fact the engine renders in the
          transcript and injects into that turn's continuation requests.

          The drain consumes: a producer hands over its observation and does not
          keep it. The engine calls it at boundaries a request normally follows,
          and for the run's remainder holds anything a turn recorded without
          stating, so a later turn states it — consuming is therefore safe even
          for the turn that ends at the boundary it drained on. A producer must
          tolerate being drained many times within one turn, and should stay
          silent unless what it observes has changed. *)
  open_scope :
    Mentat_session.Tool_claim.Id.t -> unit -> Mentat_edit.Apply_evidence.t;
      (** [open_scope claim] opens the attribution window for [claim] before the
          callback runs and returns its one closer. The closer is invoked
          exactly once, only after the callback's worker scope has quiesced, and
          yields the chronological evidence the engine persists without
          inspecting tool output. Mutation validation does not reject an
          observation attributed to an already-settled claim, so closing the
          scope before the claim settles is an obligation the driver enforces,
          not a store-checked invariant. *)
}
(** The workspace capability's engine-facing value: checkpoint capture, the
    per-claim attribution window, notice intake, and the sealed confinement
    identity. Backed by [mentat.workspace_io] plus the mutation-attribution
    adapter in the executable. *)
