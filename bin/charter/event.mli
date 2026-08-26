(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Triggering events and their identities.

    A charter fires on an event — a GitHub [pull_request] webhook delivery,
    or an owner-invoked fire. {!Pull_request.decode} is the narrow reader
    for the webhook payload: it pulls exactly the members admission needs
    and ignores everything else, since the payload is another service's
    document and grows members freely. {!Identity} names an event for
    deduplication: two deliveries with the same identity are one event, so
    a redelivery collapses to one run while a new push runs again. The
    module is pure — no I/O. *)

(** The [pull_request] webhook payload, narrowed to admission's members. *)
module Pull_request : sig
  type t = {
    action : string;  (** The delivery's action, for example ["opened"]. *)
    number : int;  (** The pull request number, at least 1. *)
    head_sha : string;
        (** The head commit, 40 or 64 lowercase hexadecimal characters. *)
    base_ref : string;  (** The base branch name; non-empty. *)
    draft : bool;  (** Whether the pull request is a draft. *)
    author_association : string;
        (** The author's association with the repository, an uppercase
            token such as ["OWNER"] or ["NONE"]. *)
    repo : string;  (** The repository's [owner/name] full name. *)
  }
  (** The type for decoded [pull_request] events. *)

  (** Decode errors. *)
  module Error : sig
    type t
    (** The type for decode errors: which member of the payload is
        unacceptable, and why. *)

    val message : t -> string
    (** [message e] is [e]'s one-line diagnostic. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf e] formats {!message}. *)
  end

  val decode : string -> (t, Error.t) result
  (** [decode bytes] reads a [pull_request] webhook payload from [bytes].
      The read is narrow: it takes [action], [repository.full_name],
      [pull_request.number], [pull_request.draft],
      [pull_request.author_association], [pull_request.head.sha], and
      [pull_request.base.ref], validating each member's shape, and ignores
      every other member at every level. A missing or wrongly-shaped needed
      member is an [Error] naming it by path. *)
end

(** Event identities — what deduplication and the run-id mint key on. *)
module Identity : sig
  type t
  (** The type for event identities. An identity names what an event is
      about, never how it was delivered: a webhook redelivery carries the
      identity of its first delivery. *)

  val of_pull_request : Pull_request.t -> t
  (** [of_pull_request pr] is the identity of [pr]'s event: the repository,
      the pull request number, the head commit, and the action's class. The
      actions [opened], [reopened], [ready_for_review], and [synchronize]
      share one class — each says this head wants review, so one head is one
      event no matter which of them delivered it; any other action is its
      own class. *)

  val cli : digest:string -> key:string -> t
  (** [cli ~digest ~key] is the identity of an owner-invoked fire: the
      charter policy [digest] (16 lowercase hexadecimal characters) and the
      invoker's [key] (non-empty; distinct keys are distinct events, so an
      invoker choosing a fresh key per fire runs every time, and one reusing
      a key exercises deduplication). Raises [Invalid_argument] when
      [digest] is not 16 lowercase hexadecimal characters or [key] is
      empty — both are minted by the caller, so a bad value is the caller's
      bug, not input. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable string form — the form receipts carry
      and the run-id mint hashes. For a pull-request event it is
      [github:<repo>#<number>@<head_sha>:<class>]; for an owner fire it is
      [cli:<digest>:<key>]. Distinct identities render distinctly: the
      members' validated shapes leave no byte free to shift across a
      delimiter, and the two prefixes keep the arms apart. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] name the same event. *)
end
