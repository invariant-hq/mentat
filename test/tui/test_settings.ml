(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness
module Config = Mentat_config

let page_up = "\027[5~"
let page_down = "\027[6~"

let submit t text =
  Tui.keys t text;
  Tui.enter t;
  Tui.settle t

let absolute_path raw =
  match Lpath.Abs.of_string raw with
  | Ok path -> path
  | Error error ->
      Windtrap.failf "invalid configuration fixture path %S: %s" raw
        (Lpath.Error.message error)

let set_config label field value config =
  match Config.set field value config with
  | Ok config -> config
  | Error error -> Windtrap.failf "%s: %s" label (Config.Error.message error)

let successful_configuration () =
  let user =
    Config.empty
    |> set_config "provider base URL"
         (Config.Field.provider_base_url (Mentat_llm.Provider.make "openai"))
         "https://visual-secret@api.example.test/v1"
    |> set_config "user max steps" Config.Field.run_max_steps 5
  in
  let overrides =
    [ Config.empty |> set_config "web enabled" Config.Field.web_enabled true ]
  in
  let env name =
    if String.equal name "MENTAT_MAX_STEPS" then Some "13" else None
  in
  match
    Config.resolve ~env
      ~user:(absolute_path "/user.json", user)
      ~extra:None
      ~workspace_config:
        (Config.Trusted
           { project = Config.Absent; project_local = Config.Absent })
      ~overrides
  with
  | Ok resolved -> Config.Resolved.view resolved
  | Error error ->
      Windtrap.failf "resolve successful configuration fixture: %s"
        (Config.Error.message error)

(* Every checkpoint is the complete numbered terminal. Paging remains visible
   in its surrounding chrome so a reviewer can judge selection, clipping,
   overflow markers, and the fixed hint row together. *)

let%expect_test "successful configuration shows values and origins" =
  Tui.run ~name:"settings-config-success" ~size:(100, 18)
    ~configuration_results:[ Ok (successful_configuration ()) ]
  @@ fun t ->
  submit t "/config";
  Tui.print t;
  [%expect
    {|
    01 |  settings ──────────────────────────────────────────────────────────────────────────────── 62 values
    02 |
    03 | config  status  usage
    04 |
    05 | Session controls below apply to the next turn only.
    06 |
    07 |      setting                    value                                   source
    08 |  ›   model                      openai/gpt-5.5 medium                   next turn                  │
    09 |      permission review          choose a next-turn request              next turn                  │
    10 |      commands.compat            true                                    default built-in comm...   │
    11 |      commands.disabled          []                                      default built-in comm...   │
    12 |      commands.enabled           true                                    default built-in comm...   │
    13 |      commands.project           true                                    default built-in comm...   │
    14 |      compaction.auto            true                                    default built-in comp...   │
    15 |      dune.lint_command          ["litany","check","--no-build","--...   default built-in dune...   │
    16 |      dune.targets               ["@check"]                              default built-in dune...   ↓
    17 |
    18 |   ↑↓ move · ←→ change · ↵ apply · tab page · / filter · esc back
    |}];
  Tui.keys t "/max_steps";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ──────────────────────────────────────────────────────────────────────────────── 62 values
    02 |   /max_steps  1 match
    03 |
    04 | config  status  usage
    05 |
    06 | Session controls below apply to the next turn only.
    07 |
    08 |      setting                    value                                    source
    09 |  ›   run.max_steps              13                                       env MENTAT_MAX_STEPS;...
    10 |
    11 |
    12 |
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |   ↑↓ select · ↵ action · esc clear filter
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.keys t "/base_url";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ──────────────────────────────────────────────────────────────────────────────── 62 values
    02 |   /base_url  1 match
    03 |
    04 | config  status  usage
    05 |
    06 | Session controls below apply to the next turn only.
    07 |
    08 |      setting                    value                                    source
    09 |  ›   providers.openai.base...   https://[REDACTED]@api.example.test/v1   user /user.json
    10 |
    11 |
    12 |
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |   ↑↓ select · ↵ action · esc clear filter
    |}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.keys t "/web.enabled";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ──────────────────────────────────────────────────────────────────────────────── 62 values
    02 |   /web.enabled  1 match
    03 |
    04 | config  status  usage
    05 |
    06 | Session controls below apply to the next turn only.
    07 |
    08 |      setting                    value                                    source
    09 |  ›   web.enabled                true                                     override
    10 |
    11 |
    12 |
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |   ↑↓ select · ↵ action · esc clear filter
    |}]

