(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness
module Session = Mentat_session

let provider = Mentat_llm.Provider.make "openai"
let api = Mentat_llm.Model.Api.make "responses"
let model = Mentat_llm.Model.make ~provider ~api ~id:"gpt-5.5"

let contract =
  Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
    ~declarations:[] ~policy:Mentat_permission.Policy.default
    ~review:Mentat_permission.Review_behavior.Enforce
    ~sandbox:(Mentat_sandbox.identity Mentat_sandbox.direct)
    ()

let time seconds =
  seconds |> Int64.of_int |> Int64.mul 1_000L |> Session.Time.of_unix_ms

let adversarial_snapshot project ~trusted =
  let cwd = Lpath.Abs.of_string_exn (Project.root project) in
  let home =
    Lpath.Abs.of_string_exn (Filename.dirname (Project.root project))
  in
  Mentat_tui.Snapshot.make ~version:"v\255\027\n2" ~model:" \t\n"
    ~effort:(Some "\r ") ~cwd ~home:(Some home) ~context_window:(Some 0)
    ~sandbox:(Some "\027danger\nfull") ~trusted

let session ?title ?forked_from ?delegated_from ~id ?prompt ~updated_at project
    =
  let id = Session.Id.of_string id in
  let metadata =
    Session.Metadata.make ?title ?forked_from ?delegated_from
      ~cwd:(Lpath.Abs.of_string_exn (Project.root project))
      ~created_at:(time 1) ~updated_at:(time updated_at) ()
  in
  let events =
    match prompt with
    | None -> []
    | Some prompt ->
        let turn =
          Session.Turn.make
            ~id:(Session.Turn.Id.of_string "turn-1")
            ~origin:Session.Turn.Origin.User
            ~input:(Session.Turn.Input.user_text prompt)
            ~max_steps:100 ~contract ()
        in
        [
          Session.Event.turn_started turn;
          Session.Event.turn_finished ~turn:(Session.Turn.id turn)
            Session.Turn.Outcome.completed;
        ]
  in
  match Session.make ~id ~metadata ~events with
  | Ok session -> session
  | Error error -> failwith (Session.Error.message error)

(* Every assertion below is the complete terminal at its declared geometry.
   Readiness checks may inspect [Tui.screen], but the expectation itself always
   goes through [Tui.print], so rows cannot silently disappear from visual
   review. *)

let%expect_test "home boots to a stable complete frame" =
  Tui.run ~name:"home-boot" @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/men… · openai/gpt-5.5 m… · ! full access ? for…
    |}]

let%expect_test "snapshot normalizes all external display facts" =
  Tui.run ~name:"snapshot-boundary" ~snapshot:adversarial_snapshot @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            v�� 2 · [model unavailable]
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/mentat-tui-snap… · [model unavailab… ? for sho…
    |}];
  Tui.keys t "/status";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── 1 providers
    02 |
    03 | config  status  usage
    04 |
    05 | Runtime
    06 |   version         v�� 2
    07 |   current model   [model unavailable]
    08 |   workspace       ~/mentat-tui-snapshot-1d2d2f92
    09 |   context window  —
    10 |   launch sandbox  �danger full
    11 |
    12 | Session
    13 |   No active session.
    14 |
    15 | Providers
    16 |   openai  missing
    17 |
    18 |
    19 |
    20 |
    21 |
    22 |
    23 |
    24 |   tab page · esc back
    |}]

let%expect_test "typing lands in the home composer" =
  Tui.run ~name:"home-typing" @@ fun t ->
  Tui.settle t;
  Tui.keys t "hello mentat";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ hello mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/ment… · openai/gpt-5.5 m… · ! full access ? fo…
    |}]

let%expect_test "a recent session renders its title and owner metadata" =
  Tui.run ~name:"home-title" ~sessions:(fun project ->
      [
        session ~id:"ses_titled" ~title:"Parser refactor spike"
          ~prompt:"spike it" ~updated_at:1000 project;
      ])
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                   ↵ "Parser refactor spike" · just now · 1 turn
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/men… · openai/gpt-5.5 me… · ! full acce… ? for…
    |}]

let%expect_test "an untitled recent session falls back to its first prompt" =
  Tui.run ~name:"home-preview" ~sessions:(fun project ->
      [
        session ~id:"ses_untitled" ~prompt:"reproduce the parser crash"
          ~updated_at:1000 project;
      ])
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                ↵ "reproduce the parser crash" · just now · 1 turn
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/ment… · openai/gpt-5.5 m… · ! full access ? fo…
    |}]

