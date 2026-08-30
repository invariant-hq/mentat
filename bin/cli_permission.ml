(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Config = Mentat_config
module Rule = Mentat_permission.Policy.Rule
module Row = Config.Resolved.View.Permission_rule
module Composition = Mentat_boot.Composition
module Config_io = Mentat_boot.Config_io
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

let docs = Cli_common.s_config

(* The list view and the config query's values-with-origins snapshot read the
   same durable-rule projection, so the two surfaces cannot disagree on rule
   order or identity. Only [user] and [extra_file] layers contribute effective
   durable rules; workspace rules are stripped at resolution and surface as a
   config warning, not here. *)

let source_location = function
  | Config.Source.User { path }
  | Config.Source.Project { path }
  | Config.Source.Project_local { path }
  | Config.Source.Extra_file { path } ->
      Lpath.Abs.to_string path
  | Config.Source.Env { name } -> name
  | Config.Source.Override -> "override"
  | Config.Source.Default { reason } -> reason

let action_text = function
  | Rule.Allow -> "allow"
  | Rule.Review -> "review"
  | Rule.Deny -> "deny"

(* list. *)

let rule_rows resolved =
  Config.Resolved.View.permission_rules (Config.Resolved.view resolved)

let list_text rows =
  match rows with
  | [] -> Output.stdout_printf "no permission rules\n"
  | rows ->
      Output.print_table
        ~header:[ "#"; "RULE"; "ACTION"; "MATCH"; "SOURCE" ]
        (List.mapi
           (fun index row ->
             let rule = Row.rule row in
             let source = Row.source row in
             [
               string_of_int (index + 1);
               Rule.Id.to_string (Row.id row);
               action_text (Rule.action rule);
               Mentat_permission.Policy.Match.to_line (Rule.matcher rule);
               Config.Source.kind_string source ^ " " ^ source_location source;
             ])
           rows)

let rule_json rule =
  match Jsont.Json.encode Rule.jsont rule with
  | Ok json -> json
  | Error _ -> Output.Json.null

let list_json rows =
  let rules =
    List.mapi
      (fun index row ->
        let source = Row.source row in
        Output.Json.obj
          [
            ("position", Output.Json.int (index + 1));
            ("id", Output.Json.string (Rule.Id.to_string (Row.id row)));
            ("rule", rule_json (Row.rule row));
            ("source", Output.Json.string (Config.Source.kind_string source));
            ("location", Output.Json.string (source_location source));
          ])
      rows
  in
  Output.stdout_printf "%s\n"
    (Output.Json.to_string
       (Output.Json.envelope ~type_:"permission.rules"
          [ ("rules", Output.Json.list rules) ]))

let list json cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let rows = rule_rows (Composition.config t) in
      if json then list_json rows else list_text rows;
      Exit_status.Success)

(* remove. *)

let layer_name = function
  | Config_io.User -> "user"
  | Config_io.Project -> "project"
  | Config_io.Project_local -> "project-local"

let layer_rank = function
  | Config_io.User -> 0
  | Config_io.Project -> 1
  | Config_io.Project_local -> 2

let compare_layer a b = Int.compare (layer_rank a) (layer_rank b)

let parse_from = function
  | None -> Ok None
  | Some "user" -> Ok (Some Config_io.User)
  | Some "project" -> Ok (Some Config_io.Project)
  | Some "project-local" -> Ok (Some Config_io.Project_local)
  | Some raw ->
      Error
        (Printf.sprintf
           "unknown config layer %S; expected user, project, or project-local"
           raw)

(* A rule id is a 12-character lowercase hexadecimal digest prefix; the CLI
   accepts a unique prefix of it. A malformed id argument is caller usage
   (exit 2), distinct from a well-formed id that matches nothing (exit 1). *)
let is_lower_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let validate_id_prefix raw =
  let length = String.length raw in
  if length = 0 then Error "permission rule id must not be empty"
  else if length > 12 then
    Error
      (Printf.sprintf "permission rule id %S is longer than 12 characters" raw)
  else if not (String.for_all is_lower_hex raw) then
    Error
      (Printf.sprintf "permission rule id %S must be lowercase hexadecimal" raw)
  else Ok raw

let matches_prefix ~prefix rule =
  String.starts_with ~prefix (Rule.Id.to_string (Rule.id rule))

(* An effective durable rule that lives in a non-writable source (an extra
   config file selected by [MENTAT_CONFIG]) is listed but cannot be pruned by
   [remove]; report that rather than a bare not-found. *)
let non_writable_match t ~prefix =
  rule_rows (Composition.config t)
  |> List.find_map (fun row ->
      match Row.source row with
      | Config.Source.Extra_file _
        when String.starts_with ~prefix (Rule.Id.to_string (Row.id row)) ->
          Some (Row.id row)
      | _ -> None)

