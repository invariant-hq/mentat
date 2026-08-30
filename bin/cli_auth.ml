(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Runtime = Mentat_provider_runtime
module Provider = Mentat_provider
module Account = Provider.Account
module Auth = Provider.Auth
module Credential = Provider.Credential
module Argv = Mentat_boot.Argv
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Output = Mentat_boot.Output

let docs = Cli_common.s_config
let provider_of s = Mentat_llm.Provider.make s
let name_of = function None -> None | Some s -> Some (Credential.Name.make s)

let discovery_phase = function
  | Account.Discovery.Known account ->
      Account.Phase.to_string (Account.phase account)
  | Account.Discovery.Resolution_failed _ -> "resolution-failed"

let auth_satisfied t = function
  | Account.Discovery.Known account ->
      Account.connected account
      || Composition.provider_credential_optional t (Account.provider account)
  | Account.Discovery.Resolution_failed _ -> false

let render_resolution_error = function
  | Account.Discovery.Known _ -> ()
  | Account.Discovery.Resolution_failed { provider; error } ->
      Output.stderr_printf "%s: %s\n"
        (Mentat_llm.Provider.id provider)
        (Provider.Credential_error.message error)

let runtime_failure error =
  Runtime.Error.diagnostic error |> Exit_status.of_diagnostic

(* status. *)

let status json provider_opt cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Composition.discover_accounts t with
      | Error error -> runtime_failure (Runtime.Error.Store error)
      | Ok all -> (
          let render discoveries =
            if json then
              Output.stdout_printf "%s\n"
                (Output.Json.to_string
                   (Output.Json.envelope ~type_:"auth_status"
                      [
                        ( "providers",
                          Output.Json.list
                            (List.map
                               (fun discovery ->
                                 let fields =
                                   [
                                     ( "provider",
                                       Output.Json.string
                                         (Mentat_llm.Provider.id
                                            (Account.Discovery.provider
                                               discovery)) );
                                     ( "phase",
                                       Output.Json.string
                                         (discovery_phase discovery) );
                                     ( "connected",
                                       Output.Json.bool
                                         (Account.Discovery.connected discovery)
                                     );
                                   ]
                                 in
                                 let fields =
                                   match discovery with
                                   | Account.Discovery.Known _ -> fields
                                   | Account.Discovery.Resolution_failed
                                       { error; _ } ->
                                       fields
                                       @ [
                                           ( "error",
                                             Output.Json.string
                                               (Provider.Credential_error
                                                .message error) );
                                         ]
                                 in
                                 Output.Json.obj fields)
                               discoveries) );
                      ]))
            else (
              Output.print_table
                ~header:[ "PROVIDER"; "PHASE"; "CONNECTED" ]
                (List.map
                   (fun discovery ->
                     [
                       Mentat_llm.Provider.id
                         (Account.Discovery.provider discovery);
                       discovery_phase discovery;
                       (if Account.Discovery.connected discovery then "yes"
                        else "no");
                     ])
                   discoveries);
              List.iter render_resolution_error discoveries)
          in
          (* A named credential-optional route remains successful without changing
         its honest account phase from Missing. The all-provider view is always
         0; an unknown provider remains a usage error. *)
          match provider_opt with
          | None ->
              render all;
              Exit_status.Success
          | Some p -> (
              match
                Argv.provider ~known:(List.map Account.Discovery.provider all) p
              with
              | Error status -> status
              | Ok want ->
                  let discoveries =
                    List.filter
                      (fun discovery ->
                        Mentat_llm.Provider.equal
                          (Account.Discovery.provider discovery)
                          want)
                      all
                  in
                  render discoveries;
                  if
                    List.exists
                      (fun row -> not (auth_satisfied t row))
                      discoveries
                  then Exit_status.Failed
                  else Exit_status.Success)))

let provider_pos_opt =
  Arg.(
    value
    & pos 0 (some string) None
    & info [] ~docv:"PROVIDER" ~doc:"A provider id.")

let status_cmd =
  let doc = "Show provider authentication status." in
  Cmd.v
    (Cmd.info "status" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(const status $ Cli_common.json $ provider_pos_opt $ Cli_common.cwd))

