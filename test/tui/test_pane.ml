(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness
module Task = Mentat_session.Task

let submit t prompt =
  Tui.settle t;
  Tui.keys t prompt;
  Tui.enter t;
  Tui.settle t

let task ~id ~content ~status ~position =
  match
    Task.Item.make ~id:(Task.Id.of_string id) ~owner:Task.Owner.Main ~content
      ~status ~position ()
  with
  | Ok item -> item
  | Error error -> failwith (Task.Error.message error)

let task_board =
  let open Task.Status in
  let items =
    [
      task ~id:"pane-1" ~content:"scaffold the module" ~status:In_progress
        ~position:0;
      task ~id:"pane-2" ~content:"write the public interface" ~status:Pending
        ~position:1;
      task ~id:"pane-3" ~content:"wire the application shell" ~status:Pending
        ~position:2;
      task ~id:"pane-4" ~content:"add complete-screen tests" ~status:Pending
        ~position:3;
      task ~id:"pane-5" ~content:"review the visual diff" ~status:Pending
        ~position:4;
      task ~id:"pane-6" ~content:"read the layout RFC" ~status:Completed
        ~position:5;
      task ~id:"pane-7" ~content:"survey the legacy UI" ~status:Completed
        ~position:6;
    ]
  in
  match Task.Board.make items with
  | Ok board -> board
  | Error error -> failwith (Task.Error.message error)

(* Every expectation is a complete numbered terminal grid emitted by
   [Tui.print]. The resize sequence is the assertion: no component crop or
   geometry-only value can conceal a displaced transcript, activity surface,
   composer, or footer. *)

let%expect_test "empty activity keeps the transcript full width across resize" =
  let prompt = "keep this transcript stable while the viewport changes" in
  let turn =
    Tui.Turn_script.complete ~prompt
      "The transcript remains stable across every responsive branch."
  in
  Tui.run ~name:"pane-empty-breakpoint" ~size:(109, 24) ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  (* Below the breakpoint the transcript owns the complete content width. *)
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-empty-brc3a3f5c5
    04 |
    05 | ❯ keep this transcript stable while the viewport changes
    06 |
    07 | ⏺ The transcript remains stable across every responsive branch.
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
    21 | ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-empty-brc3a3… · openai/gpt-5… · ! full access ? for shortcu…
    |}];
  (* At the inclusive breakpoint no orphan activity column or divider appears;
     the durable transcript expands into the complete region. *)
  Tui.resize t ~width:110 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-empty-brc3a3f5c5
    04 |
    05 | ❯ keep this transcript stable while the viewport changes
    06 |
    07 | ⏺ The transcript remains stable across every responsive branch.
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
    21 | ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-empty-brc3a3… · openai/gpt-5.5 · ! full access ? for shortcu…
    |}];
  (* Immediately above the breakpoint Mosaic gives the extra cell to the same
     full-width transcript. *)
  Tui.resize t ~width:111 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-empty-brc3a3f5c5
    04 |
    05 | ❯ keep this transcript stable while the viewport changes
    06 |
    07 | ⏺ The transcript remains stable across every responsive branch.
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
    21 | ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-empty-brc3a3f… · openai/gpt-5.5 · ! full access ? for shortcu…
    |}]

