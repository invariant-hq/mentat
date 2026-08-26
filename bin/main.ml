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

let root =
  let info =
    Cmd.info "mentat" ~version ~doc:"The OCaml coding agent." ~man ~envs
      ~exits:Cli_common.exits
  in
  Cmd.group ~default:default_term info
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

(* [-v]/[-vv]/[--verbose] raise the diagnostics level for the whole process, so
   they are taken from argv here — before the reporter is installed — rather than
   declared per command: a level chosen after [Cmd.eval'] would miss every record
   composition had already emitted, which is most of what a startup failure has
   to show. They carry no value, so the flag-provenance split never arises: the
   option is present or it is not, and there is nothing to reject.

   Scanning stops at [--], after which bytes belong to a prompt. *)
let take_verbosity argv =
  let count = ref 0 in
  let rec split kept = function
    | [] -> List.rev kept
    | "--" :: rest -> List.rev_append kept ("--" :: rest)
    | ("-v" | "--verbose") :: rest ->
        incr count;
        split kept rest
    | "-vv" :: rest ->
        count := !count + 2;
        split kept rest
    | token :: rest -> split (token :: kept) rest
  in
  (* Bound before the pair is built: tuple components evaluate in unspecified
     order, so reading [count] inside the pair would read it before [split]
     traversed anything. *)
  let kept = split [] (Array.to_list argv) in
  (Array.of_list kept, !count)

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
  Output.init ();
  Printexc.record_backtrace true;
  (* Install the diagnostics reporter before [Cmd.eval'] so library log sources
     have a sink; a bad [MENTAT_LOG]/[MENTAT_LOG_FILE] is a clean runtime error
     through the same ladder, never a parse crash. *)
  let argv, verbosity = take_verbosity Sys.argv in
  match Log_setup.install ~getenv:Sys.getenv_opt ~verbosity with
  | Error status -> exit (Exit_status.to_process_code status)
  | Ok () ->
      Log_setup.started ~version ~argv;
      (* [~catch:false] routes any exception escaping a responder to the
         top-level guard below instead of cmdliner's own
         exit-125-with-backtrace handler; cmdliner styling on the
         help/usage/error paths is stripped through the formatters. *)
      let code =
        match
          Cmd.eval' ~catch:false ~help:Output.help_ppf ~err:Output.err_ppf
            ~argv:(rewrite_run_prompt argv) root
        with
        | code -> code
        | exception exn -> (
            let backtrace = Printexc.get_backtrace () in
            match Exit_status.of_exn exn with
            | Exit_status.Internal message as status ->
                (* An internal-invariant exception writes its backtrace to
                   a crash file under the state home — never to stderr, which
                   sees only a clean one-liner that names the saved report when
                   one was written. The path is known only here, so the guard
                   emits the line rather than [Exit_status.emit]. *)
                let report =
                  Log_setup.write_crash_report ~version ~backtrace
                    ~getenv:Sys.getenv_opt
                in
                let rendered =
                  match report with
                  | Some path ->
                      Printf.sprintf "%s (report saved: %s)" message path
                  | None -> message
                in
                Output.stderr_printf "mentat: internal error: %s\n" rendered;
                Exit_status.code status
            | status -> Exit_status.to_process_code status)
      in
      Output.flush_cmdliner ();
      exit code
