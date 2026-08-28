(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Routine_fire]'s pure pieces: the sweep's delivery
   synthesis and the findings extraction from a run session's journal. The
   pipeline's effectful spine — claim, receipts, the mailed trigger, the
   supervised run, publish — is exercised end to end by the routine cram
   family, and the publish-outcome folds live with their emitter in
   [Publication.Outcome]. *)

open Windtrap
module Session = Mentat_session
module Llm = Mentat_llm
module Json = Jsont.Json

let arm events =
  {
    Mentat_routine.Routine.Trigger.Webhook.events;
    gate =
      {
        Mentat_routine.Routine.Gate.base = None;
        drafts = false;
        associations = None;
      };
  }

let pr number =
  {
    Routine_fire.Github.number;
    head_sha = String.make 40 'a';
    base_ref = "main";
    draft = false;
    author_association = "OWNER";
  }

let sweep_synthesis () =
  (match
     Routine_fire.sweep_events
       (arm [ "pull_request.opened" ])
       ~repo:"acme/widgets" [ pr 7; pr 9 ]
   with
  | [ first; second ] ->
      equal string ~msg:"admitted action" "opened"
        first.Mentat_routine.Event.Pull_request.action;
      equal string ~msg:"repo is the routine's" "acme/widgets"
        first.Mentat_routine.Event.Pull_request.repo;
      equal int ~msg:"listing order" 7
        first.Mentat_routine.Event.Pull_request.number;
      equal int ~msg:"second head" 9
        second.Mentat_routine.Event.Pull_request.number
  | events -> failf "expected two events, got %d" (List.length events));
  (match
     Routine_fire.sweep_events
       (arm [ "pull_request.synchronize"; "pull_request.opened" ])
       ~repo:"acme/widgets" [ pr 7 ]
   with
  | [ event ] ->
      equal string ~msg:"the first admitted review-class action wins"
        "synchronize" event.Mentat_routine.Event.Pull_request.action
  | events -> failf "expected one event, got %d" (List.length events));
  equal int ~msg:"no review-class action synthesizes nothing" 0
    (List.length
       (Routine_fire.sweep_events
          (arm [ "pull_request.closed" ])
          ~repo:"acme/widgets" [ pr 7 ]))

(* A run session's journal, replayed from the exact events the engine's
   structured-output settlement writes: the provider answers with the
   terminating [structured_output] call, the claim carries the validated
   answer, and the turn finishes completed. *)