let%expect_test
    "task activity moves from narrow flow to wide pane across resize" =
  let prompt = "show the responsive task activity" in
  let turn =
    Tui.Turn_script.complete ~task_boards:[ task_board ] ~prompt
      "The task activity remains attached to this transcript."
  in
  Tui.run ~name:"pane-task-breakpoint" ~size:(109, 24) ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  (* Below the breakpoint, the task board follows the transcript in the narrow
     activity flow and remains above the composer. *)
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-task-br2676d3b6
    04 |
    05 | ❯ show the responsive task activity
    06 |
    07 | ⏺ Todo(7 tasks · 2 done · 1 running)
    08 |
    09 | ⠋ Working… (0s · esc to interrupt)
    10 |
    11 |
    12 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
    13 |   ◻ 7 tasks · 2 done · 1 running
    14 |   ◼ scaffold the module
    15 |   ◻ write the public interface
    16 |   ◻ wire the application shell
    17 |   ◻ add complete-screen tests
    18 |   ◻ review the visual diff
    19 |   … 2 done
    20 |
    21 | ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ queue a message — sends after this turn
    23 | ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-task-br2676… · openai/gpt-5.5 · ! full access ? for shortcu…
    |}];
  (* At exactly 110 cells, the same complete board moves beside the transcript
     under the tasks heading. It must not remain duplicated below it. *)
  Tui.resize t ~width:110 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ tasks · 2 done · 1 running
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   ◼ scaffold the module
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-task-br2676d3b6               │   ◻ write the public
    04 |                                                                                 │     interface
    05 | ❯ show the responsive task activity                                             │   ◻ wire the application
    06 |                                                                                 │     shell
    07 | ⏺ Todo(7 tasks · 2 done · 1 running)                                            │   ◻ add complete-screen
    08 |                                                                                 │     tests
    09 | ⠋ Working… (0s · esc to interrupt)                                              │   ◻ review the visual diff
    10 |                                                                                 │   … 2 done
    11 |                                                                                 │
    12 |                                                                                 │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |
    21 | ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ queue a message — sends after this turn
    23 | ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-task-br2676d… · openai/gpt-5.5 · ! full access ? for shortcu…
    |}];
  (* A comfortably wide frame makes the transcript/activity split directly
     inspectable, including intrinsic task wrapping and the pane viewport. *)
  Tui.resize t ~width:120 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ tasks · 2 done · 1 running
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   ◼ scaffold the module
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-task-br2676d3b6               │   ◻ write the public interface
    04 |                                                                                 │   ◻ wire the application shell
    05 | ❯ show the responsive task activity                                             │   ◻ add complete-screen tests
    06 |                                                                                 │   ◻ review the visual diff
    07 | ⏺ Todo(7 tasks · 2 done · 1 running)                                            │   … 2 done
    08 |                                                                                 │
    09 | ⠋ Working… (0s · esc to interrupt)                                              │
    10 |                                                                                 │
    11 |                                                                                 │
    12 |                                                                                 │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ queue a message — sends after this turn
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-task-br2676d3b6 · openai/gpt-5.5 · ! full access        ? for shortcuts
    |}];
  (* Crossing back proves that the stable keyed transcript survives branch
     replacement and that the task board returns to exactly one narrow site. *)
  Tui.resize t ~width:109 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-task-br2676d3b6
    04 |
    05 | ❯ show the responsive task activity
    06 |
    07 | ⏺ Todo(7 tasks · 2 done · 1 running)
    08 |
    09 | ⠋ Working… (0s · esc to interrupt)
    10 |
    11 |
    12 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
    13 |   ◻ 7 tasks · 2 done · 1 running
    14 |   ◼ scaffold the module
    15 |   ◻ write the public interface
    16 |   ◻ wire the application shell
    17 |   ◻ add complete-screen tests
    18 |   ◻ review the visual diff
    19 |   … 2 done
    20 |
    21 | ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ queue a message — sends after this turn
    23 | ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-task-br2676… · openai/gpt-5.5 · ! full access ? for shortcu…
    |}];
  Tui.finish_turn t;
  Tui.settle t

