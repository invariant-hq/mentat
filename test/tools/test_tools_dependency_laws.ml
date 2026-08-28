(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Source and Dune-metadata guards for the two physical tool slices.
   The linked test process is deliberately not inspected: it necessarily adds
   the test framework's own dependencies. The compiler lexer provides a robust
   source audit which ignores comments and strings without maintaining a second
   OCaml lexer here. *)

open Windtrap

type qualified = { name : string; line : int }

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let rec find_workspace_root directory =
  if Sys.file_exists (Filename.concat directory "lib/tools/dune") then directory
  else
    let parent = Filename.dirname directory in
    if String.equal parent directory then
      failf "could not locate lib/tools/dune above %s" (Sys.getcwd ());
    find_workspace_root parent

let root = lazy (find_workspace_root (Sys.getcwd ()))
let source path = Filename.concat (Lazy.force root) path

let starts_with ~prefix value =
  let length = String.length prefix in
  String.length value >= length
  && String.equal prefix (String.sub value 0 length)

let path_has_prefix ~prefix path =
  String.equal prefix path || starts_with ~prefix:(prefix ^ ".") path

type dune_token = Dune_open | Dune_close | Dune_atom_token of string
type dune_sexp = Dune_atom of string | Dune_list of dune_sexp list

(* This small parser retains enough Dune structure to identify one library's
   exact direct dependencies. It deliberately accepts the S-expression surface
   rather than depending on line layout, so reformatting the stanza cannot
   weaken an architecture law. *)
let dune_tokens path =
  let text = read path in
  let length = String.length text in
  let rec whitespace reversed offset =
    if offset >= length then List.rev reversed
    else
      match text.[offset] with
      | ' ' | '\t' | '\r' | '\n' -> whitespace reversed (offset + 1)
      | '(' -> whitespace (Dune_open :: reversed) (offset + 1)
      | ')' -> whitespace (Dune_close :: reversed) (offset + 1)
      | ';' -> comment reversed (offset + 1)
      | '"' -> quoted reversed (Buffer.create 16) (offset + 1)
      | _ -> atom reversed (Buffer.create 16) offset
  and comment reversed offset =
    if offset >= length then List.rev reversed
    else if text.[offset] = '\n' then whitespace reversed (offset + 1)
    else comment reversed (offset + 1)
  and quoted reversed buffer offset =
    if offset >= length then failf "%s has an unterminated quoted atom" path
    else
      match text.[offset] with
      | '"' ->
          whitespace
            (Dune_atom_token (Buffer.contents buffer) :: reversed)
            (offset + 1)
      | '\\' when offset + 1 < length ->
          Buffer.add_char buffer text.[offset + 1];
          quoted reversed buffer (offset + 2)
      | character ->
          Buffer.add_char buffer character;
          quoted reversed buffer (offset + 1)
  and atom reversed buffer offset =
    if offset >= length then
      List.rev (Dune_atom_token (Buffer.contents buffer) :: reversed)
    else
      match text.[offset] with
      | ' ' | '\t' | '\r' | '\n' | '(' | ')' | ';' ->
          whitespace
            (Dune_atom_token (Buffer.contents buffer) :: reversed)
            offset
      | character ->
          Buffer.add_char buffer character;
          atom reversed buffer (offset + 1)
  in
  whitespace [] 0

let dune_atoms path =
  dune_tokens path
  |> List.filter_map (function
    | Dune_atom_token atom -> Some atom
    | Dune_open | Dune_close -> None)

let dune_sexps path =
  let rec one = function
    | Dune_atom_token atom :: rest -> (Dune_atom atom, rest)
    | Dune_open :: rest -> group [] rest
    | Dune_close :: _ -> failf "%s has an unmatched closing parenthesis" path
    | [] -> failf "%s ended while parsing a Dune expression" path
  and group reversed = function
    | Dune_close :: rest -> (Dune_list (List.rev reversed), rest)
    | [] -> failf "%s has an unterminated Dune list" path
    | tokens ->
        let item, rest = one tokens in
        group (item :: reversed) rest
  in
  let rec all reversed = function
    | [] -> List.rev reversed
    | tokens ->
        let item, rest = one tokens in
        all (item :: reversed) rest
  in
  all [] (dune_tokens path)

let dune_field name fields =
  List.find_opt
    (function
      | Dune_list (Dune_atom field :: _) -> String.equal field name
      | Dune_atom _ | Dune_list (Dune_list _ :: _) | Dune_list [] -> false)
    fields

