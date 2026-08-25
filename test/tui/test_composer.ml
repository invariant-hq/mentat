(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

let hello_turn =
  Tui.Turn_script.complete ~prompt:"say hello"
    "Hello from the scripted provider."

let reach_transcript t =
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  Tui.settle t;
  Tui.finish_turn t;
  Tui.settle t

let run_transcript ?size ?history ?enumerate_files ?file_enumeration
    ?local_shell ~name f =
  Tui.run ?size ?history ?enumerate_files ?file_enumeration ?local_shell ~name
    ~turns:[ hello_turn ]
  @@ fun t ->
  reach_transcript t;
  f t

let history texts =
  texts
  |> List.mapi (fun index text ->
      Printf.sprintf
        {|{"schema_version":1,"type":"mentat.tui.history_entry","session_id":"session-history","timestamp":"%d","draft":{"text":%S}}|}
        (1_000 - index) text)
  |> String.concat "\n"

let path text = Lpath.Rel.of_string_exn text

let replacement_session project =
  let module Session = Mentat_session in
  let metadata =
    Session.Metadata.make ~title:"Replacement session"
      ~cwd:(Lpath.Abs.of_string_exn (Project.root project))
      ~created_at:(Session.Time.of_unix_ms 1_000L)
      ~updated_at:(Session.Time.of_unix_ms 1_000L)
      ()
  in
  match
    Session.make
      ~id:(Session.Id.of_string "session-replacement")
      ~metadata ~events:[]
  with
  | Ok session -> session
  | Error error -> failwith (Session.Error.message error)

let enumerate_files () =
  Ok
    (List.map path
       [ "dune-project"; "lib/foo.ml"; "lib/sub/bar.ml"; "readme.md" ])

let%expect_test "file completion presents structured enumeration diagnostics" =
  let enumerate_files () =
    Error (Mentat_diagnostic.of_text "workspace observation denied")
  in
  Tui.run ~name:"composer-mention-diagnostic" ~enumerate_files
    ~file_enumeration:true
  @@ fun t ->
  Tui.keys t "@";
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
    13 | ! workspace observation denied
    14 | ────────────────────────────────────────────────────────────────────────────────
    15 | ❯ @
    16 | ────────────────────────────────────────────────────────────────────────────────
    17 |
    18 |                          ! /login — no connected account
    19 |                               ∅ no recent sessions
    20 |
    21 |
    22 |
    23 |
    24 |   ! not logged in · /login · ~/menta… · openai/gpt-5.5 m… · ! full access ? f…
    |}]

(* Every expectation is the complete terminal grid. There are no component
   snapshots here: an overlay that displaces the transcript, composer, footer,
   or another row remains visible to the reviewer. *)

let%expect_test "unicode input and cursor motion edit the complete composer" =
  run_transcript ~name:"composer-unicode-edit" @@ fun t ->
  Tui.keys t "日本語 café 🎉 abcd";
  Tui.keys t Key.left;
  Tui.keys t Key.left;
  Tui.keys t "X";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-unic2538b567
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
    22 | ❯ 日本語 café 🎉 abXcd
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "a multiline draft clears guardedly and recalls exactly" =
  run_transcript ~name:"composer-multiline" @@ fun t ->
  Tui.keys t "line one";
  Tui.keys t Key.linefeed;
  Tui.keys t "line two";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mff10bb77
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
    20 | ────────────────────────────────────────────────────────────────────────────────
    21 | ❯ line one
    22 |   line two
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt-… · ! full access ? for…
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mff10bb77
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
    20 | ────────────────────────────────────────────────────────────────────────────────
    21 | ❯ line one
    22 |   line two
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   press esc again to discard the draft
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mff10bb77
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
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt-… · ! full access ? for…
    |}];
  Tui.keys t Key.up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mff10bb77
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
    20 | ────────────────────────────────────────────────────────────────────────────────
    21 | ❯ line one
    22 |   line two
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt-… · ! full access ? for…
    |}]

let%expect_test "the textarea keeps the cursor row visible at its height cap" =
  run_transcript ~name:"composer-cursor-reveal" ~size:(52, 18) @@ fun t ->
  List.iteri
    (fun index line ->
      if index > 0 then Tui.keys t Key.linefeed;
      Tui.keys t line)
    [
      "line one";
      "line two";
      "line three";
      "line four";
      "line five";
      "line six";
      "line seven";
      "line eight — cursor here";
    ];
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    02 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    03 |  dev · openai/gpt-5.5 medium
    04 |  ~/mentat-tui-composer-cursoa67cc96b
    05 |
    06 | ❯ say hello
    07 |
    08 | ⏺ Hello from the scripted provider.
    09 |
    10 | ────────────────────────────────────────────────────
    11 | ❯ line three
    12 |   line four
    13 |   line five
    14 |   line six
    15 |   line seven
    16 |   line eight — cursor here
    17 | ────────────────────────────────────────────────────
    18 |   ! not logged in · /log… · open… · ! full access
    |}]

