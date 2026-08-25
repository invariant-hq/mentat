(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Catalog = Catalog
module Env = Env

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as e -> e

module Error = struct
  type t =
    | No_active_turn
    | No_pending_wait
    | Call_not_pending of { call_id : string; name : string }
    | Session of Mentat_session.Error.t
    | Request of Mentat_llm.Request.Error.t
    | Decision of Mentat_session.Decision.Resolve_error.t

  let message = function
    | No_active_turn -> "session has no active turn"
    | No_pending_wait -> "no pending wait call to answer"
    | Call_not_pending { call_id; name } ->
        Printf.sprintf "tool call is not pending: %s (%s)" call_id name
    | Session error -> Mentat_session.Error.message error
    | Request error -> Mentat_llm.Request.Error.message error
    | Decision error -> Mentat_session.Decision.Resolve_error.message error

  let pp ppf error = Format.pp_print_string ppf (message error)
end

module Step = struct
  module Reservation = struct
    module Refusal = struct
      type t = Capacity of { limit : int }
    end

    type t = {
      call : Mentat_llm.Tool.Call.t;
      edge : Mentat_session.Delegation.t;
    }

    let delegation t = Mentat_session.Delegation.id t.edge
  end

  module Children_wait = struct
    type t = {
      turn : Mentat_session.Turn.Id.t;
      wait_call : string;
      children : Mentat_session.Delegation.Id.t list;
    }
  end

  module Child_message = struct
    type t = {
      turn : Mentat_session.Turn.Id.t;
      call_id : string;
      kind : [ `Context | `Follow_up ];
      child : Mentat_session.Delegation.Id.t;
      message : string;
    }
  end

  module Effect = struct
    type t =
      | Model of {
          claim : Mentat_session.Provider_request.Started.t;
          request : Mentat_llm.Request.t;
          purpose :
            [ `Turn
            | `Compaction of Mentat_session.Compaction.Reason.t * int ];
        }
      | Tool of {
          claim : Mentat_session.Tool_claim.Started.t;
          call : Mentat_tool.Call.t;
        }
  end

  type action =
    | Perform of Effect.t
    | Reserve_child of Reservation.t
    | Await_decision of Mentat_session.Decision.Requested.t
    | Await_children of Children_wait.t
    | Settled of {
        turn : Mentat_session.Turn.Id.t;
        outcome : Mentat_session.Turn.Outcome.t;
      }
    | Idle

  type t = { events : Mentat_session.Event.t list; action : action }

  let events t = t.events
  let action t = t.action
end

(* An internal transition: either pure micro-step events to fold and keep
   planning, or a boundary — events to commit plus the single action. All
   batched micro-steps land in one [Step.events], so atomicity claims (the
   task board, the denial pairing) are one store append. *)
type transition =
  | Continue of Mentat_session.Event.t list
  | Act of Mentat_session.Event.t list * Step.action

(* Model-visible answers. Empty text never reaches the durable result. *)

let error_result call text =
  let text = if String.equal (String.trim text) "" then "failed" else text in
  Mentat_session.Event.message_appended
    (Mentat_llm.Message.tool_result
       (Mentat_llm.Tool.Result.text ~error:true call text))

let receipt_result call text =
  Mentat_session.Event.message_appended
    (Mentat_llm.Message.tool_result (Mentat_llm.Tool.Result.text call text))

let failure text = Continue [ text ]

let active_turn session =
  match Mentat_session.State.active_turn (Mentat_session.state session) with
  | Some turn -> Ok turn
  | None -> Error Error.No_active_turn

let pending_call state call_id =
  List.find_opt
    (fun call -> String.equal (Mentat_llm.Tool.Call.id call) call_id)
    (Mentat_llm.Transcript.pending (Mentat_session.State.full_transcript state))

(* Verb inputs.

   Each codec is paired with the input schema advertised by [Catalog.Verb] and
   rejects unknown members just as that schema does. A decode failure is a
   model-visible failed result, never an outer error. *)

type todo_item = {
  task_id : string;
  task_content : string;
  task_status : Mentat_session.Task.Status.t option;
  task_priority : Mentat_session.Task.Priority.t option;
}

let todo_item_jsont =
  Jsont.Object.map ~kind:"task"
    (fun task_id task_content task_status task_priority ->
      { task_id; task_content; task_status; task_priority })
  |> Jsont.Object.mem "id" Jsont.string ~enc:(fun i -> i.task_id)
  |> Jsont.Object.mem "content" Jsont.string ~enc:(fun i -> i.task_content)
  |> Jsont.Object.opt_mem "status" Mentat_session.Task.Status.jsont
       ~enc:(fun i -> i.task_status)
  |> Jsont.Object.opt_mem "priority" Mentat_session.Task.Priority.jsont
       ~enc:(fun i -> i.task_priority)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

type todo_input = { tasks : todo_item list }

let todo_input_jsont =
  Jsont.Object.map ~kind:"todo_write" (fun tasks -> { tasks })
  |> Jsont.Object.mem "tasks" (Jsont.list todo_item_jsont) ~enc:(fun i ->
      i.tasks)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

type ask_input = { ask_prompt : string; ask_choices : string list option }

let ask_input_jsont =
  Jsont.Object.map ~kind:"ask_user" (fun ask_prompt ask_choices ->
      { ask_prompt; ask_choices })
  |> Jsont.Object.mem "prompt" Jsont.string ~enc:(fun i -> i.ask_prompt)
  |> Jsont.Object.opt_mem "choices" (Jsont.list Jsont.string) ~enc:(fun i ->
      i.ask_choices)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

type plan_input = { plan_title : string option; plan_body : string }

let plan_input_jsont =
  Jsont.Object.map ~kind:"propose_plan" (fun plan_title plan_body ->
      { plan_title; plan_body })
  |> Jsont.Object.opt_mem "title" Jsont.string ~enc:(fun i -> i.plan_title)
  |> Jsont.Object.mem "body" Jsont.string ~enc:(fun i -> i.plan_body)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

type spawn_input = {
  spawn_task : string;
  spawn_description : string option;
  spawn_role : Mentat_session.Delegation.Role.t option;
}

(* The wire role admits "general" as the affirmative spelling of the
   write-capable roleless delegate: function-calling models reliably fill an
   enum rather than omit it, so an omission-only spelling is unreachable in
   practice (observed 12/12 role-filled spawns against an omission-documented
   schema). "general" and absence both mean no role. *)
let spawn_role_jsont =
  Jsont.enum ~kind:"spawn role"
    [
      ("general", None);
      ("explore", Some Mentat_session.Delegation.Role.Explore);
      ("review", Some Mentat_session.Delegation.Role.Review);
      ("verify", Some Mentat_session.Delegation.Role.Verify);
    ]

let spawn_input_jsont =
  Jsont.Object.map ~kind:"spawn" (fun spawn_task spawn_description spawn_role ->
      { spawn_task; spawn_description; spawn_role = Option.join spawn_role })
  |> Jsont.Object.mem "task" Jsont.string ~enc:(fun i -> i.spawn_task)
  |> Jsont.Object.opt_mem "description" Jsont.string ~enc:(fun i ->
      i.spawn_description)
  |> Jsont.Object.opt_mem "role" spawn_role_jsont ~enc:(fun i ->
      match i.spawn_role with None -> None | Some _ as role -> Some role)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

type wait_input = { wait_children : string list }

let wait_input_jsont =
  Jsont.Object.map ~kind:"wait" (fun wait_children -> { wait_children })
  |> Jsont.Object.mem "children" (Jsont.list Jsont.string) ~enc:(fun i ->
      i.wait_children)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

type message_input = { msg_child : string; msg_message : string }

let message_input_jsont ~kind =
  Jsont.Object.map ~kind (fun msg_child msg_message ->
      { msg_child; msg_message })
  |> Jsont.Object.mem "child" Jsont.string ~enc:(fun i -> i.msg_child)
  |> Jsont.Object.mem "message" Jsont.string ~enc:(fun i -> i.msg_message)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let send_message_jsont = message_input_jsont ~kind:"send_message"
let follow_up_jsont = message_input_jsont ~kind:"follow_up"

let decode_verb_input jsont call k =
  match Jsont.Json.decode jsont (Mentat_llm.Tool.Call.input call) with
  | Ok input -> k input
  | Error message -> failure (error_result call ("invalid input: " ^ message))

(* Recorded child messages.

   The durable carrier of a parent-to-child message is the parent transcript:
   the verb call's decoded input plus its successful receipt. The scan pairs
   each [send_message]/[follow_up] call with its non-error result in journal
   order, tracking the enclosing turn — dispatch knowledge, never a journal
   heuristic. It backs the exchange cap here and the driver's delivery scan. *)

let child_message_kind name =
  if String.equal name (Catalog.Verb.name Catalog.Verb.Send_message) then
    Some `Context
  else if String.equal name (Catalog.Verb.name Catalog.Verb.Follow_up) then
    Some `Follow_up
  else None

let decoded_child_message ~turn ~kind call =
  let jsont =
    match kind with
    | `Context -> send_message_jsont
    | `Follow_up -> follow_up_jsont
  in
  match Jsont.Json.decode jsont (Mentat_llm.Tool.Call.input call) with
  | Error _ -> None
  | Ok input ->
      Some
        {
          Step.Child_message.turn;
          call_id = Mentat_llm.Tool.Call.id call;
          kind;
          child = Mentat_session.Delegation.Id.of_string input.msg_child;
          message = input.msg_message;
        }

let settled_messages session =
  (* [calls] indexes pending message-verb calls by call id, newest first, so a
     repeated provider call id pairs with its latest call. *)
  let scan (current_turn, calls, acc) event =
    match (event : Mentat_session.Event.t) with
    | Mentat_session.Event.Turn_started turn ->
        (Some (Mentat_session.Turn.id turn), calls, acc)
    | Mentat_session.Event.Provider_settled settled -> (
        match Mentat_session.Provider_request.Settled.outcome settled with
        | Mentat_session.Provider_request.Settled.Responded response ->
            let index calls call =
              match
                ( current_turn,
                  child_message_kind (Mentat_llm.Tool.Call.name call) )
              with
              | Some turn, Some kind ->
                  (Mentat_llm.Tool.Call.id call, (turn, kind, call)) :: calls
              | _ -> calls
            in
            let calls =
              List.fold_left index calls
                (Mentat_llm.Response.tool_calls response)
            in
            (current_turn, calls, acc)
        | _ -> (current_turn, calls, acc))
    | Mentat_session.Event.Message_appended
        (Mentat_llm.Message.Tool_result result)
      when not (Mentat_llm.Tool.Result.is_error result) -> (
        match List.assoc_opt (Mentat_llm.Tool.Result.call_id result) calls with
        | Some (turn, kind, call) -> (
            match decoded_child_message ~turn ~kind call with
            | Some message -> (current_turn, calls, message :: acc)
            | None -> (current_turn, calls, acc))
        | None -> (current_turn, calls, acc))
    | _ -> (current_turn, calls, acc)
  in
  let _, _, acc =
    List.fold_left scan (None, [], []) (Mentat_session.events session)
  in
  List.rev acc

let settled_message session event =
  match (event : Mentat_session.Event.t) with
  | Mentat_session.Event.Message_appended
      (Mentat_llm.Message.Tool_result result)
    when Option.is_some
           (child_message_kind (Mentat_llm.Tool.Result.name result))
         && not (Mentat_llm.Tool.Result.is_error result) ->
      let call_id = Mentat_llm.Tool.Result.call_id result in
      List.find_opt
        (fun m -> String.equal m.Step.Child_message.call_id call_id)
        (List.rev (settled_messages session))
  | _ -> None

(* Permission review.

   Decisions use the active turn's sealed contract policy with session grants
   layered over it. [Policy.decide] keeps explicit rules authoritative: a grant
   can satisfy an otherwise-unmatched access, but cannot override a matching
   [Review] or [Deny] rule. The contract's explicit bypass remains the sole way
   to suppress a review decision wholesale. *)

let review_requests state contract requests =
  let policy = Mentat_session.Contract.policy contract in
  let grants = Mentat_session.State.grants state in
  let bypass =
    match Mentat_session.Contract.review contract with
    | Mentat_permission.Review_behavior.Bypass -> true
    | Mentat_permission.Review_behavior.Enforce -> false
  in
  let rec loop = function
    | [] -> `Allowed
    | request :: rest -> (
        match Mentat_permission.Policy.decide ~grants policy request with
        | Mentat_permission.Policy.Decision.Allowed -> loop rest
        | Mentat_permission.Policy.Decision.Denied (first, _) -> `Denied first
        | Mentat_permission.Policy.Decision.Review review ->
            if bypass then loop rest else `Review review)
  in
  loop requests

(* Executable dispatch. *)

let contract_declaration contract name =
  List.find_opt
    (fun declaration -> String.equal (Mentat_llm.Tool.name declaration) name)
    (Mentat_session.Contract.declarations contract)

(* The resume-drift inputs: every dispatch target's current declaration and, for
   executable tools, the current sealed sandbox identity, composed against the
   active turn's sealed contract. Drift is a model-visible failed result naming
   the drift, never an execution. *)
let target_for env contract name =
  match contract_declaration contract name with
  | None -> Error ("tool is not declared for this turn: " ^ name)
  | Some sealed -> (
      match Catalog.resolve env.Env.catalog name with
      | None -> Error ("tool is not available: " ^ name)
      | Some target ->
          let current =
            match target with
            | `Executable tool -> Mentat_tool.declaration tool
            | `Verb verb -> Catalog.Verb.declaration verb
          in
          if Mentat_llm.Tool.equal current sealed then Ok target
          else
            Error
              ("tool declaration changed since this turn was sealed: " ^ name))

let check_sandbox env contract =
  if
    Mentat_sandbox.Identity.equal env.Env.sandbox
      (Mentat_session.Contract.sandbox contract)
  then Ok ()
  else
    Error
      (Format.asprintf
         "sandbox posture changed since this was suspended: %a -> %a"
         Mentat_sandbox.Identity.pp
         (Mentat_session.Contract.sandbox contract)
         Mentat_sandbox.Identity.pp env.Env.sandbox)

let executable_for env contract name =
  match target_for env contract name with
  | Ok (`Executable tool) ->
      Result.map (fun () -> tool) (check_sandbox env contract)
  | Ok (`Verb _) -> Error ("tool is not available: " ^ name)
  | Error _ as error -> error

let claim_and_perform turn_id tool_call =
  let claim =
    Mentat_session.Tool_claim.Started.make ~turn:turn_id
      ~stage:(Mentat_tool.Call.stage tool_call)
      ~call:(Mentat_tool.Call.source tool_call)
      ~input:(Mentat_tool.Call.input tool_call)
      ~requests:(Mentat_tool.Call.permissions tool_call)
  in
  Act
    ( [ Mentat_session.Event.tool_claimed claim ],
      Step.Perform (Step.Effect.Tool { claim; call = tool_call }) )

let dispatch_executable env state contract turn_id call tool =
  match Mentat_tool.Call.decode tool call with
  | Error e ->
      failure (error_result call (Mentat_tool.Call.Decode_error.message e))
  | Ok tool_call -> (
      match
        review_requests state contract (Mentat_tool.Call.permissions tool_call)
      with
      | `Denied denial ->
          failure (error_result call (env.Env.denial_message denial))
      | `Review review ->
          let requested =
            Mentat_session.Decision.Requested.make ~turn:turn_id ~call
              ~stage:(Mentat_tool.Call.stage tool_call)
              (Mentat_session.Decision.Request.Permission review)
          in
          Act
            ( [ Mentat_session.Event.decision_requested requested ],
              Step.Await_decision requested )
      | `Allowed -> claim_and_perform turn_id tool_call)

(* Verb evaluation.

   Each engine verb is a pure function of decoded input and state returning
   session-owned events plus the model-visible result, committed in one step.
   State-invalid deltas are pre-checked against the session's own [State.apply]
   and lowered into model-visible failed results. *)

let verb_delta session call events ~receipt =
  let events = events @ [ receipt_result call receipt ] in
  match Mentat_session.append_all events session with
  | Ok _ -> Continue events
  | Error e -> failure (error_result call (Mentat_session.Error.message e))

let non_empty s =
  let s = String.trim s in
  if String.equal s "" then None else Some s

let eval_todo_write session call input =
  let item index i =
    match (non_empty i.task_id, non_empty i.task_content) with
    | None, _ -> Error Mentat_session.Task.Error.Empty_content
    | _, None -> Error Mentat_session.Task.Error.Empty_content
    | Some id, Some content ->
        Mentat_session.Task.Item.make
          ~id:(Mentat_session.Task.Id.of_string id)
          ~owner:Mentat_session.Task.Owner.Main ~content ?status:i.task_status
          ?priority:i.task_priority ~position:index ()
  in
  let rec items index acc = function
    | [] -> Ok (List.rev acc)
    | i :: rest -> (
        match item index i with
        | Ok item -> items (index + 1) (item :: acc) rest
        | Error _ as e -> e)
  in
  match items 0 [] input.tasks with
  | Error e -> failure (error_result call (Mentat_session.Task.Error.message e))
  | Ok items -> (
      match Mentat_session.Task.Board.make items with
      | Error e ->
          failure (error_result call (Mentat_session.Task.Error.message e))
      | Ok board ->
          verb_delta session call
            [ Mentat_session.Event.tasks_replaced board ]
            ~receipt:
              (Printf.sprintf "Task board replaced (%d tasks)."
                 (List.length items)))

let eval_ask_user turn_id call input =
  match
    Mentat_session.Question.make ~prompt:input.ask_prompt
      ?choices:input.ask_choices ()
  with
  | Error e ->
      failure (error_result call (Mentat_session.Question.Error.message e))
  | Ok question ->
      let requested =
        Mentat_session.Decision.Requested.make ~turn:turn_id ~call
          ~stage:Mentat_tool.Stage.Direct
          (Mentat_session.Decision.Request.Question question)
      in
      Act
        ( [ Mentat_session.Event.decision_requested requested ],
          Step.Await_decision requested )

let eval_propose_plan turn_id call input =
  match
    Mentat_session.Plan.make ?title:input.plan_title ~body:input.plan_body ()
  with
  | Error e -> failure (error_result call (Mentat_session.Plan.Error.message e))
  | Ok plan ->
      let requested =
        Mentat_session.Decision.Requested.make ~turn:turn_id ~call
          ~stage:Mentat_tool.Stage.Direct
          (Mentat_session.Decision.Request.Plan plan)
      in
      Act
        ( [ Mentat_session.Event.decision_requested requested ],
          Step.Await_decision requested )

let eval_spawn env turn_id call input =
  let fail text = failure (error_result call text) in
  if env.Env.depth >= env.Env.max_spawn_depth then
    fail
      (Printf.sprintf "spawn refused: delegation depth limit %d reached"
         env.Env.max_spawn_depth)
  else
    match non_empty input.spawn_task with
    | None -> fail "spawn requires a non-empty task"
    | Some task ->
        let child =
          Mentat_session.Id.of_string
            ("sub-"
            ^ Mentat_digest.key ~length:16 ~domain:"mentat.agent.child.v1"
                [
                  Mentat_session.Turn.Id.to_string turn_id;
                  Mentat_llm.Tool.Call.id call;
                ])
        in
        let edge =
          Mentat_session.Delegation.make ~child ~source_turn:turn_id
            ~source_call:(Mentat_llm.Tool.Call.id call)
            ?description:input.spawn_description ?role:input.spawn_role
            ~task:[ Mentat_llm.Content.text task ]
            ()
        in
        Act ([], Step.Reserve_child { Step.Reservation.call; edge })

let eval_wait state turn_id call input =
  let known id =
    List.exists
      (fun edge ->
        Mentat_session.Delegation.Id.equal
          (Mentat_session.Delegation.id edge)
          id)
      (Mentat_session.State.delegations state)
  in
  if input.wait_children = [] then
    failure (error_result call "wait requires at least one child")
  else if
    List.exists (fun c -> Option.is_none (non_empty c)) input.wait_children
  then failure (error_result call "wait children must be non-empty ids")
  else
    let children =
      List.map Mentat_session.Delegation.Id.of_string input.wait_children
    in
    match List.find_opt (fun id -> not (known id)) children with
    | Some id ->
        failure
          (error_result call
             ("unknown child: " ^ Mentat_session.Delegation.Id.to_string id))
    | None ->
        Act
          ( [],
            Step.Await_children
              {
                Step.Children_wait.turn = turn_id;
                wait_call = Mentat_llm.Tool.Call.id call;
                children;
              } )

(* The receipt is honest: recording is what this commit proves; the driver
   detects the settled receipt and routes delivery to the child (idempotent on
   an id derived from the recording turn and call). The exchange cap mirrors
   the current product's per-edge law: every verb call is model-origin, so
   every recorded message counts. *)
let eval_child_message env session state call ~kind input =
  match non_empty input.msg_child with
  | None -> failure (error_result call "child must be a non-empty id")
  | Some child ->
      let id = Mentat_session.Delegation.Id.of_string child in
      let known =
        List.exists
          (fun edge ->
            Mentat_session.Delegation.Id.equal
              (Mentat_session.Delegation.id edge)
              id)
          (Mentat_session.State.delegations state)
      in
      let exchanges () =
        List.length
          (List.filter
             (fun m ->
               Mentat_session.Delegation.Id.equal m.Step.Child_message.child id)
             (settled_messages session))
      in
      if not known then failure (error_result call ("unknown child: " ^ child))
      else if Option.is_none (non_empty input.msg_message) then
        failure (error_result call "message must not be empty")
      else if exchanges () >= env.Env.max_exchanges then
        failure
          (error_result call
             (Printf.sprintf
                "message exchange limit reached for child %s (max_exchanges %d)"
                child env.Env.max_exchanges))
      else
        let label =
          match kind with `Context -> "Message" | `Follow_up -> "Follow-up"
        in
        Continue
          [
            receipt_result call
              (Printf.sprintf
                 "%s recorded for child %s; delivered at settlement." label
                 child);
          ]

let eval_verb env session state turn_id call verb =
  match (verb : Catalog.Verb.t) with
  | Catalog.Verb.Todo_write ->
      decode_verb_input todo_input_jsont call (eval_todo_write session call)
  | Catalog.Verb.Ask_user ->
      decode_verb_input ask_input_jsont call (eval_ask_user turn_id call)
  | Catalog.Verb.Propose_plan ->
      decode_verb_input plan_input_jsont call (eval_propose_plan turn_id call)
  | Catalog.Verb.Spawn ->
      decode_verb_input spawn_input_jsont call (eval_spawn env turn_id call)
  | Catalog.Verb.Wait ->
      decode_verb_input wait_input_jsont call (eval_wait state turn_id call)
  | Catalog.Verb.Send_message ->
      decode_verb_input send_message_jsont call
        (eval_child_message env session state call ~kind:`Context)
  | Catalog.Verb.Follow_up ->
      decode_verb_input follow_up_jsont call
        (eval_child_message env session state call ~kind:`Follow_up)

(* The synthetic structured-output tool.

   A schema-constrained turn's terminating answer arrives as a call to the
   contract's [output_tool]. The step validates the call's input against the
   sealed schema and, on a conforming value, settles the turn [Completed] through
   the tool-claim lifecycle: the claim carries the validated input (the answer's
   durable carrier — a projection reads it, no new journal fact), and its
   settlement lowers the model-visible success result. A non-conforming value is
   a model-visible error result naming the violations; the model retries under
   the nudge budget. *)

let structured_violation_text violations =
  String.concat "; "
    (List.map
       (fun v -> Format.asprintf "%a" Mentat_llm.Schema.Violation.pp v)
       violations)

let dispatch_structured_output state turn_id output_tool call =
  let input = Mentat_llm.Tool.Call.input call in
  match
    Mentat_llm.Schema.of_json (Mentat_llm.Tool.input_schema output_tool)
  with
  | Error _ ->
      (* The sealed schema passed the executable's load-time subset check; a
         schema that no longer parses is a sealing bug. Lower it as a
         model-visible error so the step stays total rather than raising. *)
      failure
        (error_result call
           "the sealed structured-output schema is not a supported subset")
  | Ok schema -> (
      match Mentat_llm.Schema.validate schema input with
      | Error violations ->
          failure
            (error_result call
               ("the structured_output value does not conform to its schema: "
               ^ structured_violation_text violations))
      | Ok () ->
          let claim =
            Mentat_session.Tool_claim.Started.make ~turn:turn_id
              ~stage:Mentat_tool.Stage.Direct ~call ~input ~requests:[]
          in
          let id = Mentat_session.Tool_claim.Started.id claim in
          let output =
            Mentat_tool.Output.make ~text:"Structured answer recorded."
              ~json:input ()
          in
          let settled =
            Mentat_session.Tool_claim.Settled.returned ~id
              (Mentat_tool.Result.completed ~output ())
          in
          let outcome = Mentat_session.Turn.Outcome.completed in
          (* Any other calls the model bundled with [structured_output] cannot
             run once the answer settles the turn; reconcile them so the terminal
             fact sees a request-ready transcript. *)
          let others =
            List.filter
              (fun c ->
                not
                  (String.equal
                     (Mentat_llm.Tool.Call.id c)
                     (Mentat_llm.Tool.Call.id call)))
              (Mentat_llm.Transcript.pending
                 (Mentat_session.State.model_transcript state))
          in
          let reconcile =
            List.map
              (fun c ->
                error_result c "turn completed with the structured answer")
              others
          in
          Act
            ( Mentat_session.Event.tool_claimed claim
              :: Mentat_session.Event.tool_settled settled
              :: reconcile
              @ [ Mentat_session.Event.turn_finished ~turn:turn_id outcome ],
              Step.Settled { turn = turn_id; outcome } ))

let dispatch env session state turn_id turn call =
  let contract = Mentat_session.Turn.contract turn in
  let name = Mentat_llm.Tool.Call.name call in
  match Mentat_session.Contract.output_tool contract with
  | Some output_tool when String.equal (Mentat_llm.Tool.name output_tool) name
    ->
      dispatch_structured_output state turn_id output_tool call
  | Some _ | None -> (
      match target_for env contract name with
      | Error drift -> failure (error_result call drift)
      | Ok (`Verb verb) -> eval_verb env session state turn_id call verb
      | Ok (`Executable tool) -> (
          match check_sandbox env contract with
          | Error drift -> failure (error_result call drift)
          | Ok () -> dispatch_executable env state contract turn_id call tool))

(* The model boundary. *)

let compaction_summary_prompt = Mentat_prompts.Compaction.summary
let cache_key session = Mentat_session.Id.to_string (Mentat_session.id session)

(* The summarizer prelude replaces the agent's for a summary request: a
   summarizer that inherits the acting persona and reads a conversation ending
   on a question may answer it instead of summarizing. A system message always
   satisfies the prelude invariant, so construction cannot fail; the empty
   fallback names that invariant without a partial pattern. *)
let summary_prelude =
  match
    Mentat_llm.Request.Prelude.make
      [ Mentat_llm.Message.system Mentat_prompts.Compaction.system ]
  with
  | Ok prelude -> prelude
  | Error _ -> Mentat_llm.Request.Prelude.empty

(* The context reading behind the pressure checks: the latest provider-reported
   usage plus a byte-derived estimate — about four bytes per token — of the
   messages that usage does not yet cover, or the estimate of the whole model
   view when no response reported usage. A provider that never reports usage
   still gets a reading, so pressure compaction is never starved. Media sources
   are not counted. The reading is a trigger, never an accounting fact:
   installed compactions record provider-reported usage only. *)
let estimated_tokens messages =
  let option_length acc text =
    match text with Some text -> acc + String.length text | None -> acc
  in
  let contents acc parts =
    List.fold_left
      (fun acc content ->
        match (content : Mentat_llm.Content.t) with
        | Mentat_llm.Content.Text text -> acc + String.length text
        | Mentat_llm.Content.Media _ -> acc)
      acc parts
  in
  let part acc part =
    match (part : Mentat_llm.Message.Assistant.part) with
    | Mentat_llm.Message.Assistant.Text text -> acc + String.length text
    | Mentat_llm.Message.Assistant.Tool_call call ->
        acc
        + String.length
            (Format.asprintf "%a" Jsont.Json.pp (Mentat_llm.Tool.Call.input call))
    | Mentat_llm.Message.Assistant.Reasoning reasoning ->
        List.fold_left option_length acc
          [
            Mentat_llm.Message.Assistant.Reasoning.summary reasoning;
            Mentat_llm.Message.Assistant.Reasoning.text reasoning;
            Mentat_llm.Message.Assistant.Reasoning.encrypted reasoning;
          ]
  in
  let message acc m =
    match (m : Mentat_llm.Message.t) with
    | Mentat_llm.Message.System text | Mentat_llm.Message.Developer text ->
        acc + String.length text
    | Mentat_llm.Message.User parts -> contents acc parts
    | Mentat_llm.Message.Assistant assistant ->
        List.fold_left part acc (Mentat_llm.Message.Assistant.parts assistant)
    | Mentat_llm.Message.Tool_result result ->
        contents acc (Mentat_llm.Tool.Result.content result)
  in
  List.fold_left message 0 messages / 4

let context_tokens state =
  match Mentat_session.State.replay_usage state with
  | Some (usage, uncovered) ->
      Mentat_llm.Usage.input_total usage
      + Mentat_llm.Usage.output_total usage
      + estimated_tokens uncovered
  | None ->
      estimated_tokens
        (Mentat_llm.Transcript.messages
           (Mentat_session.State.model_transcript state))

(* The summary boundary. A summary need not replace the whole transcript:
   recent turns stay verbatim behind it, so exact recent tool output and error
   text survive the boundary while the summary reclaims the bulk of the
   window. The cut is the earliest turn start — a [User] message — whose
   suffix fits the tail budget, a tenth of the pressure threshold: enough for
   the last few exchanges, small enough that compaction still reclaims nearly
   everything. The cut always advances strictly past the previous summary
   boundary, so a fresh summary always covers something new; when no turn
   start both fits and advances — the recent turns alone exceed the budget,
   or automatic compaction is disabled — the summary replaces the whole
   transcript, and the walk never runs past the budget it can spend. *)
let summary_cut env state =
  let full = Mentat_session.State.full_transcript state in
  let full_length = Mentat_llm.Transcript.length full in
  let budget =
    match env.Env.compaction_pressure_tokens with
    | None -> 0
    | Some threshold -> threshold / 10
  in
  if budget = 0 then full_length
  else
    let floor =
      match Mentat_session.State.latest_compaction state with
      | Some compaction -> Mentat_session.Compaction.summarized_upto compaction
      | None -> 0
    in
    let messages = Array.of_list (Mentat_llm.Transcript.messages full) in
    let rec walk i tokens cut =
      if i <= floor then cut
      else
        let tokens = tokens + estimated_tokens [ messages.(i) ] in
        if tokens > budget then cut
        else
          let cut =
            match messages.(i) with
            | Mentat_llm.Message.User _ -> i
            | _ -> cut
          in
          walk (i - 1) tokens cut
    in
    walk (full_length - 1) 0 full_length

(* The one summary request: the model view up to the summary cut, under the
   summarizer prelude, followed by the summary prompt — shared by the pressure
   trigger, the manual flow, and the overflow recovery below. The verbatim
   tail beyond the cut is excluded: it survives the boundary as-is, and
   summarizing it too would duplicate it in the reduced view. The defensive
   fallbacks keep [Request.make] the single error surface. *)
let summary_request env session state contract =
  let view = Mentat_session.State.model_transcript state in
  let cut = summary_cut env state in
  let tail_length =
    Mentat_llm.Transcript.length (Mentat_session.State.full_transcript state)
    - cut
  in
  (* The view may carry the open pending-notices entry at its tail; it is
     not-yet-history and the compaction claim's own freeze pins it after
     [cut], so the head arithmetic excludes it — summarizing it would cover
     an entry the reduced view goes on to retain. *)
  let riding = Mentat_session.State.pending_entries_riding state in
  let head =
    let messages = Mentat_llm.Transcript.messages view in
    let head_length = List.length messages - riding - tail_length in
    if (tail_length = 0 && riding = 0) || head_length <= 0 then view
    else
      match Mentat_llm.Transcript.of_list (List.take head_length messages) with
      | Ok head -> head
      | Error _ -> view
  in
  let transcript =
    match
      Mentat_llm.Transcript.add
        (Mentat_llm.Message.user_text compaction_summary_prompt)
        head
    with
    | Ok transcript -> transcript
    | Error _ -> head
  in
  Result.map
    (fun request -> (request, cut))
    (Mentat_llm.Request.make
       ~model:(Mentat_session.Contract.model contract)
       ~prelude:summary_prelude ~cache_key:(cache_key session) transcript)

(* Nothing to summarize: the model view is empty, or a prior summary already
   covers the whole transcript and a fresh one would only summarize the
   summary. Guards both the manual admission and the pressure trigger — the
   trigger would otherwise loop on a reading a fresh summary cannot lower.
   {!summary_cut} otherwise advances strictly, so a summary that installs
   always covers new messages. *)
let nothing_to_compact state =
  Mentat_llm.Transcript.length (Mentat_session.State.model_transcript state) = 0
  ||
  match Mentat_session.State.latest_compaction state with
  | Some compaction ->
      Mentat_session.Compaction.summarized_upto compaction
      >= Mentat_llm.Transcript.length
           (Mentat_session.State.full_transcript state)
  | None -> false

let compaction_request env session state contract =
  match env.Env.compaction_pressure_tokens with
  | None -> None
  | Some threshold -> (
      if context_tokens state < threshold || nothing_to_compact state then None
      else
        match summary_request env session state contract with
        | Ok (request, cut) ->
            Some
              (request, Mentat_session.Compaction.Reason.Context_pressure, cut)
        | Error _ -> None)

(* Context overflow recovery.

   A model request that fails with [Context_overflow] triggers a single
   compaction within the turn, then one retry: the failed claim settles Failed
   but the turn stays active ([settle_provider_overflow]), the next model
   boundary emits a [Context_overflow] compaction, and the retry re-issues over
   the reduced view. The bound is PER-TURN: at most one overflow compaction, so a
   second overflow finishes the turn Failed. Both facts are replay folds over the
   active turn's events — no new durable state. *)

let active_turn_events session turn_id =
  let rec after = function
    | [] -> []
    | Mentat_session.Event.Turn_started turn :: rest
      when Mentat_session.Turn.Id.equal (Mentat_session.Turn.id turn) turn_id ->
        rest
    | _ :: rest -> after rest
  in
  after (Mentat_session.events session)

let compacted_this_turn session turn_id =
  List.exists
    (function
      | Mentat_session.Event.Compaction_installed _ -> true | _ -> false)
    (active_turn_events session turn_id)

let overflow_compacted_this_turn session turn_id =
  List.exists
    (function
      | Mentat_session.Event.Compaction_installed compaction ->
          Mentat_session.Compaction.Reason.equal
            (Mentat_session.Compaction.reason compaction)
            Mentat_session.Compaction.Reason.Context_overflow
      | _ -> false)
    (active_turn_events session turn_id)

(* Structured-output nudge budget.

   A schema-constrained turn that does not deliver a conforming answer is bounded
   by a replay fold over the active turn's events — the [overflow_compacted]
   pattern, no new durable state. Two nudge kinds count: an assistant response
   carrying no tool calls (a reminder is injected, [accept_response]) and a
   [structured_output] call whose result was an error (a non-conforming value,
   [dispatch_structured_output]). At [output_budget] nudges the next model
   boundary settles the turn [Failed]. *)

let output_budget = 3

let structured_output_not_produced_message =
  "the model did not produce a valid structured_output answer within the retry \
   budget"

let output_nudges output_name session turn_id =
  List.fold_left
    (fun count event ->
      match (event : Mentat_session.Event.t) with
      | Mentat_session.Event.Provider_settled settled -> (
          match Mentat_session.Provider_request.Settled.outcome settled with
          | Mentat_session.Provider_request.Settled.Responded response
            when not (Mentat_llm.Response.has_tool_calls response) ->
              count + 1
          | Mentat_session.Provider_request.Settled.Responded _
          | Mentat_session.Provider_request.Settled.Interrupted _
          | Mentat_session.Provider_request.Settled.Failed _
          | Mentat_session.Provider_request.Settled.Ambiguous ->
              count)
      | Mentat_session.Event.Message_appended
          (Mentat_llm.Message.Tool_result result)
        when String.equal (Mentat_llm.Tool.Result.name result) output_name
             && Mentat_llm.Tool.Result.is_error result ->
          count + 1
      | _ -> count)
    0
    (active_turn_events session turn_id)

let last_provider_failure_is_overflow session turn_id =
  List.fold_left
    (fun overflow event ->
      match event with
      | Mentat_session.Event.Provider_settled settled -> (
          match Mentat_session.Provider_request.Settled.outcome settled with
          | Mentat_session.Provider_request.Settled.Failed error -> (
              match Mentat_llm.Error.kind error with
              | Mentat_llm.Error.Context_overflow -> true
              | _ -> false)
          | _ -> false)
      | _ -> overflow)
    false
    (active_turn_events session turn_id)

(* The request prelude is the durable context [env] holds plus, for a
   schema-constrained turn, the structured-output delivery instruction —
   stable content only, so the conversation head never moves between
   requests and the provider prefix cache survives the session. Everything
   time-varying the model must see — workspace notices, the whiff
   reminder — is an ordinary entry in the durable transcript, projected by
   {!Mentat_session.State} at its event position. *)
let request_prelude env contract =
  match Mentat_session.Contract.output_tool contract with
  | None -> env.Env.prelude
  | Some _ -> (
      match
        Mentat_llm.Request.Prelude.append env.Env.prelude
          [
            Mentat_llm.Message.system
              Mentat_prompts.Tools.structured_output_instruction;
          ]
      with
      | Ok prelude -> prelude
      | Error _ -> env.Env.prelude)

let model_boundary env session state turn_id turn =
  let contract = Mentat_session.Turn.contract turn in
  let count =
    Option.value
      (Mentat_session.State.turn_response_count turn_id state)
      ~default:0
  in
  let limit = min (Mentat_session.Turn.max_steps turn) env.Env.max_steps in
  let compaction_effect request reason cut =
    let claim =
      Mentat_session.Provider_request.Started.make ~turn:turn_id
        ~request_digest:(Mentat_llm.Request.digest request)
    in
    Act
      ( [ Mentat_session.Event.provider_requested claim ],
        Step.Perform
          (Step.Effect.Model
             { claim; request; purpose = `Compaction (reason, cut) }) )
  in
  if count >= limit then
    let outcome = Mentat_session.Turn.Outcome.step_limit in
    Ok
      (Act
         ( [ Mentat_session.Event.turn_finished ~turn:turn_id outcome ],
           Step.Settled { turn = turn_id; outcome } ))
  else if
    last_provider_failure_is_overflow session turn_id
    && not (overflow_compacted_this_turn session turn_id)
  then
    (* The turn's model request overflowed and the turn has not yet spent its one
       overflow compaction: compact ([Context_overflow]) before re-issuing. *)
    match summary_request env session state contract with
    | Ok (request, cut) ->
        Ok
          (compaction_effect request
             Mentat_session.Compaction.Reason.Context_overflow cut)
    | Error e ->
        (* The model view cannot become a summary request — the same terminal
           error the ordinary request boundary raises; recovery cannot loop. *)
        Error (Error.Request e)
  else
    match compaction_request env session state contract with
    | Some (request, reason, cut) -> Ok (compaction_effect request reason cut)
    | None -> (
        match Mentat_session.Contract.output_tool contract with
        | Some output_tool
          when output_nudges (Mentat_llm.Tool.name output_tool) session turn_id
               >= output_budget ->
            (* Schema active and the nudge budget is spent: the turn never
               delivered a conforming structured answer. Settle Failed; no
               provider failure preceded this settlement, so the executable
               surfaces it as the distinct structured-output failure. *)
            let outcome =
              Mentat_session.Turn.Outcome.failed
                ~message:structured_output_not_produced_message
            in
            Ok
              (Act
                 ( [ Mentat_session.Event.turn_finished ~turn:turn_id outcome ],
                   Step.Settled { turn = turn_id; outcome } ))
        | maybe_output_tool -> (
            let declarations = Mentat_session.Contract.declarations contract in
            let tools =
              match maybe_output_tool with
              | None -> declarations
              | Some output_tool -> declarations @ [ output_tool ]
            in
            let request =
              Mentat_llm.Request.make
                ~model:(Mentat_session.Contract.model contract)
                ~prelude:(request_prelude env contract)
                ~tools
                ~options:(Mentat_session.Contract.options contract)
                ~cache_key:(cache_key session)
                (Mentat_session.State.model_transcript state)
            in
            match request with
            | Error e -> Error (Error.Request e)
            | Ok request ->
                let claim =
                  Mentat_session.Provider_request.Started.make ~turn:turn_id
                    ~request_digest:(Mentat_llm.Request.digest request)
                in
                Ok
                  (Act
                     ( [ Mentat_session.Event.provider_requested claim ],
                       Step.Perform
                         (Step.Effect.Model { claim; request; purpose = `Turn })
                     ))))

