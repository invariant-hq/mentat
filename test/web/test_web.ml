(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_web], the pure fact-to-HTML projection. The suite
   pins one snapshot-style structural assertion per [Fact.t] arm, the
   [Progress.t] folds through the live region, a cold-load fold, and the
   XSS-firewall hostile-bytes fuzz: attacker-influenceable bytes fed through
   every
   text-carrying field never survive as an unescaped tag, attribute breakout,
   or dangerous URL scheme. Everything is asserted on the rendered string with
   explicit checks; there is no snapshot-promotion step. *)

open Windtrap
module Web = Mentat_web
module Render = Web.Render
module Html = Web.Html
module Protocol = Mentat_protocol
module Fact = Protocol.Fact
module Progress = Protocol.Progress
module Position = Protocol.Position
module Session = Mentat_session
module Llm = Mentat_llm
module Permission = Mentat_permission
module Tool = Mentat_tool
module Json = Jsont.Json

(* Generic helpers. *)

let now = 1000.
let session = Session.Id.of_string "sess-1"
let position seq = Position.make ~session ~seq

let has_sub ~needle haystack =
  let needle_len = String.length needle and hay_len = String.length haystack in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.equal (String.sub haystack i needle_len) needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let ok = function
  | Ok value -> value
  | Error error ->
      failf "unexpected fact error: %s" (Render.Error.message error)

let fold ?(now = now) acc position fact =
  ok (Render.fact ~now acc position fact)

let html_of nodes = String.concat "" (List.map Html.to_string nodes)
let live acc = Html.to_string (Render.live ~now ~session acc)

(* Fixtures, built as the protocol suite builds them. *)

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider ~api ~id:"gpt-5"
let sandbox = Mentat_sandbox.identity Mentat_sandbox.direct
let digest seed = Mentat_digest.string seed
let turn_id name = Session.Turn.Id.of_string name

let contract () =
  Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
    ~declarations:[] ~policy:Permission.Policy.default
    ~review:Permission.Review_behavior.Enforce ~sandbox ()

let turn ?(id = "turn-1") ?(origin = Session.Turn.Origin.User)
    ?(input = Session.Turn.Input.user_text "Refactor.") () =
  Session.Turn.make ~id:(turn_id id) ~origin ~input ~max_steps:16
    ~contract:(contract ()) ()

let response ?reasoning text =
  Llm.Response.make ~model ?reasoning_summary:reasoning
    (Llm.Message.Assistant.text text)

let call ?(id = "call-1") ?(name = "read_file") () =
  Llm.Tool.Call.make ~id ~name ~input:(Json.object' []) ()

let tool_claim ?(stage = Tool.Stage.Direct) ?(id = "call-1")
    ?(name = "read_file") ?(turn = turn_id "turn-1") () =
  Session.Tool_claim.Started.make ~turn ~stage ~call:(call ~id ~name ())
    ~input:(Json.object' []) ~requests:[]

let completed text =
  Tool.Result.completed ~output:(Tool.Output.make ~text ()) ()

let started () = fold Render.initial (position 0) (Fact.Turn_started (turn ()))

(* An accumulator with an active turn plus one running tool, for arms that
   settle a tool. *)
let with_tool () =
  let acc, _ = started () in
  let claim = tool_claim () in
  let acc, _ = fold acc (position 1) (Fact.Tool_started claim) in
  (acc, Session.Tool_claim.Started.id claim)

(* Decision fixtures. *)

let question_request ~turn () =
  let question = Result.get_ok (Session.Question.make ~prompt:"Proceed?" ()) in
  Session.Decision.Requested.make ~turn ~call:(call ()) ~stage:Tool.Stage.Direct
    (Session.Decision.Request.Question question)

let plan_request ~turn () =
  let plan = Result.get_ok (Session.Plan.make ~body:"Do the thing." ()) in
  Session.Decision.Requested.make ~turn ~call:(call ()) ~stage:Tool.Stage.Direct
    (Session.Decision.Request.Plan plan)

let permission_request ~turn () =
  let access = Permission.Access.custom "session.test" in
  let request =
    Permission.Request.of_accesses ~display:"read a file" [ access ]
  in
  let review =
    Result.get_ok
      (Permission.Policy.Review.restore request
         [ (access, Permission.Policy.Review.Unmatched) ])
  in
  Session.Decision.Requested.make ~turn ~call:(call ()) ~stage:Tool.Stage.Direct
    (Session.Decision.Request.Permission review)

(* ── Html escaping unit tests ───────────────────────────────────────────── *)

let escaping_tests =
  group "html escaping"
    [
      test "El.txt escapes the five characters" (fun () ->
          equal string "&lt;a&gt;&amp;&quot;&#39;"
            (Html.to_string (Html.El.txt "<a>&\"'")));
      test "At.v escapes attribute values" (fun () ->
          let node = Html.El.div ~at:[ Html.At.v "title" "a\"><b" ] [] in
          let html = Html.to_string node in
          contains ~msg:html ~sub:"a&quot;&gt;&lt;b" html;
          not_contains ~sub:"\"><b" html);
      test "unsafe_raw is verbatim" (fun () ->
          equal string "<hr>" (Html.to_string (Html.El.unsafe_raw "<hr>")));
      test "void elements self-close" (fun () ->
          contains ~sub:"<hr" (Html.to_string (Html.El.hr ())));
    ]

(* ── Fact arm coverage ──────────────────────────────────────────────────── *)

let turn_family_tests =
  group "turn family"
    [
      test "turn.started renders the user article" (fun () ->
          let _acc, blocks = started () in
          let html = html_of blocks in
          contains ~msg:html ~sub:"msg user" html;
          contains ~sub:"turn-turn-1-user" html;
          contains ~sub:"Refactor." html);
      test "turn.started for a non-user origin renders no speech" (fun () ->
          let acc, blocks =
            fold Render.initial (position 0)
              (Fact.Turn_started
                 (turn
                    ~origin:
                      (Session.Turn.Origin.Triggered
                         {
                           source = "nightly-review";
                           digest = "0123456789abcdef";
                           key = "2026-08-25T06:00";
                         })
                    ~input:Session.Turn.Input.continue ()))
          in
          equal int 0 (List.length blocks);
          ignore acc);
      test "turn.assistant renders markdown, not raw prose" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_assistant (response "**bold** `code`"))
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"<strong>bold</strong>" html;
          contains ~sub:"<code>code</code>" html;
          contains ~sub:"msg assistant" html;
          contains ~sub:"f-1" html);
      test "turn.assistant renders a reasoning details block" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_assistant
                 (response ~reasoning:[ "I thought hard." ] "hi"))
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"<details" html;
          contains ~sub:"I thought hard." html);
      test "turn.assistant_interrupted renders escaped prose" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_assistant_interrupted { text = "partial" })
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"interrupted" html;
          contains ~sub:"partial" html);
      test "turn.provider_failed renders a failure notice" (fun () ->
          let acc, _ = started () in
          let error = Llm.Error.make ~kind:Llm.Error.Auth ~provider "boom" in
          let claim = Session.Provider_request.Id.of_string "prov-1" in
          let _acc, blocks =
            fold acc (position 1) (Fact.Turn_provider_failed { claim; error })
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"notice failure" html;
          contains ~sub:"boom" html);
      test "turn.message system renders an event notice" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_message (Llm.Message.system "reindexed"))
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"System — reindexed" html);
      test "turn.message assistant is rejected as a firewall miss" (fun () ->
          let acc, _ = started () in
          let message =
            Llm.Message.assistant (Llm.Message.Assistant.text "x")
          in
          match
            Render.fact ~now acc (position 1) (Fact.Turn_message message)
          with
          | Error Render.Error.Assistant_message -> ()
          | Error other -> failf "wrong error: %s" (Render.Error.message other)
          | Ok _ -> fail "expected the assistant sub-arm to be rejected");
      test "turn.message tool_result renders a generic tool row" (fun () ->
          let acc, _ = started () in
          let result = Llm.Tool.Result.text (call ()) "output text" in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_message (Llm.Message.tool_result result))
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"tool" html;
          contains ~sub:"read_file" html);
      test "turn.settled with elapsed renders the worked receipt" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold ~now:(now +. 5.) acc (position 1)
              (Fact.Turn_settled
                 {
                   turn = turn_id "turn-1";
                   outcome = Session.Turn.Outcome.completed;
                 })
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"Worked for 5s" html);
      test "turn.settled with an open tool is a finding" (fun () ->
          let acc, _ = with_tool () in
          match
            Render.fact ~now acc (position 2)
              (Fact.Turn_settled
                 {
                   turn = turn_id "turn-1";
                   outcome = Session.Turn.Outcome.completed;
                 })
          with
          | Error (Render.Error.Open_state_at_settlement _) -> ()
          | Error other -> failf "wrong error: %s" (Render.Error.message other)
          | Ok _ -> fail "expected an open-state finding");
    ]