let%expect_test "pastes stay inline or become one deletable visual atom" =
  run_transcript ~name:"composer-paste" @@ fun t ->
  Tui.paste t "naïve — 日本語";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-compos1d5b26fb
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
    22 | ❯ naïve — 日本語
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt… · ! full access ? for …
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.paste t "alpha\nbeta\ngamma\ndelta";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-compos1d5b26fb
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
    22 | ❯ [Pasted text #1 +3 lines]
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt… · ! full access ? for …
    |}];
  Tui.keys t Key.backspace;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-compos1d5b26fb
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
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt… · ! full access ? for …
    |}]

let%expect_test "question mark opens and escape closes the full shortcuts sheet"
    =
  run_transcript ~name:"composer-help" @@ fun t ->
  Tui.keys t "?";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-compofcb00cf7
    04 |
    05 | ❯ say hello
    06 |
    07 | ⏺ Hello from the scripted provider.
    08 |
    09 |
    10 | ────────────────────────────────────────────────────────────────────────────────
    11 | ❯ message mentat
    12 | ────────────────────────────────────────────────────────────────────────────────
    13 | composer       history
    14 | /  commands    shift+enter  newline
    15 | @  file paths  ↑ ↓          prompt history
    16 | !  shell mode  ctrl+r       search history
    17 | ?  this help   esc esc      interrupt turn
    18 | controls
    19 | tab              focus agents
    20 | ctrl+o           verbose reasoning
    21 | shift+tab        switch build/plan mode
    22 | pageup pagedown  scroll
    23 | ctrl+c ctrl+c    quit
    24 |   ! not logged in · /login · ~/mentat-… · openai/gpt-… · ! full access ? for …
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-compofcb00cf7
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
    24 |   ! not logged in · /login · ~/mentat-… · openai/gpt-… · ! full access ? for …
    |}]

let%expect_test "slash completion shows the catalog and filtered result" =
  run_transcript ~name:"composer-commands" @@ fun t ->
  Tui.keys t "/";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-27aaa224
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
    16 | ❯ /clear      Start a new session with empty context; previous...
    17 |   /fork       Fork current session
    18 |   /rewind     Jump back to an earlier message and resubmit
    19 |   /undo       Undo the last turn: revert its files and reload ...
    20 |   /redo       Redo an undone turn, restoring its files and mes...
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ /
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt-… · ! full access ? for…
    |}];
  Tui.keys t "q";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-27aaa224
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
    20 | ❯ /quit   Exit Mentat
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ /q
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt-… · ! full access ? for…
    |}]

let%expect_test "enter submits an unmatched slash draft as an ordinary prompt" =
  let prompt = "/tmp/build.log has the error, can you look" in
  let response =
    Tui.Turn_script.complete ~prompt "I can inspect that build log."
  in
  Tui.run ~name:"composer-command-miss-submit" ~turns:[ hello_turn; response ]
  @@ fun t ->
  reach_transcript t;
  Tui.keys t prompt;
  Tui.enter t;
  Tui.settle t;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-command-mis9f0a54fa
    04 |
    05 | ❯ say hello
    06 |
    07 | ⏺ Hello from the scripted provider.
    08 |
    09 | ❯ /tmp/build.log has the error, can you look
    10 |
    11 | ⏺ I can inspect that build log.
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
    24 |   ! not logged in · /login · ~/mentat-tui… · openai/gpt… · ! full access ? fo…
    |}]

let%expect_test "an unmatched slash filter closes without losing the draft" =
  run_transcript ~name:"composer-command-miss" @@ fun t ->
  Tui.keys t "/qzz";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-comm3437c277
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
    20 |   no matching commands
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ /qzz
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-comm3437c277
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
    22 | ❯ /qzz
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-comm3437c277
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
    22 | ❯ /qzz
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   press esc again to discard the draft
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-comm3437c277
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-comm3437c277
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
    20 |   no matching commands
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ /qzz
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "control-c on an empty draft arms quit and visibly expires" =
  run_transcript ~name:"composer-quit-arming" @@ fun t ->
  Tui.keys t Key.ctrl_c;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-quic94c2f49
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
    24 |   press ctrl+c again to quit
    |}];
  Tui.advance t 2.;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-quic94c2f49
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test
    "blank and Unicode-whitespace Enter leave the complete screen unchanged" =
  run_transcript ~name:"composer-blank-enter" @@ fun t ->
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-bla4d3082b1
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-bla4d3082b1
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t "\u{00A0}\u{2003}\u{202F}";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-bla4d3082b1
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "control-c discards a draft once and up recalls it" =
  run_transcript ~name:"composer-control-c" @@ fun t ->
  Tui.keys t "discard me";
  Tui.settle t;
  Tui.keys t Key.ctrl_c;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-c39d693d7
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
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt-… · ! full access ? for…
    |}];
  Tui.keys t Key.up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-c39d693d7
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
    22 | ❯ discard me
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-t… · openai/gpt-… · ! full access ? for…
    |}]

