(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
open Mentat_github

let ( let* ) = Result.bind

(* The manifest's product-page member — GitHub shows it on the App's page. *)
let homepage = "https://github.com/invariant-hq/mentat"
let default_port = 8917
let default_api_base = "https://api.github.com"

let resolve_dirs () =
  match User_dirs.resolve ~getenv:Sys.getenv_opt with
  | Ok dirs -> Ok dirs
  | Error message -> Error (Exit_status.runtime message)

let store_error e = Exit_status.runtime (Github_app_store.Error.message e)

let require_app dirs =
  match Github_app_store.load dirs with
  | Error e -> Error (store_error e)
  | Ok (Some app) -> Ok app
  | Ok None ->
      Error
        (Exit_status.runtime
           "no GitHub App is set up; run `mentatd github setup` first")

let now_rfc3339 () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let http_url url =
  String.starts_with ~prefix:"https://" url
  || String.starts_with ~prefix:"http://" url

(* Best-effort browser launch; the URL is printed regardless, and a box with
   no browser is served by copying the finished credential home over —
   provisioning is files. *)
let open_browser url =
  let candidates =
    if Sys.win32 then
      [ ("rundll32.exe", [| "rundll32.exe"; "url.dll,FileProtocolHandler"; url |]) ]
    else
      (if Sys.file_exists "/usr/bin/open" then
         [ ("/usr/bin/open", [| "/usr/bin/open"; url |]) ]
       else [])
      @ [ ("xdg-open", [| "xdg-open"; url |]) ]
  in
  match Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 with
  | exception Unix.Unix_error _ -> ()
  | null ->
      Fun.protect
        ~finally:(fun () -> Unix.close null)
        (fun () ->
          ignore
            (List.exists
               (fun (program, argv) ->
                 match Unix.create_process program argv null null null with
                 | _ -> true
                 | exception Unix.Unix_error _ -> false)
               candidates))

(* A JWT-authenticated client over the base the App was created against —
   the stored base is the truth, so the doctor and the hook verbs take no
   base flag of their own. *)
let jwt_api ~net (app : Github_app_store.t) =
  let* key_pem =
    Result.map_error Github_app_store.Error.message
      (Github_app_store.read_key_pem app)
  in
  let* jwt =
    Github_app.Jwt.make ~issuer:app.Github_app_store.client_id ~key_pem
      ~now:(Unix.gettimeofday ())
  in
  Result.map_error Github_api.Error.message
    (Github_api.make ~base_url:app.Github_app_store.api_base ~token:jwt net)

(* The derived hook target — GitHub's hook config is a projection of the
   credential home's files (A8), so every writer derives the complete
   config from them. *)
let derived_hook_url (app : Github_app_store.t) =
  let* ingress_id =
    Result.map_error Github_app_store.Error.message
      (Github_app_store.ingress_id app)
  in
  let* public_url =
    Result.map_error Github_app_store.Error.message
      (Github_app_store.public_url app)
  in
  Ok (Github_app.Manifest.hook_url ~public_url ~ingress_id)

let upsert_hook ~net (app : Github_app_store.t) =
  let* api = jwt_api ~net app in
  let* url = derived_hook_url app in
  let* secret =
    Result.map_error Github_app_store.Error.message
      (Github_app_store.webhook_secret app)
  in
  let* () = Github_app.Hook.upsert api ~url ~secret in
  Ok url

(* setup *)

let setup port org public_url github_base_url =
  (let* dirs = resolve_dirs () in
   let* () =
     match public_url with
     | Some url when not (http_url url) ->
         Error
           (Exit_status.usage
              (Printf.sprintf "--public-url must be an http(s) URL, got %s" url))
     | Some _ | None -> Ok ()
   in
   let api_base = Option.value github_base_url ~default:default_api_base in
   let state = Github_app_store.fresh_token () in
   let ingress_id = Github_app_store.fresh_token () in
   let name =
     Github_app.Manifest.app_name
       ~suffix:(String.sub (Github_app_store.fresh_token ()) 0 4)
   in
   let redirect_url = Printf.sprintf "http://127.0.0.1:%d/callback" port in
   let hook_url = Github_app.Manifest.hook_url ~public_url ~ingress_id in
   let manifest =
     Github_app.Manifest.json ~name ~homepage ~redirect_url ~hook_url
   in
   let create_url =
     Github_app.Manifest.create_url
       ~web_base:(Github_app.Manifest.web_base ~api_base)
       ~org ~state
   in
   let entry_page = Github_app.Manifest.entry_page ~create_url ~manifest in
   let entry_url = Printf.sprintf "http://127.0.0.1:%d/" port in
   Eio_main.run @@ fun stdenv ->
   let accept callback =
     Option.equal String.equal (Uri.get_query_param callback "state")
       (Some state)
     && (match Uri.get_query_param callback "code" with
        | Some code -> not (String.equal code "")
        | None -> false)
   in
   let serve ~path =
     if String.equal path "/" then Some entry_page else None
   in
   Output.stdout_printf
     "Opening GitHub to create your App (or open this yourself):\n  %s\n"
     entry_url;
   Output.stdout_printf "Waiting for GitHub's redirect on 127.0.0.1:%d ...\n"
     port;
   let awaited =
     Mentat_provider_runtime.Loopback.await_once ~stdenv ~provider:"GitHub"
       ~on_ready:(fun () -> open_browser entry_url)
       ~accept ~serve
       ~redirect_uri:(Uri.of_string redirect_url)
       ~timeout_s:600. ()
   in
   match awaited with
   | Error message -> Ok (Exit_status.runtime message)
   | Ok callback -> (
       let code = Option.value (Uri.get_query_param callback "code") ~default:"" in
       let exchanged =
         let* api =
           Result.map_error Github_api.Error.message
             (Github_api.make ~base_url:api_base (Eio.Stdenv.net stdenv))
         in
         Github_app.Conversion.exchange api ~code
       in
       match exchanged with
       | Error message ->
           Ok (Exit_status.runtime (Printf.sprintf "conversion: %s" message))
       | Ok conversion -> (
           match conversion.Github_app.Conversion.webhook_secret with
           | None ->
               (* Checked live: whether GitHub ever omits the secret when
                  the hook target is a placeholder. Refusing keeps A6 whole
                  — a home without its HMAC key could never verify a
                  delivery. *)
               Ok
                 (Exit_status.runtime
                    "GitHub returned no webhook secret with the conversion; \
                     the App was created but no credentials were stored — \
                     delete it from its GitHub settings page and re-run \
                     `mentatd github setup`")
           | Some webhook_secret -> (
               let app =
                 {
                   Github_app_store.dir = "";
                   app_id = conversion.Github_app.Conversion.app_id;
                   slug = conversion.Github_app.Conversion.slug;
                   name = conversion.Github_app.Conversion.name;
                   client_id = conversion.Github_app.Conversion.client_id;
                   html_url = conversion.Github_app.Conversion.html_url;
                   api_base;
                   created_at = now_rfc3339 ();
                 }
               in
               match
                 Github_app_store.write dirs ~app
                   ~key_pem:conversion.Github_app.Conversion.pem
                   ~webhook_secret ~ingress_id ~public_url
               with
               | Error e -> Ok (store_error e)
               | Ok app ->
                   Output.stdout_printf
                     "Created GitHub App %S (app id %d).\n"
                     app.Github_app_store.name app.Github_app_store.app_id;
                   Output.stdout_printf
                     "  credentials: %s (owner-only files)\n"
                     app.Github_app_store.dir;
                   Output.stdout_printf "  reviews will post as %s\n"
                     (Github_app_store.posting_login app);
                   Output.stdout_printf
                     "Install it on the repositories your routines watch:\n\
                     \  %s\n"
                     (Github_app_store.install_url app);
                   (match public_url with
                   | Some _ ->
                       Output.stdout_printf "Webhook: %s\n"
                         (Github_app.Manifest.hook_url ~public_url ~ingress_id)
                   | None ->
                       Output.stdout_printf
                         "Webhook: not routed yet — deliveries start after\n\
                         \  `mentatd github repoint <public-url>`; the cron \
                          sweep needs no webhook.\n");
                   Ok Exit_status.Success))))
  |> Exit_status.of_result

(* status — the doctor: the local half needs no network; the network half
   proves the App exists, the key signs, the hook config matches local
   files, and the installations cover the App routines. Exit 0 all green. *)

(* The roster's printable half: loadable routines, with each broken one
   printed and counted — a routine that fails to load is a doctor-red fact,
   exactly as the dashboard treats it. *)
let routine_rows dirs =
  match Routine_store.roster dirs with
  | Error e ->
      Output.stdout_printf "routines: %s\n" (Routine_store.Error.message e);
      ([], 1)
  | Ok entries ->
      let broken =
        List.fold_left
          (fun broken (name, result) ->
            match result with
            | Error e ->
                Output.stdout_printf "%s: %s\n" name
                  (Routine_store.Error.message e);
                broken + 1
            | Ok _ -> broken)
          0 entries
      in
      (List.filter_map (fun (_, result) -> Result.to_option result) entries,
       broken)

let status () =
  (let* dirs = resolve_dirs () in
   match Github_app_store.load dirs with
   | Error e -> Error (store_error e)
   | Ok None ->
       Output.stdout_printf "app: not set up; run `mentatd github setup`\n";
       let loadeds, _broken = routine_rows dirs in
       List.iter
         (fun (loaded : Routine_store.Loaded.t) ->
           Output.stdout_printf "%s  %s  %s\n"
             loaded.Routine_store.Loaded.name
             loaded.Routine_store.Loaded.routine.Mentat_routine.Routine.repo
             (if Routine_store.pat_files_present loaded then "pat" else "none"))
         loadeds;
       Ok Exit_status.Failed
   | Ok (Some app) ->
       Ok
         ( Eio_main.run @@ fun stdenv ->
           let net = Eio.Stdenv.net stdenv in
           let green = ref true in
           let flag line =
             green := false;
             Output.stdout_printf "%s\n" line
           in
           (match jwt_api ~net app with
           | Error message ->
               flag
                 (Printf.sprintf "app: %s (id %d) unreachable: %s"
                    app.Github_app_store.name app.Github_app_store.app_id
                    message)
           | Ok api -> (
               (match Github_app.Doctor.app_identity api with
               | Ok (slug, name) ->
                   Output.stdout_printf
                     "app: %s (id %d) reachable; posts as %s[bot]\n" name
                     app.Github_app_store.app_id slug
               | Error message ->
                   flag
                     (Printf.sprintf "app: %s (id %d) unreachable: %s"
                        app.Github_app_store.name app.Github_app_store.app_id
                        message));
               (match (Github_app.Hook.current_url api, derived_hook_url app) with
               | Ok live, Ok derived when String.equal live derived ->
                   if
                     String.starts_with ~prefix:"https://unrouted.invalid/"
                       live
                   then
                     Output.stdout_printf
                       "webhook: unrouted (placeholder); deliveries start \
                        after `mentatd github repoint <public-url>`\n"
                   else Output.stdout_printf "webhook: %s current\n" live
               | Ok live, Ok derived ->
                   flag
                     (Printf.sprintf
                        "webhook: %s differs from local files (expected %s); \
                         run `mentatd github repoint` or `mentatd github \
                         rotate-secret` to converge"
                        live derived)
               | Error message, _ | _, Error message ->
                   flag (Printf.sprintf "webhook: %s" message));
               (match Github_app.Doctor.installations api with
               | Ok rows ->
                   Output.stdout_printf "installations: %d\n" (List.length rows)
               | Error message ->
                   flag (Printf.sprintf "installations: %s" message));
               let loadeds, broken = routine_rows dirs in
               if broken > 0 then green := false;
               List.iter
                 (fun (loaded : Routine_store.Loaded.t) ->
                   let name = loaded.Routine_store.Loaded.name in
                   let repo =
                     loaded.Routine_store.Loaded.routine
                       .Mentat_routine.Routine.repo
                   in
                   if Routine_store.pat_files_present loaded then
                     Output.stdout_printf "%s  %s  pat\n" name repo
                   else
                     match Github_app.Mint.installation_id api ~repo with
                     | Ok id ->
                         Output.stdout_printf
                           "%s  %s  app  installation %d ok\n" name repo id
                     | Error `No_installation ->
                         flag
                           (Printf.sprintf
                              "%s  %s  app  not installed; install it: %s"
                              name repo (Github_app_store.install_url app))
                     | Error (`Error message) ->
                         flag
                           (Printf.sprintf "%s  %s  app  %s" name repo
                              message))
                 loadeds));
           if !green then Exit_status.Success else Exit_status.Failed ))
  |> Exit_status.of_result