let call ~id ~name =
  Mentat_llm.Tool.Call.make ~id ~name ~input:(Jsont.Json.object' []) ()

let update_output ~files ~additions ~deletions =
  Mentat_tools_output.Codec.encode Mentat_tools_output.Update.jsont
    ~text:"updated workspace files"
    (Mentat_tools_output.Update.make
       ~disposition:Mentat_tools_output.Update.Applied ~files
       ~additions:(Some additions) ~deletions:(Some deletions) ~skipped:0)

let llm_model ~provider id =
  Mentat_llm.Model.make
    ~provider:(Mentat_llm.Provider.make provider)
    ~api:(Mentat_llm.Model.Api.make "responses")
    ~id

let windowed_model ~provider ~window id =
  Mentat_provider.Model.make (llm_model ~provider id) ~context_window:window ()

let priced_model ~provider ~window ~input ~output ~cache_read id =
  let rate =
    Mentat_provider.Model.Pricing.Rate.make ~input_per_million:input
      ~output_per_million:output ~cached_input_per_million:cache_read ()
  in
  Mentat_provider.Model.make (llm_model ~provider id) ~context_window:window
    ~pricing:(Mentat_provider.Model.Pricing.make rate)
    ()

let openai_provider models =
  Mentat_provider.make
    (Mentat_llm.Provider.make "openai")
    ~display_name:"OpenAI" models

(* The wide pane's ambient workspace and context sections report the live signals
   the client already tracks: the aggregate mutation diff, the current context
   occupancy against the model window, and the session's priced spend. All are
   driven through the real turn — a scripted mutation, provider-reported usage,
   and the model's catalog pricing — so no value is invented. *)
let%expect_test "workspace and context sections report the live pane facts" =
  let module Change = Tui.Mutation_script.Change in
  let rel = Lpath.Rel.of_string_exn in
  let prompt = "apply the workspace edits" in
  let edit_call = call ~id:"edit-1" ~name:"edit_file" in
  let tools =
    [
      Tui.Turn_script.tool ~call:edit_call
        ~result:
          (Mentat_tool.Result.completed
             ~output:(update_output ~files:2 ~additions:4 ~deletions:1)
             ());
    ]
  in
  let mutations =
    [
      Tui.Mutation_script.make ~call_id:"edit-1"
        ~changes:
          [
            Change.update ~path:(rel "lib/app.ml")
              ~before:"let start = 1\nlet stop = 2\n"
              ~after:"let start = 1\nlet stop = 3\nlet extra = 4\n";
            Change.create ~path:(rel "README.md") ~contents:"# Notes\nHello.\n";
          ]
        ();
    ]
  in
  (* Occupancy is the whole response summed across every lane — cached input
     reads count toward the context fill, so 6000 + 3000 + 400 = 9,400. *)
  let usage =
    Mentat_llm.Usage.make ~input:6000 ~output:400 ~cache_read:3000 ()
  in
  let turn =
    Tui.Turn_script.complete ~prompt ~tools ~mutations ~usage
      "The workspace edits are applied."
  in
  let providers =
    [
      openai_provider
        [
          priced_model ~provider:"openai" ~window:128_000 ~input:5. ~output:30.
            ~cache_read:0.5 "gpt-5.5";
        ];
    ]
  in
  Tui.run ~name:"pane-workspace" ~size:(120, 24) ~providers ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ workspace
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   session · 2 files · +4 −1
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-w1e475aa7                     │
    04 |                                                                                 │ context
    05 | ❯ apply the workspace edits                                                     │   9,400 tokens
    06 |                                                                                 │   7% used
    07 | ⏺ Edit                                                                          │   $0.04 spent
    08 |   ⎿  Updated 2 files (+4, -1)                                                   │
    09 |                                                                                 │
    10 | ⏺ The workspace edits are applied.                                              │
    11 |                                                                                 │
    12 | ⊙ workspace changed · 2 files · +4 −1 · revert available                        │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |   Δ 2 changes · +4 −1 · ctrl+d opens latest                                     │
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-w1e475aa7 · openai/gpt-5.5 · ! full access · 9.4K (7%)  ? for shortcuts
    |}]

