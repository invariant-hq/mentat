(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner

let version =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> "dev"

let man =
  [
    `S "DESCRIPTION";
    `P
      "$(b,mentat) is the Mentat coding agent and its sole composition root: \
       it assembles the tool catalog, resolves config and trust, constructs \
       providers, adapts the store and workspace runtime to the engine, and \
       hands each frontend a client.";
    `P
      "A bare invocation opens the interactive terminal. Use $(b,mentat run) \
       for a headless turn.";
    `S Cli_common.s_run;
    `S Cli_common.s_session;
    `S Cli_common.s_config;
    `S Cli_common.s_diagnostic;
    `S Manpage.s_common_options;
    `P
      "$(b,-v) raises the diagnostics level to $(b,info) for the whole run and \
       $(b,-vv) to $(b,debug). Both are read before any command starts, so \
       they cover startup as well, and both override $(b,MENTAT_LOG).";
  ]

let default_term = Cli_tui.default_term ~version

let envs =
  [
    Cmd.Env.info "MENTAT_LOG"
      ~doc:
        "Diagnostics log level: $(b,quiet), $(b,error), $(b,warning), \
         $(b,info), or $(b,debug). Logging is off when unset.";
    Cmd.Env.info "MENTAT_LOG_FILE"
      ~doc:
        "Append diagnostics to this absolute path instead of standard error. \
         The interactive terminal always diverts to a per-run file under the \
         state home so logging does not corrupt the screen.";
  ]

let advertised =
  [
    Cli_config.cmd;
    Cli_permission.cmd;
    Cli_models.cmd;
    Cli_auth.cmd;
    Cli_trust.trust_cmd;
    Cli_trust.untrust_cmd;
    Cli_session.cmd;
    Cli_run.cmd;
    Cli_github.cmd;
    Cli_tui.resume_cmd ~version;
    Cli_tui.review_cmd ~version;
    Cli_sandbox.cmd;
    Cli_doctor.cmd;
    Cli_skills.cmd;
    Cli_commands.cmd;
    Cli_debug.cmd;
    Cli_report.cmd ~version;
    Cli_completion.cmd;
  ]

(* cmdliner lists every registered subcommand in the parent's help and in
   completion, with no way to register one unlisted — so the internal [serve]
   verb (the broker-launched per-session server) lives outside the advertised
   group, and evaluation widens to include it only when the first subcommand
   token names it. It stays runnable, keeps its own man page (marked
   internal), and is legible in ps; it is absent from every advertised
   surface. Tokens before the verb can only be options ([-v] and friends), so
   the scan skips option-shaped tokens and stops at [--]. *)
let internal_verbs = [ "serve" ]

let names_internal_verb argv =
  let rec scan = function
    | [] | "--" :: _ -> false
    | token :: rest ->
        if String.length token > 0 && Char.equal token.[0] '-' then scan rest
        else List.mem token internal_verbs
  in
  match Array.to_list argv with [] -> false | _exe :: rest -> scan rest

let root cmds =
  let info =
    Cmd.info "mentat" ~version ~doc:"The OCaml coding agent." ~man ~envs
      ~exits:Cli_common.exits
  in
  Cmd.group ~default:default_term info cmds

(* cmdliner resolves the first token after [run] as a subcommand and does not
   fall back to the group's default term for a bare positional, so a bare
   [mentat run "do X"] would fail as an unknown command. Splice an explicit
   [start] before a bare-word (or [-] stdin) first token to preserve the
   baseline [run PROMPT] ergonomic. An option-led first token ([run --json …])
   already reaches the default [start]; the [start]/[resume]/[reply]/[review]
   subcommand names and the [run -- PROMPT] escape are left untouched. *)
let rewrite_run_prompt argv =
  match Array.to_list argv with
  (* [run -- PROMPT] escapes a prompt that collides with a subcommand
     name; splice [start] so the default term receives it, with the documented
     rule that flags precede [-- PROMPT] (bytes after [--] are prompt, by
     POSIX). *)
  | exe :: "run" :: "--" :: rest ->
      Array.of_list (exe :: "run" :: "start" :: "--" :: rest)
  | exe :: "run" :: token :: rest
    when (not
            (List.mem token
               [ "start"; "resume"; "reply"; "review"; "--help"; "-h" ]))
         && (String.equal token "-"
            || not (String.length token > 0 && Char.equal token.[0] '-')) ->
      Array.of_list (exe :: "run" :: "start" :: token :: rest)
  | _ -> argv

let () =
  let cmds =
    if names_internal_verb Sys.argv then advertised @ [ Cli_serve.cmd ]
    else advertised
  in
  Mentat_boot.Entry.run ~version ~rewrite_argv:rewrite_run_prompt (root cmds)
