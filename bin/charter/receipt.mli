(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Typed charter receipts.

    A charter's durable record is an append-only JSONL log, one line per
    receipt. A receipt states one fact about one triggering event: the event
    arrived ({!Kind.Delivery}), what was decided about it
    ({!Kind.Disposition}), what was published for it ({!Kind.Egress}), or
    that the owner was alerted ({!Kind.Alert}). The vocabulary is a closed
    sum: {!decode} rejects an unknown kind or member, so the log can never
    silently carry a fact this module does not understand. The module is
    pure — no I/O and no clock reads; writing and reading the log is the
    caller's business. *)

(** Alert transitions — the alertable moments of an unattended run.

    This is also the whole vocabulary a charter's [notify.on] member may
    name: a notification policy names transitions of this type and nothing
    else. *)
module Transition : sig
  type t =
    | Failed  (** A run settled without a publishable outcome. *)
    | Parked  (** A run stopped on a question only a human can answer. *)
    | Fenced  (** A budget fence refused an admission. *)

  val of_string : string -> t option
  (** [of_string s] is the transition named [s] (["failed"], ["parked"], or
      ["fenced"]), or [None]. *)

  val to_string : t -> string
  (** [to_string t] is ["failed"], ["parked"], or ["fenced"]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same transition. *)
end

(** Budget meters — the per-charter admission fences. *)
module Meter : sig
  type t =
    | Usd_per_day  (** Derived spend over the trailing 24 hours. *)
    | Runs_per_hour  (** Spawned runs over the trailing hour. *)

  val to_string : t -> string
  (** [to_string t] is ["usd_per_day"] or ["runs_per_hour"]. *)

  val window : t -> float
  (** [window t] is the meter's trailing window in seconds: 86400 for
      {!Usd_per_day}, 3600 for {!Runs_per_hour}. Windows trail the query
      instant; they are never calendar buckets, so no midnight burst and no
      daylight-saving edge exists. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same meter. *)
end

(** Journal-head outcomes, as observed when a run child is reaped. *)
module Head : sig
  type t =
    | Settled  (** The session head settled under its contract. *)
    | Interrupted  (** The head settled as an interrupt. *)
    | Parked  (** Unsettled, holding a pending decision. *)
    | Unsettled  (** Unsettled, no pending decision. *)
    | Missing  (** The child left no session journal. *)

  val to_string : t -> string
  (** [to_string t] is the outcome's name: ["settled"], ["interrupted"],
      ["parked"], ["unsettled"], or ["missing"]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same outcome. *)
end

(** Reap causes — why a run child was reaped. *)
module Cause : sig
  type t =
    | Exited  (** The child exited on its own. *)
    | Wall_clock  (** The per-run wall-clock deadline expired. *)
    | Interrupted
        (** A stop request forced the reap before the child settled. *)
    | Park_expired  (** The park TTL expired on a pending decision. *)
    | Recovered
        (** The child was found dead and its head settled honestly by a
            successor. *)

  val to_string : t -> string
  (** [to_string t] is the cause's name: ["exited"], ["wall_clock"],
      ["interrupted"], ["park_expired"], or ["recovered"]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same cause. *)
end

(** Dispositions — what was decided about a delivered event. *)
module Disposition : sig
  type t =
    | Spawned of { session : string }
        (** A run child was spawned for the event, on the derived session
            [session]. The receipt is the audit record binding the event to
            its run: the session id is stamped here because it cannot be
            re-derived from a receipt's identity string alone. *)
    | Skipped of string  (** The gate refused it, for the carried reason. *)
    | Dup  (** An identical event identity already holds a receipt. *)
    | Fenced of Meter.t  (** A budget fence refused the admission. *)
    | Already_exists
        (** The derived session id collided with an existing session. *)
    | Superseded  (** A fresher head for the same pull request arrived. *)
    | Refused of string
        (** Admission failed before the gate, for the carried reason. *)
    | Reaped of {
        session : string;  (** The reaped run's session id. *)
        exit : int;  (** The child's exit code, [0] to [255]. *)
        head : Head.t;  (** The journal head's outcome at reap. *)
        usage : Jsont.json;
            (** The run's token usage, an opaque JSON object preserved
                verbatim for diagnosis; never interpreted here. *)
        usd : float option;
            (** The run's derived cost; [None] when no rate priced a spent
                lane, which degrades the charter to its run-count fence. *)
        cause : Cause.t;  (** Why the child was reaped. *)
      }  (** The run ended and its spend was stamped. *)

  val name : t -> string
  (** [name t] is [t]'s wire token — the [disposition] member {!val:encode}
      writes and {!val:decode} routes on: ["spawned"], ["skipped"], ["dup"],
      ["fenced"], ["already_exists"], ["superseded"], ["refused"], or
      ["reaped"]. Status projections build their labels on it, so a label
      can never drift from the log's own vocabulary. *)
end

(** Receipt kinds — the closed sum of facts a receipt line may state. *)
module Kind : sig
  type t =
    | Delivery  (** The event arrived and was durably recorded. *)
    | Disposition of Disposition.t  (** What was decided about it. *)
    | Egress of {
        summary : [ `Created | `Updated | `None_needed | `Skipped_no_token ];
        threads : int;
      }
        (** What the publisher concluded: whether the summary comment was
            created, updated, or — a clean suppressed run with nothing
            posted before — the publisher converged with nothing to write,
            and how many finding threads were posted. [`None_needed] is a
            real egress fact: without it a settled run with no comment
            would look egress-less forever and be re-published on every
            reconcile pass. [`Skipped_no_token] states honestly that the
            run completed but no write credential existed to publish with —
            publication was skipped, not attempted, and the fold treats the
            run's egress as decided rather than pending. *)
    | Alert of {
        transition : Transition.t;
        window : [ `Meter of Meter.t | `Identity ];
      }
        (** The owner was alerted for [transition]; [window] types the
            dedup scope — the tripped meter for a fence trip, or the
            receipt's own event identity — so a later query can tell
            whether this window already alerted. *)
end

type t = {
  at : float;  (** Seconds since the epoch, UTC; never negative. *)
  identity : string;  (** The triggering event's identity string. *)
  digest : string;
      (** The charter policy digest in force when the receipt was written,
          in lowercase hexadecimal. Fence folds count only receipts stamped
          with the digest under evaluation, so a policy edit resets every
          window. *)
  kind : Kind.t;  (** The fact this receipt states. *)
}
(** The type for receipts. *)

(** Decode errors. *)
module Error : sig
  type t
  (** The type for strict-decode errors: which member of a receipt line is
      unacceptable, and why. *)

  val message : t -> string
  (** [message e] is [e]'s one-line diagnostic. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

val encode : t -> string
(** [encode t] is [t] as one line of minified JSON, without a trailing
    newline; an appender frames lines with ['\n']. Every string member is
    JSON-escaped, so the line never contains a raw newline. *)

val decode : string -> (t, Error.t) result
(** [decode line] is the receipt [line] denotes, where [line] carries no
    trailing newline. The read is strict: malformed JSON, an unknown or
    duplicate member, a missing member, a wrongly-typed member, an unknown
    kind, disposition, meter, transition, head outcome, or cause, an alert
    window that names neither a meter nor ["identity"], a negative or
    non-finite timestamp, an empty identity or session, a digest that is not
    lowercase hexadecimal, an exit code outside [0]–[255], or a negative
    cost or thread count is an [Error] naming the offending part. The
    [usage] member of a reaped disposition must be a JSON object and is
    otherwise preserved without interpretation. *)

(** {1:folds Log queries}

    Pure folds over a receipt list, clockless — the questions admission asks
    that key on the record itself rather than on a trailing time window
    (those live in {!Fence}). *)

val spawn_recorded : digest:string -> identity:string -> t list -> bool
(** [spawn_recorded ~digest ~identity receipts] is [true] iff [receipts]
    carries a spawned disposition for [identity] stamped [digest]. This is
    the torn-claim discriminator: a run-claim marker without a matching
    spawned line belongs to a claimer that died — or refused — between
    committing the claim and spawning the run, so a later pass finding the
    marker held consults this fold to tell a completed commitment from an
    abandoned one it may adopt. *)

val settled_session : digest:string -> identity:string -> t list -> string option
(** [settled_session ~digest ~identity receipts] is the session of the last
    reaped disposition for [identity] under [digest] whose child exited 0
    with a settled head — the one run whose findings are publishable — or
    [None] when no such reap exists. *)

val egress_recorded : digest:string -> identity:string -> t list -> bool
(** [egress_recorded ~digest ~identity receipts] is [true] iff [receipts]
    carries an egress receipt for [identity] stamped [digest] — the
    publisher concluded, whichever way. A settled run with findings and no
    egress line is the one state a reconcile pass re-publishes. *)

val alerted : digest:string -> identity:string -> transition:Transition.t -> t list -> bool
(** [alerted ~digest ~identity ~transition receipts] is [true] iff
    [receipts] carries an alert receipt for [transition] with the
    identity-scoped window — an alert whose [window] is [`Identity] — for
    [identity] under [digest]. An identity-scoped alert fires once per
    event, ever: the window is the event itself, not a trailing duration,
    so the fold reads no clock. *)

val diagnostic : t -> string
(** [diagnostic t] is [t] rendered as one human-readable line: the UTC
    timestamp in RFC 3339 form, the fact's name, the event identity, and the
    kind's payload. This is the projection status verbs print; it is for
    people, and no consumer may parse it — {!decode} is the machine
    surface. *)
