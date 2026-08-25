(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Mentat_session.Event" fn message

type t =
  | Turn_started of Turn.t
  | Interrupt_requested of { turn : Turn.Id.t; reason : string option }
  | Turn_finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }
  | Message_appended of Mentat_llm.Message.t
  | Provider_requested of Provider_request.Started.t
  | Provider_settled of Provider_request.Settled.t
  | Tool_claimed of Tool_claim.Started.t
  | Tool_settled of Tool_claim.Settled.t
  | Decision_requested of Decision.Requested.t
  | Decision_resolved of Decision.Resolved.t
  | Compaction_installed of Compaction.t
  | Tasks_replaced of Task.Board.t
  | Delegation_recorded of Delegation.t
  | Delegations_detached
  | Queue_updated of Queue.Update.t
  | Workspace_notice of Notice.t
  | Undo_updated of Undo.Update.t

let turn_started turn = Turn_started turn

let interrupt_requested ~turn ?reason () =
  (match reason with
  | Some reason when String.is_empty reason ->
      invalid "interrupt_requested" "reason must not be empty"
  | Some _ | None -> ());
  Interrupt_requested { turn; reason }

let turn_finished ~turn outcome = Turn_finished { turn; outcome }

let check_message = function
  | Mentat_llm.Message.Assistant _ ->
      invalid "message_appended"
        "assistant messages must be recorded as provider settlements"
  | Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
  | Mentat_llm.Message.User _ | Mentat_llm.Message.Tool_result _ ->
      ()

let message_appended message =
  check_message message;
  Message_appended message

let provider_requested claim = Provider_requested claim
let provider_settled settlement = Provider_settled settlement
let tool_claimed claim = Tool_claimed claim
let tool_settled settlement = Tool_settled settlement
let decision_requested request = Decision_requested request
let decision_resolved resolution = Decision_resolved resolution
let compaction_installed compaction = Compaction_installed compaction
let tasks_replaced board = Tasks_replaced board
let delegation_recorded edge = Delegation_recorded edge
let delegations_detached = Delegations_detached
let queue_updated update = Queue_updated update
let workspace_notice notice = Workspace_notice notice
let undo_updated update = Undo_updated update

let equal a b =
  match (a, b) with
  | Turn_started a, Turn_started b -> Turn.equal a b
  | Interrupt_requested a, Interrupt_requested b ->
      Turn.Id.equal a.turn b.turn && Option.equal String.equal a.reason b.reason
  | Turn_finished a, Turn_finished b ->
      Turn.Id.equal a.turn b.turn && Turn.Outcome.equal a.outcome b.outcome
  | Message_appended a, Message_appended b -> Mentat_llm.Message.equal a b
  | Provider_requested a, Provider_requested b ->
      Provider_request.Started.equal a b
  | Provider_settled a, Provider_settled b -> Provider_request.Settled.equal a b
  | Tool_claimed a, Tool_claimed b -> Tool_claim.Started.equal a b
  | Tool_settled a, Tool_settled b -> Tool_claim.Settled.equal a b
  | Decision_requested a, Decision_requested b -> Decision.Requested.equal a b
  | Decision_resolved a, Decision_resolved b -> Decision.Resolved.equal a b
  | Compaction_installed a, Compaction_installed b -> Compaction.equal a b
  | Tasks_replaced a, Tasks_replaced b -> Task.Board.equal a b
  | Delegation_recorded a, Delegation_recorded b -> Delegation.equal a b
  | Delegations_detached, Delegations_detached -> true
  | Queue_updated a, Queue_updated b -> Queue.Update.equal a b
  | Workspace_notice a, Workspace_notice b -> Notice.equal a b
  | Undo_updated a, Undo_updated b -> Undo.Update.equal a b
  | Turn_started _, _
  | Interrupt_requested _, _
  | Turn_finished _, _
  | Message_appended _, _
  | Provider_requested _, _
  | Provider_settled _, _
  | Tool_claimed _, _
  | Tool_settled _, _
  | Decision_requested _, _
  | Decision_resolved _, _
  | Compaction_installed _, _
  | Tasks_replaced _, _
  | Delegation_recorded _, _
  | Delegations_detached, _
  | Queue_updated _, _
  | Workspace_notice _, _
  | Undo_updated _, _ ->
      false

let pp_message_kind ppf = function
  | Mentat_llm.Message.System _ -> Format.pp_print_string ppf "system"
  | Mentat_llm.Message.Developer _ -> Format.pp_print_string ppf "developer"
  | Mentat_llm.Message.User _ -> Format.pp_print_string ppf "user"
  | Mentat_llm.Message.Assistant _ -> Format.pp_print_string ppf "assistant"
  | Mentat_llm.Message.Tool_result _ -> Format.pp_print_string ppf "tool-result"

