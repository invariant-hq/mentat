(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Goal_steward] — the feature's law table. Every arm of the
   continue-or-stop decision is pinned here; the loops that act on a verdict
   (the run command's drive, the TUI's settle handling) are wiring the cram
   and pty tiers prove. *)

open Windtrap
module Goal = Mentat_session.Metadata.Goal
module Claim = Goal_steward.Claim
module Verdict = Goal_steward.Verdict
module Json = Jsont.Json

let obj fields =
  Json.object' (List.map (fun (n, v) -> Json.mem (Json.name n) v) fields)

let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    i + lsub <= ls && (String.equal (String.sub s i lsub) sub || go (i + 1))
  in
  lsub = 0 || go 0

let status ?note s =
  obj
    (("status", Json.string s)
    :: (match note with None -> [] | Some n -> [ ("note", Json.string n) ]))

let goal ?max_turns ?budget () =
  Goal.make ~objective:"get the suite green" ?max_turns ?budget ()

let verdict = Testable.make ~pp:Verdict.pp ~equal:Verdict.equal

let decide ?(finished = true) ?claim ?(continuations = 0) ?spent g =
  Goal_steward.decide ~goal:g ~finished ~claim ~continuations ~spent

let claim_read () =
  let claim = Testable.make ~pp:Claim.pp ~equal:Claim.equal in
  equal (option claim) ~msg:"done with a note"
    (Some (Claim.Done (Some "all tests pass")))
    (Claim.of_json (status ~note:"all tests pass" "done"));
  equal (option claim) ~msg:"continuing with a note"
    (Some (Claim.Continuing (Some "two failures left")))
    (Claim.of_json (status ~note:"two failures left" "continuing"));
  equal (option claim) ~msg:"a noteless claim carries no note"
    (Some (Claim.Done None))
    (Claim.of_json (status "done"));
  equal (option claim) ~msg:"an empty note reads as no note"
    (Some (Claim.Done None))
    (Claim.of_json (status ~note:"" "done"));
  equal (option claim) ~msg:"an unknown status is unreadable" None
    (Claim.of_json (status "finished"));
  equal (option claim) ~msg:"a missing status is unreadable" None
    (Claim.of_json (obj [ ("note", Json.string "n") ]));
  equal (option claim) ~msg:"a non-object is unreadable" None
    (Claim.of_json (Json.string "done"))

let schema_is_sealable () =
  (* The schema a steward seals on a continuation turn must clear the same
     subset gate every output schema clears, or the loop's first turn refuses
     at run time. *)
  match Mentat_llm.Schema.of_json Claim.schema with
  | Ok _ -> ()
  | Error e -> failf "goal_status schema: %s" (Mentat_llm.Schema.Error.message e)

let decision_table () =
  equal (option verdict) ~msg:"unfinished decides nothing, claim or not" None
    (decide ~finished:false ~claim:(status "done") (goal ()));
  equal (option verdict) ~msg:"a done claim stops the loop"
    (Some (Verdict.Done (Some "shipped")))
    (decide ~claim:(status ~note:"shipped" "done") (goal ()));
  equal (option verdict) ~msg:"a continuing claim continues"
    (Some Verdict.Continue)
    (decide ~claim:(status "continuing") (goal ()));
  equal (option verdict) ~msg:"an absent claim continues"
    (Some Verdict.Continue) (decide (goal ()));
  equal (option verdict) ~msg:"an unreadable claim continues"
    (Some Verdict.Continue)
    (decide ~claim:(status "maybe") (goal ()));
  equal (option verdict) ~msg:"a boundless goal has only the owner and done"
    (Some Verdict.Continue)
    (decide ~continuations:10_000 ~spent:1000. (goal ()))

let bound_edges () =
  let bounded = goal ~max_turns:3 () in
  equal (option verdict) ~msg:"under the bound continues"
    (Some Verdict.Continue) (decide ~continuations:2 bounded);
  equal (option verdict) ~msg:"the spent bound stops"
    (Some Verdict.Bound_reached) (decide ~continuations:3 bounded);
  equal (option verdict) ~msg:"a done claim beats the spent bound"
    (Some (Verdict.Done None))
    (decide ~continuations:3 ~claim:(status "done") bounded)