let dune_library_dependencies path name =
  let path = source path in
  let is_named_library = function
    | Dune_list (Dune_atom "library" :: fields) -> (
        match dune_field "name" fields with
        | Some (Dune_list [ Dune_atom "name"; Dune_atom found ]) ->
            String.equal found name
        | Some _ | None -> false)
    | Dune_atom _ | Dune_list _ -> false
  in
  match List.find_opt is_named_library (dune_sexps path) with
  | None -> failf "%s does not declare library %s" path name
  | Some (Dune_list (Dune_atom "library" :: fields)) -> (
      match dune_field "libraries" fields with
      | None -> []
      | Some (Dune_list (Dune_atom "libraries" :: dependencies)) ->
          dependencies
          |> List.map (function
            | Dune_atom dependency -> dependency
            | Dune_list _ ->
                failf
                  "%s uses a structured dependency in %s; extend the law's \
                   dependency parser before accepting it"
                  path name)
          |> List.sort_uniq String.compare
      | Some _ -> assert false)
  | Some _ -> assert false

let dune_library path name =
  let atoms = dune_atoms (source path) in
  if not (List.mem name atoms) then failf "%s does not declare %s" path name;
  atoms

let is_directory path =
  try
    let stats : Unix.stats = Unix.stat path in
    stats.Unix.st_kind = Unix.S_DIR
  with Unix.Unix_error _ -> false

(* Every top-level directory under otherlibs/ that carries a dune file is a
   member of the standalone space. Deriving the set from the directory listing,
   rather than a hard-coded list, keeps the standalone law self-maintaining: a
   new member is audited the instant its dune lands. *)
let otherlibs_members () =
  let space = source "otherlibs" in
  Sys.readdir space |> Array.to_list |> List.sort String.compare
  |> List.filter (fun entry ->
      let path = Filename.concat space entry in
      is_directory path && Sys.file_exists (Filename.concat path "dune"))

let rec source_files_below ~boundary_root directory =
  Sys.readdir directory |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun entry ->
      let path = Filename.concat directory entry in
      if is_directory path then
        let nested_library =
          (not (String.equal path boundary_root))
          && Sys.file_exists (Filename.concat path "dune")
        in
        if nested_library then [] else source_files_below ~boundary_root path
      else if
        Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"
      then [ path ]
      else [])

(* A complete .ml/.mli sweep that, unlike [source_files_below], descends THROUGH
   nested library boundaries: the source sweep must see every source under lib
   and bin, not just one library's own files. [skip] prunes the sandbox archive — where the
   lowering functions are defined — and any test tree. *)
let rec all_sources_below ~skip directory =
  Sys.readdir directory |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun entry ->
      let path = Filename.concat directory entry in
      if is_directory path then
        if skip ~path ~entry then [] else all_sources_below ~skip path
      else if
        Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"
      then [ path ]
      else [])

let relative_to directory path =
  let prefix = directory ^ Filename.dir_sep in
  if not (starts_with ~prefix path) then
    failf "%s is not beneath %s" path directory;
  String.sub path (String.length prefix)
    (String.length path - String.length prefix)

let qualified_names path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let lexbuf = Lexing.from_channel channel in
      Location.init lexbuf path;
      Lexer.init ();
      let flush segments line reversed =
        match segments with
        | [] -> reversed
        | segments ->
            { name = String.concat "." (List.rev segments); line } :: reversed
      in
      let rec tokens segments line after_dot reversed =
        let token = Lexer.token lexbuf in
        match token with
        | Parser.UIDENT segment | Parser.LIDENT segment ->
            let token_line = lexbuf.Lexing.lex_start_p.Lexing.pos_lnum in
            if segments = [] then tokens [ segment ] token_line false reversed
            else if after_dot then
              tokens (segment :: segments) line false reversed
            else
              tokens [ segment ] token_line false (flush segments line reversed)
        | Parser.DOT when segments <> [] && not after_dot ->
            tokens segments line true reversed
        | Parser.EOF -> List.rev (flush segments line reversed)
        | _ -> tokens [] 0 false (flush segments line reversed)
      in
      tokens [] 0 false [])

let files directory =
  source_files_below ~boundary_root:directory directory
  |> List.map (fun path -> (relative_to directory path, path))

let executor_sources () = files (source "lib/tools")
let output_sources () = files (source "lib/tools/output")
let tui_sources () = files (source "lib/tui")
let step_sources () = files (source "lib/agent/step")

let violations ~files forbidden =
  files
  |> List.concat_map (fun (relative, path) ->
      qualified_names path
      |> List.filter_map (fun occurrence ->
          if forbidden occurrence.name then
            Some
              (Printf.sprintf "%s:%d: %s" relative occurrence.line
                 occurrence.name)
          else None))
  |> List.sort_uniq String.compare

let assert_sources ~boundary ~files forbidden =
  match violations ~files forbidden with
  | [] -> ()
  | found ->
      failf "%s contains forbidden qualified names:\n%s" boundary
        (String.concat "\n" found)

let difference left right =
  List.filter (fun value -> not (List.mem value right)) left