let write_removal t layer id rule =
  let dirs = Composition.dirs t and root = Composition.root t in
  match
    Config_io.plan_write ~dirs ~root layer ~f:(fun config ->
        let remaining =
          List.filter
            (fun candidate -> not (Rule.equal candidate rule))
            (Config.permission_rules config)
        in
        Ok (Config.set_permission_rules remaining config))
  with
  | Ok _ ->
      Output.stdout_printf "removed rule %s from %s %s\n" (Rule.Id.to_string id)
        (layer_name layer)
        (Config_io.layer_path ~dirs ~root layer);
      Exit_status.Success
  | Error message -> Exit_status.runtime message

(* Collect prefix matches across the searched layers. The targeted layer's read
   error aborts; a non-targeted layer that cannot be read contributes no
   candidate rather than failing an unrelated removal. *)
let gather_matches t ~targeted ~prefix layers =
  let dirs = Composition.dirs t and root = Composition.root t in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | layer :: rest -> (
        match Config_io.read_layer ~dirs ~root layer with
        | Error message -> if targeted then Error message else loop acc rest
        | Ok config ->
            let here =
              Config.permission_rules config
              |> List.filter_map (fun rule ->
                  if matches_prefix ~prefix rule then Some (layer, rule)
                  else None)
            in
            loop (List.rev_append here acc) rest)
  in
  loop [] layers

let remove raw from cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match validate_id_prefix raw with
      | Error message -> Exit_status.usage message
      | Ok prefix -> (
          match parse_from from with
          | Error message -> Exit_status.usage message
          | Ok from_layer -> (
              let targeted = Option.is_some from_layer in
              let layers =
                match from_layer with
                | Some layer -> [ layer ]
                | None ->
                    [
                      Config_io.User; Config_io.Project; Config_io.Project_local;
                    ]
              in
              match gather_matches t ~targeted ~prefix layers with
              | Error message -> Exit_status.runtime message
              | Ok matches -> (
                  let distinct_ids =
                    List.map (fun (_, rule) -> Rule.id rule) matches
                    |> List.sort_uniq Rule.Id.compare
                  in
                  match distinct_ids with
                  | [] -> (
                      match
                        if targeted then None else non_writable_match t ~prefix
                      with
                      | Some id ->
                          Exit_status.runtime
                            (Printf.sprintf
                               "permission rule %s comes from a non-writable \
                                source; edit that config file directly"
                               (Rule.Id.to_string id))
                      | None ->
                          let where =
                            match from_layer with
                            | Some layer ->
                                Printf.sprintf " in the %s layer"
                                  (layer_name layer)
                            | None -> ""
                          in
                          Exit_status.runtime
                            (Printf.sprintf
                               "no durable permission rule matching %s%s; run \
                                `mentat permission list` to see rule ids"
                               prefix where))
                  | _ :: _ :: _ ->
                      Exit_status.usage
                        (Printf.sprintf
                           "permission rule prefix %s is ambiguous; it matches \
                            %d rules"
                           prefix (List.length distinct_ids))
                  | [ id ] -> (
                      let layers_with =
                        List.map fst matches |> List.sort_uniq compare_layer
                      in
                      match layers_with with
                      | [ layer ] ->
                          let _, rule =
                            List.find (fun (l, _) -> l = layer) matches
                          in
                          write_removal t layer id rule
                      | several ->
                          Exit_status.usage
                            (Printf.sprintf
                               "permission rule %s exists in several layers \
                                (%s); pass --from to choose one"
                               (Rule.Id.to_string id)
                               (String.concat ", "
                                  (List.map layer_name several))))))))

(* command line. *)

let list_cmd =
  let doc = "List durable permission rules in evaluation order." in
  Cmd.v
    (Cmd.info "list" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const list $ Cli_common.json $ Cli_common.cwd))

let rule_id_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"RULE_ID"
        ~doc:"Rule id, or a unique prefix, from `mentat permission list`.")

let from_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "from" ] ~docv:"LAYER"
        ~doc:
          "Config layer to remove the rule from: $(b,user), $(b,project), or \
           $(b,project-local). Required when the same rule exists in several \
           layers.")

let remove_cmd =
  let doc = "Remove a durable permission rule from its config file." in
  Cmd.v
    (Cmd.info "remove" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const remove $ rule_id_arg $ from_arg $ Cli_common.cwd))

let cmd =
  let doc = "Inspect and remove durable permission rules." in
  Cmd.group
    (Cmd.info "permission" ~doc ~docs ~exits:Cli_common.exits)
    [ list_cmd; remove_cmd ]
