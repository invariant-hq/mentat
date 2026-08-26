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
    | Empty_triggered_member a, Empty_triggered_member b -> String.equal a b
    | Output_schema_not_object, Output_schema_not_object -> true
    | ( ( Empty_prompt_input | Non_positive_max_steps _ | Empty_interrupt_reason
        | Empty_queue_input | Empty_queue_replacement | Empty_queue_entry _
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
    | Empty_triggered_member member ->
        Printf.sprintf "triggered %s must not be empty" member
    | Output_schema_not_object -> "output schema must be a JSON object"

  let pp ppf t = Format.pp_print_string ppf (message t)
end

type triggered = { charter : string; digest : string; key : string }

type t =
  | Prompt of {
      session : Mentat_session.Id.t;
      turn : Mentat_session.Turn.Id.t;
      input : Mentat_llm.Content.t list;
      options : Mentat_llm.Request.Options.t option;
      mode : Mentat_session.Contract.Mode.t option;
      max_steps : int option;
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
      id : Mentat_session.Queue.Id.t option;
      input : Mentat_llm.Content.t list;
    }
  | Replace_queued of {
      session : Mentat_session.Id.t;
      inputs : Mentat_llm.Content.t list list;
    }
  | Clear_queued of { session : Mentat_session.Id.t }

let prompt ~session ~turn ~input ?options ?mode ?max_steps ?triggered
    ?output_schema () =
  if List.is_empty input then Error Invalid.Empty_prompt_input
  else
    match max_steps with
    | Some n when n < 1 -> Error (Invalid.Non_positive_max_steps n)
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
                       triggered;
                       output_schema;
                     })
            | Some _ -> Error Invalid.Output_schema_not_object))

let answer_decision ~session ~decision ~answer =
  Answer_decision { session; decision; answer }

let interrupt ~session ?reason () =
  match reason with
  | Some reason when String.is_empty reason ->
      Error Invalid.Empty_interrupt_reason
  | Some _ | None -> Ok (Interrupt { session; reason })

let queue_next ?id ~session ~input () =
  if List.is_empty input then Error Invalid.Empty_queue_input
  else Ok (Queue_next { session; id; input })

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

let session = function
  | Prompt { session; _ }
  | Answer_decision { session; _ }
  | Interrupt { session; _ }
  | Queue_next { session; _ }
  | Replace_queued { session; _ }
  | Clear_queued { session } ->
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
  in
  Format.fprintf ppf "%s(%a)" name Mentat_session.Id.pp (session t)

let jsont =
  let decode_result = function
    | Ok v -> v
    | Error invalid -> decode_error (Invalid.message invalid)
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
      (fun session turn input options mode max_steps triggered output_schema ->
        decode_result
          (prompt ~session ~turn ~input ?options ?mode ?max_steps ?triggered
             ?output_schema ()))
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
  let queue_next_case =
    Jsont.Object.map ~kind:"queue-next command" (fun session id input ->
        decode_result (queue_next ?id ~session ~input ()))
    |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(function
      | Queue_next { session; _ } -> session
      | _ -> assert false)
    |> Jsont.Object.opt_mem "id" Mentat_session.Queue.Id.jsont ~enc:(function
      | Queue_next { id; _ } -> id
      | _ -> assert false)
    |> Jsont.Object.mem "input" (Jsont.list Mentat_llm.Content.jsont)
         ~enc:(function
         | Queue_next { input; _ } -> input
         | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "queue_next" ~dec:Fun.id
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
  let cases =
    List.map Jsont.Object.Case.make
      [
        prompt_case;
        answer_decision_case;
        interrupt_case;
        queue_next_case;
        replace_queued_case;
        clear_queued_case;
      ]
  in
  let enc_case = function
    | Prompt _ as c -> Jsont.Object.Case.value prompt_case c
    | Answer_decision _ as c -> Jsont.Object.Case.value answer_decision_case c
    | Interrupt _ as c -> Jsont.Object.Case.value interrupt_case c
    | Queue_next _ as c -> Jsont.Object.Case.value queue_next_case c
    | Replace_queued _ as c -> Jsont.Object.Case.value replace_queued_case c
    | Clear_queued _ as c -> Jsont.Object.Case.value clear_queued_case c
  in
  Jsont.Object.map ~kind:"command" (fun v c ->
      Wire.check v;
      c)
  |> Wire.mem
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.finish
