(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Busy of { session : Mentat_session.Id.t; owner : string option }
  | Session_not_found of Mentat_session.Id.t
  | Invalid_position of Position.Invalid.t
  | No_active_turn of Mentat_session.Id.t
  | Active_turn_exists of Mentat_session.Turn.Id.t
  | Turn_id_reused of Mentat_session.Turn.Id.t
  | Decision_not_pending of Mentat_session.Decision.Id.t
  | Already_resolved of Mentat_session.Decision.Id.t
  | Invalid_title
  | Invalid_api_key
  | Archived of Mentat_session.Id.t
  | Deleted of Mentat_session.Id.t
  | Unknown_command of User_command.Name.t
  | File_unresolved of { path : string; reason : string }
  | Unavailable of Mentat_diagnostic.t

let strf = Format.asprintf

let unavailable message =
  Unavailable
    (Mentat_diagnostic.of_text_or ~fallback:"the operation is unavailable"
       message)

let equal a b =
  match (a, b) with
  | Busy a, Busy b ->
      Mentat_session.Id.equal a.session b.session
      && Option.equal String.equal a.owner b.owner
  | Session_not_found a, Session_not_found b -> Mentat_session.Id.equal a b
  | Invalid_position a, Invalid_position b -> Position.Invalid.equal a b
  | No_active_turn a, No_active_turn b -> Mentat_session.Id.equal a b
  | Active_turn_exists a, Active_turn_exists b ->
      Mentat_session.Turn.Id.equal a b
  | Turn_id_reused a, Turn_id_reused b -> Mentat_session.Turn.Id.equal a b
  | Decision_not_pending a, Decision_not_pending b ->
      Mentat_session.Decision.Id.equal a b
  | Already_resolved a, Already_resolved b ->
      Mentat_session.Decision.Id.equal a b
  | Invalid_title, Invalid_title | Invalid_api_key, Invalid_api_key -> true
  | Archived a, Archived b -> Mentat_session.Id.equal a b
  | Deleted a, Deleted b -> Mentat_session.Id.equal a b
  | Unknown_command a, Unknown_command b -> User_command.Name.equal a b
  | File_unresolved a, File_unresolved b ->
      String.equal a.path b.path && String.equal a.reason b.reason
  | Unavailable a, Unavailable b -> Mentat_diagnostic.equal a b
  | ( ( Busy _ | Session_not_found _ | Invalid_position _ | No_active_turn _
      | Active_turn_exists _ | Turn_id_reused _ | Decision_not_pending _
      | Already_resolved _ | Invalid_title | Invalid_api_key
      | Archived _ | Deleted _ | Unknown_command _ | File_unresolved _
      | Unavailable _ ),
      _ ) ->
      false

let diagnostic = function
  | Busy { session; owner } -> (
      let message =
        strf "session %a is busy with another driver" Mentat_session.Id.pp
          session
      in
      match owner with
      | Some owner when not (String.is_empty owner) ->
          Mentat_diagnostic.make ~context:owner message
      | Some _ | None -> Mentat_diagnostic.make message)
  | Session_not_found session ->
      Mentat_diagnostic.make
        (strf "session %a not found" Mentat_session.Id.pp session)
  | Invalid_position invalid ->
      Mentat_diagnostic.make (Position.Invalid.message invalid)
  | No_active_turn session ->
      Mentat_diagnostic.make
        (strf "session %a has no active turn" Mentat_session.Id.pp session)
  | Active_turn_exists turn ->
      Mentat_diagnostic.make
        (strf "turn %a is still active" Mentat_session.Turn.Id.pp turn)
  | Turn_id_reused turn ->
      Mentat_diagnostic.make
        (strf "turn id %a was reused with a different payload"
           Mentat_session.Turn.Id.pp turn)
  | Decision_not_pending decision ->
      Mentat_diagnostic.make
        (strf "decision %a is not pending" Mentat_session.Decision.Id.pp
           decision)
  | Already_resolved decision ->
      Mentat_diagnostic.make
        (strf "decision %a is already resolved" Mentat_session.Decision.Id.pp
           decision)
  | Invalid_title -> Mentat_diagnostic.make "title must not be empty"
  | Invalid_api_key -> Mentat_diagnostic.make "API key must not be empty"
  | Archived session ->
      Mentat_diagnostic.make
        (strf "session %a is archived" Mentat_session.Id.pp session)
  | Deleted session ->
      Mentat_diagnostic.make
        (strf "session %a is deleted" Mentat_session.Id.pp session)
  | Unknown_command name ->
      Mentat_diagnostic.make
        (strf "unknown command %s" (User_command.Name.to_string name))
  | File_unresolved { path; reason } ->
      Mentat_diagnostic.make (strf "cannot resolve @%s: %s" path reason)
  | Unavailable diagnostic -> diagnostic

let pp ppf t =
  Format.pp_print_string ppf (Mentat_diagnostic.to_string (diagnostic t))

let jsont =
  let session_only kind tag inj proj =
    Jsont.Object.map ~kind inj
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:proj
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let turn_only kind tag inj proj =
    Jsont.Object.map ~kind inj
    |> Jsont.Object.mem "turn" Mentat_session.Turn.Id.jsont ~enc:proj
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let decision_only kind tag inj proj =
    Jsont.Object.map ~kind inj
    |> Jsont.Object.mem "decision" Mentat_session.Decision.Id.jsont ~enc:proj
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let busy_case =
    Jsont.Object.map ~kind:"busy error" (fun session owner ->
        Busy { session; owner })
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Busy { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.opt_mem "owner" Jsont.string ~enc:(function
      | Busy { owner; _ } -> owner
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "busy" ~dec:Fun.id
  in
  let session_not_found_case =
    session_only "session-not-found error" "session_not_found"
      (fun session -> Session_not_found session)
      (function Session_not_found session -> session | _ -> assert false)
  in
  let invalid_position_case =
    Jsont.Object.map ~kind:"invalid-position error" (fun invalid ->
        Invalid_position invalid)
    |> Jsont.Object.mem "position" Position.Invalid.jsont ~enc:(function
      | Invalid_position invalid -> invalid
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "invalid_position" ~dec:Fun.id
  in
  let no_active_turn_case =
    session_only "no-active-turn error" "no_active_turn"
      (fun session -> No_active_turn session)
      (function No_active_turn session -> session | _ -> assert false)
  in
  let active_turn_exists_case =
    turn_only "active-turn-exists error" "active_turn_exists"
      (fun turn -> Active_turn_exists turn)
      (function Active_turn_exists turn -> turn | _ -> assert false)
  in
  let turn_id_reused_case =
    turn_only "turn-id-reused error" "turn_id_reused"
      (fun turn -> Turn_id_reused turn)
      (function Turn_id_reused turn -> turn | _ -> assert false)
  in
  let decision_not_pending_case =
    decision_only "decision-not-pending error" "decision_not_pending"
      (fun decision -> Decision_not_pending decision)
      (function Decision_not_pending decision -> decision | _ -> assert false)
  in
  let already_resolved_case =
    decision_only "already-resolved error" "already_resolved"
      (fun decision -> Already_resolved decision)
      (function Already_resolved decision -> decision | _ -> assert false)
  in
  let invalid_title_case =
    Jsont.Object.map ~kind:"invalid-title error" Invalid_title
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "invalid_title" ~dec:Fun.id
  in
  let invalid_api_key_case =
    Jsont.Object.map ~kind:"invalid-api-key error" Invalid_api_key
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "invalid_api_key" ~dec:Fun.id
  in
  let archived_case =
    session_only "archived error" "archived"
      (fun session -> Archived session)
      (function Archived session -> session | _ -> assert false)
  in
  let deleted_case =
    session_only "deleted error" "deleted"
      (fun session -> Deleted session)
      (function Deleted session -> session | _ -> assert false)
  in
  let unknown_command_case =
    Jsont.Object.map ~kind:"unknown-command error" (fun name ->
        Unknown_command name)
    |> Jsont.Object.mem "name" User_command.Name.jsont ~enc:(function
      | Unknown_command name -> name
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "unknown_command" ~dec:Fun.id
  in
  let file_unresolved_case =
    Jsont.Object.map ~kind:"file-unresolved error" (fun path reason ->
        File_unresolved { path; reason })
    |> Jsont.Object.mem "path" Jsont.string ~enc:(function
      | File_unresolved { path; _ } -> path
      | _ -> assert false)
    |> Jsont.Object.mem "reason" Jsont.string ~enc:(function
      | File_unresolved { reason; _ } -> reason
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "file_unresolved" ~dec:Fun.id
  in
  let unavailable_case =
    Jsont.Object.map ~kind:"unavailable error" (fun diagnostic ->
        Unavailable diagnostic)
    |> Jsont.Object.mem "diagnostic" Mentat_diagnostic.jsont ~enc:(function
      | Unavailable diagnostic -> diagnostic
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "unavailable" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [
        busy_case;
        session_not_found_case;
        invalid_position_case;
        no_active_turn_case;
        active_turn_exists_case;
        turn_id_reused_case;
        decision_not_pending_case;
        already_resolved_case;
        invalid_title_case;
        invalid_api_key_case;
        archived_case;
        deleted_case;
        unknown_command_case;
        file_unresolved_case;
        unavailable_case;
      ]
  in
  let enc_case = function
    | Busy _ as e -> Jsont.Object.Case.value busy_case e
    | Session_not_found _ as e ->
        Jsont.Object.Case.value session_not_found_case e
    | Invalid_position _ as e -> Jsont.Object.Case.value invalid_position_case e
    | No_active_turn _ as e -> Jsont.Object.Case.value no_active_turn_case e
    | Active_turn_exists _ as e ->
        Jsont.Object.Case.value active_turn_exists_case e
    | Turn_id_reused _ as e -> Jsont.Object.Case.value turn_id_reused_case e
    | Decision_not_pending _ as e ->
        Jsont.Object.Case.value decision_not_pending_case e
    | Already_resolved _ as e -> Jsont.Object.Case.value already_resolved_case e
    | Invalid_title as e -> Jsont.Object.Case.value invalid_title_case e
    | Invalid_api_key as e -> Jsont.Object.Case.value invalid_api_key_case e
    | Archived _ as e -> Jsont.Object.Case.value archived_case e
    | Deleted _ as e -> Jsont.Object.Case.value deleted_case e
    | Unknown_command _ as e -> Jsont.Object.Case.value unknown_command_case e
    | File_unresolved _ as e -> Jsont.Object.Case.value file_unresolved_case e
    | Unavailable _ as e -> Jsont.Object.Case.value unavailable_case e
  in
  Jsont.Object.map ~kind:"protocol error" (fun v e ->
      Wire.check v;
      e)
  |> Wire.mem
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.finish
