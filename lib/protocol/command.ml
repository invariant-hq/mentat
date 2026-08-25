(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

module Invalid = struct
  type t =
    | Empty_prompt_input
    | Non_positive_max_steps of int
    | Empty_interrupt_reason
    | Empty_queue_input
    | Empty_queue_replacement
    | Empty_queue_entry of int
    | Empty_goal_objective
    | Negative_goal_budget of int
    | Empty_triggered_member of string
    | Output_schema_not_object

  let equal a b =
    match (a, b) with
    | Empty_prompt_input, Empty_prompt_input -> true
    | Non_positive_max_steps a, Non_positive_max_steps b -> Int.equal a b
    | Empty_interrupt_reason, Empty_interrupt_reason -> true
    | Empty_queue_input, Empty_queue_input -> true
    | Empty_queue_replacement, Empty_queue_replacement -> true
    | Empty_queue_entry a, Empty_queue_entry b -> Int.equal a b
    | Empty_goal_objective, Empty_goal_objective -> true
    | Negative_goal_budget a, Negative_goal_budget b -> Int.equal a b
    | Empty_triggered_member a, Empty_triggered_member b -> String.equal a b
    | Output_schema_not_object, Output_schema_not_object -> true
    | ( ( Empty_prompt_input | Non_positive_max_steps _ | Empty_interrupt_reason
        | Empty_queue_input | Empty_queue_replacement | Empty_queue_entry _
        | Empty_goal_objective | Negative_goal_budget _
        | Empty_triggered_member _ | Output_schema_not_object ),
        _ ) ->
        false

  let message = function
    | Empty_prompt_input -> "prompt input must not be empty"
    | Non_positive_max_steps n ->
        Printf.sprintf "max_steps must be positive (got %d)" n
    | Empty_interrupt_reason -> "interrupt reason must not be empty"
    | Empty_queue_input -> "queue input must not be empty"
    | Empty_queue_replacement -> "queue replacement must not be empty"
    | Empty_queue_entry index ->
        Printf.sprintf "queue replacement entry %d must not be empty" (index + 1)
    | Empty_goal_objective -> "goal objective must not be empty"
    | Negative_goal_budget n ->
        Printf.sprintf "goal budget must not be negative (got %d)" n
    | Empty_triggered_member member ->
        Printf.sprintf "triggered %s must not be empty" member
    | Output_schema_not_object -> "output schema must be a JSON object"

  let pp ppf t = Format.pp_print_string ppf (message t)
end

type goal = { objective : string; token_budget : int option }
type triggered = { charter : string; digest : string; key : string }

type t =
  | Prompt of {
      session : Mentat_session.Id.t;
      turn : Mentat_session.Turn.Id.t;
      input : Mentat_llm.Content.t list;
      options : Mentat_llm.Request.Options.t option;
      mode : Mentat_session.Contract.Mode.t option;
      max_steps : int option;
      goal : goal option;
      triggered : triggered option;
      output_schema : Jsont.json option;
    }
  | Answer_decision of {
      session : Mentat_session.Id.t;
      decision : Mentat_session.Decision.Id.t;
      answer : Mentat_session.Decision.Answer.t;
    }
  | Interrupt of { session : Mentat_session.Id.t; reason : string option }
  | Queue_next of {
      session : Mentat_session.Id.t;
      input : Mentat_llm.Content.t list;
    }
  | Replace_queued of {
      session : Mentat_session.Id.t;
      inputs : Mentat_llm.Content.t list list;
    }
  | Clear_queued of { session : Mentat_session.Id.t }
  | Goal_pause of {
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
    }
  | Goal_edit of {
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
      objective : string;
    }
  | Goal_resume of {
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
      budget : int option;
    }
  | Goal_clear of {
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
    }

let prompt ~session ~turn ~input ?options ?mode ?max_steps ?goal ?triggered
    ?output_schema () =
  if List.is_empty input then Error Invalid.Empty_prompt_input
  else
    match max_steps with
    | Some n when n < 1 -> Error (Invalid.Non_positive_max_steps n)
    | Some _ | None -> (
        match goal with
        | Some { objective; _ } when String.is_empty objective ->
            Error Invalid.Empty_goal_objective
        | Some { token_budget = Some n; _ } when n < 0 ->
            Error (Invalid.Negative_goal_budget n)
        | Some _ | None -> (
            match triggered with
            | Some { charter; _ } when String.is_empty charter ->
                Error (Invalid.Empty_triggered_member "charter")
            | Some { digest; _ } when String.is_empty digest ->
                Error (Invalid.Empty_triggered_member "digest")
            | Some { key; _ } when String.is_empty key ->
                Error (Invalid.Empty_triggered_member "key")
            | Some _ | None -> (
                match output_schema with
                | Some (Jsont.Object _) | None ->
                    Ok
                      (Prompt
                         {
                           session;
                           turn;
                           input;
                           options;
                           mode;
                           max_steps;
                           goal;
                           triggered;
                           output_schema;
                         })
                | Some _ -> Error Invalid.Output_schema_not_object)))

let answer_decision ~session ~decision ~answer =
  Answer_decision { session; decision; answer }

let interrupt ~session ?reason () =
  match reason with
  | Some reason when String.is_empty reason ->
      Error Invalid.Empty_interrupt_reason
  | Some _ | None -> Ok (Interrupt { session; reason })

let queue_next ~session ~input =
  if List.is_empty input then Error Invalid.Empty_queue_input
  else Ok (Queue_next { session; input })

let replace_queued ~session ~inputs =
  let rec first_empty index = function
    | [] -> None
    | input :: rest ->
        if List.is_empty input then Some index else first_empty (index + 1) rest
  in
  match inputs with
  | [] -> Error Invalid.Empty_queue_replacement
  | _ -> (
      match first_empty 0 inputs with
      | Some index -> Error (Invalid.Empty_queue_entry index)
      | None -> Ok (Replace_queued { session; inputs }))

let clear_queued ~session = Clear_queued { session }
let goal_pause ~session ~goal = Goal_pause { session; goal }

let goal_edit ~session ~goal ~objective =
  if String.is_empty objective then Error Invalid.Empty_goal_objective
  else Ok (Goal_edit { session; goal; objective })

let goal_resume ~session ~goal ?budget () =
  match budget with
  | Some n when n < 0 -> Error (Invalid.Negative_goal_budget n)
  | Some _ | None -> Ok (Goal_resume { session; goal; budget })

let goal_clear ~session ~goal = Goal_clear { session; goal }

let session = function
  | Prompt { session; _ }
  | Answer_decision { session; _ }
  | Interrupt { session; _ }
  | Queue_next { session; _ }
  | Replace_queued { session; _ }
  | Clear_queued { session }
  | Goal_pause { session; _ }
  | Goal_edit { session; _ }
  | Goal_resume { session; _ }
  | Goal_clear { session; _ } ->
      session

let pp ppf t =
  let name =
    match t with
    | Prompt _ -> "prompt"
    | Answer_decision _ -> "answer-decision"
    | Interrupt _ -> "interrupt"
    | Queue_next _ -> "queue-next"
    | Replace_queued _ -> "replace-queued"
    | Clear_queued _ -> "clear-queued"
    | Goal_pause _ -> "goal-pause"
    | Goal_edit _ -> "goal-edit"
    | Goal_resume _ -> "goal-resume"
    | Goal_clear _ -> "goal-clear"
  in
  Format.fprintf ppf "%s(%a)" name Mentat_session.Id.pp (session t)

let jsont =
  let decode_result = function
    | Ok v -> v
    | Error invalid -> decode_error (Invalid.message invalid)
  in
  let goal_jsont =
    Jsont.Object.map ~kind:"prompt goal" (fun objective token_budget ->
        { objective; token_budget })
    |> Jsont.Object.mem "objective" Jsont.string ~enc:(fun g -> g.objective)
    |> Jsont.Object.opt_mem "token_budget" Jsont.int ~enc:(fun g ->
        g.token_budget)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
  in
  let triggered_jsont =
    Jsont.Object.map ~kind:"prompt trigger provenance"
      (fun charter digest key -> { charter; digest; key })
    |> Jsont.Object.mem "charter" Jsont.string ~enc:(fun t -> t.charter)
    |> Jsont.Object.mem "digest" Jsont.string ~enc:(fun t -> t.digest)
    |> Jsont.Object.mem "key" Jsont.string ~enc:(fun t -> t.key)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
  in
  let prompt_case =
    Jsont.Object.map ~kind:"prompt command"
      (fun session turn input options mode max_steps goal triggered
           output_schema ->
        decode_result
          (prompt ~session ~turn ~input ?options ?mode ?max_steps ?goal
             ?triggered ?output_schema ()))
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Prompt { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.mem "turn" Mentat_session.Turn.Id.jsont ~enc:(function
      | Prompt { turn; _ } -> turn
      | _ -> assert false)
    |> Jsont.Object.mem "input" (Jsont.list Mentat_llm.Content.jsont)
         ~enc:(function
         | Prompt { input; _ } -> input
         | _ -> assert false)
    |> Jsont.Object.opt_mem "options" Mentat_llm.Request.Options.jsont
         ~enc:(function
         | Prompt { options; _ } -> options
         | _ -> assert false)
    |> Jsont.Object.opt_mem "mode" Mentat_session.Contract.Mode.jsont
         ~enc:(function
         | Prompt { mode; _ } -> mode
         | _ -> assert false)
    |> Jsont.Object.opt_mem "max_steps" Jsont.int ~enc:(function
      | Prompt { max_steps; _ } -> max_steps
      | _ -> assert false)
    |> Jsont.Object.opt_mem "goal" goal_jsont ~enc:(function
      | Prompt { goal; _ } -> goal
      | _ -> assert false)
    |> Jsont.Object.opt_mem "triggered" triggered_jsont ~enc:(function
      | Prompt { triggered; _ } -> triggered
      | _ -> assert false)
    |> Jsont.Object.opt_mem "output_schema" Jsont.json ~enc:(function
      | Prompt { output_schema; _ } -> output_schema
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "prompt" ~dec:Fun.id
  in
  let answer_decision_case =
    Jsont.Object.map ~kind:"answer-decision command"
      (fun session decision answer ->
        answer_decision ~session ~decision ~answer)
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Answer_decision { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.mem "decision" Mentat_session.Decision.Id.jsont
         ~enc:(function
         | Answer_decision { decision; _ } -> decision
         | _ -> assert false)
    |> Jsont.Object.mem "answer" Mentat_session.Decision.Answer.jsont
         ~enc:(function
         | Answer_decision { answer; _ } -> answer
         | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "answer_decision" ~dec:Fun.id
  in
  let interrupt_case =
    Jsont.Object.map ~kind:"interrupt command" (fun session reason ->
        decode_result (interrupt ~session ?reason ()))
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Interrupt { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.opt_mem "reason" Jsont.string ~enc:(function
      | Interrupt { reason; _ } -> reason
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "interrupt" ~dec:Fun.id
  in
  let queue_case kind tag make proj =
    Jsont.Object.map ~kind (fun session input ->
        decode_result (make ~session ~input))
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun t ->
        fst (proj t))
    |> Jsont.Object.mem "input" (Jsont.list Mentat_llm.Content.jsont)
         ~enc:(fun t -> snd (proj t))
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let queue_next_case =
    queue_case "queue-next command" "queue_next" queue_next (function
      | Queue_next { session; input } -> (session, input)
      | _ -> assert false)
  in
  let replace_queued_case =
    Jsont.Object.map ~kind:"replace-queued command" (fun session inputs ->
        decode_result (replace_queued ~session ~inputs))
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Replace_queued { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.mem "inputs"
         (Jsont.list (Jsont.list Mentat_llm.Content.jsont))
         ~enc:(function
           | Replace_queued { inputs; _ } -> inputs | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "replace_queued" ~dec:Fun.id
  in
  let session_only kind tag make proj =
    Jsont.Object.map ~kind (fun session -> make ~session)
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:proj
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let clear_queued_case =
    session_only "clear-queued command" "clear_queued" clear_queued (function
      | Clear_queued { session } -> session
      | _ -> assert false)
  in
  let goal_session_only kind tag make proj =
    Jsont.Object.map ~kind (fun session goal -> make ~session ~goal)
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun t ->
        fst (proj t))
    |> Jsont.Object.mem "goal" Mentat_session.Goal.Id.jsont ~enc:(fun t ->
        snd (proj t))
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let goal_pause_case =
    goal_session_only "goal-pause command" "goal.pause" goal_pause (function
      | Goal_pause { session; goal } -> (session, goal)
      | _ -> assert false)
  in
  let goal_edit_case =
    Jsont.Object.map ~kind:"goal-edit command" (fun session goal objective ->
        decode_result (goal_edit ~session ~goal ~objective))
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Goal_edit { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.mem "goal" Mentat_session.Goal.Id.jsont ~enc:(function
      | Goal_edit { goal; _ } -> goal
      | _ -> assert false)
    |> Jsont.Object.mem "objective" Jsont.string ~enc:(function
      | Goal_edit { objective; _ } -> objective
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "goal.edit" ~dec:Fun.id
  in
  let goal_resume_case =
    Jsont.Object.map ~kind:"goal-resume command" (fun session goal budget ->
        decode_result (goal_resume ~session ~goal ?budget ()))
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Goal_resume { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.mem "goal" Mentat_session.Goal.Id.jsont ~enc:(function
      | Goal_resume { goal; _ } -> goal
      | _ -> assert false)
    |> Jsont.Object.opt_mem "budget" Jsont.int ~enc:(function
      | Goal_resume { budget; _ } -> budget
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "goal.resume" ~dec:Fun.id
  in
  let goal_clear_case =
    goal_session_only "goal-clear command" "goal.clear" goal_clear (function
      | Goal_clear { session; goal } -> (session, goal)
      | _ -> assert false)
  in
  let cases =
    List.map Jsont.Object.Case.make
      [
        prompt_case;
        answer_decision_case;
        interrupt_case;
        queue_next_case;
        replace_queued_case;
        clear_queued_case;
        goal_pause_case;
        goal_edit_case;
        goal_resume_case;
        goal_clear_case;
      ]
  in
  let enc_case = function
    | Prompt _ as c -> Jsont.Object.Case.value prompt_case c
    | Answer_decision _ as c -> Jsont.Object.Case.value answer_decision_case c
    | Interrupt _ as c -> Jsont.Object.Case.value interrupt_case c
    | Queue_next _ as c -> Jsont.Object.Case.value queue_next_case c
    | Replace_queued _ as c -> Jsont.Object.Case.value replace_queued_case c
    | Clear_queued _ as c -> Jsont.Object.Case.value clear_queued_case c
    | Goal_pause _ as c -> Jsont.Object.Case.value goal_pause_case c
    | Goal_edit _ as c -> Jsont.Object.Case.value goal_edit_case c
    | Goal_resume _ as c -> Jsont.Object.Case.value goal_resume_case c
    | Goal_clear _ as c -> Jsont.Object.Case.value goal_clear_case c
  in
  Jsont.Object.map ~kind:"command" (fun v c ->
      Wire.check v;
      c)
  |> Wire.mem
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.finish
