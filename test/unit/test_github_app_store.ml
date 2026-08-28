(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Github_app_store] — the owner-level credential home:
   atomic write, custody refusals, the half-home refusal, on-demand secret
   reads, and rotation. The module lives in [bin/boot] and is not
   library-linkable, so its source rides the [copy_files] rules in [dune]. *)

open Windtrap

let temp_root () = Filename.temp_dir "mentat-test-github-app-store" ""

let make_dirs root =
  let env =
    [
      ("MENTAT_CONFIG_HOME", Filename.concat root "config");
      ("MENTAT_DATA_HOME", Filename.concat root "data");
      ("MENTAT_STATE_HOME", Filename.concat root "state");
      ("MENTAT_CACHE_HOME", Filename.concat root "cache");
    ]
  in
  match User_dirs.resolve ~getenv:(fun k -> List.assoc_opt k env) with
  | Ok dirs -> dirs
  | Error message -> failf "resolve: %s" message

let app ~api_base =
  {
    Github_app_store.dir = "";
    app_id = 12345;
    slug = "mentat-review-a3f9";
    name = "mentat-review-a3f9";
    client_id = "Iv1.abcdef1234567890";
    html_url = "https://github.com/apps/mentat-review-a3f9";
    api_base;
    created_at = "2026-08-28T00:00:00Z";
  }

let write dirs ?public_url () =
  match
    Github_app_store.write dirs
      ~app:(app ~api_base:"https://api.github.com")
      ~key_pem:"PEM BYTES\n" ~webhook_secret:"whs-secret" ~ingress_id:"aa11"
      ~public_url
  with
  | Ok app -> app
  | Error e -> failf "write: %s" (Github_app_store.Error.message e)

let ok ~msg = function
  | Ok value -> value
  | Error e -> failf "%s: %s" msg (Github_app_store.Error.message e)

let contains text needle =
  let length = String.length needle in
  let rec go index =
    if index + length > String.length text then false
    else if String.equal (String.sub text index length) needle then true
    else go (index + 1)
  in
  go 0

let err ~msg ~holds = function
  | Ok _ -> failf "%s: unexpectedly succeeded" msg
  | Error e ->
      let text = Github_app_store.Error.message e in
      is_true ~msg:(Printf.sprintf "%s (got: %s)" msg text)
        (List.for_all (contains text) holds)

let roundtrip () =
  let dirs = make_dirs (temp_root ()) in
  (match Github_app_store.load dirs with
  | Ok None -> ()
  | Ok (Some _) -> fail "an absent home must load as None"
  | Error e -> failf "absent home: %s" (Github_app_store.Error.message e));
  let written = write dirs () in
  is_true ~msg:"the home directory is owner-only"
    ((Unix.stat written.Github_app_store.dir).Unix.st_perm land 0o077 = 0);
  match ok ~msg:"load" (Github_app_store.load dirs) with
  | None -> fail "a written home must load"
  | Some loaded ->
      equal int ~msg:"the app id survives" 12345 loaded.Github_app_store.app_id;
      equal string ~msg:"the posting identity is the slug's bot login"
        "mentat-review-a3f9[bot]"
        (Github_app_store.posting_login loaded);
      equal string ~msg:"the install page derives from the html url"
        "https://github.com/apps/mentat-review-a3f9/installations/new"
        (Github_app_store.install_url loaded);
      equal string ~msg:"the key is re-read on demand" "PEM BYTES\n"
        (ok ~msg:"key" (Github_app_store.read_key_pem loaded));
      equal string ~msg:"the webhook secret reads trimmed" "whs-secret"
        (ok ~msg:"secret" (Github_app_store.webhook_secret loaded));
      equal string ~msg:"the ingress id reads trimmed" "aa11"
        (ok ~msg:"ingress" (Github_app_store.ingress_id loaded));
      equal (option string) ~msg:"no public url until repoint" None
        (ok ~msg:"url" (Github_app_store.public_url loaded));
      (* Re-running setup replaces the home whole. *)
      let replaced = write dirs ~public_url:"https://hooks.example.com" () in
      equal (option string) ~msg:"the replacement carries its public url"
        (Some "https://hooks.example.com")
        (ok ~msg:"url" (Github_app_store.public_url replaced));
      (* repoint's local half. *)
      ok ~msg:"write url"
        (Github_app_store.write_public_url replaced "https://h2.example.com");
      equal (option string) ~msg:"the public url is replaced"
        (Some "https://h2.example.com")
        (ok ~msg:"url" (Github_app_store.public_url replaced));
      (* Rotation mints a fresh 256-bit secret and writes it atomically. *)
      let fresh =
        ok ~msg:"rotate" (Github_app_store.rotate_webhook_secret replaced)
      in
      equal int ~msg:"the fresh secret is 64 hex" 64 (String.length fresh);
      equal string ~msg:"the store answers the fresh secret" fresh
        (ok ~msg:"secret" (Github_app_store.webhook_secret replaced))

let custody () =
  let dirs = make_dirs (temp_root ()) in
  let written = write dirs () in
  let dir = written.Github_app_store.dir in
  Unix.chmod dir 0o750;
  err ~msg:"a group-accessible home is refused whole" ~holds:[ "github app load" ]
    (Github_app_store.load dirs);
  Unix.chmod dir 0o700;
  let key = Filename.concat dir "private-key.pem" in
  Unix.chmod key 0o640;
  err ~msg:"a loose key file is refused" ~holds:[ "private-key.pem" ]
    (Github_app_store.load dirs);
  Unix.chmod key 0o600;
  (match Github_app_store.load dirs with
  | Ok (Some _) -> ()
  | Ok None | Error _ -> fail "restored custody must load again");
  (* A6: a half-present home is refused whole, whichever half is missing. *)
  Sys.remove key;
  err ~msg:"a home missing its key is refused whole"
    ~holds:[ "incomplete"; "private-key.pem" ]
    (Github_app_store.load dirs);
  let rewritten = write dirs () in
  Sys.remove (Filename.concat rewritten.Github_app_store.dir "app.json");
  err ~msg:"a home missing app.json is refused whole"
    ~holds:[ "incomplete"; "app.json" ]
    (Github_app_store.load dirs)

let strict_app_json () =
  let dirs = make_dirs (temp_root ()) in
  let written = write dirs () in
  let path = Filename.concat written.Github_app_store.dir "app.json" in
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc
        {|{"github_app":1,"id":1,"slug":"s","name":"n","client_id":"c","html_url":"h","api_base":"b","created_at":"t","surprise":true}|});
  err ~msg:"an unknown member refuses the load" ~holds:[ "surprise" ]
    (Github_app_store.load dirs);
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc {|{"github_app":2}|});
  err ~msg:"a foreign version refuses the load" ~holds:[ "github_app" ]
    (Github_app_store.load dirs)

let tokens () =
  let token = Github_app_store.fresh_token () in
  equal int ~msg:"a fresh token is 32 hex" 32 (String.length token);
  is_true ~msg:"lowercase hexadecimal"
    (String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       token);
  equal int ~msg:"a fresh webhook secret is 64 hex" 64
    (String.length (Github_app_store.fresh_webhook_secret ()))

let () =
  run "mentat.github_app_store"
    [
      test "write, load, rotate" roundtrip;
      test "custody and the half-home refusal" custody;
      test "strict app.json" strict_app_json;
      test "fresh tokens" tokens;
    ]