(* repoint *)

let repoint url =
  (let* dirs = resolve_dirs () in
   let* () =
     if http_url url then Ok ()
     else
       Error
         (Exit_status.usage
            (Printf.sprintf "PUBLIC-URL must be an http(s) URL, got %s" url))
   in
   let* app = require_app dirs in
   (* Local truth durable first; the upsert is a projection of it. *)
   let* () =
     Result.map_error store_error (Github_app_store.write_public_url app url)
   in
   Ok
     ( Eio_main.run @@ fun stdenv ->
       match upsert_hook ~net:(Eio.Stdenv.net stdenv) app with
       | Ok hook ->
           Output.stdout_printf "webhook now targets %s\n" hook;
           Exit_status.Success
       | Error message ->
           Exit_status.runtime
             (Printf.sprintf
                "%s\nthe public URL is recorded locally; GitHub still holds \
                 the old hook config — re-run `mentatd github repoint %s`"
                message url) ))
  |> Exit_status.of_result

(* rotate-secret *)

let rotate_secret () =
  (let* dirs = resolve_dirs () in
   let* app = require_app dirs in
   (* Local truth durable first: the fresh secret is on disk before GitHub
      hears of it, and re-running converges because the upsert is total. *)
   let* _fresh =
     Result.map_error store_error (Github_app_store.rotate_webhook_secret app)
   in
   Ok
     ( Eio_main.run @@ fun stdenv ->
       match upsert_hook ~net:(Eio.Stdenv.net stdenv) app with
       | Ok _ ->
           Output.stdout_printf
             "rotated the App webhook secret; GitHub's hook now signs with \
              it\n";
           Exit_status.Success
       | Error message ->
           Exit_status.runtime
             (Printf.sprintf
                "%s\nthe fresh secret is written locally; GitHub still signs \
                 with the old one — re-run `mentatd github rotate-secret`"
                message) ))
  |> Exit_status.of_result

