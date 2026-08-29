(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The TUI steward (RFC 0027): /goal declares standing intent and arms the
   continue-at-finished loop; the continuation is a framed prompt turn whose
   goal_status claim decides the next move; a standing goal found at attach
   is offered, never auto-spent. The decision table itself is unit-pinned in
   the session suite — these frames are the wiring proof. *)

open Tui_harness
module Session = Mentat_session
module Llm = Mentat_llm
module Json = Jsont.Json

let home_is_project project =
  Some (Lpath.Abs.of_string_exn (Project.root project))

let submit t text =
  Tui.paste t text;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider ~api ~id:"gpt-5.5"

let contract =
  Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
    ~declarations:[] ~policy:Mentat_permission.Policy.default
    ~review:Mentat_permission.Review_behavior.Enforce
    ~sandbox:(Mentat_sandbox.identity Mentat_sandbox.direct)
    ()

let time seconds =
  seconds |> Int64.of_int |> Int64.mul 1_000L |> Session.Time.of_unix_ms

let status ?note s =
  Json.object'
    (Json.mem (Json.name "status") (Json.string s)
    ::
    (match note with
    | None -> []
    | Some note -> [ Json.mem (Json.name "note") (Json.string note) ]))

(* One scripted continuation turn: the framed prompt, a structured_output
   claim, and a short closing text. *)
let continuation_turn ~objective ~claim text =
  let tool =
    Tui.Turn_script.tool
      ~call:
        (Llm.Tool.Call.make ~id:"goal-claim" ~name:"structured_output"
           ~input:claim ())
      ~result:
        (Mentat_tool.Result.completed
           ~output:
             (Mentat_tool.Output.make ~text:"goal_status recorded" ~json:claim
                ())
           ())
  in
  Tui.Turn_script.complete
    ~prompt:(Session.Metadata.Goal.continuation ~objective)
    ~tools:[ tool ] text

let%expect_test "a declared goal continues at finished and stops at done" =
  let objective = "make the fixture green" in
  let first =
    Tui.Turn_script.complete ~prompt:"start on the fixture"
      "The fixture needs one more pass."
  in
  let continuation =
    continuation_turn ~objective
      ~claim:(status ~note:"all green" "done")
      "Everything passes now."
  in
  Tui.run ~name:"goal-declare" ~home:home_is_project
    ~turns:[ first; continuation ]
  @@ fun t ->
  submit t "start on the fixture";
  Tui.finish_turn t;
  Tui.settle t;
  submit t "/goal make the fixture green --max-turns 3";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 | ⏺ The fixture needs one more pass.
    02 |
    03 |   ● goal declared: make the fixture green
    04 |
    05 |   ● goal recorded in the session document
    06 |
    07 | ❯ Continuing toward the goal: make the fixture green
    08 |
    09 |   Keep working toward it. End this turn by declaring goal_status: status "done"
    10 |   only when the goal is genuinely reached, otherwise "continuing" with a one-
    11 |   line note on what remains.
    12 |
    13 | ⏺ Structured_output
    14 |   ⎿  done
    15 |       goal_status recorded
    16 |
    17 | ⏺ Everything passes now.
    18 |
    19 |   ● goal declared done: all green
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~ · openai/gpt-5.5 · ! full access ? for shortcu…
    |}]

(* A goal recorded on the session document by another steward: opening the
   session offers the standing goal, /goal resume re-arms it, the counter
   derives from the replayed framed turns, and the recorded bound stops the
   loop with the honest notice. /goal stop then retires the intent. *)