let assert_exact_names ~boundary ~expected actual =
  let expected = List.sort_uniq String.compare expected in
  let actual = List.sort_uniq String.compare actual in
  let missing = difference expected actual in
  let unexpected = difference actual expected in
  if missing <> [] || unexpected <> [] then
    failf "%s direct dependencies changed:\nmissing: %s\nunexpected: %s"
      boundary
      (if missing = [] then "<none>" else String.concat ", " missing)
      (if unexpected = [] then "<none>" else String.concat ", " unexpected)

let tui_direct_dependencies =
  [
    "eio";
    "eio.unix";
    "jsont";
    "jsont.bytesrw";
    "logs";
    "matrix";
    "matrix-eio";
    "mosaic";
    "mosaic.ui";
    "mentat_client";
    "mentat_config";
    "mentat_diagnostic";
    "mentat_llm";
    "mentat_mutation";
    "lpath";
    "mentat_permission";
    "mentat_protocol";
    "mentat_provider";
    (* [mentat_review] is a pure value vocabulary the review query/flow carries
       (deps: jsont textdiff mentat_digest lpath — no engine, store, or
       effect), so the review screen renders its View/File_diff/Cr projections
       directly, exactly as it renders mentat_provider's model values. The git
       effect loader landed as the bin-private [Review_git] adapter
       (bin/review_git.ml), which a frontend library cannot link at all — a
       structural severance stronger than a denylist entry. See
       scratchpad/review-waist-design.md (thin-client ruling). *)
    "mentat_review";
    "mentat_session";
    "mentat_tool";
    "mentat_tools_output";
    "mentat_workspace";
    "textdiff";
    "tree-sitter.json";
    "tree-sitter.ocaml";
    "unix";
    "uri";
  ]

(* The frontend Drop list minus the two post-promotion name collisions. Bare
   [mentat_protocol] and [mentat_provider] denote the sanctioned client value
   vocabularies a thin frontend renders — the wire types (Command, Query, Fact,
   Progress, Error, Position) and the catalog/model/readiness/selector values the
   client's queries and flows carry — not the pre-promotion effect libraries
   these lists sever. Fact-folding stays out regardless: [forbidden_tui_source]
   keeps [Mentat_protocol.Projection] off the frontend. *)
let tui_must_sever_dependencies =
  [
    "mentat_host";
    "mentat_host_builtin";
    "mentat_account";
    "mentat_auth";
    "mentat_session_store";
    (* The frontend names [textdiff] for hunks; a direct legacy-diff
       reference is a regression (review-waist-design ruling, law assertion 2). *)
    "mentat_diff_legacy";
    "mentat_ocaml_dune_rpc";
    "mentat_ocaml_dune_describe";
    "mentat_ocaml";
    "mentat_sandbox";
    "fswatch";
    "mentat_workspace_fs";
    "mentat_edit";
    "mentat_prompts";
  ]

let tui_must_sever_modules =
  [
    "Mentat_host";
    "Mentat_host_builtin";
    "Mentat_account";
    "Mentat_auth";
    "Mentat_session_store";
    "Mentat_diff_legacy";
    "Mentat_ocaml_dune_rpc";
    "Mentat_ocaml";
    "Mentat_sandbox";
    "Fswatch";
    "Mentat_workspace_fs";
    "Mentat_edit";
    "Mentat_prompts";
  ]

let forbidden_tui_source name =
  path_has_prefix ~prefix:"Mentat_tools" name
  (* The engine/replay projector is lib/agent's alone (feed.ml is its sole
     legitimate caller); a frontend that folded facts itself would bypass the
     one authoritative membership check. Guard both the qualified path and the
     [module Protocol = Mentat_protocol] alias the tui sources carry. *)
  || path_has_prefix ~prefix:"Mentat_protocol.Projection" name
  || path_has_prefix ~prefix:"Protocol.Projection" name
  || List.exists
       (fun prefix -> path_has_prefix ~prefix name)
       tui_must_sever_modules

let upper_dependency name =
  [
    "mentat_mutation";
    "mentat_session";
    "mentat_agent";
    "mentat_store";
    "mentat_protocol";
  ]
  |> List.exists (fun prefix -> starts_with ~prefix name)

let concrete_transport name =
  [
    "Ca_certs";
    "Cohttp";
    "Cohttp_eio";
    "Cstruct";
    "Domain_name";
    "Ipaddr";
    "Mirage_crypto_rng";
    "Tls";
    "Tls_eio";
  ]
  |> List.exists (fun prefix -> path_has_prefix ~prefix name)

