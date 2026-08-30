(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Offline inspection of user-command discovery: [list] and [show] are pure
   views over one {!Mentat_context.Commands.load} snapshot, assembled from the
   same config/trust/root inputs the composition root feeds a run, but without
   the engine — no client, no provider call. The CLI owns the envelope shape; the
   library owns the per-command codec. *)

open! Cmdliner
module Config = Mentat_config
module Commands = Mentat_context.Commands
module Command = Commands.Command
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

let docs = Cli_common.s_diagnostic

(* An executable-minted command value always encodes; a failure is a library
   bug, classified [Internal] by the top-level guard exactly as
   {!Output.Json.to_string} treats its own encode failures. *)
let json_of codec value =
  match Jsont.Json.encode codec value with
  | Ok json -> json
  | Error message -> failwith message

(* One snapshot, from the composition base's resolved config, trust, and root. *)
let with_commands cwd f =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let user_config_file =
        Lpath.Abs.of_string_exn
          (Mentat_boot.User_dirs.config_file (Composition.dirs t))
      in
      let commands =
        Commands.load ~stdenv:(Composition.stdenv t)
          ~config:(Composition.config t) ~trusted:(Composition.trusted t)
          ~root:(Composition.root t) ~user_config_file
      in
      f (Composition.config t) commands)

(* Text rendering. *)

let bool_text value = if value then "true" else "false"

let print_policy config commands =
  let get field = Config.Resolved.get field config in
  Output.stdout_printf "Commands: %s\n"
    (if Commands.enabled commands then "enabled"
     else "disabled (commands.enabled)");
  if Commands.enabled commands then
    Output.stdout_printf "  project: %s  compat: %s\n"
      (bool_text (get Config.Field.commands_project))
      (bool_text (get Config.Field.commands_compat))

let is_active command =
  match Command.status command with Command.Active _ -> true | _ -> false

let print_active commands =
  match List.filter is_active commands with
  | [] -> Output.stdout_printf "\nActive commands: (none)\n"
  | active ->
      Output.stdout_printf "\nActive commands:\n";
      List.iteri
        (fun index command ->
          match Command.status command with
          | Command.Active content -> (
              Output.stdout_printf "  [%d] %s  %s  %s\n" (index + 1)
                (Command.name command)
                (Command.kind_string (Command.kind command))
                (Command.origin command);
              (match content.Command.description with
              | Some description ->
                  Output.stdout_printf "      %s\n" description
              | None -> ());
              match content.Command.argument_hint with
              | Some hint -> Output.stdout_printf "      args: %s\n" hint
              | None -> ())
          | _ -> ())
        active

(* The inactive reason favours the free-text detail (the shadowing winner's
   origin, an invalid candidate's message), falling back to the machine reason,
   then the bare state word. *)
let inactive_reason command =
  let status = Command.status command in
  match Command.detail_string status with
  | Some detail -> Command.state_string status ^ " " ^ detail
  | None -> (
      match Command.reason_string status with
      | Some reason -> Command.state_string status ^ " (" ^ reason ^ ")"
      | None -> Command.state_string status)

let print_inactive commands =
  match List.filter (fun command -> not (is_active command)) commands with
  | [] -> ()
  | inactive ->
      Output.stdout_printf "\nInactive commands:\n";
      List.iter
        (fun command ->
          Output.stdout_printf "  %s %s (%s)\n" (Command.name command)
            (inactive_reason command) (Command.origin command))
        inactive

let print_warnings warnings =
  Output.stdout_printf "\nWarnings:\n";
  match warnings with
  | [] -> Output.stdout_printf "  (none)\n"
  | warnings ->
      List.iter (fun warning -> Output.stdout_printf "  %s\n" warning) warnings

(* JSON envelopes. *)

let string_list values = Output.Json.list (List.map Output.Json.string values)

let config_json config =
  let get field = Config.Resolved.get field config in
  Output.Json.obj
    [
      ("enabled", Output.Json.bool (get Config.Field.commands_enabled));
      ("project", Output.Json.bool (get Config.Field.commands_project));
      ("compat", Output.Json.bool (get Config.Field.commands_compat));
      ("disabled", string_list (get Config.Field.commands_disabled));
    ]

let list_json config commands =
  Output.Json.envelope ~type_:"commands_list"
    [
      ("config", config_json config);
      ( "commands",
        Output.Json.list
          (List.map (json_of Command.jsont) (Commands.commands commands)) );
      ("warnings", string_list (Commands.warnings commands));
    ]

(* list. *)

let list json cwd =
  with_commands cwd @@ fun config commands ->
  if json then
    Output.stdout_printf "%s\n"
      (Output.Json.to_string (list_json config commands))
  else begin
    print_policy config commands;
    if Commands.enabled commands then begin
      print_active (Commands.commands commands);
      print_inactive (Commands.commands commands);
      print_warnings (Commands.warnings commands)
    end
  end;
  Exit_status.Success

let list_cmd =
  let doc = "List discovered user commands and their states." in
  Cmd.v
    (Cmd.info "list" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const list $ Cli_common.json $ Cli_common.cwd))