(* command assembly *)

let port_opt =
  let doc =
    "Bind the one-shot loopback listener on 127.0.0.1:$(docv). The port \
     must be known before the manifest is rendered — the manifest carries \
     the redirect URL — so an ephemeral port cannot serve here."
  in
  Arg.(value & opt int default_port & info [ "port" ] ~docv:"PORT" ~doc)

let org_opt =
  let doc =
    "Create the App under the organization $(docv) instead of your user \
     account (the browser opens the organization's create page; SSO and \
     org policy are yours to navigate on GitHub)."
  in
  Arg.(value & opt (some string) None & info [ "org" ] ~docv:"ORG" ~doc)

let public_url_opt =
  let doc =
    "The public base URL a tunnel already exposes; the App's webhook is \
     born targeting $(docv)/ingress/github/<id>. Without it the webhook \
     targets an unroutable placeholder until `mentatd github repoint`."
  in
  Arg.(value & opt (some string) None & info [ "public-url" ] ~docv:"URL" ~doc)

let github_base_url_opt =
  let doc =
    "The GitHub API base the App is created against — for GitHub \
     Enterprise hosts. The base is recorded in the credential home, and a \
     fire or node configured for a different base refuses the App loudly."
  in
  Arg.(
    value
    & opt (some string) None
    & info [ "github-base-url" ] ~docv:"URL" ~doc)

