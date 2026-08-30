(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Offline inspection of skill discovery: [list] and [show] are pure views over
   one {!Mentat_context.Skills.load} snapshot, assembled from the same
   config/trust/root inputs the composition root feeds a run (see
   [Composition.assemble]), but without the engine — no client, no provider
   call. The CLI owns the envelope shape; the library owns the per-fact
   codecs. *)

open! Cmdliner
module Config = Mentat_config
module Skills = Mentat_context.Skills
module Skill = Skills.Skill
module Catalog = Skills.Catalog
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

let docs = Cli_common.s_diagnostic

(* An executable-minted skill/catalog value always encodes; a failure is a
   library bug, classified [Internal] by the top-level guard exactly as
   {!Output.Json.to_string} treats its own encode failures. *)
let json_of codec value =
  match Jsont.Json.encode codec value with
  | Ok json -> json
  | Error message -> failwith message

(* One snapshot, from the composition base's resolved config, trust, and root. *)
let with_skills cwd f =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let user_config_file =
        Lpath.Abs.of_string_exn
          (Mentat_boot.User_dirs.config_file (Composition.dirs t))
      in
      let skills =
        Skills.load ~stdenv:(Composition.stdenv t)
          ~builtins:Mentat_prompts.Skills.all ~config:(Composition.config t)
          ~trusted:(Composition.trusted t) ~root:(Composition.root t)
          ~cwd:(Composition.root t) ~user_config_file
      in
      f (Composition.config t) skills)

(* Text rendering. *)

let bool_text value = if value then "true" else "false"

let print_policy config skills =
  let get field = Config.Resolved.get field config in
  Output.stdout_printf "Skills: %s\n"
    (if Skills.enabled skills then "enabled" else "disabled (skills.enabled)");
  if Skills.enabled skills then begin
    Output.stdout_printf "  builtin: %s  project: %s  compat: %s\n"
      (bool_text (get Config.Field.skills_builtin))
      (bool_text (get Config.Field.skills_project))
      (bool_text (get Config.Field.skills_compat));
    Output.stdout_printf "  catalog budget: %d bytes (%d used)\n"
      (get Config.Field.skills_catalog_max_bytes)
      (Catalog.bytes (Skills.catalog skills))
  end

let is_active skill =
  match Skill.status skill with Skill.Active _ -> true | _ -> false

let print_active skills =
  match List.filter is_active skills with
  | [] -> Output.stdout_printf "\nActive skills: (none)\n"
  | active ->
      Output.stdout_printf "\nActive skills:\n";
      List.iteri
        (fun index skill ->
          match Skill.status skill with
          | Skill.Active content ->
              Output.stdout_printf "  [%d] %s  %s  %s\n" (index + 1)
                (Skill.Name.to_string (Skill.name skill))
                (Skill.kind_string (Skill.kind skill))
                (Skill.origin skill);
              Output.stdout_printf "      %s\n" content.Skill.description
          | _ -> ())
        active

(* The inactive reason favours the free-text detail (the shadowing winner's
   origin, an invalid candidate's message), falling back to the machine reason,
   then the bare state word. *)
let inactive_reason skill =
  let status = Skill.status skill in
  match Skill.detail_string status with
  | Some detail -> Skill.state_string status ^ " " ^ detail
  | None -> (
      match Skill.reason_string status with
      | Some reason -> Skill.state_string status ^ " (" ^ reason ^ ")"
      | None -> Skill.state_string status)

let print_inactive skills =
  match List.filter (fun skill -> not (is_active skill)) skills with
  | [] -> ()
  | inactive ->
      Output.stdout_printf "\nInactive skills:\n";
      List.iter
        (fun skill ->
          Output.stdout_printf "  %s %s (%s)\n"
            (Skill.Name.to_string (Skill.name skill))
            (inactive_reason skill) (Skill.origin skill))
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
      ("enabled", Output.Json.bool (get Config.Field.skills_enabled));
      ("builtin", Output.Json.bool (get Config.Field.skills_builtin));
      ("project", Output.Json.bool (get Config.Field.skills_project));
      ("compat", Output.Json.bool (get Config.Field.skills_compat));
      ("paths", string_list (get Config.Field.skills_paths));
      ("disabled", string_list (get Config.Field.skills_disabled));
      ( "catalog_max_bytes",
        Output.Json.int (get Config.Field.skills_catalog_max_bytes) );
    ]

