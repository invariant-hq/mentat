(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Message provenance — who sent a queued input.

    A queue entry delivered on another agent's behalf carries its sender as an
    origin; the receiving side renders the sender from this typed value, never
    from the message body. Everywhere an origin appears it is optional, and
    {b absence means the owner} — the human driving the session. There is
    exactly one spelling of "the owner sent this": no origin at all.

    Provenance is attribution, never authority: an origin is recorded and
    rendered and grants nothing — a forged origin misleads only its own
    journal. *)

(** The type for message provenance. *)
type t =
  | Agent of Id.t
      (** Another agent sent this; the id is the sending session's — an
          agent's id is its address. *)
  | Trigger of { charter : string; digest : string; key : string }
      (** A trigger host sent this on behalf of the charter named [charter],
          sealed at charter-content digest [digest], for trigger key [key].
          All members are non-empty. *)

val agent : Id.t -> t
(** [agent sender] is {!Agent}[ sender]. *)

val trigger : charter:string -> digest:string -> key:string -> t
(** [trigger ~charter ~digest ~key] is {!Trigger} with every member checked
    non-empty — the one construction that validates, and the path the codec
    decodes through.

    Raises [Invalid_argument] if any member is empty. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same origin. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats an origin for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps origins to JSON values by a per-arm tag, rejecting unknown
    tags and members. Decoding validates the non-empty members of
    {!Trigger}. *)