let setup_cmd =
  let doc = "Create your own GitHub App; routines authenticate through it." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Drives GitHub's app-manifest flow: the browser opens on GitHub's \
         pre-filled create page — a generated name you can edit in place, \
         the three permissions (Contents: read, Pull requests: write, \
         Metadata: read), the pull_request event — and one click creates \
         the App. GitHub redirects to a one-shot loopback listener with a \
         conversion code; the exchange returns the App's identity, private \
         key, and webhook secret, written atomically to the owner-level \
         credential home ($(b,~/.config/mentat/github-app), owner-only \
         files). The client secret GitHub also returns is deliberately \
         discarded — nothing here performs user OAuth, and an unused \
         credential on disk is pure liability.";
      `P
        "From then on every routine with no PAT files authenticates as the \
         App: short-lived installation tokens minted per fire, reviews \
         posted as <name>[bot], and one App-level webhook covering every \
         installed repository. Routines with PAT files keep the token \
         journey unchanged.";
      `P
        "On a box with no browser, run setup where one lives and copy the \
         credential home over — provisioning is files. There is no \
         $(b,github remove): removal is deleting the credential home \
         directory, and the App itself is deleted from its GitHub settings \
         page.";
    ]
  in
  Cmd.v
    (Cmd.info "setup" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term
       Term.(
         const setup $ port_opt $ org_opt $ public_url_opt
         $ github_base_url_opt))

