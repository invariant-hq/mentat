(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Node], the resident charter node's pure decision folds —
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
  { Charter_store.Binding.name; id; secret; enabled }

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
  equal resolution ~msg:"a disabled charter still resolves, snapshot carried"
    (Mentat_server.Ingress.Resolved { secret = "secret-beta"; enabled = false })
    (Node.resolution bindings ~ingress_id:"bbbb");
  equal resolution ~msg:"an unminted id answers to nothing"
    Mentat_server.Ingress.Unknown
    (Node.resolution bindings ~ingress_id:"cccc");
  equal resolution ~msg:"no charters, no answers" Mentat_server.Ingress.Unknown
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

let () =
  run "mentat.node"
    [
      test "the ingress resolution" resolution_table;
      test "the delivery route" route_table;
      test "the derived checkout remote" checkout_urls;
      test "the child environment" environment_table;
    ]