(* credential entry helpers. *)

let read_stdin_trimmed () = String.trim (In_channel.input_all In_channel.stdin)

let read_hidden prompt =
  Output.stderr_printf "%s" prompt;
  let fd = Unix.stdin in
  let key =
    match Unix.tcgetattr fd with
    | exception Unix.Unix_error _ -> String.trim (input_line stdin)
    | attr ->
        Unix.tcsetattr fd Unix.TCSANOW { attr with Unix.c_echo = false };
        let line = try input_line stdin with End_of_file -> "" in
        Unix.tcsetattr fd Unix.TCSANOW attr;
        String.trim line
  in
  Output.stderr_printf "\n";
  key

let read_api_key ~api_key_stdin ~provider =
  let is_tty = try Unix.isatty Unix.stdin with Unix.Unix_error _ -> false in
  if api_key_stdin then
    if is_tty then Error "pipe the key on stdin with --api-key-stdin"
    else Ok (read_stdin_trimmed ())
  else if is_tty then
    Ok
      (read_hidden
         (Printf.sprintf "Enter your %s API key (input hidden): "
            (Mentat_llm.Provider.id provider)))
  else Error "reading an API key without a terminal requires --api-key-stdin"

(* login. *)

let saved_location t name_opt =
  let name = Option.value ~default:"default" name_opt in
  Printf.sprintf "%s (file store %s)" name
    (Mentat_boot.User_dirs.auth_file (Composition.dirs t))

(* The full settle block uses the exact account observation returned for
   the committed credential; it never reloads or reconstructs readiness. *)
let settle_account ~provider ~method_label ~saved account =
  Output.stdout_printf "Logged in to %s with %s.\n"
    (Mentat_llm.Provider.id provider)
    method_label;
  Output.stdout_printf "Saved: %s\n" saved;
  Output.stdout_printf "Checked: %s\n"
    (Account.Phase.to_string (Account.phase account));
  match Account.phase account with
  | Account.Phase.Blocked -> Exit_status.Failed
  | Account.Phase.Missing | Account.Phase.Unchecked | Account.Phase.Ready
  | Account.Phase.Degraded ->
      Output.stdout_printf
        "Next: run `mentat models list` to see available models.\n";
      Exit_status.Success

let login_progress (progress : Runtime.Login.Progress.t) =
  match progress with
  | Runtime.Login.Progress.Browser_url uri ->
      Output.stderr_printf "Go to: %s\n" (Uri.to_string uri)
  | Runtime.Login.Progress.Listening { redirect_uri } ->
      Output.stderr_printf "Listening on %s\n" (Uri.to_string redirect_uri)
  | Runtime.Login.Progress.Device_challenge { url; user_code; _ } ->
      Output.stderr_printf "Go to: %s\nEnter code: %s\n" (Uri.to_string url)
        user_code

let settle_login ~provider ~method_label ~saved = function
  | Error error -> runtime_failure error
  | Ok (Runtime.Login.Saved account) ->
      settle_account ~provider ~method_label ~saved account
  | Ok Runtime.Login.Cancelled -> Exit_status.runtime "login cancelled"

let resolve_method t provider ~method_opt ~api_key_stdin =
  match Provider.Catalog.declaration (Composition.catalog t) provider with
  | None ->
      Error
        (Printf.sprintf "unknown provider: %s"
           (Mentat_llm.Provider.id provider))
  | Some decl -> (
      let auth = Provider.auth decl in
      let logins = Auth.logins auth in
      let is_api_key login =
        match Auth.Login.protocol login with
        | Auth.Login.Protocol.Api_key -> true
        | _ -> false
      in
      (* Name the provider's actual methods so an unknown [--method] is a
         usage error with a did-you-mean. *)
      let unknown_method m =
        let available =
          List.map (fun l -> Auth.Login.Id.to_string (Auth.Login.id l)) logins
        in
        Error
          (Printf.sprintf "unknown login method: %s; available: %s" m
             (String.concat ", " available))
      in
      match method_opt with
      | Some m -> (
          match Auth.Login.Id.of_string m with
          | None -> unknown_method m
          | Some id -> (
              match Auth.login_by_id auth id with
              | Some login -> Ok login
              | None -> unknown_method m))
      | None -> (
          if api_key_stdin then
            match List.find_opt is_api_key logins with
            | Some login -> Ok login
            | None -> Error "this provider has no API-key login method"
          else
            match logins with
            | login :: _ -> Ok login
            | [] -> Error "this provider has no login methods"))