let%test "the output slice and TUI preserve the complete rendering firewall" =
  let output = dune_library "lib/tools/output/dune" "mentat_tools_output" in
  let forbidden_output_dependency name =
    upper_dependency name
    || List.mem name
         [
           "mentat_tools";
           "mentat_workspace_io";
           "mentat_ocaml";
           "mentat_ocaml_dune_rpc";
           "mentat_ocaml_dune_describe";
           "mentat_ocaml_grep";
           "compiler-libs.common";
           "eio";
           "eio.unix";
           "unix";
           "ca-certs";
           "cohttp";
           "cohttp-eio";
           "tls";
           "tls-eio";
         ]
  in
  let leaked = List.filter forbidden_output_dependency output in
  if leaked <> [] then
    failf "mentat_tools_output has forbidden dependencies: %s"
      (String.concat ", " leaked);
  if
    not
      (List.mem "mentat_tools_output"
         (dune_library_dependencies "lib/tools/dune" "mentat_tools"))
  then fail "the executor does not depend on the shared tool-output archive";
  let tui_dependencies =
    dune_library_dependencies "lib/tui/dune" "mentat_tui"
  in
  if not (List.mem "mentat_tools_output" tui_dependencies) then
    fail "mentat_tui no longer depends on the pure tool-output slice";
  if List.mem "mentat_tools" tui_dependencies then
    fail "mentat_tui directly depends on the tool executor";
  let severed =
    List.filter
      (fun dependency -> List.mem dependency tui_must_sever_dependencies)
      tui_dependencies
  in
  if severed <> [] then
    failf "mentat_tui regained forbidden direct dependencies: %s"
      (String.concat ", " severed);
  assert_exact_names ~boundary:"mentat_tui" ~expected:tui_direct_dependencies
    tui_dependencies;
  let forbidden_output_source name =
    concrete_transport name
    || [
         "Eio";
         "Eio_unix";
         "Unix";
         "Mentat_tools";
         "Mentat_workspace_io";
         "Mentat_ocaml";
         "Mentat_mutation";
         "Mentat_session";
         "Mentat_agent";
         "Mentat_store";
         "Mentat_protocol";
       ]
       |> List.exists (fun prefix -> path_has_prefix ~prefix name)
  in
  assert_sources ~boundary:"mentat_tools_output" ~files:(output_sources ())
    forbidden_output_source;
  assert_sources ~boundary:"mentat_tui" ~files:(tui_sources ())
    forbidden_tui_source

let%test "the executor cannot reach upper state or spawn a process directly" =
  let dune = dune_library "lib/tools/dune" "mentat_tools" in
  let leaked = List.filter upper_dependency dune in
  if leaked <> [] then
    failf "mentat_tools has forbidden upper dependencies: %s"
      (String.concat ", " leaked);
  let direct_process name =
    String.equal name "Sys.command"
    || String.equal name "Process.spawn"
    || String.equal name "Process.parse_out"
    || starts_with ~prefix:"Unix.create_process" name
    || starts_with ~prefix:"Unix.exec" name
    || String.equal name "Unix.fork"
    || starts_with ~prefix:"Unix.open_process" name
    || String.equal name "Unix.system"
    || path_has_prefix ~prefix:"Eio.Process" name
       && not (String.equal name "Eio.Process.Executable_not_found")
  in
  assert_sources ~boundary:"mentat_tools" ~files:(executor_sources ())
    direct_process

let%test "concrete HTTP and TLS modules stay inside Web.Transport_eio" =
  let adapter = [ "web/transport_eio.ml"; "web/transport_eio.mli" ] in
  let executor = executor_sources () in
  List.iter
    (fun expected ->
      if
        not
          (List.exists
             (fun (relative, _) -> String.equal expected relative)
             executor)
      then failf "the concrete Web transport is missing %s" expected)
    adapter;
  executor |> List.filter (fun (relative, _) -> not (List.mem relative adapter))
  |> fun outside ->
  assert_sources ~boundary:"mentat_tools outside Web.Transport_eio"
    ~files:outside concrete_transport

(* Structural replacement for the deleted [mentat_tui_review] sever entry: a
   frontend sub-library under lib/tui passes the letter of the dependency law
   while subverting its intent, because [source_files_below] stops descending at
   a nested library's dune, so [forbidden_tui_source] never scans its engine or
   diff reads. Forbidding a nested library outright makes "you cannot hide
   frontend reach one directory down" a checked fact, independent of which names
   are on any sever list. See scratchpad/review-waist-design.md (law assertion 3). *)
let%test "lib/tui declares no nested library" =
  let tui = source "lib/tui" in
  Sys.readdir tui |> Array.to_list |> List.sort String.compare
  |> List.iter (fun entry ->
      let path = Filename.concat tui entry in
      let dune = Filename.concat path "dune" in
      if is_directory path && Sys.file_exists dune then
        let declares_library =
          dune_sexps dune
          |> List.exists (function
            | Dune_list (Dune_atom "library" :: _) -> true
            | Dune_atom _ | Dune_list _ -> false)
        in
        if declares_library then
          failf
            "lib/tui/%s declares a nested library; the review screen is \
             mentat_tui private modules, not a sub-library. A nested library \
             stops the forbidden_tui_source scan and lets frontend code reach \
             engine or diff libraries unseen — the hollow boundary the \
             review-waist-design ruling closes."
            entry)

