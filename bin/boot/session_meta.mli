(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The one fenced-commit implementation for session-metadata mutation.

    A store-touching metadata edit (create/rename/archive/restore/delete) is
    reached two ways — the online Lifecycle cone when a client exists, and the
    offline [cli_session] twin when no engine runs — but there is exactly one
    implementation, here, so the twin and its cone cannot drift. Both call
    {!commit_transform} and map its {!Mentat_protocol.Error.t} onto the exit
    contract ({!Exit_status.of_protocol_error}); the store's and session
    library's errors reach the protocol only through the two classifiers below,
    so no responder string-flattens a structured error. *)

val session_store_error_to_protocol :
  Mentat_session.Id.t -> Mentat_store.Session.Error.t -> Mentat_protocol.Error.t
(** [session_store_error_to_protocol session e] classifies a store session error
    for [session] onto the protocol: not-found, busy (with the lock owner), or
    unavailable. *)

val session_error_to_protocol :
  Mentat_session.Id.t -> Mentat_session.Error.t -> Mentat_protocol.Error.t
(** [session_error_to_protocol session e] classifies a session-library error for
    [session] onto the protocol: archived, deleted, an active turn, or
    unavailable. *)

val with_fence :
  store:Mentat_store.t ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  owner:Mentat_store.Run_lock.Owner.t ->
  Mentat_session.Id.t ->
  (Mentat_store.Run_lock.guard -> ('a, Mentat_protocol.Error.t) result) ->
  ('a, Mentat_protocol.Error.t) result
(** [with_fence ~store ~sw ~clock ~owner session f] runs [f] under a
    short-lived run fence over [session] (the "one driver per session" lock),
    releasing it on exit. A hold that releases on its own — a custodial hold,
    or a settled session's agent lingering toward its own exit — is waited
    out on a bounded patience (derived from the agent's linger, sleeping on
    [clock] so the wait parks a fiber, never the caller's domain) rather than
    refused, so an offline command issued right after a run does not race the
    agent's linger. Any other held fence — an agent actively driving, or a
    lingering one still held open past the patience — is
    {!Mentat_protocol.Error.Busy} (with the owner); an IO failure is
    [Unavailable]. *)

val commit_transform :
  store:Mentat_store.t ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  owner:Mentat_store.Run_lock.Owner.t ->
  now:Mentat_session.Time.t ->
  Mentat_session.Id.t ->
  transform:
    (Mentat_session.t -> (Mentat_session.t, Mentat_protocol.Error.t) result) ->
  (unit, Mentat_protocol.Error.t) result
(** [commit_transform ~store ~sw ~clock ~owner ~now session ~transform] loads
    [session] under a fence ({!with_fence}, [clock] as there), applies
    [transform], stamps the result with [now], and atomically commits it.
    Every failure is a {!Mentat_protocol.Error.t}. *)

val fresh_id : ?prefix:string -> unit -> string
(** [fresh_id ?prefix ()] mints a fresh identifier body at the command boundary
    — a wall-clock millisecond stamp and random suffix, never derived from a
    session, scope, or ordinal. With [~prefix] the body is prefixed with
    [prefix ^ "-"]; without it the bare body is returned (no leading separator).
    Each caller wraps the string in its own id type ({!Mentat_session.Id},
    {!Mentat_session.Turn.Id}, or {!Mentat_mutation.Revert.Id}), so a session,
    turn, or revert minted from the CLI, the daemon web edge, or here reads the
    same shape. *)

val fresh_revert_id : unit -> Mentat_mutation.Revert.Id.t
(** [fresh_revert_id ()] mints a fresh revert identifier at the command boundary
    — never derived from the session, scope, or an ordinal, the mutation
    library's own rule. Shared by the engine's online revert cone (threaded in
    at engine construction) and the offline [cli_session] twin, so a revert
    minted either way is the same shape. *)

