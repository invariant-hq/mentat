(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness
open Cli_launch_fixture
module Pty = Pty_session

let%expect_test "unknown workspace shows the complete trust gate" =
  Project.with_temp "cli-trust-visual" @@ fun project ->
  Pty.run ~trust:false ~ready:(Screen.has "Use ↑/↓ and Enter") project
  @@ fun terminal ->
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |  Mentat repository activation
    03 |
    04 |  Repository root: ~/mentat-tui-cli-trus237b7cb0
    05 |  Selection: 1 — continue restricted
    06 |
    07 |  This repository can control config, instructions, skills, Dune rules, local
    08 |  tools, evaluator, and Build-mode project processes. Activation does not
    09 |  approve operations or widen the selected sandbox.
    10 |
    11 |  ❯ 1. Continue restricted — remember this choice
    12 |     Native reads, searches, and sandboxed edits remain available. Repository-
    13 |     controlled code will not run. Files edited now may execute if you activate
    14 |     the repository later.
    15 |    2. Trust and activate this repository — remember this choice
    16 |     Repository inputs and Build processes activate after reload.
    17 |    3. Exit
    18 |     Save nothing and start no project process.
    19 |
    20 |
    21 |
    22 |
    23 |  Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.
    24 |
    |}];
  Pty.send terminal "3";
  Pty.wait_exit terminal

let%expect_test "restricted choice is remembered by the next launch" =
  Project.with_temp "cli-trust-restricted" @@ fun project ->
  Pty.run ~trust:false ~ready:(Screen.has "Use ↑/↓ and Enter") project
  @@ fun terminal ->
  Pty.send terminal "1";
  Pty.wait terminal (Screen.has "no recent sessions");
  require_trust project "untrusted";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                    dev · openai/gpt-5.6-sol medium · untrusted
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
    24 |   ! not logged in · /login · openai/gpt-5.6-so… · ! full access · ! untrusted
    |}];
  Pty.quit terminal;
  Pty.run ~trust:false project @@ fun remembered ->
  Pty.settle remembered;
  Screen.print ~project (Pty.screen remembered);
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                    dev · openai/gpt-5.6-sol medium · untrusted
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
    24 |   ! not logged in · /login · openai/gpt-5.6-so… · ! full access · ! untrusted
    |}];
  Pty.quit remembered

let%expect_test
    "Enter accepts and remembers the visibly selected restricted default" =
  Project.with_temp "cli-trust-enter-default" @@ fun project ->
  Pty.run ~trust:false ~ready:(Screen.has "Use ↑/↓ and Enter") project
  @@ fun terminal ->
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  Pty.send terminal "\r";
  Pty.wait terminal (Screen.has "no recent sessions");
  require_trust project "untrusted";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  Pty.quit terminal;
  [%expect
    {|
    01 |
    02 |  Mentat repository activation
    03 |
    04 |  Repository root: ~/mentat-tui-cli-trust-enter9ae4ae20
    05 |  Selection: 1 — continue restricted
    06 |
    07 |  This repository can control config, instructions, skills, Dune rules, local
    08 |  tools, evaluator, and Build-mode project processes. Activation does not
    09 |  approve operations or widen the selected sandbox.
    10 |
    11 |  ❯ 1. Continue restricted — remember this choice
    12 |     Native reads, searches, and sandboxed edits remain available. Repository-
    13 |     controlled code will not run. Files edited now may execute if you activate
    14 |     the repository later.
    15 |    2. Trust and activate this repository — remember this choice
    16 |     Repository inputs and Build processes activate after reload.
    17 |    3. Exit
    18 |     Save nothing and start no project process.
    19 |
    20 |
    21 |
    22 |
    23 |  Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.
    24 |
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                    dev · openai/gpt-5.6-sol medium · untrusted
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
    24 |   ! not logged in · /login · openai/gpt-5.6-so… · ! full access · ! untrusted
    |}]

let fake_dune project =
  let bin = Project.path project "fake-bin" in
  let marker = Project.scratch project "dune-spawned" in
  Unix.mkdir bin 0o700;
  let executable = Filename.concat bin "dune" in
  Project.write_path executable
    (Printf.sprintf "#!/bin/sh\nprintf spawned > %s\nexit 1\n"
       (Filename.quote marker));
  Unix.chmod executable 0o700;
  ( marker,
    [
      ("PATH", bin ^ ":" ^ Sys.getenv "PATH");
      ("MENTAT_WORKSPACE_TOOLING", "auto");
    ] )