let login provider_str method_opt api_key_stdin name_opt cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let provider = provider_of provider_str in
      match resolve_method t provider ~method_opt ~api_key_stdin with
      | Error message -> Exit_status.usage message
      | Ok login ->
          let name = name_of name_opt in
          let is_api_key =
            match Auth.Login.protocol login with
            | Auth.Login.Protocol.Api_key -> true
            | _ -> false
          in
          if is_api_key then
            match read_api_key ~api_key_stdin ~provider with
            | Error message -> Exit_status.usage message
            | Ok "" -> Exit_status.usage "API key must not be empty"
            | Ok key -> (
                let saved =
                  Runtime.Login.save_api_key (Composition.runtime t)
                    ~sw:(Composition.sw t) ~env:(Composition.stdenv t) ~provider
                    ?name
                    ?base_url:(Composition.base_url_for t provider)
                    ?auth_base_url:(Composition.auth_base_url_for t provider)
                    ~key ()
                in
                match saved with
                | Error error -> runtime_failure error
                | Ok account ->
                    settle_account ~provider
                      ~method_label:
                        (Auth.Login.Id.to_string (Auth.Login.id login))
                      ~saved:(saved_location t name_opt)
                      account)
          else
            (* browser / device: a defaulted interactive method needs a terminal
               (baseline TTY guard). *)
            let is_tty =
              try Unix.isatty Unix.stdin with Unix.Unix_error _ -> false
            in
            if method_opt = None && (not api_key_stdin) && not is_tty then
              Exit_status.usage
                (Printf.sprintf
                   "auth login %s needs an explicit method without a terminal; \
                    use --method device-code or --method api-key \
                    --api-key-stdin"
                   provider_str)
            else
              let settled =
                Runtime.Login.run (Composition.runtime t) ~sw:(Composition.sw t)
                  ~env:(Composition.stdenv t) ~provider
                  ~method_id:(Auth.Login.id login) ?name
                  ?base_url:(Composition.base_url_for t provider)
                  ?auth_base_url:(Composition.auth_base_url_for t provider)
                  ~progress:login_progress ()
              in
              settle_login ~provider
                ~method_label:(Auth.Login.Id.to_string (Auth.Login.id login))
                ~saved:(saved_location t name_opt)
                settled)

let method_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "m"; "method" ] ~docv:"METHOD"
        ~doc:"Login method (browser, device-code, api-key).")

let api_key_stdin =
  Arg.(
    value & flag & info [ "api-key-stdin" ] ~doc:"Read an API key from stdin.")

let name_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "name" ] ~docv:"NAME" ~doc:"Credential name (default: default).")

let provider_req =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"PROVIDER" ~doc:"A provider id.")

let login_cmd =
  let doc = "Log in to a provider." in
  Cmd.v
    (Cmd.info "login" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const login $ provider_req $ method_opt $ api_key_stdin $ name_opt
         $ Cli_common.cwd))

(* save. — the non-interactive api-key persist. *)

let save provider_str api_key_stdin name_opt cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let provider = provider_of provider_str in
      match read_api_key ~api_key_stdin ~provider with
      | Error message -> Exit_status.usage message
      | Ok "" -> Exit_status.usage "API key must not be empty"
      | Ok key -> (
          let saved =
            Runtime.Login.save_api_key (Composition.runtime t)
              ~sw:(Composition.sw t) ~env:(Composition.stdenv t) ~provider
              ?name:(name_of name_opt)
              ?base_url:(Composition.base_url_for t provider)
              ?auth_base_url:(Composition.auth_base_url_for t provider)
              ~key ()
          in
          match saved with
          | Error error -> runtime_failure error
          | Ok account ->
              settle_account ~provider ~method_label:"api-key"
                ~saved:(saved_location t name_opt)
                account))

