(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner

let serve socket stop spawned web web_port ingress_port github_base_url
    routine_git_base =
  if stop then Daemon.stop ()
  else
    Daemon_server.serve ~socket_override:socket ~spawned ~web ~web_port
      ~ingress_port ~github_base_url ~routine_git_base

(* TCP ports live in 0–65535. An out-of-range value would raise only at
   bind time — or persist a permanently failing service unit — so both
   surfaces refuse it as a usage error at the flag. *)
let port_conv =
  let parse s =
    match int_of_string_opt s with
    | Some port when 0 <= port && port <= 65535 -> Ok port
    | Some _ | None ->
        Error (`Msg "PORT must be an integer between 0 and 65535")
  in
  Arg.conv (parse, Format.pp_print_int)

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
    & opt (some port_conv) None
    & info [ "web-port" ] ~docv:"PORT"
        ~doc:
          "Bind the browser frontend to $(docv) instead of an ephemeral port. \
           Has no effect without $(b,--web).")

let ingress_port_opt =
  Arg.(
    value
    & opt (some port_conv) None
    & info [ "ingress-port" ] ~docv:"PORT"
        ~doc:
          "Also bind the webhook ingress on $(b,127.0.0.1:)$(docv) ($(b,0) \
           takes an ephemeral port; the bound address is printed to standard \
           output). The listener answers only the pre-auth \
           $(b,POST /ingress/github/…) family — every delivery is \
           authenticated end-to-end by its HMAC signature, so any tunnel the \
           owner already trusts can point at it. Without this flag the \
           ingress family still rides the daemon's unix wire socket, and the \
           reconcile sweep keeps webhook routines converging with no ingress \
           at all.")

let github_base_url_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "github-base-url" ] ~docv:"URL"
        ~doc:
          "The GitHub API base for the routine node's reads and its \
           publication children — for GitHub Enterprise hosts and offline \
           test servers. Deliberately a flag, never the ambient \
           $(b,MENTAT_GITHUB_BASE_URL): an environment-writable API base \
           would redirect Bearer-token requests, so the daemon scrubs the \
           variable from every child it spawns and substitutes this value \
           when given.")

let routine_git_base_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "routine-git-base" ] ~docv:"BASE"
        ~doc:
          "Override the git host prefix routine checkouts fetch from: each \
           routine's remote is $(docv)$(b,/<owner>/<repo>.git), derived from \
           the repository it watches ($(b,https://github.com) by default) — \
           for GitHub Enterprise hosts and offline test fixtures, and one \
           flag serves routines over many repositories. A flag for the same \
           reason as $(b,--github-base-url): the node takes its remotes from \
           validated configuration, never from the environment.")

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
    `S "ROUTINES";
    `P
      "The daemon is also the resident routine node: it serves the webhook \
       ingress for every routine installed by $(b,mentatd routine add), drives \
       admitted deliveries through the routine fire pipeline (each run is a \
       spawned $(b,mentat) child, never in-process), and reconciles every \
       routine's durable record — at boot, and on a periodic beat — so an \
       interrupted run is settled honestly and an interrupted publication is \
       finished without a fresh run. Routines register by file: one installed \
       or edited while the daemon runs is in force at its next event, with no \
       restart.";
    `P
      "$(b,--ingress-port) binds the loopback listener a webhook tunnel \
       points at; $(b,--github-base-url) and $(b,--routine-git-base) override \
       the GitHub API base and the git host checkouts fetch from. All three \
       are flags on this daemon's own surface, deliberately never read from \
       the environment. A daemon holding at least one enabled webhook routine \
       never stops itself as idle — the routine is a standing commission, and \
       the service manager restarts failures only, so a clean idle-stop would \
       leave later deliveries bouncing.";
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
        "The $(b,mentat) binary spawned for children — the child broker's \
         delegated sessions and the routine pipeline's run and publication \
         children — overriding the resolution of the sibling of the \
         running executable, for layouts where the two binaries do not \
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

let install_ingress_port_opt =
  Arg.(
    value
    & opt (some port_conv) None
    & info [ "ingress-port" ] ~docv:"PORT"
        ~doc:
          "Bake $(b,--ingress-port)=$(docv) into the unit's exec line, so \
           the resident daemon binds the webhook ingress at every start. \
           The bound address is recorded in $(b,daemon.json) and the daemon \
           log.")

let install_github_base_url_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "github-base-url" ] ~docv:"URL"
        ~doc:
          "Bake $(b,--github-base-url)=$(docv) into the unit's exec line — \
           the GitHub API base for the resident routine node's reads and \
           its publication children, for GitHub Enterprise hosts.")

let install_routine_git_base_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "routine-git-base" ] ~docv:"BASE"
        ~doc:
          "Bake $(b,--routine-git-base)=$(docv) into the unit's exec line — \
           the git host prefix routine checkouts fetch from, for GitHub \
           Enterprise hosts whose repositories exist nowhere else.")

let install_web_flag =
  Arg.(
    value & flag
    & info [ "web" ]
        ~doc:
          "Bake $(b,--web) into the unit's exec line, so the resident \
           daemon serves the browser frontend — and the routines dashboard \
           at $(b,/routines) — at every start. Only one daemon claims a \
           store, so a service-managed daemon's dashboard exists only this \
           way. The URL to open, bootstrap token included, is recorded in \
           $(b,daemon.json), never printed to the service log.")

let install_web_port_opt =
  Arg.(
    value
    & opt (some port_conv) None
    & info [ "web-port" ] ~docv:"PORT"
        ~doc:
          "Bake $(b,--web-port)=$(docv) into the unit's exec line, pinning \
           the browser frontend's loopback port across restarts. Has no \
           effect without $(b,--web).")

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
      `P
        "$(b,--ingress-port), $(b,--github-base-url), \
         $(b,--routine-git-base), $(b,--web), and $(b,--web-port) are the \
         daemon's own serve flags, baked into the unit's exec line so the \
         resident daemon starts with them at every boot — $(b,--web) is \
         the only way a service-managed daemon serves the browser frontend \
         and the $(b,/routines) dashboard, since only one daemon claims a \
         store. Re-running $(b,mentatd install) with different flags \
         replaces the unit and restarts the service on the new exec line.";
    ]
  in
  Cmd.v
    (Cmd.info "install" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term
       Term.(
         const
           (fun print ingress_port github_base_url routine_git_base web
                web_port ->
             Service.install ~print ~ingress_port ~github_base_url
               ~routine_git_base ~web ~web_port)
         $ print_flag $ install_ingress_port_opt $ install_github_base_url_opt
         $ install_routine_git_base_opt $ install_web_flag
         $ install_web_port_opt))

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
           $ web_port_opt $ ingress_port_opt $ github_base_url_opt
           $ routine_git_base_opt))
    info [ stop_cmd; install_cmd; uninstall_cmd; Routine_cli.cmd ]

let () = Entry.run ~version:Daemon.binary_version root
