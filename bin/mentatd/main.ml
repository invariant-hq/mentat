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
    Cmd.Env.info "MENTAT_BIN"
      ~doc:
        "The $(b,mentat) binary the daemon's child broker spawns for \
         delegated sessions, overriding the resolution of the sibling of the \
         running executable — for layouts where the two binaries do not \
         share a directory (a build tree, a test harness).";
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

let print_flag =
  Arg.(
    value & flag
    & info [ "print" ]
        ~doc:
          "Render the service unit to standard output and touch nothing: no \
           file is written, no directory created, no service manager spoken \
           to.")

let install_cmd =
  let doc = "Install mentatd as this user's resident service." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Write the user-level service unit that keeps $(b,mentatd) resident — \
         started at login, restarted on failure — and hand it to the service \
         manager: a launchd agent at \
         $(b,~/Library/LaunchAgents/dev.invarianthq.mentatd.plist) on macOS \
         ($(b,launchctl bootstrap) into the $(b,gui) domain), a systemd user \
         unit at $(b,~/.config/systemd/user/mentatd.service) on Linux \
         ($(b,systemctl --user enable)). The daemon's standard output and \
         error are appended to the same $(b,daemon.log) the $(b,--attach) \
         spawn path writes. Any other platform is refused.";
      `P
        "The unit pins the setting that lets the daemon's run children \
         outlive it — $(b,KillMode=process) under systemd, \
         $(b,AbandonProcessGroup) under launchd. Delegated children detach \
         into their own sessions and must survive a stop, restart, or crash \
         of the daemon, which adopts them when it next boots; without the \
         pin, the service manager would take mid-turn runs down with the \
         daemon. Do not edit it out — the next install overwrites edits \
         anyway.";
      `P
        "The unit names the absolute path of the binary that ran the \
         install. A binary upgraded in place is picked up at the next \
         service start; a binary that moved leaves the unit pointing at \
         nothing, and the manager fails to start it — re-run \
         $(b,mentatd install) from the new binary, which replaces the unit \
         when its content differs and says so. A file at the unit path that \
         was not written by $(b,mentatd install) is named and refused, never \
         overwritten.";
      `P
        "A daemon already running outside the service (spawned by \
         $(b,--attach)) holds the per-user claim, so the service's daemon \
         exits at startup and the manager retries until the claim frees; \
         $(b,mentatd stop) the spawned daemon to let the service take over. \
         A service manager call that fails is a loud error naming the \
         command to run manually; the written unit stays in place.";
    ]
  in
  Cmd.v
    (Cmd.info "install" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term
       Term.(const (fun print -> Service.install ~print) $ print_flag))

let uninstall_cmd =
  let doc = "Remove the resident service installed by $(b,mentatd install)." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Unload the service from the manager and remove its unit file — \
         nothing else. The daemon's store, discovery file, and logs are \
         never touched, and running run children are not signalled: the \
         unit's child-survival pin means unloading stops only the daemon \
         itself. An absent unit is a clean no-op with a note; a file at the \
         unit path that was not written by $(b,mentatd install) is named and \
         refused.";
    ]
  in
  Cmd.v
    (Cmd.info "uninstall" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const Service.uninstall $ const ()))

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
    info [ stop_cmd; install_cmd; uninstall_cmd ]

let () = Entry.run ~version:Daemon.binary_version root
