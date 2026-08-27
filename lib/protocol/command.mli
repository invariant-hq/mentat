(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session intents — the six-verb command sum.

    A command is admitted against one session and completes as a committed fact
    on that session's feed; that membership test is why the sum is exactly the
    six verbs below and nothing else. The type is one flat sum: the engine's
    command-to-action table matches every verb anyway. Frontends use the
    validating constructors and never match the private sum. Completions arrive
    on the feed with their natural correlation id (turn id, decision id) — no
    receipt vocabulary exists. {!prompt} runs from a [Turn_started] to a
    [Turn_settled]; {!answer_decision} yields a [Decision_resolved] and its
    consequents; {!interrupt} yields the forced settlements (a [Turn_settled]
    with an [Interrupted] outcome, any ambiguous or interrupted tool result)
    while the durable interrupt request itself projects to no fact; the queue
    verbs complete as a [Journal_queue].

    {b Commands carry no principal.} The answering principal is named only when
    a decision is resolved, never on the intent itself.

    {b Client-minted turn ids.} {!prompt}'s [turn] is client-minted, opaque, and
    host/pid/path-free. Resubmitting a prompt with the same turn id and a
    byte-identical payload is idempotent; the same id with a different payload
    is {!Error.Turn_id_reused}. The engine enforces both; this module only
    carries the id.

    {b Prompt carries content, not a turn input.} A prompt requests a user turn
    with a non-empty {!Mentat_llm.Content.t} list; the engine mints the
    {!Mentat_session.Turn.Input.User} after admission. The engine-only
    {!Mentat_session.Turn.Input.Continue} and
    {!Mentat_session.Turn.Input.Plan_build} are deliberately not command-
    constructible: exact approved-plan admission is engine policy, not a client
    intent. *)

(** {1:invalid Construction failures} *)

