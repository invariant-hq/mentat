(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Committed facts — the presentation-sufficient projection of durable session
    change.

    A fact is what {!Projection.after} and {!Projection.all} mint for one
    journal event, joined with mutation evidence at tool settlements. Every
    payload is a value another library already persists through its own codec:
    {!jsont} composes those codecs and re-encodes nothing, so the decision arms
    carry the session's request and resolution whole, the tool result carries
    the tool's own durable output projection, and the mutation fields are
    mutation-owned values.

    A journal event mints a fact only when a surface renders it or a client must
    observe it to drive; an event meeting neither test projects to nothing.

    The arms group presentationally into turn, tool, decision, and journal
    families; the type is one flat sum of uniquely-named constructors so the
    [Turn_started]/[Tool_started] pair never collides and every frontend match
    is one level deep. The dotted per-arm wire tags ([turn.started],
    [tool.returned], …) are the grouping's only durable trace. The sum is
    non-private: invalid inhabitants — evidence with neither changes nor
    observations, an empty interrupted text — are locally constructible and
    rejected by {!jsont}'s strict decode. The projector and the engine are the
    sole intended producers; nothing else constructs facts.

    {b There is no [Session] family.} Lifecycle and metadata changes are
    deliberately outside the journal, so a pure fold cannot mint them a
    position; they are completed request/completion flows on the client.

    {b Tool settlements are the owner's three honest outcomes} —
    [Tool_prepared | Tool_returned | Tool_ambiguous]. A denied call is
    unmintable: it never claims, so no durable fact exists to project it from.
    An interrupted tool call is {!Tool_returned} whose result records the
    interruption verbatim. Both {!Tool_returned} and {!Tool_ambiguous} carry the
    settlement's mutation evidence: an ambiguous settlement can still have
    recorded durable changes and observations, and honesty matters most exactly
    there.

    {b A staged tool crosses two claims.} A prepare stage commits its own
    {!Tool_started} and settles {!Tool_prepared} with the final requests; when
    those requests need review a {!Decision_requested} parks; the run stage then
    commits a second {!Tool_started} that settles {!Tool_returned}. The
    canonical prepared payload the run stage reconstructs from is not a fact —
    it stays a durable journal value the resume path reads to reconstruct and
    re-check — so a surface renders only what these facts carry. *)

type evidence = {
  changes : Mentat_mutation.Change.t list;
      (** This claim's exact durable change rows, in ledger order — the
          confirmed transitions, a failed apply's confirmed prefix included;
          content references, never bytes (hunks are the [change_diff] read).
          May be empty when the claim recorded only observations. *)
  observed : Mentat_workspace.Path.t list;
      (** The opaque observationally-attributed paths
          ({!Mentat_mutation.State.observed}) — files changed inside the claim's
          window with no recorded transition, deduplicated and sorted. May be
          empty. *)
  totals : Textdiff.stats;
      (** Run-cumulative exact-row totals for the claim's turn, as of this
          settlement — an ambiguous settlement's recorded rows included. *)
  revertability : Mentat_mutation.Revertability.t;
      (** The settlement-time revert-safety answer for this claim's evidence,
          which names any uncertain apply target and observation degradation. *)
}
(** The type for the mutation evidence riding a tool settlement — the whole of
    what a surface needs to render a write honestly. The projector composes it
    from the mutation state's own projections; this module defines the grouping
    record and nothing else. It rides a settlement only when [changes] or
    [observed] is non-empty. *)

type undo_file = {
  path : Mentat_workspace.Path.t;
  additions : int;
  deletions : int;
}
(** The type for one file an undo boundary reverts, with the crossed turns'
    cumulative recorded line counts for that path — the seam's per-file [+a −d]
    trailer. Empty for a boundary whose crossed turns recorded no edits. *)

(** The type for committed facts. *)
type t =
  | Turn_started of Mentat_session.Turn.t
      (** Carries the sealed contract; a surface renders model and mode from it.
      *)
  | Turn_assistant of Mentat_llm.Response.t
      (** The durable provider response the model deltas streamed toward. *)
  | Turn_assistant_interrupted of { text : string }
      (** Cooperative cancel with retained prose (provider settlement). [text]
          is non-empty. *)
  | Turn_provider_failed of {
      claim : Mentat_session.Provider_request.Id.t;
          (** The settled provider claim, for correlation with live request
              progress and diagnostics. *)
      error : Mentat_llm.Error.t;
          (** The provider-owned structured failure, preserved whole: kind,
              phase, provider status, and request correlation remain available
              to a TUI without parsing a terminal message. *)
    }
      (** A known provider failure settlement. The following {!Turn_settled}
          closes the generic turn lifecycle; this fact reports the provider
          occurrence without introducing a mirrored protocol error taxonomy. *)
  | Turn_message of Mentat_llm.Message.t
      (** The transcript-message arm: a model-visible appended message no
          settlement fact already carries. A tool result rides its
          {!Tool_returned} settlement and is never re-emitted here; a permission
          denial's consuming result, a resolved question's answer, and an
          approved plan's projection are not journal messages at all — the owner
          derives each at replay from the resolution, its provenance riding
          {!Decision_resolved}. Only a child-wait's synthesized result and an
          injected developer or user message reach a surface through this arm.
      *)
  | Turn_settled of {
      turn : Mentat_session.Turn.Id.t;
      outcome : Mentat_session.Turn.Outcome.t;
    }
      (** The generic terminal turn outcome. A failed provider settlement emits
          {!Turn_provider_failed} before this terminal fact. *)
  | Tool_started of Mentat_session.Tool_claim.Started.t
      (** Persisted before the callback; carries call id, name, canonical input,
          and this stage's requests — no side table. *)
  | Tool_prepared of {
      claim : Mentat_session.Tool_claim.Id.t;
      description : string;
          (** [Mentat_tool.Prepared.description] of the settled payload. *)
      requests : Mentat_permission.Request.t list;
          (** The settlement's final requests — the one and only list; the
              following {!Decision_requested} answers exactly these. *)
    }
      (** What the "awaiting final approval" row renders from. There is
          deliberately no second list and no summary value. *)
  | Tool_returned of {
      claim : Mentat_session.Tool_claim.Id.t;
      result : Mentat_tool.Output.t Mentat_tool.Result.t;
          (** The erased terminal result. Its output carries durable text, JSON,
              and truncation projections, so no second result type exists. *)
      mutation : evidence option;
          (** [None] when the claim recorded neither change nor observation. *)
    }
  | Tool_ambiguous of {
      claim : Mentat_session.Tool_claim.Id.t;
      mutation : evidence option;
          (** [None] when the claim recorded neither change nor observation.
              Non-[None] carries whatever landed durably before the outcome
              became uncertain. *)
    }
      (** The callback may have run; the terminal outcome was not recorded. For
          a workspace tool this is also the possibly-still-mutating condition —
          surfaces render it as such. *)
  | Decision_requested of Mentat_session.Decision.Requested.t
      (** Every blocked boundary — a permission review, a user question, a plan
          proposal, a child's parent-question — surfaces as this one fact
          carrying the packed request; a single answer verb resolves them all.
      *)
  | Decision_resolved of Mentat_session.Decision.Resolved.t
      (** The resolution whole: the decision id, the answering principal, and
          the erased answer, nothing projected away. The one typed handling each
          answer implies is re-derived at replay, never carried here; an
          approved plan's body, context choice, and feedback ride the answer, so
          the plan reaches Build admission intact. *)
  | Journal_task_board of Mentat_session.Task.Board.t
      (** Atomic full-board state. *)
  | Journal_delegation of Mentat_session.Delegation.t
      (** The immutable spawn edge. *)
  | Journal_queue of Mentat_session.Queue.Update.t
  | Compaction of Mentat_session.Compaction.t
      (** The installed boundary, whole. *)
  | Workspace_notice of Mentat_session.Notice.t
      (** A durable workspace runtime observation the active turn saw — a
          filesystem-watcher batch or a dune build-health change. Structured
          (severity, source, title, multi-line body) so a surface renders the
          whole observation in the transcript, not a truncated one-line dump.
          The engine states the turn's observations in that turn's continuation
          requests, so this fact is the human-visible half of a model-visible
          turn datum. *)
  | Undo of {
      update : Mentat_session.Undo.Update.t;
          (** The durable boundary update: {!Mentat_session.Undo.Update.Armed}
              names the anchor turn and the ledger revert; [Released] clears it.
          *)
      dropped_turns : int;
          (** The number of user turns the armed boundary hides — the "N turns
              undone" count. [0] for a [Released] update. *)
      files : undo_file list;
          (** The crossed turns' per-file recorded line counts, in first-seen
              path order — the seam's per-file [+a −d] trailer. Empty for a
              [Released] update or a boundary whose crossed turns recorded no
              edits. *)
    }
      (** The undo boundary was armed, moved, or released. The session
          {!Mentat_session.Undo.Update.t} holds only the anchor and revert id;
          this fact is that value plus the projector-computed presentation
          fields — the dropped-turn count and the per-file line stats resolved
          from the crossed turns' recorded change rows — so the TUI seam and the
          [/redo] affordance are pure functions of it, reconstructed on resume.
          The seam renders from this fact, never from ephemeral widget state. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same durable fact. Other
    payloads use their owners' equalities, arm by arm. *)

val jsont : t Jsont.t
(** [jsont] maps facts to versioned JSON objects by a per-arm tag, rejecting
    unknown tags, unknown members, and an unexpected envelope version. It
    composes the payload owners' codecs and re-encodes nothing. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a fact's arm tag, with the claim, turn, or decision correlation
    id when the arm carries one, for diagnostics. The output is not stable
    syntax. *)