let%expect_test "history walk reaches loaded prompts and restores the draft" =
  let history = history [ "alpha prompt" ] in
  run_transcript ~name:"composer-history-recall" ~history @@ fun t ->
  Tui.keys t "working draft";
  Tui.settle t;
  Tui.keys t Key.up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor951d660f
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
    22 | ❯ say hello
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor951d660f
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
    22 | ❯ alpha prompt
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor951d660f
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
    22 | ❯ say hello
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor951d660f
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
    22 | ❯ working draft
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "reverse search renders and inserts its selected prompt" =
  let history = history [ "beta two"; "alpha one" ] in
  run_transcript ~name:"composer-history-search" ~history @@ fun t ->
  Tui.keys t Key.ctrl_r;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor17340341
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
    18 | reverse-i-search:
    19 | ❯ alpha one
    20 |   beta two
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ⌕ search history
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ↵ insert · esc cancel · type to search                             ⌕ history
    |}];
  Tui.keys t "bt";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor17340341
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
    19 | reverse-i-search: bt
    20 | ❯ beta two
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ⌕ bt
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ↵ insert · esc cancel · type to search                             ⌕ history
    |}];
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor17340341
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
    22 | ❯ beta two
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "reverse search reaches a record older than 200 entries" =
  let oldest = "sentinel entry older than 200" in
  let newer =
    List.init 200 (fun index -> Printf.sprintf "filler history %03d" index)
  in
  let history = history (oldest :: newer) in
  run_transcript ~name:"composer-history-search" ~history @@ fun t ->
  Tui.keys t Key.ctrl_r;
  Tui.settle t;
  Tui.keys t "sentinel";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histor17340341
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
    19 | reverse-i-search: sentinel
    20 | ❯ sentinel entry older than 200
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ⌕ sentinel
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ↵ insert · esc cancel · type to search                             ⌕ history
    |}]

let%expect_test "escape from reverse search restores the borrowed draft" =
  let history = history [ "beta two"; "alpha one" ] in
  run_transcript ~name:"composer-history-cancel" ~history @@ fun t ->
  Tui.keys t "keep me";
  Tui.settle t;
  Tui.keys t Key.ctrl_r;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-historfe819e48
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
    18 | reverse-i-search:
    19 | ❯ alpha one
    20 |   beta two
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ⌕ search history
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ↵ insert · esc cancel · type to search                             ⌕ history
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-historfe819e48
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
    22 | ❯ keep me
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "reverse search renders its no-match state" =
  let history = history [ "alpha one" ] in
  run_transcript ~name:"composer-history-miss" ~history @@ fun t ->
  Tui.keys t Key.ctrl_r;
  Tui.settle t;
  Tui.keys t "zzq";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histd708d5ed
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
    19 | reverse-i-search: zzq
    20 |   no matching prompts
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ⌕ zzq
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ↵ insert · esc cancel · type to search                             ⌕ history
    |}];
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-histd708d5ed
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
    22 | ❯ zzq
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

(* A bare [@] stays quiet: it lists only the root's children, directories
   first. A typed query matches recursively — a nested file surfaces without
   stepping through its parents — while tab on a directory drills by rewriting
   the token to [@dir/], whose listing is that directory's children. Escape
   closes the list without eating the token, and backspace walks back out. *)
let%expect_test
    "file completion browses the root, matches nested paths, and drills with \
     tab" =
  run_transcript ~name:"composer-mention-expand" ~enumerate_files
    ~file_enumeration:true
  @@ fun t ->
  Tui.keys t "@";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    18 | ❯ +  lib/
    19 |   +  dune-project
    20 |   +  readme.md
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ @
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t "bar";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    20 | ❯ +  lib/sub/bar.ml
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ @bar
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  List.iter (fun _ -> Tui.keys t Key.backspace) [ (); (); () ];
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    18 | ❯ +  lib/
    19 |   +  dune-project
    20 |   +  readme.md
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ @
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    19 | ❯ +  lib/sub/
    20 |   +  lib/foo.ml
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ @lib/
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    20 | ❯ +  lib/sub/bar.ml
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ @lib/sub/
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t "zzz";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    20 |   no matching files
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ @lib/sub/zzz
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    22 | ❯ @lib/sub/zzz
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  List.iter
    (fun _ -> Tui.keys t Key.backspace)
    [ (); (); (); (); (); (); (); (); (); (); (); () ];
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio30255bee
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "file completion inserts an atomic reference and closes" =
  run_transcript ~name:"composer-mention-insert" ~enumerate_files
    ~file_enumeration:true
  @@ fun t ->
  Tui.keys t "@readme";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio87cca229
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
    20 | ❯ +  readme.md
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ @readme
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mentio87cca229
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
    22 | ❯ @readme.md
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "without enumeration capability an at-sign remains free text" =
  run_transcript ~name:"composer-mention-fallback" @@ fun t ->
  Tui.keys t "@readme";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-mention-a0749f71
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
    22 | ❯ @readme
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "without shell capability an exclamation remains prompt text" =
  run_transcript ~name:"composer-shell-fallback" @@ fun t ->
  Tui.keys t "!echo ordinary";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-shell-1a0a87ff
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
    22 | ❯ !echo ordinary
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}]

