(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Public-boundary integration tests for [ocaml_docs]. Effectful cases cross
   the provider decoder, cached permissions, erased result/output boundary,
   workspace capability, and real child-process supervisor. One scripted
   executable stands in for Dune, Merlin, and ocamlfind; it records each
   process's exact cwd, argv, stdin, and private-environment properties before
   returning deterministic protocol data.

   Coverage retained from the legacy suite: interface and implementation path
   outlines, nested depth, pagination continuation, path error classes, strict
   provider decoding, permission planning, name-form project resolution, and
   multi-token Merlin program prefixes. Fresh Dune describe on every name query
   replaces the removed snapshot/freshness split.

   Coverage added here: safe-integer and product bounds; compact semantic
   validation; exact private child transport for all three backends; parser to
   Merlin fallback; malformed, duplicate, exit, signal, output-limit,
   incomplete-capture, timeout, launch, and cancellation paths; workspace,
   locked [.pkg], and admitted-switch provenance; scopes, ambiguity, unknown
   member recovery, toolchain exclusions, symlink no-follow, post-describe
   disappearance, non-UTF-8 and size limits; D2-safe durable replay; and
   constructor invariants. *)

open Windtrap
open Test_tools_support
module Access = Mentat_permission.Access
module Docs = Mentat_tools.Ocaml.Docs
module Json = Jsont.Json
module Permission = Mentat_permission
module Tool = Mentat_tool
module Wio = Mentat_workspace_io
module Workspace = Mentat_workspace

type world_base = {
  sw : Eio.Switch.t;
  ws_dir : string;
  outside_dir : string;
  switch_dir : string;
  plan_dir : string;
  fake : string;
  io : Wio.t;
}

type world = { base : world_base; tool : Tool.t }

let sw world = world.base.sw
let ws_dir world = world.base.ws_dir
let outside_dir world = world.base.outside_dir
let switch_dir world = world.base.switch_dir
let plan_dir world = world.base.plan_dir

let add_optional name encode value fields =
  match value with
  | None -> fields
  | Some value -> fields @ [ (name, encode value) ]

let input ?scope ?package ?depth ?offset ?limit ?max_source_bytes query =
  [ ("query", Json.string query) ]
  |> add_optional "scope" (fun value -> Json.string value) scope
  |> add_optional "package" (fun value -> Json.string value) package
  |> add_optional "depth" (fun value -> Json.int value) depth
  |> add_optional "offset" (fun value -> Json.int value) offset
  |> add_optional "limit" (fun value -> Json.int value) limit
  |> add_optional "max_source_bytes"
       (fun value -> Json.int value)
       max_source_bytes
  |> json_object

let semantic_exn result =
  match
    Mentat_tools_output.Codec.decode Mentat_tools_output.Ocaml.Docs.jsont
      (output_exn result)
  with
  | Some semantic -> semantic
  | None -> fail "ocaml_docs output carried no Docs semantics"

let print_status ?(normalize = Fun.id) result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> print_endline "status: completed"
  | Tool.Result.Failed { kind; message; metadata } ->
      Printf.printf "status: failed %s\nmessage: %s\nmetadata: %b\n"
        (failure_name kind) (normalize message) (Option.is_some metadata)
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "status: interrupted cancelled=%b\nreason: %s\n" cancelled
        reason

let decode_call_result tool provider_input =
  Tool.Call.decode tool (model_call tool provider_input)

let decode_call tool provider_input =
  match decode_call_result tool provider_input with
  | Ok call -> call
  | Error error ->
      failf "call decode failed: %s" (Tool.Call.Decode_error.message error)

let run ?(cancelled = fun () -> false) world provider_input =
  Tool.Call.run (decode_call world.tool provider_input) ~cancelled |> finished

let write_disk path contents =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel contents)

let fake_program =
  String.concat "\n"
    [
      "#!/bin/sh";
      "plan=$1";
      "kind=$2";
      "shift 2";
      "count_file=$plan/$kind-count";
      "if [ -f \"$count_file\" ]; then n=$(cat \"$count_file\"); else n=0; fi";
      "n=$((n + 1))";
      "printf '%s' \"$n\" > \"$count_file\"";
      "pwd > \"$plan/$kind-cwd-$n\"";
      "printf '%s\\n' \"$@\" > \"$plan/$kind-argv-$n\"";
      "cat > \"$plan/$kind-stdin-$n\"";
      "if [ \"$HOME\" = \"$TMPDIR\" ]; then shared=yes; else shared=no; fi";
      "printf 'scratch=%s\\nsecret=%s\\n' \"$shared\" \
       \"${MENTAT_DOCS_EXPECT_SECRET-unset}\" > \"$plan/$kind-env-$n\"";
      "behavior=response";
      "if [ -f \"$plan/$kind-behavior-$n\" ]; then behavior=$(cat \
       \"$plan/$kind-behavior-$n\"); fi";
      ": > \"$plan/$kind-started-$n\"";
      "response=$plan/$kind-response-$n";
      "case \"$behavior\" in";
      "  response) [ ! -f \"$response\" ] || cat \"$response\" ;;";
      "  remove_source) rm \"$(cat \"$plan/$kind-remove-$n\")\"; cat \
       \"$response\" ;;";
      "  exit7) printf '\\033[31mbackend failed\\033[0m\\n' >&2; exit 7 ;;";
      "  invalid_exit) printf '\\377bad\\033]0;secret\\007 detail\\n' >&2; \
       exit 9 ;;";
      "  signal) kill -TERM $$ ;;";
      "  overflow) exec /usr/bin/yes x ;;";
      "  sleep) exec /bin/sleep 60 ;;";
      "  incomplete) ( /bin/sleep 3 ) & [ ! -f \"$response\" ] || cat \
       \"$response\" ;;";
      "  *) printf 'unknown behavior: %s\\n' \"$behavior\" >&2; exit 64 ;;";
      "esac";
      "";
    ]

let api_source =
  "(** Demo library synopsis. *)\n\n\
   (** The answer. *)\n\
   val answer : int\n\n\
   type t = A\n\n\
   exception Boom\n\n\
   module Nested : sig\n\
   val inside : string\n\
   type inner\n\
   end\n\n\
   module type S = sig val x : int end\n\n\
   class type c = object method m : int end\n\n\
   class d : object method m : int end\n"

let abs path = Lpath.Abs.of_string_exn path
let key name = Workspace.Root.Key.of_string_exn name

let workspace ws_dir switch_dir =
  let primary = Workspace.Root.make ~key:(key "main") (abs ws_dir) in
  let switch = Workspace.Root.make ~key:(key "switch") (abs switch_dir) in
  let cwd = Workspace.Path.make ~root_key:(key "main") Lpath.Rel.root in
  match Workspace.make ~cwd ~primary ~read_only:[ switch ] () with
  | Ok workspace -> workspace
  | Error error ->
      failf "workspace construction failed: %a" Workspace.Error.pp error

