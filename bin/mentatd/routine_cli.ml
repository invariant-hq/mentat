(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
open Mentat_routine

let ( let* ) = Result.bind

let resolve_dirs () =
  match User_dirs.resolve ~getenv:Sys.getenv_opt with
  | Ok dirs -> Ok dirs
  | Error message -> Error (Exit_status.runtime message)

let store_error e = Exit_status.runtime (Routine_store.Error.message e)

let load dirs ~name =
  Result.map_error store_error (Routine_store.load dirs ~name)

let read_receipts dirs ~name =
  Result.map_error store_error (Routine_store.read_receipts dirs ~name)

(* The printing obligation (A4): every roster surface names each routine's
   auth mode and posting identity — the price of deciding the mode by file
   presence, so a stale token file or a forgotten setup can never flip a
   routine's identity silently. One projection, two densities. *)

let auth_word dirs loaded =
  match Routine_store.auth_mode dirs loaded with
  | Ok `Pat -> "pat"
  | Ok (`App _) -> "app"
  | Ok `Neither -> "none"
  | Error _ -> "error"

let auth_line dirs loaded =
  match Routine_store.auth_mode dirs loaded with
  | Ok `Pat -> "auth: personal access tokens (secrets/)"
  | Ok (`App app) ->
      Printf.sprintf "auth: GitHub App %s (posts as %s)"
        app.Github_app_store.name
        (Github_app_store.posting_login app)
  | Ok `Neither ->
      "auth: none; run `mentatd github setup` or write secrets/read-token"
  | Error e -> Printf.sprintf "auth: %s" (Routine_store.Error.message e)

(* add *)

let add src =
  (let* dirs = resolve_dirs () in
   let* installed =
     Result.map_error store_error (Routine_store.install dirs ~src)
   in
   let loaded = installed.Routine_store.Installed.loaded in
   Output.stdout_printf "added %s (%s)\n" loaded.Routine_store.Loaded.name
     loaded.Routine_store.Loaded.dir;
   Output.stdout_printf "digest %s\n" loaded.Routine_store.Loaded.digest;
   (match installed.Routine_store.Installed.webhook with
   | None -> ()
   | Some { Routine_store.Installed.id; id_minted; secret_minted } ->
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
              (Filename.concat loaded.Routine_store.Loaded.dir "secrets")
              "webhook"));
   Output.stdout_printf "%s\n" (auth_line dirs loaded);
   (match Routine_store.auth_mode dirs loaded with
   | Ok (`App _) ->
       Output.stdout_printf
         "verify the installation covers %s: mentatd github status\n"
         loaded.Routine_store.Loaded.routine.Routine.repo
   | Ok `Pat | Ok `Neither | Error _ -> ());
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* rotate-secret *)

let rotate_secret name =
  (let* name = Argv.routine_name name in
   let* dirs = resolve_dirs () in
   let* loaded = load dirs ~name in
   let* () =
     match Routine.webhook_arm loaded.Routine_store.Loaded.routine with
     | Some _ -> Ok ()
     | None ->
         Error
           (Exit_status.usage
              (Printf.sprintf
                 "routine %s has no github_webhook trigger, so there is no \
                  webhook secret to rotate"
                 name))
   in
   (* A per-routine verb must not silently act on owner-level state: an App
      routine's deliveries verify against the App's webhook secret, which
      `mentatd github rotate-secret` owns. *)
   let* () =
     match Routine_store.auth_mode dirs loaded with
     | Ok (`App _) ->
         Error
           (Exit_status.usage
              (Printf.sprintf
                 "routine %s authenticates through the GitHub App, whose \
                  webhook secret is owner-level; use `mentatd github \
                  rotate-secret`"
                 name))
     | Ok `Pat | Ok `Neither -> Ok ()
     | Error e -> Error (store_error e)
   in
   let* path =
     Result.map_error store_error (Routine_store.rotate_webhook_secret loaded)
   in
   Output.stdout_printf "rotated webhook secret at %s\n" path;
   (match loaded.Routine_store.Loaded.ingress_id with
   | Some id ->
       Output.stdout_printf
         "webhook POST /ingress/github/%s (URL unchanged; set the new secret \
          on the GitHub hook now — the old one no longer verifies)\n"
         id
   | None -> ());
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* list *)

(* The roster row's LAST cell is garnish: an unreadable receipt log renders as
   such here, and [routine runs NAME] is the verb that names the fault. *)
let last_disposition dirs name =
  match Routine_store.read_receipts dirs ~name with
  | Error _ -> "unreadable"
  | Ok receipts -> (
      let last =
        List.fold_left
          (fun acc receipt ->
            match receipt.Receipt.kind with
            | Receipt.Kind.Disposition disposition -> Some disposition
            | Receipt.Kind.Delivery _ | Receipt.Kind.Egress _
            | Receipt.Kind.Alert _ ->
                acc)
          None receipts
      in
      match last with
      | None -> "-"
      | Some disposition -> Receipt.Disposition.label disposition)

let list () =
  (let* dirs = resolve_dirs () in
   let* entries = Result.map_error store_error (Routine_store.roster dirs) in
   (match entries with
   | [] -> ()
   | entries ->
       let rows =
         List.map
           (fun (name, result) ->
             match result with
             | Error e ->
                 [ name; "-"; "-"; "-"; Routine_store.Error.message e ]
             | Ok loaded ->
                 [
                   name;
                   loaded.Routine_store.Loaded.digest;
                   (if loaded.Routine_store.Loaded.routine.Routine.enabled then
                      "enabled"
                    else "disabled");
                   auth_word dirs loaded;
                   last_disposition dirs name;
                 ])
           entries
       in
       Output.print_table
         ~header:[ "NAME"; "DIGEST"; "STATE"; "AUTH"; "LAST" ]
         rows);
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* runs *)

let runs name =
  (let* name = Argv.routine_name name in
   let* dirs = resolve_dirs () in
   let* _loaded = load dirs ~name in
   let* receipts = read_receipts dirs ~name in
   List.iter
     (fun receipt ->
       match receipt.Receipt.kind with
       | Receipt.Kind.Disposition _ ->
           Output.stdout_printf "%s\n" (Receipt.diagnostic receipt)
       | Receipt.Kind.Delivery _ | Receipt.Kind.Egress _ | Receipt.Kind.Alert _
         ->
           ())
     receipts;
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* status *)

let render_status dirs ~now (loaded : Routine_store.Loaded.t) =
  let routine = loaded.Routine_store.Loaded.routine in
  let digest = loaded.Routine_store.Loaded.digest in
  let* receipts = read_receipts dirs ~name:loaded.Routine_store.Loaded.name in
  Output.stdout_printf "%s\n" loaded.Routine_store.Loaded.name;
  Output.stdout_printf "  state: %s\n"
    (if routine.Routine.enabled then "enabled" else "disabled");
  Output.stdout_printf "  digest: %s\n" digest;
  Output.stdout_printf "  %s\n" (auth_line dirs loaded);
  let budget = routine.Routine.budget in
  Output.stdout_printf "  %s\n" (Fence.spend_line ~digest ~now ~budget receipts);
  Output.stdout_printf "  %s\n"
    (Fence.runs_line ~digest ~now ~budget
       ~trigger:(Routine.delivery_trigger routine)
       receipts);
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
       let* name = Argv.routine_name name in
       let* loaded = load dirs ~name in
       let* () = render_status dirs ~now loaded in
       Ok Exit_status.Success
   | None ->
       let* entries = Result.map_error store_error (Routine_store.roster dirs) in
       let* () =
         List.fold_left
           (fun acc (name, result) ->
             let* () = acc in
             match result with
             | Error e ->
                 Output.stdout_printf "%s\n  %s\n" name
                   (Routine_store.Error.message e);
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
  (let* name = Argv.routine_name name in
   let* dirs = resolve_dirs () in
   let dir = User_dirs.routine_dir dirs name in
   let* () =
     if Sys.file_exists dir then Ok ()
     else
       Error (Exit_status.runtime (Printf.sprintf "no routine named %s" name))
   in
   let* () = Result.map_error Exit_status.runtime (remove_tree dir) in
   Output.stdout_printf "removed %s (%s)\n" name dir;
   let state = User_dirs.routine_state_dir dirs name in
   if Sys.file_exists state then
     Output.stdout_printf
       "state kept at %s: receipts and claim markers are the audit trail\n"
       state;
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* fire — the pipeline, run in this process. The pipeline itself lives in
   [Routine_fire] and the GitHub read conventions in [Github_reads]; this
   verb reads the event bytes, requires the read credential, snaps the
   reads onto the pipeline's injected record, and wires the owner's SIGINT
   onto the pipeline's stop seam. *)

(* The stop seam's verb-boundary wiring: the first Ctrl-C requests a stop
   the pipeline delivers to the run child, the second forces the kill (the
   disposition receipt is still written before the pipeline returns), and a
   third is the last-resort hard exit for a teardown wedged after that. *)
let with_stop_signal f =
  let sigints = Atomic.make 0 in
  let previous =
    Sys.signal Sys.sigint
      (Sys.Signal_handle
         (fun _ -> if Atomic.fetch_and_add sigints 1 >= 2 then exit 130))
  in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigint previous)
    (fun () ->
      f (fun () ->
          match Atomic.get sigints with
          | 0 -> `None
          | 1 -> `Stop
          | _ -> `Force))

let fire_env t ~stop (loaded : Routine_store.Loaded.t) =
  let repo = loaded.Routine_store.Loaded.routine.Routine.repo in
  let base_url = Composition.getenv t "MENTAT_GITHUB_BASE_URL" in
  let git_url =
    match Composition.getenv t "MENTAT_ROUTINE_GIT_URL" with
    | Some url when String.length url > 0 -> url
    | Some _ | None -> Printf.sprintf "https://github.com/%s.git" repo
  in
  let* repo_connection =
    Result.map_error Exit_status.runtime
      (Github_auth.repo ~dirs:(Composition.dirs t)
         ~net:(Eio.Stdenv.net (Composition.stdenv t))
         ~base_url ~git_url loaded)
  in
  let* mentat_bin =
    Result.map_error Exit_status.runtime
      (Daemon.resolve_sibling ~env:"MENTAT_BIN" ~name:"mentat"
         ~beside:"mentatd")
  in
  (* The fire supervises run sessions, so its composition was staged with
     the real resolver ([fire]'s [with_base ~resolve_bin]); the broker it
     yields can spawn activations. *)
  let broker = Composition.broker t in
  Ok
    ( {
        Routine_fire.dirs = Composition.dirs t;
        store = Composition.store t;
        catalog = Composition.catalog t;
        stdenv = Composition.stdenv t;
        environment = Composition.environment t;
        mentat_bin;
        broker;
        stop;
        say = (fun line -> Output.stdout_printf "%s\n" line);
      },
      repo_connection )

let fire name event_file sweep =
  (let* name = Argv.routine_name name in
   let* () =
     match (event_file, sweep) with
     | Some _, true ->
         Error (Exit_status.usage "choose one of --event or --sweep")
     | _ -> Ok ()
   in
   Ok
     (Composition.with_base ~cwd:None ~overrides:[]
        ~resolve_bin:(fun () ->
          Daemon.resolve_sibling ~env:"MENTAT_BIN" ~name:"mentat"
            ~beside:"mentatd")
        (fun t ->
          match Routine_store.load (Composition.dirs t) ~name with
          | Error e -> Exit_status.runtime (Routine_store.Error.message e)
          | Ok loaded -> (
              let cli_armed =
                List.exists
                  (function
                    | Routine.Trigger.Cli -> true
                    | Routine.Trigger.Github_webhook _ -> false)
                  loaded.Routine_store.Loaded.routine.Routine.triggers
              in
              if not cli_armed then
                Exit_status.usage
                  (Printf.sprintf
                     "routine %s has no cli trigger arm; add {\"kind\": \
                      \"cli\"} to its trigger list to fire it by hand"
                     name)
              else
                let outcome status =
                  match status with
                  | Ok Routine_fire.Disposed -> Exit_status.Success
                  | Ok Routine_fire.Interrupted -> Exit_status.Interrupted
                  | Error message -> Exit_status.runtime message
                in
                match (event_file, sweep) with
                | None, false ->
                    (* Every version-1 routine reviews pull requests, so a
                       bare fire has nothing to review; the (digest, key)
                       identity is minted vocabulary awaiting a routine
                       shape that runs without an event. *)
                    Exit_status.usage
                      (Printf.sprintf
                         "routine %s reviews pull requests and a bare fire \
                          has nothing to review; use --event FILE or --sweep"
                         name)
                | (Some _, _ | None, true)
                  when Option.is_none
                         (Routine.webhook_arm
                            loaded.Routine_store.Loaded.routine) ->
                    Exit_status.usage
                      (Printf.sprintf
                         "routine %s has no github_webhook trigger; --event \
                          and --sweep replay webhook deliveries"
                         name)
                | Some file, _ -> (
                    match
                      Fs.read_capped ~max_bytes:Routine_fire.max_event_bytes
                        file
                    with
                    | Ok None ->
                        Exit_status.usage
                          (Printf.sprintf "--event: file not found: %s" file)
                    | Error message -> Exit_status.runtime message
                    | Ok (Some body) ->
                        with_stop_signal (fun stop ->
                            match fire_env t ~stop loaded with
                            | Error status -> status
                            | Ok (env, repo) ->
                                outcome
                                  (Routine_fire.fire_event env ~repo loaded
                                     ~body)))
                | None, true ->
                    with_stop_signal (fun stop ->
                        match fire_env t ~stop loaded with
                        | Error status -> status
                        | Ok (env, repo) ->
                            outcome (Routine_fire.fire_sweep env ~repo loaded))))))
  |> Exit_status.of_result

(* command assembly *)

let src_arg =
  let doc = "The routine to install: its directory, or its routine.json." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH|DIR" ~doc)

let name_arg =
  let doc = "The routine's name." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)

let name_opt_arg =
  let doc = "Limit to this routine." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)

let add_cmd =
  let doc = "Validate and install a routine; mint its webhook identity." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Validates the routine at $(i,PATH|DIR) — strictly, refusing unknown \
         members, unimplemented trigger kinds, and any write-capable grant — \
         and installs it under its own name in the config home, printing \
         the routine's auth mode (GitHub App, PAT files, or neither). For a \
         PAT webhook routine the ingress URL token and the webhook secret \
         are minted once, where absent: re-adding replaces the policy files \
         (which moves the policy digest and resets fence windows) but never \
         the identity, so owner edits never move the webhook URL. The \
         printed $(b,/ingress/github/…) path and the secret at \
         $(b,secrets/webhook) go into the repository's webhook settings. An \
         App routine mints no per-routine webhook identity — its deliveries \
         arrive on the App's own ingress id, and there is nothing to paste \
         into GitHub settings.";
      `P
        "A proposal shipped inside a repository must not carry $(b,secrets/) \
         or $(b,ingress.id); both are created at install, and a removed \
         routine's re-add mints a fresh URL.";
    ]
  in
  Cmd.v
    (Cmd.info "add" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const add $ src_arg))

let rotate_secret_cmd =
  let doc = "Re-mint a webhook routine's HMAC secret; the URL never moves." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Replaces the secret at $(b,secrets/webhook) with a fresh 256-bit \
         key, atomically. The ingress URL is untouched — rotation changes \
         what signs deliveries, never where they land — and the old secret \
         stops verifying the moment the verb returns: deliveries still \
         signed with it answer 401 until the new secret is set on the \
         repository's webhook settings, and the reconcile sweep covers \
         whatever the gap misses.";
      `P
        "A routine without a $(b,github_webhook) trigger has no webhook \
         secret and is refused. So is an App routine: its deliveries verify \
         against the App's owner-level secret, which \
         $(b,mentatd github rotate-secret) rotates — a per-routine verb \
         must not silently act on owner-level state.";
    ]
  in
  Cmd.v
    (Cmd.info "rotate-secret" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const rotate_secret $ name_arg))

let list_cmd =
  let doc = "List installed routines." in
  Cmd.v
    (Cmd.info "list" ~doc ~exits:Exit_status.exits)
    (Exit_status.term Term.(const list $ const ()))

let runs_cmd =
  let doc = "Print a routine's disposition receipts." in
  Cmd.v
    (Cmd.info "runs" ~doc ~exits:Exit_status.exits)
    (Exit_status.term Term.(const runs $ name_arg))

let status_cmd =
  let doc = "Render each routine's durable record: budgets and receipts." in
  Cmd.v
    (Cmd.info "status" ~doc ~exits:Exit_status.exits)
    (Exit_status.term Term.(const status $ name_opt_arg))

let remove_cmd =
  let doc = "Remove a routine's configuration, keeping its audit trail." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Deletes the routine directory — policy, secrets, and webhook \
         identity, so a later $(b,add) mints a fresh URL. Receipts and run \
         roots under the state home are deliberately kept and named: they \
         are the audit trail.";
    ]
  in
  Cmd.v
    (Cmd.info "remove" ~doc ~man ~exits:Exit_status.exits)
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

let fire_cmd =
  let doc = "Fire a routine by hand: a saved delivery, or a sweep." in
  let envs =
    [
      Cmd.Env.info "MENTAT_BIN"
        ~doc:
          "The $(b,mentat) binary the pipeline spawns for the run and \
           publication children, overriding the resolution of the sibling \
           of the running executable — for layouts where the two binaries \
           do not share a directory (a build tree, a test harness).";
      Cmd.Env.info "MENTAT_GITHUB_BASE_URL"
        ~doc:
          "Overrides the GitHub API base for the read closures and the \
           publisher child — for GitHub Enterprise hosts and offline test \
           servers.";
      Cmd.Env.info "MENTAT_ROUTINE_GIT_URL"
        ~doc:
          "Overrides the git remote the checkout fetches from (derived from \
           the routine's repository by default) — for GitHub Enterprise \
           hosts and offline test fixtures.";
    ]
  in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Runs the routine pipeline in this process: gate, identity claim, \
         delivery receipt, budget fences, checkout provisioning, the sealed \
         review run, the disposition receipt with usage and derived cost, \
         publication through the connector, and the egress receipt. \
         $(b,--event FILE) drives a saved delivery; $(b,--sweep) synthesizes \
         one delivery per open pull request head without a receipt, so a \
         crontab line is a complete, fenced, deduplicated review routine \
         with no listener.";
      `P
        "The GitHub credential follows the routine's auth mode: with PAT \
         files, $(b,secrets/read-token) reads and the optional \
         $(b,secrets/write-token) publishes (absent, the run still reviews \
         and the egress receipt records that publication was skipped); \
         with neither file and the owner's GitHub App set up \
         ($(b,mentatd github setup)), short-lived installation tokens are \
         minted per fire and reviews post as the App.";
    ]
  in
  Cmd.v
    (Cmd.info "fire" ~doc ~envs ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const fire $ name_arg $ event_opt $ sweep_flag))

let cmd =
  let doc = "Manage standing, unattended review routines." in
  Cmd.group
    (Cmd.info "routine" ~doc ~exits:Exit_status.exits)
    [
      add_cmd;
      list_cmd;
      fire_cmd;
      runs_cmd;
      status_cmd;
      remove_cmd;
      rotate_secret_cmd;
    ]
