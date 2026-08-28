(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Node], the resident routine node's pure decision folds —
   the ingress resolution, the delivery route, and the child-environment
   scrub — driven with no daemon, wire, or store behind them. The module
   lives in [bin/mentatd] and is not library-linkable, so its source is
   copied into this test executable by the [copy_files] rule in [dune]. *)

open Windtrap

let resolution =
  Testable.make
    ~pp:(fun ppf -> function
      | Mentat_server.Ingress.Unknown -> Format.pp_print_string ppf "Unknown"
      | Mentat_server.Ingress.Resolved { secret; enabled } ->
          Format.fprintf ppf "Resolved { secret = %S; enabled = %b }" secret
            enabled)
    ~equal:(fun a b ->
      match (a, b) with
      | Mentat_server.Ingress.Unknown, Mentat_server.Ingress.Unknown -> true
      | ( Mentat_server.Ingress.Resolved
            { secret = a_secret; enabled = a_enabled },
          Mentat_server.Ingress.Resolved
            { secret = b_secret; enabled = b_enabled } ) ->
          String.equal a_secret b_secret && Bool.equal a_enabled b_enabled
      | _ -> false)

let route =
  Testable.make
    ~pp:(fun ppf -> function
      | `Admit -> Format.pp_print_string ppf "Admit"
      | `Ping -> Format.pp_print_string ppf "Ping"
      | `Foreign kind -> Format.fprintf ppf "Foreign %S" kind
      | `Malformed reason -> Format.fprintf ppf "Malformed %S" reason)
    ~equal:(fun a b ->
      match (a, b) with
      | `Admit, `Admit | `Ping, `Ping -> true
      | `Foreign a, `Foreign b -> String.equal a b
      | `Malformed _, `Malformed _ -> true
      | _ -> false)

let binding name id secret enabled =
  { Routine_store.Binding.name; id; secret; enabled }

let resolution_table () =
  let bindings =
    [
      binding "alpha" "aaaa" "secret-alpha" true;
      binding "beta" "bbbb" "secret-beta" false;
    ]
  in
  equal resolution ~msg:"a minted id resolves to its snapshot"
    (Mentat_server.Ingress.Resolved { secret = "secret-alpha"; enabled = true })
    (Node.resolution bindings ~ingress_id:"aaaa");
  equal resolution ~msg:"a disabled routine still resolves, snapshot carried"
    (Mentat_server.Ingress.Resolved { secret = "secret-beta"; enabled = false })
    (Node.resolution bindings ~ingress_id:"bbbb");
  equal resolution ~msg:"an unminted id answers to nothing"
    Mentat_server.Ingress.Unknown
    (Node.resolution bindings ~ingress_id:"cccc");
  equal resolution ~msg:"no routines, no answers" Mentat_server.Ingress.Unknown
    (Node.resolution [] ~ingress_id:"aaaa")

(* A minimal body the narrow decode admits. *)
let pull_request_body =
  Printf.sprintf
    {|{ "action": "opened",
        "repository": { "full_name": "acme/widgets" },
        "pull_request": { "number": 7, "draft": false,
          "author_association": "OWNER",
          "head": { "sha": %S },
          "base": { "ref": "main" } } }|}
    (String.make 40 'a')

let ping_body = {|{"zen":"keep it simple","hook_id":42}|}

(* The body is the arbiter: the HMAC covers it alone, so an intermediary
   relabeling a signed delivery's header must never turn a 202'd review
   into a silent drop, and a header may only confirm what the body already
   refused. *)
let route_table () =
  equal route ~msg:"a pull_request body is admitted under its own header"
    `Admit
    (Node.event_route (Some "pull_request") ~body:pull_request_body);
  equal route ~msg:"a relabeled pull_request body is still admitted" `Admit
    (Node.event_route (Some "ping") ~body:pull_request_body);
  equal route ~msg:"an absent header defers to the decode" `Admit
    (Node.event_route None ~body:pull_request_body);
  equal route ~msg:"a genuine ping is acknowledged without custody" `Ping
    (Node.event_route (Some "ping") ~body:ping_body);
  equal route ~msg:"a ping body under a relabeled header is still a ping"
    `Ping
    (Node.event_route (Some "pull_request") ~body:ping_body);
  equal route ~msg:"a foreign kind the body agrees with is foreign"
    (`Foreign "issues")
    (Node.event_route (Some "issues") ~body:{|{"action":"opened"}|});
  equal route ~msg:"garbage claiming pull_request is refused"
    (`Malformed "")
    (Node.event_route (Some "pull_request") ~body:"not json");
  equal route ~msg:"garbage with no header is refused" (`Malformed "")
    (Node.event_route None ~body:"not json")