(* [mentat.store] is the durable tier's aggregator — it binds the
   session document, the mutation event log, the blob store, and review state
   behind one library and so links [mentat_mutation], [mentat_session],
   [mentat_edit], and [mentat_review]. The forward arrows are compiler facts of
   the store stanza; the reverse edge must stay absent. None of the four lower
   libraries may name [mentat_store], or the store's role as the sole
   composition point of the durable tier collapses into a dependency cycle. This
   guard fails the moment a lower library regains the upward dependency. *)
let%test "the durable-tier libraries never depend on their store aggregator" =
  [
    ("lib/mutation/dune", "mentat_mutation");
    ("lib/session/dune", "mentat_session");
    ("lib/edit/dune", "mentat_edit");
    ("lib/review/dune", "mentat_review");
  ]
  |> List.iter (fun (path, name) ->
      if List.mem "mentat_store" (dune_library_dependencies path name) then
        failf
          "%s directly depends on mentat_store; the durable tier's aggregator \
           is the store, never the reverse"
          name)

(* [mentat.provider_runtime] is the one effect leaf that concentrates the
   provider transports and account effects. The full direct-edge denylist has two
   flavors: upward-effect edges
   ([mentat.agent], [mentat.protocol], [mentat.session], [mentat.store],
   [mentat.config], [mentat.workspace_io], [mentat.mutation], [mentat.review],
   [mentat.tui]) a leaf must never reach, and redundant direct edges to pure
   primitives ([lpath], [mentat.digest]) it already reaches transitively.
   The guard reads DIRECT deps only, so the transitive [mentat.digest] the OAuth
   PKCE path pulls is fine; only a direct edge fails. *)
let%test "mentat.provider_runtime lists no library above its leaf" =
  let forbidden =
    [
      "mentat_agent";
      "mentat_protocol";
      "mentat_session";
      "mentat_store";
      "mentat_config";
      "mentat_workspace_io";
      "mentat_mutation";
      "mentat_review";
      "lpath";
      "mentat_digest";
      "mentat_tui";
    ]
  in
  let leaked =
    dune_library_dependencies "lib/provider_runtime/dune"
      "mentat_provider_runtime"
    |> List.filter (fun name -> List.mem name forbidden)
  in
  if leaked <> [] then
    failf "lib/provider_runtime/dune lists a library above this leaf: %s"
      (String.concat ", " leaked)

(* [mentat.provider] is the pure metadata that
   crosses the provider waist. It links only the pure LLM currency, the pure
   OAuth core, and the codec primitives its declarations name — never
   [mentat.digest], an Eio or Unix effect, or a concrete provider transport. An
   exact-deps guard pins the set so a new edge is caught either way. *)
let%test "mentat.provider links exactly its pure foundations" =
  assert_exact_names ~boundary:"mentat_provider"
    ~expected:[ "jsont"; "oauth2"; "mentat_llm"; "uri" ]
    (dune_library_dependencies "lib/provider/dune" "mentat_provider")

(* [mentat.client] wraps the engine's feed-serving seam through
   the injected [Driver.t] record, so it links the protocol and the pure value
   vocabularies but never an engine, store, or transport effect library. *)
let%test "mentat.client links no forbidden effect library" =
  let forbidden =
    [
      "mentat_agent";
      "mentat_agent_step";
      "mentat_store";
      "mentat_session_store";
      "mentat_provider_runtime";
      "mentat_workspace_io";
    ]
  in
  let leaked =
    dune_library_dependencies "lib/client/dune" "mentat_client"
    |> List.filter (fun name -> List.mem name forbidden)
  in
  if leaked <> [] then
    failf "lib/client/dune lists a forbidden effect library: %s"
      (String.concat ", " leaked)

(* [mentat.server] promotes the host side behind a socket, so
   it links the protocol, the client seam it refills, a socket transport, and the
   pure value vocabularies its endpoint codecs name — but never an engine, a
   store, a provider transport, or a rendering surface. The forward exclusion is a
   compiler fact of the stanza; this guard fails if the stanza regains one. *)
let%test "mentat.server links no forbidden effect library" =
  let forbidden =
    [
      "mentat_agent";
      "mentat_agent_step";
      "mentat_store";
      "mentat_session_store";
      "mentat_provider_runtime";
      "mentat_workspace_io";
      (* Both rendering surfaces: the daemon host owns the browser edge, never the
         HTML mentat.web emits nor the terminal cells mentat.tui paints.
         The composition root joins them behind the shared edge; lib/server does
         not link either. *)
      "mentat_tui";
      "mentat_web";
    ]
  in
  let leaked =
    dune_library_dependencies "lib/server/dune" "mentat_server"
    |> List.filter (fun name -> List.mem name forbidden)
  in
  if leaked <> [] then
    failf "lib/server/dune lists a forbidden effect library: %s"
      (String.concat ", " leaked)