(* Termination.

   Answers every unanswered assistant tool call, then finishes the turn: an
   interrupted or failed turn may leave calls unanswered, and each must carry a
   result or the terminal event is rejected for a non-request-ready model
   transcript. *)

let reconcile_pending state ~text =
  List.map
    (fun call -> error_result call text)
    (Mentat_llm.Transcript.pending
       (Mentat_session.State.model_transcript state))

let terminate_transition state turn_id ~outcome ~text =
  let results = reconcile_pending state ~text in
  Act
    ( results @ [ Mentat_session.Event.turn_finished ~turn:turn_id outcome ],
      Step.Settled { turn = turn_id; outcome } )

(* The plan loop. *)

let plan env session =
  let state = Mentat_session.state session in
  match Mentat_session.State.active_turn state with
  | None -> Ok (Act ([], Step.Idle))
  | Some turn -> (
      let turn_id = Mentat_session.Turn.id turn in
      match Mentat_session.State.suspension state with
      | Some (Mentat_session.State.Decision requested) ->
          Ok (Act ([], Step.Await_decision requested))
      | Some (Mentat_session.State.Provider _ | Mentat_session.State.Tool _) ->
          (* An in-flight claim is never re-performed: that head belongs to
             the feed-backs or to [recover]. *)
          Error
            (Error.Session
               (Mentat_session.Error.State
                  (Mentat_session.State.Error.Turn
                     (Mentat_session.State.Error.Turn.Open_suspension turn_id))))
      | None -> (
          if Mentat_session.State.interrupt_requested state then
            Ok
              (terminate_transition state turn_id
                 ~outcome:
                   (Mentat_session.Turn.Outcome.interrupted ~cancelled:true ())
                 ~text:"interrupted")
          else
            match
              Mentat_llm.Transcript.state
                (Mentat_session.State.model_transcript state)
            with
            | Mentat_llm.Transcript.Ready ->
                model_boundary env session state turn_id turn
            | Mentat_llm.Transcript.Awaiting_tool_results (call, _) ->
                Ok (dispatch env session state turn_id turn call)))