let checkout_urls () =
  equal string ~msg:"the default base is github.com"
    "https://github.com/acme/widgets.git"
    (Node.checkout_url ~git_base:None ~repo:"acme/widgets");
  equal string ~msg:"a configured base carries the derived path"
    "https://ghe.example/acme/widgets.git"
    (Node.checkout_url ~git_base:(Some "https://ghe.example")
       ~repo:"acme/widgets");
  equal string ~msg:"a trailing slash is tolerated"
    "/tmp/remotes/acme/widgets.git"
    (Node.checkout_url ~git_base:(Some "/tmp/remotes/") ~repo:"acme/widgets")

let environment_table () =
  let env = Testable.list (Testable.pair Testable.string Testable.string) in
  let base =
    [
      ("PATH", "/usr/bin");
      ("MENTAT_GITHUB_BASE_URL", "http://ambient.example");
      ("HOME", "/home/owner");
    ]
  in
  equal env ~msg:"the ambient API base never rides into a child"
    [ ("PATH", "/usr/bin"); ("HOME", "/home/owner") ]
    (Node.child_environment base ~github_base_url:None);
  equal env ~msg:"a validated base replaces the ambient one"
    [
      ("PATH", "/usr/bin");
      ("HOME", "/home/owner");
      ("MENTAT_GITHUB_BASE_URL", "http://validated.example");
    ]
    (Node.child_environment base
       ~github_base_url:(Some "http://validated.example"));
  equal env ~msg:"a validated base is bound even when nothing was ambient"
    [
      ("PATH", "/usr/bin");
      ("MENTAT_GITHUB_BASE_URL", "http://validated.example");
    ]
    (Node.child_environment
       [ ("PATH", "/usr/bin") ]
       ~github_base_url:(Some "http://validated.example"))

(* The App routing fold: a verified App delivery's repository selects the
   webhook-armed routines watching it that the injected mode predicate
   admits — PAT routines and cli-only routines never match. *)
let app_route_table () =
  let loaded ~name ~json =
    let routine =
      match Mentat_routine.Routine.decode json with
      | Ok routine -> routine
      | Error e -> failf "fixture: %s" (Mentat_routine.Routine.Error.message e)
    in
    {
      Routine_store.Loaded.name;
      dir = "/nonexistent/" ^ name;
      routine;
      digest = "0000000000000000";
      prompt = "p";
      output_schema = "{}";
      ingress_id = None;
    }
  in
  let webhook ~name ~repo =
    loaded ~name
      ~json:
        (Printf.sprintf
           {|{ "routine": 1, "name": %S,
               "workspace": { "repo": %S },
               "trigger": [ { "kind": "github_webhook",
                              "events": ["pull_request.opened"] } ],
               "run": { "mode": "review", "prompt": "p.md",
                        "output_schema": "s.json" },
               "budget": { "per_run": { "wall_clock": "5m" } },
               "publish": { "github": "review-threads" } }|}
           name repo)
  in
  let cli_only =
    loaded ~name:"cli-only"
      ~json:
        {|{ "routine": 1, "name": "cli-only",
            "workspace": { "repo": "acme/widgets" },
            "trigger": [ { "kind": "cli" } ],
            "run": { "mode": "review", "prompt": "p.md",
                     "output_schema": "s.json" },
            "budget": { "per_run": { "wall_clock": "5m" } },
            "publish": { "github": "review-threads" } }|}
  in
  let app = webhook ~name:"app-watcher" ~repo:"acme/widgets" in
  let pat = webhook ~name:"pat-watcher" ~repo:"acme/widgets" in
  let elsewhere = webhook ~name:"elsewhere" ~repo:"acme/gears" in
  let app_mode (l : Routine_store.Loaded.t) =
    not (String.equal l.Routine_store.Loaded.name "pat-watcher")
  in
  let matched =
    Node.app_route [ app; pat; elsewhere; cli_only ] ~app_mode
      ~repo:"acme/widgets"
  in
  equal (list string)
    ~msg:"only the App-mode webhook routine watching the repo matches"
    [ "app-watcher" ]
    (List.map (fun (l : Routine_store.Loaded.t) -> l.Routine_store.Loaded.name)
       matched);
  equal (list string) ~msg:"an unwatched repository matches nothing" []
    (List.map (fun (l : Routine_store.Loaded.t) -> l.Routine_store.Loaded.name)
       (Node.app_route [ app; pat; cli_only ] ~app_mode ~repo:"acme/gizmos"))

let () =
  run "mentat.node"
    [
      test "the ingress resolution" resolution_table;
      test "the delivery route" route_table;
      test "the app delivery routing" app_route_table;
      test "the derived checkout remote" checkout_urls;
      test "the child environment" environment_table;
    ]