let make_tool world ?(merlin_program = [ world.fake; world.plan_dir; "merlin" ])
    ?(dune_program = [ world.fake; world.plan_dir; "dune" ])
    ?(ocamlfind_program = [ world.fake; world.plan_dir; "ocamlfind" ])
    ?opam_switch_prefix clock =
  Docs.make world.io ~clock ~merlin_program ~dune_program ~ocamlfind_program
    ~opam_switch_prefix ()

let with_world_using ~clock ?(switch = true) name fn =
  Eio_main.run @@ fun stdenv ->
  let stdenv = (stdenv :> Eio_unix.Stdenv.base) in
  let base = Unix.realpath (temp_dir ~prefix:("mentat-docs-" ^ name) ()) in
  let ws_dir = Filename.concat base "workspace" in
  let outside_dir = Filename.concat base "outside" in
  let switch_dir = Filename.concat base "switch" in
  let tmp_dir = Filename.concat base "tmp" in
  let plan_dir = Filename.concat ws_dir ".docs-plan" in
  List.iter mkdir [ ws_dir; outside_dir; switch_dir; tmp_dir; plan_dir ];
  write_disk (Filename.concat ws_dir "api.mli") api_source;
  write_disk
    (Filename.concat ws_dir "impl.ml")
    "let answer = 42\nmodule Nested = struct let inside = \"x\" end\n";
  write_disk (Filename.concat ws_dir "broken.ml") "let answer =\n";
  write_disk (Filename.concat ws_dir "binary.ml") "let x = \255\n";
  write_disk (Filename.concat ws_dir "small.ml") "let x = 1\n";
  write_disk (Filename.concat ws_dir "lib/demo/demo.mli") api_source;
  write_disk
    (Filename.concat ws_dir "_build/.pkg/dep.1.2-hash123/target/dep.mli")
    "(** Dependency synopsis. *)\nval dependency : int\n";
  write_disk
    (Filename.concat switch_dir "lib/dep/dep.mli")
    "(** Switch synopsis. *)\nval from_switch : string\n";
  Unix.symlink "api.mli" (Filename.concat ws_dir "inside-link.mli");
  Unix.symlink
    (Filename.concat outside_dir "escape.mli")
    (Filename.concat ws_dir "escape-link.mli");
  write_disk (Filename.concat outside_dir "escape.mli") "val escaped : int\n";
  let fake = Filename.concat ws_dir "fake-toolchain" in
  install_executable fake fake_program;
  setenv "TMPDIR" (Some tmp_dir);
  setenv "MENTAT_DOCS_EXPECT_SECRET" (Some "hidden");
  Eio.Switch.run @@ fun sw ->
  let logical = workspace ws_dir switch_dir in
  let io = resolve_exn ~sw ~stdenv ~logical () in
  let base = { sw; ws_dir; outside_dir; switch_dir; plan_dir; fake; io } in
  let clock = clock stdenv in
  let opam_switch_prefix = if switch then Some switch_dir else None in
  let tool = make_tool base ?opam_switch_prefix clock in
  fn { base; tool }

let with_world ?switch name fn =
  with_world_using ?switch ~clock:Eio.Stdenv.mono_clock name fn

let plan_file world kind stem index =
  Filename.concat (plan_dir world) (Printf.sprintf "%s-%s-%d" kind stem index)

let set_response world kind index response =
  write_disk (plan_file world kind "response" index) response

let set_behavior world kind index behavior =
  write_disk (plan_file world kind "behavior" index) behavior

let invocation world kind stem index =
  read_disk (plan_file world kind stem index)

let invocation_count world kind =
  match read_disk (Filename.concat (plan_dir world) (kind ^ "-count")) with
  | text -> int_of_string text
  | exception Sys_error _ -> 0

let normalize world text =
  text
  |> String.replace_all ~sub:(outside_dir world) ~by:"<outside>"
  |> String.replace_all ~sub:(switch_dir world) ~by:"<switch>"
  |> String.replace_all ~sub:(ws_dir world) ~by:"<workspace>"

let print_result ?(text = true) world result =
  print_status ~normalize:(normalize world) result;
  match Tool.Result.output result with
  | None -> ()
  | Some output ->
      let semantic = semantic_exn result in
      Printf.printf "counts: values=%d types=%d modules=%d truncated=%b\n"
        (Mentat_tools_output.Ocaml.Docs.values semantic)
        (Mentat_tools_output.Ocaml.Docs.types semantic)
        (Mentat_tools_output.Ocaml.Docs.modules semantic)
        (Tool.Output.truncated output);
      if text then
        Printf.printf "text: %S\n" (normalize world (Tool.Output.text output));
      Printf.printf "json: %s\n"
        (Tool.Output.json output |> Option.map json_string
        |> Option.value ~default:"none")

let decode_verdict tool label provider_input =
  match decode_call_result tool provider_input with
  | Ok call ->
      Printf.printf "%s: accepted canonical=%s\n" label
        (json_string (Tool.Call.input call))
  | Error error ->
      Printf.printf "%s: rejected diagnostic=%b\n" label
        (not (String.is_empty (Tool.Call.Decode_error.message error)))

let local_workspace_output world =
  Printf.sprintf
    {|((root %s)
 (build_context _build/default)
 (library
  ((name demo)
   (uid uid-demo)
   (local true)
   (requires ())
   (source_dir lib/demo)
   (modules
    (((name Demo) (impl ()) (intf lib/demo/demo.mli) (cmt ()) (cmti ()))))
   (include_dirs (_build/default/lib/demo)))))
|}
    (ws_dir world)

let external_workspace_output world ~source =
  Printf.sprintf
    {|((root %s)
 (build_context _build/default)
 (library
  ((name dep)
   (uid uid-dep)
   (local false)
   (requires ())
   (source_dir %s)
   (modules (((name Dep) (impl ()) (intf %s) (cmt ()) (cmti ()))))
   (include_dirs ()))))
|}
    (ws_dir world) (Filename.dirname source) source

let ambiguous_workspace_output world =
  {|((root ROOT)
 (build_context _build/default)
 (library
  ((name demo)
   (uid uid-local-demo)
   (local true)
   (requires ())
   (source_dir lib/demo)
   (modules
    (((name Demo) (impl ()) (intf lib/demo/demo.mli) (cmt ()) (cmti ()))))
   (include_dirs ())))
 (library
  ((name demo)
   (uid uid-external-demo)
   (local false)
   (requires ())
   (source_dir _build/.pkg/demo.1.0-hash/target)
   (modules
    (((name Demo)
      (impl ())
      (intf _build/.pkg/demo.1.0-hash/target/demo.mli)
      (cmt ())
      (cmti ()))))
   (include_dirs ()))))
|}
  |> String.replace_all ~sub:"ROOT" ~by:(ws_dir world)