let rec drive env session emitted events =
  match Mentat_session.append_all events session with
  | Error e -> Error (Error.Session e)
  | Ok session -> (
      let emitted = List.rev_append events emitted in
      match plan env session with
      | Error _ as e -> e
      | Ok (Continue events) -> drive env session emitted events
      | Ok (Act (events, action)) -> (
          match Mentat_session.append_all events session with
          | Error e -> Error (Error.Session e)
          | Ok _ -> Ok { Step.events = List.rev_append emitted events; action })
      )

let normalize env session events = drive env session [] events

(* Append [events] and return the step without re-planning — for boundaries
   whose action carries a claim already inside [events]. *)
let act session events action =
  match Mentat_session.append_all events session with
  | Error e -> Error (Error.Session e)
  | Ok _ -> Ok { Step.events; action }

(* Settle-and-finish in one suffix: the settlement events, then reconciliation
   results for every remaining unanswered call, then the terminal fact. *)
let finish_with session ~turn_id ~settle ~outcome ~text =
  match Mentat_session.append_all settle session with
  | Error e -> Error (Error.Session e)
  | Ok scratch -> (
      let results = reconcile_pending (Mentat_session.state scratch) ~text in
      let tail =
        results @ [ Mentat_session.Event.turn_finished ~turn:turn_id outcome ]
      in
      match Mentat_session.append_all tail scratch with
      | Error e -> Error (Error.Session e)
      | Ok _ ->
          Ok
            {
              Step.events = settle @ tail;
              action = Step.Settled { turn = turn_id; outcome };
            })