let%expect_test "delegated child sessions do not replace the parent recent" =
  Tui.run ~name:"home-child" ~sessions:(fun project ->
      let parent =
        session ~id:"ses_main" ~title:"Main investigation" ~prompt:"investigate"
          ~updated_at:999 project
      in
      let delegated_from =
        Session.Metadata.Delegated_from.make
          ~parent:(Session.Id.of_string "ses_main")
          ~delegation:(Session.Delegation.Id.of_string "delegation-1")
      in
      let child =
        session ~id:"ses_sub" ~title:"subagent explore: survey" ~prompt:"survey"
          ~delegated_from ~updated_at:1000 project
      in
      [ parent; child ])
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                    ↵ "Main investigation" · just now · 1 turn
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/men… · openai/gpt-5.5 me… · ! full acce… ? for…
    |}]

let%expect_test
    "more than five newer child sessions do not hide a top-level recent" =
  Tui.run ~name:"home-eligibility-before-limit" ~sessions:(fun project ->
      let parent_id = Session.Id.of_string "ses_resumable" in
      let parent =
        session ~id:"ses_resumable" ~title:"Resume the top-level work"
          ~prompt:"continue the investigation" ~updated_at:1000 project
      in
      let fork index =
        let forked_from =
          Session.Metadata.Forked_from.make ~parent:parent_id ~copied_events:0
        in
        session
          ~id:(Printf.sprintf "ses_fork_%d" index)
          ~title:(Printf.sprintf "Fork child %d" index)
          ~forked_from ~updated_at:(1000 + index) project
      in
      let delegated index =
        let delegated_from =
          Session.Metadata.Delegated_from.make ~parent:parent_id
            ~delegation:
              (Session.Delegation.Id.of_string
                 (Printf.sprintf "delegation-%d" index))
        in
        session
          ~id:(Printf.sprintf "ses_delegated_%d" index)
          ~title:(Printf.sprintf "Delegated child %d" index)
          ~delegated_from ~updated_at:(1003 + index) project
      in
      (parent :: List.init 3 (fun index -> fork (index + 1)))
      @ List.init 3 (fun index -> delegated (index + 1)))
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                 ↵ "Resume the top-level work" · just now · 1 turn
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-5.5 … · ! full access ? f…
    |}]

let%expect_test "enter on an empty home draft resumes the newest session" =
  Tui.run ~name:"home-resume" ~sessions:(fun project ->
      [
        session ~id:"ses_recent" ~title:"Parser refactor spike"
          ~prompt:"spike it" ~updated_at:1000 project;
      ])
  @@ fun t ->
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-homa2cd4116
    04 |
    05 | ❯ spike it
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
    24 |   ! not logged in · /login · ~/mentat-… · openai/gpt-… · ! full access ? for …
    |}]

let%expect_test
    "partial session listings retain every warning and keep rows interactive" =
  (* The first diagnostic carries a multi-line decoder-trace context, as a
     real store corruption does; the unchanged golden proves the stage renders
     only each diagnostic's head line. *)
  let diagnostics =
    [
      Mentat_diagnostic.make
        ~context:
          "sessions/ses_corrupt/session.json\n\
           File \"-\": in member notice of workspace-notice event object"
        "first corrupt session";
      Mentat_diagnostic.make "second corrupt session";
    ]
  in
  Tui.run ~name:"home-partial-sessions" ~size:(120, 24)
    ~sessions:(fun project ->
      [
        session ~id:"ses_healthy" ~title:"Healthy retained session"
          ~prompt:"healthy transcript" ~updated_at:1000 project;
      ])
    ~session_diagnostics:diagnostics
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                                               █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                                               █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                                                dev · openai/gpt-5.5 medium
    09 |
    10 |                          ▎ welcome — and thanks for trying mentat this early.
    11 |                          ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 |           ────────────────────────────────────────────────────────────────────────────────────────────────────
    15 |           ❯ message mentat
    16 |           ────────────────────────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                                              ! /login — no connected account
    19 |                                     ! first corrupt session · second corrupt session
    20 |                                     ↵ "Healthy retained session" · just now · 1 turn
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/mentat-tui-home-partial-4d1d1a… · openai/gpt-5.5 medium · ! full access ? for shortcuts
    |}];

  Tui.keys t "/sessions";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                                               █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                                               █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                                                dev · openai/gpt-5.5 medium
    09 |
    10 |                          ▎ welcome — and thanks for trying mentat this early.
    11 |                          ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 |
    15 |
    16 |
    17 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
    18 |    sessions
    19 |
    20 |   ! first corrupt session · second corrupt session
    21 |  ❯   Healthy retained session                                                                         idle     just now
    22 |
    23 |
    24 |
    |}];

  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-home-partial-4d1d1a3d
    04 |
    05 | ❯ healthy transcript
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
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-home-partial-4d1d1a3d · openai/gpt-5.5 · ! full access       ? for shortcuts
    |}]

