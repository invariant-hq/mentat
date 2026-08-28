(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The steward's goal vocabulary: the continuation framing, the [goal_status]
    claim, and the continue-or-stop decision.

    A goal is recorded intent on a session
    ({!Mentat_session.Metadata.Goal}); the steward — the process driving the
    session — reads it at each finished judgment and decides whether to send
    another continuation. Everything here is pure: the loop that acts on a
    {!Verdict.t} lives in the steward processes, never in this unit and never
    in the engine. *)

(** The [goal_status] claim — what a continuation turn declares about the
    goal. *)
module Claim : sig
  type t =
    | Done of string option
        (** The model declares the goal reached; the optional note says how it
            concluded. *)
    | Continuing of string option
        (** The model declares more work remains; the optional note says what
            is next. *)

  val of_json : Jsont.json -> t option
  (** [of_json json] is the claim [json] declares, or [None] when [json] does
      not carry one — an unknown status, a missing member, any malformed
      shape. Absence means continue, so a claim the steward cannot read stops
      nothing and fails nothing. *)

  val schema : Jsont.json
  (** [schema] is the JSON schema of the claim — [{status: done | continuing,
      note?}] — the output schema a steward seals on the continuation turn so
      the model can deliver the claim as a structured answer. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same claim. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a claim for diagnostics. *)
end

(** The steward's continue-or-stop verdict. *)
module Verdict : sig
  type t =
    | Continue  (** Send the next continuation. *)
    | Done of string option
        (** The model declared the goal reached; the note is the claim's. *)
    | Bound_reached  (** The recorded turn bound is spent. *)
    | Budget_spent  (** The recorded dollar budget is spent. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same verdict. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a verdict for diagnostics. *)
end

val continuation : objective:string -> string
(** [continuation ~objective] is the framed continuation text every steward
    sends — the goal named, then the [goal_status] instruction. One constant
    framing, so the transcript always shows who continued the work and why,
    and the journal count of framed continuations stays derivable. *)

val continuations : objective:string -> Mentat_session.t -> int
(** [continuations ~objective session] is how many continuation turns for
    [objective] the journal holds — the turns whose input opens with the
    {!continuation} framing for exactly this objective. Derived, never
    persisted: a resumed steward and the one that sent the turns count the
    same journal. Re-declaring the identical objective continues the same
    ledger; a fresh objective starts at zero. *)

val decide :
  goal:Mentat_session.Metadata.Goal.t ->
  finished:bool ->
  claim:Jsont.json option ->
  continuations:int ->
  spent:float option ->
  Verdict.t option
(** [decide ~goal ~finished ~claim ~continuations ~spent] is the steward's one
    decision, or [None] while the session is not finished — the loop fires on
    the finished judgment alone (settled head, empty queue), so user input
    preempts it by construction.

    [claim] is the head turn's structured-output claim
    ({!Mentat_agent.Catalog.claim}); [continuations] is how many goal
    continuations the steward has already spent, derived from the journal;
    [spent] is the journal's whole cost fold in dollars, [None] when the
    model is unpriced.

    The arms, in order: a claim declaring done is {!Verdict.Done} — the
    honest completion beats every bound; a spent turn bound is
    {!Verdict.Bound_reached}; a spent budget is {!Verdict.Budget_spent};
    everything else — a continuing claim, an absent claim, an unreadable
    claim — is {!Verdict.Continue}: ending the goal takes the explicit
    declaration, a bound, or the owner, never the model forgetting. An
    unpriced spend ([None]) trips no budget: the turn bound and the owner
    remain the fences. *)