let tool_family_tests =
  group "tool family"
    [
      test "tool.started adds a running row to the live region" (fun () ->
          let acc, _ = with_tool () in
          let html = live acc in
          contains ~msg:html ~sub:"tool running" html;
          contains ~sub:"tool-" html;
          contains ~sub:"read_file" html);
      test "tool.returned renders a settled committed row" (fun () ->
          let acc, claim = with_tool () in
          let _acc, blocks =
            fold acc (position 2)
              (Fact.Tool_returned
                 { claim; result = completed "hello world"; mutation = None })
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"tool done" html;
          contains ~sub:"read_file" html;
          contains ~sub:"hello world" html);
      test "tool.prepared morphs the row to awaiting" (fun () ->
          let acc, _ = started () in
          let claim = tool_claim ~stage:Tool.Stage.Prepare () in
          let acc, _ = fold acc (position 1) (Fact.Tool_started claim) in
          let acc, _ =
            fold acc (position 2)
              (Fact.Tool_prepared
                 {
                   claim = Session.Tool_claim.Started.id claim;
                   description = "will edit README";
                   requests = [];
                 })
          in
          let html = live acc in
          contains ~msg:html ~sub:"tool awaiting" html;
          contains ~sub:"will edit README" html);
      test "tool.ambiguous renders an ambiguous committed row" (fun () ->
          let acc, claim = with_tool () in
          let _acc, blocks =
            fold acc (position 2)
              (Fact.Tool_ambiguous { claim; mutation = None })
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"tool ambiguous" html);
    ]

let decision_family_tests =
  group "decision family"
    [
      test "decision.requested renders a question form in the live region"
        (fun () ->
          let acc, _ = started () in
          let request = question_request ~turn:(turn_id "turn-1") () in
          let acc, _ =
            fold acc (position 1) (Fact.Decision_requested request)
          in
          let html = live acc in
          contains ~msg:html ~sub:"class=\"decision\"" html;
          contains ~sub:"method=\"post\"" html;
          contains ~sub:"/session/sess-1/decision/" html;
          contains ~sub:"Proceed?" html);
      test "decision.requested renders permission allow/deny buttons" (fun () ->
          let acc, _ = started () in
          let request = permission_request ~turn:(turn_id "turn-1") () in
          let acc, _ =
            fold acc (position 1) (Fact.Decision_requested request)
          in
          let html = live acc in
          contains ~msg:html ~sub:"value=\"allow-once\"" html;
          contains ~sub:"value=\"deny\"" html;
          contains ~sub:"read a file" html);
      test "decision.requested renders plan approve/revise buttons" (fun () ->
          let acc, _ = started () in
          let request = plan_request ~turn:(turn_id "turn-1") () in
          let acc, _ =
            fold acc (position 1) (Fact.Decision_requested request)
          in
          let html = live acc in
          contains ~msg:html ~sub:"value=\"approve\"" html;
          contains ~sub:"Do the thing." html);
      test "decision.resolved renders an answered block and clears the form"
        (fun () ->
          let acc, _ = started () in
          let request = question_request ~turn:(turn_id "turn-1") () in
          let acc, _ =
            fold acc (position 1) (Fact.Decision_requested request)
          in
          let answer =
            Session.Decision.Answer.Question
              (Session.Question.Answer.free "yes")
          in
          let resolved, _ =
            Result.get_ok
              (Session.Decision.resolve request ~call:(call ())
                 ~by:Session.Principal.local_user answer)
          in
          let acc, blocks =
            fold acc (position 2) (Fact.Decision_resolved resolved)
          in
          let committed = html_of blocks in
          contains ~msg:committed ~sub:"You answered: yes" committed;
          not_contains ~sub:"class=\"decision\"" (live acc));
    ]

