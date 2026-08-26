(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
open Mentat_charter
open Mentat_github

let docs = Cli_common.s_config
let ( let* ) = Result.bind

let resolve_dirs () =
  match User_dirs.resolve ~getenv:Sys.getenv_opt with
  | Ok dirs -> Ok dirs
  | Error message -> Error (Exit_status.runtime message)

let store_error e = Exit_status.runtime (Charter_store.Error.message e)

let load dirs ~name =
  Result.map_error store_error (Charter_store.load dirs ~name)

let read_receipts dirs ~name =
  Result.map_error store_error (Charter_store.read_receipts dirs ~name)

let webhook_arm charter =
  List.exists
    (function
      | Charter.Trigger.Github_webhook _ -> true | Charter.Trigger.Cli -> false)
    charter.Charter.triggers

(* add *)

let add src =
  (let* dirs = resolve_dirs () in
   let* installed =
     Result.map_error store_error (Charter_store.install dirs ~src)
   in
   let loaded = installed.Charter_store.Installed.loaded in
   Output.stdout_printf "added %s (%s)\n" loaded.Charter_store.Loaded.name
     loaded.Charter_store.Loaded.dir;
   Output.stdout_printf "digest %s\n" loaded.Charter_store.Loaded.digest;
   (match installed.Charter_store.Installed.webhook with
   | None -> ()
   | Some { Charter_store.Installed.id; id_minted; secret_minted } ->
       if id_minted then
         Output.stdout_printf
           "webhook POST /ingress/github/%s (fresh URL; update GitHub \
            settings)\n"
           id
       else Output.stdout_printf "webhook POST /ingress/github/%s\n" id;
       if secret_minted then
         Output.stdout_printf
           "webhook secret minted at %s; set it on the GitHub hook\n"
           (Filename.concat
              (Filename.concat loaded.Charter_store.Loaded.dir "secrets")
              "webhook"));
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* list *)

let disposition_label = function
  | Receipt.Disposition.Spawned _ -> "spawned"
  | Receipt.Disposition.Skipped _ -> "skipped"
  | Receipt.Disposition.Dup -> "dup"
  | Receipt.Disposition.Fenced meter ->
      "fenced:" ^ Receipt.Meter.to_string meter
  | Receipt.Disposition.Already_exists -> "already_exists"
  | Receipt.Disposition.Superseded -> "superseded"
  | Receipt.Disposition.Refused _ -> "refused"
  | Receipt.Disposition.Reaped { exit; _ } -> Printf.sprintf "reaped:%d" exit

(* The roster row's LAST cell is garnish: an unreadable receipt log renders as
   such here, and [charter runs NAME] is the verb that names the fault. *)
let last_disposition dirs name =
  match Charter_store.read_receipts dirs ~name with
  | Error _ -> "unreadable"
  | Ok receipts -> (
      let last =
        List.fold_left
          (fun acc receipt ->
            match receipt.Receipt.kind with
            | Receipt.Kind.Disposition disposition -> Some disposition
            | Receipt.Kind.Delivery | Receipt.Kind.Egress _
            | Receipt.Kind.Alert _ ->
                acc)
          None receipts
      in
      match last with
      | None -> "-"
      | Some disposition -> disposition_label disposition)

let list () =
  (let* dirs = resolve_dirs () in
   let* entries = Result.map_error store_error (Charter_store.roster dirs) in
   (match entries with
   | [] -> ()
   | entries ->
       let rows =
         List.map
           (fun (name, result) ->
             match result with
             | Error e ->
                 [ name; "-"; "-"; "load error: " ^ Charter_store.Error.message e ]
             | Ok loaded ->
                 [
                   name;
                   loaded.Charter_store.Loaded.digest;
                   (if loaded.Charter_store.Loaded.charter.Charter.enabled then
                      "enabled"
                    else "disabled");
                   last_disposition dirs name;
                 ])
           entries
       in
       Output.print_table ~header:[ "NAME"; "DIGEST"; "STATE"; "LAST" ] rows);
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* runs *)

let runs name =
  (let* name = Argv.charter_name name in
   let* dirs = resolve_dirs () in
   let* _loaded = load dirs ~name in
   let* receipts = read_receipts dirs ~name in
   List.iter
     (fun receipt ->
       match receipt.Receipt.kind with
       | Receipt.Kind.Disposition _ ->
           Output.stdout_printf "%s\n" (Receipt.diagnostic receipt)
       | Receipt.Kind.Delivery | Receipt.Kind.Egress _ | Receipt.Kind.Alert _
         ->
           ())
     receipts;
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* status *)

(* Mirrors the arm default {!Fence.admit} applies when the charter names no
   rate: 6 for a webhook arm, none for cli. *)
let rate_limit charter =
  match charter.Charter.budget.Charter.Budget.runs_per_hour with
  | Some limit -> Some limit
  | None -> if webhook_arm charter then Some 6 else None

let render_status dirs ~now (loaded : Charter_store.Loaded.t) =
  let charter = loaded.Charter_store.Loaded.charter in
  let digest = loaded.Charter_store.Loaded.digest in
  let* receipts = read_receipts dirs ~name:loaded.Charter_store.Loaded.name in
  Output.stdout_printf "%s\n" loaded.Charter_store.Loaded.name;
  Output.stdout_printf "  state: %s\n"
    (if charter.Charter.enabled then "enabled" else "disabled");
  Output.stdout_printf "  digest: %s\n" digest;
  let spend = Fence.spend_in_window ~digest ~now receipts in
  (match charter.Charter.budget.Charter.Budget.usd_per_day with
  | Some limit ->
      Output.stdout_printf "  spend 24h: %.2f usd of %.2f\n" spend limit
  | None -> Output.stdout_printf "  spend 24h: %.2f usd (no limit)\n" spend);
  let spawns = Fence.spawns_in_window ~digest ~now receipts in
  (match rate_limit charter with
  | Some limit -> Output.stdout_printf "  runs 1h: %d of %d\n" spawns limit
  | None -> Output.stdout_printf "  runs 1h: %d (no limit)\n" spawns);
  (match List.fold_left (fun _ receipt -> Some receipt) None receipts with
  | Some receipt ->
      Output.stdout_printf "  last: %s\n" (Receipt.diagnostic receipt)
  | None -> Output.stdout_printf "  last: no receipts\n");
  Ok ()

let status name =
  (let* dirs = resolve_dirs () in
   let now = Unix.gettimeofday () in
   match name with
   | Some name ->
       let* name = Argv.charter_name name in
       let* loaded = load dirs ~name in
       let* () = render_status dirs ~now loaded in
       Ok Exit_status.Success
   | None ->
       let* entries = Result.map_error store_error (Charter_store.roster dirs) in
       let* () =
         List.fold_left
           (fun acc (name, result) ->
             let* () = acc in
             match result with
             | Error e ->
                 Output.stdout_printf "%s\n  load error: %s\n" name
                   (Charter_store.Error.message e);
                 Ok ()
             | Ok loaded -> render_status dirs ~now loaded)
           (Ok ()) entries
       in
       Ok Exit_status.Success)
  |> Exit_status.of_result

(* remove *)

(* Strict recursive delete: a removal the owner asked for either completes or
   names what it could not remove. *)
let rec remove_tree path =
  match Sys.is_directory path with
  | true ->
      let* () =
        match Sys.readdir path with
        | entries ->
            Array.fold_left
              (fun acc entry ->
                let* () = acc in
                remove_tree (Filename.concat path entry))
              (Ok ()) entries
        | exception Sys_error message -> Error message
      in
      (match Unix.rmdir path with
      | () -> Ok ()
      | exception Unix.Unix_error (e, _, _) ->
          Error (Printf.sprintf "%s: %s" path (Unix.error_message e)))
  | false -> (
      match Sys.remove path with
      | () -> Ok ()
      | exception Sys_error message -> Error message)
  | exception Sys_error message -> Error message

let remove name =
  (let* name = Argv.charter_name name in
   let* dirs = resolve_dirs () in
   let dir = User_dirs.charter_dir dirs name in
   let* () =
     if Sys.file_exists dir then Ok ()
     else
       Error (Exit_status.runtime (Printf.sprintf "no charter named %s" name))
   in
   let* () = Result.map_error Exit_status.runtime (remove_tree dir) in
   Output.stdout_printf "removed %s (%s)\n" name dir;
   let state = User_dirs.charter_state_dir dirs name in
   if Sys.file_exists state then
     Output.stdout_printf
       "state kept at %s: receipts and claim markers are the audit trail\n"
       state;
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* fire — the pipeline, run in this process (the cli trigger arm: the
   invoker is the owner's own scheduler). The pipeline itself lives in
   [Charter_fire]; this verb reads the event bytes, requires the read
   credential, and constructs the injected GitHub closures over the
   first-party client — the one HTTP-touching assembly in the cone. *)

let json_mem name = function
  | Jsont.Object (mems, _) -> Option.map snd (Jsont.Json.find_mem name mems)
  | _ -> None

let json_string = function Jsont.String (s, _) -> Some s | _ -> None

let json_int = function
  | Jsont.Number (v, _) when Float.is_integer v -> Some (int_of_float v)
  | _ -> None

let contains ~needle haystack =
  let n = String.length needle and m = String.length haystack in
  let rec go i = i + n <= m && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  n > 0 && go 0

let api_error e = Github_api.Error.message e

(* The sweep listing's page items, mapped to the pipeline's open-PR shape.
   Members the pipeline does not gate on are ignored, the narrow-read
   posture every foreign payload gets. *)
let open_prs_of_pages pages =
  List.concat_map
    (fun page ->
      match page with
      | Jsont.Array (items, _) ->
          List.filter_map
            (fun item ->
              let ( let* ) = Option.bind in
              let* number = Option.bind (json_mem "number" item) json_int in
              let* head_sha =
                Option.bind
                  (Option.bind (json_mem "head" item) (json_mem "sha"))
                  json_string
              in
              let* base_ref =
                Option.bind
                  (Option.bind (json_mem "base" item) (json_mem "ref"))
                  json_string
              in
              let* draft =
                match json_mem "draft" item with
                | Some (Jsont.Bool (b, _)) -> Some b
                | _ -> None
              in
              let* author_association =
                Option.bind (json_mem "author_association" item) json_string
              in
              Some
                {
                  Charter_fire.Github.number;
                  head_sha;
                  base_ref;
                  draft;
                  author_association;
                })
            items
      | _ -> [])
    pages

(* The posted-comments closure: both comment families the publisher writes
   into, filtered to the credential's own login and this tool's marker
   openers — marker presence alone is forgeable, so the author predicate is
   what makes a comment ours. Assumes the read and write credentials share
   the owner's posting identity, which single-owner charters do. *)
let posted_listing api ~repo ~number =
  let ( let* ) = Result.bind in
  let* login =
    match Github_api.get api ~path:"/user" with
    | Error e -> Error (api_error e)
    | Ok json -> (
        match Option.bind (json_mem "login" json) json_string with
        | Some login -> Ok login
        | None -> Error "/user answered without a login member")
  in
  let listing path =
    match Github_api.get_paginated api ~path ~max_pages:10 with
    | Error e -> Error (api_error e)
    | Ok pages ->
        Ok
          (List.concat_map
             (fun page ->
               match page with Jsont.Array (items, _) -> items | _ -> [])
             pages)
  in
  let* review_comments =
    listing (Printf.sprintf "/repos/%s/pulls/%d/comments?per_page=100" repo number)
  in
  let* issue_comments =
    listing (Printf.sprintf "/repos/%s/issues/%d/comments?per_page=100" repo number)
  in
  let ours item =
    let by_us =
      Option.bind (Option.bind (json_mem "user" item) (json_mem "login")) json_string
      = Some login
    in
    let marked =
      match Option.bind (json_mem "body" item) json_string with
      | Some body -> contains ~needle:"<!-- mentat-" body
      | None -> false
    in
    by_us && marked
  in
  let rows =
    List.filter_map
      (fun item ->
        if not (ours item) then None
        else
          match
            ( Option.bind (json_mem "id" item) json_int,
              Option.bind (json_mem "body" item) json_string )
          with
          | Some id, Some body ->
              Some
                (Output.Json.obj
                   [ ("id", Output.Json.int id); ("body", Output.Json.string body) ])
          | _ -> None)
      (review_comments @ issue_comments)
  in
  Ok (Output.Json.to_string (Output.Json.list rows))

let fire_env t (loaded : Charter_store.Loaded.t) =
  let dirs = Composition.dirs t in
  let repo = loaded.Charter_store.Loaded.charter.Charter.repo in
  let* token =
    let path =
      Filename.concat
        (Filename.concat loaded.Charter_store.Loaded.dir "secrets")
        "read-token"
    in
    match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
    | Ok (Some bytes) when String.length (String.trim bytes) > 0 ->
        Ok (String.trim bytes)
    | Ok (Some _) | Ok None ->
        Error
          (Exit_status.runtime
             (Printf.sprintf
                "fire needs the GitHub read credential at %s (a fine-grained \
                 PAT with read access to %s)"
                path repo))
    | Error message -> Error (Exit_status.runtime message)
  in
  let base_url = Composition.getenv t "MENTAT_GITHUB_BASE_URL" in
  let* api =
    match Github_api.make ?base_url ~token (Eio.Stdenv.net (Composition.stdenv t)) with
    | Ok api -> Ok api
    | Error e -> Error (Exit_status.runtime (api_error e))
  in
  let github =
    {
      Charter_fire.Github.current_head =
        (fun ~number ->
          match
            Github_api.get api ~path:(Printf.sprintf "/repos/%s/pulls/%d" repo number)
          with
          | Error e -> Error (api_error e)
          | Ok json -> (
              match
                Option.bind
                  (Option.bind (json_mem "head" json) (json_mem "sha"))
                  json_string
              with
              | Some sha -> Ok sha
              | None -> Error "pull request answered without head.sha"));
      open_prs =
        (fun () ->
          match
            Github_api.get_paginated api
              ~path:(Printf.sprintf "/repos/%s/pulls?state=open&per_page=100" repo)
              ~max_pages:10
          with
          | Error e -> Error (api_error e)
          | Ok pages -> Ok (open_prs_of_pages pages));
      posted = (fun ~number -> posted_listing api ~repo ~number);
    }
  in
  let git_url =
    match Composition.getenv t "MENTAT_CHARTER_GIT_URL" with
    | Some url when String.length url > 0 -> url
    | Some _ | None -> Printf.sprintf "https://github.com/%s.git" repo
  in
  Ok
    {
      Charter_fire.dirs;
      store = Composition.store t;
      catalog = Composition.catalog t;
      stdenv = Composition.stdenv t;
      environment = Composition.environment t;
      mentat_bin = Sys.executable_name;
      git_url;
      github;
    }

let fire name event_file sweep key =
  (let* name = Argv.charter_name name in
   let* () =
     match (event_file, sweep) with
     | Some _, true ->
         Error (Exit_status.usage "choose one of --event or --sweep")
     | _ -> Ok ()
   in
   let* () =
     match (key, event_file, sweep) with
     | Some _, Some _, _ | Some _, _, true ->
         Error
           (Exit_status.usage
              "--key names a bare fire's identity; --event and --sweep carry \
               their delivery's own")
     | _ -> Ok ()
   in
   Ok
     (Composition.with_base ~cwd:None ~overrides:[] (fun t ->
          match Charter_store.load (Composition.dirs t) ~name with
          | Error e -> Exit_status.runtime (Charter_store.Error.message e)
          | Ok loaded -> (
              let cli_armed =
                List.exists
                  (function
                    | Charter.Trigger.Cli -> true
                    | Charter.Trigger.Github_webhook _ -> false)
                  loaded.Charter_store.Loaded.charter.Charter.triggers
              in
              if not cli_armed then
                Exit_status.usage
                  (Printf.sprintf
                     "charter %s has no cli trigger arm; add {\"kind\": \
                      \"cli\"} to its trigger list to fire it by hand"
                     name)
              else
                let outcome status =
                  match status with
                  | Ok Charter_fire.Disposed -> Exit_status.Success
                  | Ok Charter_fire.Interrupted -> Exit_status.Interrupted
                  | Error message -> Exit_status.runtime message
                in
                match (event_file, sweep) with
                | None, false ->
                    (* Every version-1 charter reviews pull requests, so a
                       bare or --key fire has nothing to review; the (digest,
                       key) identity is minted vocabulary awaiting a charter
                       shape that runs without an event. *)
                    Exit_status.usage
                      (Printf.sprintf
                         "charter %s reviews pull requests and a bare fire \
                          has nothing to review; use --event FILE or --sweep"
                         name)
                | (Some _, _ | None, true)
                  when not (webhook_arm loaded.Charter_store.Loaded.charter) ->
                    Exit_status.usage
                      (Printf.sprintf
                         "charter %s has no github_webhook trigger; --event \
                          and --sweep replay webhook deliveries"
                         name)
                | Some file, _ -> (
                    match Fs.read_capped ~max_bytes:(1024 * 1024) file with
                    | Ok None ->
                        Exit_status.usage
                          (Printf.sprintf "--event: file not found: %s" file)
                    | Error message -> Exit_status.runtime message
                    | Ok (Some body) -> (
                        match fire_env t loaded with
                        | Error status -> status
                        | Ok env ->
                            outcome (Charter_fire.fire_event env loaded ~body)))
                | None, true -> (
                    match fire_env t loaded with
                    | Error status -> status
                    | Ok env -> outcome (Charter_fire.fire_sweep env loaded))))))
  |> Exit_status.of_result

(* command assembly *)

let src_arg =
  let doc = "The charter to install: its directory, or its charter.json." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH|DIR" ~doc)

let name_arg =
  let doc = "The charter's name." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)

let name_opt_arg =
  let doc = "Limit to this charter." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)

let add_cmd =
  let doc = "Validate and install a charter; mint its webhook identity." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Validates the charter at $(i,PATH|DIR) — strictly, refusing unknown \
         members, unimplemented trigger kinds, and any write-capable grant — \
         and installs it under its own name in the config home. For a \
         webhook charter the ingress URL token and the webhook secret are \
         minted once, where absent: re-adding replaces the policy files \
         (which moves the policy digest and resets fence windows) but never \
         the identity, so owner edits never move the webhook URL. The \
         printed $(b,/ingress/github/…) path and the secret at \
         $(b,secrets/webhook) go into the repository's webhook settings.";
      `P
        "A proposal shipped inside a repository must not carry $(b,secrets/) \
         or $(b,ingress.id); both are created at install, and a removed \
         charter's re-add mints a fresh URL.";
    ]
  in
  Cmd.v
    (Cmd.info "add" ~doc ~docs ~man ~exits:Cli_common.exits)
    (Exit_status.term Term.(const add $ src_arg))

let list_cmd =
  let doc = "List installed charters." in
  Cmd.v
    (Cmd.info "list" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const list $ const ()))

let runs_cmd =
  let doc = "Print a charter's disposition receipts." in
  Cmd.v
    (Cmd.info "runs" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const runs $ name_arg))

let status_cmd =
  let doc = "Render each charter's durable record: budgets and receipts." in
  Cmd.v
    (Cmd.info "status" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const status $ name_opt_arg))

let remove_cmd =
  let doc = "Remove a charter's configuration, keeping its audit trail." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Deletes the charter directory — policy, secrets, and webhook \
         identity, so a later $(b,add) mints a fresh URL. Receipts and run \
         roots under the state home are deliberately kept and named: they \
         are the audit trail.";
    ]
  in
  Cmd.v
    (Cmd.info "remove" ~doc ~docs ~man ~exits:Cli_common.exits)
    (Exit_status.term Term.(const remove $ name_arg))

let event_opt =
  let doc =
    "Drive the saved webhook delivery in $(docv) — the raw pull_request \
     payload bytes — through the pipeline, fenced exactly as the ingress \
     fences a live delivery."
  in
  Arg.(value & opt (some string) None & info [ "event" ] ~docv:"FILE" ~doc)

let sweep_flag =
  let doc =
    "Reconcile against the repository's open pull requests: one listing \
     with the read credential, then one synthesized delivery per head that \
     holds no receipt under the current policy digest."
  in
  Arg.(value & flag & info [ "sweep" ] ~doc)

let key_opt =
  let doc =
    "The identity key of a bare fire; distinct keys are distinct events. \
     Reserved: every version-1 charter is event-shaped, so a bare fire is \
     refused."
  in
  Arg.(value & opt (some string) None & info [ "key" ] ~docv:"STRING" ~doc)

let fire_cmd =
  let doc = "Fire a charter by hand: a saved delivery, or a sweep." in
  let envs =
    [
      Cmd.Env.info "MENTAT_GITHUB_BASE_URL"
        ~doc:
          "Overrides the GitHub API base for the read closures and the \
           publisher child — for GitHub Enterprise hosts and offline test \
           servers.";
      Cmd.Env.info "MENTAT_CHARTER_GIT_URL"
        ~doc:
          "Overrides the git remote the checkout fetches from (derived from \
           the charter's repository by default) — for GitHub Enterprise \
           hosts and offline test fixtures.";
    ]
  in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Runs the charter pipeline in this process: gate, identity claim, \
         delivery receipt, budget fences, checkout provisioning, the sealed \
         review run, the disposition receipt with usage and derived cost, \
         publication through the connector, and the egress receipt. \
         $(b,--event FILE) drives a saved delivery; $(b,--sweep) synthesizes \
         one delivery per open pull request head without a receipt, so a \
         crontab line is a complete, fenced, deduplicated review charter \
         with no listener.";
      `P
        "The read credential is $(b,secrets/read-token) in the charter \
         directory; the write credential, $(b,secrets/write-token), is \
         optional — absent, the run still reviews and the egress receipt \
         records that publication was skipped.";
    ]
  in
  Cmd.v
    (Cmd.info "fire" ~doc ~docs ~envs ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const fire $ name_arg $ event_opt $ sweep_flag $ key_opt))

let cmd =
  let doc = "Manage standing, unattended review charters." in
  Cmd.group
    (Cmd.info "charter" ~doc ~docs ~exits:Cli_common.exits)
    [ add_cmd; list_cmd; fire_cmd; runs_cmd; status_cmd; remove_cmd ]
