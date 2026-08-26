(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Charter_store] — install, load, roster, the ingress index,
   and the durable record (claim markers and the receipt log). The module
   lives in [bin/boot] and is not library-linkable, so its source is copied
   into this test executable by the [copy_files] rules in [dune]. *)

open Windtrap
open Mentat_charter

let temp_root () = Filename.temp_dir "mentat-test-charter-store" ""

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

let write_file path bytes =
  (match Fs.mkdir_p (Filename.dirname path) with
  | Ok () -> ()
  | Error message -> failf "mkdir_p: %s" message);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc bytes)

let webhook_json ~name =
  Printf.sprintf
    {|{ "charter": 1, "name": %S,
  "workspace": { "repo": "acme/widgets" },
  "trigger": [
    { "kind": "github_webhook", "events": ["pull_request.opened"] },
    { "kind": "cli" } ],
  "run": { "mode": "review", "prompt": "prompt.md",
           "output_schema": "schema.json" },
  "budget": { "per_run": { "wall_clock": "15m" },
              "per_charter": { "usd_per_day": 10.0 } },
  "publish": { "github": "review-threads" } }|}
    name

let cli_json ~name =
  Printf.sprintf
    {|{ "charter": 1, "name": %S,
  "workspace": { "repo": "acme/widgets" },
  "trigger": [ { "kind": "cli" } ],
  "run": { "mode": "review", "prompt": "prompt.md",
           "output_schema": "schema.json" },
  "budget": { "per_run": { "wall_clock": "15m" } },
  "publish": { "github": "review-threads" } }|}
    name

let proposal root ~name json =
  let dir = Filename.concat root ("proposal-" ^ name) in
  write_file (Filename.concat dir "charter.json") json;
  write_file (Filename.concat dir "prompt.md") "Review the diff.\n";
  write_file (Filename.concat dir "schema.json") {|{"type":"object"}|};
  dir

let ok ~msg = function
  | Ok value -> value
  | Error e -> failf "%s: %s" msg (Charter_store.Error.message e)

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
      let text = Charter_store.Error.message e in
      is_true ~msg:(Printf.sprintf "%s (got: %s)" msg text)
        (List.for_all (contains text) holds)

let is_hex ~length s =
  String.length s = length
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       s

let install_and_reinstall () =
  let root = temp_root () in
  let dirs = make_dirs root in
  let src = proposal root ~name:"hook" (webhook_json ~name:"hook") in
  let installed = ok ~msg:"install" (Charter_store.install dirs ~src) in
  let loaded = installed.Charter_store.Installed.loaded in
  is_true ~msg:"the policy digest is 16 hex"
    (is_hex ~length:16 loaded.Charter_store.Loaded.digest);
  let webhook =
    match installed.Charter_store.Installed.webhook with
    | Some webhook -> webhook
    | None -> fail "a webhook charter must carry a webhook outcome"
  in
  is_true ~msg:"the ingress id is a 32-hex token"
    (is_hex ~length:32 webhook.Charter_store.Installed.id);
  is_true ~msg:"the first install mints both"
    (webhook.Charter_store.Installed.id_minted
    && webhook.Charter_store.Installed.secret_minted);
  is_true ~msg:"the loaded charter carries its ingress id"
    (match loaded.Charter_store.Loaded.ingress_id with
    | Some id -> String.equal id webhook.Charter_store.Installed.id
    | None -> false);
  let secret_path =
    Filename.concat
      (Filename.concat loaded.Charter_store.Loaded.dir "secrets")
      "webhook"
  in
  is_true ~msg:"the minted secret is owner-only"
    ((Unix.stat secret_path).Unix.st_perm land 0o077 = 0);
  (* Re-installing replaces policy and keeps identity: owner edits never move
     the webhook URL. *)
  let again = ok ~msg:"re-install" (Charter_store.install dirs ~src) in
  (match again.Charter_store.Installed.webhook with
  | Some w ->
      is_true ~msg:"the second install mints nothing"
        ((not w.Charter_store.Installed.id_minted)
        && not w.Charter_store.Installed.secret_minted);
      equal string ~msg:"the ingress id is stable"
        webhook.Charter_store.Installed.id w.Charter_store.Installed.id
  | None -> fail "the re-install lost the webhook outcome");
  (* A cli-only charter mints no webhook identity. *)
  let cli_src = proposal root ~name:"clionly" (cli_json ~name:"clionly") in
  let cli = ok ~msg:"cli install" (Charter_store.install dirs ~src:cli_src) in
  is_true ~msg:"a cli charter has no webhook outcome"
    (Option.is_none cli.Charter_store.Installed.webhook)