let journal_family_tests =
  group "journal family"
    [
      test "journal.task_board renders a board in the live region" (fun () ->
          let acc, _ = started () in
          let item =
            Result.get_ok
              (Session.Task.Item.make
                 ~id:(Session.Task.Id.of_string "t1")
                 ~owner:Session.Task.Owner.Main ~content:"write the code"
                 ~status:Session.Task.Status.In_progress ~position:0 ())
          in
          let board = Result.get_ok (Session.Task.Board.make [ item ]) in
          let acc, _ = fold acc (position 1) (Fact.Journal_task_board board) in
          let html = live acc in
          contains ~msg:html ~sub:"class=\"board\"" html;
          contains ~sub:"task in_progress" html;
          contains ~sub:"write the code" html);
      test "journal.queue renders a queue chip" (fun () ->
          let acc, _ = started () in
          let entry =
            Session.Queue.Entry.make
              ~id:(Session.Queue.Id.of_string "q1")
              ~input:[ Llm.Content.text "next" ]
              ()
          in
          let update = Session.Queue.Update.enqueued entry in
          let acc, _ = fold acc (position 1) (Fact.Journal_queue update) in
          contains ~sub:"queued" (live acc));
      test "journal.delegation renders a child link" (fun () ->
          let acc, _ = started () in
          let edge =
            Session.Delegation.make
              ~child:(Session.Id.of_string "child-1")
              ~source_turn:(turn_id "turn-1") ~source_call:"call-1"
              ~description:"explore the codebase"
              ~task:[ Llm.Content.text "look around" ]
              ()
          in
          let _acc, blocks =
            fold acc (position 1) (Fact.Journal_delegation edge)
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"/session/child-1" html;
          contains ~sub:"explore the codebase" html);
      test "compaction renders a seam with a labelled boundary" (fun () ->
          let acc, _ = started () in
          let compaction =
            Session.Compaction.make
              ~reason:Session.Compaction.Reason.Context_pressure
              ~provider_claim:(Session.Provider_request.Id.of_string "prov-1")
              ~request_digest:(digest "summary")
              ~summary_messages:[ Llm.Message.user_text "Summarized." ]
              ~summarized_upto:4
              ~context:
                (Session.Compaction.Context_tokens.make ~before:9000 ~after:800
                   ())
              ()
          in
          let _acc, blocks =
            fold acc (position 1) (Fact.Compaction compaction)
          in
          let html = html_of blocks in
          contains ~msg:html ~sub:"class=\"seam\"" html;
          contains ~sub:"compacted" html);
    ]

(* ── Progress folds ─────────────────────────────────────────────────────── *)

let pulse turn update = Progress.Model { turn; update }

let progress_tests =
  group "progress"
    [
      test "assistant delta streams as plain escaped text, not markdown"
        (fun () ->
          let acc, _ = started () in
          let acc =
            Render.progress acc
              (pulse (turn_id "turn-1")
                 (Progress.Model.Assistant_delta { text = "**not bold**" }))
          in
          let html = live acc in
          contains ~msg:html ~sub:"streaming" html;
          contains ~sub:"**not bold**" html;
          not_contains ~sub:"<strong>" html);
      test "reasoning delta streams into the ticker" (fun () ->
          let acc, _ = started () in
          let acc =
            Render.progress acc
              (pulse (turn_id "turn-1")
                 (Progress.Model.Reasoning_delta { text = "hmm" }))
          in
          contains ~sub:"hmm" (live acc));
      test "usage pulse feeds the working line token count" (fun () ->
          let acc, _ = started () in
          let usage = Llm.Usage.make ~input:10 ~output:2500 () in
          let acc =
            Render.progress acc
              (pulse (turn_id "turn-1") (Progress.Model.Usage usage))
          in
          contains ~sub:"2.5k tokens" (live acc));
      test "model download pulse renders a download banner" (fun () ->
          let acc, _ = started () in
          let update =
            {
              Progress.Model_download.model = "qwen";
              received = 0L;
              total = Some 100L;
              phase = Progress.Model_download.Downloading;
            }
          in
          let acc =
            Render.progress acc
              (Progress.Model_download { turn = turn_id "turn-1"; update })
          in
          let html = live acc in
          contains ~msg:html ~sub:"Downloading qwen" html);
      test "compaction pulse shows the compacting banner" (fun () ->
          let acc, _ = started () in
          let acc =
            Render.progress acc
              (Progress.Compaction
                 {
                   turn = turn_id "turn-1";
                   update =
                     Progress.Compaction.Started
                       { reason = Session.Compaction.Reason.Context_pressure };
                 })
          in
          contains ~sub:"Compacting" (live acc));
      test "a pulse for an inactive turn is ignored" (fun () ->
          let acc, _ = started () in
          let acc =
            Render.progress acc
              (pulse (turn_id "other")
                 (Progress.Model.Assistant_delta { text = "ghost" }))
          in
          not_contains ~sub:"ghost" (live acc));
    ]

(* ── Cold load ──────────────────────────────────────────────────────────── *)