let output_tool =
  Llm.Tool.make ~name:"structured_output"
    ~input_schema:(Json.object' [ (Json.name "type", Json.string "object") ])
    ()

let contract =
  Session.Contract.make ~mode:Session.Contract.Mode.Review
    ~model:
      (Llm.Model.make
         ~provider:(Llm.Provider.make "openai")
         ~api:(Llm.Model.Api.make "responses")
         ~id:"gpt-5")
    ~declarations:[] ~output_tool ~policy:Mentat_permission.Policy.default
    ~review:Mentat_permission.Review_behavior.Enforce
    ~sandbox:Mentat_sandbox.Identity.not_requested ()

let answer_json summary =
  Json.object' [ (Json.name "summary", Json.string summary) ]

let run_turn ~id =
  Session.Turn.make
    ~id:(Session.Turn.Id.of_string id)
    ~origin:Session.Turn.Origin.User
    ~input:(Session.Turn.Input.user [ Llm.Content.text "Review the diff." ])
    ~max_steps:32 ~contract ()

(* One finished turn whose provider response carries [calls] and whose
   terminating structured-output claim, when [answer] is given, records it —
   the event shape [dispatch_structured_output] commits. [outcome] defaults
   to completed; the discriminating extraction case ends otherwise. *)
let completed_turn ~id ?answer
    ?(outcome = Session.Turn.Outcome.completed) () =
  let turn = run_turn ~id in
  let turn_id = Session.Turn.id turn in
  let claim =
    Session.Provider_request.Started.make ~turn:turn_id
      ~request_digest:(Mentat_digest.string ("req-" ^ id))
  in
  let calls, claims =
    match answer with
    | None -> ([], [])
    | Some answer ->
        let call =
          Llm.Tool.Call.make ~id:("call-" ^ id) ~name:"structured_output"
            ~input:answer ()
        in
        let started =
          Session.Tool_claim.Started.make ~turn:turn_id
            ~stage:Mentat_tool.Stage.Direct ~call ~input:answer ~requests:[]
        in
        let settled =
          Session.Tool_claim.Settled.returned
            ~id:(Session.Tool_claim.Started.id started)
            (Mentat_tool.Result.completed
               ~output:
                 (Mentat_tool.Output.make ~text:"Structured answer recorded."
                    ~json:answer ())
               ())
        in
        ( [ call ],
          [ Session.Event.tool_claimed started; Session.Event.tool_settled settled ] )
  in
  let assistant =
    match calls with
    | [] -> Llm.Message.Assistant.text "no answer"
    | calls ->
        Llm.Message.Assistant.make
          (List.map Llm.Message.Assistant.tool_call calls)
  in
  [
    Session.Event.turn_started turn;
    Session.Event.provider_requested claim;
    Session.Event.provider_settled
      (Session.Provider_request.Settled.responded
         ~id:(Session.Provider_request.Started.id claim)
         (Llm.Response.make
            ~model:
              (Llm.Model.make
                 ~provider:(Llm.Provider.make "openai")
                 ~api:(Llm.Model.Api.make "responses")
                 ~id:"gpt-5")
            assistant));
  ]
  @ claims
  @ [ Session.Event.turn_finished ~turn:turn_id outcome ]

let session_of events =
  let metadata =
    Session.Metadata.make
      ~cwd:(Lpath.Abs.of_string_exn "/workspace")
      ~created_at:(Session.Time.of_unix_ms 0L)
      ~updated_at:(Session.Time.of_unix_ms 0L)
      ()
  in
  match
    Session.make ~id:(Session.Id.of_string "run-fixture") ~metadata ~events
  with
  | Ok session -> session
  | Error e -> failf "replay: %s" (Session.Error.message e)

let findings_extraction () =
  equal (option string) ~msg:"the completed head's answer, minified"
    (Some {|{"summary":"s"}|})
    (Routine_fire.findings_of_session
       (session_of (completed_turn ~id:"t1" ~answer:(answer_json "s") ())));
  equal (option string) ~msg:"a completed head without the claim has none"
    None
    (Routine_fire.findings_of_session
       (session_of (completed_turn ~id:"t1" ())));
  equal (option string)
    ~msg:"a head that did not complete has none, claim or not" None
    (Routine_fire.findings_of_session
       (session_of
          (completed_turn ~id:"t1" ~answer:(answer_json "s")
             ~outcome:Session.Turn.Outcome.step_limit ())));
  equal (option string)
    ~msg:"a failed head has none, claim or not" None
    (Routine_fire.findings_of_session
       (session_of
          (completed_turn ~id:"t1" ~answer:(answer_json "s")
             ~outcome:(Session.Turn.Outcome.failed ~message:"x") ())));
  equal (option string) ~msg:"an unstarted session has none" None
    (Routine_fire.findings_of_session (session_of []));
  equal (option string) ~msg:"the head turn's answer wins"
    (Some {|{"summary":"late"}|})
    (Routine_fire.findings_of_session
       (session_of
          (completed_turn ~id:"t1" ~answer:(answer_json "early") ()
          @ completed_turn ~id:"t2" ~answer:(answer_json "late") ())))

let () =
  run "mentat.routine_fire"
    [
      test "the sweep synthesizes admitted review-class deliveries"
        sweep_synthesis;
      test "the findings document is the head turn's structured answer"
        findings_extraction;
    ]