(* Entry points. *)

let start ?(notices = []) env contract ~id ~input ~origin session =
  let turn =
    Mentat_session.Turn.make ~id ~origin ~input ~max_steps:env.Env.max_steps
      ~contract ()
  in
  normalize env session
    (Mentat_session.Event.turn_started turn
    :: List.map Mentat_session.Event.workspace_notice notices)

(* Manual compaction. *)

type compaction_start = Nothing_to_compact | Compact_step of Step.t

(* The manual boundary mark: a compaction-only turn. Unlike the automatic path —
   a [`Compaction] prelude inside the requesting turn keyed on pressure — a
   manual compaction admits its own [Origin.Compaction] turn whose single body is
   one billable summary claim. The response feeds the same {!install_summary},
   which settles this turn once the fact installs. Nothing about the automatic
   path changes. *)
let compact env contract ~id session =
  let state = Mentat_session.state session in
  match Mentat_session.State.active_turn state with
  | Some active ->
      (* Manual compaction requires an idle head; the driver guards this, so
         this is a defensive backstop that names the honest condition. *)
      Error
        (Error.Session
           (Mentat_session.Error.State
              (Mentat_session.State.Error.Turn
                 (Mentat_session.State.Error.Turn.Active
                    (Mentat_session.Turn.id active)))))
  | None -> (
      if nothing_to_compact state then Ok Nothing_to_compact
      else
        let turn =
          Mentat_session.Turn.make ~id
            ~origin:Mentat_session.Turn.Origin.Compaction
            ~input:Mentat_session.Turn.Input.continue
            ~max_steps:env.Env.max_steps ~contract ()
        in
        match summary_request env session state contract with
        | Error e -> Error (Error.Request e)
        | Ok (request, cut) ->
            let claim =
              Mentat_session.Provider_request.Started.make ~turn:id
                ~request_digest:(Mentat_llm.Request.digest request)
            in
            Result.map
              (fun step -> Compact_step step)
              (act session
                 [
                   Mentat_session.Event.turn_started turn;
                   Mentat_session.Event.provider_requested claim;
                 ]
                 (Step.Perform
                    (Step.Effect.Model
                       {
                         claim;
                         request;
                         purpose =
                           `Compaction
                             ( Mentat_session.Compaction.Reason.User_requested,
                               cut );
                       }))))