let%expect_test "a standing goal offers, re-arms, and stops at its bound" =
  let objective = "tidy the docs" in
  let goal =
    Session.Metadata.Goal.make ~objective ~max_turns:1 ()
  in
  let standing_id = Session.Id.of_string "session-standing-goal" in
  let standing project =
    let cwd = Lpath.Abs.of_string_exn (Project.root project) in
    let turn =
      Session.Turn.make
        ~id:(Session.Turn.Id.of_string "standing-turn")
        ~origin:Session.Turn.Origin.User
        ~input:(Session.Turn.Input.user_text "start on the docs")
        ~max_steps:100 ~contract ()
    in
    let session =
      Session.create ~id:standing_id ~title:"Docs tidy" ~goal ~cwd
        ~created_at:(time 1) ()
    in
    match
      Session.append_all
        [
          Session.Event.turn_started turn;
          Session.Event.turn_finished ~turn:(Session.Turn.id turn)
            Session.Turn.Outcome.completed;
        ]
        session
    with
    | Ok session -> session
    | Error error -> failwith (Session.Error.message error)
  in
  let continuation =
    continuation_turn ~objective
      ~claim:(status ~note:"one section left" "continuing")
      "Tidied the first section."
  in
  Tui.run ~name:"goal-standing" ~home:home_is_project ~session:standing_id
    ~sessions:(fun project -> [ standing project ])
    ~turns:[ continuation ]
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
    04 |
    05 |   ● a goal stands: tidy the docs — /goal resume re-arms it
    06 |
    07 | ❯ start on the docs
    08 |
    09 |
    10 |
    11 |
    12 |
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |
    19 |
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~ · openai/gpt-5.5 · ! full access ? for shortcu…
    |}];
  submit t "/goal resume";
  Tui.finish_turn t;
  Tui.settle t;
  submit t "/goal stop";
  Tui.print t;
  [%expect {|
    01 |
    02 | ❯ Continuing toward the goal: tidy the docs
    03 |
    04 |   Keep working toward it. End this turn by declaring goal_status: status "done"
    05 |   only when the goal is genuinely reached, otherwise "continuing" with a one-
    06 |   line note on what remains.
    07 |
    08 | ⏺ Structured_output
    09 |   ⎿  done
    10 |       goal_status recorded
    11 |
    12 | ⏺ Tidied the first section.
    13 |
    14 |   ● goal stopped: the turn bound (1) is spent — /goal with a higher --max-turns
    15 | re-arms it
    16 |
    17 |   ● goal stopped
    18 |
    19 |   ● goal retired from the session document
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~ · openai/gpt-5.5 · ! full access ? for shortcu…
    |}]

(* A failed continuation is machinery, never a declaration: the loop stops
   loudly with the re-arm affordance instead of burning the bound on
   repeats. *)
let%expect_test "a failed continuation stops the loop loudly" =
  let objective = "chase the flake" in
  let first =
    Tui.Turn_script.complete ~prompt:"look at the flake"
      "The flake reproduces sometimes."
  in
  let failing =
    Tui.Turn_script.fail
      ~prompt:(Session.Metadata.Goal.continuation ~objective)
      (Llm.Error.make ~kind:Llm.Error.Transport ~provider ~status:500
         "provider melted")
  in
  Tui.run ~name:"goal-failed" ~home:home_is_project ~turns:[ first; failing ]
  @@ fun t ->
  submit t "look at the flake";
  Tui.finish_turn t;
  Tui.settle t;
  submit t "/goal chase the flake";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 | ❯ look at the flake
    02 |
    03 | ⏺ The flake reproduces sometimes.
    04 |
    05 |   ● goal declared: chase the flake
    06 |
    07 |   ● goal recorded in the session document
    08 |
    09 | ❯ Continuing toward the goal: chase the flake
    10 |
    11 |   Keep working toward it. End this turn by declaring goal_status: status "done"
    12 |   only when the goal is genuinely reached, otherwise "continuing" with a one-
    13 |   line note on what remains.
    14 |
    15 | ✗ provider melted
    16 |   Tell mentat how to proceed.
    17 |
    18 |   ● goal stopped: the last turn failed — /goal resume re-arms it once the cause
    19 | is addressed
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~ · openai/gpt-5.5 · ! full access ? for shortcu…
    |}]

let%expect_test "the declaration grammar refuses a bad bound in place" =
  let plain_id = Session.Id.of_string "session-plain" in
  let plain project =
    let cwd = Lpath.Abs.of_string_exn (Project.root project) in
    let turn =
      Session.Turn.make
        ~id:(Session.Turn.Id.of_string "plain-turn")
        ~origin:Session.Turn.Origin.User
        ~input:(Session.Turn.Input.user_text "look around")
        ~max_steps:100 ~contract ()
    in
    let session =
      Session.create ~id:plain_id ~title:"Plain" ~cwd ~created_at:(time 1) ()
    in
    match
      Session.append_all
        [
          Session.Event.turn_started turn;
          Session.Event.turn_finished ~turn:(Session.Turn.id turn)
            Session.Turn.Outcome.completed;
        ]
        session
    with
    | Ok session -> session
    | Error error -> failwith (Session.Error.message error)
  in
  Tui.run ~name:"goal-grammar" ~home:home_is_project ~session:plain_id
    ~sessions:(fun project -> [ plain project ])
    ~turns:[]
  @@ fun t ->
  Tui.settle t;
  submit t "/goal tidy up --max-turns 0";
  Tui.print t;
  [%expect {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
    04 |
    05 | ❯ look around
    06 |
    07 |
    08 |
    09 |
    10 |
    11 |
    12 |
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |
    19 |
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   --max-turns takes a positive count
    |}]