let%expect_test "config table pages within its measured body" =
  Tui.run ~name:"settings-config-page" ~size:(80, 12) @@ fun t ->
  submit t "/config";
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── unavailable
    02 |
    03 | config  status  usage
    04 |
    05 | Session controls below apply to the next turn only.
    06 |
    07 | !  configuration unavailable in the visual harness
    08 |
    09 |      setting              value                           source
    10 |  ›   model                openai/gpt-5.5 medium           next turn            ↓
    11 |
    12 |   ↑↓ move · ←→ change · ↵ apply · tab page · / filter · esc back
    |}];
  Tui.keys t page_down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── unavailable
    02 |
    03 | config  status  usage
    04 |
    05 | Session controls below apply to the next turn only.
    06 |
    07 | !  configuration unavailable in the visual harness
    08 |
    09 |      setting              value                           source
    10 |  ›   permission review    choose a next-turn request      next turn            ↑
    11 |
    12 |   ↑↓ move · ←→ change · ↵ apply · tab page · / filter · esc back
    |}];
  Tui.keys t "/jk";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── unavailable
    02 |   /jk  no matches
    03 |
    04 | config  status  usage
    05 |
    06 | Session controls below apply to the next turn only.
    07 |
    08 | !  configuration unavailable in the visual harness
    09 |
    10 | No matching settings.
    11 |
    12 |   type to filter · esc clear filter
    |}]

let%expect_test "status scroll box owns measured page keys" =
  Tui.run ~name:"settings-status-page" ~size:(80, 12) @@ fun t ->
  submit t "/status";
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── 1 providers
    02 |
    03 | config  status  usage
    04 |
    05 | Runtime                                                                        █
    06 |   version         dev                                                          █
    07 |   current model   openai/gpt-5.5 medium                                        █
    08 |   workspace       ~/mentat-tui-settings-sta0b408d23
    09 |   context window  128,000 tokens
    10 |   launch sandbox  danger-full-access
    11 |
    12 |   tab page · esc back
    |}];
  Tui.keys t page_down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── 1 providers
    02 |
    03 | config  status  usage
    04 |
    05 |   workspace       ~/mentat-tui-settings-sta0b408d23
    06 |   context window  128,000 tokens                                               ▄
    07 |   launch sandbox  danger-full-access                                           █
    08 |                                                                                █
    09 | Session                                                                        ▀
    10 |   No active session.
    11 |
    12 |   tab page · esc back
    |}];
  Tui.keys t page_up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── 1 providers
    02 |
    03 | config  status  usage
    04 |
    05 | Runtime                                                                        █
    06 |   version         dev                                                          █
    07 |   current model   openai/gpt-5.5 medium                                        █
    08 |   workspace       ~/mentat-tui-settings-sta0b408d23
    09 |   context window  128,000 tokens
    10 |   launch sandbox  danger-full-access
    11 |
    12 |   tab page · esc back
    |}]

let%expect_test "usage scroll box pages active-session metrics" =
  let usage =
    Mentat_llm.Usage.make ~input:12_345 ~cache_read:4_321 ~cache_write:123
      ~output:678 ~reasoning:90 ()
  in
  let turn =
    Tui.Turn_script.complete ~prompt:"collect usage" ~usage "Usage collected."
  in
  Tui.run ~name:"settings-usage-page" ~size:(80, 12) ~turns:[ turn ] @@ fun t ->
  submit t "collect usage";
  Tui.finish_turn t;
  Tui.settle t;
  submit t "/usage";
  Tui.print t;
  [%expect
    {|
    01 |  settings ───────────────────────────────────────────────────────── this session
    02 |
    03 | config  status  usage
    04 |
    05 | Model                                                                          █
    06 |   openai/gpt-5.5                                                               █
    07 |
    08 | Tokens
    09 |   total        17,557
    10 |   input        12,345
    11 |
    12 |   tab page · esc back
    |}];
  Tui.keys t page_down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ───────────────────────────────────────────────────────── this session
    02 |
    03 | config  status  usage
    04 |
    05 | Tokens
    06 |   total        17,557                                                          █
    07 |   input        12,345                                                          █
    08 |   cache read   4,321
    09 |   cache write  123
    10 |   output       678
    11 |
    12 |   tab page · esc back
    |}]

