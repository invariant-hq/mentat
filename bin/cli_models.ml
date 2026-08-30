(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Client = Mentat_client
module Model = Mentat_provider.Model
module Catalog = Mentat_provider.Catalog
module Selector = Mentat_provider.Selector
module Readiness = Mentat_provider.Model_readiness
module Route = Readiness.Route
module Entry = Readiness.Entry
module Availability = Readiness.Availability
module Actionability = Readiness.Actionability
module Account = Mentat_provider.Account
module Discovery = Account.Discovery
module Phase = Account.Phase
module Credential_error = Mentat_provider.Credential_error
module Provider = Mentat_llm.Provider
module Composition = Mentat_boot.Composition
module Config_io = Mentat_boot.Config_io
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

let docs = Cli_common.s_config

let status_string (s : Model.status) =
  match s with
  | Model.Stable -> "stable"
  | Model.Preview -> "preview"
  | Model.Deprecated -> "deprecated"
  | Model.Unavailable reason -> "unavailable: " ^ reason

let context_string m =
  match Model.context_window m with Some n -> string_of_int n | None -> "-"

let selector_string m = Selector.to_string (Model.selector m)

(* Base-tier $/MTOK straight from the pricing metadata; an unpriced lane stays
   [None] — unknown, not free. *)
let cost_input model = fst (Model.rate_per_million model)
let cost_output model = snd (Model.rate_per_million model)

let cost_cell input output =
  match (input, output) with
  | None, None -> "-"
  | _ ->
      let fmt = function None -> "?" | Some v -> Printf.sprintf "%g" v in
      fmt input ^ "/" ^ fmt output

let float_or_null = function
  | None -> Output.Json.null
  | Some value -> Jsont.Json.number value

let cost_json model =
  Output.Json.obj
    [
      ("input_per_million", float_or_null (cost_input model));
      ("output_per_million", float_or_null (cost_output model));
    ]

(* A model is its provider's declared default when the declaration names it. The
   readiness owner value carries no default marker, so the catalog answers it. *)
let is_provider_default catalog model =
  match Catalog.declaration catalog (Model.provider model) with
  | None -> false
  | Some declaration ->
      Option.fold ~none:false
        ~some:(fun default ->
          Selector.equal (Model.selector default) (Model.selector model))
        (Mentat_provider.default_model declaration)

(* The effective provider-route actionability, condensed for a table cell: the
   fact a user acts on. Static eligibility is already the STATUS column, and the
   finer checked availability rides {!readiness_json}. *)
let phase_word (phase : Phase.t) =
  match phase with
  | Phase.Missing -> "sign-in"
  | Phase.Blocked -> "blocked"
  | phase -> Phase.to_string phase

let readiness_cell entry =
  match Entry.actionability entry with
  | Actionability.Actionable -> "ready"
  | Actionability.Model_unavailable -> "unavailable"
  | Actionability.Provider_blocked (Discovery.Resolution_failed _) ->
      "cred error"
  | Actionability.Provider_blocked (Discovery.Known account) ->
      phase_word (Account.phase account)

let availability_string = function
  | Availability.Available -> "available"
  | Availability.Unavailable -> "unavailable"
  | Availability.Unknown -> "unknown"

let actionability_string = function
  | Actionability.Actionable -> "actionable"
  | Actionability.Model_unavailable -> "model_unavailable"
  | Actionability.Provider_blocked _ -> "provider_blocked"

let readiness_json route entry =
  Output.Json.obj
    [
      ( "availability",
        Output.Json.string (availability_string (Entry.availability entry)) );
      ( "actionability",
        Output.Json.string (actionability_string (Entry.actionability entry)) );
      ("auth_required", Output.Json.bool (Route.auth_required route));
    ]

(* The credential-readiness label for one provider route, credential-free. *)
let credentials_label = function
  | Discovery.Resolution_failed { error; _ } ->
      "error · " ^ Credential_error.message error
  | Discovery.Known account -> Phase.to_string (Account.phase account)

(* The winning source of the configured main model, or [default] when selection
   derived it — selection itself records no provenance, so the config layer does.
*)
let config_source_string (source : Mentat_config.Source.t) =
  match source with
  | Mentat_config.Source.User _ -> "user config"
  | Mentat_config.Source.Project _ -> "project config"
  | Mentat_config.Source.Project_local _ -> "project-local config"
  | Mentat_config.Source.Extra_file _ -> "extra config file"
  | Mentat_config.Source.Env { name } -> "env " ^ name
  | Mentat_config.Source.Override -> "override"
  | Mentat_config.Source.Default { reason } -> "default · " ^ reason

let current_source config =
  match Mentat_config.Resolved.origin Mentat_config.Field.model config with
  | Some origin -> config_source_string (Mentat_config.Origin.source origin)
  | None -> "default"

(* The small-model role's source: the winning config source of [small_model]
   when configured, else [default] — an unset [small_model] falls back to the
   main model, so its provenance is a derivation, not a config layer. *)
let current_small_source config =
  match
    Mentat_config.Resolved.origin Mentat_config.Field.small_model config
  with
  | Some origin -> config_source_string (Mentat_config.Origin.source origin)
  | None -> "default"

(* A server-listed row someone could actually pick shows by default; a
   server-listed row that is only history — the server marks it deprecated —
   rides [--all]. Declared rows keep the estate-wide rule: visible even when
   deprecated, for diagnostics. *)
let on_demand entry =
  match Entry.origin entry with
  | Entry.Declared -> false
  | Entry.Listed -> not (Model.selectable (Entry.model entry))

(* The flat model rows the readiness owner value carries, in provider/model
   declaration order: every route's entries, narrowed by an optional provider
   and dropped to visible, pickable models unless [all]. *)
let readiness_rows ~all ~provider readiness =
  let want = Option.map Provider.make provider in
  Readiness.routes readiness
  |> List.filter (fun route ->
      match want with
      | None -> true
      | Some p -> Provider.equal (Route.provider route) p)
  |> List.concat_map (fun route ->
      Route.models route
      |> List.filter (fun entry ->
          all || (Model.visible (Entry.model entry) && not (on_demand entry)))
      |> List.map (fun entry -> (route, entry)))

(* list. *)

(* [list] consumes the [model_readiness] query so the catalog
   is reported with live per-model actionability, not just static metadata. The
   catalog is still read from the base for the provider-default marker, which the
   readiness owner value does not carry. *)
let list json provider all cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Composition.client t with
      | Error status -> status
      | Ok client -> (
          match Client.model_readiness ~refresh:true client with
          | Error error -> Exit_status.of_protocol_error error
          | Ok readiness ->
              let catalog = Composition.catalog t in
              let rows = readiness_rows ~all ~provider readiness in
              let is_default (_, entry) =
                is_provider_default catalog (Entry.model entry)
              in
              if json then
                Output.stdout_printf "%s\n"
                  (Output.Json.to_string
                     (Output.Json.envelope ~type_:"models"
                        [
                          ( "models",
                            Output.Json.list
                              (List.map
                                 (fun (route, entry) ->
                                   let m = Entry.model entry in
                                   Output.Json.obj
                                     [
                                       ( "model",
                                         Output.Json.string (selector_string m)
                                       );
                                       ( "status",
                                         Output.Json.string
                                           (status_string (Model.status m)) );
                                       ( "context_window",
                                         Output.Json.int_or_null
                                           (Model.context_window m) );
                                       ( "provider_default",
                                         Output.Json.bool
                                           (is_provider_default catalog m) );
                                       ("cost", cost_json m);
                                       ("readiness", readiness_json route entry);
                                     ])
                                 rows) );
                        ]))
              else begin
                Output.print_table
                  ~header:
                    [ "MODEL"; "STATUS"; "CONTEXT"; "COST $/MTOK"; "READINESS" ]
                  (List.map
                     (fun (_, entry) ->
                       let m = Entry.model entry in
                       let selector = selector_string m in
                       let selector =
                         if is_provider_default catalog m then selector ^ " *"
                         else selector
                       in
                       [
                         selector;
                         status_string (Model.status m);
                         context_string m;
                         cost_cell (cost_input m) (cost_output m);
                         readiness_cell entry;
                       ])
                     rows);
                if List.exists is_default rows then
                  Output.stdout_printf "* provider default\n"
              end;
              Exit_status.Success))

