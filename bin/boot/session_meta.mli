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
  owner:Mentat_store.Run_lock.Owner.t ->
  Mentat_session.Id.t ->
  (Mentat_store.Run_lock.guard -> ('a, Mentat_protocol.Error.t) result) ->
  ('a, Mentat_protocol.Error.t) result
(** [with_fence ~store ~sw ~owner session f] runs [f] under a short-lived run
    fence over [session] (the "one driver per session" lock), releasing it on
    exit. A held fence is {!Mentat_protocol.Error.Busy} (with the owner); an IO
    failure is [Unavailable]. *)

val commit_transform :
  store:Mentat_store.t ->
  sw:Eio.Switch.t ->
  owner:Mentat_store.Run_lock.Owner.t ->
  now:Mentat_session.Time.t ->
  Mentat_session.Id.t ->
  transform:
    (Mentat_session.t -> (Mentat_session.t, Mentat_protocol.Error.t) result) ->
  (unit, Mentat_protocol.Error.t) result
(** [commit_transform ~store ~sw ~owner ~now session ~transform] loads [session]
    under a fence, applies [transform], stamps the result with [now], and
    atomically commits it. Every failure is a {!Mentat_protocol.Error.t}. *)

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
    library's own rule. Shared by the online revert cone (through the store
    adapter) and the offline [cli_session] twin, so a revert minted either way
    is the same shape. *)

val latest_edit_turn :
  Mentat_mutation.State.t -> Mentat_session.Turn.Id.t option
(** [latest_edit_turn state] names the most recent turn that recorded an exact
    change — observations and reverts carry no turn, so only an editing turn
    qualifies. The one resolver behind both the wire [Latest] scope and the
    offline [--latest] flag, so the two twins cannot drift. *)

val revert :
  merge:bool ->
  override:Mentat_mutation.Revert.Override.t option ->
  store:Mentat_store.t ->
  fence:Mentat_store.Run_lock.guard ->
  document:Mentat_store.Session.Document.t ->
  selection:Mentat_mutation.Revert.Selection.t option ->
  observe:(Mentat_workspace.Path.t -> Mentat_edit.Observed.t) ->
  checkpoint:
    (boundary:Mentat_mutation.Checkpoint.boundary ->
    Mentat_mutation.Checkpoint.t) ->
  apply:
    (Mentat_edit.t -> (Mentat_edit.Result.t, Mentat_edit.Apply_error.t) result) ->
  new_id:(unit -> Mentat_mutation.Revert.Id.t) ->
  (Mentat_store.Mutation.revert_outcome, Mentat_store.Mutation.Error.t) result
(** [revert ~store ~fence ~document ~selection ~observe ~checkpoint ~apply
     ~new_id] is the one revert-lifecycle implementation: under the held [fence]
    it runs the whole {!Mentat_store.Mutation.revert_apply} lifecycle for
    [selection] — capture, freeze, apply, settle — and returns its structured
    {!Mentat_store.Mutation.revert_outcome} unflattened, so a consumer reads the
    {!Mentat_mutation.Revert.Problem.t} list ([Refused] mints no fact) rather
    than a pre-rendered string. Each consumer projects at its own edge: the
    offline twin renders and reads [Needs_override] for consent, the online
    adapter maps onto the port arms.

    [merge] is threaded to {!Mentat_store.Mutation.revert_apply}: each consumer
    passes the [revert.merge] config value, so a superseded selection merges
    cleanly unless the user turned the gate off. [override] is the explicit
    consent covering non-contiguous paths: [None] refuses them with
    [Needs_override]; only the offline twin supplies [Some] from a presented
    refusal.

    It is fence-agnostic and takes a resolved [selection], because the two
    consumers resolve selection differently: the online cone from a
    {!Mentat_mutation.Revert.Scope.t} (through {!revert_scope}), the offline
    [cli_session] twin from its command flags — including the whole-session and
    string-path scopes the wire [Scope.t] does not carry. Both then share this
    one lifecycle, so it and its outcome mapping cannot drift. The error is the
    lower {!Mentat_store.Mutation.Error.t} each consumer maps — the adapter onto
    {!Mentat_agent.Ports.Store_error.t}, the twin onto the protocol. *)

val revert_scope :
  merge:bool ->
  override:Mentat_mutation.Revert.Override.t option ->
  store:Mentat_store.t ->
  fence:Mentat_store.Run_lock.guard ->
  document:Mentat_store.Session.Document.t ->
  scope:Mentat_mutation.Revert.Scope.t ->
  observe:(Mentat_workspace.Path.t -> Mentat_edit.Observed.t) ->
  checkpoint:
    (boundary:Mentat_mutation.Checkpoint.boundary ->
    Mentat_mutation.Checkpoint.t) ->
  apply:
    (Mentat_edit.t -> (Mentat_edit.Result.t, Mentat_edit.Apply_error.t) result) ->
  new_id:(unit -> Mentat_mutation.Revert.Id.t) ->
  (Mentat_store.Mutation.revert_outcome, Mentat_store.Mutation.Error.t) result
(** [revert_scope ~store ~fence ~document ~scope …] is the online cone's entry:
    it re-reads [document]'s replayed history under the fence, resolves the wire
    [scope] ([Latest]/[Change]/[Path]) to a selection, and runs {!revert}. The
    store adapter binds it as {!Mentat_agent.Ports.STORE.revert}. *)
