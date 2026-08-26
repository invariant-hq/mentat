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

  val of_string : string -> t option
  (** [of_string s] is the outcome named [s] (["settled"], ["interrupted"],
      ["parked"], ["unsettled"], or ["missing"]), or [None]. *)

  val to_string : t -> string
  (** [to_string t] is the outcome's name. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same outcome. *)
end

(** Reap causes — why a run child was reaped. *)
module Cause : sig
  type t =
    | Exited  (** The child exited on its own. *)
    | Wall_clock  (** The per-run wall-clock deadline expired. *)
    | Park_expired  (** The park TTL expired on a pending decision. *)
    | Recovered
        (** The child was found dead and its head settled honestly by a
            successor. *)

  val of_string : string -> t option
  (** [of_string s] is the cause named [s] (["exited"], ["wall_clock"],
      ["park_expired"], or ["recovered"]), or [None]. *)

  val to_string : t -> string
  (** [to_string t] is the cause's name. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same cause. *)
end

(** Dispositions — what was decided about a delivered event. *)
module Disposition : sig
  type t =
    | Spawned  (** A run child was spawned for the event. *)
    | Skipped of string  (** The gate refused it, for the carried reason. *)
    | Dup  (** An identical event identity already holds a receipt. *)
    | Fenced of Meter.t  (** A budget fence refused the admission. *)
    | Already_exists
        (** The derived session id collided with an existing session. *)
    | Superseded  (** A fresher head for the same pull request arrived. *)
    | Refused of string
        (** Admission failed before the gate, for the carried reason. *)
    | Reaped of {
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
end

(** Receipt kinds — the closed sum of facts a receipt line may state. *)
module Kind : sig
  type t =
    | Delivery  (** The event arrived and was durably recorded. *)
    | Disposition of Disposition.t  (** What was decided about it. *)
    | Egress of {
        summary : [ `Created | `Updated | `None_needed ];
        threads : int;
      }
        (** What the publisher concluded: whether the summary comment was
            created, updated, or — a clean suppressed run with nothing
            posted before — the publisher converged with nothing to write,
            and how many finding threads were posted. [`None_needed] is a
            real egress fact: without it a settled run with no comment
            would look egress-less forever and be re-published on every
            reconcile pass. *)
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
    non-finite timestamp, an empty identity, a digest that is not lowercase
    hexadecimal, an exit code outside [0]–[255], or a negative cost or
    thread count is an [Error] naming the offending part. The
    [usage] member of a reaped disposition must be a JSON object and is
    otherwise preserved without interpretation. *)

val diagnostic : t -> string
(** [diagnostic t] is [t] rendered as one human-readable line: the UTC
    timestamp in RFC 3339 form, the fact's name, the event identity, and the
    kind's payload. This is the projection status verbs print; it is for
    people, and no consumer may parse it — {!decode} is the machine
    surface. *)
