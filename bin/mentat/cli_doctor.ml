(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Account = Mentat_provider.Account
module Selector = Mentat_provider.Selector
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

type level = Pass | Warn | Fail

let level_string = function Pass -> "PASS" | Warn -> "WARN" | Fail -> "FAIL"

type check = { name : string; level : level; detail : string }

(* Surface keybindings.json problems outside a TUI session: an absent file is
   silent, a rejected entry is a warning naming the reason. keybindings.json sits
   beside the resolved config file in the config home, so the parse is shared
   with the interactive launch path ({!Cli_tui.keybindings_diagnostics}) rather
   than reaching a rendering library from a host module. The [Sys.file_exists]
   gate keeps an absent file silent — distinct from a present-and-clean file,
   which reports a passing check. *)
let keybindings_check add config_file =
  let path =
    Filename.concat (Filename.dirname config_file) "keybindings.json"
  in
  if not (Sys.file_exists path) then ()
  else
    match Cli_tui.keybindings_diagnostics path with
    | [] -> add "keybindings" Pass "no problems"
    | diagnostics ->
        List.iter (fun message -> add "keybindings" Warn message) diagnostics

(* Where the diagnostics trail lives, and whether there is anything in it: a user
   told to send their log should not have to know the XDG ladder. Crash reports
   are counted, but only a fresh one warns — they are retained twenty deep, so
   warning on any at all would make a crash from last month a permanent
   complaint, and doctor's warnings are meant to be acted on. *)
let recent = 24. *. 60. *. 60.

let scan ~now dir =
  match Sys.readdir dir with
  | entries ->
      Array.fold_left
        (fun (total, freshest) name ->
          if not (Filename.check_suffix name ".log") then (total, freshest)
          else
            let age =
              match Unix.stat (Filename.concat dir name) with
              | stat -> Some (now -. stat.Unix.st_mtime)
              | exception Unix.Unix_error _ -> None
            in
            ( total + 1,
              Option.fold ~none:freshest ~some:(Float.min freshest) age ))
        (0, infinity) entries
  | exception Sys_error _ -> (0, infinity)

let diagnostics_check add state_home =
  let now = Unix.gettimeofday () in
  let logs, _ = scan ~now (Filename.concat state_home "logs") in
  let crashes, freshest_crash =
    scan ~now (Filename.concat state_home "crashes")
  in
  let detail =
    Printf.sprintf "%s (%d log(s), %d crash report(s))" state_home logs crashes
  in
  if freshest_crash <= recent then
    add "diagnostics" Warn
      (detail ^ "; a crash was reported in the last day — see CONTRIBUTING.md")
  else add "diagnostics" Pass detail

(* Probe each stage independently rather than fail-closed, so a broken config or
   store surfaces as a reported check instead of aborting doctor; the [--json]
   envelope is always emitted, even on a failed stage. Shared with [report],
   which bundles these checks instead of printing them, so a report and the
   doctor a user could have run by hand cannot disagree. *)
let checks_of_probe probe =
  let checks = ref [] in
  let add name level detail = checks := { name; level; detail } :: !checks in
  (match Composition.Probe.config probe with
  | Ok path ->
      add "config" Pass (Printf.sprintf "resolved (%s)" path);
      keybindings_check add path
  | Error reason -> add "config" Fail reason);
  (match Composition.Probe.storage probe with
  | Ok data_home ->
      add "storage" Pass (Printf.sprintf "session store at %s" data_home)
  | Error reason -> add "storage" Fail reason);
  (match Composition.Probe.sessions probe with
  | Ok (stored, 0) ->
      add "sessions" Pass (Printf.sprintf "%d stored, 0 corrupt" stored)
  | Ok (stored, corrupt) ->
      add "sessions" Fail
        (Printf.sprintf "%d corrupt of %d stored" corrupt (stored + corrupt))
  | Error _ ->
      (* The store itself did not stage; [storage] already reports the fault as
         a failure, so this stays a warning rather than double-counting. *)
      add "sessions" Warn "not scanned (storage unavailable)");
  if Composition.Probe.trusted probe then add "trust" Pass "workspace trusted"
  else
    add "trust" Warn
      "workspace not trusted; run `mentat trust .` to enable project config";
  (match Composition.Probe.accounts probe with
  | Error reason -> add "auth" Fail reason
  | Ok discoveries ->
      let connected =
        List.length (List.filter Account.Discovery.connected discoveries)
      in
      if connected = 0 then
        add "auth" Warn
          "no connected provider; run `mentat auth login <provider>`"
      else add "auth" Pass (Printf.sprintf "%d connected provider(s)" connected);
      List.iter
        (function
          | Account.Discovery.Known _ -> ()
          | Account.Discovery.Resolution_failed { provider; error } ->
              add
                ("auth:" ^ Mentat_llm.Provider.id provider)
                Fail
                (Mentat_provider.Credential_error.message error))
        discoveries);
  (match Composition.Probe.default_model probe with
  | Ok model -> add "model" Pass (Selector.to_string (Selector.of_model model))
  | Error message -> add "model" Warn message);
  (match Composition.Probe.toolchain probe with
  | Ok detail -> add "toolchain" Pass detail
  | Error reason -> add "toolchain" Warn reason);
  (match Composition.Probe.parity probe with
  | Ok detail -> add "parity" Pass detail
  | Error reason -> add "parity" Warn reason);
  (match Composition.Probe.project probe with
  | Ok detail -> add "project" Pass detail
  | Error reason -> add "project" Warn reason);
  (match Composition.Probe.dune_lane probe with
  | Ok detail -> add "dune" Pass detail
  | Error reason -> add "dune" Warn reason);
  (match Composition.Probe.lint probe with
  | Ok detail -> add "lint" Pass detail
  | Error reason -> add "lint" Warn reason);
  (* Last: the checks above are readiness, this one is a pointer to where the
     evidence lives when readiness was not the problem. *)
  (match Composition.Probe.state probe with
  | Ok state_home -> diagnostics_check add state_home
  | Error reason -> add "diagnostics" Warn reason);
  List.rev !checks

let checks_json checks =
  Output.Json.list
    (List.map
       (fun c ->
         Output.Json.obj
           [
             ("name", Output.Json.string c.name);
             ( "level",
               Output.Json.string
                 (String.lowercase_ascii (level_string c.level)) );
             ("detail", Output.Json.string c.detail);
           ])
       checks)

let probe_checks_json probe = checks_json (checks_of_probe probe)

let run json cwd =
  Composition.with_probe ~cwd (fun probe ->
      let checks = checks_of_probe probe in
      let failed = List.exists (fun c -> c.level = Fail) checks in
      if json then
        Output.stdout_printf "%s\n"
          (Output.Json.to_string
             (Output.Json.envelope ~type_:"doctor"
                [ ("checks", checks_json checks) ]))
      else
        List.iter
          (fun c ->
            Output.stdout_printf "[%s] %s: %s\n" (level_string c.level) c.name
              c.detail)
          checks;
      if failed then Exit_status.Failed else Exit_status.Success)

let cmd =
  let doc = "Diagnose configuration, storage, trust, and provider readiness." in
  let info =
    Cmd.info "doctor" ~doc ~docs:Cli_common.s_diagnostic ~exits:Cli_common.exits
  in
  Cmd.v info
    (Exit_status.term Term.(const run $ Cli_common.json $ Cli_common.cwd))
