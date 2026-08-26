(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Cmdliner

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

let run ~version ?(rewrite_argv = fun argv -> argv) cmd =
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
            ~argv:(rewrite_argv argv) cmd
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
