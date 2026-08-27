(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable next-turn queue facts.

    While a turn runs, the user may queue further inputs to be admitted as their
    own turns once the current one settles — and the queue is also the mailbox:
    an input delivered on another agent's behalf is the same kind of entry,
    carrying its sender as an {!Origin} member. The queue's mutations are
    durable facts ({!Update.t}); {e admission} is not a fact but a derived
    read: a {!Turn.t} whose origin is {!Turn.Origin.Queued} consumes the named
    entry. An interrupted turn preserves the pending queue for immediate
    correction admission; a failed turn empties it because failure does not
    establish a safe handoff boundary.

    Queue values carry no ordering cursor and no timestamp; order is journal
    order. *)

(** {1:ids Identifiers} *)

module Id : sig
  type t
  (** The type for stable queue-entry identifiers, minted engine-side by one of
      two schemes: an interactive entry's id is minted from its journal position
      (at-most-once, position-keyed so identical inputs stay distinct entries);
      a delivered message's id is content-derived from the sender's recorded
      position (at-least-once delivery, idempotent under re-drive).

      Invariant: an identifier's stable textual form is non-empty. *)

  val of_string : string -> t
  (** [of_string s] is [s] as a queue-entry id.

      Raises [Invalid_argument] if [s] is empty. *)

  val to_string : t -> string
  (** [to_string id] is [id]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same queue-entry id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representations,
      compatibly with {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an id for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps queue-entry ids to JSON strings, validating the non-empty
      invariant of {!of_string} on decode. *)
end

(** {1:entries Entries} *)

module Entry : sig
  type t = private {
    id : Id.t;
    input : Mentat_llm.Content.t list;
    origin : Origin.t option;
  }
  (** The type for a queued turn input. Invariant: [input] is non-empty.
      [origin] is the sender when the entry was delivered on another agent's
      behalf; an absent origin means the owner ({!Origin}). *)

  val make : ?origin:Origin.t -> id:Id.t -> input:Mentat_llm.Content.t list ->
    unit -> t
  (** [make ~id ~input ()] is a queue entry, carrying [origin] when the input
      was sent on another agent's behalf.

      Raises [Invalid_argument] if [input] is empty. *)

  val id : t -> Id.t
  (** [id t] is [t]'s stable entry id. *)

  val input : t -> Mentat_llm.Content.t list
  (** [input t] is [t]'s queued user content. *)

  val origin : t -> Origin.t option
  (** [origin t] is [t]'s sender; [None] means the owner. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same entry. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an entry for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps entries to JSON values, validating the non-empty [input]
      invariant on decode. *)
end

(** {1:updates Updates} *)

module Update : sig
  (** The type for a durable next-turn queue mutation. *)
  type t = private
    | Enqueued of Entry.t  (** One entry was appended to the queue. *)
    | Replaced of Entry.t list
        (** The whole queue was replaced (the [Replace_queued] command). *)
    | Cleared  (** The queue was emptied. *)

  val enqueued : Entry.t -> t
  (** [enqueued entry] records appending [entry]. *)

  val replaced : Entry.t list -> t
  (** [replaced entries] records replacing the whole queue with [entries].

      Raises [Invalid_argument] if two entries share an id. *)

  val cleared : t
  (** [cleared] records emptying the queue. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same update. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an update for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps updates to JSON values by a per-arm tag, rejecting unknown
      tags and members and validating local invariants on decode. *)
end