(* The workspace section also carries the ambient git-worktree summary and the
   dune build-health verdict, polled from the engine at session start and turn
   settle. The worktree row (git, against the review base) and the session row
   (this run's tool mutations) carry distinct leading labels and independent
   numbers, and a failing dune watch adds an error row. A [Disconnected] or
   [Unknown] verdict would render no dune row (Health's fail-honest law). *)
let%expect_test "workspace section shows the worktree diff and dune verdict" =
  let module Change = Tui.Mutation_script.Change in
  let rel = Lpath.Rel.of_string_exn in
  let prompt = "touch a file" in
  let edit_call = call ~id:"edit-1" ~name:"edit_file" in
  let tools =
    [
      Tui.Turn_script.tool ~call:edit_call
        ~result:
          (Mentat_tool.Result.completed
             ~output:(update_output ~files:1 ~additions:2 ~deletions:0)
             ());
    ]
  in
  let mutations =
    [
      Tui.Mutation_script.make ~call_id:"edit-1"
        ~changes:
          [
            Change.update ~path:(rel "lib/app.ml") ~before:"let a = 1\n"
              ~after:"let a = 1\nlet b = 2\nlet c = 3\n";
          ]
        ();
    ]
  in
  let usage = Mentat_llm.Usage.make ~input:6000 ~output:400 () in
  let turn =
    Tui.Turn_script.complete ~prompt ~tools ~mutations ~usage "Done."
  in
  let providers =
    [
      openai_provider
        [
          priced_model ~provider:"openai" ~window:128_000 ~input:5. ~output:30.
            ~cache_read:0.5 "gpt-5.5";
        ];
    ]
  in
  (* Worktree numbers deliberately differ from the session mutation above, so the
     two same-shaped rows are visibly distinct signals. *)
  let glance =
    ( Some (Textdiff.Stats.v ~files:5 ~additions:40 ~deletions:8),
      Mentat_workspace.Health.Live
        {
          owner = Mentat_workspace.Health.Owner.Theirs 4242;
          phase =
            Mentat_workspace.Health.Phase.Settled
              {
                build =
                  Mentat_workspace.Health.Verdict.Failing
                    { errors = 2; warnings = 0 };
                lint = None;
              };
        } )
  in
  Tui.run ~name:"pane-worktree" ~size:(120, 24) ~providers
    ~workspace_glance:glance ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ workspace
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   worktree · 5 files · +40 −8
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-a62e47f3                      │   session · 1 file · +2 −0
    04 |                                                                                 │   dune · theirs · 2 errors
    05 | ❯ touch a file                                                                  │
    06 |                                                                                 │ context
    07 | ⏺ Edit                                                                          │   6,400 tokens
    08 |   ⎿  Updated 1 file (+2, -0)                                                    │   5% used
    09 |                                                                                 │   $0.04 spent
    10 | ⏺ Done.                                                                         │
    11 |                                                                                 │
    12 | ⊙ workspace changed · 1 file · +2 −0 · revert available                         │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |   Δ 1 change · +2 −0 · ctrl+d opens latest                                      │
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-a62e47f3 · openai/gpt-5.5 · ! full access · 6.4K (5%)   ? for shortcuts
    |}]

(* Two OpenAI models whose only pane-visible difference is their context window:
   the launch model at 128,000 (matching the harness snapshot) and the switch
   target at 256,000. The client resolves the window from these declarations,
   exactly as the executable seeds it from the catalog at startup. Neither
   carries pricing, so the switch test's context section omits the spend row. *)
let two_window_providers =
  [
    openai_provider
      [
        windowed_model ~provider:"openai" ~window:128_000 "gpt-5.5";
        windowed_model ~provider:"openai" ~window:256_000 "gpt-6";
      ];
  ]

(* Switching models mid-session must re-denominate the context fill against the
   new model's window rather than dropping the percent. Both turns report the
   same 25,600-token occupancy, so only the denominator moves: 20% of 128K on the
   launch model, 10% of 256K once the wider model's sealed turn arrives. *)
let%expect_test "a model switch re-denominates the context percentage" =
  let usage = Mentat_llm.Usage.make ~input:25_000 ~output:600 () in
  let gpt6 = llm_model ~provider:"openai" "gpt-6" in
  let turn1 =
    Tui.Turn_script.complete ~usage ~prompt:"first prompt on the launch model"
      "Answered on the launch model."
  in
  let turn2 =
    Tui.Turn_script.complete ~model:gpt6 ~usage
      ~prompt:"second prompt after switching models"
      "Answered on the wider model."
  in
  Tui.run ~name:"pane-model-switch" ~size:(120, 24)
    ~providers:two_window_providers ~turns:[ turn1; turn2 ]
  @@ fun t ->
  submit t "first prompt on the launch model";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ context
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   25,600 tokens
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-mode7436aad1                  │   20% used
    04 |                                                                                 │
    05 | ❯ first prompt on the launch model                                              │
    06 |                                                                                 │
    07 | ⏺ Answered on the launch model.                                                 │
    08 |                                                                                 │
    09 |                                                                                 │
    10 |                                                                                 │
    11 |                                                                                 │
    12 |                                                                                 │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-mode7436a… · openai/gpt-5.5 · ! full access · 25.6K (20… ? for shortcu…
    |}];
  submit t "second prompt after switching models";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ context
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   25,600 tokens
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-mode7436aad1                  │   10% used
    04 |                                                                                 │
    05 | ❯ first prompt on the launch model                                              │
    06 |                                                                                 │
    07 | ⏺ Answered on the launch model.                                                 │
    08 |                                                                                 │
    09 | ❯ second prompt after switching models                                          │
    10 |                                                                                 │
    11 | ⏺ Answered on the wider model.                                                  │
    12 |                                                                                 │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane-mode7436aa… · openai/gpt-6 · ! full access · 25.6K (10… ? for shortcuts
    |}]

(* The pane's third ambient section surfaces this session's live background
   processes — the [shell] tool's [background:true] children — polled on the same
   session-scoped cadence as the glance. The injected view is a test-controlled
   thunk, so one run shows a process appear beside the transcript and then, once
   it exits, the section clear with no orphan heading. The age is baked into the
   view (no clock read), keeping the frame deterministic. *)
let%expect_test
    "the running section shows a live background process then clears on exit" =
  let running =
    ref
      [
        Mentat_protocol.Process.View.make ~handle:"bg-1" ~command:"npm run dev"
          ~status:Mentat_protocol.Process.Status.Running ~age_ms:5000;
      ]
  in
  let turn1 =
    Tui.Turn_script.complete ~prompt:"run the dev server in the background"
      "Started the dev server."
  in
  let turn2 =
    Tui.Turn_script.complete ~prompt:"stop the dev server" "Stopped it."
  in
  Tui.run ~name:"pane-running" ~size:(120, 24)
    ~running_processes:(fun () -> !running)
    ~turns:[ turn1; turn2 ]
  @@ fun t ->
  submit t "run the dev server in the background";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ running
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   bg-1 · npm run dev · running · 5s
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane9c992d04                       │
    04 |                                                                                 │
    05 | ❯ run the dev server in the background                                          │
    06 |                                                                                 │
    07 | ⏺ Started the dev server.                                                       │
    08 |                                                                                 │
    09 |                                                                                 │
    10 |                                                                                 │
    11 |                                                                                 │
    12 |                                                                                 │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pane9c992d04 · openai/gpt-5.5 · ! full access                ? for shortcuts
    |}];
  (* The process exits before the next turn; that turn's settle poll returns the
     empty view and the section — heading and all — disappears. *)
  running := [];
  submit t "stop the dev server";
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane9c992d04
    04 |
    05 | ❯ run the dev server in the background
    06 |
    07 | ⏺ Started the dev server.
    08 |
    09 | ❯ stop the dev server
    10 |
    11 | ⏺ Stopped it.
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
    24 |   ! not logged in · /login · ~/mentat-tui-pane9c992d04 · openai/gpt-5.5 · ! full access                ? for shortcuts
    |}]