let provider_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "provider" ] ~docv:"PROVIDER" ~doc:"Only this provider's models.")

let all_flag =
  Arg.(
    value & flag & info [ "all" ] ~doc:"Include hidden and unavailable models.")

let list_term =
  Term.(const list $ Cli_common.json $ provider_opt $ all_flag $ Cli_common.cwd)

let list_cmd =
  let doc = "List available models." in
  Cmd.v
    (Cmd.info "list" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term list_term)

(* show. *)

let show json selector cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Composition.resolve_model t selector with
      (* An unknown provider/model is invalid input — a usage error
         (exit 2), uniform with [models select]. *)
      | Error message -> Exit_status.usage message
      | Ok m ->
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string
                 (Output.Json.envelope ~type_:"model"
                    [
                      ("model", Output.Json.string (selector_string m));
                      ( "status",
                        Output.Json.string (status_string (Model.status m)) );
                      ( "context_window",
                        Output.Json.int_or_null (Model.context_window m) );
                      ( "max_output_tokens",
                        Output.Json.int_or_null (Model.max_output_tokens m) );
                      ( "display_name",
                        Output.Json.string_or_null (Model.display_name m) );
                    ]))
          else (
            Output.stdout_printf "model=%s\n" (selector_string m);
            Output.stdout_printf "status=%s\n" (status_string (Model.status m));
            Output.stdout_printf "context_window=%s\n" (context_string m);
            match Model.display_name m with
            | Some name -> Output.stdout_printf "display_name=%s\n" name
            | None -> ());
          Exit_status.Success)

