(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

let submit t prompt =
  Tui.settle t;
  Tui.keys t prompt;
  Tui.enter t;
  Tui.settle t

(* These are complete terminal frames, never component crops. The script holds
   the provider settlement at App's typed command/fact boundary so the visual
   state remains deterministic while the real App, Mosaic, and Matrix render. *)

let%expect_test "a held turn ticks, then settles into durable transcript" =
  let turn =
    Tui.Turn_script.complete ~prompt:"say hello"
      "Hello from the scripted provider."
  in
  Tui.run ~name:"t" ~turns:[ turn ] @@ fun t ->
  submit t "say hello";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ say hello
    06 |
    07 | ⠋ Working… (0s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}];
  Tui.advance t 5.;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ say hello
    06 |
    07 | ⠋ Working… (5s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ say hello
    06 |
    07 | ⏺ Hello from the scripted provider.
    08 |
    09 |   Worked for 5s
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
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

(* An overloaded provider is outlasted by the adapter's announced retries. The
   working line must show the failure class, the attempt counter against its
   budget, and the wait before the next attempt — never an opaque "Working…"
   that reads as a hang. *)
let%expect_test "a retrying turn shows the announced wait in the working line" =
  let turn =
    Tui.Turn_script.complete ~prompt:"say hello"
      ~retries:
        [
          Mentat_llm.Event.Retry.make ~attempt:3 ~limit:10 ~delay:8.
            ~reason:"provider overloaded" ();
        ]
      "Hello from the scripted provider."
  in
  Tui.run ~name:"retrying" ~turns:[ turn ] @@ fun t ->
  submit t "say hello";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-e9d634ba
    04 |
    05 | ❯ say hello
    06 |
    07 | ⠋ Provider overloaded — retry 3/10… (0s · next attempt in 8s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}];
  (* The wait is live: five seconds later the same announcement counts down. *)
  Tui.advance t 5.;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-e9d634ba
    04 |
    05 | ❯ say hello
    06 |
    07 | ⠋ Provider overloaded — retry 3/10… (5s · next attempt in 3s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-e9d634ba
    04 |
    05 | ❯ say hello
    06 |
    07 | ⏺ Hello from the scripted provider.
    08 |
    09 |   Worked for 5s
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
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

(* A step that generates tool calls streams no prose — only tool-input pulses.
   The working line must name the tool being written and the input's byte
   count rather than an opaque "Working…" that reads as a hang; each pulse
   carries the whole count, so the latest alone is rendered. *)
let%expect_test "a tool-writing turn names the tool in the working line" =
  let turn =
    Tui.Turn_script.complete ~prompt:"edit the file"
      ~tool_inputs:[ (None, 213); (Some "edit_file", 4096) ]
      "Edited."
  in
  Tui.run ~name:"writing" ~turns:[ turn ] @@ fun t ->
  submit t "edit the file";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-6c5c2486
    04 |
    05 | ❯ edit the file
    06 |
    07 | ⠋ Writing edit_file… (0s · 4.0 KB · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-6c5c2486
    04 |
    05 | ❯ edit the file
    06 |
    07 | ⏺ Edited.
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
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

(* A local model auto-downloads its weights on first use, inside the turn's
   first provider call. The working line must name the artifact and its byte
   progress rather than an opaque "Working…", and the interrupt affordance is
   honest because the same cancel flag reaches the in-flight fetch. *)
let%expect_test "a downloading turn shows artifact progress in the working line"
    =
  let turn =
    Tui.Turn_script.complete ~prompt:"say hello"
      ~downloads:
        [
          {
            Mentat_protocol.Progress.Model_download.model = "gpt-oss-20b";
            received = 1_200_000_000L;
            total = Some 12_109_566_624L;
            phase = Mentat_protocol.Progress.Model_download.Downloading;
          };
        ]
      "Hello from the scripted provider."
  in
  Tui.run ~name:"download" ~turns:[ turn ] @@ fun t ->
  submit t "say hello";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-dcc50273
    04 |
    05 | ❯ say hello
    06 |
    07 | ⠋ Downloading gpt-oss-20b… (0s · 1.2 / 12.1 GB (10%) · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-dcc50273
    04 |
    05 | ❯ say hello
    06 |
    07 | ⏺ Hello from the scripted provider.
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
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

let session_notice ~source ~severity ~title ?body () =
  Mentat_session.Notice.make ~source ~severity ~title ?body ()

let%expect_test "one durable block per observation, mid-turn and after" =
  (* The live-tail pulse glance is gone from the wire: the durable
     transcript block lands the moment the fact arrives, renders once, in
     place, and survives settlement. The mid-turn frame is the point — a
     reintroduced second rendering would show here beside the block. *)
  let turn =
    Tui.Turn_script.complete ~prompt:"inspect workspace health"
      ~notices:
        [
          session_notice ~source:"dune"
            ~severity:Mentat_session.Notice.Severity.Info
            ~title:"Build is healthy" ~body:"No diagnostics remain." ();
        ]
      "Workspace inspection is complete."
  in
  Tui.run ~name:"t" ~turns:[ turn ] @@ fun t ->
  submit t "inspect workspace health";
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ inspect workspace health
    06 |
    07 | ⊙ dune — Build is healthy
    08 |   No diagnostics remain.
    09 |
    10 | ⠋ Working… (0s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ inspect workspace health
    06 |
    07 | ⊙ dune — Build is healthy
    08 |   No diagnostics remain.
    09 |
    10 | ⏺ Workspace inspection is complete.
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
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

(* The exact two shapes bin/workspace_notices.ml emits: [failing_notice]
   carries the count-titled header and the head Dune diagnostic as its
   body; [recovered_notice] is a bodyless Info header. Durable blocks are
   history: the recovery renders below the failure it answers; nothing
   replaces in place. *)
let%expect_test
    "dune build-health failing and recovery notices render their shapes" =
  let failing =
    Tui.Turn_script.complete ~prompt:"trigger the build check"
      ~notices:
        [
          session_notice ~source:"dune"
            ~severity:Mentat_session.Notice.Severity.Error
            ~title:"Build failing (1 diagnostic)"
            ~body:
              "This expression has type string but an expression was \
               expected of type int"
            ();
        ]
      "Build health noted."
  in
  let recovered =
    Tui.Turn_script.complete ~prompt:"and now"
      ~notices:
        [
          session_notice ~source:"dune"
            ~severity:Mentat_session.Notice.Severity.Info ~title:"Build recovered"
            ();
        ]
      "Recovered."
  in
  Tui.run ~name:"t" ~turns:[ failing; recovered ] @@ fun t ->
  submit t "trigger the build check";
  Tui.finish_turn t;
  Tui.settle t;
  submit t "and now";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ trigger the build check
    06 |
    07 | ✗ dune — Build failing (1 diagnostic)
    08 |   This expression has type string but an expression was expected of type int
    09 |
    10 | ⏺ Build health noted.
    11 |
    12 | ❯ and now
    13 |
    14 | ⊙ dune — Build recovered
    15 |
    16 | ⏺ Recovered.
    17 |
    18 |
    19 |
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

let%expect_test
    "a durable workspace notice renders its full body in the transcript" =
  let notice =
    Mentat_session.Notice.make ~source:"dune"
      ~severity:Mentat_session.Notice.Severity.Error
      ~title:"Build failing (2 diagnostics)"
      ~body:
        "lib/a.ml:1:3-1:6: Error: Unbound value foo\n\
         lib/b.ml:9:2-9:8: Error: This expression has type string but an \
         expression was expected of type int"
      ()
  in
  let turn =
    Tui.Turn_script.complete ~prompt:"check the build" ~notices:[ notice ]
      "Build health noted."
  in
  Tui.run ~name:"t" ~turns:[ turn ] @@ fun t ->
  submit t "check the build";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ check the build
    06 |
    07 | ✗ dune — Build failing (2 diagnostics)
    08 |   lib/a.ml:1:3-1:6: Error: Unbound value foo
    09 |   lib/b.ml:9:2-9:8: Error: This expression has type string but an expression
    10 |   was expected of type int
    11 |
    12 | ⠋ Working… (0s · esc to interrupt)
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |
    19 |
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

let narrow_prompt =
  "Explain why this deliberately long prompt must wrap without Mentat choosing \
   terminal columns itself."

let narrow_reply =
  "Mosaic owns the available width, wraps this assistant response across the \
   narrow transcript, and keeps the complete application frame inspectable."

let%expect_test "streaming and settlement wrap in a narrow complete screen" =
  let turn =
    Tui.Turn_script.complete ~prompt:narrow_prompt
      ~assistant_deltas:
        [
          "Mosaic owns the available width, wraps this ";
          "assistant response across the narrow transcript";
        ]
      narrow_reply
  in
  Tui.run ~name:"t" ~size:(44, 22) ~turns:[ turn ] @@ fun t ->
  submit t narrow_prompt;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    04 |  dev · openai/gpt-5.5 medium
    05 |  ~/mentat-tui-553b9dad
    06 |
    07 | ❯ Explain why this deliberately long prompt
    08 |   must wrap without Mentat choosing
    09 |   terminal columns itself.
    10 |
    11 | ⏺ Mosaic owns the available width, wraps
    12 |   this assistant response across the narrow
    13 |   transcript
    14 |
    15 | ⠋ Working… (0s · esc to interrupt)
    16 |
    17 |
    18 |
    19 | ────────────────────────────────────────────
    20 | ❯ queue a message — sends after this turn
    21 | ────────────────────────────────────────────
    22 |   ! not logged in · /log…… · ! full acce…
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    04 |  dev · openai/gpt-5.5 medium
    05 |  ~/mentat-tui-553b9dad
    06 |
    07 | ❯ Explain why this deliberately long prompt
    08 |   must wrap without Mentat choosing
    09 |   terminal columns itself.
    10 |
    11 | ⏺ Mosaic owns the available width, wraps
    12 |   this assistant response across the narrow
    13 |   transcript, and keeps the complete
    14 |   application frame inspectable.
    15 |
    16 |
    17 |
    18 |
    19 | ────────────────────────────────────────────
    20 | ❯ message mentat
    21 | ────────────────────────────────────────────
    22 |   ! not logged in · /log…… · ! full acce…
    |}]

let reasoning =
  [
    "First inspect the durable input and identify the visible invariant.\n";
    "Then compare the intrinsic layout at both widths without predicting any \
     row count.\n";
    "Finally preserve the user's complete frame so clipped or displaced UI is \
     obvious.\n";
    "The fourth line proves the collapsed viewport stays anchored to the live \
     tail.";
  ]

let%expect_test "reasoning has collapsed and expanded whole-screen views" =
  let usage = Mentat_llm.Usage.make ~input:120 ~output:18 ~reasoning:42 () in
  let turn =
    Tui.Turn_script.complete ~prompt:"think through the layout"
      ~reasoning_deltas:reasoning ~usage "The layout remains owned by Mosaic."
  in
  Tui.run ~name:"t" ~size:(92, 28) ~turns:[ turn ] @@ fun t ->
  submit t "think through the layout";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ think through the layout
    06 |
    07 | ∴ Thinking
    08 |  Then compare the intrinsic layout at both widths without predicting any row count.
    09 |  Finally preserve the user's complete frame so clipped or displaced UI is obvious.
    10 |  The fourth line proves the collapsed viewport stays anchored to the live tail.
    11 |
    12 | ⠋ Thinking… (0s · ↓ 60 tokens · esc to interrupt)
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |
    19 |
    20 |
    21 |
    22 |
    23 |
    24 |
    25 | ────────────────────────────────────────────────────────────────────────────────────────────
    26 | ❯ queue a message — sends after this turn
    27 | ────────────────────────────────────────────────────────────────────────────────────────────
    28 |   ! not logged in · /login · ~/mentat-tui-55… · openai/gpt-5… · ! full access ? for short…
    |}];
  Tui.keys t Key.ctrl_o;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ think through the layout
    06 |
    07 | ∴ Thinking
    08 |   First inspect the durable input and identify the visible invariant.
    09 |   Then compare the intrinsic layout at both widths without predicting any row count.
    10 |   Finally preserve the user's complete frame so clipped or displaced UI is obvious.
    11 |   The fourth line proves the collapsed viewport stays anchored to the live tail.
    12 |
    13 | ⠋ Thinking… (0s · ↓ 60 tokens · esc to interrupt)
    14 |
    15 |
    16 |
    17 |
    18 |
    19 |
    20 |
    21 |
    22 |
    23 |   ◎ verbose ctrl+o closes
    24 |
    25 | ────────────────────────────────────────────────────────────────────────────────────────────
    26 | ❯ queue a message — sends after this turn
    27 | ────────────────────────────────────────────────────────────────────────────────────────────
    28 |   ! not logged in · /login · ~/mentat-tui-55… · openai/gpt-5… · ! full access ? for short…
    |}];
  Tui.finish_turn t;
  Tui.settle t