(* The declared session goal is ambient: it heads the wide pane as its own
   section (with a budget fact) and survives the narrow squeeze as a labelled
   line above the task strip. *)
let%expect_test "the declared goal heads the pane and the narrow strip" =
  let prompt = "start the parser rewrite" in
  let turn =
    Tui.Turn_script.complete ~task_boards:[ task_board ] ~prompt
      "Parser rewrite is underway."
  in
  Tui.run ~name:"pane-goal" ~size:(120, 24) ~turns:[ turn ] @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.update_goal t
    (Mentat_session.Goal.Update.declare
       ~id:(Mentat_session.Goal.Id.of_string "goal-pane")
       ~objective:"Ship the parser rewrite without regressions"
       ~token_budget:200_000 ());
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                 │ goal · 200K left
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   Ship the parser rewrite without
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-p10251be4                          │   regressions
    04 |                                                                                 │
    05 | ❯ start the parser rewrite                                                      │ tasks · 2 done · 1 running
    06 |                                                                                 │   ◼ scaffold the module
    07 | ⏺ Todo(7 tasks · 2 done · 1 running)                                            │   ◻ write the public interface
    08 |                                                                                 │   ◻ wire the application shell
    09 | ⏺ Parser rewrite is underway.                                                   │   ◻ add complete-screen tests
    10 |                                                                                 │   ◻ review the visual diff
    11 |                                                                                 │   … 2 done
    12 |                                                                                 │
    13 |                                                                                 │
    14 |                                                                                 │
    15 |                                                                                 │
    16 |                                                                                 │
    17 |                                                                                 │
    18 |                                                                                 │
    19 |                                                                                 │
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-p10251be4 · openai/gpt-5.5 · ! full access                   ? for shortcuts
    |}];
  Tui.resize t ~width:100 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-p10251be4
    04 |
    05 | ❯ start the parser rewrite
    06 |
    07 | ⏺ Todo(7 tasks · 2 done · 1 running)
    08 |
    09 | ⏺ Parser rewrite is underway.
    10 |
    11 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
    12 |   goal · Ship the parser rewrite without regressions
    13 |   ◻ 7 tasks · 2 done · 1 running
    14 |   ◼ scaffold the module
    15 |   ◻ write the public interface
    16 |   ◻ wire the application shell
    17 |   ◻ add complete-screen tests
    18 |   ◻ review the visual diff
    19 |   … 2 done
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-p10251b… · openai/gpt-5.5 · ! full access ? for shortcu…
    |}]

