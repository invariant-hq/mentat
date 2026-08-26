(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** JSON reading machinery shared by the executable's document readers.

    Two postures over decoded {!Jsont.json} values, matching the two kinds
    of document this executable reads. The strict readers serve closed
    envelopes this program owns — every member routed exactly once, an
    unknown or missing member an {!Error.t} naming it. {!Lenient} serves
    another service's documents — take the named member if it has the
    expected shape, ignore everything else, and let the caller decide what
    absence means. *)

(** Read errors. *)
module Error : sig
  type t
  (** The type for read errors: which part of an input is unacceptable, and
      why. *)

  val make : context:string -> string -> t
  (** [make ~context reason] is the error rejecting [context] for [reason].
      An empty [context] leaves the reason unprefixed. *)

  val message : t -> string
  (** [message e] is [e]'s one-line diagnostic: the reason, prefixed with the
      context naming the offending part when there is one. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

val as_string : context:string -> Jsont.json -> (string, Error.t) result
(** [as_string ~context json] is [json]'s value as a string, or an [Error]
    rejecting [context]. *)

val as_non_empty_string :
  context:string -> Jsont.json -> (string, Error.t) result
(** [as_non_empty_string ~context json] is {!as_string} refusing the empty
    string. *)

val as_bool : context:string -> Jsont.json -> (bool, Error.t) result
(** [as_bool ~context json] is [json]'s value as a boolean, or an [Error]
    rejecting [context]. *)

val positive_int : context:string -> Jsont.json -> (int, Error.t) result
(** [positive_int ~context json] is [json]'s value as a positive integer.
    [Jsont.Number] carries a float; only a value at least 1 that survives the
    integer round-trip is accepted, so an out-of-range magnitude cannot alias
    a valid value. Anything else is an [Error] rejecting [context]. *)

val non_negative_int : context:string -> Jsont.json -> (int, Error.t) result
(** [non_negative_int ~context json] is like {!positive_int} but admits 0. *)

val positive_number : context:string -> Jsont.json -> (float, Error.t) result
(** [positive_number ~context json] is [json]'s value as a finite number
    strictly greater than 0, or an [Error] rejecting [context]. *)

val route_members :
  context:string ->
  slots:(string * Jsont.json option ref) list ->
  Jsont.object' ->
  (unit, Error.t) result
(** [route_members ~context ~slots mems] routes each member of [mems] into
    its slot exactly once; an unlisted or repeated member is an [Error]
    naming it under [context]. *)

val require :
  context:string ->
  string ->
  Jsont.json option ref ->
  (Jsont.json, Error.t) result
(** [require ~context name slot] is the routed value in [slot], or the
    [Error] naming the missing member [name] under [context]. *)

val repo_full_name : context:string -> string -> (string, Error.t) result
(** [repo_full_name ~context s] is [s] when it names a repository as
    [owner/name]: exactly one ['/'], both halves non-empty, both drawn from
    letters, digits, ['.'], ['_'], and ['-']. Anything else is an [Error]
    rejecting [context]. *)

(** Narrow reads over another service's documents.

    Every reader answers [None] for a missing member or an unexpected
    shape — the foreign document grows members freely, and what absence
    means is the caller's decision, so nothing here mints an error. *)
module Lenient : sig
  val mem : string -> Jsont.json -> Jsont.json option
  (** [mem name json] is the value of member [name] when [json] is an
      object carrying it. *)

  val string : Jsont.json -> string option
  (** [string json] is [json]'s value when it is a string. *)

  val bool : Jsont.json -> bool option
  (** [bool json] is [json]'s value when it is a boolean. *)

  val number : Jsont.json -> float option
  (** [number json] is [json]'s value when it is a number. *)

  val int : Jsont.json -> int option
  (** [int json] is [json]'s value when it is a number that is an exact
      integer. *)

  val decode : string -> Jsont.json option
  (** [decode bytes] is the JSON value [bytes] denotes, or [None] when it
      does not parse. *)
end