let provider = Mentat_llm.Provider.make "openai"

let%expect_test "an authentication failure settles as repairable UI" =
  let error =
    Mentat_llm.Error.make ~kind:Mentat_llm.Error.Auth ~provider ~status:401
      "invalid API key"
  in
  let turn = Tui.Turn_script.fail ~prompt:"authenticate this request" error in
  Tui.run ~name:"t" ~turns:[ turn ] @@ fun t ->
  submit t "authenticate this request";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ authenticate this request
    06 |
    07 | ✗ invalid API key
    08 |   Tell mentat how to proceed.
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
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

let%expect_test
    "control-c during an active turn arms quit without interrupting the turn" =
  let turn =
    Tui.Turn_script.complete ~prompt:"keep this turn running"
      ~assistant_deltas:[ "The live answer remains in progress." ]
      "The held turn completes normally after quit disarms."
  in
  Tui.run ~name:"turn-control-c" ~turns:[ turn ] @@ fun t ->
  submit t "keep this turn running";
  Tui.keys t Key.ctrl_c;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-cb327da91
    04 |
    05 | ❯ keep this turn running
    06 |
    07 | ⏺ The live answer remains in progress.
    08 |
    09 | ⠋ Working… (0s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   press ctrl+c again to quit
    |}];
  Tui.advance t 2.;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-cb327da91
    04 |
    05 | ❯ keep this turn running
    06 |
    07 | ⏺ The live answer remains in progress.
    08 |
    09 | ⠋ Working… (2s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt… · ! full access ? for …
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-cb327da91
    04 |
    05 | ❯ keep this turn running
    06 |
    07 | ⏺ The held turn completes normally after quit disarms.
    08 |
    09 |   Worked for 2s
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
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt… · ! full access ? for …
    |}]

