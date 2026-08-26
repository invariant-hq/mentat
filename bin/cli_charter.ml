(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
open Mentat_charter

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
  | Receipt.Disposition.Spawned -> "spawned"
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
       "state kept at %s: receipts and run roots are the audit trail\n" state;
   Ok Exit_status.Success)
  |> Exit_status.of_result

(* fire — registered so the surface is visible; the pipeline is not in this
   build. *)

let fire name =
  (let* name = Argv.charter_name name in
   Error
     (Exit_status.runtime
        (Printf.sprintf
           "charter fire %s: not implemented in this build (--event and \
            --sweep land with the fire pipeline)"
           name)))
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

let fire_cmd =
  let doc = "Fire a charter by hand (not implemented in this build)." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "The fire pipeline — $(b,--event FILE) to run a saved delivery, \
         $(b,--sweep) to reconcile against the open pull requests — is not \
         in this build; the verb refuses until it lands.";
    ]
  in
  Cmd.v
    (Cmd.info "fire" ~doc ~docs ~man ~exits:Cli_common.exits)
    (Exit_status.term Term.(const fire $ name_arg))

let cmd =
  let doc = "Manage standing, unattended review charters." in
  Cmd.group
    (Cmd.info "charter" ~doc ~docs ~exits:Cli_common.exits)
    [ add_cmd; list_cmd; fire_cmd; runs_cmd; status_cmd; remove_cmd ]