(* Typed feed-backs. *)

(* A response cut at the output limit while the context reading meets the
   pressure threshold is the window showing, not a finished answer: the turn
   stays active so the next request boundary compacts under pressure and
   re-issues over the reduced view. Below the threshold, or with automatic
   compaction disabled, a length stop is an ordinary completion at the model's
   output cap. *)
let truncated_at_pressure env response state =
  match env.Env.compaction_pressure_tokens with
  | None -> false
  | Some threshold -> (
      match Mentat_llm.Response.stop response with
      | Some Mentat_llm.Response.Stop.Length ->
          let reading =
            match Mentat_llm.Response.usage response with
            | Some usage ->
                Mentat_llm.Usage.input_total usage
                + Mentat_llm.Usage.output_total usage
            | None -> context_tokens state
          in
          reading >= threshold
      | Some _ | None -> false)

let accept_response env id response session =
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  let settle =
    Mentat_session.Event.provider_settled
      (Mentat_session.Provider_request.Settled.responded ~id response)
  in
  let state = Mentat_session.state session in
  if
    Mentat_llm.Response.has_tool_calls response
    || Mentat_session.State.interrupt_requested state
  then normalize env session [ settle ]
  else
    match
      Mentat_session.Contract.output_tool (Mentat_session.Turn.contract turn)
    with
    | Some _ ->
        (* Schema active but the model finished without delivering the answer.
           Record the response and re-plan without finishing: the next model
           boundary re-issues over the grown transcript (a distinct request) with
           the reminder escalated into its prelude, or settles Failed once the
           nudge budget is spent. A mid-turn transcript reminder is not an option
           — the session admits injected user messages only at turn boundaries —
           so the reminder rides the prelude, the sanctioned host channel. *)
        normalize env session [ settle ]
    | None
      when truncated_at_pressure env response state
           && not (compacted_this_turn session turn_id) ->
        (* One recovery per turn: a repeat length stop after a compaction
           completes the turn with what the model produced. *)
        normalize env session [ settle ]
    | None ->
        let outcome = Mentat_session.Turn.Outcome.completed in
        act session
          [ settle; Mentat_session.Event.turn_finished ~turn:turn_id outcome ]
          (Step.Settled { turn = turn_id; outcome })