let pp ppf = function
  | Turn_started turn -> Format.fprintf ppf "turn-started(%a)" Turn.pp turn
  | Interrupt_requested { turn; _ } ->
      Format.fprintf ppf "interrupt-requested(%a)" Turn.Id.pp turn
  | Turn_finished { turn; outcome } ->
      Format.fprintf ppf "turn-finished(turn=%a, outcome=%a)" Turn.Id.pp turn
        Turn.Outcome.pp outcome
  | Message_appended message ->
      Format.fprintf ppf "message-appended(%a)" pp_message_kind message
  | Provider_requested claim ->
      Format.fprintf ppf "provider-requested(%a)" Provider_request.Started.pp
        claim
  | Provider_settled settlement ->
      Format.fprintf ppf "provider-settled(%a)" Provider_request.Settled.pp
        settlement
  | Tool_claimed claim ->
      Format.fprintf ppf "tool-claimed(%a)" Tool_claim.Started.pp claim
  | Tool_settled settlement ->
      Format.fprintf ppf "tool-settled(%a)" Tool_claim.Settled.pp settlement
  | Decision_requested request ->
      Format.fprintf ppf "decision-requested(%a)" Decision.Requested.pp request
  | Decision_resolved resolution ->
      Format.fprintf ppf "decision-resolved(%a)" Decision.Resolved.pp resolution
  | Compaction_installed compaction ->
      Format.fprintf ppf "compaction-installed(%a)" Compaction.pp compaction
  | Tasks_replaced board ->
      Format.fprintf ppf "tasks-replaced(%a)" Task.Board.pp board
  | Delegation_recorded edge ->
      Format.fprintf ppf "delegation-recorded(%a)" Delegation.pp edge
  | Delegations_detached -> Format.pp_print_string ppf "delegations-detached"
  | Queue_updated update ->
      Format.fprintf ppf "queue-updated(%a)" Queue.Update.pp update
  | Workspace_notice notice ->
      Format.fprintf ppf "workspace-notice(%a)" Notice.pp notice
  | Undo_updated update ->
      Format.fprintf ppf "undo-updated(%a)" Undo.Update.pp update