let status_cmd =
  let doc = "Check the App end to end: credentials, hook, installations." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "The pre-flight doctor. Locally: the credential home is present, \
         complete, and private, and every routine's auth mode is named. \
         Over the network, under a fresh app JWT: the App still exists and \
         the stored key still signs (GET /app), the live hook config \
         matches what the local files derive, and each App routine's \
         repository is covered by an installation — with the install page \
         URL printed when one is not. Exit 0 when everything is green, 1 \
         otherwise. GitHub never returns the hook's secret, so a secret \
         edited by hand in GitHub's UI is invisible here — it surfaces as \
         signature rejections on the ingress, and `mentatd github \
         rotate-secret` is the repair.";
    ]
  in
  Cmd.v
    (Cmd.info "status" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const status $ const ()))

let public_url_arg =
  let doc = "The public base URL your tunnel exposes." in
  Arg.(
    required & pos 0 (some string) None & info [] ~docv:"PUBLIC-URL" ~doc)

let repoint_cmd =
  let doc = "Point the App's one webhook at a public URL." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Records $(i,PUBLIC-URL) in the credential home, then upserts \
         GitHub's hook config whole — URL derived from the recorded base \
         and the App's ingress id, secret from the stored webhook secret. \
         Local truth is written first: if the GitHub update fails, re-run \
         the verb and it converges, because the upsert is total. One verb \
         re-points deliveries for every installed repository — there is \
         nothing to update per repository.";
    ]
  in
  Cmd.v
    (Cmd.info "repoint" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const repoint $ public_url_arg))

let rotate_secret_cmd =
  let doc = "Re-mint the App's webhook HMAC secret; the URL never moves." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Mints a fresh 256-bit secret, writes it to the credential home, \
         then upserts GitHub's hook config whole. The old secret stops \
         verifying the moment the local write lands; deliveries signed \
         with it answer 401 until the upsert completes, and the reconcile \
         sweep covers whatever the gap misses. If the GitHub update fails, \
         local truth is ahead — re-run the verb to converge.";
      `P
        "This is the owner-level rotation for App-mode routines. A PAT \
         routine's per-repository webhook secret rotates with \
         $(b,mentatd routine rotate-secret) instead.";
    ]
  in
  Cmd.v
    (Cmd.info "rotate-secret" ~doc ~man ~exits:Exit_status.exits)
    (Exit_status.term Term.(const rotate_secret $ const ()))

let cmd =
  let doc = "Own the GitHub App your routines authenticate through." in
  Cmd.group
    (Cmd.info "github" ~doc ~exits:Exit_status.exits)
    [ setup_cmd; status_cmd; repoint_cmd; rotate_secret_cmd ]