let%expect_test
    "streamed assistant prose survives interruption and the next follow-up" =
  let turns =
    [
      Tui.Turn_script.complete ~prompt:"start a careful explanation"
        ~assistant_deltas:
          [
            "The useful partial explanation remains visible after interruption.";
          ]
        "This held settlement must not replace the interrupted text.";
      Tui.Turn_script.complete ~prompt:"continue from that partial answer"
        "The follow-up continues without losing the interrupted prose.";
    ]
  in
  Tui.run ~name:"turn-interrupted-prose" ~turns @@ fun t ->
  submit t "start a careful explanation";
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-interruptfcc069e0
    04 |
    05 | ❯ start a careful explanation
    06 |
    07 | ⏺ The useful partial explanation remains visible after interruption.
    08 |
    09 | ◌ Interrupted — tell mentat what to do differently.
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  submit t "continue from that partial answer";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-interruptfcc069e0
    04 |
    05 | ❯ start a careful explanation
    06 |
    07 | ⏺ The useful partial explanation remains visible after interruption.
    08 |
    09 | ◌ Interrupted — tell mentat what to do differently.
    10 |
    11 | ❯ continue from that partial answer
    12 |
    13 | ⏺ The follow-up continues without losing the interrupted prose.
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test
    "startup-disabled reasoning stays hidden and thinking toggles the live view"
    =
  let turn =
    Tui.Turn_script.complete ~prompt:"reason without hiding the answer"
      ~reasoning_deltas:
        [
          "Private reasoning is visible only while thinking is enabled.\n";
          "The assistant answer remains independent from that preference.";
        ]
      ~assistant_deltas:[ "The visible assistant stream remains intact." ]
      "The visible assistant answer remains intact."
  in
  Tui.run ~name:"turn-thinking-visibility" ~show_reasoning:false ~turns:[ turn ]
  @@ fun t ->
  submit t "reason without hiding the answer";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-thinking-vi82da262e
    04 |
    05 | ❯ reason without hiding the answer
    06 |
    07 | ⏺ The visible assistant stream remains intact.
    08 |
    09 | ⠋ Working… (0s · esc to interrupt)
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
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  submit t "/thinking";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-thinking-vi82da262e
    04 |
    05 | ❯ reason without hiding the answer
    06 |
    07 | ❯ /thinking
    08 |
    09 | ∴ Thinking
    10 |  Private reasoning is visible only while thinking is enabled.
    11 |  The assistant answer remains independent from that preference.
    12 |
    13 | ⏺ The visible assistant stream remains intact.
    14 |
    15 | ⠋ Working… (0s · esc to interrupt)
    16 |
    17 |
    18 |
    19 |
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  submit t "/thinking";
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-thinking-vi82da262e
    04 |
    05 | ❯ reason without hiding the answer
    06 |
    07 | ❯ /thinking
    08 |
    09 | ❯ /thinking
    10 |
    11 | ⏺ The visible assistant stream remains intact.
    12 |
    13 | ⠋ Working… (0s · esc to interrupt)
    14 |
    15 |
    16 |
    17 |
    18 |
    19 |
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-turn-thinking-vi82da262e
    04 |
    05 | ❯ reason without hiding the answer
    06 |
    07 | ❯ /thinking
    08 |
    09 | ❯ /thinking
    10 |
    11 | ⏺ The visible assistant answer remains intact.
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

