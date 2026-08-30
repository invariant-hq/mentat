(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The engine's ports — the reach into what genuinely varies.

    Two ports, each mapping to exactly one adapter the executable supplies: a
    provider function, because providers genuinely vary (five live transports
    plus scripted fakes), and a workspace capability record. The store is
    deliberately not a port: persistence does not vary, so the engine links
    [mentat.store] directly and the store's own abstract types — the opened
    root, the {!Mentat_store.Run_lock.guard} fence proof, the CAS document —
    enforce the preconditions a port signature would only restate. Beyond that
    one substrate the engine's stanza links no resource library — no provider
    transport, no filesystem or watch library, no UI — so those resources
    reach the engine only through these values. The ports double as the
    fault-injection seam for what they carry: crash and fault tests inject
    failing provider and workspace adapters, and induce store faults on a real
    store root.

    Every port-crossing type is an owner value the engine already links. No
    parallel provider or workspace type system is published.

    Process spawn is deliberately not a port: the engine never spawns — tools
    close over the workspace-IO spawn boundary at construction, and a call's
    cancellation is a read-only predicate. A delegated child session keeps
    that law: the engine records the edge and creates the child document,
    then hands one identity to the process broker it holds — the child's
    process belongs to the broker, never to the engine. *)

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
          root; the engine appends the fact through
          {!Mentat_store.Mutation.append} before the callback runs. *)
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