(* The host/frontend partition: the composition root and its effect
   adapters in bin/ never link a rendering library. Enumerating the whole
   directory — rather than a hard-coded module list — keeps a renderer reference
   from reaching any host module unseen. The frontend pair is the sole
   exception: [cli_tui] hosts the interactive stage and [cli_trust_prompt] is the
   executable-private launch-gate Mosaic app. *)
let%test "only the frontend bin modules link a rendering library" =
  let renderer name =
    path_has_prefix ~prefix:"Mentat_tui" name
    || path_has_prefix ~prefix:"Mosaic" name
    || path_has_prefix ~prefix:"Matrix" name
  in
  let frontend_modules = [ "cli_tui"; "cli_trust_prompt" ] in
  let host_sources =
    files (source "bin")
    |> List.filter (fun (relative, _) ->
        not (List.mem (Filename.remove_extension relative) frontend_modules))
  in
  assert_sources ~boundary:"the host-side bin modules" ~files:host_sources
    renderer

(* The step interpreter is the effect-free core of [mentat.agent]: its own
   interface promises it "mints no entropy, reads no clock, and performs no IO,"
   and the load-bearing firewall behind that promise is the dune [libraries]
   whitelist — the step links no transport, no store, and no [unix], so those
   effects cannot be named at all. What a dependency whitelist cannot reach are
   the effectful modules that live in Stdlib itself and are therefore always
   linked: [Domain], [Random], [Sys], and the [Effect] handler operations
   ([perform], [Deep], [Shallow]). This law scans the step's own sources and
   closes that one Stdlib-resident hole.

   Honesty about its reach: this is a best-effort guard against ACCIDENT, not a
   sandbox. A lexical scan cannot see through [open Effect], a local module
   alias, or [Obj.magic], so a determined author still evades it — the defences
   that actually hold are the dune whitelist and review. What the guard buys is
   that the common accidental slip, reaching for [Sys.getenv] or [Random.int]
   out of habit, becomes a build failure instead of a silent impurity. It
   forbids the effect OPERATIONS, never the module: the step defines its own
   [Step.Effect] value vocabulary ([Effect.t], [Effect.Tool], [Effect.Model]),
   which names no handler operation and so stays clear of the law. *)
let%test "the step interpreter names no Stdlib effect" =
  let stdlib_effect name =
    path_has_prefix ~prefix:"Domain" name
    || path_has_prefix ~prefix:"Random" name
    || path_has_prefix ~prefix:"Sys" name
    || path_has_prefix ~prefix:"Unix" name
    || String.equal name "Effect.perform"
    || path_has_prefix ~prefix:"Effect.Deep" name
    || path_has_prefix ~prefix:"Effect.Shallow" name
  in
  assert_sources ~boundary:"the step interpreter" ~files:(step_sources ())
    stdlib_effect

(* [mentat.workspace_io] is the effect leaf that
   holds the native filesystem and the process spawn. Its direct dependency set
   is load-bearing, so it is exact-pinned here and any new edge is caught either
   way. [cstruct] and [optint] are not incidental C-stub baggage: they are named
   through Eio's File API (Cstruct buffers for pread/pwrite, Optint.Int63 for
   file sizes). [nofollow] is the symlink-refusing openat-family primitives the
   native-write path traverses with, extracted to the standalone otherlibs
   member; [subprocess] is the bounded, group-terminating Eio child supervision
   this leaf's spawn choke point drives, extracted to the same space. The
   review-projection ruling has landed: the review projection
   (feature computation, CR scanning, fingerprinting) is now the executable-side
   [Review_git] adapter in bin/, so this leaf carries no review domain. Neither
   [textdiff] nor [mentat_review] is linked here — the A-firewall holds
   structurally, by the dune whitelist rather than by convention. *)
let%test "mentat.workspace_io links exactly its effect foundations" =
  assert_exact_names ~boundary:"mentat_workspace_io"
    ~expected:
      [
        "cstruct";
        "eio";
        "eio.unix";
        "logs";
        "mtime";
        "nofollow";
        "optint";
        "subprocess";
        "mentat_config";
        "mentat_digest";
        "mentat_edit";
        "mentat_ocaml_toolchain";
        "lpath";
        "mentat_sandbox";
        "mentat_workspace";
        "unix";
      ]
    (dune_library_dependencies "lib/workspace_io/dune" "mentat_workspace_io")

(* Sandbox confinement is lowered to a raw argv — [Mentat_sandbox.lower_argv] and
   its escalated twin — at exactly one place outside lib/sandbox, the spawn
   boundary in [mentat_workspace_io]. The confinement design promises "a
   grep-level check that this lowering appears only in this archive"; this law is
   that check. It deliberately keeps no list of the
   libraries that link mentat_sandbox: such a list rots silently the moment a new
   linker appears (lib/agent/step links the sandbox today), so instead the scan
   sweeps every source under lib and bin, excluding only lib/sandbox — where the
   functions are defined — and any test tree. The sole legitimate site is the
   sandbox-lowering call in [mentat_workspace_io]'s launch path; the law also
   fails if that site vanishes, so a move of the spawn boundary must re-point
   this check consciously. *)
