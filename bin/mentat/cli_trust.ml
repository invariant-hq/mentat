(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Trust_store = Mentat_boot.Trust_store

(* Two standalone commands recording a user-side decision at
   config_home/trust.json for the nearest workspace root. A "trust group"
   command is deliberately not taken here, to keep the command surface small. *)

let set_and_report t status label =
  let root = Lpath.Abs.to_string (Composition.root t) in
  let path = Mentat_boot.User_dirs.trust_file (Composition.dirs t) in
  match Trust_store.set ~path ~root status with
  | Ok () ->
      Mentat_boot.Output.stdout_printf "%s %s\n" label root;
      Exit_status.Success
  | Error e -> Exit_status.runtime (Trust_store.Error.message e)

let dir_arg =
  let doc = "The workspace directory to trust." in
  Arg.(value & pos 0 string "." & info [] ~docv:"DIR" ~doc)

let run status label dir =
  Composition.with_base ~cwd:(Some dir) ~overrides:[] (fun t ->
      set_and_report t status label)

let trust_cmd =
  let doc = "Trust a workspace so its project config and rules take effect." in
  let info =
    Cmd.info "trust" ~doc ~docs:Cli_common.s_config ~exits:Cli_common.exits
  in
  Cmd.v info
    (Exit_status.term
       Term.(const (run Trust_store.Trusted "trusted") $ dir_arg))

let untrust_cmd =
  let doc = "Untrust a workspace, disabling its project config and rules." in
  let info =
    Cmd.info "untrust" ~doc ~docs:Cli_common.s_config ~exits:Cli_common.exits
  in
  Cmd.v info
    (Exit_status.term
       Term.(const (run Trust_store.Untrusted "untrusted") $ dir_arg))
