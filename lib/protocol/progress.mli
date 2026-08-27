(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Ephemeral progress.

    Progress is a distinct type from {!Fact.t}: never persisted, never returned
    by the projector, droppable and coalescible without changing any durable
    projection. Every pulse carries the {!turn} it reports on. Model and
    compaction pulses also carry the identifiers of the fact that supersedes
    them: {!Model.Assistant_delta} streams the text the eventual assistant fact
    carries authoritatively — a frontend that accumulates deltas discards its
    buffer when the fact lands. The compaction arms report the automatic
    attempt; dropping them loses only animation, because the durable outcome is
    either the installed compaction fact or nothing. A manual compaction's
    result is never only a pulse — it completes through its flow's typed result.
    A notice pulse is ambient by design: notices are never journaled, so no fact
    supersedes it and dropping it loses only the ambient display — the
    model-visible effect is the notice's presence in the drained turn's request
    prelude. A model-download pulse reports the transparent preparation of a
    local model's weights before a call; no fact supersedes it, so dropping it
    loses only the preparation display, because the durable outcome is the
    eventual assistant fact or a startup provider error.

    {b The model-pulse omission law.} {!Model.t} is a deliberate display
    projection of {!Mentat_llm.Event.t}, not a mirror. It renames the provider's
    [Text_delta] and [Reasoning_summary_delta] to {!Model.Assistant_delta} and
    {!Model.Reasoning_delta}, carries [Usage] and [Retry] (as {!Model.Retrying})
    verbatim, adds a synthetic {!Model.Started} the provider vocabulary has no
    arm for, and projects [Tool_input_delta] onto {!Model.Tool_input} with the
    input text deliberately stripped: a tool call's canonical input is
    reconciled durably from the terminal response and projects as the
    {!Fact.Tool_started}/{!Fact.Tool_returned} facts, never an early-run pulse,
    so the pulse carries only the call's liveness — the tool name and a
    cumulative byte count, a snapshot whose latest arrival is the whole display
    truth, never an increment a consumer accumulates. [Tool_call] stays omitted
    entirely, superseded by those same facts. The liveness arm exists because a
    step that streams only tool input would otherwise pulse nothing for its
    whole generation, and the frontend would show an apparently hung call.

    The sums are non-private: an empty message is locally constructible and
    rejected by {!jsont}'s strict decode; the engine's pulse producers are the
    sole intended constructors.

    There is deliberately no tool-progress arm (the tool library has no update
    producer) and no account arm (account progress rides the login flow's own
    completion). *)

module Model : sig
  (** The type for model-call progress. *)
  type t =
    | Started
        (** The provider call is in flight; superseded by the assistant fact. *)
    | Assistant_delta of { text : string }
    | Reasoning_delta of { text : string }
    | Usage of Mentat_llm.Usage.t
        (** Per-step snapshot; the durable totals ride the turn's facts. *)
    | Tool_input of { name : string option; received : int }
        (** The stream is writing a tool call's input: [name] is the tool being
            called once the provider has named it, and [received] is the
            cumulative input bytes of that call so far — positive, and a
            snapshot, so a dropped pulse only coarsens the latest count. A
            provider retry restarts the stream and its counts with it.
            Superseded by the {!Fact.Tool_started} the terminal response
            commits; the input text itself is never carried (the omission law
            above). *)
    | Retrying of Mentat_llm.Event.Retry.t
        (** The provider adapter announced an upcoming call retry; superseded by
            the next pulse of the same call — a delta once an attempt succeeds —
            or by the turn's terminal facts when the budget is exhausted. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same model pulse, by the
      payload owners' equalities. *)
end

module Model_download : sig
  (** The type for model-artifact download progress: the transparent preparation
      of a local model's weights before its first call. The vocabulary is
      provider-neutral so any future artifact fetch reuses it — the provider
      adapter keeps its download state, checksums, and mirror selection private
      and adapts them onto these fields at the composition edge. Unlike the
      other arms, a download pulse is superseded by no fact: the durable outcome
      is the model call itself. *)
  type phase =
    | Checking  (** Resolving local state and remote metadata. *)
    | Downloading  (** Transferring bytes. *)
    | Verifying  (** Checking the fetched artifact before installation. *)
    | Ready  (** Installed and available; the model call proceeds. *)

  type t = {
    model : string;  (** Provider-local id of the model being prepared. *)
    received : int64;  (** Bytes transferred or verified so far. *)
    total : int64 option;  (** Total byte count when the source declares it. *)
    phase : phase;
  }

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same download pulse. *)
end

module Compaction : sig
  (** The type for automatic-compaction progress. The vocabulary is exactly the
      arms an engine producer emits: [Started] when a summary call begins,
      [Summarizing] while it streams, [Failed] when it cannot install. There is
      deliberately no [Retrying] or [Skipped] arm — no producer emits either,
      and a manual compaction's skip is its flow result, not a pulse — and
      [Started] carries no token estimate, because no producer has one. *)
  type t =
    | Started of { reason : Mentat_session.Compaction.Reason.t }
    | Summarizing
    | Failed of {
        reason : Mentat_session.Compaction.Reason.t;
        message : string;  (** Non-empty. *)
      }

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same compaction pulse, by
      the payload owners' equalities. *)
end

(** The type for progress pulses. *)
type t =
  | Model of { turn : Mentat_session.Turn.Id.t; update : Model.t }
  | Model_download of {
      turn : Mentat_session.Turn.Id.t;
      update : Model_download.t;
    }
      (** Transparent preparation of [turn]'s model artifact before its call. *)
  | Compaction of { turn : Mentat_session.Turn.Id.t; update : Compaction.t }

val turn : t -> Mentat_session.Turn.Id.t
(** [turn t] is the turn [t] reports on — the routing key a frontend uses to
    attach a pulse to that turn's rendering and to retire pulses when the
    turn's superseding facts land. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same pulse. Composed from the
    payload owners' equalities, arm by arm. *)

val jsont : t Jsont.t
(** [jsont] maps pulses to versioned JSON objects by a per-arm tag, rejecting
    unknown tags, unknown members, an unexpected envelope version, and empty
    messages. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a pulse's arm tag and its {!turn} for diagnostics. The output
    is not stable syntax. *)