let rec advance_until t ~marker remaining =
  if Screen.contains (Tui.screen t) marker then ()
  else if remaining = 0 then failwith "home animation marker was never rendered"
  else begin
    Tui.advance t 0.1;
    advance_until t ~marker (remaining - 1)
  end

let pouring_row = "█ █ █▄▄ █ █  █  █▀█  █   ▂▄▂"

let resting_row = "█ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂"

let%expect_test "home animation advances and freezes on the first keystroke" =
  Tui.run ~name:"home-motion" ~reduced_motion:false @@ fun t ->
  Tui.settle t;
  advance_until t ~marker:pouring_row 30;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀
    06 |                           █ █ █▄▄ █ █  █  █▀█  █   ▂▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/ment… · openai/gpt-5.5 m… · ! full access ? fo…
    |}];
  advance_until t ~marker:resting_row 30;
  advance_until t ~marker:pouring_row 30;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀
    06 |                           █ █ █▄▄ █ █  █  █▀█  █   ▂▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/ment… · openai/gpt-5.5 m… · ! full access ? fo…
    |}];
  Tui.keys t "x";
  Tui.settle t;
  Tui.advance t 1.;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ x
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/ment… · openai/gpt-5.5 m… · ! full access ? fo…
    |}]

let%expect_test "reduced motion keeps the complete home frame static" =
  Tui.run ~name:"home-reduced-motion" @@ fun t ->
  Tui.settle t;
  Tui.advance t 1.;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/menta… · openai/gpt-5.5 … · ! full access ? fo…
    |}]

let%expect_test "Mosaic truncates the full model line in a narrow terminal" =
  Tui.run ~name:"home-narrow" ~size:(40, 12) @@ fun t ->
  Tui.resize t ~width:40 ~height:12;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |       █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    02 |
    03 |        dev · openai/gpt-5.5 medium
    04 |
    05 |
    06 |
    07 | ────────────────────────────────────────
    08 | ❯ message mentat
    09 | ────────────────────────────────────────
    10 |
    11 |      ! /login — no connected account
    12 |   ! not logged in · /l… · ! full acc…
    |}]

let%expect_test "a wide footer shows the full provider and model" =
  Tui.run ~name:"home-model-wide" ~size:(160, 24) ~home:(fun project ->
      Some (Lpath.Abs.of_string_exn (Project.root project)))
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                                                                   █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                                                                   █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                                                                    dev · openai/gpt-5.5 medium
    09 |
    10 |                                              ▎ welcome — and thanks for trying mentat this early.
    11 |                                              ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 |                               ────────────────────────────────────────────────────────────────────────────────────────────────────
    15 |                               ❯ message mentat
    16 |                               ────────────────────────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                                                                  ! /login — no connected account
    19 |                                                                       ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~ · openai/gpt-5.5 medium · ! full access                                                                         ? for shortcuts
    |}]

let%expect_test "path spelling follows the injected home boundary" =
  Tui.run ~name:"home-injected-equal" ~home:(fun project ->
      Some (Lpath.Abs.of_string_exn (Project.root project)))
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login ·… · openai/gpt-5.5 med… · ! full access ? for sho…
    |}];

  Tui.run ~name:"home-injected-child" ~home:(fun project ->
      Some (Lpath.Abs.of_string_exn (Filename.dirname (Project.root project))))
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying mentat this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ message mentat
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/menta… · openai/gpt-5.5 … · ! full access ? fo…
    |}];

  Tui.run ~name:"home-injected-outside" ~size:(120, 24) ~home:(fun project ->
      Some (Lpath.Abs.of_string_exn (Project.scratch project "unrelated-home")))
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                                               █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                                               █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                                                dev · openai/gpt-5.5 medium
    09 |
    10 |                          ▎ welcome — and thanks for trying mentat this early.
    11 |                          ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 |           ────────────────────────────────────────────────────────────────────────────────────────────────────
    15 |           ❯ message mentat
    16 |           ────────────────────────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                                              ! /login — no connected account
    19 |                                                   ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · /tmp/mentat-tui-home-injectedcd880cdc.hom… · openai/gpt-5.5 me… · ! full access ? for sh…
    |}]

