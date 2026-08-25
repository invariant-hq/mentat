(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Store = Mentat_store
module Session = Mentat_session
module Protocol_error = Mentat_protocol.Error

let owner_display holder =
  Option.map (fun o -> Format.asprintf "%a" Store.Run_lock.Owner.pp o) holder

let session_store_error_to_protocol session (e : Store.Session.Error.t) :
    Protocol_error.t =
  match e with
  | Store.Session.Error.Not_found _ -> Protocol_error.Session_not_found session
  | Store.Session.Error.Locked { holder; _ } ->
      Protocol_error.Busy { session; owner = owner_display holder }
  | Store.Session.Error.Already_exists _ | Store.Session.Error.Conflict _
  | Store.Session.Error.Corrupt _ | Store.Session.Error.Io _ ->
      Protocol_error.Unavailable (Store.Session.Error.diagnostic e)

let session_error_to_protocol session (e : Session.Error.t) : Protocol_error.t =
  match e with
  | Session.Error.Archived -> Protocol_error.Archived session
  | Session.Error.Deleted -> Protocol_error.Deleted session
  | Session.Error.Active_turn turn -> Protocol_error.Active_turn_exists turn
  | Session.Error.State _ | Session.Error.Replay _
  | Session.Error.Unknown_turn _ | Session.Error.Turn_not_finished _
  | Session.Error.Delegated_session _ | Session.Error.Branch_copy_out_of_range _
  | Session.Error.Branch_reset_mismatch _
  | Session.Error.Unexpected_delegation_detachment _
  | Session.Error.Unsupported_version _ ->
      Protocol_error.unavailable (Session.Error.message e)

let with_fence ~store ~sw ~owner session f =
  match Store.Run_lock.try_acquire ~sw store ~session ~owner with
  | Error (`Held holder) ->
      Error (Protocol_error.Busy { session; owner = owner_display holder })
  | Error (`Io io) -> Error (Protocol_error.unavailable (Store.Io.message io))
  | Ok guard ->
      Fun.protect
        ~finally:(fun () -> Store.Run_lock.release guard)
        (fun () -> f guard)

let commit_transform ~store ~sw ~owner ~now session ~transform =
  with_fence ~store ~sw ~owner session (fun guard ->
      match Store.Session.load store session with
      | Error e -> Error (session_store_error_to_protocol session e)
      | Ok doc -> (
          match transform (Store.Session.Document.session doc) with
          | Error _ as e -> e
          | Ok updated -> (
              let stamped = Session.touch now updated in
              match Store.Session.commit store ~fence:guard doc stamped with
              | Ok _ -> Ok ()
              | Error e -> Error (session_store_error_to_protocol session e))))

(* Mint a fresh id at the command boundary — a wall-clock millisecond stamp and
   a random suffix, never derived from a session, scope, or ordinal (the mutation
   library's rule for revert ids, boundary-validated for session and turn ids).
   Each
   caller wraps the string in its own id type, so a session, turn, or revert id
   minted from the CLI, the daemon web edge, or here reads the same shape. *)
let id_seed = lazy (Random.self_init ())

let fresh_id ?prefix () =
  Lazy.force id_seed;
  let body =
    Printf.sprintf "%013.0f-%04x"
      (Unix.gettimeofday () *. 1000.)
      (Random.int 0x10000)
  in
  match prefix with None -> body | Some prefix -> prefix ^ "-" ^ body

let fresh_revert_id () =
  Mentat_mutation.Revert.Id.of_string (fresh_id ~prefix:"revert" ())

(* A [Latest] scope names the most recent turn that recorded an exact change;
   observations and reverts carry no turn, so the fold skips them. *)
let latest_edit_turn state =
  List.fold_left
    (fun acc -> function
      | Mentat_mutation.Event.Edit { turn; _ } -> Some turn | _ -> acc)
    None
    (Mentat_mutation.State.events state)

let selection_of_scope state (scope : Mentat_mutation.Revert.Scope.t) =
  match scope with
  | Mentat_mutation.Revert.Scope.Latest ->
      Option.map
        (fun t -> Mentat_mutation.Revert.Selection.turns [ t ])
        (latest_edit_turn state)
  | Mentat_mutation.Revert.Scope.Change id ->
      Some (Mentat_mutation.Revert.Selection.changes [ id ])
  | Mentat_mutation.Revert.Scope.Path path ->
      Some (Mentat_mutation.Revert.Selection.paths [ path ])

(* The revert outcome stays structured to the rendering edge — the store's
   [revert_outcome] with its [Problem.t] list, not a flattened string list. Each
   consumer projects it: the offline twin renders it (and reads [Needs_override]
   for its consent surface), the online adapter maps it onto the port arms. *)
let revert ~merge ~override ~store ~fence ~document ~selection ~observe
    ~checkpoint ~apply ~new_id =
  Store.Mutation.revert_apply ~merge ?override store ~fence ~document ~selection
    ~observe ~checkpoint ~apply ~new_id

let revert_scope ~merge ~override ~store ~fence ~document ~scope ~observe
    ~checkpoint ~apply ~new_id =
  match Store.Mutation.read store document with
  | Error e -> Error e
  | Ok state ->
      revert ~merge ~override ~store ~fence ~document
        ~selection:(selection_of_scope state scope)
        ~observe ~checkpoint ~apply ~new_id
