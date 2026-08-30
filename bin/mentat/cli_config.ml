(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Config = Mentat_config
module Catalog = Mentat_provider.Catalog
module View = Config.Resolved.View
module Entry = View.Entry
module Argv = Mentat_boot.Argv
module Composition = Mentat_boot.Composition
module Config_io = Mentat_boot.Config_io
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

let docs = Cli_common.s_config

(* One consistent enveloping discipline for every config JSON output: no
   bare/enveloped inconsistency across commands. *)

let layer_arg =
  let doc_of name = Printf.sprintf "Operate on the %s config layer." name in
  Arg.(
    value
    & vflag Config_io.User
        [
          (Config_io.User, info [ "user" ] ~doc:(doc_of "user"));
          (Config_io.Project, info [ "project" ] ~doc:(doc_of "shared project"));
          ( Config_io.Project_local,
            info [ "project-local" ] ~doc:(doc_of "gitignored project-local") );
        ])

let key_arg =
  let doc = "A supported config key." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"KEY" ~doc)

(* path. *)

let path layer cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      Output.stdout_printf "%s\n"
        (Config_io.layer_path ~dirs:(Composition.dirs t)
           ~root:(Composition.root t) layer);
      Exit_status.Success)

let path_cmd =
  let doc = "Print a config file path." in
  Cmd.v
    (Cmd.info "path" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const path $ layer_arg $ Cli_common.cwd))

(* show. *)

(* The effective configuration as key, rendered value, and optional provenance.
   A secret-bearing field projects as [Redacted] at the view, so no consumer of
   this — [show], or a report bundle a user mails to a maintainer — can reach a
   credential through it. *)
let entries t ~origins =
  let view = Config.Resolved.view (Composition.config t) in
  List.map
    (fun entry ->
      let value =
        match Entry.value entry with
        | View.Value.Shown { text; json = _ } -> text
        | View.Value.Redacted -> "[REDACTED]"
      in
      let origin =
        if origins then
          Some
            (Config.Source.kind_string
               (Config.Origin.source (Entry.origin entry)))
        else None
      in
      (Entry.key entry, value, origin))
    (View.entries view)

let trust_string t = if Composition.trusted t then "trusted" else "untrusted"

(* Resolution warnings name config input that did not take effect: a workspace
   key outside the shared allowlist, a file dropped by trust, a clamped budget.
   Without a print here the fact reaches only the TUI settings screen, and a key
   that does nothing looks exactly like a key that works.

   [about] narrows the report to one key: reading a single value should explain
   that value, not every other key the same file lost. A file-level warning —
   an unparseable or trust-disabled workspace file — bears on every key and
   survives the filter. *)
let print_warnings ?about t =
  let bears_on warning =
    match (about, Config.Warning.field warning) with
    | None, _ | _, None -> true
    | Some (Config.Field.Any about), Some (Config.Field.Any field) ->
        String.equal (Config.Field.name about) (Config.Field.name field)
  in
  List.iter
    (fun warning ->
      if bears_on warning then
        Output.stderr_printf "mentat: warning: %s\n"
          (Format.asprintf "%a" Config.Warning.pp warning))
    (Config.Resolved.warnings (Composition.config t))

(* A report always carries provenance: "which layer set this" is most of the
   answer to a configuration bug. *)
let resolved_json t =
  let values =
    List.map
      (fun (name, value, origin) ->
        ( name,
          Output.Json.obj
            [
              ("value", Output.Json.string value);
              ( "source",
                Output.Json.string (Option.value origin ~default:"unknown") );
            ] ))
      (entries t ~origins:true)
  in
  Output.Json.obj
    [
      ("workspace_trust", Output.Json.string (trust_string t));
      ("values", Output.Json.obj values);
    ]

let show json origins cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      print_warnings t;
      let fields = entries t ~origins in
      let trust = trust_string t in
      if json then
        let field_json =
          List.map
            (fun (name, value, origin) ->
              match origin with
              | Some source ->
                  ( name,
                    Output.Json.obj
                      [
                        ("value", Output.Json.string value);
                        ("source", Output.Json.string source);
                      ] )
              | None -> (name, Output.Json.string value))
            fields
        in
        Output.stdout_printf "%s\n"
          (Output.Json.to_string
             (Output.Json.envelope ~type_:"config"
                [
                  ("workspace_trust", Output.Json.string trust);
                  ("values", Output.Json.obj field_json);
                ]))
      else (
        List.iter
          (fun (name, value, origin) ->
            match origin with
            | Some source ->
                Output.stdout_printf "%s=%s (%s)\n" name value source
            | None -> Output.stdout_printf "%s=%s\n" name value)
          fields;
        Output.stdout_printf "workspace_trust=%s\n" trust);
      Exit_status.Success)