let%expect_test "compact semantic is validated and closed" =
  let module Semantic = Mentat_tools_output.Ocaml.Docs in
  let semantic = Semantic.make ~values:2 ~types:3 ~modules:4 in
  let json = encode Semantic.jsont semantic in
  Printf.printf "counts: %d/%d/%d\njson: %s\n" (Semantic.values semantic)
    (Semantic.types semantic)
    (Semantic.modules semantic)
    (json_string json);
  List.iter
    (fun (label, make) ->
      Printf.printf "%s: %s\n" label
        (match make () with
        | _ -> "accepted"
        | exception Invalid_argument _ -> "rejected"))
    [
      ( "negative values",
        fun () -> Semantic.make ~values:(-1) ~types:0 ~modules:0 );
      ( "negative types",
        fun () -> Semantic.make ~values:0 ~types:(-1) ~modules:0 );
      ( "negative modules",
        fun () -> Semantic.make ~values:0 ~types:0 ~modules:(-1) );
    ];
  let decodes json =
    Option.is_some (Json.decode Semantic.jsont json |> Result.to_option)
  in
  Printf.printf "roundtrip: %b unknown: %b version: %b negative: %b\n"
    (decodes json)
    (decodes
       (json_object
          [
            ("version", Json.int 1);
            ("values", Json.int 0);
            ("types", Json.int 0);
            ("modules", Json.int 0);
            ("extra", Json.int 0);
          ]))
    (decodes
       (json_object
          [
            ("version", Json.int 2);
            ("values", Json.int 0);
            ("types", Json.int 0);
            ("modules", Json.int 0);
          ]))
    (decodes
       (json_object
          [
            ("version", Json.int 1);
            ("values", Json.int (-1));
            ("types", Json.int 0);
            ("modules", Json.int 0);
          ]));
  [%expect
    {|
    counts: 2/3/4
    json: {"version":1,"values":2,"types":3,"modules":4}
    negative values: rejected
    negative types: rejected
    negative modules: rejected
    roundtrip: true unknown: false version: false negative: false
    |}]