let cold_tests =
  group "cold load"
    [
      test "cold folds a page into transcript plus live regions" (fun () ->
          let facts =
            [
              (position 0, Fact.Turn_started (turn ()));
              (position 1, Fact.Turn_assistant (response "done"));
              ( position 2,
                Fact.Turn_settled
                  {
                    turn = turn_id "turn-1";
                    outcome = Session.Turn.Outcome.completed;
                  } );
            ]
          in
          let page = { Protocol.Transcript.Page.facts; before = None } in
          let view =
            {
              Protocol.Transcript.Tail.head = Some (position 2);
              pending = None;
              page;
            }
          in
          let _acc, body = ok (Render.cold ~now ~session view) in
          let html = Html.to_string body in
          contains ~msg:html ~sub:"id=\"transcript\"" html;
          contains ~sub:"id=\"live\"" html;
          contains ~sub:"Refactor." html;
          contains ~sub:"done" html);
      test "cold seeds the pending decision form from the tail" (fun () ->
          let facts = [ (position 0, Fact.Turn_started (turn ())) ] in
          let page = { Protocol.Transcript.Page.facts; before = None } in
          let pending = question_request ~turn:(turn_id "turn-1") () in
          let view =
            {
              Protocol.Transcript.Tail.head = Some (position 0);
              pending = Some pending;
              page;
            }
          in
          let _acc, body = ok (Render.cold ~now ~session view) in
          contains ~sub:"class=\"decision\"" (Html.to_string body));
    ]

(* ── Windowed reads: mid-turn seeding ───────────────────────────────────── *)

let settled id =
  Fact.Turn_settled
    { turn = turn_id id; outcome = Session.Turn.Outcome.completed }

(* A bounded window whose leading fact belongs to a turn started above the
   window (an orphan), followed by one complete in-window turn. *)
let orphan_window () =
  [
    (position 5, Fact.Turn_assistant (response "orphan tail"));
    (position 6, Fact.Turn_started (turn ~id:"turn-2" ()));
    (position 7, Fact.Turn_assistant (response "complete answer"));
    (position 8, settled "turn-2");
  ]

let view_of ?(pending = None) facts =
  {
    Protocol.Transcript.Tail.head = Some (position 8);
    pending;
    page = { Protocol.Transcript.Page.facts; before = None };
  }

let windowed_tests =
  group "windowed reads"
    [
      test "cold tolerates a mid-turn window and marks the truncation"
        (fun () ->
          let _acc, body =
            ok (Render.cold ~now ~session (view_of (orphan_window ())))
          in
          let html = Html.to_string body in
          contains ~msg:html ~sub:"truncated" html;
          contains ~sub:"Earlier messages" html;
          contains ~sub:"complete answer" html;
          not_contains ~sub:"orphan tail" html);
      test "page folds a backward window without an inline marker" (fun () ->
          match Render.page ~now (orphan_window ()) with
          | Error error -> failf "page error: %s" (Render.Error.message error)
          | Ok (_acc, blocks) ->
              let html = html_of blocks in
              contains ~msg:html ~sub:"complete answer" html;
              not_contains ~sub:"orphan tail" html;
              not_contains ~sub:"Earlier messages" html);
      test "attach seeds a running turn so a live fact folds" (fun () ->
          let seed =
            [
              (position 5, Fact.Turn_assistant (response "orphan"));
              (position 6, Fact.Turn_started (turn ~id:"turn-2" ()));
            ]
          in
          let acc = Render.attach ~now seed in
          let claim = tool_claim ~turn:(turn_id "turn-2") () in
          match Render.fact ~now acc (position 7) (Fact.Tool_started claim) with
          | Ok _ -> ()
          | Error error ->
              failf "seeded acc rejected a live fact: %s"
                (Render.Error.message error));
      test "cold rejects an out-of-order fact after a turn is established"
        (fun () ->
          let facts =
            [
              (position 6, Fact.Turn_started (turn ~id:"turn-2" ()));
              (position 7, settled "turn-2");
              (position 8, Fact.Turn_assistant (response "no active turn"));
            ]
          in
          match Render.cold ~now ~session (view_of facts) with
          | Error Render.Error.No_active_turn -> ()
          | Error other -> failf "wrong error: %s" (Render.Error.message other)
          | Ok _ ->
              fail "expected the post-context firewall to reject the orphan");
      test "cold preserves the assistant-message firewall post-context"
        (fun () ->
          let facts =
            [
              (position 6, Fact.Turn_started (turn ~id:"turn-2" ()));
              ( position 7,
                Fact.Turn_message
                  (Llm.Message.assistant (Llm.Message.Assistant.text "x")) );
            ]
          in
          match Render.cold ~now ~session (view_of facts) with
          | Error Render.Error.Assistant_message -> ()
          | Error other -> failf "wrong error: %s" (Render.Error.message other)
          | Ok _ -> fail "expected the assistant-message firewall");
    ]

(* ── XSS-firewall hostile-bytes fuzz ────────────────────────────────────── *)

let hostile = "<script>alert('XSS')</script>\" onload=\"evil()\" ]]>"

let assert_no_injection ~context html =
  let banned needle =
    not_contains
      ~msg:(Printf.sprintf "%s: unescaped %S survived" context needle)
      ~sub:needle html
  in
  banned "<script>";
  banned "</script>";
  banned "onload=\"evil";
  banned "'XSS'"