let jsont =
  let single kind tag mem_name value inj proj =
    Jsont.Object.map ~kind (fun payload -> inj payload)
    |> Jsont.Object.mem mem_name value ~enc:proj
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let turn_started_case =
    single "turn-started event" "turn_started" "turn" Turn.jsont
      (fun turn -> Turn_started turn)
      (function Turn_started turn -> turn | _ -> assert false)
  in
  let interrupt_requested_case =
    Jsont.Object.map ~kind:"interrupt-requested event" (fun turn reason ->
        decode_invalid_arg (fun () -> interrupt_requested ~turn ?reason ()))
    |> Jsont.Object.mem "turn" Turn.Id.jsont ~enc:(function
      | Interrupt_requested { turn; _ } -> turn
      | _ -> assert false)
    |> Jsont.Object.opt_mem "reason" Jsont.string ~enc:(function
      | Interrupt_requested { reason; _ } -> reason
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "interrupt_requested" ~dec:Fun.id
  in
  let turn_finished_case =
    Jsont.Object.map ~kind:"turn-finished event" (fun turn outcome ->
        Turn_finished { turn; outcome })
    |> Jsont.Object.mem "turn" Turn.Id.jsont ~enc:(function
      | Turn_finished { turn; _ } -> turn
      | _ -> assert false)
    |> Jsont.Object.mem "outcome" Turn.Outcome.jsont ~enc:(function
      | Turn_finished { outcome; _ } -> outcome
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "turn_finished" ~dec:Fun.id
  in
  let message_appended_case =
    single "message-appended event" "message_appended" "message"
      Mentat_llm.Message.jsont
      (fun message -> decode_invalid_arg (fun () -> message_appended message))
      (function Message_appended message -> message | _ -> assert false)
  in
  let provider_requested_case =
    single "provider-requested event" "provider_requested" "claim"
      Provider_request.Started.jsont
      (fun claim -> Provider_requested claim)
      (function Provider_requested claim -> claim | _ -> assert false)
  in
  let provider_settled_case =
    single "provider-settled event" "provider_settled" "settlement"
      Provider_request.Settled.jsont
      (fun settlement -> Provider_settled settlement)
      (function Provider_settled settlement -> settlement | _ -> assert false)
  in
  let tool_claimed_case =
    single "tool-claimed event" "tool_claimed" "claim" Tool_claim.Started.jsont
      (fun claim -> Tool_claimed claim)
      (function Tool_claimed claim -> claim | _ -> assert false)
  in
  let tool_settled_case =
    single "tool-settled event" "tool_settled" "settlement"
      Tool_claim.Settled.jsont
      (fun settlement -> Tool_settled settlement)
      (function Tool_settled settlement -> settlement | _ -> assert false)
  in
  let decision_requested_case =
    single "decision-requested event" "decision_requested" "request"
      Decision.Requested.jsont
      (fun request -> Decision_requested request)
      (function Decision_requested request -> request | _ -> assert false)
  in
  let decision_resolved_case =
    single "decision-resolved event" "decision_resolved" "resolution"
      Decision.Resolved.jsont
      (fun resolution -> Decision_resolved resolution)
      (function
        | Decision_resolved resolution -> resolution | _ -> assert false)
  in
  let compaction_installed_case =
    single "compaction-installed event" "compaction_installed" "compaction"
      Compaction.jsont
      (fun compaction -> Compaction_installed compaction)
      (function
        | Compaction_installed compaction -> compaction | _ -> assert false)
  in
  let tasks_replaced_case =
    single "tasks-replaced event" "tasks_replaced" "board" Task.Board.jsont
      (fun board -> Tasks_replaced board)
      (function Tasks_replaced board -> board | _ -> assert false)
  in
  let delegation_recorded_case =
    single "delegation-recorded event" "delegation_recorded" "edge"
      Delegation.jsont
      (fun edge -> Delegation_recorded edge)
      (function Delegation_recorded edge -> edge | _ -> assert false)
  in
  let delegations_detached_case =
    Jsont.Object.map ~kind:"delegations-detached event" Delegations_detached
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "delegations_detached" ~dec:Fun.id
  in
  let queue_updated_case =
    single "queue-updated event" "queue_updated" "update" Queue.Update.jsont
      (fun update -> Queue_updated update)
      (function Queue_updated update -> update | _ -> assert false)
  in
  let workspace_notice_case =
    single "workspace-notice event" "workspace_notice" "notice" Notice.jsont
      (fun notice -> Workspace_notice notice)
      (function Workspace_notice notice -> notice | _ -> assert false)
  in
  let undo_updated_case =
    single "undo-updated event" "undo_updated" "update" Undo.Update.jsont
      (fun update -> Undo_updated update)
      (function Undo_updated update -> update | _ -> assert false)
  in
  let cases =
    List.map Jsont.Object.Case.make
      [
        turn_started_case;
        interrupt_requested_case;
        turn_finished_case;
        message_appended_case;
        provider_requested_case;
        provider_settled_case;
        tool_claimed_case;
        tool_settled_case;
        decision_requested_case;
        decision_resolved_case;
        compaction_installed_case;
        tasks_replaced_case;
        delegation_recorded_case;
        delegations_detached_case;
        queue_updated_case;
        workspace_notice_case;
        undo_updated_case;
      ]
  in
  let enc_case = function
    | Turn_started _ as e -> Jsont.Object.Case.value turn_started_case e
    | Interrupt_requested _ as e ->
        Jsont.Object.Case.value interrupt_requested_case e
    | Turn_finished _ as e -> Jsont.Object.Case.value turn_finished_case e
    | Message_appended _ as e -> Jsont.Object.Case.value message_appended_case e
    | Provider_requested _ as e ->
        Jsont.Object.Case.value provider_requested_case e
    | Provider_settled _ as e -> Jsont.Object.Case.value provider_settled_case e
    | Tool_claimed _ as e -> Jsont.Object.Case.value tool_claimed_case e
    | Tool_settled _ as e -> Jsont.Object.Case.value tool_settled_case e
    | Decision_requested _ as e ->
        Jsont.Object.Case.value decision_requested_case e
    | Decision_resolved _ as e ->
        Jsont.Object.Case.value decision_resolved_case e
    | Compaction_installed _ as e ->
        Jsont.Object.Case.value compaction_installed_case e
    | Tasks_replaced _ as e -> Jsont.Object.Case.value tasks_replaced_case e
    | Delegation_recorded _ as e ->
        Jsont.Object.Case.value delegation_recorded_case e
    | Delegations_detached as e ->
        Jsont.Object.Case.value delegations_detached_case e
    | Queue_updated _ as e -> Jsont.Object.Case.value queue_updated_case e
    | Workspace_notice _ as e -> Jsont.Object.Case.value workspace_notice_case e
    | Undo_updated _ as e -> Jsont.Object.Case.value undo_updated_case e
  in
  Jsont.Object.map ~kind:"session event" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
