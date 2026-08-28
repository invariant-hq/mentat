(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Offline inspection of what a run assembles: [context] shows workspace
   context discovery, [prompt] the exact model-visible prelude fragments the
   engine seals, [session] the identity, state, and on-disk artifacts of a saved
   session, and [model] the model-conditioning decisions. Each is a pure view
   over config + trust resolution (see [Composition.assemble]); none links the
   engine or spends a model call. The CLI owns the envelope shape; the libraries
   own the per-fact codecs. *)

open! Cmdliner
module Config = Mentat_config
module Context = Mentat_context.Context
module Source = Context.Source
module Skills = Mentat_context.Skills
module Mode = Mentat_session.Contract.Mode
module Session = Mentat_session
module Id = Session.Id
module Summary = Session.Summary
module Session_view = Session.Session_view
module Outcome = Session.Turn.Outcome
module Status = Session.Metadata.Status
module Message = Mentat_llm.Message
module Model = Mentat_provider.Model
module Selector = Mentat_provider.Selector
module Catalog = Mentat_provider.Catalog

let docs = Cli_common.s_diagnostic

let json_of codec value =
  match Jsont.Json.encode codec value with
  | Ok json -> json
  | Error message -> failwith message

let user_config_file t =
  Lpath.Abs.of_string_exn (User_dirs.config_file (Composition.dirs t))

(* Context and skills load against the run directory exactly as a run does: the
   canonicalized root is both discovery root and cwd. *)
let load_context t ~nested_scan =
  Context.load ~environment:Context.Environment.none
    ~stdenv:(Composition.stdenv t) ~nested_scan ~config:(Composition.config t)
    ~trusted:(Composition.trusted t) ~root:(Composition.root t)
    ~cwd:(Composition.root t) ~user_config_file:(user_config_file t)

let load_skills t =
  Skills.load ~stdenv:(Composition.stdenv t) ~builtins:Mentat_prompts.Skills.all
    ~config:(Composition.config t) ~trusted:(Composition.trusted t)
    ~root:(Composition.root t) ~cwd:(Composition.root t)
    ~user_config_file:(user_config_file t)

(* debug context. *)

let enabled_string enabled = if enabled then "enabled" else "disabled"

let origin_label config field =
  match Config.Resolved.origin field config with
  | None -> "default"
  | Some origin -> Config.Source.kind_string (Config.Origin.source origin)

