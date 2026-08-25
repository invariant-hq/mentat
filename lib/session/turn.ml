(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Mentat_session.Turn" fn message

let reject_empty_option fn field = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid fn (field ^ " must not be empty")

module Id =
  String_id.Make
    (struct
      let module_path = "Mentat_session.Turn.Id"
      let kind = "turn id"
    end)
    ()

module Origin = struct
  type t =
    | User
    | Goal_continuation
    | Queued of Queue.Id.t
    | Triggered of { charter : string; digest : string; key : string }
    | Plan_build
    | Compaction
    | Step_limit_wind_down

  let triggered ~charter ~digest ~key =
    let reject field value =
      if String.is_empty value then
        invalid "Origin.triggered" (field ^ " must not be empty")
    in
    reject "charter" charter;
    reject "digest" digest;
    reject "key" key;
    Triggered { charter; digest; key }

  let equal a b =
    match (a, b) with
    | User, User -> true
    | Goal_continuation, Goal_continuation -> true
    | Queued a, Queued b -> Queue.Id.equal a b
    | Triggered a, Triggered b ->
        String.equal a.charter b.charter
        && String.equal a.digest b.digest
        && String.equal a.key b.key
    | Plan_build, Plan_build -> true
    | Compaction, Compaction -> true
    | Step_limit_wind_down, Step_limit_wind_down -> true
    | ( ( User | Goal_continuation | Queued _ | Triggered _ | Plan_build
        | Compaction | Step_limit_wind_down ),
        _ ) ->
        false

  let pp ppf = function
    | User -> Format.pp_print_string ppf "user"
    | Goal_continuation -> Format.pp_print_string ppf "goal-continuation"
    | Queued id -> Format.fprintf ppf "queued(%a)" Queue.Id.pp id
    | Triggered { charter; digest; key } ->
        Format.fprintf ppf "triggered(%s@%s:%s)" charter digest key
    | Plan_build -> Format.pp_print_string ppf "plan-build"
    | Compaction -> Format.pp_print_string ppf "compaction"
    | Step_limit_wind_down -> Format.pp_print_string ppf "step-limit-wind-down"

  let jsont =
    let user_case =
      Jsont.Object.map ~kind:"user origin" User
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "user" ~dec:Fun.id
    in
    let goal_case =
      Jsont.Object.map ~kind:"goal-continuation origin" Goal_continuation
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "goal_continuation" ~dec:Fun.id
    in
    let queued_case =
      Jsont.Object.map ~kind:"queued origin" (fun id -> Queued id)
      |> Jsont.Object.mem "entry" Queue.Id.jsont ~enc:(function
        | Queued id -> id
        | User | Goal_continuation | Triggered _ | Plan_build | Compaction
        | Step_limit_wind_down ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "queued" ~dec:Fun.id
    in
    let triggered_case =
      Jsont.Object.map ~kind:"triggered origin" (fun charter digest key ->
          decode_invalid_arg (fun () -> triggered ~charter ~digest ~key))
      |> Jsont.Object.mem "charter" Jsont.string ~enc:(function
        | Triggered { charter; _ } -> charter
        | User | Goal_continuation | Queued _ | Plan_build | Compaction
        | Step_limit_wind_down ->
            assert false)
      |> Jsont.Object.mem "digest" Jsont.string ~enc:(function
        | Triggered { digest; _ } -> digest
        | User | Goal_continuation | Queued _ | Plan_build | Compaction
        | Step_limit_wind_down ->
            assert false)
      |> Jsont.Object.mem "key" Jsont.string ~enc:(function
        | Triggered { key; _ } -> key
        | User | Goal_continuation | Queued _ | Plan_build | Compaction
        | Step_limit_wind_down ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "triggered" ~dec:Fun.id
    in
    let plan_case =
      Jsont.Object.map ~kind:"plan-build origin" Plan_build
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "plan_build" ~dec:Fun.id
    in
    let compaction_case =
      Jsont.Object.map ~kind:"compaction origin" Compaction
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "compaction" ~dec:Fun.id
    in
    let step_limit_case =
      Jsont.Object.map ~kind:"step-limit wind-down origin" Step_limit_wind_down
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "step_limit_wind_down" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [
          user_case;
          goal_case;
          queued_case;
          triggered_case;
          plan_case;
          compaction_case;
          step_limit_case;
        ]
    in
    let enc_case = function
      | User as origin -> Jsont.Object.Case.value user_case origin
      | Goal_continuation as origin -> Jsont.Object.Case.value goal_case origin
      | Queued _ as origin -> Jsont.Object.Case.value queued_case origin
      | Triggered _ as origin -> Jsont.Object.Case.value triggered_case origin
      | Plan_build as origin -> Jsont.Object.Case.value plan_case origin
      | Compaction as origin -> Jsont.Object.Case.value compaction_case origin
      | Step_limit_wind_down as origin ->
          Jsont.Object.Case.value step_limit_case origin
    in
    Jsont.Object.map ~kind:"turn origin" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Input = struct
  type t =
    | User of Mentat_llm.Content.t list
    | Continue
    | Plan_build of Plan.Approval.t

  let user content =
    if List.is_empty content then
      invalid "Input.user" "content must not be empty";
    User content

  let user_text text = user [ Mentat_llm.Content.text text ]

  let text = function
    | Continue -> None
    | Plan_build approval -> Some (Plan.Approval.to_model_text approval)
    | User content ->
        let texts =
          List.filter_map
            (function
              | Mentat_llm.Content.Text text -> Some text
              | Mentat_llm.Content.Media _ -> None)
            content
        in
        if List.is_empty texts then None else Some (String.concat " " texts)

  let continue = Continue
  let plan_build approval = Plan_build approval

  let equal a b =
    match (a, b) with
    | User a, User b ->
        a = b
        (* Content blocks carry no JSON and no functions, so structural
           equality is exact (see {!Mentat_llm.Content}). *)
    | Continue, Continue -> true
    | Plan_build a, Plan_build b -> Plan.Approval.equal a b
    | (User _ | Continue | Plan_build _), _ -> false

  let pp ppf = function
    | User content ->
        Format.fprintf ppf "user[%d content block(s)]" (List.length content)
    | Continue -> Format.pp_print_string ppf "continue"
    | Plan_build approval ->
        Format.fprintf ppf "plan-build(%a)" Plan.Approval.pp approval

  let jsont =
    let user_case =
      Jsont.Object.map ~kind:"user turn input" (fun content ->
          decode_invalid_arg (fun () -> user content))
      |> Jsont.Object.mem "content" (Jsont.list Mentat_llm.Content.jsont)
           ~enc:(function
           | User content -> content
           | Continue | Plan_build _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "user" ~dec:Fun.id
    in
    let continue_case =
      Jsont.Object.map ~kind:"continue turn input" Continue
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "continue" ~dec:Fun.id
    in
    let plan_build_case =
      Jsont.Object.map ~kind:"plan-build turn input" (fun approval ->
          Plan_build approval)
      |> Jsont.Object.mem "approval" Plan.Approval.jsont ~enc:(function
        | Plan_build approval -> approval
        | User _ | Continue -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "plan_build" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ user_case; continue_case; plan_build_case ]
    in
    let enc_case = function
      | User _ as input -> Jsont.Object.Case.value user_case input
      | Continue as input -> Jsont.Object.Case.value continue_case input
      | Plan_build _ as input -> Jsont.Object.Case.value plan_build_case input
    in
    Jsont.Object.map ~kind:"turn input" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Outcome = struct
  type t =
    | Completed
    | Step_limit
    | Interrupted of { reason : string option; cancelled : bool }
    | Failed of { message : string }

  let completed = Completed
  let step_limit = Step_limit

  let interrupted ?reason ~cancelled () =
    reject_empty_option "Outcome.interrupted" "reason" reason;
    Interrupted { reason; cancelled }

  let failed ~message =
    if String.is_empty message then
      invalid "Outcome.failed" "message must not be empty";
    Failed { message }

  let equal a b = a = b

  let pp ppf = function
    | Completed -> Format.pp_print_string ppf "completed"
    | Step_limit -> Format.pp_print_string ppf "step-limit"
    | Interrupted { reason = None; cancelled } ->
        Format.fprintf ppf "interrupted(cancelled=%B)" cancelled
    | Interrupted { reason = Some reason; cancelled } ->
        Format.fprintf ppf "interrupted(reason=%S, cancelled=%B)" reason
          cancelled
    | Failed { message } -> Format.fprintf ppf "failed(%S)" message

  let jsont =
    let completed_case =
      Jsont.Object.map ~kind:"completed turn outcome" Completed
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "completed" ~dec:Fun.id
    in
    let step_limit_case =
      Jsont.Object.map ~kind:"step-limit turn outcome" Step_limit
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "step_limit" ~dec:Fun.id
    in
    let interrupted_case =
      Jsont.Object.map ~kind:"interrupted turn outcome" (fun reason cancelled ->
          decode_invalid_arg (fun () -> interrupted ?reason ~cancelled ()))
      |> Jsont.Object.opt_mem "reason" Jsont.string ~enc:(function
        | Interrupted { reason; _ } -> reason
        | Completed | Step_limit | Failed _ -> assert false)
      |> Jsont.Object.mem "cancelled" Jsont.bool ~enc:(function
        | Interrupted { cancelled; _ } -> cancelled
        | Completed | Step_limit | Failed _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "interrupted" ~dec:Fun.id
    in
    let failed_case =
      Jsont.Object.map ~kind:"failed turn outcome" (fun message ->
          decode_invalid_arg (fun () -> failed ~message))
      |> Jsont.Object.mem "message" Jsont.string ~enc:(function
        | Failed { message } -> message
        | Completed | Step_limit | Interrupted _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "failed" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ completed_case; step_limit_case; interrupted_case; failed_case ]
    in
    let enc_case = function
      | Completed as outcome -> Jsont.Object.Case.value completed_case outcome
      | Step_limit as outcome -> Jsont.Object.Case.value step_limit_case outcome
      | Interrupted _ as outcome ->
          Jsont.Object.Case.value interrupted_case outcome
      | Failed _ as outcome -> Jsont.Object.Case.value failed_case outcome
    in
    Jsont.Object.map ~kind:"turn outcome" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  id : Id.t;
  origin : Origin.t;
  input : Input.t;
  max_steps : int;
  contract : Contract.t;
}

let make ~id ~origin ~input ~max_steps ~contract () =
  if max_steps <= 0 then invalid "make" "max_steps must be positive";
  { id; origin; input; max_steps; contract }

let id t = t.id
let origin t = t.origin
let input t = t.input
let max_steps t = t.max_steps
let contract t = t.contract

let equal a b =
  Id.equal a.id b.id
  && Origin.equal a.origin b.origin
  && Input.equal a.input b.input
  && Int.equal a.max_steps b.max_steps
  && Contract.equal a.contract b.contract

let pp ppf t =
  Format.fprintf ppf "@[<hov>{ id = %a; origin = %a; input = %a; model = %a }@]"
    Id.pp t.id Origin.pp t.origin Input.pp t.input Mentat_llm.Model.pp
    (Contract.model t.contract)

let jsont =
  Jsont.Object.map ~kind:"session turn"
    (fun id origin input max_steps contract ->
      decode_invalid_arg (fun () ->
          make ~id ~origin ~input ~max_steps ~contract ()))
  |> Jsont.Object.mem "id" Id.jsont ~enc:id
  |> Jsont.Object.mem "origin" Origin.jsont ~enc:origin
  |> Jsont.Object.mem "input" Input.jsont ~enc:input
  |> Jsont.Object.mem "max_steps" Jsont.int ~enc:max_steps
  |> Jsont.Object.mem "contract" Contract.jsont ~enc:contract
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