let install_summary env id ~summary ~reason ~summarized_upto ?usage session =
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  let state = Mentat_session.state session in
  match Mentat_session.State.suspension state with
  | Some (Mentat_session.State.Provider started)
    when Mentat_session.Provider_request.Id.equal
           (Mentat_session.Provider_request.Started.id started)
           id -> (
      let context =
        Option.map
          (fun (usage, _uncovered) ->
            Mentat_session.Compaction.Context_tokens.make
              ~before:
                (Mentat_llm.Usage.input_total usage
                + Mentat_llm.Usage.output_total usage)
              ())
          (Mentat_session.State.replay_usage state)
      in
      (* The summary re-enters the next request as the model-view prefix. With
         a verbatim tail the live conversation follows it directly; with none,
         the resume notice trails the summary so the reduced view ends on a
         user message that prompts continuation rather than acknowledgement.
         The cut is the one decided when the summary request was built — the
         claim's own freeze may have grown [full] since (the pending batch
         pins after the cut and survives in the tail), so recomputing here
         could summarize away what the summarizer never saw. *)
      ignore env;
      let tail_retained =
        summarized_upto
        < Mentat_llm.Transcript.length
            (Mentat_session.State.full_transcript state)
      in
      let summary_messages =
        if tail_retained then summary
        else
          summary
          @ [ Mentat_llm.Message.user_text Mentat_prompts.Compaction.resume ]
      in
      let compaction =
        Mentat_session.Compaction.make ~reason ~provider_claim:id
          ~request_digest:
            (Mentat_session.Provider_request.Started.request_digest started)
          ~summary_messages ~summarized_upto ?usage ?context ()
      in
      let installed = Mentat_session.Event.compaction_installed compaction in
      match Mentat_session.Turn.origin turn with
      | Mentat_session.Turn.Origin.Compaction ->
          (* A manual compaction turn is complete once its summary installs: the
             one summary call is its whole body. Install and settle in one
             suffix; the auto path instead continues the requesting turn on the
             reduced model view. *)
          let outcome = Mentat_session.Turn.Outcome.completed in
          act session
            [
              installed;
              Mentat_session.Event.turn_finished ~turn:turn_id outcome;
            ]
            (Step.Settled { turn = turn_id; outcome })
      | Mentat_session.Turn.Origin.User
      | Mentat_session.Turn.Origin.Queued _
      | Mentat_session.Turn.Origin.Triggered _
      | Mentat_session.Turn.Origin.Plan_build
      | Mentat_session.Turn.Origin.Step_limit_wind_down ->
          normalize env session [ installed ])
  | Some _ | None ->
      Error
        (Error.Session
           (Mentat_session.Error.State
              (Mentat_session.State.Error.Provider
                 (Mentat_session.State.Error.Provider.Not_pending id))))