let%expect_test "trusted selection is coherent and starts no project process" =
  Project.with_temp "cli-trust-selected" @@ fun project ->
  let marker, env = fake_dune project in
  Pty.run ~trust:false ~env ~ready:(Screen.has "Use ↑/↓ and Enter") project
  @@ fun terminal ->
  require
    (not (Sys.file_exists marker))
    "a project-controlled process started before trust";
  Pty.send terminal "\027[B";
  Pty.wait terminal (Screen.has "Selection: 2");
  require
    (not (Sys.file_exists marker))
    "selection alone started a project-controlled process";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |  Mentat repository activation
    03 |
    04 |  Repository root: ~/mentat-tui-cli-trust-7ddbe1f1
    05 |  Selection: 2 — trust and activate this repository
    06 |
    07 |  This repository can control config, instructions, skills, Dune rules, local
    08 |  tools, evaluator, and Build-mode project processes. Activation does not
    09 |  approve operations or widen the selected sandbox.
    10 |
    11 |    1. Continue restricted — remember this choice
    12 |     Native reads, searches, and sandboxed edits remain available. Repository-
    13 |     controlled code will not run. Files edited now may execute if you activate
    14 |     the repository later.
    15 |  ❯ 2. Trust and activate this repository — remember this choice
    16 |     Repository inputs and Build processes activate after reload.
    17 |    3. Exit
    18 |     Save nothing and start no project process.
    19 |
    20 |
    21 |
    22 |
    23 |  Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.
    24 |
    |}];
  Pty.send terminal "\r";
  Pty.wait terminal (Screen.has "no recent sessions");
  require_trust project "trusted";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                          dev · openai/gpt-5.6-sol medium
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
    24 |   ! not logged in · /login · ~/men… · openai/gpt-5.6-sol… · ! full access ? f…
    |}];
  Pty.quit terminal

let exit_prompt name input =
  Project.with_temp name @@ fun project ->
  Pty.run ~trust:false ~ready:(Screen.has "Use ↑/↓ and Enter") project
  @@ fun terminal ->
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  Pty.send terminal input;
  Pty.wait_exit terminal;
  require
    (not (Sys.file_exists (trust_store project)))
    "exiting the trust prompt persisted a decision";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal)

let%expect_test "Escape and EOF show the complete prompt before exiting" =
  exit_prompt "cli-trust-escape" "\027";
  [%expect
    {|
    01 |
    02 |  Mentat repository activation
    03 |
    04 |  Repository root: ~/mentat-tui-cli-trus214cdf7f
    05 |  Selection: 1 — continue restricted
    06 |
    07 |  This repository can control config, instructions, skills, Dune rules, local
    08 |  tools, evaluator, and Build-mode project processes. Activation does not
    09 |  approve operations or widen the selected sandbox.
    10 |
    11 |  ❯ 1. Continue restricted — remember this choice
    12 |     Native reads, searches, and sandboxed edits remain available. Repository-
    13 |     controlled code will not run. Files edited now may execute if you activate
    14 |     the repository later.
    15 |    2. Trust and activate this repository — remember this choice
    16 |     Repository inputs and Build processes activate after reload.
    17 |    3. Exit
    18 |     Save nothing and start no project process.
    19 |
    20 |
    21 |
    22 |
    23 |  Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.
    24 |
    01 |
    02 | Exited without saving a workspace trust decision.
    03 |
    04 |
    05 |
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
    21 |
    22 |
    23 |
    24 |
    |}];
  exit_prompt "cli-trust-eof" "\004";
  [%expect
    {|
    01 |
    02 |  Mentat repository activation
    03 |
    04 |  Repository root: ~/mentat-tui-cli-tdcdec4d6
    05 |  Selection: 1 — continue restricted
    06 |
    07 |  This repository can control config, instructions, skills, Dune rules, local
    08 |  tools, evaluator, and Build-mode project processes. Activation does not
    09 |  approve operations or widen the selected sandbox.
    10 |
    11 |  ❯ 1. Continue restricted — remember this choice
    12 |     Native reads, searches, and sandboxed edits remain available. Repository-
    13 |     controlled code will not run. Files edited now may execute if you activate
    14 |     the repository later.
    15 |    2. Trust and activate this repository — remember this choice
    16 |     Repository inputs and Build processes activate after reload.
    17 |    3. Exit
    18 |     Save nothing and start no project process.
    19 |
    20 |
    21 |
    22 |
    23 |  Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.
    24 |
    01 |
    02 | Exited without saving a workspace trust decision.
    03 |
    04 |
    05 |
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
    21 |
    22 |
    23 |
    24 |
    |}]

