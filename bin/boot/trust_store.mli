(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The workspace trust store — [config_home/trust.json].

    A user-side, version-2 record keying canonical workspace roots to a trust
    status: [{"version":2,"workspaces":{"<abs-root>":"trusted"|"untrusted"}}].
    The executable owns this file (the next config library takes trust as a
    pre-decided outcome, never reading it). A missing file or absent entry is
    {!Unknown} — never persisted; only an explicit [trust]/[untrust] writes.
    Writes preserve every other workspace's entry. *)

type status = Unknown  (** No recorded decision. *) | Trusted | Untrusted

val status_to_string : status -> string
(** [status_to_string s] is ["unknown"], ["trusted"], or ["untrusted"]. *)

(** Structured trust-store errors. Callers recover identically, but the message
    retains the operation and path — not flattened to an unstructured string. *)
module Error : sig
  type t = { operation : string; path : string; reason : string }
  (** [operation] is what failed (read, trust update), [path] the store file,
      [reason] the rendered cause. *)

  val message : t -> string
  (** [message e] is [e]'s user-facing [<path>: <reason>] line. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

val status : path:string -> root:string -> (status, Error.t) result
(** [status ~path ~root] is [root]'s recorded status in the store at [path], or
    {!Unknown} if the file or the entry is absent. [Error] on a malformed,
    unsupported, or unreadable store. *)

val is_trusted : path:string -> root:string -> bool
(** [is_trusted ~path ~root] is [true] iff [root] is recorded {!Trusted}. A read
    failure is treated as not-trusted (fail-closed). *)

val set : path:string -> root:string -> status -> (unit, Error.t) result
(** [set ~path ~root status] records [root]'s status, preserving other entries.
    The reload-modify-write is serialized against a concurrent [trust]/[untrust]
    by the two-level lock at [<path>.lock] and the [0600] file is replaced
    atomically ([status] must be {!Trusted} or {!Untrusted}). *)