let provider_failure_message error =
  let message = Mentat_llm.Error.message error in
  match Mentat_llm.Error.kind error with
  (* The generic provider kind adds no qualifier; naming it would read "provider
     provider failure". Every other kind narrows the failure ("provider auth
     failure", "provider transport failure"). *)
  | Mentat_llm.Error.Provider -> Printf.sprintf "provider failure: %s" message
  | kind ->
      Printf.sprintf "provider %s failure: %s"
        (Mentat_llm.Error.label kind)
        message

let provider_failed_settle id error =
  [
    Mentat_session.Event.provider_settled
      (Mentat_session.Provider_request.Settled.failed ~id error);
  ]

let settle_provider_failed id error session =
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  let message = provider_failure_message error in
  finish_with session ~turn_id
    ~settle:(provider_failed_settle id error)
    ~outcome:(Mentat_session.Turn.Outcome.failed ~message)
    ~text:message

let settle_provider_overflow env id error session =
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  if overflow_compacted_this_turn session turn_id then
    (* The turn already spent its one Context_overflow compaction and the retry
       overflowed again: settle the claim Failed and finish the turn carrying the
       provider error — the per-turn bound. *)
    let message = provider_failure_message error in
    finish_with session ~turn_id
      ~settle:(provider_failed_settle id error)
      ~outcome:(Mentat_session.Turn.Outcome.failed ~message)
      ~text:message
  else
    (* First overflow this turn: settle the claim Failed but keep the turn active.
       A [Failed] settlement clears the suspension and appends nothing, so the
       transcript stays request-ready; the next model boundary compacts
       ([Context_overflow]) and re-issues the request once over the reduced
       view. *)
    normalize env session (provider_failed_settle id error)

let settle_provider_ambiguous id session =
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  let settle =
    [
      Mentat_session.Event.provider_settled
        (Mentat_session.Provider_request.Settled.ambiguous ~id);
    ]
  in
  let outcome =
    Mentat_session.Turn.Outcome.interrupted ~reason:"provider outcome unknown"
      ~cancelled:false ()
  in
  finish_with session ~turn_id ~settle ~outcome ~text:"provider outcome unknown"

let resume_run env contract turn_id call prepared =
  let name = Mentat_tool.Prepared.tool prepared in
  let* tool = executable_for env contract name in
  match Mentat_tool.Call.decode tool call with
  | Error e -> Error (Mentat_tool.Call.Decode_error.message e)
  | Ok fresh -> (
      match Mentat_tool.Call.resume fresh prepared with
      | Error e -> Error (Mentat_tool.Call.Resume_error.message e)
      | Ok run_call ->
          let claim =
            Mentat_session.Tool_claim.Started.make ~turn:turn_id
              ~stage:Mentat_tool.Stage.Run
              ~call:(Mentat_tool.Call.source run_call)
              ~input:(Mentat_tool.Call.input run_call)
              ~requests:(Mentat_tool.Prepared.requests prepared)
          in
          Ok
            ( Mentat_session.Event.tool_claimed claim,
              Step.Effect.Tool { claim; call = run_call } ))

let settle_tool env id outcome session =
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  let state = Mentat_session.state session in
  match Mentat_session.State.suspension state with
  | Some (Mentat_session.State.Tool started)
    when Mentat_session.Tool_claim.Id.equal
           (Mentat_session.Tool_claim.Started.id started)
           id -> (
      match (outcome : Mentat_tool.Call.outcome) with
      | Mentat_tool.Call.Finished result ->
          normalize env session
            [
              Mentat_session.Event.tool_settled
                (Mentat_session.Tool_claim.Settled.returned ~id result);
            ]
      | Mentat_tool.Call.Prepared prepared -> (
          let settle =
            Mentat_session.Event.tool_settled
              (Mentat_session.Tool_claim.Settled.prepared ~id prepared)
          in
          let source = Mentat_session.Tool_claim.Started.call started in
          let call_id = Mentat_llm.Tool.Call.id source in
          match pending_call state call_id with
          | None ->
              Error
                (Error.Call_not_pending
                   { call_id; name = Mentat_llm.Tool.Call.name source })
          | Some call -> (
              let contract = Mentat_session.Turn.contract turn in
              match
                review_requests state contract
                  (Mentat_tool.Prepared.requests prepared)
              with
              | `Denied denial ->
                  normalize env session
                    [
                      settle; error_result call (env.Env.denial_message denial);
                    ]
              | `Review review ->
                  let requested =
                    Mentat_session.Decision.Requested.make ~turn:turn_id ~call
                      ~stage:Mentat_tool.Stage.Run
                      (Mentat_session.Decision.Request.Permission review)
                  in
                  normalize env session
                    [
                      settle; Mentat_session.Event.decision_requested requested;
                    ]
              | `Allowed -> (
                  match resume_run env contract turn_id call prepared with
                  | Ok (claim_event, eff) ->
                      act session [ settle; claim_event ] (Step.Perform eff)
                  | Error drift ->
                      normalize env session [ settle; error_result call drift ])
              )))
  | Some _ | None ->
      let known =
        List.exists
          (fun (started, _) ->
            Mentat_session.Tool_claim.Id.equal
              (Mentat_session.Tool_claim.Started.id started)
              id)
          (Mentat_session.State.tool_claims state)
      in
      let error =
        if known then Mentat_session.State.Error.Tool_claim.Not_pending id
        else Mentat_session.State.Error.Tool_claim.Unknown id
      in
      Error
        (Error.Session
           (Mentat_session.Error.State
              (Mentat_session.State.Error.Tool_claim error)))

let settle_tool_ambiguous env id session =
  let* _turn = active_turn session in
  normalize env session
    [
      Mentat_session.Event.tool_settled
        (Mentat_session.Tool_claim.Settled.ambiguous ~id);
    ]

let prepared_payload state turn_id call_id =
  List.find_map
    (fun (started, settled) ->
      if
        Mentat_session.Turn.Id.equal
          (Mentat_session.Tool_claim.Started.turn started)
          turn_id
        && String.equal
             (Mentat_llm.Tool.Call.id
                (Mentat_session.Tool_claim.Started.call started))
             call_id
        && Mentat_tool.Stage.equal
             (Mentat_session.Tool_claim.Started.stage started)
             Mentat_tool.Stage.Prepare
      then
        Option.bind settled (fun settled ->
            match Mentat_session.Tool_claim.Settled.outcome settled with
            | Mentat_session.Tool_claim.Settled.Prepared prepared ->
                Some prepared
            | Mentat_session.Tool_claim.Settled.Returned _
            | Mentat_session.Tool_claim.Settled.Ambiguous ->
                None)
      else None)
    (Mentat_session.State.tool_claims state)

let proceed_permission env session state turn turn_id requested call resolved =
  let contract = Mentat_session.Turn.contract turn in
  match Mentat_session.Decision.Requested.stage requested with
  | Mentat_tool.Stage.Run -> (
      match
        prepared_payload state turn_id
          (Mentat_session.Decision.Requested.call_id requested)
      with
      | None ->
          normalize env session
            [
              resolved;
              error_result call "staged plan is missing; cannot resume";
            ]
      | Some prepared -> (
          match resume_run env contract turn_id call prepared with
          | Ok (claim_event, eff) ->
              act session [ resolved; claim_event ] (Step.Perform eff)
          | Error drift ->
              normalize env session [ resolved; error_result call drift ]))
  | Mentat_tool.Stage.Direct | Mentat_tool.Stage.Prepare -> (
      let name = Mentat_llm.Tool.Call.name call in
      match executable_for env contract name with
      | Error drift ->
          normalize env session [ resolved; error_result call drift ]
      | Ok tool -> (
          match Mentat_tool.Call.decode tool call with
          | Error e ->
              normalize env session
                [
                  resolved;
                  error_result call (Mentat_tool.Call.Decode_error.message e);
                ]
          | Ok tool_call -> (
              match claim_and_perform turn_id tool_call with
              | Act (events, action) -> act session (resolved :: events) action
              | Continue _ -> assert false)))

let resolve_decision env id ~answered_by answer session =
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  let state = Mentat_session.state session in
  match Mentat_session.State.suspension state with
  | Some (Mentat_session.State.Decision requested)
    when Mentat_session.Decision.Id.equal
           (Mentat_session.Decision.Requested.id requested)
           id -> (
      let call_id = Mentat_session.Decision.Requested.call_id requested in
      match pending_call state call_id with
      | None ->
          Error
            (Error.Call_not_pending
               {
                 call_id;
                 name = Mentat_session.Decision.Requested.name requested;
               })
      | Some call -> (
          match
            Mentat_session.Decision.resolve requested ~call ~by:answered_by
              answer
          with
          | Error e -> Error (Error.Decision e)
          | Ok (resolution, handling) -> (
              let resolved =
                Mentat_session.Event.decision_resolved resolution
              in
              match handling with
              | Mentat_session.Decision.Consume _ ->
                  normalize env session [ resolved ]
              | Mentat_session.Decision.Proceed_permission ->
                  proceed_permission env session state turn turn_id requested
                    call resolved
              | Mentat_session.Decision.Proceed_plan _ ->
                  let outcome = Mentat_session.Turn.Outcome.completed in
                  act session
                    [
                      resolved;
                      Mentat_session.Event.turn_finished ~turn:turn_id outcome;
                    ]
                    (Step.Settled { turn = turn_id; outcome }))))
  | Some _ | None ->
      let error =
        match Mentat_session.State.decision id state with
        | Some _ -> Mentat_session.State.Error.Decision.Not_pending id
        | None -> Mentat_session.State.Error.Decision.Unknown id
      in
      Error
        (Error.Session
           (Mentat_session.Error.State
              (Mentat_session.State.Error.Decision error)))

let reserve_result env reservation answer session =
  let* _turn = active_turn session in
  let state = Mentat_session.state session in
  let call = reservation.Step.Reservation.call in
  let call_id = Mentat_llm.Tool.Call.id call in
  match pending_call state call_id with
  | None ->
      Error
        (Error.Call_not_pending
           { call_id; name = Mentat_llm.Tool.Call.name call })
  | Some _ -> (
      match answer with
      | `Granted ->
          let edge = reservation.Step.Reservation.edge in
          (* The delegation id is the addressable handle: [wait],
             [send_message], and [follow_up] all decode their child argument as
             a delegation id (the child id [H(source_turn, source_call)]). The
             receipt leads with it so the model can address the child it just
             spawned; the session id follows for the threads surface, which keys
             child scopes by session. *)
          normalize env session
            [
              Mentat_session.Event.delegation_recorded edge;
              receipt_result call
                (Printf.sprintf "Spawned child %s (session %s)."
                   (Mentat_session.Delegation.Id.to_string
                      (Mentat_session.Delegation.id edge))
                   (Mentat_session.Id.to_string
                      (Mentat_session.Delegation.child edge)));
            ]
      | `Refused (Step.Reservation.Refusal.Capacity { limit }) ->
          normalize env session
            [
              error_result call
                (Printf.sprintf
                   "spawn refused: subagent capacity limit %d reached" limit);
            ])

let deliver_child env ~wait ~settled session =
  let* _turn = active_turn session in
  let state = Mentat_session.state session in
  let pending =
    Mentat_llm.Transcript.pending (Mentat_session.State.model_transcript state)
  in
  match
    List.find_opt
      (fun call ->
        String.equal
          (Mentat_llm.Tool.Call.id call)
          wait.Step.Children_wait.wait_call)
      pending
  with
  | None -> Error Error.No_pending_wait
  | Some call ->
      let find id =
        List.find_opt
          (fun (settled_id, _) ->
            Mentat_session.Delegation.Id.equal settled_id id)
          settled
      in
      let children = wait.Step.Children_wait.children in
      if List.for_all (fun id -> Option.is_some (find id)) children then
        let content =
          List.concat_map
            (fun id ->
              match find id with
              | Some (_, (contents, _usage)) ->
                  Mentat_llm.Content.text
                    ("[" ^ Mentat_session.Delegation.Id.to_string id ^ "]")
                  :: contents
              | None -> [])
            children
        in
        normalize env session
          [
            Mentat_session.Event.message_appended
              (Mentat_llm.Message.tool_result
                 (Mentat_llm.Tool.Result.make call content));
          ]
      else Ok { Step.events = []; action = Step.Await_children wait }

let interrupt ?reason ?assistant_text ?usage session =
  (match reason with
  | Some "" ->
      invalid_arg "Mentat_agent_step.interrupt: reason must not be empty"
  | Some _ | None -> ());
  let* turn = active_turn session in
  let turn_id = Mentat_session.Turn.id turn in
  let state = Mentat_session.state session in
  let text = Option.value reason ~default:"interrupted" in
  let prose =
    match assistant_text with
    | Some s when not (String.equal (String.trim s) "") -> Some s
    | Some _ | None -> None
  in
  let settle =
    match Mentat_session.State.suspension state with
    | None -> []
    | Some (Mentat_session.State.Provider started) -> (
        let id = Mentat_session.Provider_request.Started.id started in
        match prose with
        | Some prose_text ->
            [
              Mentat_session.Event.provider_settled
                (Mentat_session.Provider_request.Settled.interrupted ~id ?usage
                   ~text:prose_text ());
            ]
        | None ->
            [
              Mentat_session.Event.provider_settled
                (Mentat_session.Provider_request.Settled.ambiguous ~id);
            ])
    | Some (Mentat_session.State.Tool started) ->
        let id = Mentat_session.Tool_claim.Started.id started in
        [
          Mentat_session.Event.tool_settled
            (Mentat_session.Tool_claim.Settled.returned ~id
               (Mentat_tool.Result.interrupted ~reason:text ~cancelled:true ()));
        ]
    | Some (Mentat_session.State.Decision _) ->
        (* The parked-decision interrupt closer: after the recorded
           interrupt, the reconciliation below may answer the decision-held
           call — the append clears the suspension while the abandoned
           decision stays durably unresolved. No settlement event exists. *)
        []
  in
  let outcome =
    Mentat_session.Turn.Outcome.interrupted ?reason ~cancelled:true ()
  in
  finish_with session ~turn_id ~settle ~outcome ~text

(* Recovery. *)

let recover env session =
  let state = Mentat_session.state session in
  match Mentat_session.State.active_turn state with
  | None -> { Step.events = []; action = Step.Idle }
  | Some turn -> (
      let turn_id = Mentat_session.Turn.id turn in
      let step = function
        | Ok step -> step
        | Error e ->
            invalid_arg ("Mentat_agent_step.recover: " ^ Error.message e)
      in
      let interrupted reason =
        Mentat_session.Turn.Outcome.interrupted ~reason ~cancelled:false ()
      in
      (* Continue the turn after a determined settlement; if the advance
         cannot continue, the turn still reaches a terminal fact. *)
      let continue_with settle =
        match normalize env session settle with
        | Ok s -> s
        | Error e ->
            let message = Error.message e in
            let outcome =
              if Mentat_session.State.interrupt_requested state then
                interrupted message
              else Mentat_session.Turn.Outcome.failed ~message
            in
            step (finish_with session ~turn_id ~settle ~outcome ~text:message)
      in
      match Mentat_session.State.suspension state with
      | Some (Mentat_session.State.Provider started) ->
          let id = Mentat_session.Provider_request.Started.id started in
          let settle =
            [
              Mentat_session.Event.provider_settled
                (Mentat_session.Provider_request.Settled.ambiguous ~id);
            ]
          in
          step
            (finish_with session ~turn_id ~settle
               ~outcome:(interrupted "provider outcome unknown after crash")
               ~text:"provider outcome unknown after crash")
      | Some (Mentat_session.State.Tool started) ->
          let id = Mentat_session.Tool_claim.Started.id started in
          let settle =
            [
              Mentat_session.Event.tool_settled
                (Mentat_session.Tool_claim.Settled.ambiguous ~id);
            ]
          in
          if Mentat_session.State.interrupt_requested state then
            step
              (finish_with session ~turn_id ~settle
                 ~outcome:(interrupted "interrupted")
                 ~text:"interrupted")
          else continue_with settle
      | Some (Mentat_session.State.Decision requested) ->
          { Step.events = []; action = Step.Await_decision requested }
      | None ->
          if Mentat_session.State.interrupt_requested state then
            step
              (finish_with session ~turn_id ~settle:[]
                 ~outcome:
                   (Mentat_session.Turn.Outcome.interrupted ~cancelled:true ())
                 ~text:"interrupted")
          else continue_with [])

(* Admission. *)

module Admission = struct
  type t =
    | Queued of Mentat_session.Queue.Entry.t
    | Step_limit_wind_down of Mentat_session.Turn.Input.t
    | Idle
end

(* A manual compaction turn is transparent to what follows it: it is not work,
   so it neither triggers an admission nor suppresses one. The last real turn is
   the last one that is not a compaction. *)
let last_work_turn state =
  List.rev (Mentat_session.State.turns state)
  |> List.find_opt (fun turn ->
      not
        (Mentat_session.Turn.Origin.equal
           (Mentat_session.Turn.origin turn)
           Mentat_session.Turn.Origin.Compaction))

(* A turn that spent its step budget stopped mid-work with nothing said about
   where it stands. One wrap-up turn is owed — the step limit is a runaway
   backstop, not a decision that the work is over. The wind-down turn carries
   [Step_limit_wind_down], which is what stops a wind-down that spends its own
   budget from admitting another one. *)
let step_limit_wind_down_due state =
  match last_work_turn state with
  | None -> false
  | Some last -> (
      match
        Mentat_session.State.turn_outcome (Mentat_session.Turn.id last) state
      with
      | Some Mentat_session.Turn.Outcome.Step_limit ->
          not
            (Mentat_session.Turn.Origin.equal
               (Mentat_session.Turn.origin last)
               Mentat_session.Turn.Origin.Step_limit_wind_down)
      | Some Mentat_session.Turn.Outcome.Completed
      | Some (Mentat_session.Turn.Outcome.Interrupted _)
      | Some (Mentat_session.Turn.Outcome.Failed _)
      | None ->
          false)

let step_limit_wind_down =
  Admission.Step_limit_wind_down
    (Mentat_session.Turn.Input.user_text Mentat_prompts.Turn.step_limit)

let next_admission state =
  match Mentat_session.State.active_turn state with
  | Some _ -> Admission.Idle
  | None -> (
      match Mentat_session.State.pending_queue state with
      | entry :: _ -> Admission.Queued entry
      | [] ->
          if step_limit_wind_down_due state then step_limit_wind_down
          else Admission.Idle)