let install_refusals () =
  let root = temp_root () in
  let dirs = make_dirs root in
  (* Secrets never ride a proposal. *)
  let with_secrets = proposal root ~name:"s" (webhook_json ~name:"s") in
  write_file
    (Filename.concat (Filename.concat with_secrets "secrets") "webhook")
    "leak\n";
  err ~msg:"a proposal carrying secrets/ is refused" ~holds:[ "secrets" ]
    (Charter_store.install dirs ~src:with_secrets);
  (* A webhook identity is minted, never imported. *)
  let with_id = proposal root ~name:"i" (webhook_json ~name:"i") in
  write_file (Filename.concat with_id "ingress.id") "beef\n";
  err ~msg:"a proposal carrying ingress.id is refused" ~holds:[ "ingress.id" ]
    (Charter_store.install dirs ~src:with_id);
  (* The library's strict decode errors surface verbatim. *)
  let unknown =
    proposal root ~name:"u"
      (String.concat ""
         [
           {|{ "charter": 1, "name": "u", "bogus_member": true,|};
           {| "workspace": { "repo": "acme/widgets" },|};
           {| "trigger": [ { "kind": "cli" } ],|};
           {| "run": { "mode": "review", "prompt": "prompt.md",|};
           {| "output_schema": "schema.json" },|};
           {| "budget": { "per_run": { "wall_clock": "15m" } },|};
           {| "publish": { "github": "review-threads" } }|};
         ])
  in
  err ~msg:"an unknown member is a named load error" ~holds:[ "bogus_member" ]
    (Charter_store.install dirs ~src:unknown)

let load_mismatch () =
  let root = temp_root () in
  let dirs = make_dirs root in
  let src = proposal root ~name:"alpha" (cli_json ~name:"alpha") in
  let (_ : Charter_store.Installed.t) =
    ok ~msg:"install" (Charter_store.install dirs ~src)
  in
  Unix.rename
    (User_dirs.charter_dir dirs "alpha")
    (User_dirs.charter_dir dirs "beta");
  err ~msg:"a renamed directory is a named mismatch" ~holds:[ "alpha"; "beta" ]
    (Charter_store.load dirs ~name:"beta");
  err ~msg:"a missing charter is named" ~holds:[ "no charter named nope" ]
    (Charter_store.load dirs ~name:"nope")

let roster_and_index () =
  let root = temp_root () in
  let dirs = make_dirs root in
  let hook = proposal root ~name:"hook" (webhook_json ~name:"hook") in
  let cli = proposal root ~name:"clionly" (cli_json ~name:"clionly") in
  let (_ : Charter_store.Installed.t) =
    ok ~msg:"install hook" (Charter_store.install dirs ~src:hook)
  in
  let (_ : Charter_store.Installed.t) =
    ok ~msg:"install clionly" (Charter_store.install dirs ~src:cli)
  in
  (* A broken charter is a named error in the roster, never an omission; a
     dot entry is the platform's, never a charter. *)
  write_file
    (Filename.concat (User_dirs.charter_dir dirs "broken") "charter.json")
    "not json";
  write_file (Filename.concat (User_dirs.charters_dir dirs) ".DS_Store") "";
  let entries = ok ~msg:"roster" (Charter_store.roster dirs) in
  equal (list string) ~msg:"the roster is sorted and complete"
    [ "broken"; "clionly"; "hook" ]
    (List.map fst entries);
  is_true ~msg:"the broken charter carries its error"
    (match List.assoc "broken" entries with Error _ -> true | Ok _ -> false);
  let bindings, failures = ok ~msg:"index" (Charter_store.ingress_index dirs) in
  (match bindings with
  | [ binding ] ->
      equal string ~msg:"the one binding is the webhook charter" "hook"
        binding.Charter_store.Binding.name;
      is_true ~msg:"the binding's id is the minted token"
        (is_hex ~length:32 binding.Charter_store.Binding.id);
      is_true ~msg:"the binding carries the secret"
        (is_hex ~length:64 binding.Charter_store.Binding.secret);
      is_true ~msg:"the binding is enabled" binding.Charter_store.Binding.enabled
  | _ -> failf "expected one binding, got %d" (List.length bindings));
  equal (list string) ~msg:"the broken charter is a named index failure"
    [ "broken" ] (List.map fst failures)

let digest16 = "0123456789abcdef"

let receipt ~at kind =
  {
    Receipt.at;
    identity = Event.Identity.to_string (Event.Identity.cli ~digest:digest16 ~key:"k1");
    digest = digest16;
    kind;
  }

let receipts_roundtrip () =
  let root = temp_root () in
  let dirs = make_dirs root in
  let name = "hook" in
  equal (list string) ~msg:"a missing log reads empty" []
    (List.map Receipt.encode
       (ok ~msg:"read empty" (Charter_store.read_receipts dirs ~name)));
  let delivery = receipt ~at:1000.0 Receipt.Kind.Delivery in
  let spawned =
    receipt ~at:1001.0
      (Receipt.Kind.Disposition
         (Receipt.Disposition.Spawned { session = "c-fdfec12877f34773" }))
  in
  ok ~msg:"append delivery" (Charter_store.append_receipt dirs ~name delivery);
  ok ~msg:"append spawned" (Charter_store.append_receipt dirs ~name spawned);
  equal (list string) ~msg:"the log reads back in order"
    [ Receipt.encode delivery; Receipt.encode spawned ]
    (List.map Receipt.encode
       (ok ~msg:"read" (Charter_store.read_receipts dirs ~name)));
  (* An unterminated final fragment is not a record; a complete foreign line
     is corruption and is named. *)
  let path =
    Filename.concat (User_dirs.charter_state_dir dirs name) "receipts.jsonl"
  in
  let intact = In_channel.with_open_bin path In_channel.input_all in
  Out_channel.with_open_gen
    [ Open_append; Open_wronly ] 0o600 path
    (fun oc -> Out_channel.output_string oc "{\"torn");
  equal (list string) ~msg:"a torn tail is ignored, complete lines read"
    [ Receipt.encode delivery; Receipt.encode spawned ]
    (List.map Receipt.encode
       (ok ~msg:"read torn" (Charter_store.read_receipts dirs ~name)));
  Out_channel.with_open_gen
    [ Open_trunc; Open_wronly ] 0o600 path
    (fun oc -> Out_channel.output_string oc (intact ^ "garbage\n"));
  err ~msg:"a foreign complete line is a named error" ~holds:[ "line 3" ]
    (Charter_store.read_receipts dirs ~name)

let claim () =
  let root = temp_root () in
  let dirs = make_dirs root in
  let name = "hook" in
  let identity = Event.Identity.cli ~digest:digest16 ~key:"k1" in
  let claim digest =
    ok ~msg:"claim" (Charter_store.claim_identity dirs ~name ~digest identity)
  in
  is_true ~msg:"the first claim wins"
    (match claim digest16 with `Claimed -> true | `Dup -> false);
  is_true ~msg:"the second claim reads dup"
    (match claim digest16 with `Dup -> true | `Claimed -> false);
  (* A policy edit re-admits every event: the marker keys on the digest. *)
  is_true ~msg:"a new digest claims afresh"
    (match claim "fedcba9876543210" with `Claimed -> true | `Dup -> false)

let () =
  run "mentat.charter_store"
    [
      test "install and reinstall" install_and_reinstall;
      test "install refusals" install_refusals;
      test "load mismatch" load_mismatch;
      test "roster and index" roster_and_index;
      test "receipts roundtrip" receipts_roundtrip;
      test "claim markers" claim;
    ]