let fuzz_tests =
  group "hostile bytes"
    [
      test "assistant markdown escapes every text node" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1) (Fact.Turn_assistant (response hostile))
          in
          let html = html_of blocks in
          assert_no_injection ~context:"assistant" html;
          contains ~sub:"&lt;script&gt;" html);
      test "a javascript link destination is dropped" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_assistant (response "[click](javascript:alert(1))"))
          in
          let html = html_of blocks in
          not_contains ~msg:html ~sub:"javascript:" html;
          contains ~sub:"click" html);
      test "user prompt text is escaped" (fun () ->
          let acc, blocks =
            fold Render.initial (position 0)
              (Fact.Turn_started
                 (turn ~input:(Session.Turn.Input.user_text hostile) ()))
          in
          assert_no_injection ~context:"user" (html_of blocks);
          ignore acc);
      test "interrupted prose is escaped" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_assistant_interrupted { text = hostile })
          in
          assert_no_injection ~context:"interrupted" (html_of blocks));
      test "provider error message is escaped" (fun () ->
          let acc, _ = started () in
          let error =
            Llm.Error.make ~kind:Llm.Error.Provider ~provider hostile
          in
          let claim = Session.Provider_request.Id.of_string "prov-1" in
          let _acc, blocks =
            fold acc (position 1) (Fact.Turn_provider_failed { claim; error })
          in
          assert_no_injection ~context:"provider error" (html_of blocks));
      test "system message is escaped" (fun () ->
          let acc, _ = started () in
          let _acc, blocks =
            fold acc (position 1)
              (Fact.Turn_message (Llm.Message.system hostile))
          in
          assert_no_injection ~context:"system" (html_of blocks));
      test "tool result output is escaped" (fun () ->
          let acc, claim = with_tool () in
          let _acc, blocks =
            fold acc (position 2)
              (Fact.Tool_returned
                 { claim; result = completed hostile; mutation = None })
          in
          assert_no_injection ~context:"tool output" (html_of blocks));
      test "a hostile question prompt is escaped in the form" (fun () ->
          let acc, _ = started () in
          let question =
            Result.get_ok (Session.Question.make ~prompt:hostile ())
          in
          let request =
            Session.Decision.Requested.make ~turn:(turn_id "turn-1")
              ~call:(call ()) ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Question question)
          in
          let acc, _ =
            fold acc (position 1) (Fact.Decision_requested request)
          in
          assert_no_injection ~context:"question" (live acc));
      test "a hostile plan body is escaped in the form" (fun () ->
          let acc, _ = started () in
          let plan = Result.get_ok (Session.Plan.make ~body:hostile ()) in
          let request =
            Session.Decision.Requested.make ~turn:(turn_id "turn-1")
              ~call:(call ()) ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Plan plan)
          in
          let acc, _ =
            fold acc (position 1) (Fact.Decision_requested request)
          in
          assert_no_injection ~context:"plan" (live acc));
      test "a hostile notice title is escaped in text and attribute" (fun () ->
          let acc, _ = started () in
          let notice =
            Session.Notice.make ~source:"dune"
              ~severity:Session.Notice.Severity.Error ~title:hostile
              ~body:hostile ()
          in
          let _acc, blocks =
            fold acc (position 1) (Fact.Workspace_notice notice)
          in
          assert_no_injection ~context:"notice" (html_of blocks));
      test "a hostile delegation label is escaped" (fun () ->
          let acc, _ = started () in
          let edge =
            Session.Delegation.make
              ~child:(Session.Id.of_string "child-1")
              ~source_turn:(turn_id "turn-1") ~source_call:"call-1"
              ~description:hostile
              ~task:[ Llm.Content.text "x" ]
              ()
          in
          let _acc, blocks =
            fold acc (position 1) (Fact.Journal_delegation edge)
          in
          assert_no_injection ~context:"delegation" (html_of blocks));
    ]

(* ── Route + feed fixtures ──────────────────────────────────────────────── *)

module Client = Mentat_client
module Driver = Client.Driver
module ClientFeed = Client.Feed
module Update = Protocol.Update
module Transcript = Protocol.Transcript
module Command = Protocol.Command
module Routes = Web.Routes
module Page = Web.Page
module Path = Lpath
module Session_view = Session.Session_view
module Summary = Session.Summary
module Metadata = Session.Metadata
module Time = Session.Time
module Decision = Session.Decision

(* Run a body needing a switch under one Eio domain, guarded so a feed fiber
   that never wakes fails loudly instead of hanging the suite. *)
let with_eio f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  match
    Eio.Time.with_timeout clock 15.0 (fun () ->
        f sw;
        Ok ())
  with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: the feed body exceeded 15s"

(* Every field of the default sub-records fails loudly; a test overrides only the
   fields it exercises with [{ default with field = ... }] — the test_client
   idiom re-homed for the route layer. *)

let default_session : Driver.Session.t =
  {
    Driver.Session.submit = (fun _ -> fail "submit: not scripted");
    follow = (fun _ ~from:_ -> fail "follow: not scripted");
    answer_unattended =
      (fun ~session:_ ~decision:_ -> fail "answer_unattended: not scripted");
    possibly_mutating =
      (fun ~session:_ -> fail "possibly_mutating: not scripted");
    faulted = (fun ~session:_ -> fail "faulted: not scripted");
    fork = (fun ~session:_ ~into:_ -> fail "fork: not scripted");
    rewind = (fun ~session:_ ~into:_ ~anchor:_ -> fail "rewind: not scripted");
    compact = (fun ~session:_ ~turn:_ -> fail "compact: not scripted");
    pending_decision = (fun _ -> fail "pending_decision: not scripted");
    change_diff = (fun ~session:_ ~change:_ -> fail "change_diff: not scripted");
    tail = (fun ?n:_ _ -> fail "tail: not scripted");
    page = (fun ?n:_ _ ~before:_ -> fail "page: not scripted");
    running_processes = (fun _ -> fail "running_processes: not scripted");
    revert = (fun ~session:_ ~scope:_ -> fail "revert: not scripted");
    undo = (fun ~session:_ ~op:_ -> fail "undo: not scripted");
    export = (fun ~session:_ -> fail "export: not scripted");
  }

let default_accounts : Driver.Accounts.t =
  {
    Driver.Accounts.login =
      (fun ~provider:_ ~method_:_ -> fail "login: not scripted");
    save_api_key = (fun ~provider:_ ~key:_ -> fail "save_api_key: not scripted");
    logout = (fun ?revoke:_ _ -> fail "logout: not scripted");
    account_readiness = (fun () -> fail "account_readiness: not scripted");
    model_readiness = (fun ?refresh:_ () -> fail "model_readiness: not scripted");
  }

