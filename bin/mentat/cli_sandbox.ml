(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Cfg = Mentat_config
module Sandbox = Mentat_sandbox
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

let docs = Cli_common.s_diagnostic

let configured_read t =
  Cfg.Resolved.get Cfg.Field.sandbox_read (Composition.config t)

let configured_network t =
  Cfg.Resolved.get Cfg.Field.sandbox_network (Composition.config t)

let json_roots roots =
  Output.Json.list
    (List.map
       (fun (label, path) ->
         Output.Json.obj
           [
             ("label", Output.Json.string label);
             ("path", Output.Json.string (Lpath.Abs.to_string path));
           ])
       roots)

(* F7: the run-start posture block. Configured-posture only (no seal), so a run
   pays nothing to announce what it is about to run under. *)
let print_run_posture t =
  Output.stderr_printf "mentat: sandbox: %s (read %s, network %s)\n"
    (Cfg.Mode.to_string (Composition.configured_sandbox_mode t))
    (Cfg.Read.to_string (configured_read t))
    (Sandbox.Policy.Network.to_string (configured_network t))

(* status. *)

let status json cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match
        Composition.resolve_workspace t
          ~mode:(Composition.configured_sandbox_mode t)
          ~network:(configured_network t)
      with
      | Error status -> status
      | Ok cap ->
          let mode =
            Cfg.Mode.to_string (Composition.configured_sandbox_mode t)
          in
          let read = Cfg.Read.to_string (configured_read t) in
          let network =
            Sandbox.Policy.Network.to_string (configured_network t)
          in
          let evidence = Mentat_workspace_io.evidence cap in
          let roots = Mentat_workspace_io.describe_roots cap in
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string
                 (Output.Json.envelope ~type_:"sandbox.status"
                    [
                      ("mode", Output.Json.string mode);
                      ("read", Output.Json.string read);
                      ("network", Output.Json.string network);
                      ("evidence", Sandbox.Evidence.to_json evidence);
                      ("roots", json_roots roots);
                    ]))
          else (
            Output.stdout_printf "mode=%s\n" mode;
            Output.stdout_printf "read=%s\n" read;
            Output.stdout_printf "network=%s\n" network;
            Output.stdout_printf "evidence=%s\n"
              (Format.asprintf "%a" Sandbox.Evidence.pp evidence);
            List.iter
              (fun (label, path) ->
                Output.stdout_printf "root=%s %s\n" label
                  (Lpath.Abs.to_string path))
              roots);
          Exit_status.Success)

let status_cmd =
  let doc = "Show the effective sandbox posture." in
  Cmd.v
    (Cmd.info "status" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const status $ Cli_common.json $ Cli_common.cwd))

(* explain. *)

let json_abs_list paths =
  Output.Json.list
    (List.map (fun p -> Output.Json.string (Lpath.Abs.to_string p)) paths)

let policy_json p =
  Output.Json.obj
    [
      ( "reads_default",
        Output.Json.string
          (match Sandbox.Policy.reads_default p with
          | Sandbox.Policy.All -> "all"
          | Sandbox.Policy.Denied -> "denied") );
      ( "entries",
        Output.Json.list
          (List.map
             (fun (path, access) ->
               Output.Json.obj
                 [
                   ("path", Output.Json.string (Lpath.Abs.to_string path));
                   ( "access",
                     Output.Json.string (Sandbox.Policy.Access.to_string access)
                   );
                 ])
             (Sandbox.Policy.entries p)) );
      ("writable_roots", json_abs_list (Sandbox.Policy.writable_roots p));
      ("denied_paths", json_abs_list (Sandbox.Policy.denied_paths p));
      ( "network",
        Output.Json.string
          (Sandbox.Policy.Network.to_string (Sandbox.Policy.network p)) );
    ]

let explain json cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match
        Composition.resolve_workspace t
          ~mode:(Composition.configured_sandbox_mode t)
          ~network:(configured_network t)
      with
      | Error status -> status
      | Ok cap ->
          let identity =
            Format.asprintf "%a" Sandbox.Identity.pp
              (Mentat_workspace_io.identity cap)
          in
          let evidence = Mentat_workspace_io.evidence cap in
          let policy = Mentat_workspace_io.policy cap in
          let roots = Mentat_workspace_io.describe_roots cap in
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string
                 (Output.Json.envelope ~type_:"sandbox.explain"
                    [
                      ("identity", Output.Json.string identity);
                      ("evidence", Sandbox.Evidence.to_json evidence);
                      ( "policy",
                        match policy with
                        | None -> Output.Json.null
                        | Some p -> policy_json p );
                      ("roots", json_roots roots);
                    ]))
          else (
            Output.stdout_printf "identity=%s\n" identity;
            Output.stdout_printf "evidence=%s\n"
              (Format.asprintf "%a" Sandbox.Evidence.pp evidence);
            (match policy with
            | None -> Output.stdout_printf "policy=unconfined\n"
            | Some p ->
                Output.stdout_printf "network=%s\n"
                  (Sandbox.Policy.Network.to_string (Sandbox.Policy.network p));
                (match Sandbox.Policy.reads_default p with
                | Sandbox.Policy.All -> Output.stdout_printf "read=all\n"
                | Sandbox.Policy.Denied ->
                    Output.stdout_printf "read=denied-by-default\n");
                (* Clauses in resolution order: a later line beneath an earlier
                   one overrides it, which is how a carveout reads. *)
                List.iter
                  (fun (path, access) ->
                    Output.stdout_printf "%s=%s\n"
                      (Sandbox.Policy.Access.to_string access)
                      (Lpath.Abs.to_string path))
                  (Sandbox.Policy.entries p));
            List.iter
              (fun (label, path) ->
                Output.stdout_printf "root=%s %s\n" label
                  (Lpath.Abs.to_string path))
              roots);
          Exit_status.Success)

let explain_cmd =
  let doc = "Explain the concrete sealed sandbox policy." in
  Cmd.v
    (Cmd.info "explain" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const explain $ Cli_common.json $ Cli_common.cwd))

let cmd =
  let doc = "Inspect the sandbox posture." in
  Cmd.group
    (Cmd.info "sandbox" ~doc ~docs ~exits:Cli_common.exits)
    [ status_cmd; explain_cmd ]