module Invalid : sig
  (** Local construction failures — the closed reasons a validating constructor
      rejects. A failure to build a command is a client-side programming error
      caught before submission, not a {!Error.t} that crosses the feed. *)

  (** The type for a rejected construction. *)
  type t =
    | Empty_prompt_input  (** {!prompt} was given an empty content list. *)
    | Non_positive_max_steps of int
        (** {!prompt}'s [max_steps] was present and not positive. *)
    | Empty_interrupt_reason
        (** {!interrupt}'s [reason] was present and empty. *)
    | Empty_queue_input  (** {!queue_next} was given an empty content list. *)
    | Empty_queue_replacement
        (** {!replace_queued} was given no replacement entries. *)
    | Empty_queue_entry of int
        (** Entry at the zero-based index was an empty content list. *)
    | Empty_triggered_member of string
        (** {!prompt}'s [triggered] had the named member empty. *)
    | Output_schema_not_object
        (** {!prompt}'s [output_schema] was present but not a JSON object. The
            supported-subset check is the executable's load-time responsibility;
            this is the command's defensive object re-check. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same failure. *)

  val message : t -> string
  (** [message t] is a human-readable diagnostic. Presentation only. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats {!message} output. *)
end

(** {1:commands Commands} *)

type triggered = { source : string; digest : string; key : string }
(** Trigger provenance declared at turn start: the trigger's identity as the
    scheduling host defines it, the digest sealing the policy content it fired
    under, and the key naming the event it fired on. When present on
    {!Prompt}, the engine mints the turn's origin as
    {!Mentat_session.Turn.Origin.Triggered} instead of
    {!Mentat_session.Turn.Origin.User}. Provenance is attribution, never
    authority: it changes nothing about how the turn is admitted or executed.
    All members are non-empty. *)

(** The type for session intents. Every verb targets exactly one session. *)
type t = private
  | Prompt of {
      session : Mentat_session.Id.t;
      turn : Mentat_session.Turn.Id.t;  (** Client-minted. *)
      input : Mentat_llm.Content.t list;  (** Non-empty. *)
      options : Mentat_llm.Request.Options.t option;
      mode : Mentat_session.Contract.Mode.t option;
      max_steps : int option;
      triggered : triggered option;
          (** Optional trigger provenance. When present, the engine mints the
              turn's origin as {!Mentat_session.Turn.Origin.Triggered}; absent,
              the turn admits as {!Mentat_session.Turn.Origin.User}. *)
      output_schema : Jsont.json option;
          (** An optional JSON Schema the turn's final answer must conform to.
              When present, the engine seals a synthetic [structured_output]
              tool carrying it and settles the turn on a validated call. It is a
              JSON object ({!Invalid.Output_schema_not_object}); the
              supported-subset check is the executable's load-time
              responsibility. Carrying it on the command gives every frontend
              and the daemon the same path and seals it into the replayable
              contract. *)
    }
      (** Start a user turn. The model, catalog, resolved permission posture,
          skills, and instruction toggles are deliberately absent: the
          executable seals the turn contract; the client requests, never
          resolves. *)
  | Answer_decision of {
      session : Mentat_session.Id.t;
      decision : Mentat_session.Decision.Id.t;
      answer : Mentat_session.Decision.Answer.t;
          (** Packed; the engine checks its kind against the pending decision.
          *)
    }  (** The one answer verb for every decision kind. *)
  | Interrupt of { session : Mentat_session.Id.t; reason : string option }
  | Queue_next of {
      session : Mentat_session.Id.t;
      id : Mentat_session.Queue.Id.t option;
          (** An optional client-minted entry id. When present, the engine
              records the entry under it and an entry already recorded under it
              — pending or consumed — makes the resubmission an idempotent
              [Ok]; absent, the engine mints a position-keyed id, so identical
              inputs stay distinct entries. Carried by delivery paths whose
              at-least-once re-drives must not duplicate the entry (a parent's
              recorded child message, delivered over the wire). *)
      origin : Mentat_session.Origin.t option;
          (** Optional message provenance, recorded into the entry the engine
              commits. Absent means the owner sent the input
              ({!Mentat_session.Origin}). Admission judges it — the engine
              refuses an entry whose sender the target session's recorded
              facts do not admit ({!Mentat_session.accepts_mail}) — but an
              admitted origin is attribution, never authority: it changes
              nothing about how the entry is consumed. *)
      input : Mentat_llm.Content.t list;
    }
  | Replace_queued of {
      session : Mentat_session.Id.t;
      inputs : Mentat_llm.Content.t list list;
    }  (** Replaces the pending queue with the ordered non-empty [inputs]. *)
  | Clear_queued of { session : Mentat_session.Id.t }

(** {1:constructors Constructors}

    Constructors validate locally so malformed commands are unrepresentable
    rather than runtime errors. The verbs with nothing to validate construct
    directly; the rest are [(t, Invalid.t) result]. *)

val prompt :
  session:Mentat_session.Id.t ->
  turn:Mentat_session.Turn.Id.t ->
  input:Mentat_llm.Content.t list ->
  ?options:Mentat_llm.Request.Options.t ->
  ?mode:Mentat_session.Contract.Mode.t ->
  ?max_steps:int ->
  ?triggered:triggered ->
  ?output_schema:Jsont.json ->
  unit ->
  (t, Invalid.t) result
(** [prompt ~session ~turn ~input ()] is a prompt command, or a failure if
    [input] is empty ({!Invalid.Empty_prompt_input}), [max_steps] is present and
    not positive ({!Invalid.Non_positive_max_steps}), [triggered] has an empty
    member ({!Invalid.Empty_triggered_member}), or [output_schema] is present
    but not a JSON object ({!Invalid.Output_schema_not_object}). *)

val answer_decision :
  session:Mentat_session.Id.t ->
  decision:Mentat_session.Decision.Id.t ->
  answer:Mentat_session.Decision.Answer.t ->
  t
(** [answer_decision ~session ~decision ~answer] answers pending decision
    [decision] with the packed [answer]. *)

val interrupt :
  session:Mentat_session.Id.t -> ?reason:string -> unit -> (t, Invalid.t) result
(** [interrupt ~session ?reason ()] requests a durable interrupt of the active
    turn, or {!Invalid.Empty_interrupt_reason} if [reason] is present and empty.
*)

val queue_next :
  ?id:Mentat_session.Queue.Id.t ->
  ?origin:Mentat_session.Origin.t ->
  session:Mentat_session.Id.t ->
  input:Mentat_llm.Content.t list ->
  unit ->
  (t, Invalid.t) result
(** [queue_next ?id ?origin ~session ~input ()] appends [input] to the
    next-turn queue, or {!Invalid.Empty_queue_input} if [input] is empty. [id]
    is the optional client-minted entry id and [origin] the optional message
    provenance; see {!Queue_next}. *)

val replace_queued :
  session:Mentat_session.Id.t ->
  inputs:Mentat_llm.Content.t list list ->
  (t, Invalid.t) result
(** [replace_queued ~session ~inputs] replaces the pending queue with one entry
    per element of [inputs], preserving order. It returns
    {!Invalid.Empty_queue_replacement} when [inputs] is empty or
    {!Invalid.Empty_queue_entry} with the offending zero-based index when an
    element is empty. *)

val clear_queued : session:Mentat_session.Id.t -> t
(** [clear_queued ~session] empties the pending queue. *)

(** {1:queries Queries} *)

val session : t -> Mentat_session.Id.t
(** [session t] is the one session [t] targets. Every command targets exactly
    one session. *)

(** {1:wire Wire} *)

val jsont : t Jsont.t
(** [jsont] maps commands to versioned JSON objects by a per-verb tag, rejecting
    unknown tags, unknown members, and an unexpected envelope version. Decoding
    re-runs the constructors' local validations, reporting an {!Invalid.t}
    reason as a structured decode error. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a command for diagnostics. The output is not stable syntax. *)