let default_settings : Driver.Settings.t =
  {
    Driver.Settings.set_model =
      (fun ~session:_ ?reasoning_effort:_ _ -> fail "set_model: not scripted");
    set_permission_review =
      (fun ~session:_ _ -> fail "set_permission_review: not scripted");
    configuration = (fun () -> fail "configuration: not scripted");
    set_default_model =
      (fun ?reasoning_effort:_ _ -> fail "set_default_model: not scripted");
    set_ui_theme = (fun ~theme:_ -> fail "set_ui_theme: not scripted");
  }

let default_lifecycle : Driver.Lifecycle.t =
  {
    Driver.Lifecycle.create =
      (fun ~id:_ ~title:_ -> fail "create: not scripted");
    rename = (fun ~session:_ ~title:_ -> fail "rename: not scripted");
    archive = (fun ~session:_ -> fail "archive: not scripted");
    restore = (fun ~session:_ -> fail "restore: not scripted");
    delete = (fun ~session:_ -> fail "delete: not scripted");
    sessions = (fun ~listing:_ -> fail "sessions: not scripted");
    session = (fun _ -> fail "session: not scripted");
  }

let default_review : Driver.Review.t =
  {
    Driver.Review.apply = (fun _ -> fail "review apply: not scripted");
    state = (fun ~scope:_ -> fail "review state: not scripted");
    diff = (fun ~path:_ -> fail "review diff: not scripted");
    crs = (fun () -> fail "review crs: not scripted");
    compose = (fun _ -> fail "review compose: not scripted");
  }

let default_workspace : Driver.Workspace.t =
  {
    Driver.Workspace.glance = (fun () -> fail "glance: not scripted");
    dune = (fun () -> fail "workspace dune: not scripted");
    dune_control =
      (fun ~op:_ -> fail "workspace dune_control: not scripted");
  }

let client_of ?(session = default_session) ?(accounts = default_accounts)
    ?(settings = default_settings) ?(lifecycle = default_lifecycle)
    ?(review = default_review) ?(workspace = default_workspace) () =
  Client.make
    ~user_commands:(fun () -> fail "user_commands: not scripted")
    ~expand_command:(fun ~name:_ ~arguments:_ ->
      fail "expand_command: not scripted")
    ~attach:(fun ~session:_ _source -> fail "attach: not scripted")
    { Driver.session; accounts; settings; lifecycle; review; workspace }

(* A feed seam that pops scripted updates synchronously, then reports [Closed]
   once exhausted, so [Routes.feed] runs to completion without parking. *)
let closing_seam updates : ClientFeed.seam =
  let q = Queue.create () in
  List.iter (fun u -> Queue.push u q) updates;
  {
    ClientFeed.next =
      (fun () ->
        match Queue.take_opt q with
        | Some update -> Ok (ClientFeed.Item update)
        | None -> Ok ClientFeed.Closed);
    close = (fun () -> ());
  }

let env_of client =
  Routes.Env.make ~client
    ~now:(fun () -> now)
    ~new_session:(fun () -> Session.Id.of_string "new-session")
    ~new_turn:(fun () -> turn_id "minted-turn")

let sample_session ?title id_str =
  let metadata =
    Metadata.make ?title
      ~cwd:(Path.Abs.of_string_exn "/workspace")
      ~created_at:(Time.of_unix_ms 1L) ~updated_at:(Time.of_unix_ms 2L) ()
  in
  match
    Session.make
      ~id:(Session.Id.of_string id_str)
      ~metadata
      ~events:[ Session.Event.turn_started (turn ()) ]
  with
  | Ok session -> session
  | Error error -> failf "session build: %a" Session.Error.pp error

let summary_of ?title id_str = Summary.of_session (sample_session ?title id_str)

let tail_of facts head =
  {
    Transcript.Tail.head;
    pending = None;
    page = { Transcript.Page.facts; before = None };
  }

let frame_id frame = frame.Routes.Frame.id
let frame_html frame = frame.Routes.Frame.html
let http_status response = (Routes.to_http response).Routes.Http.status

(* ── Page shell ─────────────────────────────────────────────────────────── *)

let page_tests =
  group "page shell"
    [
      test
        "the in-page CSP is byte-identical to the edge's authoritative header \
         (CSP drift guard)" (fun () ->
          equal string
            ~msg:
              "Page.content_security_policy and \
               Mentat_server.Web.content_security_policy must not drift"
            Mentat_server.Web.content_security_policy
            Page.content_security_policy);
      test "session document carries the CSP meta, composer, and resume token"
        (fun () ->
          let html =
            Html.to_string
              (Page.session ~title:"Hi" ~session
                 ~resume:(Some (position 3))
                 ~earlier:None ~body:Html.El.void)
          in
          contains ~msg:html ~sub:"Content-Security-Policy" html;
          contains ~sub:"default-src &#39;none&#39;" html;
          contains ~sub:"script-src &#39;self&#39;" html;
          contains ~sub:"/static/app.js" html;
          contains ~sub:"id=\"composer\"" html;
          contains ~sub:"data-resume=\"3\"" html);
      test "a hostile session title is escaped in the shell" (fun () ->
          (* The shell legitimately carries its own [<script src>] chrome, so the
             fragment fuzz's blanket [</script>] ban does not apply; assert the
             title reaches the page only in escaped form and injects nothing. *)
          let html =
            Html.to_string
              (Page.session ~title:hostile ~session ~resume:None ~earlier:None
                 ~body:Html.El.void)
          in
          contains ~msg:html ~sub:"&lt;script&gt;alert(&#39;XSS&#39;)" html;
          not_contains ~sub:"<script>alert" html;
          not_contains ~sub:"onload=\"evil" html);
      test "the session index lists rows and the new-session form" (fun () ->
          let html =
            Html.to_string
              (Page.session_list
                 ~sessions:[ summary_of ~title:"Alpha" "sess-1" ]
                 ~unreadable:0)
          in
          contains ~msg:html ~sub:"/session/sess-1" html;
          contains ~sub:"Alpha" html;
          contains ~sub:"New session" html);
      test "unreadable store entries surface a notice" (fun () ->
          let html =
            Html.to_string (Page.session_list ~sessions:[] ~unreadable:2)
          in
          contains ~msg:html ~sub:"could not be read" html);
    ]

