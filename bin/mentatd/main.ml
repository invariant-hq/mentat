(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner

let run socket stop spawned web web_port =
  if stop then Daemon.stop ()
  else Daemon_server.serve ~socket_override:socket ~spawned ~web ~web_port

let socket_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "socket" ] ~docv:"DIR"
        ~doc:
          "Bind the daemon's unix socket under DIR instead of the default \
           per-user, per-store directory under $(b,/tmp). The choice is \
           recorded in $(b,daemon.json), so attachers follow it automatically. \
           Use this when the default path is unsuitable (an unusual $(b,/tmp), \
           a test harness).")

let stop_flag =
  Arg.(
    value & flag
    & info [ "stop" ]
        ~doc:
          "Stop the running daemon: SIGTERM the recorded process and wait for \
           it to release its claim. No daemon running is a clean no-op.")

let spawned_flag =
  Arg.(
    value & flag
    & info [ "spawned" ]
        ~doc:
          "Internal: mark this daemon as detached-spawned, so it calls \
           $(b,setsid) at startup to survive the terminal. Set by the \
           find-or-spawn path; not for direct use.")

let web_flag =
  Arg.(
    value & flag
    & info [ "web" ]
        ~doc:
          "Also serve the browser frontend on a local loopback port, over the \
           daemon's own working-directory workspace. The URL to open — \
           carrying a single-use bootstrap token — is printed to standard \
           output. The surface is html-over-the-wire behind a strict \
           same-origin edge (a $(b,SameSite=Strict) cookie, \
           $(b,Origin)/$(b,Host) checks, a strict Content-Security-Policy); it \
           renders on loopback only.")

let web_port_opt =
  Arg.(
    value
    & opt (some int) None
    & info [ "web-port" ] ~docv:"PORT"
        ~doc:
          "Bind the browser frontend to $(docv) instead of an ephemeral port. \
           Has no effect without $(b,--web).")

let man =
  [
    `S "DESCRIPTION";
    `P
      "$(b,mentatd) runs the per-user mentat daemon in the foreground: one \
       process serving many workspaces over a local unix socket, so an \
       attached client shares its engine, fence, and provider runtime.";
    `P
      "The daemon is $(b,opt-in). The in-process client remains the default; a \
       $(b,mentat) command reaches the daemon only with $(b,--attach), which \
       starts one if none is running. The standalone-versus-attach default is \
       not decided here.";
    `P
      "The daemon's captured environment makes the provider calls, so an \
       attaching client's $(b,MENTAT_*) overrides do not reach a daemon that \
       is already running with a different environment.";
    `P
      "A first SIGTERM or SIGINT stops the daemon gracefully (it settles every \
       instance durable-first). Send the signal a second time to force an \
       immediate exit if a graceful teardown wedges.";
    `S "ENVIRONMENT";
    `P
      "$(b,MENTAT_DAEMON_SOCKET) overrides discovery: when set to a daemon's \
       socket path, $(b,--attach) connects straight to that socket — no \
       $(b,daemon.json) is read, no daemon is spawned, and no identity check \
       runs beyond the normal handshake. A socket that does not answer is a \
       definite failure, not a fallback that spawns. Leave it unset for the \
       normal find-or-spawn behavior.";
  ]

let envs =
  [
    Cmd.Env.info "MENTAT_LOG"
      ~doc:
        "Diagnostics log level: $(b,quiet), $(b,error), $(b,warning), \
         $(b,info), or $(b,debug). Logging is off when unset.";
    Cmd.Env.info "MENTAT_LOG_FILE"
      ~doc:
        "Append diagnostics to this absolute path instead of standard error.";
  ]

let root =
  let doc = "The mentat daemon." in
  let info =
    Cmd.info "mentatd" ~version:Daemon.binary_version ~doc ~man ~envs
      ~exits:Exit_status.exits
  in
  Cmd.v info
    (Exit_status.term
       Term.(
         const run $ socket_opt $ stop_flag $ spawned_flag $ web_flag
         $ web_port_opt))

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
      Log_setup.started ~version:Daemon.binary_version ~argv;
      (* [~catch:false] routes any exception escaping the responder to the
         top-level guard below instead of cmdliner's own
         exit-125-with-backtrace handler; cmdliner styling on the
         help/usage/error paths is stripped through the formatters. *)
      let code =
        match
          Cmd.eval' ~catch:false ~help:Output.help_ppf ~err:Output.err_ppf
            ~argv root
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
                  Log_setup.write_crash_report ~version:Daemon.binary_version
                    ~backtrace ~getenv:Sys.getenv_opt
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
