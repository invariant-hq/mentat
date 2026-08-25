(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Strict-decode machinery shared by the connector's readers. *)

(** Decode errors. *)
module Error : sig
  type t
  (** The type for decode errors: which part of an input is unacceptable, and
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

val positive_int : context:string -> Jsont.json -> (int, Error.t) result
(** [positive_int ~context json] is [json]'s value as a positive integer.
    [Jsont.Number] carries a float; only a value at least 1 that survives the
    integer round-trip is accepted, so an out-of-range magnitude cannot alias
    a valid value. Anything else is an [Error] rejecting [context]. *)