let%expect_test "the absolute root is a valid injected home ancestor" =
  Tui.run ~name:"home-injected-root" ~size:(160, 24) ~home:(fun _ ->
      Some Lpath.Abs.root)
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                                                                   █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                                                                   █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                                                                    dev · openai/gpt-5.5 medium
    09 |
    10 |                                              ▎ welcome — and thanks for trying mentat this early.
    11 |                                              ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 |                               ────────────────────────────────────────────────────────────────────────────────────────────────────
    15 |                               ❯ message mentat
    16 |                               ────────────────────────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                                                                  ! /login — no connected account
    19 |                                                                       ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~$TESTCASE_ROOT · openai/gpt-5.5 medium · ! full access    ? for shortcuts
    |}]

(* Theme palette threading: a user theme recolours the accent role,
   and that resolved colour must reach the frame's bytes — the brand lockup and
   the composer cursor both render in the accent. Overriding only [accent] to a
   distinctive hue makes it appear in the home frame's truecolor ANSI, proving a
   custom palette threads end to end onto an accent surface. *)
let themed_palette accent_hex =
  let source = Printf.sprintf {|{"accent":%S}|} accent_hex in
  match Jsont_bytesrw.decode_string Jsont.json source with
  | Error message -> failwith ("themed_palette: " ^ message)
  | Ok json -> (
      match
        Mentat_tui.Theme.Palette.of_json ~base:Mentat_tui.Theme.Palette.default
          json
      with
      | palette, [] -> palette
      | _, diagnostic :: _ ->
          failwith
            ("themed_palette: "
            ^ Mentat_tui.Theme.Palette.Diagnostic.message diagnostic))

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec loop i =
    i + nl <= hl
    && (String.equal (String.sub haystack i nl) needle || loop (i + 1))
  in
  nl = 0 || loop 0

let%expect_test "a user theme's accent colour reaches the home frame" =
  Tui.run ~name:"home-theme-accent" ~palette:(themed_palette "#00e5ff")
    (fun t ->
      Tui.settle t;
      let ansi = Tui.screen_ansi t in
      Printf.printf "themed accent present: %b\n"
        (contains ~needle:"38;2;0;229;255" ansi));
  [%expect {| themed accent present: true |}]

(* A draft that wraps inside the 60-column composer inset must grow the
   composer and push the facts below it down — never paint the resume hint
   over the composer's bottom rule. The wide terminal makes the wrap width
   (inset) differ from the terminal width, the regression's trigger. *)
let%expect_test "a wrapping draft grows the home composer without overlap" =
  Tui.run ~name:"home-grown-composer" ~size:(140, 24) ~sessions:(fun project ->
      [
        session ~id:"ses_recent" ~title:"Hello world" ~prompt:"hi"
          ~updated_at:1000 project;
      ])
  @@ fun t ->
  Tui.settle t;
  Tui.keys t
    "this long draft wraps across the sixty column home inset and must push \
     the resume hint down instead of overlapping it";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                                                         █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                                                         █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                                                          dev · openai/gpt-5.5 medium
    09 |
    10 |                                    ▎ welcome — and thanks for trying mentat this early.
    11 |                                    ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 |                     ────────────────────────────────────────────────────────────────────────────────────────────────────
    15 |                     ❯ this long draft wraps across the sixty column home inset and must push the resume hint down
    16 |                       instead of overlapping it
    17 |                     ────────────────────────────────────────────────────────────────────────────────────────────────────
    18 |
    19 |                                                        ! /login — no connected account
    20 |                                                      ↵ "Hello world" · just now · 1 turn
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/mentat-tui-home-grown-3073938c · openai/gpt-5.5 medium · ! full access                      ? for shortcuts
    |}]
