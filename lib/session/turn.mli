(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable session turns.

    A turn is one accepted model/tool loop in a session. It records the stable
    turn identity, why the turn was admitted ({!Origin}), the accepted input,
    the step limit, and the sealed {!Contract.t} that fixes the mode, model,
    tools, permission policy, and sandbox for the whole loop.

    Turns are inert data. They are not live handles and cannot be used to await,
    cancel, stream, or inspect in-progress execution. State replay permits at
    most one active unfinished turn at a time and validates that turn ids are
    unique per session. *)

(** {1:ids Identifiers} *)

module Id : sig
  type t
  (** The type for stable turn identifiers.

      Ids are client-minted, opaque, and free of host, pid, and path. Replay
      validates per-session uniqueness; command-level idempotency for a
      re-submitted id is the protocol's concern.

      Invariant: an identifier's stable textual form is non-empty. *)

  val of_string : string -> t
  (** [of_string s] is [s] as a turn id.

      Raises [Invalid_argument] if [s] is empty. *)

  val to_string : t -> string
  (** [to_string id] is [id]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same turn id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representations,
      compatibly with {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an id for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps turn ids to JSON strings, validating the non-empty invariant
      of {!of_string} on decode. *)
end

(** {1:origins Origins} *)

module Origin : sig
  (** The type for why a turn was admitted. *)
  type t =
    | User  (** A user prompt started the turn. *)
    | Queued of Queue.Id.t
        (** The turn admits queued entry [id]; admission consumes it. *)
    | Triggered of { source : string; digest : string; key : string }
        (** A trigger host admitted the turn on behalf of trigger [source] —
            the trigger's identity as the scheduling host defines it. [digest]
            seals the policy content the trigger fired under; [key] names the
            event it fired on. Provenance is attribution, never authority: the
            origin records who admitted the prompt and grants nothing — the turn
            executes under its sealed contract exactly as a {!User} turn does,
            and a forged provenance misleads only its own journal. All members
            are non-empty. *)
    | Plan_build  (** The Build turn a plan approval admits. *)
    | Compaction
        (** A user-requested manual compaction. The turn accepts only
            {!Input.Continue}, issues exactly one summary provider call,
            installs the compaction fact, and settles — it records no user
            speech, and its turn-boundary facts are not projected (only its
            [Compaction] fact is). Automatic
            compaction never uses this origin: it is a prelude within the
            requesting turn. *)
    | Step_limit_wind_down
        (** The one wrap-up turn the engine admits after a turn settled
            {!Outcome.Step_limit}: it asks the model to park what is in flight
            and state where the work stands. A turn carrying this origin never
            admits another wind-down, so the mechanism cannot repeat. *)

  val triggered : source:string -> digest:string -> key:string -> t
  (** [triggered ~source ~digest ~key] is {!Triggered} with every member
      checked non-empty — the one construction that validates, and the path
      the codec decodes through, so a producer that minted through it can
      never write a [Triggered] origin its own replay rejects.

      Raises [Invalid_argument] if any member is empty. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same origin. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an origin for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps origins to JSON values by a per-arm tag, rejecting unknown
      tags and members. Decoding validates the non-empty members of
      {!Triggered}. *)
end

(** {1:inputs Accepted inputs} *)

module Input : sig
  (** Accepted turn inputs. *)

  (** The type for accepted turn inputs. *)
  type t = private
    | User of Mentat_llm.Content.t list
        (** The turn starts by appending a user message with this non-empty
            content. *)
    | Continue
        (** The turn continues execution from the current transcript without
            appending a user message. *)
    | Plan_build of Plan.Approval.t
        (** The exact approval a Build turn consumes. [`Current] keeps the
            existing model transcript after its canonical approval result;
            [`Fresh] establishes a new model-context boundary and seeds it with
            the approved plan and optional feedback. *)

  val user : Mentat_llm.Content.t list -> t
  (** [user content] is a user turn input.

      Raises [Invalid_argument] if [content] is empty. *)

  val user_text : string -> t
  (** [user_text s] is a user turn input with one text block.

      Raises [Invalid_argument] if [s] is empty. *)

  val text : t -> string option
  (** [text t] is the user-visible text of [t]. For {!User}, text blocks are
      joined with single spaces and non-text blocks are skipped, yielding [None]
      when no text block is present. For {!Plan_build}, it is
      {!Plan.Approval.to_model_text}; for {!Continue}, it is [None].

      Owed consumer: the deferred [sessions]/[session] summary queries (the
      session picker/summary line). *)

  val continue : t
  (** [continue] is an input that resumes from the current transcript without
      appending a message. *)

  val plan_build : Plan.Approval.t -> t
  (** [plan_build approval] is the typed input for the Build turn admitted by
      [approval]. Replay requires exact equality with the preceding settled
      approval and rejects this input under any origin other than
      {!Origin.Plan_build}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same turn input. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an input for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps turn inputs to JSON values by a per-arm tag. Decoding
      validates the non-empty user-content invariant and delegates plan-build
      approval validation to {!Plan.Approval.jsont}. *)
end

(** {1:outcomes Terminal outcomes} *)

module Outcome : sig
  (** Terminal turn outcomes. *)

  (** The type for terminal turn outcomes. *)
  type t = private
    | Completed  (** The turn reached an ordinary terminal point. *)
    | Step_limit
        (** The execution loop stopped at its configured step limit. Like
            {!Completed}, this is a clean outcome. *)
    | Interrupted of { reason : string option; cancelled : bool }
        (** The turn was interrupted by the host or user. [reason], when
            present, is non-empty. [cancelled] is [true] iff a user or host
            interrupt request forced the outcome, [false] when the system
            settled the turn interrupted on its own (e.g. an ambiguous provider
            outcome at crash recovery). Owed consumers: the frontend settle line
            via the protocol's [Turn_settled] fact, and child-settlement
            messaging (which today renders it through {!pp}). *)
    | Failed of { message : string }
        (** The turn failed before reaching a normal terminal point. [message]
            is a non-empty diagnostic, not stable syntax for programmatic
            handling. *)

  val completed : t
  (** [completed] is {!Completed}. *)

  val step_limit : t
  (** [step_limit] is {!Step_limit}. *)

  val interrupted : ?reason:string -> cancelled:bool -> unit -> t
  (** [interrupted ?reason ~cancelled ()] is an interrupted outcome.

      Raises [Invalid_argument] if [reason] is present and empty. *)

  val failed : message:string -> t
  (** [failed ~message] is a failed outcome.

      Raises [Invalid_argument] if [message] is empty. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same outcome. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an outcome for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps turn outcomes to JSON values, validating non-empty
      interrupted reasons and failure messages. *)
end

(** {1:turns Turns} *)

type t
(** The type for an accepted turn start.

    Invariant: [max_steps] is positive and the embedded {!Contract.t} satisfies
    its declaration/host-tool contract. State replay also requires the turn id
    to be unique and no other turn to be active. *)

val make :
  id:Id.t ->
  origin:Origin.t ->
  input:Input.t ->
  max_steps:int ->
  contract:Contract.t ->
  unit ->
  t
(** [make ~id ~origin ~input ~max_steps ~contract ()] is an accepted turn start.

    [max_steps] is the positive model-response limit accepted for this turn.

    Raises [Invalid_argument] if [max_steps] is not positive. *)

val id : t -> Id.t
(** [id t] is [t]'s stable id. *)

val origin : t -> Origin.t
(** [origin t] is why [t] was admitted. *)

val input : t -> Input.t
(** [input t] is [t]'s accepted input. *)

val max_steps : t -> int
(** [max_steps t] is [t]'s accepted execution-loop step limit. *)

val contract : t -> Contract.t
(** [contract t] is [t]'s sealed execution contract; read the model, tool
    declarations, permission policy, and sandbox from it. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] contain the same turn data. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a turn for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps turns to JSON values. Decoding validates local constructor
    invariants; replay validity is checked by {!State.apply}. *)