let%expect_test "settings queries survive a model panel overlay" =
  let turn =
    Tui.Turn_script.complete ~prompt:"open retained settings"
      "Settings owner attached."
  in
  Tui.run ~name:"settings-model-retained" ~hold_settings_queries:true
    ~turns:[ turn ]
  @@ fun t ->
  submit t "open retained settings";
  Tui.finish_turn t;
  Tui.settle t;
  submit t "/config";
  Tui.enter t;
  Tui.settle t;
  Tui.finish_settings_queries t;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── unavailable
    02 |
    03 | config  status  usage
    04 |
    05 | Session controls below apply to the next turn only.
    06 |
    07 | !  configuration unavailable in the visual harness
    08 |
    09 |      setting               value                           source
    10 |  ›   model                 openai/gpt-5.5                  next turn
    11 |      permission review     choose a next-turn request      next turn
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
    24 |   ↑↓ move · ←→ change · ↵ apply · tab page · / filter · esc back
    |}];
  (* Tab switches pages; the arrow keys never do, so their meaning never
     depends on the selected row. *)
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── 1 providers
    02 |
    03 | config  status  usage
    04 |
    05 | Runtime
    06 |   version         dev
    07 |   current model   openai/gpt-5.5
    08 |   workspace       ~/mentat-tui-settings-model-23cbcc98
    09 |   context window  128,000 tokens
    10 |   launch sandbox  danger-full-access
    11 |
    12 | Session
    13 |   id            session-visual-00001
    14 |   lifecycle     active
    15 |   phase         idle
    16 |   active model  openai/gpt-5.5
    17 |   waiting       none
    18 |   workflow      build
    19 |   last outcome  completed
    20 |
    21 | Providers
    22 |   openai  missing
    23 |
    24 |   tab page · esc back
    |}]

let%expect_test "a readiness refresh failure retains the footer fact" =
  let provider = Mentat_llm.Provider.make "openai" in
  let missing =
    Mentat_provider.Account.Discovery.Known
      (Mentat_provider.Account.missing ~provider)
  in
  let failure =
    Mentat_protocol.Error.Unavailable
      (Mentat_diagnostic.of_text "readiness refresh failed")
  in
  Tui.run ~name:"settings-readiness-retained"
    ~readiness_results:[ Ok [ missing ]; Error failure ]
  @@ fun t ->
  Tui.settle t;
  submit t "/status";
  Tui.keys t page_down;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── unavailable
    02 |
    03 | config  status  usage
    04 |
    05 | Runtime
    06 |   version         dev
    07 |   current model   openai/gpt-5.5 medium
    08 |   workspace       ~/mentat-tui-settings-readiness-cd2dfc79
    09 |   context window  128,000 tokens
    10 |   launch sandbox  danger-full-access
    11 |
    12 | Session
    13 |   No active session.
    14 |
    15 | Providers
    16 | !  readiness refresh failed
    17 |
    18 |
    19 |
    20 |
    21 |
    22 |
    23 |
    24 |   tab page · esc back
    |}];
  Tui.keys t Key.escape;
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
    24 |   ! not logged in · /login · ~/menta… · openai/gpt-5.5 m… · ! full access ? f…
    |}]

let%expect_test "Tab cycles pages and the arrow keys never leave a page" =
  Tui.run ~name:"settings-key-semantics" ~size:(80, 12) @@ fun t ->
  submit t "/config";
  (* Right on the model row does not switch pages: the arrow keys never
     navigate tabs, so their meaning never depends on the selected row. The
     footer stays on config with the model row still selected. *)
  Tui.keys t Key.right;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── unavailable
    02 |
    03 | config  status  usage
    04 |
    05 | Session controls below apply to the next turn only.
    06 |
    07 | !  configuration unavailable in the visual harness
    08 |
    09 |      setting              value                           source
    10 |  ›   model                openai/gpt-5.5 medium           next turn            ↓
    11 |
    12 |   ↑↓ move · ←→ change · ↵ apply · tab page · / filter · esc back
    |}];
  (* Tab is the page switch: config -> status -> usage -> config. *)
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── 1 providers
    02 |
    03 | config  status  usage
    04 |
    05 | Runtime                                                                        █
    06 |   version         dev                                                          █
    07 |   current model   openai/gpt-5.5 medium                                        █
    08 |   workspace       ~/mentat-tui-settings-key-se1088c88
    09 |   context window  128,000 tokens
    10 |   launch sandbox  danger-full-access
    11 |
    12 |   tab page · esc back
    |}];
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ─────────────────────────────────────────────────────────── no session
    02 |
    03 | config  status  usage
    04 |
    05 | No active session usage.
    06 |
    07 |
    08 |
    09 |
    10 |
    11 |
    12 |   tab page · esc back
    |}];
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|
    01 |  settings ────────────────────────────────────────────────────────── unavailable
    02 |
    03 | config  status  usage
    04 |
    05 | Session controls below apply to the next turn only.
    06 |
    07 | !  configuration unavailable in the visual harness
    08 |
    09 |      setting              value                           source
    10 |  ›   model                openai/gpt-5.5 medium           next turn            ↓
    11 |
    12 |   ↑↓ move · ←→ change · ↵ apply · tab page · / filter · esc back
    |}]