(* ── Routes ─────────────────────────────────────────────────────────────── *)

let route_tests =
  group "routes"
    [
      test "GET / renders the session list" (fun () ->
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.sessions =
                (fun ~listing:_ ->
                  Ok ([ summary_of ~title:"Alpha" "sess-1" ], []));
            }
          in
          let client = client_of ~lifecycle () in
          match
            Routes.handle (env_of client) ~meth:"GET" ~path:[] ~query:[]
              ~body:[]
          with
          | Routes.Html node -> contains ~sub:"Alpha" (Html.to_string node)
          | _ -> fail "expected an Html response");
      test "GET /session/<id> cold-loads transcript, live, and resume"
        (fun () ->
          let detail =
            Session_view.of_session
              (sample_session ~title:"My Session" "sess-1")
          in
          let facts =
            [
              (position 0, Fact.Turn_started (turn ()));
              (position 1, Fact.Turn_assistant (response "all done"));
              ( position 2,
                Fact.Turn_settled
                  {
                    turn = turn_id "turn-1";
                    outcome = Session.Turn.Outcome.completed;
                  } );
            ]
          in
          let view = tail_of facts (Some (position 2)) in
          let session_driver =
            {
              default_session with
              Driver.Session.tail = (fun ?n:_ _ -> Ok view);
            }
          in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.session = (fun _ -> Ok detail);
            }
          in
          let client = client_of ~session:session_driver ~lifecycle () in
          match
            Routes.handle (env_of client) ~meth:"GET"
              ~path:[ "session"; "sess-1" ] ~query:[] ~body:[]
          with
          | Routes.Html node ->
              let html = Html.to_string node in
              contains ~msg:html ~sub:"id=\"transcript\"" html;
              contains ~sub:"id=\"live\"" html;
              contains ~sub:"My Session" html;
              contains ~sub:"Refactor." html;
              contains ~sub:"data-resume=\"2\"" html
          | _ -> fail "expected an Html response");
      test "GET /session/<id>/before returns an earlier-page fragment"
        (fun () ->
          let facts = [ (position 0, Fact.Turn_started (turn ())) ] in
          let page = { Transcript.Page.facts; before = None } in
          let session_driver =
            {
              default_session with
              Driver.Session.page = (fun ?n:_ _ ~before:_ -> Ok page);
            }
          in
          let client = client_of ~session:session_driver () in
          match
            Routes.handle (env_of client) ~meth:"GET"
              ~path:[ "session"; "sess-1"; "before" ]
              ~query:[ ("p", [ "1" ]) ]
              ~body:[]
          with
          | Routes.Fragment nodes ->
              let html = html_of nodes in
              contains ~msg:html ~sub:"id=\"earlier\"" html;
              contains ~sub:"Refactor." html
          | _ -> fail "expected a Fragment response");
      test "POST prompt submits a client-minted turn and redirects" (fun () ->
          let submitted = ref None in
          let session_driver =
            {
              default_session with
              Driver.Session.submit =
                (fun command ->
                  submitted := Some command;
                  Ok ());
            }
          in
          let client = client_of ~session:session_driver () in
          (match
             Routes.handle (env_of client) ~meth:"POST"
               ~path:[ "session"; "sess-1"; "prompt" ]
               ~query:[]
               ~body:[ ("prompt", "hello there") ]
           with
          | Routes.Redirect target -> equal string "/session/sess-1" target
          | _ -> fail "expected a Redirect response");
          match !submitted with
          | Some (Command.Prompt { session = target; turn; _ }) ->
              is_true (Session.Id.equal session target);
              equal string "minted-turn" (Session.Turn.Id.to_string turn)
          | _ -> fail "expected a Prompt command");
      test "POST prompt with blank text is a bad request" (fun () ->
          let client = client_of () in
          match
            Routes.handle (env_of client) ~meth:"POST"
              ~path:[ "session"; "sess-1"; "prompt" ]
              ~query:[]
              ~body:[ ("prompt", "   ") ]
          with
          | Routes.Bad_request _ -> ()
          | _ -> fail "expected a Bad_request response");
      test "POST decision answers the pending decision" (fun () ->
          let request = question_request ~turn:(turn_id "turn-1") () in
          let submitted = ref None in
          let session_driver =
            {
              default_session with
              Driver.Session.pending_decision = (fun _ -> Ok (Some request));
              submit =
                (fun command ->
                  submitted := Some command;
                  Ok ());
            }
          in
          let client = client_of ~session:session_driver () in
          (match
             Routes.handle (env_of client) ~meth:"POST"
               ~path:[ "session"; "sess-1"; "decision"; "d1" ]
               ~query:[]
               ~body:[ ("answer", "free"); ("text", "yes") ]
           with
          | Routes.Redirect _ -> ()
          | _ -> fail "expected a Redirect response");
          match !submitted with
          | Some
              (Command.Answer_decision
                 { answer = Decision.Answer.Question _; _ }) ->
              ()
          | _ -> fail "expected an Answer_decision with a question answer");
      test "POST /sessions creates a session and redirects to it" (fun () ->
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.create = (fun ~id:_ ~title:_ -> Ok ());
            }
          in
          let client = client_of ~lifecycle () in
          match
            Routes.handle (env_of client) ~meth:"POST" ~path:[ "sessions" ]
              ~query:[] ~body:[]
          with
          | Routes.Redirect target -> equal string "/session/new-session" target
          | _ -> fail "expected a Redirect response");
      test "GET /static/app.js serves the script" (fun () ->
          let client = client_of () in
          match
            Routes.handle (env_of client) ~meth:"GET"
              ~path:[ "static"; "app.js" ] ~query:[] ~body:[]
          with
          | Routes.Asset { media_type; body } ->
              contains ~sub:"javascript" media_type;
              contains ~sub:"EventSource" body
          | _ -> fail "expected an Asset response");
      test "an unrouted path is Not_found" (fun () ->
          let client = client_of () in
          match
            Routes.handle (env_of client) ~meth:"GET" ~path:[ "nope" ] ~query:[]
              ~body:[]
          with
          | Routes.Not_found -> ()
          | _ -> fail "expected a Not_found response");
      test "the feed path is not served by handle" (fun () ->
          let client = client_of () in
          match
            Routes.handle (env_of client) ~meth:"GET"
              ~path:[ "session"; "sess-1"; "feed" ]
              ~query:[] ~body:[]
          with
          | Routes.Not_found -> ()
          | _ -> fail "expected a Not_found response");
      test "to_http maps responses to statuses" (fun () ->
          equal int 200 (http_status (Routes.Html Html.El.void));
          equal int 303 (http_status (Routes.Redirect "/"));
          equal int 404 (http_status Routes.Not_found);
          equal int 400 (http_status (Routes.Bad_request "x"));
          equal int 404
            (http_status
               (Routes.Failed (Protocol.Error.Session_not_found session))));
    ]