let save_cmd =
  let doc = "Save a provider API key (non-interactive)." in
  Cmd.v
    (Cmd.info "save" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const save $ provider_req $ api_key_stdin $ name_opt $ Cli_common.cwd))

(* logout / remove. *)

let render_current_discovery = function
  | Account.Discovery.Known account -> (
      match Account.source account with
      | None -> Output.stdout_printf "Current credential source: none.\n"
      | Some source ->
          Output.stdout_printf "Current credential source: %s.\n"
            (Format.asprintf "%a" Credential.Source.pp source))
  | Account.Discovery.Resolution_failed { provider; error } ->
      Output.stderr_printf
        "Current credential source for %s could not be resolved: %s\n"
        (Mentat_llm.Provider.id provider)
        (Provider.Credential_error.message error)

let render_local_settlement ~provider ~name_opt = function
  | Account.Logout.Removed ->
      Output.stdout_printf "Removed %s credential %s.\n"
        (Mentat_llm.Provider.id provider)
        (Option.value ~default:"default" name_opt)
  | Account.Logout.Superseded ->
      Output.stdout_printf
        "Kept replacement %s credential %s written during revocation.\n"
        (Mentat_llm.Provider.id provider)
        (Option.value ~default:"default" name_opt)

let render_remote_settlement = function
  | Account.Logout.Revoked ->
      Output.stdout_printf "Remote revocation succeeded.\n"
  | Account.Logout.Unsupported ->
      Output.stdout_printf
        "The stored credential does not support provider revocation.\n"
  | Account.Logout.Failed problem ->
      Output.stderr_printf "mentat: warning: remote revocation failed (%s).\n"
        (Account.Problem.to_string problem)

let render_logout ~provider ~name_opt (settlement : Account.Logout.t) =
  (match settlement.Account.Logout.revocation with
  | None ->
      Output.stdout_printf "Logged out of %s.\n"
        (Mentat_llm.Provider.id provider)
  | Some Account.Logout.Not_stored ->
      Output.stdout_printf
        "No stored credential was available for revocation.\n"
  | Some (Account.Logout.Settled { remote; local }) ->
      render_remote_settlement remote;
      render_local_settlement ~provider ~name_opt local);
  render_current_discovery settlement.Account.Logout.current;
  Exit_status.Success

let do_logout revoke provider_str name_opt cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      let known =
        Provider.Catalog.declarations (Composition.catalog t)
        |> List.map Provider.id
      in
      match Argv.provider ~known provider_str with
      | Error status -> status
      | Ok provider -> (
          match
            Runtime.Login.logout (Composition.runtime t) ~sw:(Composition.sw t)
              ~env:(Composition.stdenv t) ~provider ?name:(name_of name_opt)
              ~revoke
              ?auth_base_url:(Composition.auth_base_url_for t provider)
              ~environment:(Composition.environment t)
              ()
          with
          | Error error -> runtime_failure error
          | Ok settlement -> render_logout ~provider ~name_opt settlement))

let revoke_flag =
  Arg.(
    value & flag
    & info [ "revoke" ]
        ~doc:"Revoke the credential with the provider before removing it.")

let logout_cmd =
  let doc = "Log out of a provider." in
  Cmd.v
    (Cmd.info "logout" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const do_logout $ revoke_flag $ provider_req $ name_opt
         $ Cli_common.cwd))

let remove_cmd =
  let doc = "Remove a stored provider credential." in
  Cmd.v
    (Cmd.info "remove" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const (fun p n c -> do_logout false p n c)
         $ provider_req $ name_opt $ Cli_common.cwd))

let cmd =
  let doc = "Manage provider credentials." in
  Cmd.group
    (Cmd.info "auth" ~doc ~docs ~exits:Cli_common.exits)
    [ status_cmd; login_cmd; save_cmd; logout_cmd; remove_cmd ]