let%expect_test "provider input is strict, bounded, and uses safe integers" =
  with_world "schema" @@ fun world ->
  let declaration = Tool.declaration world.tool in
  Printf.printf "name: %s\n" (Mentat_llm.Tool.name declaration);
  Printf.printf "schema: %s\n"
    (json_string (Mentat_llm.Tool.input_schema declaration));
  decode_verdict world.tool "minimal" (input "api.mli");
  decode_verdict world.tool "full"
    (input ~scope:"deps" ~package:"demo.pkg" ~depth:3 ~offset:4 ~limit:5
       ~max_source_bytes:4096 "Demo.Nested.answer");
  List.iter
    (fun (label, provider_input) ->
      decode_verdict world.tool label provider_input)
    [
      ("missing query", json_object []);
      ( "unknown member",
        json_object
          [ ("query", Json.string "api.mli"); ("path", Json.string "x") ] );
      ( "duplicate query",
        json_object
          [
            ("query", Json.string "api.mli"); ("query", Json.string "other.mli");
          ] );
      ("empty query", input "");
      ("NUL query", input "bad\000query");
      ("query type", json_object [ ("query", Json.int 1) ]);
      ("bad scope", input ~scope:"project" "demo");
      ("empty package", input ~package:"" "Demo");
      ("NUL package", input ~package:"bad\000package" "Demo");
      ("depth negative", input ~depth:(-1) "api.mli");
      ("offset zero", input ~offset:0 "api.mli");
      ("limit zero", input ~limit:0 "api.mli");
      ("limit high", input ~limit:1001 "api.mli");
      ("source zero", input ~max_source_bytes:0 "api.mli");
      ("source high", input ~max_source_bytes:8_388_609 "api.mli");
      ( "fraction",
        json_object
          [ ("query", Json.string "api.mli"); ("depth", Json.number 1.5) ] );
      ( "numeric string",
        json_object
          [ ("query", Json.string "api.mli"); ("offset", Json.string "1") ] );
      ( "unsafe integer",
        json_object
          [
            ("query", Json.string "api.mli");
            ("depth", Json.number 9_007_199_254_740_992.);
          ] );
      ( "infinity",
        json_object
          [
            ("query", Json.string "api.mli");
            ("offset", Json.number Float.infinity);
          ] );
    ];
  [%expect
    {|
    name: ocaml_docs
    schema: {"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"A workspace file path (has a / or ends in .ml/.mli), a findlib/local library name (lowercase, dotted), a capitalized module path, or a qualified identifier. The form is selected by the query's shape."},"scope":{"type":"string","minLength":1,"enum":["workspace","deps","any"],"description":"Name-form resolution universe. workspace restricts to local libraries, deps to dependencies, any (default) resolves against both and reports an ambiguity when a name matches both. Ignored for path-form queries."},"package":{"type":"string","minLength":1,"description":"findlib library hint that forces the containing library for a capitalized query whose root module does not match its library name."},"depth":{"type":"integer","minimum":0,"maximum":9007199254740991,"description":"Inline nested-module expansion depth. Defaults to 0 (nested module bodies collapse to a member count)."},"offset":{"type":"integer","minimum":1,"maximum":9007199254740991,"description":"1-based first preorder outline item to return. Defaults to 1."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum number of outline items to return. Defaults to 100."},"max_source_bytes":{"type":"integer","minimum":1,"maximum":8388608,"description":"Maximum accepted resolved source-file size in bytes. Defaults to 2097152."}},"required":["query"],"additionalProperties":false}
    minimal: accepted canonical={"query":"api.mli","scope":"any"}
    full: accepted canonical={"depth":3,"limit":5,"max_source_bytes":4096,"offset":4,"package":"demo.pkg","query":"Demo.Nested.answer","scope":"deps"}
    missing query: rejected diagnostic=true
    unknown member: rejected diagnostic=true
    duplicate query: rejected diagnostic=true
    empty query: rejected diagnostic=true
    NUL query: rejected diagnostic=true
    query type: rejected diagnostic=true
    bad scope: rejected diagnostic=true
    empty package: rejected diagnostic=true
    NUL package: rejected diagnostic=true
    depth negative: rejected diagnostic=true
    offset zero: rejected diagnostic=true
    limit zero: rejected diagnostic=true
    limit high: rejected diagnostic=true
    source zero: rejected diagnostic=true
    source high: rejected diagnostic=true
    fraction: rejected diagnostic=true
    numeric string: rejected diagnostic=true
    unsafe integer: rejected diagnostic=true
    infinity: rejected diagnostic=true
    |}]

let print_permissions call =
  let requests = Tool.Call.permissions call in
  Printf.printf "requests: %d\n" (List.length requests);
  List.iter
    (fun request ->
      Printf.printf "source: %s\n"
        (Option.value ~default:"none" (Permission.Request.source request));
      List.iter
        (function
          | Access.Path { op; scope = Access.Path_scope.Workspace path } ->
              Printf.printf "path: %s key=%s address=%s\n" (path_op_name op)
                (Workspace.Root.Key.to_string (Workspace.Path.root_key path))
                (Workspace.Path.display path)
          | Access.Custom { name; subject } ->
              Printf.printf "custom: name=%s subject=%s\n" name
                (Option.value ~default:"none" subject)
          | access -> failf "unexpected Docs permission: %a" Access.pp access)
        (Permission.Request.accesses request))
    requests

let%expect_test "permissions bind path or universe reads and are cached" =
  with_world "permissions" @@ fun world ->
  let path_call = decode_call world.tool (input "api.mli") in
  print_endline "-- path --";
  print_permissions path_call;
  print_endline "-- name --";
  print_permissions (decode_call world.tool (input "demo"));
  print_endline "-- unresolved path --";
  print_permissions (decode_call world.tool (input "../outside/nope.mli"));
  Unix.unlink (Filename.concat (ws_dir world) "api.mli");
  print_endline "-- cached after deletion --";
  print_permissions path_call;
  [%expect
    {|
    -- path --
    requests: 1
    source: ocaml_docs
    path: read key=main address=api.mli
    custom: name=command.confinement subject=direct
    -- name --
    requests: 1
    source: ocaml_docs
    path: read key=main address=.
    path: read key=switch address=lib
    custom: name=command.confinement subject=direct
    -- unresolved path --
    requests: 0
    -- cached after deletion --
    requests: 1
    source: ocaml_docs
    path: read key=main address=api.mli
    custom: name=command.confinement subject=direct
    |}]

let%expect_test "path outlines interface and implementation without children" =
  with_world "path-outline" @@ fun world ->
  print_endline "-- interface --";
  print_result world (run world (input "api.mli"));
  print_endline "-- implementation --";
  print_result world (run world (input "impl.ml"));
  Printf.printf "commands: dune=%d merlin=%d ocamlfind=%d\n"
    (invocation_count world "dune")
    (invocation_count world "merlin")
    (invocation_count world "ocamlfind");
  [%expect
    {|
    -- interface --
    status: completed
    counts: values=2 types=2 modules=3 truncated=false
    text: "workspace file api.mli\nlevel=file_outline source=api.mli interface_available=true\nitems=7/7 offset=1\n- value answer: val answer : int\n  doc: The answer.\n- type t: type t = A\n- exception Boom: exception Boom\n- module Nested: module Nested : sig ... end (2 members)\n- module_type S: module type S = sig ... end (1 members)\n- class_type c: class type c = object method m : int end\n- class d: class d : object method m : int end\n"
    json: {"version":1,"values":2,"types":2,"modules":3}
    -- implementation --
    status: completed
    counts: values=1 types=0 modules=1 truncated=false
    text: "workspace file impl.ml\nlevel=file_outline source=impl.ml interface_available=false\nitems=2/2 offset=1\n- value answer: let answer = 42\n- module Nested: module Nested : sig ... end (1 members)\n"
    json: {"version":1,"values":1,"types":0,"modules":1}
    commands: dune=0 merlin=0 ocamlfind=0
    |}]

let%expect_test
    "depth pagination and doc truncation remain in authoritative text" =
  with_world "bounds" @@ fun world ->
  print_endline "-- expanded page --";
  print_result world (run world (input ~depth:1 ~limit:2 "api.mli"));
  let long_doc = String.make (Docs.max_doc_bytes + 20) 'd' in
  write_disk
    (Filename.concat (ws_dir world) "long-doc.mli")
    (Printf.sprintf "(** %s *)\nval documented : int\n" long_doc);
  print_endline "-- truncated doc --";
  let truncated = run world (input "long-doc.mli") in
  print_status truncated;
  let output = output_exn truncated in
  let text = Tool.Output.text output in
  let extract_doc_payload text =
    let marker = " [truncated]" in
    let line =
      text |> String.split_on_char '\n'
      |> List.find (String.starts_with ~prefix:"  doc: ")
    in
    if not (String.ends_with ~suffix:marker line) then
      failf "missing truncated-doc marker in %S" line;
    String.sub line 7 (String.length line - 7 - String.length marker)
  in
  let doc_payload = extract_doc_payload text in
  Printf.printf "doc-marker=%b retained-bytes=%d output-truncated=%b json=%s\n"
    (String.includes ~affix:"[truncated]" text)
    (String.length doc_payload)
    (Tool.Output.truncated output)
    (Tool.Output.json output |> Option.map json_string
    |> Option.value ~default:"none");
  let utf8_doc = String.make (Docs.max_doc_bytes - 2) 'd' ^ "€" in
  write_disk
    (Filename.concat (ws_dir world) "utf8-doc.mli")
    (Printf.sprintf "(** %s *)\nval documented : int\n" utf8_doc);
  let utf8_output = run world (input "utf8-doc.mli") |> output_exn in
  let utf8_payload = extract_doc_payload (Tool.Output.text utf8_output) in
  Printf.printf "utf8-valid=%b retained-bytes=%d output-truncated=%b\n"
    (String.is_valid_utf_8 utf8_payload)
    (String.length utf8_payload)
    (Tool.Output.truncated utf8_output);
  [%expect
    {|
    -- expanded page --
    status: completed
    counts: values=1 types=1 modules=0 truncated=true
    text: "workspace file api.mli\nlevel=file_outline source=api.mli interface_available=true\nitems=2/10 offset=1\n- value answer: val answer : int\n  doc: The answer.\n- type t: type t = A\nnext: ocaml_docs {\"query\":\"api.mli\",\"scope\":\"any\",\"depth\":1,\"offset\":3,\"limit\":2}\n"
    json: {"version":1,"values":1,"types":1,"modules":0}
    -- truncated doc --
    status: completed
    doc-marker=true retained-bytes=499 output-truncated=true json={"version":1,"values":1,"types":0,"modules":0}
    utf8-valid=true retained-bytes=498 output-truncated=true
    |}]

let status_summary result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> "completed"
  | Tool.Result.Failed { kind; message; metadata } ->
      Printf.sprintf "failed:%s diagnostic=%b metadata=%b" (failure_name kind)
        (not (String.is_empty message))
        (Option.is_some metadata)
  | Tool.Result.Interrupted { cancelled; reason } ->
      Printf.sprintf "interrupted cancelled=%b diagnostic=%b" cancelled
        (not (String.is_empty reason))

let%expect_test "filesystem boundary rejects unsafe sources before children" =
  with_world "filesystem" @@ fun world ->
  mkdir (Filename.concat (ws_dir world) "directory");
  let cases =
    [
      ("missing", input "missing.mli");
      ("directory", input "directory/");
      ("outside", input "../outside/escape.mli");
      ("binary", input "binary.ml");
      ("oversize", input ~max_source_bytes:4 "small.ml");
      ("inside symlink", input "inside-link.mli");
      ("escape symlink", input "escape-link.mli");
    ]
  in
  List.iter
    (fun (label, provider_input) ->
      let result = run world provider_input in
      Printf.printf "%s: %s output=%b\n" label (status_summary result)
        (Option.is_some (Tool.Result.output result)))
    cases;
  Printf.printf "commands: dune=%d merlin=%d ocamlfind=%d\n"
    (invocation_count world "dune")
    (invocation_count world "merlin")
    (invocation_count world "ocamlfind");
  [%expect
    {|
    missing: failed:not_found diagnostic=true metadata=false output=false
    directory: failed:invalid_input diagnostic=true metadata=false output=false
    outside: failed:invalid_input diagnostic=true metadata=false output=false
    binary: failed:invalid_input diagnostic=true metadata=false output=false
    oversize: failed:invalid_input diagnostic=true metadata=false output=false
    inside symlink: completed output=true
    escape symlink: failed:invalid_input diagnostic=true metadata=false output=false
    commands: dune=0 merlin=0 ocamlfind=0
    |}]

let merlin_return value = Printf.sprintf {|{"class":"return","value":%s}|} value

let%expect_test "Merlin fallback receives exact source cwd argv and private env"
    =
  with_world "merlin-transport" @@ fun world ->
  set_response world "merlin" 1
    (merlin_return
       {|[{"name":"answer","kind":"Value","type":"int","deprecated":true},{"name":"Nested","kind":"Module","children":[{"name":"inside","kind":"Value","type":"string"}]}]|});
  let result = run world (input ~depth:1 "broken.ml") in
  print_result world result;
  Printf.printf "cwd: %s\n"
    (normalize world (String.trim (invocation world "merlin" "cwd" 1)));
  Printf.printf "argv: %S\n"
    (normalize world (invocation world "merlin" "argv" 1));
  Printf.printf "stdin exact: %b\nenv: %S\n"
    (String.equal (invocation world "merlin" "stdin" 1) "let answer =\n")
    (invocation world "merlin" "env" 1);
  [%expect
    {|
    status: completed
    counts: values=2 types=0 modules=1 truncated=false
    text: "workspace file broken.ml\nlevel=file_outline source=broken.ml interface_available=false\nitems=3/3 offset=1\n- value answer: int [deprecated]\n- module Nested: module Nested : sig ... end\n  - value Nested.inside: string\n"
    json: {"version":1,"values":2,"types":0,"modules":1}
    cwd: <workspace>
    argv: "single\noutline\n-filename\n<workspace>/broken.ml\n"
    stdin exact: true
    env: "scratch=no\nsecret=unset\n"
    |}]

let run_merlin_case label configure =
  with_world ("merlin-" ^ label) @@ fun world ->
  configure world;
  let result = run world (input "broken.ml") in
  Printf.printf "%s: %s output=%b\n" label (status_summary result)
    (Option.is_some (Tool.Result.output result))

let%expect_test "Merlin protocol and terminal failures stay distinct" =
  run_merlin_case "malformed" (fun world ->
      set_response world "merlin" 1 "not json");
  run_merlin_case "duplicate class" (fun world ->
      set_response world "merlin" 1
        {|{"class":"return","class":"return","value":[]}|});
  run_merlin_case "non-list value" (fun world ->
      set_response world "merlin" 1 (merlin_return {|{}|}));
  List.iter
    (fun behavior ->
      run_merlin_case behavior (fun world ->
          set_behavior world "merlin" 1 behavior))
    [ "exit7"; "invalid_exit"; "signal"; "overflow"; "incomplete" ];
  with_world "merlin-missing-program" @@ fun world ->
  let clock = Eio_mock.Clock.Mono.make () in
  let tool =
    make_tool world.base
      ~merlin_program:[ Filename.concat (ws_dir world) "missing-merlin" ]
      clock
  in
  let result =
    Tool.Call.run
      (decode_call tool (input "broken.ml"))
      ~cancelled:(fun () -> false)
    |> finished
  in
  Printf.printf "missing program: %s output=%b\n" (status_summary result)
    (Option.is_some (Tool.Result.output result));
  [%expect
    {|
    malformed: failed:invalid_input diagnostic=true metadata=false output=false
    duplicate class: failed:invalid_input diagnostic=true metadata=false output=false
    non-list value: failed:invalid_input diagnostic=true metadata=false output=false
    exit7: failed:invalid_input diagnostic=true metadata=false output=false
    invalid_exit: failed:invalid_input diagnostic=true metadata=false output=false
    signal: failed:invalid_input diagnostic=true metadata=false output=false
    overflow: failed:invalid_input diagnostic=true metadata=false output=false
    incomplete: failed:invalid_input diagnostic=true metadata=false output=false
    missing program: failed:invalid_input diagnostic=true metadata=false output=false
    |}]

let print_compact_result result =
  Printf.printf "%s" (status_summary result);
  match Tool.Result.output result with
  | None -> print_newline ()
  | Some output ->
      let semantic = semantic_exn result in
      Printf.printf " counts=%d/%d/%d truncated=%b\n"
        (Mentat_tools_output.Ocaml.Docs.values semantic)
        (Mentat_tools_output.Ocaml.Docs.types semantic)
        (Mentat_tools_output.Ocaml.Docs.modules semantic)
        (Tool.Output.truncated output)

let%expect_test "fresh Dune universe resolves library module focus and recovery"
    =
  with_world "dune-local" @@ fun world ->
  List.iter
    (fun index ->
      set_response world "dune" index (local_workspace_output world))
    [ 1; 2; 3; 4; 5 ];
  print_endline "-- library --";
  print_result world (run world (input "demo"));
  print_endline "-- module --";
  print_compact_result (run world (input "Demo.Nested"));
  print_endline "-- focus --";
  print_compact_result (run world (input "Demo.Nested.inside"));
  print_endline "-- unknown focus recovery --";
  let recovery = run world (input "Demo.Nested.missing") in
  print_compact_result recovery;
  Printf.printf "recovery members=%b\n"
    (Tool.Output.text (output_exn recovery)
    |> String.includes ~affix:"modules: inside inner");
  print_endline "-- unknown nested module recovery --";
  let nested_recovery = run world (input "Demo.Nested.Missing.answer") in
  print_compact_result nested_recovery;
  Printf.printf "nearest members=%b\n"
    (Tool.Output.text (output_exn nested_recovery)
    |> String.includes ~affix:"modules: inside inner");
  Printf.printf "cwd: %s\n"
    (normalize world (String.trim (invocation world "dune" "cwd" 1)));
  Printf.printf "argv: %S\nstdin-empty: %b\nenv: %S\n"
    (invocation world "dune" "argv" 1)
    (String.is_empty (invocation world "dune" "stdin" 1))
    (invocation world "dune" "env" 1);
  Printf.printf "commands: dune=%d merlin=%d ocamlfind=%d\n"
    (invocation_count world "dune")
    (invocation_count world "merlin")
    (invocation_count world "ocamlfind");
  [%expect
    {|
    -- library --
    status: completed
    counts: values=2 types=2 modules=3 truncated=false
    text: "workspace library demo\nlevel=library_overview source=lib/demo/demo.mli interface_available=true\nsynopsis: Demo library synopsis.\nmodules: Nested S\nitems=7/7 offset=1\n- value answer: val answer : int\n  doc: The answer.\n- type t: type t = A\n- exception Boom: exception Boom\n- module Nested: module Nested : sig ... end (2 members)\n- module_type S: module type S = sig ... end (1 members)\n- class_type c: class type c = object method m : int end\n- class d: class d : object method m : int end\n"
    json: {"version":1,"values":2,"types":2,"modules":3}
    -- module --
    completed counts=1/1/0 truncated=false
    -- focus --
    completed counts=1/0/0 truncated=false
    -- unknown focus recovery --
    completed counts=0/0/0 truncated=false
    recovery members=true
    -- unknown nested module recovery --
    completed counts=0/0/0 truncated=false
    nearest members=true
    cwd: <workspace>
    argv: "describe\nworkspace\n--root\n.\n--with-deps\n"
    stdin-empty: true
    env: "scratch=no\nsecret=unset\n"
    commands: dune=5 merlin=0 ocamlfind=0
    |}]

let%expect_test "locked package and admitted switch sources retain provenance" =
  with_world "dependency-pkg" @@ fun package_world ->
  let package_source = "_build/.pkg/dep.1.2-hash123/target/dep.mli" in
  set_response package_world "dune" 1
    (external_workspace_output package_world ~source:package_source);
  print_endline "-- locked package --";
  print_result package_world (run package_world (input ~scope:"deps" "dep"));
  Printf.printf "ocamlfind: %d\n" (invocation_count package_world "ocamlfind");
  with_world "dependency-switch" @@ fun switch_world ->
  let unavailable_source = "/toolchain/not-admitted/dep.mli" in
  set_response switch_world "dune" 1
    (external_workspace_output switch_world ~source:unavailable_source);
  set_response switch_world "ocamlfind" 1
    (Printf.sprintf "%s\n2.0\n"
       (Filename.concat (switch_dir switch_world) "lib/dep"));
  print_endline "-- switch --";
  print_result switch_world (run switch_world (input ~scope:"deps" "dep"));
  Printf.printf "cwd: %s\n"
    (normalize switch_world
       (String.trim (invocation switch_world "ocamlfind" "cwd" 1)));
  Printf.printf "argv-exact: %b stdin-empty: %b env: %S\n"
    (String.equal
       (invocation switch_world "ocamlfind" "argv" 1)
       "query\n-format\n%d\n%v\ndep\n")
    (String.is_empty (invocation switch_world "ocamlfind" "stdin" 1))
    (invocation switch_world "ocamlfind" "env" 1);
  [%expect
    {|
    -- locked package --
    status: completed
    counts: values=1 types=0 modules=0 truncated=false
    text: "dep@1.2 (build hash123)\nlevel=library_overview source=_build/.pkg/dep.1.2-hash123/target/dep.mli interface_available=true\nitems=1/1 offset=1\n- value dependency: val dependency : int\n  doc: Dependency synopsis.\n"
    json: {"version":1,"values":1,"types":0,"modules":0}
    ocamlfind: 0
    -- switch --
    status: completed
    counts: values=1 types=0 modules=0 truncated=false
    text: "dep@2.0 (opam switch <switch>)\nlevel=library_overview source=<switch>/lib/dep/dep.mli interface_available=true\nitems=1/1 offset=1\n- value from_switch: val from_switch : string\n  doc: Switch synopsis.\n"
    json: {"version":1,"values":1,"types":0,"modules":0}
    cwd: <workspace>
    argv-exact: true stdin-empty: true env: "scratch=no\nsecret=unset\n"
    |}]

let%expect_test "name-source no-follow and post-describe race fail safely" =
  with_world "dependency-symlink" @@ fun symlink_world ->
  let source = "_build/.pkg/dep.1.2-hash123/target/dep.mli" in
  let source_disk = Filename.concat (ws_dir symlink_world) source in
  let real_disk = Filename.concat (Filename.dirname source_disk) "real.mli" in
  write_disk real_disk "val real : int\n";
  Unix.unlink source_disk;
  Unix.symlink "real.mli" source_disk;
  set_response symlink_world "dune" 1
    (external_workspace_output symlink_world ~source);
  Printf.printf "symlink: %s\n"
    (run symlink_world (input ~scope:"deps" "dep") |> status_summary);
  with_world "dependency-race" @@ fun race_world ->
  let source = "_build/.pkg/dep.1.2-hash123/target/dep.mli" in
  let source_disk = Filename.concat (ws_dir race_world) source in
  set_response race_world "dune" 1
    (external_workspace_output race_world ~source);
  set_behavior race_world "dune" 1 "remove_source";
  write_disk (plan_file race_world "dune" "remove" 1) source_disk;
  Printf.printf "removed after describe: %s\n"
    (run race_world (input ~scope:"deps" "dep") |> status_summary);
  [%expect
    {|
    symlink: failed:invalid_input diagnostic=true metadata=false
    removed after describe: failed:not_found diagnostic=true metadata=false
    |}]

let run_dune_case label configure =
  with_world ("dune-" ^ label) @@ fun world ->
  configure world;
  let result = run world (input "demo") in
  Printf.printf "%s: %s output=%b\n" label (status_summary result)
    (Option.is_some (Tool.Result.output result))

let%expect_test "Dune protocol and child terminal causes stay explicit" =
  run_dune_case "malformed" (fun world ->
      set_response world "dune" 1 "not sexp");
  run_dune_case "duplicate metadata" (fun world ->
      set_response world "dune" 1
        (String.replace_all ~sub:"(name demo)"
           ~by:"(name demo) (name duplicate)"
           (local_workspace_output world)));
  List.iter
    (fun behavior ->
      run_dune_case behavior (fun world -> set_behavior world "dune" 1 behavior))
    [ "exit7"; "invalid_exit"; "signal"; "overflow"; "incomplete" ];
  with_world "dune-missing-program" @@ fun world ->
  let clock = Eio_mock.Clock.Mono.make () in
  let tool =
    make_tool world.base
      ~dune_program:[ Filename.concat (ws_dir world) "missing-dune" ]
      clock
  in
  let result =
    Tool.Call.run (decode_call tool (input "demo")) ~cancelled:(fun () -> false)
    |> finished
  in
  Printf.printf "missing program: %s output=%b\n" (status_summary result)
    (Option.is_some (Tool.Result.output result));
  [%expect
    {|
    malformed: failed:failed diagnostic=true metadata=false output=false
    duplicate metadata: failed:failed diagnostic=true metadata=false output=false
    exit7: failed:failed diagnostic=true metadata=false output=false
    invalid_exit: failed:failed diagnostic=true metadata=false output=false
    signal: failed:failed diagnostic=true metadata=false output=false
    overflow: failed:failed diagnostic=true metadata=false output=false
    incomplete: failed:failed diagnostic=true metadata=false output=false
    missing program: failed:unavailable diagnostic=true metadata=false output=false
    |}]

let%expect_test "Dune timeout and cancellation stop the real child" =
  let mock_clock = Eio_mock.Clock.Mono.make () in
  Eio_mock.Clock.Mono.set_time mock_clock (Mtime.of_uint64_ns 0L);
  with_world_using ~clock:(fun _ -> mock_clock) "dune-timeout"
  @@ fun timeout_world ->
  set_behavior timeout_world "dune" 1 "sleep";
  let rec advance_when_scheduled () =
    Eio.Fiber.yield ();
    if Eio_mock.Clock.Mono.try_advance mock_clock then `Stop_daemon
    else advance_when_scheduled ()
  in
  Eio.Fiber.fork_daemon ~sw:(sw timeout_world) advance_when_scheduled;
  Printf.printf "timeout: %s\n"
    (run timeout_world (input "demo") |> status_summary);
  with_world "dune-cancel-running" @@ fun running_world ->
  set_behavior running_world "dune" 1 "sleep";
  let deadline = Unix.gettimeofday () +. 0.1 in
  Printf.printf "running cancellation: %s\n"
    (run
       ~cancelled:(fun () -> Unix.gettimeofday () >= deadline)
       running_world (input "demo")
    |> status_summary);
  with_world "dune-cancel-before" @@ fun before_world ->
  Printf.printf "before observation: %s invocations=%d\n"
    (run ~cancelled:(fun () -> true) before_world (input "demo")
    |> status_summary)
    (invocation_count before_world "dune");
  [%expect
    {|
    +mock time is now 0
    +mock time is now 30
    timeout: failed:timed_out diagnostic=true metadata=false
    running cancellation: interrupted cancelled=true diagnostic=true
    before observation: interrupted cancelled=true diagnostic=true invocations=0
    |}]

let prepare_switch_fallback world =
  set_response world "dune" 1
    (external_workspace_output world ~source:"/toolchain/not-admitted/dep.mli")

let run_ocamlfind_case label configure =
  with_world ("ocamlfind-" ^ label) @@ fun world ->
  prepare_switch_fallback world;
  configure world;
  let result = run world (input ~scope:"deps" "dep") in
  Printf.printf "%s: %s output=%b\n" label (status_summary result)
    (Option.is_some (Tool.Result.output result))

let%expect_test "ocamlfind preserves legacy miss and explicit boundary taxonomy"
    =
  List.iter
    (fun behavior ->
      run_ocamlfind_case behavior (fun world ->
          set_behavior world "ocamlfind" 1 behavior))
    [ "exit7"; "invalid_exit"; "signal"; "overflow"; "incomplete" ];
  run_ocamlfind_case "non-UTF-8" (fun world ->
      set_response world "ocamlfind" 1 "\255bad\n1.0\n");
  run_ocamlfind_case "outside switch" (fun world ->
      set_response world "ocamlfind" 1
        (Printf.sprintf "%s\n1.0\n" (outside_dir world)));
  with_world "ocamlfind-missing-program" @@ fun world ->
  prepare_switch_fallback world;
  let clock = Eio_mock.Clock.Mono.make () in
  let tool =
    make_tool world.base
      ~ocamlfind_program:[ Filename.concat (ws_dir world) "missing-ocamlfind" ]
      clock
  in
  let result =
    Tool.Call.run
      (decode_call tool (input ~scope:"deps" "dep"))
      ~cancelled:(fun () -> false)
    |> finished
  in
  Printf.printf "missing program: %s output=%b\n" (status_summary result)
    (Option.is_some (Tool.Result.output result));
  [%expect
    {|
    exit7: failed:not_found diagnostic=true metadata=false output=false
    invalid_exit: failed:not_found diagnostic=true metadata=false output=false
    signal: failed:not_found diagnostic=true metadata=false output=false
    overflow: failed:not_found diagnostic=true metadata=false output=false
    incomplete: failed:not_found diagnostic=true metadata=false output=false
    non-UTF-8: failed:failed diagnostic=true metadata=false output=false
    outside switch: failed:failed diagnostic=true metadata=false output=false
    missing program: failed:unavailable diagnostic=true metadata=false output=false
    |}]

let%expect_test "ocamlfind timeout and cancellation are not lookup misses" =
  let mock_clock = Eio_mock.Clock.Mono.make () in
  Eio_mock.Clock.Mono.set_time mock_clock (Mtime.of_uint64_ns 0L);
  with_world_using ~clock:(fun _ -> mock_clock) "ocamlfind-timeout"
  @@ fun timeout_world ->
  prepare_switch_fallback timeout_world;
  set_behavior timeout_world "ocamlfind" 1 "sleep";
  let rec advance_when_scheduled () =
    Eio.Fiber.yield ();
    if Eio_mock.Clock.Mono.try_advance mock_clock then `Stop_daemon
    else advance_when_scheduled ()
  in
  Eio.Fiber.fork_daemon ~sw:(sw timeout_world) advance_when_scheduled;
  Printf.printf "timeout: %s\n"
    (run timeout_world (input ~scope:"deps" "dep") |> status_summary);
  with_world "ocamlfind-cancel" @@ fun cancel_world ->
  prepare_switch_fallback cancel_world;
  set_behavior cancel_world "ocamlfind" 1 "sleep";
  let deadline = Unix.gettimeofday () +. 0.1 in
  Printf.printf "cancellation: %s\n"
    (run
       ~cancelled:(fun () -> Unix.gettimeofday () >= deadline)
       cancel_world
       (input ~scope:"deps" "dep")
    |> status_summary);
  [%expect
    {|
    +mock time is now 0
    +mock time is now 30
    timeout: failed:timed_out diagnostic=true metadata=false
    cancellation: interrupted cancelled=true diagnostic=true
    |}]

let%expect_test
    "scope ambiguity toolchain exclusions and fallback policy are explicit" =
  with_world "resolution-errors" @@ fun world ->
  write_disk
    (Filename.concat (ws_dir world) "_build/.pkg/demo.1.0-hash/target/demo.mli")
    "val external_demo : int\n";
  List.iter
    (fun index ->
      set_response world "dune" index (ambiguous_workspace_output world))
    [ 1; 2; 3; 4 ];
  let cases =
    [
      ("ambiguous any", input "demo");
      ("local scope", input ~scope:"workspace" "demo");
      ("dependency scope", input ~scope:"deps" "demo");
      ("toolchain", input "stdlib");
    ]
  in
  List.iter
    (fun (label, provider_input) ->
      Printf.printf "%s: %s\n" label (run world provider_input |> status_summary))
    cases;
  with_world ~switch:false "no-switch" @@ fun no_switch ->
  prepare_switch_fallback no_switch;
  let result = run no_switch (input ~scope:"deps" "dep") in
  Printf.printf "no switch: %s ocamlfind=%d\n" (status_summary result)
    (invocation_count no_switch "ocamlfind");
  [%expect
    {|
    ambiguous any: failed:invalid_input diagnostic=true metadata=false
    local scope: completed
    dependency scope: completed
    toolchain: failed:invalid_input diagnostic=true metadata=false
    no switch: failed:unavailable diagnostic=true metadata=false ocamlfind=0
    |}]

let%expect_test "durable replay preserves text compact JSON and no authority" =
  with_world "durable" @@ fun world ->
  let result = run world (input ~limit:1 "api.mli") in
  let durable = encode result_codec result in
  let replayed = decode result_codec durable in
  let original_output = output_exn result in
  let replayed_output = output_exn replayed in
  let semantic = semantic_exn replayed in
  let forbidden =
    [
      "source_path";
      "provenance";
      "items";
      "signature";
      "doc";
      "continuation";
      "authority";
      "capability";
      "sandbox";
      "process";
    ]
  in
  let members = json_member_names durable in
  let leaked = List.filter (fun name -> List.mem name forbidden) members in
  Printf.printf
    "status=%s text-equal=%b json-equal=%b truncated-equal=%b counts=%d/%d/%d\n"
    (status_summary replayed)
    (String.equal
       (Tool.Output.text original_output)
       (Tool.Output.text replayed_output))
    (Tool.Output.json original_output = Tool.Output.json replayed_output)
    (Bool.equal
       (Tool.Output.truncated original_output)
       (Tool.Output.truncated replayed_output))
    (Mentat_tools_output.Ocaml.Docs.values semantic)
    (Mentat_tools_output.Ocaml.Docs.types semantic)
    (Mentat_tools_output.Ocaml.Docs.modules semantic);
  Printf.printf "forbidden members: %s\n"
    (if List.is_empty leaked then "none" else String.concat "," leaked);
  Printf.printf "semantic JSON: %s\n"
    (Tool.Output.json replayed_output
    |> Option.map json_string
    |> Option.value ~default:"none");
  [%expect
    {|
    status=completed text-equal=true json-equal=true truncated-equal=true counts=1/0/0
    forbidden members: none
    semantic JSON: {"version":1,"values":1,"types":0,"modules":0}
    |}]

let%expect_test "constructor rejects invalid fixed programs and switch roots" =
  with_world "constructor" @@ fun world ->
  let clock = Eio_mock.Clock.Mono.make () in
  let attempt label construct =
    Printf.printf "%s: %s\n" label
      (match construct () with
      | _ -> "accepted"
      | exception Invalid_argument _ -> "rejected")
  in
  let valid = [ world.base.fake; plan_dir world; "backend" ] in
  List.iter
    (fun (label, construct) -> attempt label construct)
    [
      ( "empty Merlin prefix",
        fun () -> make_tool world.base ~merlin_program:[] clock );
      ( "empty Dune prefix",
        fun () -> make_tool world.base ~dune_program:[] clock );
      ( "empty ocamlfind prefix",
        fun () -> make_tool world.base ~ocamlfind_program:[] clock );
      ( "empty program token",
        fun () -> make_tool world.base ~merlin_program:[ "" ] clock );
      ( "NUL program token",
        fun () -> make_tool world.base ~dune_program:[ "bad\000token" ] clock );
      ( "empty switch",
        fun () -> make_tool world.base ~opam_switch_prefix:"" clock );
      ( "NUL switch",
        fun () ->
          make_tool world.base ~opam_switch_prefix:"/bad\000switch" clock );
      ( "relative switch",
        fun () -> make_tool world.base ~opam_switch_prefix:"relative" clock );
      ( "non-normal switch",
        fun () -> make_tool world.base ~opam_switch_prefix:"/tmp/../tmp" clock
      );
      ( "valid",
        fun () ->
          make_tool world.base ~merlin_program:valid ~dune_program:valid
            ~ocamlfind_program:valid ~opam_switch_prefix:(switch_dir world)
            clock );
    ];
  Printf.printf "invocations: dune=%d merlin=%d ocamlfind=%d\n"
    (invocation_count world "dune")
    (invocation_count world "merlin")
    (invocation_count world "ocamlfind");
  [%expect
    {|
    empty Merlin prefix: rejected
    empty Dune prefix: rejected
    empty ocamlfind prefix: rejected
    empty program token: rejected
    NUL program token: rejected
    empty switch: rejected
    NUL switch: rejected
    relative switch: rejected
    non-normal switch: rejected
    valid: accepted
    invocations: dune=0 merlin=0 ocamlfind=0
    |}]

let%expect_test "name queries refuse while a supervised watch holds dune's lock"
    =
  with_world "watch-lock" @@ fun world ->
  let clock = Eio_mock.Clock.Mono.make () in
  let tool =
    Docs.make world.base.io ~clock
      ~merlin_program:[ world.base.fake; world.base.plan_dir; "merlin" ]
      ~dune_program:[ world.base.fake; world.base.plan_dir; "dune" ]
      ~ocamlfind_program:[ world.base.fake; world.base.plan_dir; "ocamlfind" ]
      ~opam_switch_prefix:None
      ~dune_lease:(fun () -> `Held)
      ()
  in
  let result =
    Tool.Call.run (decode_call tool (input "fmt")) ~cancelled:(fun () -> false)
    |> finished
  in
  print_status result;
  Printf.printf "invocations: dune=%d merlin=%d\n"
    (invocation_count world "dune")
    (invocation_count world "merlin");
  [%expect
    {|
    status: failed unavailable
    message: another session's build watch holds dune's build lock, and the docs universe needs `dune describe`, which cannot run beside it; use ocaml_find_definitions or ocaml_type_at for name lookups, or query ocaml_docs by path
    metadata: false
    invocations: dune=0 merlin=0
    |}]