(* ── The live feed ──────────────────────────────────────────────────────── *)

let feed_tests =
  group "live feed"
    [
      test "committed facts stream as append frames with sequence ids"
        (fun () ->
          with_eio (fun sw ->
              let updates =
                [
                  Update.Committed
                    {
                      position = position 0;
                      fact = Fact.Turn_started (turn ());
                    };
                  Update.Progress
                    (pulse (turn_id "turn-1")
                       (Progress.Model.Assistant_delta { text = "streaming hi" }));
                  Update.Committed
                    {
                      position = position 1;
                      fact = Fact.Turn_assistant (response "all done");
                    };
                ]
              in
              let session_driver =
                {
                  default_session with
                  Driver.Session.follow =
                    (fun _ ~from:_ -> Ok (closing_seam updates));
                }
              in
              let client = client_of ~session:session_driver () in
              let frames = ref [] in
              let emit frame = frames := frame :: !frames in
              (match
                 Routes.feed (env_of client) ~sw ~session ~from:`Beginning ~emit
               with
              | Ok () -> ()
              | Error _ -> fail "the feed faulted unexpectedly");
              let frames = List.rev !frames in
              is_true ~msg:"the user article appends under its own sequence id"
                (List.exists
                   (fun f ->
                     frame_id f = Some 0
                     && has_sub ~needle:"msg user" (frame_html f))
                   frames);
              is_true ~msg:"the settled assistant appends as f-1"
                (List.exists
                   (fun f ->
                     frame_id f = Some 1 && has_sub ~needle:"f-1" (frame_html f))
                   frames);
              is_true ~msg:"a live morph re-renders the streaming region"
                (List.exists
                   (fun f ->
                     frame_id f = None
                     && has_sub ~needle:"streaming hi" (frame_html f))
                   frames)));
      test "resume gates emission but still rebuilds the accumulator" (fun () ->
          with_eio (fun sw ->
              let updates =
                [
                  Update.Committed
                    {
                      position = position 0;
                      fact = Fact.Turn_started (turn ());
                    };
                  Update.Progress
                    (pulse (turn_id "turn-1")
                       (Progress.Model.Assistant_delta { text = "after resume" }));
                  Update.Committed
                    {
                      position = position 1;
                      fact = Fact.Turn_assistant (response "all done");
                    };
                ]
              in
              let session_driver =
                {
                  default_session with
                  Driver.Session.follow =
                    (fun _ ~from:_ -> Ok (closing_seam updates));
                }
              in
              let client = client_of ~session:session_driver () in
              let frames = ref [] in
              let emit frame = frames := frame :: !frames in
              (match
                 Routes.feed (env_of client) ~sw ~session
                   ~from:(`After (position 0))
                   ~emit
               with
              | Ok () -> ()
              | Error _ -> fail "the feed faulted unexpectedly");
              let frames = List.rev !frames in
              is_false ~msg:"the pre-cursor user article is not re-emitted"
                (List.exists
                   (fun f -> has_sub ~needle:"msg user" (frame_html f))
                   frames);
              is_true
                ~msg:"the in-flight turn's progress applies after the rebuild"
                (List.exists
                   (fun f -> has_sub ~needle:"after resume" (frame_html f))
                   frames);
              is_true ~msg:"the post-cursor assistant is emitted"
                (List.exists (fun f -> frame_id f = Some 1) frames)));
      test "a firewall miss aborts the feed and renders nothing" (fun () ->
          with_eio (fun sw ->
              let assistant =
                Llm.Message.assistant (Llm.Message.Assistant.text "leak")
              in
              let updates =
                [
                  Update.Committed
                    {
                      position = position 0;
                      fact = Fact.Turn_started (turn ());
                    };
                  Update.Committed
                    {
                      position = position 1;
                      fact = Fact.Turn_message assistant;
                    };
                ]
              in
              let session_driver =
                {
                  default_session with
                  Driver.Session.follow =
                    (fun _ ~from:_ -> Ok (closing_seam updates));
                }
              in
              let client = client_of ~session:session_driver () in
              let frames = ref [] in
              let emit frame = frames := frame :: !frames in
              match
                Routes.feed (env_of client) ~sw ~session ~from:`Beginning ~emit
              with
              | Error (Routes.Render_fault Render.Error.Assistant_message) ->
                  is_false ~msg:"the faulty fragment was never emitted"
                    (List.exists
                       (fun f -> has_sub ~needle:"leak" (frame_html f))
                       !frames)
              | Error _ -> fail "expected the assistant firewall fault"
              | Ok () -> fail "expected the feed to abort"));
    ]

let () =
  run "mentat_web"
    [
      escaping_tests;
      turn_family_tests;
      tool_family_tests;
      decision_family_tests;
      journal_family_tests;
      progress_tests;
      cold_tests;
      windowed_tests;
      fuzz_tests;
      page_tests;
      route_tests;
      feed_tests;
    ]