let list_json config skills =
  Output.Json.envelope ~type_:"skills_list"
    [
      ("config", config_json config);
      ("catalog", json_of Catalog.jsont (Skills.catalog skills));
      ( "skills",
        Output.Json.list (List.map (json_of Skill.jsont) (Skills.skills skills))
      );
      ("warnings", string_list (Skills.warnings skills));
    ]

(* list. *)

let list json cwd =
  with_skills cwd @@ fun config skills ->
  if json then
    Output.stdout_printf "%s\n"
      (Output.Json.to_string (list_json config skills))
  else begin
    print_policy config skills;
    if Skills.enabled skills then begin
      print_active (Skills.skills skills);
      print_inactive (Skills.skills skills);
      print_warnings (Skills.warnings skills)
    end
  end;
  Exit_status.Success

let list_cmd =
  let doc = "List discovered skills and their states." in
  Cmd.v
    (Cmd.info "list" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const list $ Cli_common.json $ Cli_common.cwd))

(* show. *)

let active_names skills =
  List.filter_map
    (fun skill ->
      match Skill.status skill with
      | Skill.Active _ -> Some (Skill.Name.to_string (Skill.name skill))
      | _ -> None)
    (Skills.skills skills)

let unknown_skill name skills =
  let known =
    match active_names skills with
    | [] -> "(none)"
    | names -> String.concat ", " names
  in
  let warning =
    match Skills.warnings skills with
    | [] -> ""
    | warnings -> "; " ^ String.concat "; " warnings
  in
  Exit_status.runtime
    (Printf.sprintf "unknown skill %S; available skills: %s%s" name known
       warning)

let show_json skill content skills =
  Output.Json.envelope ~type_:"skills_show"
    [
      ("skill", json_of Skill.jsont skill);
      ("text", Output.Json.string content.Skill.text);
      ("warnings", string_list (Skills.warnings skills));
    ]

let print_show skill content skills =
  Output.stdout_printf "name: %s\n" (Skill.Name.to_string (Skill.name skill));
  (match content.Skill.display_name with
  | Some display -> Output.stdout_printf "display name: %s\n" display
  | None -> ());
  Output.stdout_printf "kind: %s\n" (Skill.kind_string (Skill.kind skill));
  Output.stdout_printf "origin: %s\n" (Skill.origin skill);
  Output.stdout_printf "digest: %s\n" content.Skill.digest;
  Output.stdout_printf "bytes: %d\n" content.Skill.bytes;
  (match content.Skill.ignored_keys with
  | [] -> ()
  | keys ->
      Output.stdout_printf "ignored frontmatter keys: %s\n"
        (String.concat ", " keys));
  (match content.Skill.resources with
  | [] -> ()
  | resources ->
      Output.stdout_printf "resources:\n";
      List.iter (Output.stdout_printf "  %s\n") resources);
  Output.stdout_printf "\n%s\n" content.Skill.text;
  match Skills.warnings skills with
  | [] -> ()
  | warnings -> print_warnings warnings

let show json name cwd =
  with_skills cwd @@ fun _config skills ->
  match Skill.Name.of_string name with
  | Error message -> Exit_status.runtime message
  | Ok skill_name -> (
      match Skills.find_active skills skill_name with
      | None -> unknown_skill name skills
      | Some (skill, content) ->
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string (show_json skill content skills))
          else print_show skill content skills;
          Exit_status.Success)

let name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"NAME" ~doc:"Skill name.")

let show_cmd =
  let doc = "Show one active skill." in
  Cmd.v
    (Cmd.info "show" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const show $ Cli_common.json $ name_arg $ Cli_common.cwd))

(* group. *)

let cmd =
  let doc = "Inspect discovered skills." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Skills are named, reusable guidance loaded into runs on demand. This \
         group shows what was discovered, what is active, and how much of the \
         catalog budget the descriptions consume.";
    ]
  in
  Cmd.group
    (Cmd.info "skills" ~doc ~docs ~man ~exits:Cli_common.exits)
    [ list_cmd; show_cmd ]