(* A fixed viewport keeps the activity column static. A long assistant line
   must wrap inside the transcript, not widen it: the transcript's zero main-axis
   flex basis makes it grow only into the width the bounded activity column
   leaves. Here a single 335-cell line at 220 cells holds the pane at its 45-cell
   bound. With the transcript's earlier [auto] (max-content) basis the same line
   dragged the pane below 45, and a longer line collapsed it to its 30-cell
   minimum and clipped the worktree row — the field-reported failure. *)
let%expect_test "a long transcript line never moves the fixed activity column" =
  let prompt = "review the modules" in
  let long_line =
    "Reviewed the review modules end to end and confirmed every public entry "
    ^ "point in lib/tui/review_screen.mli:6, lib/tui/review_panel.mli:6, "
    ^ "lib/tui/review_rows.mli:6, lib/tui/review_diff.mli:6, and "
    ^ "lib/tui/review_compose.mli:6 lines up with its documented behaviour "
    ^ "today across the whole reviewer surface without any regressions at all."
  in
  let turn = Tui.Turn_script.complete ~prompt long_line in
  let glance =
    ( Some (Textdiff.Stats.v ~files:116 ~additions:2154 ~deletions:88),
      Mentat_workspace.Health.Live
        {
          owner = Mentat_workspace.Health.Owner.Theirs 4242;
          phase =
            Mentat_workspace.Health.Phase.Settled
              { build = Mentat_workspace.Health.Verdict.Clean; lint = None };
        } )
  in
  Tui.run ~name:"pane-repro" ~size:(220, 24) ~workspace_glance:glance
    ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |                                                                                                                                                                                │ workspace
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                                                                                                                    │   worktree · 116 files · +2154 −88
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pa9e6e3b9b                                                                                                                        │   dune · theirs · clean
    04 |                                                                                                                                                                                │
    05 | ❯ review the modules                                                                                                                                                           │
    06 |                                                                                                                                                                                │
    07 | ⏺ Reviewed the review modules end to end and confirmed every public entry point in lib/tui/review_screen.mli:6, lib/tui/review_panel.mli:6, lib/tui/review_rows.mli:6, lib/tui/│
    08 |   review_diff.mli:6, and lib/tui/review_compose.mli:6 lines up with its documented behaviour today across the whole reviewer surface without any regressions at all.           │
    09 |                                                                                                                                                                                │
    10 |                                                                                                                                                                                │
    11 |                                                                                                                                                                                │
    12 |                                                                                                                                                                                │
    13 |                                                                                                                                                                                │
    14 |                                                                                                                                                                                │
    15 |                                                                                                                                                                                │
    16 |                                                                                                                                                                                │
    17 |                                                                                                                                                                                │
    18 |                                                                                                                                                                                │
    19 |                                                                                                                                                                                │
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    24 |   ! not logged in · /login · ~/mentat-tui-pa9e6e3b9b · openai/gpt-5.5 · ! full access                                                                                                                      ? for shortcuts
    |}]