(* A goal wind-down commits its budget-limited transition between turns, so the
   [Journal_goal] fact reaches the transcript reducer with no active turn. That
   is a session-scoped transition, not a turn-scoped fault: the settled
   transcript stays clean and no error banner is appended. *)
let%expect_test "a goal transition between turns does not fault the transcript"
    =
  let goal = Mentat_session.Goal.Id.of_string "goal-budget" in
  let turn =
    Tui.Turn_script.complete ~prompt:"start the budgeted work"
      "Work parked at the budget."
  in
  Tui.run ~name:"t" ~turns:[ turn ] @@ fun t ->
  submit t "start the budgeted work";
  Tui.finish_turn t;
  Tui.settle t;
  (* The goal is declared, then wound down, while no turn is active; both facts
     formerly raised "turn-scoped fact arrived with no active turn". *)
  Tui.update_goal t
    (Mentat_session.Goal.Update.declare ~id:goal ~objective:"Ship the parser"
       ~token_budget:100 ());
  Tui.settle t;
  Tui.update_goal t (Mentat_session.Goal.Update.budget_limited ~id:goal);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ start the budgeted work
    06 |
    07 | ⏺ Work parked at the budget.
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
    18 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
    19 |   goal · Ship the parser
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]

let%expect_test "a failed turn leaves the session usable for the next prompt" =
  let error =
    Mentat_llm.Error.make ~kind:Mentat_llm.Error.Invalid_request ~provider
      ~status:400 "the request was rejected"
  in
  let turns =
    [
      Tui.Turn_script.fail ~prompt:"first request" error;
      Tui.Turn_script.complete ~prompt:"second request"
        "The next turn completed normally.";
    ]
  in
  Tui.run ~name:"t" ~turns @@ fun t ->
  submit t "first request";
  Tui.finish_turn t;
  Tui.settle t;
  submit t "second request";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-553b9dad
    04 |
    05 | ❯ first request
    06 |
    07 | ✗ the request was rejected
    08 |   Tell mentat how to proceed.
    09 |
    10 | ❯ second request
    11 |
    12 | ⏺ The next turn completed normally.
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
    24 |   ! not logged in · /login · ~/mentat… · openai/gpt-… · ! full access ? for s…
    |}]