let model_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"MODEL" ~doc:"A provider/model selector.")

let show_cmd =
  let doc = "Show one model's details." in
  Cmd.v
    (Cmd.info "show" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const show $ Cli_common.json $ model_arg $ Cli_common.cwd))

(* current. *)

(* [current] resolves the effective main and small models (base selection), then
   consumes the readiness query to explain each: where the selection came from —
   config provenance, else derived — and the credential readiness of its provider
   route. The small role layers over the main model and falls back to it, so an
   unset [small_model] shows the same model under a [default] source. *)
let current json cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Composition.default_model t with
      | Error message -> Exit_status.runtime message
      | Ok main_model -> (
          match Composition.small_model t with
          | Error message -> Exit_status.runtime message
          | Ok small_model -> (
              match Composition.client t with
              | Error status -> status
              | Ok client -> (
                  match Client.model_readiness client with
                  | Error error -> Exit_status.of_protocol_error error
                  | Ok readiness ->
                      let config = Composition.config t in
                      let credentials_for provider =
                        match
                          List.find_opt
                            (fun route ->
                              Provider.equal (Route.provider route) provider)
                            (Readiness.routes readiness)
                        with
                        | Some route ->
                            credentials_label (Route.discovery route)
                        | None -> "-"
                      in
                      let role model source =
                        let selector =
                          Selector.to_string (Selector.of_model model)
                        in
                        let credentials =
                          credentials_for (Mentat_llm.Model.provider model)
                        in
                        (selector, source, credentials)
                      in
                      let main_selector, main_source, main_credentials =
                        role main_model (current_source config)
                      in
                      let small_selector, small_source, small_credentials =
                        role small_model (current_small_source config)
                      in
                      if json then
                        Output.stdout_printf "%s\n"
                          (Output.Json.to_string
                             (Output.Json.envelope ~type_:"model.current"
                                [
                                  ("model", Output.Json.string main_selector);
                                  ("source", Output.Json.string main_source);
                                  ( "credentials",
                                    Output.Json.string main_credentials );
                                  ( "small",
                                    Output.Json.obj
                                      [
                                        ( "model",
                                          Output.Json.string small_selector );
                                        ( "source",
                                          Output.Json.string small_source );
                                        ( "credentials",
                                          Output.Json.string small_credentials
                                        );
                                      ] );
                                ]))
                      else
                        Output.print_table
                          ~header:[ "ROLE"; "MODEL"; "SOURCE"; "CREDENTIALS" ]
                          [
                            [
                              "main";
                              main_selector;
                              main_source;
                              main_credentials;
                            ];
                            [
                              "small";
                              small_selector;
                              small_source;
                              small_credentials;
                            ];
                          ];
                      Exit_status.Success))))

let current_cmd =
  let doc = "Show the effective main and small models." in
  Cmd.v
    (Cmd.info "current" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const current $ Cli_common.json $ Cli_common.cwd))

(* select. *)

(* [select] writes the chosen selector into user config: the main [model] key by
   default, or the auxiliary [small_model] key under [--small]. Both are
   [(Selector.t, optional)] fields, so one write path serves both roles. *)
let select small selector cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Composition.resolve_model t selector with
      | Error message -> Exit_status.usage message
      | Ok _ -> (
          let field =
            if small then Mentat_config.Field.small_model
            else Mentat_config.Field.model
          in
          match
            Config_io.plan_write ~dirs:(Composition.dirs t)
              ~root:(Composition.root t) Config_io.User ~f:(fun config ->
                Mentat_config.set_text field selector config)
          with
          | Ok _ ->
              Output.stdout_printf "%s %s\n"
                (Mentat_config.Field.name field)
                selector;
              Exit_status.Success
          | Error message -> Exit_status.runtime message))

