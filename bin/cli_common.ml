(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner

let s_run = "RUN COMMANDS"
let s_session = "SESSION COMMANDS"
let s_config = "CONFIGURATION COMMANDS"
let s_diagnostic = "DIAGNOSTIC COMMANDS"
let exits = Exit_status.exits

let cwd =
  let doc = "Run as if $(b,mentat) were invoked in directory $(docv)." in
  Arg.(value & opt (some string) None & info [ "C"; "cwd" ] ~docv:"DIR" ~doc)

let json =
  let doc = "Emit machine-readable JSON instead of human text." in
  Arg.(value & flag & info [ "json" ] ~doc)

let session_arg =
  let doc = "Session id or a unique id prefix." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"SESSION" ~doc)

let last =
  let doc = "Target the most recent resumable session in the workspace." in
  Arg.(value & flag & info [ "last" ] ~doc)

let attach =
  let doc =
    "Run against the per-user $(b,mentat) daemon, starting it if needed (local \
     socket only). Config, trust, and command expansion stay local; the engine \
     runs in the daemon."
  in
  Arg.(value & flag & info [ "attach" ] ~doc)

(* Client-side: the attaching mentat reads both; mentatd reads neither. *)
let daemon_envs =
  [
    Cmd.Env.info "MENTAT_DAEMON_SOCKET"
      ~doc:
        "Overrides daemon discovery for $(b,--attach): connect straight to \
         this socket path — no $(b,daemon.json) is read, no daemon is \
         spawned, and no identity check runs beyond the normal handshake. A \
         socket that does not answer is a definite failure, not a fallback \
         that spawns. Leave it unset for the normal find-or-spawn behavior.";
    Cmd.Env.info "MENTATD_BIN"
      ~doc:
        "The daemon binary $(b,--attach) spawns when none is running, \
         instead of the $(b,mentatd) installed beside $(b,mentat) — for \
         layouts where the two binaries do not share a directory (a build \
         tree, a test harness).";
  ]
