(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Store_error = struct
  type t =
    | Not_found
    | Conflict
    | Rejected of Mentat_session.Error.t
    | Corrupt of Mentat_diagnostic.t
    | Io of Mentat_diagnostic.t

  let message (e : t) =
    match e with
    | Not_found -> "session document not found"
    | Conflict -> "store commit conflict: the fence was violated"
    | Rejected e ->
        Printf.sprintf "semantic append refused: %s"
          (Mentat_session.Error.message e)
    | Corrupt d ->
        Printf.sprintf "corrupt store data: %s" (Mentat_diagnostic.to_string d)
    | Io d ->
        Printf.sprintf "store io failure: %s" (Mentat_diagnostic.to_string d)

  let pp ppf e = Format.pp_print_string ppf (message e)
end

module type STORE = sig
  type guard
  type loaded

  val session_of : loaded -> Mentat_session.t

  val try_acquire :
    Mentat_session.Id.t ->
    [ `Acquired of guard | `Held of string option | `Io of Mentat_diagnostic.t ]

  val release : guard -> unit
  val create : Mentat_session.t -> (loaded, Store_error.t) result

  val fork :
    from:Mentat_session.Id.t ->
    events:Mentat_mutation.Event.t list ->
    Mentat_session.t ->
    (loaded, Store_error.t) result

  val load : guard -> (loaded, Store_error.t) result
  val view : Mentat_session.Id.t -> (loaded, Store_error.t) result

  val commit :
    guard ->
    loaded ->
    Mentat_session.Event.t list ->
    (loaded, Store_error.t) result

  val commit_metadata :
    guard -> loaded -> Mentat_session.t -> (loaded, Store_error.t) result

  val append_edit :
    guard ->
    loaded ->
    entries:Mentat_edit.Result.Entry.t list ->
    Mentat_mutation.Event.t ->
    (Mentat_mutation.State.t, Store_error.t) result

  val append_mutation :
    guard ->
    loaded ->
    Mentat_mutation.Event.t list ->
    (Mentat_mutation.State.t, Store_error.t) result

  val mutation_events :
    loaded -> (Mentat_mutation.Event.t list, Store_error.t) result

  val blob :
    Mentat_session.Id.t ->
    Mentat_digest.Content_ref.t ->
    (string option, Store_error.t) result

  val put_attachment :
    Mentat_session.Id.t ->
    string ->
    (Mentat_digest.Content_ref.t, Store_error.t) result

  val attachment :
    Mentat_session.Id.t ->
    Mentat_digest.Content_ref.t ->
    (string option, Store_error.t) result

  val revert :
    guard ->
    loaded ->
    scope:Mentat_mutation.Revert.Scope.t ->
    (Mentat_mutation.Revert.Outcome.t, Store_error.t) result

  val revert_selection :
    guard ->
    loaded ->
    selection:Mentat_mutation.Revert.Selection.t ->
    (Mentat_mutation.Revert.Outcome.t, Store_error.t) result

  val truncate :
    guard ->
    loaded ->
    keep:(Mentat_session.Turn.Id.t -> bool) ->
    Mentat_session.t ->
    (loaded * Mentat_mutation.State.t, Store_error.t) result

  val export : guard -> (string, Store_error.t) result
end

type provider_call =
  Mentat_llm.Request.t ->
  on_event:(Mentat_llm.Event.t -> unit) ->
  on_download:(Mentat_protocol.Progress.Model_download.t -> unit) ->
  cancelled:(unit -> bool) ->
  (Mentat_llm.Response.t, Mentat_llm.Error.t) result

let script call request ~on_event:_ ~on_download:_ ~cancelled:_ = call request

type workspace = {
  identity : Mentat_sandbox.Identity.t;
  checkpoint :
    boundary:Mentat_mutation.Checkpoint.boundary -> Mentat_mutation.Checkpoint.t;
  drain_notices : unit -> Mentat_workspace.Notice.t list;
  open_scope :
    Mentat_session.Tool_claim.Id.t -> unit -> Mentat_edit.Apply_evidence.t;
}