let small_flag =
  Arg.(
    value & flag
    & info [ "small" ]
        ~doc:
          "Write the auxiliary small-model key ($(b,small_model)) instead of \
           the main model.")

let select_cmd =
  let doc = "Select the main or small model in user config." in
  Cmd.v
    (Cmd.info "select" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const select $ small_flag $ model_arg $ Cli_common.cwd))

(* download. — the composition-edge responder over the runtime's local-artifact
   flow. Only local providers carry a downloadable
   weight; a remote model resolves to [Not_downloadable]. *)

module Runtime = Mentat_provider_runtime
module Artifact = Runtime.Artifact

let phase_string (p : Artifact.Progress.phase) =
  match p with
  | Artifact.Progress.Checking -> "checking"
  | Artifact.Progress.Downloading -> "downloading"
  | Artifact.Progress.Verifying -> "verifying"
  | Artifact.Progress.Ready -> "ready"

let received_human (p : Artifact.Progress.t) =
  match p.Artifact.Progress.total with
  | Some total ->
      Printf.sprintf "%Ld/%Ld bytes" p.Artifact.Progress.received total
  | None -> Printf.sprintf "%Ld bytes" p.Artifact.Progress.received

let download force json selector cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Catalog.resolve (Composition.catalog t) selector with
      (* An unknown provider/model is a usage error (exit 2), uniform. *)
      | Error e -> Exit_status.usage (Catalog.Error.message e)
      | Ok m -> (
          let model = Model.llm m in
          let observe (p : Artifact.Progress.t) =
            if json then
              Output.stdout_printf "%s\n"
                (Output.Json.to_string
                   (Output.Json.envelope ~type_:"model.download.progress"
                      [
                        ("model", Output.Json.string p.Artifact.Progress.model);
                        ("label", Output.Json.string p.Artifact.Progress.label);
                        ( "received",
                          Output.Json.int
                            (Int64.to_int p.Artifact.Progress.received) );
                        ( "total",
                          Output.Json.int_or_null
                            (Option.map Int64.to_int p.Artifact.Progress.total)
                        );
                        ( "phase",
                          Output.Json.string
                            (phase_string p.Artifact.Progress.phase) );
                      ]))
            else
              Output.stderr_printf "mentat: %s %s (%s)\n"
                (phase_string p.Artifact.Progress.phase)
                p.Artifact.Progress.label (received_human p)
          in
          let outcome =
            Runtime.Local.download (Composition.runtime t)
              ~sw:(Composition.sw t) ~env:(Composition.stdenv t) ~force ~observe
              model
          in
          let terminal () =
            if json then
              let outcome_json =
                match
                  Jsont.Json.encode Artifact.Download_outcome.jsont outcome
                with
                | Ok j -> j
                | Error _ -> Output.Json.null
              in
              Output.stdout_printf "%s\n"
                (Output.Json.to_string
                   (Output.Json.envelope ~type_:"model.download"
                      [ ("outcome", outcome_json) ]))
          in
          match outcome with
          | Artifact.Download_outcome.Already_installed path ->
              terminal ();
              if not json then
                Output.stdout_printf "already installed at %s\n" path;
              Exit_status.Success
          | Artifact.Download_outcome.Downloaded ->
              terminal ();
              if not json then Output.stdout_printf "installed %s\n" selector;
              Exit_status.Success
          | Artifact.Download_outcome.Not_downloadable ->
              terminal ();
              if json then Exit_status.Failed
              else
                Exit_status.runtime
                  (Printf.sprintf
                     "no local artifact for %s; only local providers have \
                      downloadable weights"
                     selector)
          | Artifact.Download_outcome.Refused { message; force_hint } ->
              terminal ();
              let message =
                if force_hint then message ^ "; re-run with --force"
                else message
              in
              if json then Exit_status.Failed else Exit_status.runtime message))

let force_flag =
  Arg.(
    value & flag
    & info [ "force" ] ~doc:"Re-download even if already installed.")

let download_cmd =
  let doc = "Download a local model artifact." in
  Cmd.v
    (Cmd.info "download" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const download $ force_flag $ Cli_common.json $ model_arg
         $ Cli_common.cwd))

let cmd =
  let doc = "List and select models." in
  Cmd.group
    ~default:(Exit_status.term list_term)
    (Cmd.info "models" ~doc ~docs ~exits:Cli_common.exits)
    [ list_cmd; show_cmd; current_cmd; select_cmd; download_cmd ]