let%test
    "sandbox argv lowering is named only at the workspace_io spawn boundary" =
  let boundary_file = "lib/workspace_io/mentat_workspace_io.ml" in
  let sandbox_root = source "lib/sandbox" in
  let skip ~path ~entry =
    String.equal path sandbox_root
    || String.equal entry "test" || String.equal entry "tests"
  in
  let names_lowering name =
    String.equal name "Mentat_sandbox.lower_argv"
    || String.equal name "Mentat_sandbox.lower_escalated_argv"
  in
  let root = Lazy.force root in
  let occurrences =
    all_sources_below ~skip (source "lib")
    @ all_sources_below ~skip (source "bin")
    |> List.concat_map (fun path ->
        let relative = relative_to root path in
        qualified_names path
        |> List.filter_map (fun occurrence ->
            if names_lowering occurrence.name then
              Some (relative, occurrence.line, occurrence.name)
            else None))
  in
  let outside =
    List.filter
      (fun (relative, _, _) -> not (String.equal relative boundary_file))
      occurrences
  in
  if outside <> [] then
    failf "sandbox argv lowering escaped the workspace_io spawn boundary:\n%s"
      (String.concat "\n"
         (List.map
            (fun (relative, line, name) ->
              Printf.sprintf "%s:%d: %s" relative line name)
            outside));
  if occurrences = [] then
    fail
      "no source names Mentat_sandbox.lower_argv; the confinement spawn \
       boundary moved out of mentat_workspace_io — re-point this guard to its \
       new home"

(* [mentat.tools_output] is the pure projection slice the executor and the
   frontend share. It links exactly the pure tool vocabulary, the pure LLM
   currency, and the JSON codec — no executor, no effect leaf, no transport. The
   firewall law above scans sources against a denylist; this exact pin closes
   the denylist's blind spot, where a pure-looking new edge (a second codec, say)
   slips a deny-only guard but not an exact one. *)
let%test "mentat.tools_output links exactly its pure slice" =
  assert_exact_names ~boundary:"mentat_tools_output"
    ~expected:[ "jsont"; "mentat_llm"; "mentat_tool" ]
    (dune_library_dependencies "lib/tools/output/dune" "mentat_tools_output")

(* [mentat.config] is the pure typed-field vocabulary — layered
   precedence, parsing, and structure-preserving edit planning. Its category-A
   firewall is that it cannot touch disk: file discovery and IO stay
   executable-private, so it links only pure vocabularies and codecs, never eio,
   unix, or any other effect library. This exact pin is that firewall — a new
   edge to an effect library trips it rather than silently opening a disk path. *)
let%test "mentat.config links exactly its pure vocabulary and cannot touch disk"
    =
  assert_exact_names ~boundary:"mentat_config"
    ~expected:
      [
        "jsont";
        "jsont.bytesrw";
        "lpath";
        "mentat_diagnostic";
        "mentat_llm";
        "mentat_provider";
        "mentat_sandbox";
        "mentat_permission";
      ]
    (dune_library_dependencies "lib/config/dune" "mentat_config")

(* [mentat.context] is request-scoped instruction and skill
   discovery behind a load→value→project waist. It runs its own discovery IO
   (eio/unix), but its category-A firewall is that discovery can never reach the
   engine cone: it links no engine, client, store, session-journal, mutation, or
   provider-runtime. This exact pin catches any such edge, so folding discovery
   into a lower layer cannot silently open one. *)
let%test
    "mentat.context links exactly its discovery foundations, never the engine \
     cone" =
  assert_exact_names ~boundary:"mentat_context"
    ~expected:
      [
        "eio";
        "eio.unix";
        "unix";
        "jsont";
        "frontmatter";
        "lpath";
        "mentat_prompts";
        "mentat_config";
        "mentat_digest";
        "mentat_llm";
        "mentat_tool";
        "mentat_diagnostic";
      ]
    (dune_library_dependencies "lib/context/dune" "mentat_context")

(* Maintainer ruling: [mentat.digest] stays under lib/ — its content-identity
   role is linked at every layer, not a release-standalone posture — but its
   foundation purity is made a compiler fact here. It is the SHA-256
   content-identity core carrying its own C stubs; it links exactly the JSON
   codec its [Content_ref] declarations name, never an effect library, a
   transport, or a mentat_* peer. This exact pin trips on a new edge rather
   than letting the foundation silently acquire a dependency. *)