let%expect_test "shell mode keeps one editor through discard and recall" =
  run_transcript ~name:"composer-shell-recall" ~local_shell:true @@ fun t ->
  Tui.keys t "!";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-sheld768ec9f
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
    22 | ! shell command
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   esc exit shell · ↵ run                                               ! shell
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-sheld768ec9f
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t "!echo composer-marker";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-sheld768ec9f
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
    22 | ! echo composer-marker
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   esc exit shell · ↵ run                                               ! shell
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-sheld768ec9f
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
    22 | ! echo composer-marker
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   press esc again to discard the draft
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-sheld768ec9f
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt… · ! full access ? for…
    |}];
  Tui.keys t Key.up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-sheld768ec9f
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
    22 | ! echo composer-marker
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   esc exit shell · ↵ run                                               ! shell
    |}]

let%expect_test "shift-tab dresses plan mode and returns to build mode" =
  run_transcript ~name:"composer-mode" ~size:(52, 18) @@ fun t ->
  Tui.keys t Key.shift_tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    04 |  dev · openai/gpt-5.5 medium
    05 |  ~/mentat-tui-compo0bbb5b3f
    06 |
    07 | ❯ say hello
    08 |
    09 | ⏺ Hello from the scripted provider.
    10 |
    11 |
    12 |
    13 |
    14 |
    15 |  ⏸ plan ────────────────────────────────────────────
    16 | ❯ message mentat
    17 | ────────────────────────────────────────────────────
    18 |   ! not logged in · /log… · open… · ! full access
    |}];
  Tui.keys t Key.shift_tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    04 |  dev · openai/gpt-5.5 medium
    05 |  ~/mentat-tui-compo0bbb5b3f
    06 |
    07 | ❯ say hello
    08 |
    09 | ⏺ Hello from the scripted provider.
    10 |
    11 |
    12 |
    13 |
    14 |
    15 | ────────────────────────────────────────────────────
    16 | ❯ message mentat
    17 | ────────────────────────────────────────────────────
    18 |   ! not logged in · /log… · open… · ! full access
    |}]

let%expect_test "a local shell interrupt requires two escape gestures" =
  run_transcript ~name:"composer-shell-correlation" ~local_shell:true
  @@ fun t ->
  Tui.keys t "!sleep 30";
  Tui.enter t;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-shell-corbb624c29
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
    24 |   press esc again to interrupt
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.fail_local_shell t (Mentat_diagnostic.of_text "cancelled by fixture");
  Tui.settle t

let%expect_test "a local shell completion is stale after local clear" =
  run_transcript ~name:"composer-shell-stale-clear" ~local_shell:true
  @@ fun t ->
  Tui.keys t "!sleep stale";
  Tui.enter t;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.keys t "/clear";
  Tui.enter t;
  Tui.settle t;
  Tui.fail_local_shell t (Mentat_diagnostic.of_text "STALE LOCAL SHELL FAILURE");
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-shell-sta7703c373
    04 |
    05 |   conversation cleared · session session-visual-00001 remains saved
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
    24 |   ! not logged in · /login · ~/mentat-tu… · openai/gpt-… · ! full acce… ? for…
    |}]

let%expect_test "a local shell completion is stale after session replacement" =
  Tui.run ~name:"composer-shell-stale-session" ~local_shell:true
    ~sessions:(fun project -> [ replacement_session project ])
    ~turns:[ hello_turn ]
  @@ fun t ->
  reach_transcript t;
  Tui.keys t "!sleep stale session";
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.fail_local_shell t
    (Mentat_diagnostic.of_text "STALE REPLACED SESSION SHELL FAILURE");
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-composer-shell-staleaec4f87d
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
    24 |   ! not logged in · /login · ~/mentat-tui… · openai/gpt… · ! full access ? fo…
    |}]