(* show. *)

let active_names commands =
  List.filter_map
    (fun command ->
      match Command.status command with
      | Command.Active _ -> Some (Command.name command)
      | _ -> None)
    (Commands.commands commands)

let unknown_command name commands =
  let known =
    match active_names commands with
    | [] -> "(none)"
    | names -> String.concat ", " names
  in
  Exit_status.runtime
    (Printf.sprintf "unknown command %S; available commands: %s" name known)

let find_active_command commands name =
  List.find_map
    (fun command ->
      match Command.status command with
      | Command.Active content when String.equal (Command.name command) name ->
          Some (command, content)
      | _ -> None)
    (Commands.commands commands)

let show_json command content commands =
  Output.Json.envelope ~type_:"commands_show"
    [
      ("command", json_of Command.jsont command);
      ("text", Output.Json.string content.Command.text);
      ("warnings", string_list (Commands.warnings commands));
    ]

let print_show command content commands =
  Output.stdout_printf "name: %s\n" (Command.name command);
  Output.stdout_printf "kind: %s\n" (Command.kind_string (Command.kind command));
  Output.stdout_printf "origin: %s\n" (Command.origin command);
  Output.stdout_printf "digest: %s\n" content.Command.digest;
  Output.stdout_printf "bytes: %d\n" content.Command.bytes;
  (match content.Command.description with
  | Some description -> Output.stdout_printf "description: %s\n" description
  | None -> ());
  (match content.Command.argument_hint with
  | Some hint -> Output.stdout_printf "argument hint: %s\n" hint
  | None -> ());
  (match content.Command.ignored_keys with
  | [] -> ()
  | keys ->
      Output.stdout_printf "ignored frontmatter keys: %s\n"
        (String.concat ", " keys));
  Output.stdout_printf "\n%s\n" content.Command.text;
  match Commands.warnings commands with
  | [] -> ()
  | warnings -> print_warnings warnings

let show json name cwd =
  with_commands cwd @@ fun _config commands ->
  match Commands.Name.of_string name with
  | Error message -> Exit_status.runtime message
  | Ok _ -> (
      match find_active_command commands name with
      | None -> unknown_command name commands
      | Some (command, content) ->
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string (show_json command content commands))
          else print_show command content commands;
          Exit_status.Success)

let name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"NAME" ~doc:"Command name.")

let show_cmd =
  let doc = "Show one active command's resolved template." in
  Cmd.v
    (Cmd.info "show" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const show $ Cli_common.json $ name_arg $ Cli_common.cwd))

(* group. *)

let cmd =
  let doc = "Inspect discovered user commands." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "User commands are markdown prompt templates a user invokes as \
         [/name]. This group shows what was discovered, what is active, and \
         why the rest are shadowed, disabled, or invalid.";
    ]
  in
  Cmd.group
    (Cmd.info "commands" ~doc ~docs ~man ~exits:Cli_common.exits)
    [ list_cmd; show_cmd ]
