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
      "$(b,mentat serve) runs the per-user daemon in the foreground: one \
       process serving many workspaces over a local unix socket, so an \
       attached client shares its engine, fence, and provider runtime.";
    `P
      "The daemon is $(b,opt-in). The in-process client remains the default; a \
       command reaches the daemon only with $(b,--attach), which starts one if \
       none is running. The standalone-versus-attach default is not decided \
       here.";
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

let cmd =
  let doc = "Run the per-user mentat daemon." in
  let info =
    Cmd.info "serve" ~doc ~docs:Cli_common.s_diagnostic ~man
      ~exits:Cli_common.exits
  in
  Cmd.v info
    (Exit_status.term
       Term.(
         const run $ socket_opt $ stop_flag $ spawned_flag $ web_flag
         $ web_port_opt))
