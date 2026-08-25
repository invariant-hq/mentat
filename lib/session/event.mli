(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable session events — the sole truth.

    A session is an ordered list of these eighteen inert facts, and {!State.t}
    is their pure fold. One flat, private, pattern-matchable sum carries the
    whole product vocabulary — the readable-without-engine firewall: [eval],
    [trace], and the protocol projector match this variant directly and never
    link the planner.

    Events are inert, identity-free, and timestamp-free: no session id, no
    cursor, no wall-clock time, no callback. Timestamps live only in
    {!Metadata}. Constructors check only local shape; cross-event invariants are
    checked once, at replay, by {!State.apply}.

    {b Openers and closers.} A provider call, a tool call, and a decision each
    have one {e opener} that installs the turn's single suspension —
    {!Provider_requested}, {!Tool_claimed}, {!Decision_requested} — and one
    {e closer} that clears it — {!Provider_settled}, {!Tool_settled},
    {!Decision_resolved}. A settlement is terminal for its claim: replay rejects
    a second closer as not-pending, so a late or duplicate result fails loudly
    rather than overwriting a terminal. Because a claim is recorded before its
    effect runs, a crash leaves an open claim that recovery settles ambiguously
    — never a fabricated success, never a re-issued effect. *)

(** The type for a durable session event. *)
type t = private
  | Turn_started of Turn.t  (** An accepted turn started. *)
  | Interrupt_requested of { turn : Turn.Id.t; reason : string option }
      (** A durable interrupt was requested for [turn]. After it, openers are
          rejected; settlements, an interrupted terminal outcome, and
          non-bypassing reconciliation tool results stay admissible. A repeated
          interrupt request for the same active turn is idempotent, not an
          error. *)
  | Turn_finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }
      (** An accepted turn reached a terminal outcome. Every outcome requires a
          request-ready model transcript and no open suspension. *)
  | Message_appended of Mentat_llm.Message.t
      (** A non-assistant model-visible message was appended. Assistant output
          is recorded through {!Provider_settled}, so this arm never carries an
          assistant message. A tool result that bypasses an open claim or
          decision — one answering the call that suspension holds — is rejected
          at replay; every other tool result is an ordinary append. *)
  | Provider_requested of Provider_request.Started.t
      (** Opener: a provider call was claimed before it was issued and installs
          the turn's suspension. *)
  | Provider_settled of Provider_request.Settled.t
      (** Closer for a provider claim — responded, interrupted, or ambiguous —
          and clears the suspension. Terminal: a second settlement is
          not-pending. *)
  | Tool_claimed of Tool_claim.Started.t
      (** Opener: an executable tool call was claimed before it ran, one of the
          two staged claims or a single direct claim. *)
  | Tool_settled of Tool_claim.Settled.t
      (** Closer for a tool claim — prepared, returned, or ambiguous — and
          clears the suspension. A [Prepared] settlement is terminal for its
          prepare claim yet leaves the model call pending for the run claim. *)
  | Decision_requested of Decision.Requested.t
      (** Opener: a blocked call is waiting for a typed answer. *)
  | Decision_resolved of Decision.Resolved.t
      (** Closer for a decision; first valid answer wins and a second resolution
          for a resolved id is not-pending. *)
  | Compaction_installed of Compaction.t
      (** A summary established a model-replay context boundary. Also the closer
          of the summary call's provider claim: it must name the currently open
          provider suspension and clears it, so "summarized but not installed"
          is unrepresentable — a crash mid-summary instead leaves that claim
          open for ordinary ambiguous recovery. *)
  | Tasks_replaced of Task.Board.t  (** The task board was replaced whole. *)
  | Delegation_recorded of Delegation.t
      (** A subagent delegation edge was recorded. *)
  | Delegations_detached
      (** A branch detached the live child ownership inherited in its copied
          prefix. Historical calls and results remain in the transcript, but
          {!State.delegations} restarts empty. *)
  | Queue_updated of Queue.Update.t  (** The next-turn queue changed. *)
  | Workspace_notice of Notice.t
      (** A workspace runtime observation — a filesystem-watcher batch or a dune
          build-health change — recorded against the active turn it entered.
          Unlike a prelude datum, it is a durable, replay-faithful part of the
          model's context for {e its own turn only}: replay reconstructs exactly
          the observation that turn saw, and a later turn carries its own, never
          this one. A notice is an external observation, not derived state, so
          storing it does not violate the derived-facts-are-never-stored law.
          Admitted only while a turn is active. *)
  | Undo_updated of Undo.Update.t
      (** The durable undo boundary was armed, moved, or released — the [/undo]
          [/redo] affordance's persistent half. While armed it excludes the
          crossed transcript suffix from the model view (a suffix cut, the
          mirror of {!Compaction_installed}'s prefix cut) and names the ledger
          revert that took the working tree back. Admitted only at an idle head:
          arming anchors at a finished user turn whose first message is at or
          after the model-context head, so the excluded suffix stays inside the
          live tail. A commit does not record an update — it truncates the
          crossed turns and their boundary events out of the journal. *)

val turn_started : Turn.t -> t
(** [turn_started turn] records accepted turn [turn]. *)

val interrupt_requested : turn:Turn.Id.t -> ?reason:string -> unit -> t
(** [interrupt_requested ~turn ?reason ()] records a durable interrupt request.

    Raises [Invalid_argument] if [reason] is present and empty. *)

val turn_finished : turn:Turn.Id.t -> Turn.Outcome.t -> t
(** [turn_finished ~turn outcome] records [turn]'s terminal outcome. *)

val message_appended : Mentat_llm.Message.t -> t
(** [message_appended message] records a non-assistant model-visible message.

    Raises [Invalid_argument] if [message] is an assistant message; completed
    provider responses use {!Provider_settled}. *)

val provider_requested : Provider_request.Started.t -> t
(** [provider_requested claim] records a provider-request claim. *)

val provider_settled : Provider_request.Settled.t -> t
(** [provider_settled settlement] records a provider-request settlement. *)

val tool_claimed : Tool_claim.Started.t -> t
(** [tool_claimed claim] records a tool claim. *)

val tool_settled : Tool_claim.Settled.t -> t
(** [tool_settled settlement] records a tool-claim settlement. *)

val decision_requested : Decision.Requested.t -> t
(** [decision_requested request] records a pending decision. *)

val decision_resolved : Decision.Resolved.t -> t
(** [decision_resolved resolution] records a decision resolution. *)

val compaction_installed : Compaction.t -> t
(** [compaction_installed compaction] records a compaction boundary. *)

val tasks_replaced : Task.Board.t -> t
(** [tasks_replaced board] records a whole-board replacement. *)

val delegation_recorded : Delegation.t -> t
(** [delegation_recorded edge] records a delegation edge. *)

val delegations_detached : t
(** [delegations_detached] records that a branch owns none of the delegation
    edges in its preceding copied prefix. *)

val queue_updated : Queue.Update.t -> t
(** [queue_updated update] records a next-turn queue mutation. *)

val workspace_notice : Notice.t -> t
(** [workspace_notice notice] records a workspace runtime observation against
    the active turn. Replay admits it only while a turn is active. *)

val undo_updated : Undo.Update.t -> t
(** [undo_updated update] records an undo-boundary update. Replay admits it only
    at an idle head and, when arming, requires the anchor to be a finished user
    turn whose first message is at or after the model-context head. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same event. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats an event for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps events to JSON values by a per-arm tag, rejecting unknown event
    tags and unknown members. Decoding runs each constructor's local checks;
    replay validity is {!State.of_events}'s. *)