let nested_scan_string = function
  | `Off -> "off"
  | `Complete -> "complete"
  | `Capped -> "capped"

let print_workspace config context =
  let get field = Config.Resolved.get field config in
  Output.stdout_printf "Workspace:\n";
  Output.stdout_printf "  cwd: %s\n" (Lpath.Abs.to_string (Context.cwd context));
  Output.stdout_printf "  root: %s\n"
    (Lpath.Abs.to_string (Context.root context));
  Output.stdout_printf "  root marker: %s\n"
    (Option.value (Context.root_marker context) ~default:"(none)");
  Output.stdout_printf "  global instructions: %s (%s)\n"
    (enabled_string (get Config.Field.instructions_global))
    (origin_label config Config.Field.instructions_global);
  Output.stdout_printf "  project instructions: %s (%s)\n"
    (enabled_string (get Config.Field.instructions_project))
    (origin_label config Config.Field.instructions_project);
  Output.stdout_printf "  claude compatibility: %s (%s)\n"
    (enabled_string (get Config.Field.instructions_claude_md))
    (origin_label config Config.Field.instructions_claude_md);
  Output.stdout_printf "  project budget: %d bytes (%d used)\n"
    (get Config.Field.instructions_project_max_bytes)
    (Context.budget_used context);
  Output.stdout_printf "  nested scan: %s\n"
    (nested_scan_string (Context.nested_scan context))

let source_label source =
  Printf.sprintf "%s %s"
    (Source.kind_string (Source.kind source))
    (Source.display_path source)

let print_sources context =
  let active, inactive =
    List.partition
      (fun source ->
        match Source.status source with Source.Active _ -> true | _ -> false)
      (Context.sources context)
  in
  Output.stdout_printf "Active instruction sources:\n";
  (match active with
  | [] -> Output.stdout_printf "  (none)\n"
  | active ->
      List.iteri
        (fun index source ->
          Output.stdout_printf "  [%d] %s\n" (index + 1) (source_label source);
          match Source.status source with
          | Source.Active content ->
              Output.stdout_printf "      bytes: %d included: %d digest: %s\n"
                content.Source.bytes content.Source.included_bytes
                content.Source.digest
          | _ -> ())
        active);
  Output.stdout_printf "\nInactive instruction sources:\n";
  match inactive with
  | [] -> Output.stdout_printf "  (none)\n"
  | inactive ->
      List.iter
        (fun source ->
          let status = Source.status source in
          let detail =
            match Source.detail_string status with
            | Some detail -> " " ^ detail
            | None -> (
                match Source.reason_string status with
                | Some reason -> " (" ^ reason ^ ")"
                | None -> "")
          in
          Output.stdout_printf "  %s %s%s\n"
            (Source.display_path source)
            (Source.state_string status)
            detail)
        inactive

let print_warnings warnings =
  Output.stdout_printf "Warnings:\n";
  match warnings with
  | [] -> Output.stdout_printf "  (none)\n"
  | warnings -> List.iter (Output.stdout_printf "  %s\n") warnings

let workspace_json config context =
  let get field = Config.Resolved.get field config in
  let enablement field =
    Output.Json.obj
      [
        ("enabled", Output.Json.bool (get field));
        ("origin", Output.Json.string (origin_label config field));
      ]
  in
  Output.Json.obj
    [
      ("cwd", Output.Json.string (Lpath.Abs.to_string (Context.cwd context)));
      ("root", Output.Json.string (Lpath.Abs.to_string (Context.root context)));
      ("root_marker", Output.Json.string_or_null (Context.root_marker context));
      ("global_instructions", enablement Config.Field.instructions_global);
      ("project_instructions", enablement Config.Field.instructions_project);
      ("claude_compatibility", enablement Config.Field.instructions_claude_md);
      ( "budget",
        Output.Json.obj
          [
            ( "total",
              Output.Json.int (get Config.Field.instructions_project_max_bytes)
            );
            ("used", Output.Json.int (Context.budget_used context));
          ] );
      ( "nested_scan",
        Output.Json.string (nested_scan_string (Context.nested_scan context)) );
    ]

let context_show_json config context =
  Output.Json.envelope ~type_:"context_show"
    [
      ("workspace", workspace_json config context);
      ( "sources",
        Output.Json.list
          (List.map (json_of Source.jsont) (Context.sources context)) );
      ( "projection",
        Output.Json.obj
          [
            ( "rendered_digest",
              Output.Json.string (Context.rendered_digest context) );
          ] );
      ( "warnings",
        Output.Json.list
          (List.map Output.Json.string (Context.warnings context)) );
    ]

let context json cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match load_context t ~nested_scan:true with
      | Error diagnostic -> Exit_status.of_diagnostic diagnostic
      | Ok context ->
          let config = Composition.config t in
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string (context_show_json config context))
          else begin
            print_workspace config context;
            Output.stdout_printf "\n";
            print_sources context;
            Output.stdout_printf "\nProjection:\n  rendered digest: %s\n"
              (Context.rendered_digest context);
            Output.stdout_printf "\n";
            print_warnings (Context.warnings context)
          end;
          Exit_status.Success)

let context_cmd =
  let doc = "Show active workspace context." in
  Cmd.v
    (Cmd.info "context" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const context $ Cli_common.json $ Cli_common.cwd))

(* debug prompt. *)

(* The mode prompt is a host-provided developer instruction the caller slots
   between the workspace context and the skills catalog; Build carries none.
   This mirrors the run's mode fragment (composition's [mode_fragment]), and the
   surrounding assembly is {!Context.prelude} — the very list the engine seals —
   so the printed prelude is exactly what a turn would seal minus the runtime
   notices a live turn adds. *)
let mode_developer = function
  | Mode.Build -> []
  | Mode.Plan -> [ Message.developer Mentat_prompts.Modes.plan ]
  | Mode.Review -> [ Message.developer Mentat_prompts.Modes.review ]

(* Prelude fragments are system, developer, or user messages by construction; a
   [User] carries text blocks. Any other kind never appears in a prelude but is
   rendered rather than crashing an inspector. *)
let content_text (block : Mentat_llm.Content.t) =
  match block with Mentat_llm.Content.Text text -> Some text | _ -> None

let fragment_role_text (message : Message.t) =
  match message with
  | Message.System text -> ("system", text)
  | Message.Developer text -> ("developer", text)
  | Message.User content ->
      ("user", String.concat "\n" (List.filter_map content_text content))
  | Message.Assistant assistant ->
      ("assistant", String.concat "\n" (Message.Assistant.texts assistant))
  | Message.Tool_result _ -> ("tool_result", "")

let prompt_json context mode fragments =
  Output.Json.envelope ~type_:"context_prompt"
    [
      ("mode", json_of Mode.jsont mode);
      ( "fragments",
        Output.Json.list
          (List.map
             (fun message ->
               let role, text = fragment_role_text message in
               Output.Json.obj
                 [
                   ("role", Output.Json.string role);
                   ("text", Output.Json.string text);
                 ])
             fragments) );
      ("context_digest", Output.Json.string (Context.rendered_digest context));
    ]

let prompt json mode cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match load_context t ~nested_scan:false with
      | Error diagnostic -> Exit_status.of_diagnostic diagnostic
      | Ok context ->
          let fragments =
            Context.prelude context ~developer:(mode_developer mode)
              ~skills:(load_skills t)
          in
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string (prompt_json context mode fragments))
          else
            List.iter
              (fun message ->
                Output.stdout_printf "%s\n" (snd (fragment_role_text message)))
              fragments;
          Exit_status.Success)

let mode_arg =
  let modes =
    [ ("build", Mode.Build); ("plan", Mode.Plan); ("review", Mode.Review) ]
  in
  Arg.(
    value
    & opt (enum modes) Mode.Build
    & info [ "mode" ] ~docv:"MODE"
        ~doc:"Product mode to project: $(b,build), $(b,plan), or $(b,review).")

let prompt_cmd =
  let doc = "Print the exact model-visible context for the next request." in
  Cmd.v
    (Cmd.info "prompt" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const prompt $ Cli_common.json $ mode_arg $ Cli_common.cwd))

(* debug session. *)

let humanize_age seconds =
  let s = if seconds < 0 then 0 else seconds in
  if s < 1 then "just now"
  else if s < 60 then Printf.sprintf "%ds ago" s
  else if s < 3600 then Printf.sprintf "%dm ago" (s / 60)
  else if s < 86400 then Printf.sprintf "%dh ago" (s / 3600)
  else Printf.sprintf "%dd ago" (s / 86400)

type artifact = { path : string; exists : bool; age : int option }

let stat_artifact ~now path =
  match Unix.stat path with
  | stat ->
      {
        path;
        exists = true;
        age = Some (int_of_float (now -. stat.Unix.st_mtime));
      }
  | exception Unix.Unix_error _ -> { path; exists = false; age = None }

(* Read a candidate log file with a generous cap for the grep; an oversized or
   unreadable file is skipped rather than failing the report. *)
let read_for_grep path =
  match Fs.read_capped ~max_bytes:(16 * 1024 * 1024) path with
  | Ok contents -> contents
  | Error _ -> None

let list_logs dir =
  match Sys.readdir dir with
  | entries ->
      Array.to_list entries
      |> List.filter (fun name -> Filename.check_suffix name ".log")
      |> List.sort String.compare
      |> List.map (Filename.concat dir)
  | exception Sys_error _ -> []

let short_id id =
  let s = Id.to_string id in
  if String.length s > 8 then String.sub s 0 8 else s

(* A log file mentions the session if a per-run tag ([s=<first-8>]) or a boundary
   line ([session <full-id> …]) names it. *)
let log_mentions ~id contents =
  String.includes ~affix:(Printf.sprintf "[s=%s]" (short_id id)) contents
  || String.includes
       ~affix:(Printf.sprintf "session %s " (Id.to_string id))
       contents

(* A crash report names the session in its [session=<full-id>] header line. *)
let crash_mentions ~id contents =
  String.includes
    ~affix:(Printf.sprintf "session=%s" (Id.to_string id))
    contents

let matching_logs ~now ~id ~logs_dir ~explicit_log =
  let candidates =
    list_logs logs_dir
    @ match explicit_log with Some path -> [ path ] | None -> []
  in
  List.filter_map
    (fun path ->
      match read_for_grep path with
      | Some contents when log_mentions ~id contents ->
          Some (stat_artifact ~now path)
      | _ -> None)
    candidates

let matching_crashes ~now ~id ~crashes_dir =
  List.filter_map
    (fun path ->
      match read_for_grep path with
      | Some contents when crash_mentions ~id contents ->
          Some (stat_artifact ~now path)
      | _ -> None)
    (list_logs crashes_dir)

let lifecycle_string = function
  | Status.Active -> "active"
  | Status.Archived -> "archived"
  | Status.Deleted -> "deleted"

let mode_string = function
  | Mode.Build -> "build"
  | Mode.Plan -> "plan"
  | Mode.Review -> "review"

let outcome_string = function
  | Outcome.Completed -> "completed"
  | Outcome.Step_limit -> "step_limit"
  | Outcome.Interrupted { reason; cancelled } ->
      Printf.sprintf "interrupted%s%s"
        (if cancelled then " (cancelled)" else "")
        (match reason with Some reason -> ": " ^ reason | None -> "")
  | Outcome.Failed { message } -> "failed: " ^ message

(* The last stored error is the failure message of the most recent terminal
   outcome, when it failed. *)
let last_error view =
  match Session_view.last_outcome view with
  | Some (Outcome.Failed { message }) -> Some message
  | _ -> None

let age_of_time ~now time =
  int_of_float (now -. (Int64.to_float (Session.Time.to_unix_ms time) /. 1000.))

let session_report_json ~now ~id ~view ~summary ~artifacts ~logs ~crashes
    ~follow_up =
  let artifact_json (kind, artifact) =
    Output.Json.obj
      [
        ("kind", Output.Json.string kind);
        ("path", Output.Json.string artifact.path);
        ("exists", Output.Json.bool artifact.exists);
        ("age_seconds", Output.Json.int_or_null artifact.age);
      ]
  in
  let file_json artifact =
    Output.Json.obj
      [
        ("path", Output.Json.string artifact.path);
        ("age_seconds", Output.Json.int_or_null artifact.age);
      ]
  in
  Output.Json.envelope ~type_:"debug_session"
    [
      ( "session",
        Output.Json.obj
          [
            ("id", Output.Json.string (Id.to_string id));
            ("title", Output.Json.string_or_null (Summary.title summary));
            ( "lifecycle",
              Output.Json.string (lifecycle_string (Summary.lifecycle summary))
            );
            ( "phase",
              Output.Json.string
                (Summary.Phase.to_string (Summary.phase summary)) );
            ( "mode",
              Output.Json.string_or_null
                (Option.map mode_string (Session_view.workflow_mode view)) );
            ( "last_outcome",
              Output.Json.string_or_null
                (Option.map outcome_string (Session_view.last_outcome view)) );
            ( "waiting",
              Output.Json.string_or_null
                (Option.map Session_view.Waiting.to_string
                   (Session_view.waiting view)) );
            ("last_error", Output.Json.string_or_null (last_error view));
            ("turns", Output.Json.int (Summary.turns summary));
            ( "active_model",
              Output.Json.string_or_null
                (Option.map Mentat_llm.Model.id
                   (Session_view.active_model view)) );
            ( "created_age_seconds",
              Output.Json.int (age_of_time ~now (Summary.created_at summary)) );
            ( "updated_age_seconds",
              Output.Json.int (age_of_time ~now (Summary.updated_at summary)) );
          ] );
      ("artifacts", Output.Json.list (List.map artifact_json artifacts));
      ("logs", Output.Json.list (List.map file_json logs));
      ("crashes", Output.Json.list (List.map file_json crashes));
      ("follow_up", Output.Json.list (List.map Output.Json.string follow_up));
    ]

let print_artifact (kind, artifact) =
  if artifact.exists then
    Output.stdout_printf "  %s: %s (%s)\n" kind artifact.path
      (match artifact.age with Some age -> humanize_age age | None -> "-")
  else Output.stdout_printf "  %s: %s (missing)\n" kind artifact.path

let print_files heading files =
  Output.stdout_printf "%s:\n" heading;
  match files with
  | [] -> Output.stdout_printf "  (none)\n"
  | files ->
      List.iter
        (fun artifact ->
          Output.stdout_printf "  %s (%s)\n" artifact.path
            (match artifact.age with
            | Some age -> humanize_age age
            | None -> "-"))
        files

let print_session_report ~id ~view ~summary ~artifacts ~logs ~crashes ~follow_up
    =
  let optional label = function
    | Some value -> Output.stdout_printf "  %s: %s\n" label value
    | None -> ()
  in
  Output.stdout_printf "Session %s\n" (Id.to_string id);
  optional "title" (Summary.title summary);
  Output.stdout_printf "  lifecycle: %s\n"
    (lifecycle_string (Summary.lifecycle summary));
  Output.stdout_printf "  phase: %s\n"
    (Summary.Phase.to_string (Summary.phase summary));
  optional "mode" (Option.map mode_string (Session_view.workflow_mode view));
  optional "last outcome"
    (Option.map outcome_string (Session_view.last_outcome view));
  optional "waiting"
    (Option.map Session_view.Waiting.to_string (Session_view.waiting view));
  optional "last error" (last_error view);
  Output.stdout_printf "  turns: %d\n" (Summary.turns summary);
  optional "active model"
    (Option.map Mentat_llm.Model.id (Session_view.active_model view));
  Output.stdout_printf "\nArtifacts:\n";
  List.iter print_artifact artifacts;
  Output.stdout_printf "\n";
  print_files "Logs" logs;
  Output.stdout_printf "\n";
  print_files "Crash reports" crashes;
  Output.stdout_printf "\nFollow up:\n";
  List.iter (Output.stdout_printf "  %s\n") follow_up

(* One session's projection over the store and the state home, shared with
   [report], which bundles it instead of printing it. Correlation is by content —
   a log qualifies when its records carry this session's tag — so a run that was
   never attributed contributes nothing. *)
let project t document =
  let now = Unix.gettimeofday () in
  let id = Mentat_store.Session.Document.id document in
  let session = Mentat_store.Session.Document.session document in
  let view = Session_view.of_session session in
  let summary = Session_view.summary view in
  let dirs = Composition.dirs t in
  let session_dir = Mentat_store.Session.on_disk_dir (Composition.store t) id in
  let artifacts =
    [
      ( "session.json",
        stat_artifact ~now (Filename.concat session_dir "session.json") );
      ( "ledger.jsonl",
        stat_artifact ~now (Filename.concat session_dir "ledger.jsonl") );
    ]
  in
  let logs =
    matching_logs ~now ~id
      ~logs_dir:(Filename.concat (User_dirs.state_home dirs) "logs")
      ~explicit_log:(Composition.getenv t "MENTAT_LOG_FILE")
  in
  let crashes =
    matching_crashes ~now ~id
      ~crashes_dir:(Filename.concat (User_dirs.state_home dirs) "crashes")
  in
  let id_text = Id.to_string id in
  let follow_up =
    [
      Printf.sprintf "mentat session show %s" id_text;
      Printf.sprintf "mentat session export %s --format text" id_text;
      Printf.sprintf "mentat session diff %s" id_text;
    ]
  in
  (now, id, view, summary, artifacts, logs, crashes, follow_up)

let session_bundle t document =
  let now, id, view, summary, artifacts, logs, crashes, follow_up =
    project t document
  in
  ( session_report_json ~now ~id ~view ~summary ~artifacts ~logs ~crashes
      ~follow_up,
    List.map (fun a -> a.path) logs,
    List.map (fun a -> a.path) crashes )

let session json target last cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Session_locate.resolve t ~session:target ~last with
      | Error error -> Session_locate.status error
      | Ok document ->
          let now, id, view, summary, artifacts, logs, crashes, follow_up =
            project t document
          in
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string
                 (session_report_json ~now ~id ~view ~summary ~artifacts ~logs
                    ~crashes ~follow_up))
          else
            print_session_report ~id ~view ~summary ~artifacts ~logs ~crashes
              ~follow_up;
          Exit_status.Success)

let session_cmd =
  let doc = "Report a session's state and on-disk artifacts." in
  Cmd.v
    (Cmd.info "session" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const session $ Cli_common.json $ Cli_common.session_arg
         $ Cli_common.last $ Cli_common.cwd))

(* debug model. *)

let status_string status =
  match (status : Model.status) with
  | Model.Stable -> "stable"
  | Model.Preview -> "preview"
  | Model.Deprecated -> "deprecated"
  | Model.Unavailable reason -> "unavailable: " ^ reason

(* Render the run's editor-family decision (owned by [Composition.editor_family])
   as a (value, reason) pair for the report. The decision is the run's; only the
   human strings live here. *)
let editor_decision decision =
  let module E = Composition.Editor_family in
  let value =
    match E.family decision with
    | E.Apply_patch -> "apply-patch"
    | E.String_replace -> "string-replace"
  in
  let reason =
    match decision with
    | E.Configured _ -> "config tools.editor"
    | E.Auto_capable -> "model supports apply-patch"
    | E.Auto_incapable -> "model lacks apply-patch"
    | E.Auto_no_model -> "no model resolved"
  in
  (value, reason)

let reasoning_decision model =
  match model with
  | None -> ("none", "no model resolved")
  | Some model -> (
      match Model.default_reasoning model with
      | Some effort ->
          ( Mentat_llm.Request.Options.Reasoning_effort.to_string effort,
            "declared default" )
      | None -> ("none", "no declared default"))

(* With [--model] the selector is resolved through the catalog (a failure is a
   usage error, uniform with [models show]); without, the host's main model, and
   when none resolves offline the string-replace family is reported with the
   auth-dependent detail deferred to [models current]. *)
let resolve_model t model_raw =
  match model_raw with
  | Some selector -> (
      match Catalog.resolve (Composition.catalog t) selector with
      | Ok model -> Ok (Some model)
      | Error error -> Error (Exit_status.usage (Catalog.Error.message error)))
  | None -> (
      match Composition.default_model t with
      | Error _ -> Ok None
      | Ok llm -> (
          match
            Catalog.find (Composition.catalog t) (Selector.of_model llm)
          with
          | Ok model -> Ok (Some model)
          | Error _ -> Ok None))

let decision_json ~value ~reason =
  Output.Json.obj
    [
      ("value", Output.Json.string value); ("reason", Output.Json.string reason);
    ]

let model_report json model_raw cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match resolve_model t model_raw with
      | Error status -> status
      | Ok model ->
          let model_id =
            match model with
            | None -> "none"
            | Some model -> Selector.to_string (Model.selector model)
          in
          let editor_value, editor_reason =
            editor_decision (Composition.editor_family t model)
          in
          let reasoning_value, reasoning_reason = reasoning_decision model in
          let context_window = Option.bind model Model.context_window in
          let status =
            Option.map (fun model -> status_string (Model.status model)) model
          in
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string
                 (Output.Json.envelope ~type_:"debug_model"
                    [
                      ("model", Output.Json.string model_id);
                      ("status", Output.Json.string_or_null status);
                      ("context_window", Output.Json.int_or_null context_window);
                      ( "decisions",
                        Output.Json.obj
                          [
                            ( "editor",
                              decision_json ~value:editor_value
                                ~reason:editor_reason );
                            ( "reasoning",
                              decision_json ~value:reasoning_value
                                ~reason:reasoning_reason );
                          ] );
                    ]))
          else begin
            Output.stdout_printf "Model: %s\n" model_id;
            Option.iter (Output.stdout_printf "status: %s\n") status;
            Option.iter
              (Output.stdout_printf "context window: %d\n")
              context_window;
            Output.stdout_printf "editor: %s (%s)\n" editor_value editor_reason;
            Output.stdout_printf "reasoning: %s (%s)\n" reasoning_value
              reasoning_reason;
            Output.stdout_printf
              "credential readiness: run `mentat models current`\n"
          end;
          Exit_status.Success)

let model_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "model" ] ~docv:"MODEL"
        ~doc:
          "Resolve decisions for MODEL (a provider/model selector). Defaults \
           to the host's main model; when no model resolves the string-replace \
           editor family is reported.")

let model_cmd =
  let doc = "Print every model-conditioning decision for a resolved model." in
  Cmd.v
    (Cmd.info "model" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const model_report $ Cli_common.json $ model_arg $ Cli_common.cwd))

(* debug tools. *)

(* [debug tools] resolves a model like a run does — [--model] through the
   catalog, else the host's main model — because the Build editor family is a
   model decision. A model that will not resolve offline is reported, never
   guessed. *)
let resolve_model_llm t model_raw =
  match model_raw with
  | Some selector -> (
      match Catalog.resolve (Composition.catalog t) selector with
      | Ok model -> Ok (Model.llm model)
      | Error error -> Error (Exit_status.usage (Catalog.Error.message error)))
  | None -> (
      match Composition.default_model t with
      | Ok model -> Ok model
      | Error message -> Error (Exit_status.runtime message))

let print_declaration declaration =
  Output.stdout_printf "## %s\n\n" (Mentat_llm.Tool.name declaration);
  (match Mentat_llm.Tool.description declaration with
  | Some description -> Output.stdout_printf "%s\n\n" description
  | None -> ());
  Output.stdout_printf "Input schema: %s\n"
    (Output.Json.to_string (Mentat_llm.Tool.input_schema declaration))

let tools_json mode model declarations =
  Output.Json.envelope ~type_:"debug_tools"
    [
      ("mode", json_of Mode.jsont mode);
      ( "model",
        Output.Json.string (Selector.to_string (Selector.of_model model)) );
      ( "tools",
        Output.Json.list (List.map (json_of Mentat_llm.Tool.jsont) declarations)
      );
    ]

let tools json model_raw mode cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match resolve_model_llm t model_raw with
      | Error status -> status
      | Ok model -> (
          match Composition.tool_declarations t ~mode ~model with
          | Error status -> status
          | Ok declarations ->
              if json then
                Output.stdout_printf "%s\n"
                  (Output.Json.to_string (tools_json mode model declarations))
              else begin
                Output.stdout_printf "Model: %s\nMode: %s\n\n"
                  (Selector.to_string (Selector.of_model model))
                  (mode_string mode);
                List.iteri
                  (fun index declaration ->
                    if index > 0 then Output.stdout_printf "\n";
                    print_declaration declaration)
                  declarations
              end;
              Exit_status.Success))

let tools_cmd =
  let doc = "Print the model-visible tool declarations for a run." in
  Cmd.v
    (Cmd.info "tools" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const tools $ Cli_common.json $ model_arg $ mode_arg $ Cli_common.cwd))

(* group. *)

(* dirs. — the resolved per-user directories and the derived socket base, one
   key=value line each. The socket base is where every session's agent binds
   its derived endpoint ([<sockets>/s/<leaf>]); harnesses read it here rather
   than re-deriving the data-home digest. *)
let dirs cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let dirs = Composition.dirs t in
      Output.stdout_printf "config_home=%s\n" (User_dirs.config_home dirs);
      Output.stdout_printf "data_home=%s\n" (User_dirs.data_home dirs);
      Output.stdout_printf "state_home=%s\n" (User_dirs.state_home dirs);
      Output.stdout_printf "sockets=%s\n" (User_dirs.daemon_socket_dir dirs);
      Exit_status.Success)

let dirs_cmd =
  let doc = "Print the resolved per-user directories and the socket base." in
  Cmd.v
    (Cmd.info "dirs" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const dirs $ Cli_common.cwd))

let cmd =
  let doc = "Inspect model-visible prompts and internal state." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Prints what a run assembles offline: the workspace context, the \
         model-visible prompt, a session's state and on-disk artifacts, and \
         the model-conditioning decisions. Useful for diagnosing instruction, \
         context, and session issues without spending a model call.";
    ]
  in
  Cmd.group
    (Cmd.info "debug" ~doc ~docs ~man ~exits:Cli_common.exits)
    [ context_cmd; prompt_cmd; session_cmd; tools_cmd; model_cmd; dirs_cmd ]
