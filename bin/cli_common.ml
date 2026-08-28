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