let%test
    "mentat.digest links exactly its pure identity foundation (kept in lib/ by \
     maintainer ruling)" =
  assert_exact_names ~boundary:"mentat_digest" ~expected:[ "jsont" ]
    (dune_library_dependencies "lib/digest/dune" "mentat_digest")

(* The otherlibs/ contract: otherlibs/ holds standalone, release-ready
   libraries. Its load-bearing conjunct is STANDALONE — a member's [libraries]
   field names only third-party opam packages and, at most, another library
   defined under that same member's own directory tree: never a mentat_* library
   (mentat policy stays in the consumers that link the member) and never a
   DIFFERENT otherlibs member (the space threads no second cross-member
   dependency graph, so each member releases on its own schedule). The
   within-member exception is the core+IO-companion pattern the ecosystem uses
   (dune-rpc/dune-rpc-lwt, tls/tls-eio): oauth2 carries its Eio transport as the
   co-located oauth2_eio sublibrary, so the scan reads every dune under a
   member's tree and treats an edge to a same-tree library as internal. This is
   the law behind the contract's teeth: a "no core dep" convention rots silently,
   a checked one does not. The scan enumerates members from the directory
   listing so a new member is audited the moment its dune lands. The member-set
   assertion is the one deliberate hand-maintained line — growing otherlibs/ is
   a conscious act, so adding a directory must also update this list, which
   re-affirms the contract.

   Two more clauses are checked here. First, every library a member defines
   carries NO mentat_ prefix: the bare rename is pulled forward from release, so
   a prefixed name is a regression, not a pending chore, and it is also what
   keeps the cross-member guard meaningful once bare names no longer wear the
   prefix the [names_mentat] filter catches. Second, only [(library ...)]
   stanzas are read — a member's [(test ...)] dune under [test/] contributes no
   library, so co-located tests link the member's own libraries and the test
   framework freely without tripping the guard. *)
let%test
    "otherlibs members are standalone and unprefixed: bare names, no mentat_ \
     or cross-member dependency" =
  let members = otherlibs_members () in
  assert_exact_names ~boundary:"otherlibs members"
    ~expected:
      [
        "frontmatter";
        "fswatch";
        "github";
        "jsonschema";
        "lpath";
        "nofollow";
        "oauth2";
        "sse";
        "subprocess";
        "textdiff";
      ]
    members;
  let member_root member = source (Filename.concat "otherlibs" member) in
  let rec dune_files_below directory =
    Sys.readdir directory |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun entry ->
        let path = Filename.concat directory entry in
        if is_directory path then dune_files_below path
        else if String.equal entry "dune" then [ path ]
        else [])
  in
  (* Every [(library (name X) ... (libraries ...))] stanza in a dune file, as a
     (name, direct dependencies) pair; non-library stanzas contribute nothing. *)
  let dune_libraries path =
    dune_sexps path
    |> List.filter_map (function
      | Dune_list (Dune_atom "library" :: fields) -> (
          match dune_field "name" fields with
          | Some (Dune_list [ Dune_atom "name"; Dune_atom name ]) ->
              let deps =
                match dune_field "libraries" fields with
                | Some (Dune_list (Dune_atom "libraries" :: items)) ->
                    List.filter_map
                      (function Dune_atom d -> Some d | Dune_list _ -> None)
                      items
                | Some _ | None -> []
              in
              Some (name, deps)
          | Some _ | None -> None)
      | Dune_atom _ | Dune_list _ -> None)
  in
  let by_member =
    List.map
      (fun member ->
        ( member,
          dune_files_below (member_root member)
          |> List.concat_map dune_libraries ))
      members
  in
  let all_libraries =
    List.concat_map (fun (_, stanzas) -> List.map fst stanzas) by_member
  in
  let names_mentat dependency =
    starts_with ~prefix:"mentat_" dependency
    || path_has_prefix ~prefix:"mentat" dependency
  in
  List.iter
    (fun (member, stanzas) ->
      let own = List.map fst stanzas in
      List.iter
        (fun (name, _) ->
          if starts_with ~prefix:"mentat_" name || String.equal name "mentat"
          then
            failf
              "otherlibs/%s declares library %s, which carries the mentat_ \
               prefix. An otherlibs member uses bare, unprefixed names — the \
               release-time rename is pulled forward, so the prefix is gone \
               the moment it lands."
              member name)
        stanzas;
      let cross_member =
        List.filter (fun l -> not (List.mem l own)) all_libraries
      in
      List.iter
        (fun (name, deps) ->
          let forbidden =
            List.filter
              (fun dep -> names_mentat dep || List.mem dep cross_member)
              deps
          in
          if forbidden <> [] then
            failf
              "otherlibs/%s (%s) is not standalone; it names: %s. An otherlibs \
               member depends only on third-party packages and libraries under \
               its own directory tree — never a mentat_* library, never a \
               different otherlibs member."
              member name
              (String.concat ", " forbidden))
        stanzas)
    by_member