let%expect_test "a trust-store failure stays visible and permits retry" =
  Project.with_temp "cli-trust-save-retry" @@ fun project ->
  Pty.run ~trust:false ~ready:(Screen.has "Use ↑/↓ and Enter") project
  @@ fun terminal ->
  let config = Project.scratch project "config/mentat" in
  let lock = Filename.concat config "trust.json.lock" in
  Unix.mkdir config 0o700;
  Unix.mkdir lock 0o700;
  Pty.send terminal "2";
  Pty.wait terminal (fun screen ->
      Screen.contains screen "Could not save the decision"
      && Screen.contains screen "Escape or Ctrl+C exits.");
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |  Mentat repository activation
    03 |
    04 |  Repository root: ~/mentat-tui-cli-trust-sa2524971f
    05 |  Selection: 2 — trust and activate this repository
    06 |
    07 |  Could not save the decision: /tmp/mentat-tui-cli-trust-sa2524971f.home/mentat-
    08 |  tui-cli-trust-sa2524971f.xdg/config/mentat/trust.json: /tmp/mentat-tui-cli-
    09 |  trust-sa2524971f.home/mentat-tui-cli-trust-sa2524971f.xdg/config/mentat/
    10 |  trust.json.lock: Is a directory
    11 |
    12 |  This repository can control config, instructions, skills, Dune rules, local
    13 |  tools, evaluator, and Build-mode project processes. Activation does not
    14 |  approve operations or widen the selected sandbox.
    15 |
    16 |    1. Continue restricted — remember this choice
    17 |     Native reads, searches, and sandboxed edits remain available. Repository-
    18 |     controlled code will not run. Files edited now may execute if you activate
    19 |     the repository later.
    20 |  ❯ 2. Trust and activate this repository — remember this choice
    21 |     Repository inputs and Build processes activate after reload.
    22 |    3. Exit
    23 |  Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.
    24 |
    |}];
  Unix.rmdir lock;
  Pty.send terminal "2";
  Pty.wait terminal (fun screen ->
      Screen.contains screen "no recent sessions"
      && Screen.contains screen "! /login — no connected account"
      && Screen.contains screen "! not logged in · /login ·");
  require_trust project "trusted";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                          dev · openai/gpt-5.6-sol medium
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
    24 |   ! not logged in · /login · ~/men… · openai/gpt-5.6-sol… · ! full access ? f…
    |}];
  Pty.quit terminal

let%expect_test "failed activation rolls back visibly and permits retry" =
  Project.with_temp "cli-trust-activation-retry" @@ fun project ->
  Project.write project ".mentat/config.json"
    "{\"model\":\"missing/no-such-model\"}\n";
  Pty.run ~trust:false ~unset:[ "MENTAT_MODEL" ]
    ~ready:(Screen.has "Use ↑/↓ and Enter")
    project
  @@ fun terminal ->
  Pty.send terminal "2";
  Pty.wait terminal (Screen.has "returned to restricted mode");
  require_trust project "untrusted";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |  Mentat repository activation
    03 |
    04 |  Repository root: ~/mentat-tui-cli-trust-activatifb9ad62b
    05 |  Selection: 1 — continue restricted
    06 |
    07 |  Repository activation failed: unknown provider "missing"; known providers:
    08 |  openai, anthropic, google, local, ollama, opencode-go
    09 |  The repository was returned to restricted mode.
    10 |
    11 |  This repository can control config, instructions, skills, Dune rules, local
    12 |  tools, evaluator, and Build-mode project processes. Activation does not
    13 |  approve operations or widen the selected sandbox.
    14 |
    15 |  ❯ 1. Continue restricted — remember this choice
    16 |     Native reads, searches, and sandboxed edits remain available. Repository-
    17 |     controlled code will not run. Files edited now may execute if you activate
    18 |     the repository later.
    19 |    2. Trust and activate this repository — remember this choice
    20 |     Repository inputs and Build processes activate after reload.
    21 |    3. Exit
    22 |     Save nothing and start no project process.
    23 |  Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.
    24 |
    |}];
  Unix.unlink (Project.path project ".mentat/config.json");
  Pty.send terminal "2";
  Pty.wait terminal (Screen.has "no recent sessions");
  require_trust project "trusted";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |
    03 |
    04 |
    05 |                           █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·
    06 |                           █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂
    07 |
    08 |                          dev · openai/gpt-5.6-sol medium
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
    24 |   ! not logged in · /login · ~/men… · openai/gpt-5.6-sol … · ! full access ? …
    |}];
  Pty.quit terminal