let budget_edges () =
  let budgeted = goal ~budget:5.0 () in
  equal (option verdict) ~msg:"under the budget continues"
    (Some Verdict.Continue) (decide ~spent:4.99 budgeted);
  equal (option verdict) ~msg:"the spent budget stops"
    (Some Verdict.Budget_spent) (decide ~spent:5.0 budgeted);
  equal (option verdict) ~msg:"an unpriced spend trips no budget"
    (Some Verdict.Continue) (decide budgeted);
  equal (option verdict) ~msg:"a done claim beats the spent budget"
    (Some (Verdict.Done None))
    (decide ~spent:9.0 ~claim:(status "done") budgeted);
  equal (option verdict) ~msg:"the turn bound is named before the budget"
    (Some Verdict.Bound_reached)
    (decide ~continuations:3 ~spent:9.0 (goal ~max_turns:3 ~budget:5.0 ()))

let framing () =
  let text = Goal_steward.continuation ~objective:"get the suite green" in
  is_true ~msg:"the framing names the goal"
    (contains_sub ~sub:"Continuing toward the goal: get the suite green" text);
  is_true ~msg:"the framing carries the goal_status instruction"
    (contains_sub ~sub:"goal_status" text)

(* The counter fixture: a journal of settled turns with the given inputs. *)
let session_of_inputs inputs =
  let module Session = Mentat_session in
  let module Llm = Mentat_llm in
  let contract =
    Session.Contract.make ~mode:Session.Contract.Mode.Build
      ~model:
        (Llm.Model.make
           ~provider:(Llm.Provider.make "openai")
           ~api:(Llm.Model.Api.make "responses")
           ~id:"gpt-5")
      ~declarations:[] ~policy:Mentat_permission.Policy.default
      ~review:Mentat_permission.Review_behavior.Enforce
      ~sandbox:(Mentat_sandbox.identity Mentat_sandbox.direct)
      ()
  in
  let turn i text =
    let id = Printf.sprintf "t%d" i in
    let turn =
      Session.Turn.make
        ~id:(Session.Turn.Id.of_string id)
        ~origin:Session.Turn.Origin.User
        ~input:(Session.Turn.Input.user_text text)
        ~max_steps:1 ~contract ()
    in
    let provider =
      Session.Provider_request.Started.make ~turn:(Session.Turn.id turn)
        ~request_digest:(Mentat_digest.string ("req-" ^ id))
    in
    [
      Session.Event.turn_started turn;
      Session.Event.provider_requested provider;
      Session.Event.provider_settled
        (Session.Provider_request.Settled.responded
           ~id:(Session.Provider_request.Started.id provider)
           (Llm.Response.make
              ~model:(Session.Contract.model contract)
              (Llm.Message.Assistant.text "ok")));
      Session.Event.turn_finished ~turn:(Session.Turn.id turn)
        Session.Turn.Outcome.completed;
    ]
  in
  let session =
    Session.create
      ~id:(Session.Id.of_string "counter")
      ~cwd:(Lpath.Abs.of_string_exn "/workspace")
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  match
    Session.append_all (List.concat (List.mapi turn inputs)) session
  with
  | Ok session -> session
  | Error e -> failf "counter fixture: %s" (Mentat_session.Error.message e)

let counter () =
  let objective = "get the suite green" in
  let framed = Goal_steward.continuation ~objective in
  let session =
    session_of_inputs
      [
        "start the work";
        framed;
        "an ordinary owner question";
        framed;
        Goal_steward.continuation ~objective:(objective ^" and the docs");
      ]
  in
  equal int ~msg:"framed turns for this exact objective count" 2
    (Goal_steward.continuations ~objective session);
  equal int ~msg:"another objective keeps its own ledger" 1
    (Goal_steward.continuations
       ~objective:(objective ^ " and the docs")
       session);
  equal int
    ~msg:"an objective that is a prefix of another counts nothing of it" 0
    (Goal_steward.continuations ~objective:"get the suite" session);
  equal int ~msg:"an empty journal counts zero" 0
    (Goal_steward.continuations ~objective (session_of_inputs []))

let () =
  run "mentat.goal_steward"
    [
      test "the goal_status claim reads tolerantly" claim_read;
      test "the claim schema clears the output-schema gate" schema_is_sealable;
      test "the decision table's core arms" decision_table;
      test "the turn-bound edges" bound_edges;
      test "the budget edges" budget_edges;
      test "the continuation framing is one constant" framing;
      test "the continuation counter is journal-derived" counter;
    ]
