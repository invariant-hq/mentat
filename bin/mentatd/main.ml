(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner

let serve socket stop spawned web web_port =
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
    & info [ "stop" ] ~deprecated:"use 'mentatd stop' instead"
        ~doc:"Deprecated alias of the $(b,stop) subcommand.")

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
      "$(b,MENTAT_DAEMON_SOCKET) and $(b,MENTATD_BIN) are read by the \
       attaching $(b,mentat) client, not by this daemon; they are documented \
       on the $(b,mentat) commands that offer $(b,--attach).";
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

let stop_cmd =
  let doc = "Stop the running daemon." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Stop the running daemon: SIGTERM the recorded process and wait for \
         it to release its claim. No daemon running is a clean no-op.";
    ]
  in
  Cmd.v
    (Cmd.info "stop" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const Daemon.stop $ const ()))

let root =
  let doc = "The mentat daemon." in
  let info =
    Cmd.info "mentatd" ~version:Daemon.binary_version ~doc ~man ~envs
      ~exits:Exit_status.exits
  in
  Cmd.group
    ~default:
      (Exit_status.term
         Term.(
           const serve $ socket_opt $ stop_flag $ spawned_flag $ web_flag
           $ web_port_opt))
    info [ stop_cmd ]

let () = Entry.run ~version:Daemon.binary_version root
