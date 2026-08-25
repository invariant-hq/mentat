(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Result.Syntax
module C = Mentat_config
module Rule = Mentat_permission.Policy.Rule
module Provider = Mentat_llm.Provider

(* This suite exercises the pure config core against its field-precedence
   contract: the field
   vocabulary, the file parser (with pinned diagnostic strings carried verbatim
   from [lib/host/config.ml]), the typed read/write surface, layered precedence
   with origins, workspace trust-gated sanitization, structure-preserving edit
   planning, end-to-end [resolve], and the credential-free codecs. No IO: every
   input is a value.

   [resolve] takes file {e paths} and mints their {!C.Source.t} provenance; the
   output side (origins, warnings) still traffics in [Source.t], so the source
   fixtures below double as the expected provenance. *)

(* Helpers *)

let jo fields =
  Jsont.Json.object'
    (List.map (fun (n, v) -> Jsont.Json.mem (Jsont.Json.name n) v) fields)

let js = Jsont.Json.string
let ji = Jsont.Json.int
let jb = Jsont.Json.bool
let jnum = Jsont.Json.number
let jlist = Jsont.Json.list

let abs s =
  match Lpath.Abs.of_string s with
  | Ok p -> p
  | Error e -> failf "abs %s: %s" s (Lpath.Error.message e)

(* Input paths handed to [resolve], and the [Source.t] provenance [resolve]
   mints from each — the expected output-side values. *)
let user_path = abs "/home/u/config.json"
let extra_path = abs "/etc/mentat/extra.json"
let project_path = abs "/w/config.json"
let project_local_path = abs "/w/config.local.json"
let user_src = C.Source.User { path = user_path }
let extra_src = C.Source.Extra_file { path = extra_path }
let project_src = C.Source.Project { path = project_path }
let project_local_src = C.Source.Project_local { path = project_local_path }
let source_str s = Format.asprintf "%a" C.Source.pp s
let source_equal a b = String.equal (source_str a) (source_str b)
let source = Testable.make ~pp:C.Source.pp ~equal:source_equal
let mode_t = Testable.make ~pp:C.Mode.pp ~equal:C.Mode.equal

let unattended_t =
  Testable.make ~pp:Mentat_permission.Unattended.pp
    ~equal:Mentat_permission.Unattended.equal

(* Distinct constant rules for precedence and duplicate-id examples. *)
let rule_a = Rule.deny_all
let rule_b = Rule.allow_all_dangerously
let rule_c = Rule.always_review
let rule_id rule = Rule.Id.to_string (Rule.id rule)

let rule_json r =
  match Jsont.Json.encode Rule.jsont r with
  | Ok j -> j
  | Error m -> failf "rule encode: %s" m

let source_json source =
  match Jsont.Json.encode C.Source.jsont source with
  | Ok json -> json
  | Error message -> failf "source encode: %s" message

let rules_wire rs =
  [
    ( "permission",
      jo
        [
          ( "rules",
            jo [ ("version", ji 1); ("items", jlist (List.map rule_json rs)) ]
          );
        ] );
  ]

(* Build a configuration from a top-level field association, failing loudly. *)
let doc_exn ?(source = "cfg") fields =
  match C.of_json ~source (jo fields) with
  | Ok d -> d
  | Error e -> failf "config: %s" (C.Error.message e)

let doc_err ?(source = "cfg") fields =
  match C.of_json ~source (jo fields) with
  | Ok _ -> failf "expected decode error"
  | Error e -> C.Error.message e

(* A dotted key nested into the object shape the parser expects. *)
let nested key leaf =
  match String.split_on_char '.' key with
  | [ k ] -> [ (k, leaf) ]
  | [ section; k ] -> [ (section, jo [ (k, leaf) ]) ]
  | _ -> failf "bad key %s" key

let set_exn field text doc =
  match C.set_text field text doc with
  | Ok d -> d
  | Error e -> failf "set %s: %s" (C.Field.name field) (C.Error.message e)

let no_env _ = None

let disabled =
  C.Disabled { status = "untrusted"; project = None; project_local = None }

let resolve_exn ?(env = no_env) ~user ?(extra = None) ?(workspace = disabled)
    ?(overrides = []) () =
  match C.resolve ~env ~user ~extra ~workspace_config:workspace ~overrides with
  | Ok r -> r
  | Error e -> failf "resolve: %s" (C.Error.message e)

let patch1 field text =
  match C.set_text field text C.empty with
  | Ok p -> p
  | Error e -> failf "patch: %s" (C.Error.message e)

let field_name_opt = function
  | None -> None
  | Some (C.Field.Any f) -> Some (C.Field.name f)

(* Warning classification by the exposed stable kind. Each sanitization test
   keeps one message pin per kind for the wording. *)
let kind_is k w = String.equal (C.Warning.kind_string w) k
let is_ignored_key = kind_is "ignored_project_key"
let is_ignored_rules = kind_is "ignored_project_rules"
let is_ignored_budget = kind_is "ignored_project_budget"
let is_disabled = kind_is "project_config_disabled"

let json_of_text bytes =
  match Jsont_bytesrw.decode_string Jsont.json bytes with
  | Ok j -> j
  | Error m -> failf "decode json: %s" m

let jsont_roundtrip codec value =
  match Jsont.Json.encode codec value with
  | Error m -> failf "encode: %s" m
  | Ok json -> (
      match Jsont.Json.decode codec json with
      | Ok v -> v
      | Error m -> failf "decode: %s" m)

(* Generators *)

let alpha = Gen.string_of ~size:(Gen.int_range 1 4) (Gen.char_range 'a' 'z')

let selector_gen =
  Gen.bind alpha (fun p -> Gen.map (fun m -> p ^ "/" ^ m) alpha)

let opt g = Gen.one_of [ Gen.pure None; Gen.map Option.some g ]

(* The precedence property draws (user, override) scenarios with an EXPLICIT
   distribution: 40% unconfigured (both layers absent), 60% configured split
   across user-only / override-only / both. Leaving it emergent (independent
   50/50 options give both-absent ~25%) let it flake below the >= 15% floor on
   unlucky seeds; the deliberate 40% sits ~5 sigma above that floor over the
   100-sample default, so the floor stays a genuine guard with wide margin. *)
let scenario_gen =
  Gen.frequency
    [
      (4, Gen.pure (None, None));
      (2, Gen.map (fun u -> (Some u, None)) selector_gen);
      (2, Gen.map (fun o -> (None, Some o)) selector_gen);
      ( 2,
        Gen.bind selector_gen (fun u ->
            Gen.map (fun o -> (Some u, Some o)) selector_gen) );
    ]

let scenario_gen =
  Gen.with_pp
    (fun ppf (u, o) ->
      Format.fprintf ppf "(user=%s, override=%s)"
        (Option.value u ~default:"-")
        (Option.value o ~default:"-"))
    scenario_gen

(* 1. Field vocabulary. *)

let all_field_names =
  [
    "model";
    "small_model";
    "reasoning";
    "tui.thinking";
    "tui.mouse";
    "notify.enabled";
    "notify.channel";
    "notify.when";
    "notify.command";
    "notify.on";
    "tui.theme";
    "tui.theme_dark";
    "tui.theme_light";
    "tui.diff_layout";
    "run.max_steps";
    "run.subagent_max_concurrent";
    "run.subagent_max_depth";
    "run.subagent_max_exchanges";
    "permission.unattended";
    "sandbox.mode";
    "sandbox.require";
    "sandbox.read";
    "sandbox.readable_roots";
    "sandbox.writable_roots";
    "sandbox.network";
    "sandbox.env_inherit";
    "sandbox.env_exclude";
    "sandbox.env_include_only";
    "shell";
    "compaction.auto";
    "revert.merge";
    "notices.fswatch";
    "notices.cr_comments";
    "notices.dune_diagnostics";
    "dune.watch";
    "dune.targets";
    "dune.lint_command";
    "workspace.tooling";
    "instructions.global";
    "instructions.project";
    "instructions.claude_md";
    "instructions.project_max_bytes";
    "skills.enabled";
    "skills.builtin";
    "skills.project";
    "skills.compat";
    "skills.disabled";
    "skills.paths";
    "skills.catalog_max_bytes";
    "commands.enabled";
    "commands.project";
    "commands.compat";
    "commands.disabled";
    "tools.editor";
    "ocaml.merlin_program";
    "web.enabled";
    "web.allow_private_network";
    "web.fetch_max_bytes";
    "web.output_max_chars";
    "web.timeout_ms";
    "web.max_timeout_ms";
    "web.search_provider";
    "web.exa_api_key";
    "web.parallel_api_key";
    "image.max_bytes";
    "image.max_dimension";
    "image.max_count";
  ]

let field_vocabulary =
  group "field vocabulary"
    [
      test "all is a stable, ordered enumeration" (fun () ->
          equal (list string) ~msg:"names in declaration order" all_field_names
            (List.map (fun (C.Field.Any f) -> C.Field.name f) C.Field.all));
      test "of_string/name round-trips over all" (fun () ->
          List.iter
            (fun (C.Field.Any field) ->
              let name = C.Field.name field in
              match C.Field.of_string name with
              | Ok (C.Field.Any parsed) ->
                  is_true
                    ~msg:(name ^ " round-trips to the same field")
                    (C.Field.equal field parsed);
                  equal string ~msg:"name is stable" name (C.Field.name parsed)
              | Error e -> failf "of_string %s: %s" name (C.Error.message e))
            C.Field.all);
      test "web resource limits are user-owned" (fun () ->
          List.iter
            (fun (C.Field.Any field) ->
              is_false
                ~msg:(C.Field.name field ^ " is not workspace-shared")
                (C.Field.allowed_in_workspace field))
            [
              C.Field.Any C.Field.web_fetch_max_bytes;
              C.Field.Any C.Field.web_output_max_chars;
              C.Field.Any C.Field.web_timeout_ms;
              C.Field.Any C.Field.web_max_timeout_ms;
              C.Field.Any C.Field.web_search_provider;
              C.Field.Any C.Field.web_exa_api_key;
              C.Field.Any C.Field.web_parallel_api_key;
            ]);
      test "closed-vocabulary fields accept exactly their values ()" (fun () ->
          List.iter
            (fun (C.Field.Any field) ->
              match C.Field.values field with
              | None -> ()
              | Some spellings ->
                  let name = C.Field.name field in
                  List.iter
                    (fun sp ->
                      (* every advertised spelling parses *)
                      let doc = set_exn field sp C.empty in
                      equal (option string)
                        ~msg:(name ^ " text round-trips " ^ sp)
                        (Some sp) (C.text field doc))
                    spellings;
                  is_true
                    ~msg:(name ^ " rejects an out-of-vocabulary value")
                    (Result.is_error
                       (C.set_text field "not-a-valid-spelling" C.empty)))
            C.Field.all);
      test "provider base URL family parses and round-trips" (fun () ->
          (match C.Field.of_string "providers.openai.base_url" with
          | Ok (C.Field.Any f) ->
              equal string ~msg:"name round-trips" "providers.openai.base_url"
                (C.Field.name f)
          | Error e -> failf "provider parse: %s" (C.Error.message e));
          equal string ~msg:"name from a typed provider field"
            "providers.anthropic.base_url"
            (C.Field.name
               (C.Field.provider_base_url (Provider.make "anthropic"))));
      test "provider family rejects malformed keys" (fun () ->
          equal string ~msg:"invalid provider id"
            {|invalid provider id "Bad": id must start with a lowercase ASCII letter|}
            (match C.Field.of_string "providers.Bad.base_url" with
            | Ok _ -> failf "expected error"
            | Error e -> C.Error.message e);
          equal string ~msg:"providers prefix without base_url"
            "unknown config key: providers.openai"
            (match C.Field.of_string "providers.openai" with
            | Ok _ -> failf "expected error"
            | Error e -> C.Error.message e));
      test "permission.rules is not a scalar field key" (fun () ->
          equal string ~msg:"structured field is not addressable as a scalar"
            "config key permission.rules is not a scalar value"
            (match C.Field.of_string "permission.rules" with
            | Ok _ -> failf "expected error"
            | Error e -> C.Error.message e));
      test "removed surface names are ordinary unknown config keys" (fun () ->
          List.iter
            (fun name ->
              equal string ~msg:name
                ("unknown config key: " ^ name)
                (match C.Field.of_string name with
                | Ok _ -> failf "expected error"
                | Error e -> C.Error.message e))
            [
              "run.subagent_wake"; "tools.anchored_edits"; "web.search_backend";
            ]);
      test "an unknown config key is rejected with a hint" (fun () ->
          match C.Field.of_string "nonsense.key" with
          | Ok _ -> failf "expected error"
          | Error e ->
              equal string ~msg:"message" "unknown config key: nonsense.key"
                (C.Error.message e);
              is_true ~msg:"diagnostic carries the supported-keys hint"
                (String.includes ~affix:"Hint: supported keys:"
                   (Mentat_diagnostic.to_string (C.Error.diagnostic e))));
    ]

(* 2. Parser. *)

let parser_valid =
  group "parser: valid leaves decode"
    [
      test "one representative per codec kind" (fun () ->
          let get f fields = C.text f (doc_exn fields) in
          equal (option string) ~msg:"string (shell)" (Some "/bin/zsh")
            (get C.Field.shell (nested "shell" (js "/bin/zsh")));
          equal (option string) ~msg:"selector (model)"
            (Some "anthropic/claude-3")
            (get C.Field.model (nested "model" (js "anthropic/claude-3")));
          equal (option string) ~msg:"bool in a section (tui.thinking)"
            (Some "true")
            (get C.Field.tui_thinking (nested "tui.thinking" (jb true)));
          equal (option string) ~msg:"int in a section (run.max_steps)"
            (Some "10")
            (get C.Field.run_max_steps (nested "run.max_steps" (ji 10)));
          equal (option string) ~msg:"typed enum (sandbox.mode)"
            (Some "workspace-write")
            (get C.Field.sandbox_mode
               (nested "sandbox.mode" (js "workspace-write")));
          equal (option string) ~msg:"typed enum (reasoning)" (Some "high")
            (get C.Field.reasoning (nested "reasoning" (js "high")));
          equal (option string) ~msg:"string enum (tools.editor)"
            (Some "apply-patch")
            (get C.Field.tools_editor
               (nested "tools.editor" (js "apply-patch")));
          equal (option string) ~msg:"string list (skills.paths)"
            (Some {|["/a","/b"]|})
            (get C.Field.skills_paths
               (nested "skills.paths" (jlist [ js "/a"; js "/b" ])));
          equal (option string) ~msg:"sandbox roots (readable_roots)"
            (Some {|["/abs","~","~/sub"]|})
            (get C.Field.sandbox_readable_roots
               (nested "sandbox.readable_roots"
                  (jlist [ js "/abs"; js "~"; js "~/sub" ])));
          equal (option string) ~msg:"merlin program" (Some {|["ocamlmerlin"]|})
            (get C.Field.ocaml_merlin_program
               (nested "ocaml.merlin_program" (jlist [ js "ocamlmerlin" ]))));
      test "provider base_url nesting decodes" (fun () ->
          let doc =
            doc_exn
              [
                ( "providers",
                  jo [ ("openai", jo [ ("base_url", js "https://x") ]) ] );
              ]
          in
          equal (option string) ~msg:"nested provider url" (Some "https://x")
            (C.text (C.Field.provider_base_url (Provider.make "openai")) doc));
      test "permission.rules (versioned) decodes to file order" (fun () ->
          let doc = doc_exn (rules_wire [ rule_a; rule_b ]) in
          let rules = C.permission_rules doc in
          equal int ~msg:"count" 2 (List.length rules);
          is_true ~msg:"order preserved"
            (match rules with
            | [ x; y ] -> Rule.equal x rule_a && Rule.equal y rule_b
            | _ -> false));
      test "empty text is the empty configuration" (fun () ->
          match C.of_text ~source:"cfg" "" with
          | Ok d -> is_true ~msg:"equals empty" (C.equal d C.empty)
          | Error e -> failf "of_text: %s" (C.Error.message e));
    ]

(* Each row: label, malformed fields, the exact pinned diagnostic. *)
let malformed_rows =
  [
    ("string non-string", nested "shell" (ji 1), "cfg shell must be a string");
    ("string empty", nested "shell" (js ""), "cfg shell must not be empty");
    ("selector non-string", nested "model" (ji 1), "cfg model must be a string");
    ( "selector malformed",
      nested "model" (js "noslash"),
      "cfg model model selector must be in the form provider/model" );
    ( "bool non-bool",
      nested "tui.thinking" (js "yes"),
      "cfg tui.thinking must be a boolean" );
    ( "int non-number",
      nested "run.max_steps" (js "x"),
      "cfg run.max_steps must be an integer" );
    ( "int non-integer",
      nested "run.max_steps" (jnum 1.5),
      "cfg run.max_steps must be an integer" );
    ( "int not positive",
      nested "run.max_steps" (ji 0),
      "cfg run.max_steps must be positive" );
    ( "enum non-string",
      nested "sandbox.mode" (ji 1),
      "cfg sandbox.mode must be a string" );
    ( "enum unknown (mode)",
      nested "sandbox.mode" (js "bogus"),
      "cfg sandbox.mode: unknown sandbox mode: bogus" );
    ( "enum unknown (reasoning)",
      nested "reasoning" (js "extreme"),
      "cfg reasoning: unknown reasoning effort: extreme" );
    ( "enum unknown (require)",
      nested "sandbox.require" (js "hard"),
      "cfg sandbox.require: unknown sandbox requirement: hard" );
    ( "enum unknown (read)",
      nested "sandbox.read" (js "some"),
      "cfg sandbox.read: unknown sandbox read scope: some" );
    ( "enum unknown (network)",
      nested "sandbox.network" (js "vpn"),
      "cfg sandbox.network: unknown sandbox network: vpn" );
    ( "enum unknown (unattended)",
      nested "permission.unattended" (js "halt"),
      "cfg permission.unattended: unknown permission unattended policy: halt" );
    ( "string enum unknown (editor)",
      nested "tools.editor" (js "vim"),
      "cfg tools.editor: unknown tools editor: vim" );
    ( "string enum unknown (tooling)",
      nested "workspace.tooling" (js "maybe"),
      "cfg workspace.tooling: unknown workspace tooling mode: maybe" );
    ( "string list non-array",
      nested "skills.paths" (js "/a"),
      "cfg skills.paths must be a JSON array of strings" );
    ( "string list non-string element",
      nested "skills.paths" (jlist [ ji 1 ]),
      "cfg skills.paths must be a string" );
    ( "string list empty element",
      nested "skills.paths" (jlist [ js "" ]),
      "cfg skills.paths must not be empty" );
    ( "sandbox roots invalid spelling",
      nested "sandbox.readable_roots" (jlist [ js "relative/path" ]),
      {|cfg sandbox.readable_roots[0] must be absolute, "~", or start with "~/"|}
    );
    ( "merlin empty list",
      nested "ocaml.merlin_program" (jlist []),
      "cfg ocaml.merlin_program must not be empty" );
    ( "lint command empty token",
      nested "dune.lint_command" (jlist [ js "" ]),
      "cfg dune.lint_command must not be empty" );
    ( "merlin NUL token",
      nested "ocaml.merlin_program" (jlist [ js "a\000b" ]),
      "cfg ocaml.merlin_program elements must be non-empty and must not \
       contain NUL" );
    ("section not an object", [ ("run", js "x") ], "cfg run must be an object");
    ( "providers not an object",
      [ ("providers", js "x") ],
      "cfg providers must be an object" );
    ( "provider entry not an object",
      [ ("providers", jo [ ("openai", js "x") ]) ],
      "cfg providers.openai must be an object" );
    ( "provider base_url non-string",
      [ ("providers", jo [ ("openai", jo [ ("base_url", ji 1) ]) ]) ],
      "cfg providers.openai.base_url must be a string" );
    ( "obsolete unversioned rules array",
      [ ("permission", jo [ ("rules", jlist []) ]) ],
      "cfg permission.rules uses the obsolete unversioned array format; use { \
       \"version\": 1, \"items\": [...] }" );
  ]

let parser_errors =
  group "parser: pinned diagnostics"
    [
      test "malformed shapes produce the exact pinned strings" (fun () ->
          List.iter
            (fun (label, fields, expected) ->
              equal string ~msg:label expected (doc_err fields))
            malformed_rows);
      test "a non-object top-level is rejected" (fun () ->
          equal string ~msg:"number top-level"
            "cfg config must be a JSON object"
            (match C.of_json ~source:"cfg" (ji 1) with
            | Ok _ -> failf "expected error"
            | Error e -> C.Error.message e);
          equal string ~msg:"array via of_text"
            "cfg config must be a JSON object"
            (match C.of_text ~source:"cfg" "[]" with
            | Ok _ -> failf "expected error"
            | Error e -> C.Error.message e));
      test "an unknown permission.rules version is rejected" (fun () ->
          let msg =
            doc_err
              [
                ( "permission",
                  jo
                    [ ("rules", jo [ ("version", ji 2); ("items", jlist []) ]) ]
                );
              ]
          in
          is_true ~msg:("prefixed: " ^ msg)
            (String.starts_with ~prefix:"cfg permission.rules: " msg);
          is_true
            ~msg:("names the version: " ^ msg)
            (String.includes ~affix:"unknown permission rules version: 2" msg));
      test "duplicate permission rules are rejected with the rule id" (fun () ->
          equal string ~msg:"duplicate id in message"
            ("cfg permission.rules contains duplicate rule " ^ rule_id rule_a)
            (doc_err (rules_wire [ rule_a; rule_a ])));
    ]

let messages errors = List.map C.Error.message errors

let parser_validate =
  group "parser: value errors vs ignored keys"
    [
      test "validate reports supported invalid fields; ignored_keys the rest"
        (fun () ->
          let json =
            jo
              [
                ("unknown1", ji 1);
                ("run", jo [ ("max_steps", js "x"); ("unknown_run", ji 1) ]);
                ("unknown2", ji 2);
              ]
          in
          equal (list string) ~msg:"value errors"
            [ "cfg run.max_steps must be an integer" ]
            (messages (C.validate ~source:"cfg" json));
          equal (list string) ~msg:"ignored keys, in file order"
            [
              "cfg unknown field: unknown1";
              "cfg unknown field: unknown2";
              "cfg run unknown field: unknown_run";
            ]
            (messages (C.ignored_keys ~source:"cfg" json)));
      test "removed file shapes are ordinary unknown fields, not rejections"
        (fun () ->
          (* These members named behavior in an earlier stack. next has no
             field, alias, or decoder for them, so each loads without error,
             contributes nothing, and is no value error — it is an ignored key,
             exactly like any other unknown member. *)
          List.iter
            (fun (label, fields, ignored_message) ->
              is_true
                ~msg:(label ^ " loads and contributes nothing")
                (C.equal C.empty (doc_exn fields));
              equal (list string)
                ~msg:(label ^ " is no value error")
                []
                (messages (C.validate ~source:"cfg" (jo fields)));
              equal (list string)
                ~msg:(label ^ " is named as ignored")
                [ ignored_message ]
                (messages (C.ignored_keys ~source:"cfg" (jo fields))))
            [
              ( "permission.mode",
                [ ("permission", jo [ ("mode", js "auto") ]) ],
                "cfg permission unknown field: mode" );
              ( "run.subagent_wake",
                [ ("run", jo [ ("subagent_wake", jb false) ]) ],
                "cfg run unknown field: subagent_wake" );
              ( "tools.anchored_edits",
                [ ("tools", jo [ ("anchored_edits", jb true) ]) ],
                "cfg tools unknown field: anchored_edits" );
              ( "web.search_backend",
                [ ("web", jo [ ("search_backend", js "brave") ]) ],
                "cfg web unknown field: search_backend" );
            ]);
      test "a workspace layer also ignores the keys the allowlist drops"
        (fun () ->
          let json =
            jo
              [
                ("model", js "openai/gpt-5.6-sol");
                ("shell", js "/bin/bash");
                ("providers", jo [ ("openai", jo [ ("base_url", js "u") ]) ]);
              ]
          in
          equal (list string) ~msg:"user layer keeps every supported key" []
            (messages (C.ignored_keys ~source:"cfg" json));
          equal (list string) ~msg:"workspace layer names the dropped keys"
            [
              "cfg providers.openai.base_url is ignored in a workspace config \
               file; set it in the user config with `mentat config set \
               providers.openai.base_url`";
              "cfg shell is ignored in a workspace config file; set it in the \
               user config with `mentat config set shell`";
            ]
            (messages (C.ignored_keys ~workspace:true ~source:"cfg" json)));
      test "a workspace layer ignores permission.rules" (fun () ->
          let json =
            jo
              [
                ( "permission",
                  jo
                    [
                      ( "rules",
                        jo
                          [
                            ("version", ji 1);
                            ("items", jlist [ rule_json rule_a ]);
                          ] );
                    ] );
              ]
          in
          equal (list string) ~msg:"named as ignored"
            [ "cfg permission.rules is ignored in a workspace config file" ]
            (messages (C.ignored_keys ~workspace:true ~source:"cfg" json)));
      test "a clean configuration reports nothing either way" (fun () ->
          let json = jo (nested "run.max_steps" (ji 5)) in
          equal (list string) ~msg:"no value errors" []
            (messages (C.validate ~source:"cfg" json));
          equal (list string) ~msg:"no ignored keys" []
            (messages (C.ignored_keys ~workspace:true ~source:"cfg" json)));
    ]

(* 3. Typed reads and writes. *)

let typed_surface =
  group "typed reads and writes"
    [
      test
        "Resolved.get is total over defaulted fields; find covers optional \
         fields" (fun () ->
          let r = resolve_exn ~user:(user_path, C.empty) () in
          equal int ~msg:"web.timeout_ms default" 30_000
            (C.Resolved.get C.Field.web_timeout_ms r);
          equal unattended_t ~msg:"permission.unattended default"
            Mentat_permission.Unattended.Block
            (C.Resolved.get C.Field.permission_unattended r);
          is_true ~msg:"tui.thinking default"
            (C.Resolved.get C.Field.tui_thinking r);
          equal (option mode_t) ~msg:"unset sandbox.mode" None
            (C.Resolved.find C.Field.sandbox_mode r);
          let env = function
            | "MENTAT_SANDBOX_MODE" -> Some "workspace-write"
            | _ -> None
          in
          let r = resolve_exn ~env ~user:(user_path, C.empty) () in
          equal (option mode_t) ~msg:"env-configured sandbox.mode"
            (Some C.Mode.Workspace_write)
            (C.Resolved.find C.Field.sandbox_mode r));
      test "image caps default and accept positive-int overrides" (fun () ->
          let r = resolve_exn ~user:(user_path, C.empty) () in
          equal int ~msg:"image.max_bytes default"
            (5 * 1024 * 1024)
            (C.Resolved.get C.Field.image_max_bytes r);
          equal int ~msg:"image.max_dimension default" 8000
            (C.Resolved.get C.Field.image_max_dimension r);
          equal int ~msg:"image.max_count default" 20
            (C.Resolved.get C.Field.image_max_count r);
          let c = set_exn C.Field.image_max_count "5" C.empty in
          let r = resolve_exn ~user:(user_path, c) () in
          equal int ~msg:"image.max_count override" 5
            (C.Resolved.get C.Field.image_max_count r);
          match C.set C.Field.image_max_bytes 0 C.empty with
          | Ok _ -> failf "expected a non-positive byte cap to be rejected"
          | Error _ -> ());
      test "typed set stores the domain value; text renders its spelling"
        (fun () ->
          match C.set C.Field.sandbox_mode C.Mode.Workspace_write C.empty with
          | Ok c ->
              equal (option string) ~msg:"spelling" (Some "workspace-write")
                (C.text C.Field.sandbox_mode c);
              equal (option mode_t) ~msg:"typed find recovers the value"
                (Some C.Mode.Workspace_write)
                (C.find C.Field.sandbox_mode c)
          | Error e -> failf "set: %s" (C.Error.message e));
      test "model selectors stay typed across text and JSON boundaries"
        (fun () ->
          let check field raw =
            let parsed = set_exn field raw C.empty in
            let selector =
              match C.find field parsed with
              | Some selector -> selector
              | None -> fail "parsed selector is absent"
            in
            let config =
              match C.set field selector C.empty with
              | Ok config -> config
              | Error error -> failf "set: %s" (C.Error.message error)
            in
            ignore (require_some ~msg:"typed set/find" (C.find field config));
            equal (option string) ~msg:"text projection" (Some raw)
              (C.text field config);
            let bytes =
              match
                C.plan ~source:"cfg" ~original:"{}" ~f:(fun _ -> Ok config)
              with
              | Ok (C.Plan.Write bytes) -> bytes
              | Ok C.Plan.Unchanged -> fail "expected selector write"
              | Error error -> failf "plan: %s" (C.Error.message error)
            in
            let decoded =
              match C.of_text ~source:"cfg" bytes with
              | Ok config -> config
              | Error error -> failf "decode: %s" (C.Error.message error)
            in
            ignore
              (require_some ~msg:"typed JSON round-trip" (C.find field decoded));
            equal (option string) ~msg:"JSON spelling round-trip" (Some raw)
              (C.text field decoded)
          in
          check C.Field.model "openai/gpt-5");
      test "typed set validates invariants the domain type cannot carry"
        (fun () ->
          let err field value =
            match C.set field value C.empty with
            | Ok _ -> failf "expected error"
            | Error e -> C.Error.message e
          in
          equal string ~msg:"non-positive int" "run.max_steps must be positive"
            (err C.Field.run_max_steps 0);
          equal string ~msg:"string-enum spelling" "unknown tools editor: vim"
            (err C.Field.tools_editor "vim");
          equal string ~msg:"root spelling"
            {|sandbox.writable_roots[0] must be absolute, "~", or start with "~/"|}
            (err C.Field.sandbox_writable_roots [ "relative" ]));
      test "override layers cannot carry permission rules" (fun () ->
          let user_doc = C.set_permission_rules [ rule_a ] C.empty in
          let override = C.set_permission_rules [ rule_b ] C.empty in
          let r =
            resolve_exn ~user:(user_path, user_doc) ~overrides:[ override ] ()
          in
          equal (list string) ~msg:"only the user file contributes rules"
            [ source_str user_src ]
            (List.map
               (fun (s, _) -> source_str s)
               (C.Resolved.permission_rules r)));
    ]

(* 4. Precedence and origins. *)

let precedence =
  group "precedence and origins"
    [
      test "higher-precedence layers win; shadowed sources are nearest-first"
        (fun () ->
          let r =
            resolve_exn
              ~user:(user_path, doc_exn (nested "model" (js "user/m")))
              ~extra:
                (Some (extra_path, doc_exn (nested "model" (js "extra/m"))))
              ~overrides:[ patch1 C.Field.model "over/m" ]
              ()
          in
          equal (option string) ~msg:"override wins effective value"
            (Some "over/m")
            (C.Resolved.text C.Field.model r);
          match C.Resolved.origin C.Field.model r with
          | None -> failf "expected an origin"
          | Some o ->
              equal source ~msg:"winning source is the override"
                C.Source.Override (C.Origin.source o);
              equal (list string)
                ~msg:"shadowed nearest-first: extra, then user"
                [ source_str extra_src; source_str user_src ]
                (List.map source_str (C.Origin.shadowed o)));
      test "defaults contribute Default origins only where unconfigured"
        (fun () ->
          let r =
            resolve_exn
              ~user:(user_path, doc_exn (nested "tui.thinking" (jb false)))
              ()
          in
          (* configured field: its own source, not a default *)
          (match C.Resolved.origin C.Field.tui_thinking r with
          | Some o ->
              equal source ~msg:"configured takes the user source" user_src
                (C.Origin.source o)
          | None -> failf "expected origin");
          (* unconfigured with a default: a Default origin and effective value *)
          (match C.Resolved.origin C.Field.compaction_auto r with
          | Some o ->
              equal source ~msg:"default origin"
                (C.Source.Default { reason = "built-in compaction.auto" })
                (C.Origin.source o);
              equal (option string) ~msg:"effective default value" (Some "true")
                (C.Resolved.text C.Field.compaction_auto r)
          | None -> failf "expected a default origin");
          (* unconfigured without a default: no origin, no value *)
          equal (option pass)
            ~msg:"no origin for an unconfigured no-default field" None
            (C.Resolved.origin C.Field.sandbox_mode r);
          equal (option pass) ~msg:"configured is None" None
            (C.Resolved.configured C.Field.sandbox_mode r);
          equal (option pass) ~msg:"text is None" None
            (C.Resolved.text C.Field.sandbox_mode r));
      test "permission.rules groups follow first-match precedence" (fun () ->
          let user_doc = C.set_permission_rules [ rule_a ] C.empty in
          let extra_doc = C.set_permission_rules [ rule_b ] C.empty in
          let r =
            resolve_exn ~user:(user_path, user_doc)
              ~extra:(Some (extra_path, extra_doc))
              ()
          in
          let groups = C.Resolved.permission_rules r in
          equal (list string) ~msg:"descending precedence: extra before user"
            [ source_str extra_src; source_str user_src ]
            (List.map (fun (s, _) -> source_str s) groups);
          is_true ~msg:"rule payloads travel with their source"
            (match groups with
            | [ (_, [ x ]); (_, [ y ]) ] ->
                Rule.equal x rule_b && Rule.equal y rule_a
            | _ -> false));
      prop
        "configured agrees with the highest configuring layer; configured \
         fields have origins"
        scenario_gen (fun (user_m, over_m) ->
          let user_doc =
            match user_m with
            | None -> C.empty
            | Some m -> set_exn C.Field.model m C.empty
          in
          let overrides =
            match over_m with
            | None -> []
            | Some m -> [ patch1 C.Field.model m ]
          in
          let r = resolve_exn ~user:(user_path, user_doc) ~overrides () in
          let expected =
            match over_m with Some m -> Some m | None -> user_m
          in
          (* Both floors sit well below their ~60% / ~40% deliberate means, so
             they guard that each region is exercised without hugging a boundary. *)
          cover "configured" (Option.is_some expected);
          cover "unconfigured" (Option.is_none expected);
          equal (option string) ~msg:"configured spelling" expected
            (C.Resolved.text C.Field.model r);
          equal bool ~msg:"configured presence" (Option.is_some expected)
            (Option.is_some (C.Resolved.configured C.Field.model r));
          match expected with
          | None ->
              equal (option pass) ~msg:"no origin when unconfigured" None
                (C.Resolved.origin C.Field.model r)
          | Some _ ->
              ignore
                (require_some ~msg:"origin when configured"
                   (C.Resolved.origin C.Field.model r)));
    ]

(* 5. Workspace sanitization / trust gating. *)

let workspace =
  group "workspace sanitization and trust gating"
    [
      test
        "trusted: non-allowlist keys, rules, and widening budgets are stripped \
         with warnings" (fun () ->
          let user_doc =
            C.set_permission_rules [ rule_c ]
              (doc_exn (nested "run.max_steps" (ji 50)))
          in
          let project_doc =
            C.set_permission_rules [ rule_a ]
              (doc_exn
                 (nested "model" (js "proj/m")
                 @ nested "tui.thinking" (jb false)
                 @ nested "run.max_steps" (ji 100)))
          in
          let ws =
            C.Trusted
              {
                project = C.Loaded (project_path, project_doc);
                project_local = C.Absent;
              }
          in
          let r = resolve_exn ~user:(user_path, user_doc) ~workspace:ws () in
          equal (option string) ~msg:"shared key survives (model)"
            (Some "proj/m")
            (C.Resolved.text C.Field.model r);
          equal (option int) ~msg:"widening budget is clamped to the user value"
            (Some 50)
            (C.Resolved.configured C.Field.run_max_steps r);
          equal (option pass)
            ~msg:"non-allowlist key does not configure the value" None
            (C.Resolved.configured C.Field.tui_thinking r);
          equal (option string) ~msg:"stripped key falls back to its default"
            (Some "true")
            (C.Resolved.text C.Field.tui_thinking r);
          let ws_warnings = C.Resolved.warnings r in
          equal int ~msg:"exactly three warnings" 3 (List.length ws_warnings);
          (match ws_warnings with
          | [ w_key; w_rules; w_budget ] ->
              is_true ~msg:"first: ignored key" (is_ignored_key w_key);
              equal (option string) ~msg:"key warning names the field"
                (Some "tui.thinking")
                (field_name_opt (C.Warning.field w_key));
              is_true ~msg:"second: ignored rules" (is_ignored_rules w_rules);
              equal string ~msg:"rules warning wording"
                "permission.rules is ignored in workspace config: 1 rule \
                 dropped (workspace config cannot carry permission rules)"
                (C.Warning.message w_rules);
              is_true ~msg:"third: ignored budget" (is_ignored_budget w_budget);
              equal string ~msg:"budget warning wording"
                "run.max_steps is ignored because workspace config may tighten \
                 but not widen it (effective limit: 50)"
                (C.Warning.message w_budget);
              equal (option string) ~msg:"budget warning names the field"
                (Some "run.max_steps")
                (field_name_opt (C.Warning.field w_budget))
          | _ -> failf "expected exactly [key; rules; budget]");
          equal (list string) ~msg:"only the user layer contributes rules"
            [ source_str user_src ]
            (List.map
               (fun (s, _) -> source_str s)
               (C.Resolved.permission_rules r)));
      test "trusted: web resource limits are stripped as user policy" (fun () ->
          let user_doc =
            doc_exn
              [
                ( "web",
                  jo
                    [
                      ("fetch_max_bytes", ji 100);
                      ("output_max_chars", ji 200);
                      ("timeout_ms", ji 300);
                      ("max_timeout_ms", ji 400);
                    ] );
              ]
          in
          let project_doc =
            doc_exn
              (nested "model" (js "project/m")
              @ [
                  ( "web",
                    jo
                      [
                        ("fetch_max_bytes", ji 1_000);
                        ("output_max_chars", ji 2_000);
                        ("timeout_ms", ji 900);
                        ("max_timeout_ms", ji 800);
                      ] );
                ])
          in
          let ws =
            C.Trusted
              {
                project = C.Loaded (project_path, project_doc);
                project_local = C.Absent;
              }
          in
          let r = resolve_exn ~user:(user_path, user_doc) ~workspace:ws () in
          equal (option string) ~msg:"an unrelated shared field survives"
            (Some "project/m")
            (C.Resolved.text C.Field.model r);
          List.iter
            (fun (C.Field.Any field, expected) ->
              equal (option string) ~msg:(C.Field.name field) (Some expected)
                (C.Resolved.text field r))
            [
              (C.Field.Any C.Field.web_fetch_max_bytes, "100");
              (C.Field.Any C.Field.web_output_max_chars, "200");
              (C.Field.Any C.Field.web_timeout_ms, "300");
              (C.Field.Any C.Field.web_max_timeout_ms, "400");
            ];
          let warnings = C.Resolved.warnings r in
          equal (list string) ~msg:"each web field is diagnosed"
            [
              "web.fetch_max_bytes";
              "web.output_max_chars";
              "web.timeout_ms";
              "web.max_timeout_ms";
            ]
            (List.filter_map
               (fun warning -> field_name_opt (C.Warning.field warning))
               warnings);
          is_true ~msg:"all web fields use the non-shared-key warning"
            (List.for_all is_ignored_key warnings));
      test "disabled: present files warn and nothing contributes" (fun () ->
          let user_doc = doc_exn (nested "model" (js "user/m")) in
          let ws =
            C.Disabled
              {
                status = "untrusted";
                project = Some project_path;
                project_local = Some project_local_path;
              }
          in
          let r = resolve_exn ~user:(user_path, user_doc) ~workspace:ws () in
          equal (option string) ~msg:"only user contributes" (Some "user/m")
            (C.Resolved.text C.Field.model r);
          let ws_warnings = C.Resolved.warnings r in
          equal int ~msg:"one warning per present file" 2
            (List.length ws_warnings);
          List.iter
            (fun w ->
              is_true ~msg:"disabled warning" (is_disabled w);
              equal string ~msg:"disabled wording"
                "workspace config file disabled: workspace trust is untrusted"
                (C.Warning.message w))
            ws_warnings;
          equal (list string) ~msg:"warnings name the present files"
            [ source_str project_src; source_str project_local_src ]
            (List.map (fun w -> source_str (C.Warning.source w)) ws_warnings));
      prop "no trusted workspace doc can raise a budget or introduce a rule"
        (let ws_doc_gen =
           Gen.bind
             (opt (Gen.int_range 1 200))
             (fun steps ->
               Gen.bind
                 (Gen.of_list [ true; false ])
                 (fun with_rules ->
                   Gen.map
                     (fun thinking ->
                       let d = C.empty in
                       let d =
                         match steps with
                         | None -> d
                         | Some n ->
                             set_exn C.Field.run_max_steps (string_of_int n) d
                       in
                       let d =
                         if with_rules then
                           C.set_permission_rules [ rule_a; rule_b ] d
                         else d
                       in
                       if thinking then set_exn C.Field.tui_thinking "false" d
                       else d)
                     (Gen.of_list [ true; false ])))
         in
         Gen.with_pp
           (fun ppf d ->
             Format.fprintf ppf "doc[max_steps=%s rules=%d]"
               (Option.value (C.text C.Field.run_max_steps d) ~default:"-")
               (List.length (C.permission_rules d)))
           ws_doc_gen)
        (fun project_doc ->
          let user_doc = doc_exn (nested "run.max_steps" (ji 50)) in
          let ws =
            C.Trusted
              {
                project = C.Loaded (project_path, project_doc);
                project_local = C.Absent;
              }
          in
          let r = resolve_exn ~user:(user_path, user_doc) ~workspace:ws () in
          (match C.Resolved.configured C.Field.run_max_steps r with
          | Some n ->
              is_true
                ~msg:(Printf.sprintf "budget %d not raised above 50" n)
                (n <= 50)
          | None -> failf "user always sets run.max_steps");
          List.iter
            (fun (src, _) ->
              match src with
              | C.Source.Project _ | C.Source.Project_local _ ->
                  failf "a workspace rule leaked into the effective posture"
              | _ -> ())
            (C.Resolved.permission_rules r));
    ]

(* 6. Edit planning. *)

let plan_write = function
  | Ok (C.Plan.Write bytes) -> bytes
  | Ok C.Plan.Unchanged -> failf "expected Write, got Unchanged"
  | Error e -> failf "plan: %s" (C.Error.message e)

let reparse bytes =
  match C.of_text ~source:"config" bytes with
  | Ok d -> d
  | Error e -> failf "reparse: %s" (C.Error.message e)

let edit_planning =
  group "edit planning"
    [
      test "an identity edit is Unchanged" (fun () ->
          List.iter
            (fun original ->
              match C.plan ~source:"config" ~original ~f:(fun d -> Ok d) with
              | Ok C.Plan.Unchanged -> ()
              | Ok (C.Plan.Write b) -> failf "expected Unchanged, got %s" b
              | Error e -> failf "plan: %s" (C.Error.message e))
            [
              "";
              {|{"model":"openai/m"}|};
              {|{ "unknown": 1, "run": { "max_steps": 5 } }|};
            ]);
      test "setting a field retains unknown members and their nesting"
        (fun () ->
          let original =
            {|{ "unknown_top": 1, "model": "openai/old", "run": { "max_steps": 5, "unknown_run": true } }|}
          in
          let bytes =
            plan_write
              (C.plan ~source:"config" ~original ~f:(fun d ->
                   C.set_text C.Field.model "openai/new" d))
          in
          (* Round-trip law: the written bytes re-parse to exactly f's output. *)
          let expected =
            match C.of_text ~source:"config" original with
            | Ok d -> (
                match C.set_text C.Field.model "openai/new" d with
                | Ok d -> d
                | Error e -> failf "%s" (C.Error.message e))
            | Error e -> failf "%s" (C.Error.message e)
          in
          is_true ~msg:"reparse equals f's output"
            (C.equal (reparse bytes) expected);
          (* Unknown members are retained by value and nesting (order is not
             preserved; see the note below). Look them up by name. *)
          let json = json_of_text bytes in
          let mem name obj =
            match obj with
            | Jsont.Object (fields, _) ->
                Option.map snd (Jsont.Json.find_mem name fields)
            | _ -> None
          in
          equal (option string) ~msg:"supported field updated"
            (Some "openai/new")
            (match mem "model" json with
            | Some (Jsont.String (v, _)) -> Some v
            | _ -> None);
          is_true ~msg:"top-level unknown retained"
            (match mem "unknown_top" json with
            | Some (Jsont.Number (n, _)) -> Float.equal n 1.
            | _ -> false);
          is_true ~msg:"section unknown retained inside its section"
            (match mem "run" json with
            | Some run -> (
                match mem "unknown_run" run with
                | Some (Jsont.Bool (b, _)) -> b
                | _ -> false)
            | None -> false));
      test "unknown-sibling serialization is deterministic" (fun () ->
          (* The plan preserves unknown members' values and nesting but not their
             sibling order: the .mli and RFC document value+nesting only. Rather
             than pin the exact reordered layout, which the .mli disclaims,
             assert only that the serialization is deterministic — writing the
             same plan twice yields byte-identical output. *)
          let original =
            {|{ "unknown_top": 1, "model": "openai/old", "another_unknown": 2, "run": { "unknown_run": true, "max_steps": 5 } }|}
          in
          let write () =
            plan_write
              (C.plan ~source:"config" ~original ~f:(fun d ->
                   C.set_text C.Field.model "openai/new" d))
          in
          equal string ~msg:"serialization is deterministic" (write ())
            (write ()));
      test "unsetting the last key removes the empty section" (fun () ->
          let bytes =
            plan_write
              (C.plan ~source:"config"
                 ~original:{|{ "run": { "max_steps": 5 } }|} ~f:(fun d ->
                   Ok (C.unset C.Field.run_max_steps d)))
          in
          equal string ~msg:"section removed" "{}" (String.trim bytes));
      test "unsetting a key keeps a section that still holds an unknown"
        (fun () ->
          let bytes =
            plan_write
              (C.plan ~source:"config"
                 ~original:{|{ "run": { "max_steps": 5, "foo": 1 } }|}
                 ~f:(fun d -> Ok (C.unset C.Field.run_max_steps d)))
          in
          equal string ~msg:"unknown keeps the section alive"
            {|{"run":{"foo":1}}|} (String.trim bytes));
      test
        "planning a permission-rule removal rewrites the rules, keeps siblings"
        (fun () ->
          (* The pure edit behind [permission remove]: reparse the file, drop the
             targeted rule, and [set_permission_rules] the survivors back through
             [plan]. The written bytes must re-parse to exactly the survivors
             while every unrelated member (an unknown key, another permission
             key) is preserved. *)
          let original =
            plan_write
              (C.plan ~source:"config"
                 ~original:
                   {|{ "permission": { "unattended": "deny" }, "unknown_top": 7 }|}
                 ~f:(fun d -> Ok (C.set_permission_rules [ rule_a; rule_b ] d)))
          in
          equal (list string) ~msg:"both rules present before removal"
            [ rule_id rule_a; rule_id rule_b ]
            (List.map rule_id (C.permission_rules (reparse original)));
          let bytes =
            plan_write
              (C.plan ~source:"config" ~original ~f:(fun d ->
                   let remaining =
                     List.filter
                       (fun r -> not (Rule.equal r rule_a))
                       (C.permission_rules d)
                   in
                   Ok (C.set_permission_rules remaining d)))
          in
          let reparsed = reparse bytes in
          equal (list string) ~msg:"only the surviving rule remains"
            [ rule_id rule_b ]
            (List.map rule_id (C.permission_rules reparsed));
          equal (option string) ~msg:"the other permission key survives"
            (Some "deny")
            (C.text C.Field.permission_unattended reparsed);
          is_true ~msg:"the unknown sibling survives"
            (match json_of_text bytes with
            | Jsont.Object (fields, _) ->
                Option.is_some (Jsont.Json.find_mem "unknown_top" fields)
            | _ -> false));
      test "provider families are written together, deterministically"
        (fun () ->
          let bytes =
            plan_write
              (C.plan ~source:"config" ~original:"{}" ~f:(fun d ->
                   let* d =
                     C.set_text
                       (C.Field.provider_base_url (Provider.make "openai"))
                       "https://o.example" d
                   in
                   C.set_text
                     (C.Field.provider_base_url (Provider.make "anthropic"))
                     "https://a.example" d))
          in
          equal string ~msg:"one providers object, both entries"
            {|{"providers":{"openai":{"base_url":"https://o.example"},"anthropic":{"base_url":"https://a.example"}}}|}
            (String.trim bytes);
          (* Round-trip: both providers survive the plan. *)
          let doc = reparse bytes in
          equal (option string) ~msg:"openai" (Some "https://o.example")
            (C.text (C.Field.provider_base_url (Provider.make "openai")) doc);
          equal (option string) ~msg:"anthropic" (Some "https://a.example")
            (C.text (C.Field.provider_base_url (Provider.make "anthropic")) doc));
      test "an empty original scaffolds a minimal object" (fun () ->
          let bytes =
            plan_write
              (C.plan ~source:"config" ~original:"" ~f:(fun d ->
                   C.set_text C.Field.model "openai/m" d))
          in
          equal string ~msg:"scaffolded" {|{"model":"openai/m"}|}
            (String.trim bytes));
      test "plan labels errors with its source" (fun () ->
          let err ~source original =
            match C.plan ~source ~original ~f:(fun d -> Ok d) with
            | Ok _ -> failf "expected an error"
            | Error e -> C.Error.message e
          in
          equal string ~msg:"a non-object original"
            "config must contain a JSON object"
            (err ~source:"config" "[]");
          equal string ~msg:"the source labels a non-object original"
            "cfg.json must contain a JSON object"
            (err ~source:"cfg.json" "[]");
          equal string ~msg:"the source labels a malformed field"
            "cfg.json run.max_steps must be an integer"
            (err ~source:"cfg.json" {|{ "run": { "max_steps": "x" } }|});
          is_true ~msg:"malformed JSON fails loudly"
            (Result.is_error
               (C.plan ~source:"config" ~original:"not json" ~f:(fun d -> Ok d))));
      (let sample_gen =
         Gen.bind (opt selector_gen) (fun model ->
             Gen.bind
               (opt (Gen.int_range 1 1000))
               (fun steps ->
                 Gen.map
                   (fun thinking -> (model, steps, thinking))
                   (opt (Gen.of_list [ true; false ]))))
       in
       let apply (model, steps, thinking) d =
         let* d =
           match model with
           | None -> Ok d
           | Some m -> C.set_text C.Field.model m d
         in
         let* d =
           match steps with
           | None -> Ok d
           | Some n -> C.set_text C.Field.run_max_steps (string_of_int n) d
         in
         match thinking with
         | None -> Ok d
         | Some b -> C.set_text C.Field.tui_thinking (string_of_bool b) d
       in
       let original_of sample =
         match C.plan ~source:"config" ~original:"" ~f:(apply sample) with
         | Ok (C.Plan.Write b) -> b
         | Ok C.Plan.Unchanged -> ""
         | Error e -> failf "orig: %s" (C.Error.message e)
       in
       let sample_gen =
         Gen.with_pp
           (fun ppf (m, s, t) ->
             Format.fprintf ppf "(%s, %s, %s)"
               (Option.value m ~default:"-")
               (Option.fold ~none:"-" ~some:string_of_int s)
               (Option.fold ~none:"-" ~some:string_of_bool t))
           sample_gen
       in
       group "edit planning properties"
         [
           prop "a no-op edit is always Unchanged" sample_gen (fun sample ->
               let original = original_of sample in
               match C.plan ~source:"config" ~original ~f:(fun d -> Ok d) with
               | Ok C.Plan.Unchanged -> ()
               | Ok (C.Plan.Write b) -> failf "expected Unchanged, got %s" b
               | Error e -> failf "plan: %s" (C.Error.message e));
           prop "any Write re-parses to f's output"
             (Gen.pair sample_gen selector_gen) (fun (sample, fresh) ->
               let original = original_of sample in
               let f d = C.set_text C.Field.model fresh d in
               match C.plan ~source:"config" ~original ~f with
               | Error e -> failf "plan: %s" (C.Error.message e)
               | Ok C.Plan.Unchanged ->
                   (* model already equals [fresh]. *)
                   ()
               | Ok (C.Plan.Write bytes) ->
                   let old_doc =
                     match C.of_text ~source:"config" original with
                     | Ok d -> d
                     | Error e -> failf "%s" (C.Error.message e)
                   in
                   let expected =
                     match f old_doc with
                     | Ok d -> d
                     | Error e -> failf "%s" (C.Error.message e)
                   in
                   is_true ~msg:"reparse equals f's output"
                     (C.equal (reparse bytes) expected));
         ]);
    ]

(* 7. resolve end to end. *)

let resolve_end_to_end =
  group "resolve end to end"
    [
      test
        "fixed docs, env, overrides, and a trusted workspace resolve to \
         effective values, origins, warnings, and rule groups" (fun () ->
          let user_doc =
            C.set_permission_rules [ rule_c ]
              (doc_exn
                 (nested "model" (js "user/m")
                 @ nested "run.max_steps" (ji 50)
                 @ nested "reasoning" (js "low")))
          in
          let project_doc =
            C.set_permission_rules [ rule_a ]
              (doc_exn
                 (nested "model" (js "proj/m")
                 @ nested "tui.thinking" (jb false)
                 @ nested "run.max_steps" (ji 100)))
          in
          let env = function
            | "MENTAT_SANDBOX_MODE" -> Some "workspace-write"
            | _ -> None
          in
          let ws =
            C.Trusted
              {
                project = C.Loaded (project_path, project_doc);
                project_local = C.Absent;
              }
          in
          let r =
            resolve_exn ~env ~user:(user_path, user_doc) ~workspace:ws
              ~overrides:[ patch1 C.Field.reasoning "high" ]
              ()
          in
          (* Effective values across every layer kind. *)
          equal (option string) ~msg:"workspace shared key wins over user"
            (Some "proj/m")
            (C.Resolved.text C.Field.model r);
          equal (option string) ~msg:"override wins over user reasoning"
            (Some "high")
            (C.Resolved.text C.Field.reasoning r);
          equal (option string) ~msg:"env sets sandbox.mode"
            (Some "workspace-write")
            (C.Resolved.text C.Field.sandbox_mode r);
          equal (option int) ~msg:"budget clamped to the user value" (Some 50)
            (C.Resolved.configured C.Field.run_max_steps r);
          (* Origins point at the winning layer. *)
          (match C.Resolved.origin C.Field.model r with
          | Some o ->
              equal source ~msg:"model origin is the project file" project_src
                (C.Origin.source o);
              equal (list string) ~msg:"shadowing the user file"
                [ source_str user_src ]
                (List.map source_str (C.Origin.shadowed o))
          | None -> failf "expected a model origin");
          (match C.Resolved.origin C.Field.sandbox_mode r with
          | Some o ->
              equal source ~msg:"sandbox.mode origin is the env var"
                (C.Source.Env { name = "MENTAT_SANDBOX_MODE" })
                (C.Origin.source o)
          | None -> failf "expected a sandbox.mode origin");
          (* Only the user layer's rules survive; the workspace rules are gone. *)
          equal (list string) ~msg:"rule groups: user only"
            [ source_str user_src ]
            (List.map
               (fun (s, _) -> source_str s)
               (C.Resolved.permission_rules r));
          (* Warnings enumerate every dropped workspace input. *)
          let ws_warnings = C.Resolved.warnings r in
          equal int ~msg:"three workspace warnings" 3 (List.length ws_warnings);
          is_true ~msg:"a stripped-key warning"
            (List.exists is_ignored_key ws_warnings);
          is_true ~msg:"a stripped-rules warning"
            (List.exists is_ignored_rules ws_warnings);
          is_true ~msg:"a clamped-budget warning"
            (List.exists is_ignored_budget ws_warnings));
      test "the one hard error: web.timeout_ms exceeding web.max_timeout_ms"
        (fun () ->
          let user_doc = doc_exn (nested "web.timeout_ms" (ji 200000)) in
          match
            C.resolve ~env:no_env ~user:(user_path, user_doc) ~extra:None
              ~workspace_config:disabled ~overrides:[]
          with
          | Ok _ -> failf "expected a cross-field error"
          | Error e ->
              equal string ~msg:"exact message"
                "web.timeout_ms must not exceed web.max_timeout_ms"
                (C.Error.message e));
      test "a non-workspace layer alone can satisfy the cross-field bound"
        (fun () ->
          (* Raising max alongside timeout keeps resolve happy. *)
          let user_doc =
            doc_exn
              [
                ( "web",
                  jo
                    [ ("timeout_ms", ji 200000); ("max_timeout_ms", ji 300000) ]
                );
              ]
          in
          match
            C.resolve ~env:no_env ~user:(user_path, user_doc) ~extra:None
              ~workspace_config:disabled ~overrides:[]
          with
          | Ok r ->
              equal (option string) ~msg:"timeout is honored" (Some "200000")
                (C.Resolved.text C.Field.web_timeout_ms r)
          | Error e -> failf "unexpected error: %s" (C.Error.message e));
    ]

(* 8. Snapshot: reads never re-consult the environment. *)

let snapshot =
  group "resolved is a snapshot"
    [
      test "defaults and env layers are baked at resolve time" (fun () ->
          (* Hand [resolve] a live, mutable env getter, then mutate its backing
             store, to prove reads are frozen at resolve time. *)
          let tbl = Hashtbl.create 8 in
          Hashtbl.replace tbl "SHELL" "/bin/from-resolve";
          Hashtbl.replace tbl "MENTAT_SANDBOX_MODE" "read-only";
          let env name = Hashtbl.find_opt tbl name in
          let r = resolve_exn ~env ~user:(user_path, C.empty) () in
          let shell_before = C.Resolved.text C.Field.shell r in
          let mode_before = C.Resolved.text C.Field.sandbox_mode r in
          let shell_origin_before =
            Option.map
              (fun o -> source_str (C.Origin.source o))
              (C.Resolved.origin C.Field.shell r)
          in
          (* Mutate the backing store after the snapshot was taken. *)
          Hashtbl.replace tbl "SHELL" "/bin/changed";
          Hashtbl.replace tbl "MENTAT_SANDBOX_MODE" "danger-full-access";
          equal (option string) ~msg:"shell default frozen at resolve"
            (Some "/bin/from-resolve") shell_before;
          equal (option string) ~msg:"shell read is stable after env mutation"
            shell_before
            (C.Resolved.text C.Field.shell r);
          equal (option string) ~msg:"env-layer value frozen at resolve"
            (Some "read-only") mode_before;
          equal (option string) ~msg:"env read is stable after env mutation"
            mode_before
            (C.Resolved.text C.Field.sandbox_mode r);
          equal (option string) ~msg:"origin is stable after env mutation"
            shell_origin_before
            (Option.map
               (fun o -> source_str (C.Origin.source o))
               (C.Resolved.origin C.Field.shell r)));
    ]

(* 9. Codec round-trips. *)

let codecs =
  group "codec round-trips"
    [
      test "Source.jsont round-trips every constructor" (fun () ->
          List.iter
            (fun s ->
              equal source
                ~msg:("round-trips " ^ source_str s)
                s
                (jsont_roundtrip C.Source.jsont s))
            [
              user_src;
              project_src;
              project_local_src;
              extra_src;
              C.Source.Env { name = "MENTAT_MODEL" };
              C.Source.Override;
              C.Source.Default { reason = "built-in shell" };
            ]);
      test "Source.kind_string is the stable short kind" (fun () ->
          equal (list string) ~msg:"kinds"
            [
              "user";
              "project";
              "project-local";
              "extra";
              "env";
              "override";
              "default";
            ]
            (List.map C.Source.kind_string
               [
                 user_src;
                 project_src;
                 project_local_src;
                 extra_src;
                 C.Source.Env { name = "X" };
                 C.Source.Override;
                 C.Source.Default { reason = "r" };
               ]));
      test "Origin.jsont round-trips a winning source with shadows" (fun () ->
          let r =
            resolve_exn
              ~user:(user_path, doc_exn (nested "model" (js "user/m")))
              ~extra:
                (Some (extra_path, doc_exn (nested "model" (js "extra/m"))))
              ~overrides:[ patch1 C.Field.model "over/m" ]
              ()
          in
          match C.Resolved.origin C.Field.model r with
          | None -> failf "expected an origin"
          | Some o ->
              let o' = jsont_roundtrip C.Origin.jsont o in
              equal source ~msg:"source survives" (C.Origin.source o)
                (C.Origin.source o');
              equal (list string) ~msg:"shadowed survives"
                (List.map source_str (C.Origin.shadowed o))
                (List.map source_str (C.Origin.shadowed o')));
      test "Warning.diagnostic renders the message with source attribution"
        (fun () ->
          let r =
            resolve_exn
              ~user:(user_path, doc_exn (nested "model" (js "user/m")))
              ~workspace:
                (C.Disabled
                   {
                     status = "untrusted";
                     project = Some project_path;
                     project_local = None;
                   })
              ()
          in
          match C.Resolved.warnings r with
          | [ w ] ->
              let rendered =
                Mentat_diagnostic.to_string (C.Warning.diagnostic w)
              in
              is_true ~msg:"primary line is the message"
                (String.starts_with ~prefix:(C.Warning.message w) rendered);
              is_true ~msg:"context names the source file"
                (String.includes
                   ~affix:("project: " ^ Lpath.Abs.to_string project_path)
                   rendered)
          | ws -> failf "expected one warning, got %d" (List.length ws));
      test "Warning.jsont round-trips each warning kind" (fun () ->
          (* Collect one of each producible warning kind through resolve. *)
          let user_doc = doc_exn (nested "run.max_steps" (ji 50)) in
          let stripped_doc =
            C.set_permission_rules [ rule_a ]
              (doc_exn
                 (nested "tui.thinking" (jb false)
                 @ nested "run.max_steps" (ji 100)))
          in
          let trusted =
            resolve_exn ~user:(user_path, user_doc)
              ~workspace:
                (C.Trusted
                   {
                     project = C.Loaded (project_path, stripped_doc);
                     project_local = C.Absent;
                   })
              ()
          in
          let invalid =
            resolve_exn ~user:(user_path, user_doc)
              ~workspace:
                (C.Trusted
                   {
                     project =
                       C.Invalid (project_path, "malformed workspace config");
                     project_local = C.Absent;
                   })
              ()
          in
          let disabled_r =
            resolve_exn ~user:(user_path, user_doc)
              ~workspace:
                (C.Disabled
                   {
                     status = "untrusted";
                     project = Some project_path;
                     project_local = None;
                   })
              ()
          in
          let warnings =
            C.Resolved.warnings trusted
            @ C.Resolved.warnings invalid
            @ C.Resolved.warnings disabled_r
          in
          is_true ~msg:"exercises every warning kind" (List.length warnings >= 5);
          List.iter
            (fun w ->
              let w' = jsont_roundtrip C.Warning.jsont w in
              equal string ~msg:"kind survives" (C.Warning.kind_string w)
                (C.Warning.kind_string w');
              equal string ~msg:"message survives" (C.Warning.message w)
                (C.Warning.message w');
              equal (option string) ~msg:"field survives"
                (field_name_opt (C.Warning.field w))
                (field_name_opt (C.Warning.field w'));
              is_true ~msg:"source survives"
                (source_equal (C.Warning.source w) (C.Warning.source w')))
            warnings);
    ]

(* The values-with-origins view. A base URL is the one config value that can
   embed userinfo credentials; the sentinel stands in for such a secret so a
   leak would be visible on the wire. *)

let sentinel = "https://tok3n-SECRET-sentinel@api.example.test/v1"

(* A resolved config carrying a credential-bearing [base_url], a plain [base_url]
   with nothing to hide, an API key, and a plain scalar, so the view has a
   withheld entry, a partly-shown one, and two verbatim ones. *)
let secret_resolved () =
  let user =
    C.empty
    |> set_exn (C.Field.provider_base_url (Provider.make "openai")) sentinel
    |> set_exn
         (C.Field.provider_base_url (Provider.make "ollama"))
         "http://127.0.0.1:11434"
    |> set_exn C.Field.web_exa_api_key "exa-SECRET-sentinel"
    |> set_exn C.Field.run_max_steps "7"
  in
  resolve_exn ~user:(user_path, user) ()

let rules_resolved () =
  let user = C.set_permission_rules [ rule_a ] C.empty in
  let extra = C.set_permission_rules [ rule_b; rule_c ] C.empty in
  resolve_exn ~user:(user_path, user) ~extra:(Some (extra_path, extra)) ()

let encode_view view =
  match Jsont_bytesrw.encode_string C.Resolved.View.jsont view with
  | Ok s -> s
  | Error m -> failf "encode view: %s" m

let decode_view s =
  match Jsont_bytesrw.decode_string C.Resolved.View.jsont s with
  | Ok v -> v
  | Error m -> failf "decode view: %s" m

let entry_for key view =
  List.find_opt
    (fun e -> String.equal (C.Resolved.View.Entry.key e) key)
    (C.Resolved.View.entries view)

let rule_row_json ~id ~rule ~source =
  jo [ ("id", js id); ("rule", rule_json rule); ("source", source_json source) ]

let permission_rule_row =
  Testable.make ~pp:C.Resolved.View.Permission_rule.pp
    ~equal:C.Resolved.View.Permission_rule.equal

let rule_row_decode_rejected json =
  Result.is_error (Jsont.Json.decode C.Resolved.View.Permission_rule.jsont json)

let resolved_view =
  group "resolved view (values with origins)"
    [
      test "the view codec round-trips and preserves entry count" (fun () ->
          let view = C.Resolved.view (secret_resolved ()) in
          let s1 = encode_view view in
          let view' = decode_view s1 in
          let s2 = encode_view view' in
          is_true ~msg:"encode/decode/encode is stable" (String.equal s1 s2);
          equal int ~msg:"entry count preserved"
            (List.length (C.Resolved.View.entries view))
            (List.length (C.Resolved.View.entries view')));
      test
        "permission-rule rows preserve effective order, identity, rule, and \
         source" (fun () ->
          let rows =
            C.Resolved.View.permission_rules
              (C.Resolved.view (rules_resolved ()))
          in
          equal (list string) ~msg:"higher source first, then file order"
            [ rule_id rule_b; rule_id rule_c; rule_id rule_a ]
            (List.map
               (fun row ->
                 Rule.Id.to_string (C.Resolved.View.Permission_rule.id row))
               rows);
          equal (list string) ~msg:"each row retains its contributing source"
            [ source_str extra_src; source_str extra_src; source_str user_src ]
            (List.map
               (fun row ->
                 source_str (C.Resolved.View.Permission_rule.source row))
               rows);
          is_true ~msg:"each row retains the exact permission rule"
            (match rows with
            | [ b; c; a ] ->
                Rule.equal (C.Resolved.View.Permission_rule.rule b) rule_b
                && Rule.equal (C.Resolved.View.Permission_rule.rule c) rule_c
                && Rule.equal (C.Resolved.View.Permission_rule.rule a) rule_a
            | _ -> false));
      test "permission-rule rows round-trip through the complete view codec"
        (fun () ->
          let view = C.Resolved.view (rules_resolved ()) in
          let decoded = decode_view (encode_view view) in
          let expected = C.Resolved.View.permission_rules view in
          let actual = C.Resolved.View.permission_rules decoded in
          equal (list permission_rule_row)
            ~msg:"typed rows survive with exact rule and source" expected actual);
      test "permission-rule row codec rejects an id from a different rule"
        (fun () ->
          is_true ~msg:"mismatched owner id rejected"
            (rule_row_decode_rejected
               (rule_row_json ~id:(rule_id rule_a) ~rule:rule_b ~source:user_src)));
      test "permission-rule row codec rejects a non-durable source" (fun () ->
          is_true ~msg:"workspace source rejected"
            (rule_row_decode_rejected
               (rule_row_json ~id:(rule_id rule_a) ~rule:rule_a
                  ~source:project_src)));
      test "permission-rule row codec rejects presentation members" (fun () ->
          is_true ~msg:"unknown presentation member rejected"
            (rule_row_decode_rejected
               (jo
                  [
                    ("id", js (rule_id rule_a));
                    ("rule", rule_json rule_a);
                    ("source", source_json user_src);
                    ("presentation", js "remove");
                  ])));
      test "a credential is never emitted; the endpoint carrying it is"
        (fun () ->
          let view = C.Resolved.view (secret_resolved ()) in
          let s = encode_view view in
          is_false ~msg:"sentinel credential absent from the wire"
            (String.includes ~affix:"SECRET" s);
          let text key =
            match entry_for key view with
            | None -> failf "%s entry missing from the view" key
            | Some e -> (
                match C.Resolved.View.Entry.value e with
                | C.Resolved.View.Value.Shown { text; _ } -> Some text
                | C.Resolved.View.Value.Redacted -> None)
          in
          equal (option string) ~msg:"an API key is withheld whole" None
            (text "web.exa_api_key");
          equal (option string) ~msg:"a base URL keeps its endpoint"
            (Some "https://[REDACTED]@api.example.test/v1")
            (text "providers.openai.base_url");
          equal (option string) ~msg:"a base URL with no userinfo is verbatim"
            (Some "http://127.0.0.1:11434")
            (text "providers.ollama.base_url");
          equal (option string) ~msg:"plain field shows its value" (Some "7")
            (text "run.max_steps"));
    ]

(* The notify vocabulary is owned by config and read back typed by the TUI
   reducer, so its enums must round-trip and reject out-of-vocabulary spellings.
   The [values] list is the single source of accepted spellings. *)
let notify_vocabulary =
  let module N = C.Notify in
  let roundtrips name values of_string to_string =
    test name (fun () ->
        List.iter
          (fun spelling ->
            match of_string spelling with
            | Some value ->
                equal string
                  ~msg:(spelling ^ " round-trips")
                  spelling (to_string value)
            | None -> failf "%s: %S did not parse" name spelling)
          values;
        is_true
          ~msg:(name ^ " rejects an out-of-vocabulary spelling")
          (Option.is_none (of_string "not-a-valid-spelling")))
  in
  group "notify vocabulary"
    [
      roundtrips "channel spellings round-trip" N.Channel.values
        N.Channel.of_string N.Channel.to_string;
      roundtrips "focus-policy spellings round-trip" N.When.values
        N.When.of_string N.When.to_string;
      roundtrips "event spellings round-trip" N.Event.values N.Event.of_string
        N.Event.to_string;
    ]

let () =
  run "mentat.config"
    [
      field_vocabulary;
      notify_vocabulary;
      parser_valid;
      parser_errors;
      parser_validate;
      typed_surface;
      precedence;
      workspace;
      edit_planning;
      resolve_end_to_end;
      snapshot;
      codecs;
      resolved_view;
    ]