(* The dune row's remaining shapes: a failed build that printed only warnings
   warns rather than erroring, a lint count rides as a suffix, and a mid-build
   watch shows its status word instead of a verdict. *)
let%expect_test "dune row renders warnings with lint, and a building watch" =
  let prompt = "just answer" in
  let turn = Tui.Turn_script.complete ~prompt "Done." in
  let warned =
    ( None,
      Mentat_workspace.Health.Live
        {
          owner = Mentat_workspace.Health.Owner.Theirs 4242;
          phase =
            Mentat_workspace.Health.Phase.Settled
              {
                build =
                  Mentat_workspace.Health.Verdict.Failing
                    { errors = 0; warnings = 2 };
                lint = Some 3;
              };
        } )
  in
  Tui.run ~name:"pane-dune-warned" ~size:(120, 12) ~workspace_glance:warned
    ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |                                                                                 │ workspace
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   dune · theirs · 2 warnings · 3 lint
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-dun794b9825                   │
    04 |                                                                                 │
    05 | ❯ just answer                                                                   │
    06 |                                                                                 │
    07 | ⏺ Done.                                                                         │
    08 |
    09 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    10 | ❯ message mentat
    11 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    12 |   ! not logged in · /login · ~/mentat-tui-pane-dun794b9825 · openai/gpt-5.5 · ! full access            ? for shortcuts
    |}];
  let building =
    ( None,
      Mentat_workspace.Health.Live
        {
          owner = Mentat_workspace.Health.Owner.Theirs 4242;
          phase = Mentat_workspace.Health.Phase.Building;
        } )
  in
  Tui.run ~name:"pane-dune-building" ~size:(120, 12) ~workspace_glance:building
    ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |                                                                                 │ workspace
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   dune · theirs · building
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-dune-1d74279b                 │
    04 |                                                                                 │
    05 | ❯ just answer                                                                   │
    06 |                                                                                 │
    07 | ⏺ Done.                                                                         │
    08 |
    09 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    10 | ❯ message mentat
    11 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    12 |   ! not logged in · /login · ~/mentat-tui-pane-dune-1d74279b · openai/gpt-5.5 · ! full access          ? for shortcuts
    |}]

(* The supervisor's off reasons name themselves muted: no dune on the command
   PATH, and a give-up after successive spawned watches died before coming
   up. A disabled lane and plain absence still render no row at all. *)
let%expect_test "dune row names the supervisor's off reasons" =
  let prompt = "watch off" in
  let turn = Tui.Turn_script.complete ~prompt "Done." in
  let no_dune =
    (None, Mentat_workspace.Health.Off Mentat_workspace.Health.Off.No_dune)
  in
  Tui.run ~name:"pane-dune-nodune" ~size:(120, 12) ~workspace_glance:no_dune
    ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |                                                                                 │ workspace
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   dune · off · not on PATH
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-dun5f783333                   │
    04 |                                                                                 │
    05 | ❯ watch off                                                                     │
    06 |                                                                                 │
    07 | ⏺ Done.                                                                         │
    08 |
    09 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    10 | ❯ message mentat
    11 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    12 |   ! not logged in · /login · ~/mentat-tui-pane-dun5f783333 · openai/gpt-5.5 · ! full access            ? for shortcuts
    |}];
  let gave_up =
    (None, Mentat_workspace.Health.Off Mentat_workspace.Health.Off.Gave_up)
  in
  Tui.run ~name:"pane-dune-gaveup" ~size:(120, 12) ~workspace_glance:gave_up
    ~turns:[ turn ]
  @@ fun t ->
  submit t prompt;
  Tui.finish_turn t;
  Tui.settle t;
  Tui.print t;
  [%expect {|
    01 |                                                                                 │ workspace
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.5 medium                     │   dune · off · gave up
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-pane-dunf070191e                   │
    04 |                                                                                 │
    05 | ❯ watch off                                                                     │
    06 |                                                                                 │
    07 | ⏺ Done.                                                                         │
    08 |
    09 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    10 | ❯ message mentat
    11 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    12 |   ! not logged in · /login · ~/mentat-tui-pane-dunf070191e · openai/gpt-5.5 · ! full access            ? for shortcuts
    |}]
