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

  val label : t -> string
  (** [label t] is the one-word status label every status surface prints
      for [t]: {!name}, suffixed with the tripped meter for a fenced
      disposition (["fenced:usd_per_day"]) and with the exit code for a
      reaped one (["reaped:0"]). One projection, so the CLI roster and the
      dashboard can never disagree on the same fact. *)
end

(** The re-drivable half of an admitted delivery. *)
module Delivery : sig
  type t = {
    action : string;  (** The delivery's action, for example ["opened"]. *)
    base_ref : string;  (** The base branch name. *)
    draft : bool;  (** Whether the pull request is a draft. *)
    author_association : string;
        (** The author's association, GitHub's uppercase token. *)
  }
  (** The type for a delivery receipt's event members: exactly the decoded
      members the gate needs that the receipt's identity string does not
      already carry (the identity names the repository, number, and head).
      Together they let a reconcile pass re-synthesize the admitted event
      and drive an acknowledged-then-lost delivery to its disposition —
      without them a 202'd event whose process died before deciding would
      be unrecoverable, since the sender never redelivers. *)
end

(** Receipt kinds — the closed sum of facts a receipt line may state. *)
module Kind : sig
  type t =
    | Delivery of Delivery.t option
        (** The event arrived and was durably recorded. [Some] carries the
            re-drivable event members; [None] is a line written before the
            members existed — {!val:decode} accepts their absence, and a
            reconcile pass closes such a record rather than re-driving
            it. *)
    | Disposition of Disposition.t  (** What was decided about it. *)
    | Egress of {
        summary : [ `Created | `Updated | `None_needed | `Skipped_no_token ];
        threads : int;
      }
        (** What the publisher concluded: whether the summary comment was
            created, updated, or the publisher converged with nothing to
            write, and how many finding threads were posted.
            [`None_needed] is a real egress fact — a clean suppressed run
            with nothing posted before, or a settled run whose log carries
            no findings document (a step-limit or failed last turn, a lost
            log): without it such a run would look egress-less forever and
            re-enter the publisher on every reconcile pass.
            [`Skipped_no_token] states honestly that the
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
    otherwise preserved without interpretation. A delivery line may carry
    the event members ([action], [base_ref], [draft],
    [author_association]) — all four, or none at all for a line written
    before they existed; a partial set is an [Error]. *)

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

val reap_recorded : digest:string -> identity:string -> t list -> bool
(** [reap_recorded ~digest ~identity receipts] is [true] iff [receipts]
    carries a reaped disposition for [identity] stamped [digest]. This is
    the settle discriminator: a run child's fence frees at its exit,
    before its reaper's own append, so a reaper and a recovering pass can
    both find the record open — whichever appends second consults this
    fold under the charter's fire lock and yields, keeping the record to
    exactly one reaped line per digest and identity. *)

val alerted : digest:string -> identity:string -> transition:Transition.t -> t list -> bool
(** [alerted ~digest ~identity ~transition receipts] is [true] iff
    [receipts] carries an alert receipt for [transition] with the
    identity-scoped window — an alert whose [window] is [`Identity] — for
    [identity] under [digest]. An identity-scoped alert fires once per
    event, ever: the window is the event itself, not a trailing duration,
    so the fold reads no clock. *)

(** One spawned run with no reaped line. *)
module Pending : sig
  type t = {
    identity : string;  (** The triggering event's identity string. *)
    digest : string;
        (** The charter policy digest the run was spawned under. *)
    session : string;  (** The run's derived session id. *)
    spawned_at : float;
        (** The spawned receipt's timestamp, seconds since the epoch — what
            a pass re-arms the wall-clock judgment from. *)
  }
  (** The type for pending runs. *)
end

val pending_runs : t list -> Pending.t list
(** [pending_runs receipts] is the runs whose record is open: every spawned
    disposition in [receipts] with no reaped disposition under the same
    charter digest and event identity, in log order. Pairing is by digest
    and identity together — never by session — so each policy's record is
    whole on its own: a policy edit's re-run neither adopts nor closes an
    earlier policy's run. *)

val open_deliveries : t list -> t list
(** [open_deliveries receipts] is the deliveries whose decision never
    landed: for each (digest, identity) pair that carries at least one
    delivery receipt and no disposition, the {e last} delivery receipt of
    the pair, in log order of that last line. These are acknowledged
    arrivals a process lost between the 202 and the disposition — the
    sender never redelivers, so a reconcile pass owes each one a drive
    (rebuilt from the receipt's {!Delivery} members) or an honest close. *)

val diagnostic : t -> string
(** [diagnostic t] is [t] rendered as one human-readable line: the UTC
    timestamp in RFC 3339 form, the fact's name, the event identity, and the
    kind's payload. This is the projection status verbs print; it is for
    people, and no consumer may parse it — {!decode} is the machine
    surface. *)
