(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The run session-id mint.

    A routine run's session id is derived, never random: the same policy
    admitting the same event mints the same id, so a duplicate spawn
    collides loudly at session creation instead of running twice. *)

val mint : policy_digest:string -> Event.Identity.t -> string
(** [mint ~policy_digest identity] is the session id for the run
    [policy_digest] admits for [identity]: ["c-"] followed by the first 16
    lowercase hexadecimal characters of the SHA-256 of the
    [mentat.routine.run.v1] domain, [policy_digest], and [identity]'s
    string form, each length-framed. The result is 18 characters of
    letters, digits, and ['-'] — admissible wherever a session id is. A
    policy edit moves every event's id, so an edited routine re-runs a
    head its old policy already reviewed. Raises [Invalid_argument] when
    [policy_digest] is not 16 lowercase hexadecimal characters; the caller
    mints it, so a bad value is the caller's bug, not input. *)