let origins_flag =
  Arg.(value & flag & info [ "origins" ] ~doc:"Include each value's source.")

let show_cmd =
  let doc = "Show effective configuration." in
  Cmd.v
    (Cmd.info "show" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const show $ Cli_common.json $ origins_flag $ Cli_common.cwd))

(* get. *)

let get json layer_opt key cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Argv.config_key key with
      | Error status -> status
      | Ok (Config.Field.Any field as any) -> (
          print_warnings ~about:any t;
          let value =
            match layer_opt with
            | None -> Config.Resolved.text field (Composition.config t)
            | Some layer -> (
                match
                  Config_io.read_layer ~dirs:(Composition.dirs t)
                    ~root:(Composition.root t) layer
                with
                | Error _ -> None
                | Ok config -> Config.text field config)
          in
          match value with
          | None ->
              (* On the [--json] path an unset value is an enveloped
                 error on stdout, not a bare [mentat:] line. *)
              let message = Printf.sprintf "%s is not set" key in
              if json then (
                Output.json_error ~type_:"config.value" message;
                Exit_status.Failed)
              else Exit_status.runtime message
          | Some value ->
              if json then
                Output.stdout_printf "%s\n"
                  (Output.Json.to_string
                     (Output.Json.envelope ~type_:"config.value"
                        [
                          ("key", Output.Json.string key);
                          ("value", Output.Json.string value);
                        ]))
              else Output.stdout_printf "%s\n" value;
              Exit_status.Success))

(* An optional layer for reads: no flag reads the effective value. *)
let read_layer_arg =
  Arg.(
    value
    & vflag None
        [
          (Some Config_io.User, info [ "user" ]);
          (Some Config_io.Project, info [ "project" ]);
          (Some Config_io.Project_local, info [ "project-local" ]);
        ])

let get_cmd =
  let doc = "Read a config value." in
  Cmd.v
    (Cmd.info "get" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const get $ Cli_common.json $ read_layer_arg $ key_arg $ Cli_common.cwd))

(* set / unset. — both gate the workspace allowlist for project layers
   (symmetric gating). *)

let check_allowed layer field =
  if
    match layer with
    | Config_io.User -> true
    | Config_io.Project | Config_io.Project_local ->
        Config.Field.allowed_in_workspace field
  then Ok ()
  else
    Error
      (Printf.sprintf "%s cannot be set in the %s layer"
         (Config.Field.name field)
         (match layer with
         | Config_io.User -> "user"
         | Config_io.Project -> "project"
         | Config_io.Project_local -> "project-local"))

let write_layer t layer ~f =
  match
    Config_io.plan_write ~dirs:(Composition.dirs t) ~root:(Composition.root t)
      layer ~f
  with
  | Ok _ -> Exit_status.Success
  | Error message -> Exit_status.runtime message

(* A [model] value is catalog-validated at the set, exactly as
   [models select] does, so a bogus id is rejected here (exit 2) instead of
   silently persisting and failing at the next run. Other fields have no
   catalog dimension. *)
let validate_value t field value =
  if Config.Field.equal field Config.Field.model then
    match Argv.model_selector value with
    | Error status -> Error status
    | Ok _ -> (
        match Catalog.resolve (Composition.catalog t) value with
        | Ok _ -> Ok ()
        | Error e -> Error (Exit_status.usage (Catalog.Error.message e)))
  else Ok ()

let set layer key value cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Argv.config_key key with
      | Error status -> status
      | Ok (Config.Field.Any field) -> (
          match check_allowed layer field with
          | Error message -> Exit_status.usage message
          | Ok () -> (
              match validate_value t field value with
              | Error status -> status
              | Ok () ->
                  write_layer t layer ~f:(fun config ->
                      Config.set_text field value config))))

let value_arg =
  Arg.(
    required
    & pos 1 (some string) None
    & info [] ~docv:"VALUE" ~doc:"The new value.")

let set_cmd =
  let doc = "Set a config value." in
  Cmd.v
    (Cmd.info "set" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const set $ layer_arg $ key_arg $ value_arg $ Cli_common.cwd))

let unset layer key cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Argv.config_key key with
      | Error status -> status
      | Ok (Config.Field.Any field) -> (
          match check_allowed layer field with
          | Error message -> Exit_status.usage message
          | Ok () ->
              write_layer t layer ~f:(fun config ->
                  Ok (Config.unset field config))))

let unset_cmd =
  let doc = "Remove a config value." in
  Cmd.v
    (Cmd.info "unset" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const unset $ layer_arg $ key_arg $ Cli_common.cwd))

(* init. *)

let init layer cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      (* The single init path really creates the file — dir + [{}] over the
         parent chain (no more silent no-create) and, project-local, the
         [.gitignore] entry. *)
      match
        Config_io.init ~dirs:(Composition.dirs t) ~root:(Composition.root t)
          layer
      with
      | Ok path ->
          Output.stdout_printf "%s\n" path;
          Exit_status.Success
      | Error message -> Exit_status.runtime message)

let init_cmd =
  let doc = "Create an empty config file." in
  Cmd.v
    (Cmd.info "init" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const init $ layer_arg $ Cli_common.cwd))

(* validate. — structured output. *)

(* One report shape for every outcome: [errors] decides the verdict and the
   exit code, [warnings] carries the keys that parse but do nothing. --strict
   moves the second list into the first — the check a CI job wants — so the two
   modes differ in severity, never in what they notice. *)
let report json ~errors ~warnings =
  let strings items = Output.Json.list (List.map Output.Json.string items) in
  if json then
    Output.stdout_printf "%s\n"
      (Output.Json.to_string
         (Output.Json.envelope ~type_:"config.validate"
            [
              ("valid", Output.Json.bool (errors = []));
              ("errors", strings errors);
              ("warnings", strings warnings);
            ]))
  else (
    List.iter (Output.stderr_printf "warning: %s\n") warnings;
    List.iter (Output.stderr_printf "%s\n") errors;
    if errors = [] then Output.stdout_printf "ok\n");
  if errors = [] then Exit_status.Success else Exit_status.Failed

let validate json strict path_opt cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let path =
        match path_opt with
        | Some p -> p
        | None -> Mentat_boot.User_dirs.config_file (Composition.dirs t)
      in
      let ok () = report json ~errors:[] ~warnings:[] in
      match Config_io.read ~path with
      | Error message ->
          if json then (
            Output.json_error ~type_:"config.validate" message;
            Exit_status.Failed)
          else Exit_status.runtime message
      (* A missing or empty config file has nothing to validate — ok, not an
         "end of text" parse error. *)
      | Ok None -> ok ()
      | Ok (Some bytes) when String.length (String.trim bytes) = 0 -> ok ()
      | Ok (Some bytes) -> (
          match Jsont_bytesrw.decode_string Jsont.json bytes with
          | Error message ->
              if json then report json ~errors:[ message ] ~warnings:[]
              else Exit_status.runtime message
          | Ok j ->
              (* A workspace file's allowlist is part of "is this file right",
                 so the check reads the same layer boundary the resolver
                 does. *)
              let workspace =
                match
                  Config_io.layer_of_path ~dirs:(Composition.dirs t)
                    ~root:(Composition.root t) path
                with
                | Some (Config_io.Project | Config_io.Project_local) -> true
                | Some Config_io.User | None -> false
              in
              let message e = Config.Error.message e in
              let errors = List.map message (Config.validate ~source:path j) in
              let ignored =
                List.map message (Config.ignored_keys ~workspace ~source:path j)
              in
              if strict then report json ~errors:(errors @ ignored) ~warnings:[]
              else report json ~errors ~warnings:ignored))

let strict_flag =
  Arg.(
    value & flag
    & info [ "strict" ] ~doc:"Fail on keys that have no effect, not just warn.")

let path_pos =
  Arg.(
    value
    & pos 0 (some string) None
    & info [] ~docv:"PATH" ~doc:"File to validate.")

let validate_cmd =
  let doc = "Validate a config file." in
  Cmd.v
    (Cmd.info "validate" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const validate $ Cli_common.json $ strict_flag $ path_pos
         $ Cli_common.cwd))

(* group. *)

let cmd =
  let doc = "Inspect and edit configuration." in
  Cmd.group
    (Cmd.info "config" ~doc ~docs ~exits:Cli_common.exits)
    [ path_cmd; show_cmd; get_cmd; set_cmd; unset_cmd; init_cmd; validate_cmd ]
