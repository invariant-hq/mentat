(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let max_detail_bytes = 4 * 1024

module Ocaml = Mentat_ocaml
module Project = Mentat_ocaml.Project
module Json = Jsont.Json
module Permission = Mentat_permission
module Tool = Mentat_tool
module Workspace = Mentat_workspace

let name = "ocaml_docs"
let description = Mentat_prompts.Tools.ocaml_docs
let default_limit = 100
let max_limit = 1_000
let max_doc_bytes = 500
let default_max_source_bytes = 2 * 1024 * 1024
let max_source_bytes = 8 * 1024 * 1024
let max_source_bytes_limit = max_source_bytes
let command_timeout_seconds = 30.
let command_capture_bytes = 8 * 1024 * 1024

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let optional_json_field name value fields =
  match value with None -> fields | Some value -> (name, value) :: fields

let json_to_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> invalid_arg ("could not encode JSON: " ^ message)

module Input = struct
  type scope = Workspace | Deps | Any

  type t = {
    query : string;
    scope : scope;
    package : string option;
    depth : int option;
    offset : int option;
    limit : int option;
    max_source_bytes : int option;
  }

  let max_input_integer =
    Float.min 9_007_199_254_740_991. (float_of_int Int.max_int)

  let scope_to_string = function
    | Workspace -> "workspace"
    | Deps -> "deps"
    | Any -> "any"

  let scope_of_string = function
    | "workspace" -> Workspace
    | "deps" -> Deps
    | "any" -> Any
    | scope -> invalid_arg ("unknown scope: " ^ scope)

  let validate_string label value =
    if String.is_empty value then invalid_arg (label ^ " must not be empty");
    if String.contains value '\000' then
      invalid_arg (label ^ " must not contain NUL")

  let validate_depth = function
    | Some depth when depth < 0 -> invalid_arg "depth must be non-negative"
    | Some _ | None -> ()

  let validate_pagination offset limit =
    begin match offset with
    | Some offset when offset < 1 -> invalid_arg "offset must be at least 1"
    | Some _ | None -> ()
    end;
    match limit with
    | Some limit when limit < 1 -> invalid_arg "limit must be positive"
    | Some limit when limit > max_limit ->
        invalid_arg ("limit must be at most " ^ string_of_int max_limit)
    | Some _ | None -> ()

  let validate_max_source_bytes = function
    | Some value when value < 1 ->
        invalid_arg "max_source_bytes must be positive"
    | Some value when value > max_source_bytes ->
        invalid_arg
          ("max_source_bytes must be at most " ^ string_of_int max_source_bytes)
    | Some _ | None -> ()

  let make ?(scope = Any) ?package ?depth ?offset ?limit ?max_source_bytes query
      =
    validate_string "query" query;
    Option.iter (validate_string "package") package;
    validate_depth depth;
    validate_pagination offset limit;
    validate_max_source_bytes max_source_bytes;
    { query; scope; package; depth; offset; limit; max_source_bytes }

  let make_json query scope package depth offset limit max_source_bytes =
    Mentat_tool.Codec.decode_invalid_arg (fun () ->
        let scope =
          Option.value ~default:Any (Option.map scope_of_string scope)
        in
        make ~scope ?package ?depth ?offset ?limit ?max_source_bytes query)

  let exact_integer =
    let decode = function
      | Jsont.Number (value, _)
        when Float.is_integer value && Float.abs value <= max_input_integer ->
          int_of_float value
      | Jsont.Number _ | Jsont.Null _ | Jsont.Bool _ | Jsont.String _
      | Jsont.Array _ | Jsont.Object _ ->
          Codec.decode_error "expected an integer in JSON's safe integer range"
    in
    Jsont.map ~kind:"integer" ~dec:decode
      ~enc:(fun value -> Json.int value)
      Jsont.json

  let query t = t.query
  let scope t = t.scope
  let package t = t.package
  let depth t = t.depth
  let offset t = t.offset
  let limit t = t.limit
  let max_source_bytes t = t.max_source_bytes

  let to_json t =
    let fields =
      [ ("query", Json.string (query t)) ]
      |> optional_json_field "scope"
           (Some (Json.string (scope_to_string (scope t))))
      |> optional_json_field "package"
           (Option.map (fun value -> Json.string value) (package t))
      |> optional_json_field "depth"
           (Option.map (fun value -> Json.int value) (depth t))
      |> optional_json_field "offset"
           (Option.map (fun value -> Json.int value) (offset t))
      |> optional_json_field "limit"
           (Option.map (fun value -> Json.int value) (limit t))
      |> optional_json_field "max_source_bytes"
           (Option.map (fun value -> Json.int value) (max_source_bytes t))
    in
    json_obj (List.rev fields)

  let object_codec =
    Jsont.Object.map ~kind:"ocaml_docs input" make_json
    |> Jsont.Object.mem "query" Jsont.string ~enc:query
    |> Jsont.Object.opt_mem "scope" Jsont.string ~enc:(fun t ->
        Some (scope_to_string (scope t)))
    |> Jsont.Object.opt_mem "package" Jsont.string ~enc:package
    |> Jsont.Object.opt_mem "depth" exact_integer ~enc:depth
    |> Jsont.Object.opt_mem "offset" exact_integer ~enc:offset
    |> Jsont.Object.opt_mem "limit" exact_integer ~enc:limit
    |> Jsont.Object.opt_mem "max_source_bytes" exact_integer
         ~enc:max_source_bytes
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let codec = Codec.strict_object ~kind:"strict ocaml_docs input" object_codec

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "query",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "description",
                      Json.string
                        "A workspace file path (has a / or ends in .ml/.mli), \
                         a findlib/local library name (lowercase, dotted), a \
                         capitalized module path, or a qualified identifier. \
                         The form is selected by the query's shape." );
                  ] );
              ( "scope",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "enum",
                      Json.list
                        [
                          Json.string "workspace";
                          Json.string "deps";
                          Json.string "any";
                        ] );
                    ( "description",
                      Json.string
                        "Name-form resolution universe. workspace restricts to \
                         local libraries, deps to dependencies, any (default) \
                         resolves against both and reports an ambiguity when a \
                         name matches both. Ignored for path-form queries." );
                  ] );
              ( "package",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "description",
                      Json.string
                        "findlib library hint that forces the containing \
                         library for a capitalized query whose root module \
                         does not match its library name." );
                  ] );
              ( "depth",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ("maximum", Json.number max_input_integer);
                    ( "description",
                      Json.string
                        "Inline nested-module expansion depth. Defaults to 0 \
                         (nested module bodies collapse to a member count)." );
                  ] );
              ( "offset",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.number max_input_integer);
                    ( "description",
                      Json.string
                        "1-based first preorder outline item to return. \
                         Defaults to 1." );
                  ] );
              ( "limit",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_limit);
                    ( "description",
                      Json.string
                        "Maximum number of outline items to return. Defaults \
                         to 100." );
                  ] );
              ( "max_source_bytes",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_source_bytes_limit);
                    ( "description",
                      Json.string
                        "Maximum accepted resolved source-file size in bytes. \
                         Defaults to 2097152." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "query" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
end

let input_text input = json_to_string (Input.to_json input)

(* Query classifier. *)

type form =
  | Path
  | Library of string
  | Module_path of string list
  | Focused of string list

let is_path_query query =
  String.contains query '/'
  || Filename.check_suffix query ".ml"
  || Filename.check_suffix query ".mli"

let is_capitalized segment =
  (not (String.is_empty segment)) && Char.Ascii.is_upper segment.[0]

let classify query =
  if is_path_query query then Path
  else
    let segments = String.split_on_char '.' query in
    if List.for_all (fun s -> not (is_capitalized s)) segments then
      Library query
    else
      match List.rev segments with
      | [] -> Library query
      | last :: _ ->
          if is_capitalized last then Module_path segments else Focused segments

(* Conventional main-module name for a findlib library name: replace '.' with
   '_' and capitalize. eio -> Eio, eio.unix -> Eio_unix, jsont.bytesrw ->
   Jsont_bytesrw, mentat_permission -> Mentat_permission. *)
let main_module_of_library library =
  String.capitalize_ascii
    (String.map (fun c -> if Char.equal c '.' then '_' else c) library)

(* Infer a findlib library name from a capitalized root module segment. *)
let library_of_module_root segment = String.uncapitalize_ascii segment

(* Outline nodes (parser walk). *)

module Item = struct
  type kind =
    | Value
    | Type
    | Module
    | Module_type
    | Exception
    | Class
    | Class_type

  type t = {
    kind : kind;
    path : string list;
    depth : int;
    signature : string;
    deprecated : bool;
    child_count : int option;
    doc : string option;
    doc_truncated : bool;
  }

  let kind_to_string = function
    | Value -> "value"
    | Type -> "type"
    | Module -> "module"
    | Module_type -> "module_type"
    | Exception -> "exception"
    | Class -> "class"
    | Class_type -> "class_type"
end

type node = {
  n_kind : Item.kind;
  n_name : string;
  n_start : int;
  n_end : int;
  n_has_body : bool;
  n_deprecated : bool;
  n_doc : string option;
  n_doc_truncated : bool;
  n_children : node list;
}

let compiler_span (loc : Location.t) =
  (loc.Warnings.loc_start.Lexing.pos_cnum, loc.Warnings.loc_end.Lexing.pos_cnum)

let doc_string_of_payload = function
  | Parsetree.PStr
      [
        {
          Parsetree.pstr_desc =
            Parsetree.Pstr_eval
              ( {
                  Parsetree.pexp_desc =
                    Parsetree.Pexp_constant
                      {
                        Parsetree.pconst_desc =
                          Parsetree.Pconst_string (text, _, _);
                        _;
                      };
                  _;
                },
                _ );
          _;
        };
      ] ->
      Some text
  | _ -> None

let doc_of_attributes attributes =
  let docs =
    List.filter_map
      (fun ({ Parsetree.attr_name = { Location.txt; _ }; attr_payload; _ } :
             Parsetree.attribute) ->
        if String.equal txt "ocaml.doc" then doc_string_of_payload attr_payload
        else None)
      attributes
  in
  match docs with
  | [] -> (None, false)
  | docs ->
      let text = String.concat "\n" docs in
      if String.length text <= max_doc_bytes then (Some text, false)
      else (Some (Text_helpers.valid_utf8_prefix text max_doc_bytes), true)

let is_deprecated attributes =
  List.exists
    (fun ({ Parsetree.attr_name = { Location.txt; _ }; _ } :
           Parsetree.attribute) ->
      String.equal txt "ocaml.deprecated" || String.equal txt "deprecated")
    attributes

let make_node ~kind ~name ~loc ~attrs ?(has_body = false) ?(children = []) () =
  let doc, doc_truncated = doc_of_attributes attrs in
  let n_start, n_end = compiler_span loc in
  {
    n_kind = kind;
    n_name = name;
    n_start;
    n_end;
    n_has_body = has_body;
    n_deprecated = is_deprecated attrs;
    n_doc = doc;
    n_doc_truncated = doc_truncated;
    n_children = children;
  }

let loc_name = function { Location.txt; loc } -> (txt, loc)

let loc_name_option = function
  | { Location.txt = Some txt; loc } -> Some (txt, loc)
  | _ -> None

(* Signature / structure walks producing outline nodes. Only modules and module
   types descend (their bodies carry members); types keep their full multi-line
   source slice, so constructors/labels are not separate items. *)

let rec module_expr_children module_expr =
  match module_expr.Parsetree.pmod_desc with
  | Parsetree.Pmod_structure structure -> (true, structure_nodes structure)
  | Parsetree.Pmod_constraint (_, module_type) ->
      module_type_children module_type
  | Parsetree.Pmod_functor (_, module_expr) -> module_expr_children module_expr
  | Parsetree.Pmod_ident _ | Parsetree.Pmod_apply _
  | Parsetree.Pmod_apply_unit _ | Parsetree.Pmod_unpack _
  | Parsetree.Pmod_extension _ ->
      (false, [])

and module_type_children module_type =
  match module_type.Parsetree.pmty_desc with
  | Parsetree.Pmty_signature signature -> (true, signature_nodes signature)
  | Parsetree.Pmty_with (module_type, _)
  | Parsetree.Pmty_typeof
      { Parsetree.pmod_desc = Parsetree.Pmod_constraint (_, module_type); _ } ->
      module_type_children module_type
  | Parsetree.Pmty_functor (_, module_type) -> module_type_children module_type
  | Parsetree.Pmty_ident _ | Parsetree.Pmty_typeof _
  | Parsetree.Pmty_extension _ | Parsetree.Pmty_alias _ ->
      (false, [])

and module_binding_nodes binding =
  match loc_name_option binding.Parsetree.pmb_name with
  | None -> []
  | Some (name, name_loc) ->
      let has_body, children =
        module_expr_children binding.Parsetree.pmb_expr
      in
      [
        make_node ~kind:Item.Module ~name ~loc:name_loc
          ~attrs:binding.Parsetree.pmb_attributes ~has_body ~children ();
      ]

and module_declaration_nodes declaration =
  match loc_name_option declaration.Parsetree.pmd_name with
  | None -> []
  | Some (name, name_loc) ->
      let has_body, children =
        module_type_children declaration.Parsetree.pmd_type
      in
      [
        make_node ~kind:Item.Module ~name ~loc:name_loc
          ~attrs:declaration.Parsetree.pmd_attributes ~has_body ~children ();
      ]

and module_type_declaration_nodes declaration =
  let name, name_loc = loc_name declaration.Parsetree.pmtd_name in
  let has_body, children =
    match declaration.Parsetree.pmtd_type with
    | None -> (false, [])
    | Some module_type -> module_type_children module_type
  in
  [
    make_node ~kind:Item.Module_type ~name ~loc:name_loc
      ~attrs:declaration.Parsetree.pmtd_attributes ~has_body ~children ();
  ]

and value_binding_nodes binding =
  let rec var_name (pattern : Parsetree.pattern) =
    match pattern.Parsetree.ppat_desc with
    | Parsetree.Ppat_var name -> Some (loc_name name)
    | Parsetree.Ppat_constraint (pattern, _) -> var_name pattern
    | _ -> None
  in
  match var_name binding.Parsetree.pvb_pat with
  | Some (name, _) ->
      [
        make_node ~kind:Item.Value ~name ~loc:binding.Parsetree.pvb_loc
          ~attrs:binding.Parsetree.pvb_attributes ();
      ]
  | None -> []

and value_description_node desc =
  let name, _ = loc_name desc.Parsetree.pval_name in
  [
    make_node ~kind:Item.Value ~name ~loc:desc.Parsetree.pval_loc
      ~attrs:desc.Parsetree.pval_attributes ();
  ]

and type_declaration_node decl =
  let name, _ = loc_name decl.Parsetree.ptype_name in
  [
    make_node ~kind:Item.Type ~name ~loc:decl.Parsetree.ptype_loc
      ~attrs:decl.Parsetree.ptype_attributes ();
  ]

and longident_last = function
  | Longident.Lident name -> name
  | Longident.Ldot (_, name) -> name.Location.txt
  | Longident.Lapply (_, lid) -> longident_last lid.Location.txt

and type_extension_node extension =
  let name = longident_last extension.Parsetree.ptyext_path.Location.txt in
  [
    make_node ~kind:Item.Type ~name ~loc:extension.Parsetree.ptyext_loc
      ~attrs:extension.Parsetree.ptyext_attributes ();
  ]

and exception_node exception_ =
  let constructor = exception_.Parsetree.ptyexn_constructor in
  let name, _ = loc_name constructor.Parsetree.pext_name in
  [
    make_node ~kind:Item.Exception ~name ~loc:exception_.Parsetree.ptyexn_loc
      ~attrs:
        (exception_.Parsetree.ptyexn_attributes
       @ constructor.Parsetree.pext_attributes)
      ();
  ]

and class_declaration_node : type a.
    kind:Item.kind -> a Parsetree.class_infos -> node list =
 fun ~kind decl ->
  let name, _ = loc_name decl.Parsetree.pci_name in
  [
    make_node ~kind ~name ~loc:decl.Parsetree.pci_loc
      ~attrs:decl.Parsetree.pci_attributes ();
  ]

(* Use the enclosing signature/structure {e item} location for each top node's
   source span, so a declaration's [signature] slice includes its leading
   keyword ([val], [type], ...) which the inner declaration location omits.
   Nested module bodies are walked recursively and keep their own inner spans;
   module signatures are synthesized so the override is harmless there. *)
and with_item_span loc nodes =
  let start, end_ = compiler_span loc in
  List.map (fun node -> { node with n_start = start; n_end = end_ }) nodes

and structure_item_nodes item =
  with_item_span item.Parsetree.pstr_loc
    (match item.Parsetree.pstr_desc with
    | Parsetree.Pstr_value (_, bindings) ->
        List.concat_map value_binding_nodes bindings
    | Parsetree.Pstr_primitive desc -> value_description_node desc
    | Parsetree.Pstr_type (_, declarations) ->
        List.concat_map type_declaration_node declarations
    | Parsetree.Pstr_typext extension -> type_extension_node extension
    | Parsetree.Pstr_exception exception_ -> exception_node exception_
    | Parsetree.Pstr_module binding -> module_binding_nodes binding
    | Parsetree.Pstr_recmodule bindings ->
        List.concat_map module_binding_nodes bindings
    | Parsetree.Pstr_modtype declaration ->
        module_type_declaration_nodes declaration
    | Parsetree.Pstr_class declarations ->
        List.concat_map (class_declaration_node ~kind:Item.Class) declarations
    | Parsetree.Pstr_class_type declarations ->
        List.concat_map
          (class_declaration_node ~kind:Item.Class_type)
          declarations
    | Parsetree.Pstr_eval _ | Parsetree.Pstr_open _ | Parsetree.Pstr_include _
    | Parsetree.Pstr_attribute _ | Parsetree.Pstr_extension _ ->
        [])

and structure_nodes structure = List.concat_map structure_item_nodes structure

and signature_item_nodes item =
  with_item_span item.Parsetree.psig_loc
    (match item.Parsetree.psig_desc with
    | Parsetree.Psig_value desc -> value_description_node desc
    | Parsetree.Psig_type (_, declarations)
    | Parsetree.Psig_typesubst declarations ->
        List.concat_map type_declaration_node declarations
    | Parsetree.Psig_typext extension -> type_extension_node extension
    | Parsetree.Psig_exception exception_ -> exception_node exception_
    | Parsetree.Psig_module declaration -> module_declaration_nodes declaration
    | Parsetree.Psig_recmodule declarations ->
        List.concat_map module_declaration_nodes declarations
    | Parsetree.Psig_modtype declaration
    | Parsetree.Psig_modtypesubst declaration ->
        module_type_declaration_nodes declaration
    | Parsetree.Psig_modsubst substitution ->
        let name, name_loc = loc_name substitution.Parsetree.pms_name in
        [
          make_node ~kind:Item.Module ~name ~loc:name_loc
            ~attrs:substitution.Parsetree.pms_attributes ();
        ]
    | Parsetree.Psig_class descriptions ->
        List.concat_map
          (fun (desc : Parsetree.class_description) ->
            class_declaration_node ~kind:Item.Class desc)
          descriptions
    | Parsetree.Psig_class_type declarations ->
        List.concat_map
          (fun (desc : Parsetree.class_type_declaration) ->
            class_declaration_node ~kind:Item.Class_type desc)
          declarations
    | Parsetree.Psig_open _ | Parsetree.Psig_include _
    | Parsetree.Psig_attribute _ | Parsetree.Psig_extension _ ->
        [])

and signature_nodes signature = List.concat_map signature_item_nodes signature

(* First floating documentation comment of a signature, used as an overview
   synopsis. *)
let floating_synopsis_of_signature signature =
  match signature with
  | item :: _ -> (
      match item.Parsetree.psig_desc with
      | Parsetree.Psig_attribute
          { Parsetree.attr_name = { Location.txt; _ }; attr_payload; _ }
        when String.equal txt "ocaml.text" ->
          doc_string_of_payload attr_payload
      | _ -> None)
  | [] -> None

type parse_kind = Interface | Implementation

let parse_error_message exn =
  Location.report_exception Format.str_formatter exn;
  let message = Format.flush_str_formatter () |> String.trim in
  if String.is_empty message then Printexc.to_string exn else message

let parse ~kind ~filename source =
  let lexbuf = Lexing.from_string source in
  Location.init lexbuf filename;
  let previous = !Location.input_name in
  Fun.protect
    ~finally:(fun () -> Location.input_name := previous)
    (fun () ->
      Location.input_name := filename;
      match kind with
      | Implementation ->
          let structure = Parse.implementation lexbuf in
          (structure_nodes structure, None)
      | Interface ->
          let signature = Parse.interface lexbuf in
          (signature_nodes signature, floating_synopsis_of_signature signature))

(* Output. *)

module Output = struct
  type level = File_outline | Library_overview | Module_outline | Item_focus

  type dep_install =
    | Pkg_build of { build_hash : string; ambiguous_builds : bool }
    | Opam_switch of { prefix : string }

  type origin =
    | Workspace_file
    | Workspace_library
    | Dependency of {
        package : string;
        version : string;
        install : dep_install;
      }

  type total = Exact of int
  type status = Complete | Partial of { next : Input.t }

  type t = {
    level : level;
    origin : origin;
    library : string option;
    source_path : string;
    interface_available : bool;
    synopsis : string option;
    modules : string list;
    sublibraries : string list;
    items : Item.t list;
    offset : int;
    total : total;
    status : status;
  }

  let provenance t =
    match t.origin with
    | Workspace_file -> "workspace file " ^ t.source_path
    | Workspace_library -> (
        match t.library with
        | Some library -> "workspace library " ^ library
        | None -> "workspace library")
    | Dependency { package; version; install } -> (
        match install with
        | Pkg_build { build_hash; _ } ->
            Printf.sprintf "%s@%s (build %s)" package version build_hash
        | Opam_switch { prefix } ->
            Printf.sprintf "%s@%s (opam switch %s)" package version prefix)

  let level_to_string = function
    | File_outline -> "file_outline"
    | Library_overview -> "library_overview"
    | Module_outline -> "module_outline"
    | Item_focus -> "item_focus"

  let item_line (item : Item.t) =
    let indent = String.make (item.Item.depth * 2) ' ' in
    let signature =
      item.Item.signature |> String.split_on_char '\n' |> List.map String.trim
      |> List.filter (fun s -> not (String.is_empty s))
      |> String.concat " "
    in
    let child_count =
      match item.Item.child_count with
      | None -> ""
      | Some count -> Printf.sprintf " (%d members)" count
    in
    let deprecated = if item.Item.deprecated then " [deprecated]" else "" in
    Printf.sprintf "%s- %s %s: %s%s%s" indent
      (Item.kind_to_string item.Item.kind)
      (String.concat "." item.Item.path)
      signature child_count deprecated

  let doc_line (item : Item.t) =
    match item.Item.doc with
    | None -> []
    | Some doc ->
        let text =
          doc |> String.split_on_char '\n' |> List.map String.trim
          |> String.concat " " |> String.trim
        in
        if String.is_empty text then []
        else
          [
            (String.make ((item.Item.depth * 2) + 2) ' '
            ^ "doc: " ^ text
            ^ if item.Item.doc_truncated then " [truncated]" else "");
          ]

  let text t =
    let b = Buffer.create 512 in
    Buffer.add_string b (provenance t);
    Buffer.add_char b '\n';
    Buffer.add_string b
      (Printf.sprintf "level=%s source=%s interface_available=%b\n"
         (level_to_string t.level) t.source_path t.interface_available);
    begin match t.synopsis with
    | None -> ()
    | Some synopsis ->
        let synopsis =
          synopsis |> String.split_on_char '\n' |> List.map String.trim
          |> String.concat " " |> String.trim
        in
        if not (String.is_empty synopsis) then
          Buffer.add_string b ("synopsis: " ^ synopsis ^ "\n")
    end;
    begin match t.sublibraries with
    | [] -> ()
    | subs ->
        Buffer.add_string b ("sublibraries: " ^ String.concat " " subs ^ "\n")
    end;
    begin match t.modules with
    | [] -> ()
    | modules ->
        Buffer.add_string b ("modules: " ^ String.concat " " modules ^ "\n")
    end;
    let total = match t.total with Exact n -> string_of_int n in
    Buffer.add_string b
      (Printf.sprintf "items=%d/%s offset=%d\n" (List.length t.items) total
         t.offset);
    List.iter
      (fun item ->
        Buffer.add_string b (item_line item);
        Buffer.add_char b '\n';
        List.iter
          (fun line ->
            Buffer.add_string b line;
            Buffer.add_char b '\n')
          (doc_line item))
      t.items;
    begin match t.status with
    | Complete -> ()
    | Partial { next } ->
        Buffer.add_string b ("next: " ^ name ^ " " ^ input_text next ^ "\n")
    end;
    Buffer.contents b

  let encode t =
    let values, types, modules =
      List.fold_left
        (fun (values, types, modules) (item : Item.t) ->
          match item.Item.kind with
          | Item.Value | Item.Exception -> (values + 1, types, modules)
          | Item.Type | Item.Class_type -> (values, types + 1, modules)
          | Item.Module | Item.Module_type | Item.Class ->
              (values, types, modules + 1))
        (0, 0, 0) t.items
    in
    let semantic =
      Mentat_tools_output.Ocaml.Docs.make ~values ~types ~modules
    in
    Mentat_tools_output.Codec.encode Mentat_tools_output.Ocaml.Docs.jsont
      ~text:(text t)
      ~truncated:
        ((match t.status with Complete -> false | Partial _ -> true)
        || List.exists (fun (item : Item.t) -> item.Item.doc_truncated) t.items
        )
      semantic
end

(* Flatten / page. *)

let slice source start end_ =
  let start = max 0 (min start (String.length source)) in
  let end_ = max start (min end_ (String.length source)) in
  String.sub source start (end_ - start)

let node_signature source node =
  match (node.n_kind, node.n_has_body) with
  | Item.Module, true -> Printf.sprintf "module %s : sig ... end" node.n_name
  | Item.Module_type, true ->
      Printf.sprintf "module type %s = sig ... end" node.n_name
  | _ -> String.trim (slice source node.n_start node.n_end)

let rec flatten ~source ~max_depth ~scope nodes =
  List.concat_map
    (fun node ->
      let depth = List.length scope in
      let path = scope @ [ node.n_name ] in
      let has_children = not (List.is_empty node.n_children) in
      let expand = has_children && depth < max_depth in
      let child_count =
        if has_children && not expand then Some (List.length node.n_children)
        else None
      in
      let item =
        {
          Item.kind = node.n_kind;
          path;
          depth;
          signature = node_signature source node;
          deprecated = node.n_deprecated;
          child_count;
          doc = node.n_doc;
          doc_truncated = node.n_doc_truncated;
        }
      in
      if expand then
        item :: flatten ~source ~max_depth ~scope:path node.n_children
      else [ item ])
    nodes

let focus_item source node =
  let has_children = not (List.is_empty node.n_children) in
  {
    Item.kind = node.n_kind;
    path = [ node.n_name ];
    depth = 0;
    signature = node_signature source node;
    deprecated = node.n_deprecated;
    child_count =
      (if has_children then Some (List.length node.n_children) else None);
    doc = node.n_doc;
    doc_truncated = node.n_doc_truncated;
  }

let is_module_node node =
  match node.n_kind with Item.Module | Item.Module_type -> true | _ -> false

let submodule_names nodes =
  List.filter_map
    (fun node -> if is_module_node node then Some node.n_name else None)
    nodes

(* Resolution. *)

type failure = { kind : Tool.Result.failure; message : string }

let fail kind message = Error { kind; message }
let interrupted () = Tool.Result.cancelled ()

let close_matches ~candidates query =
  candidates
  |> List.filter_map (fun candidate ->
      let d = String.edit_distance query candidate in
      if d <= 2 then Some (d, candidate) else None)
  |> List.sort (fun (d1, _) (d2, _) -> Int.compare d1 d2)
  |> List.map snd
  |> fun names -> List.take 5 names

(* Workspace-capability source reads. *)

let current_root_path workspace_io =
  Some (Workspace.Path.root_of (Mentat_workspace_io.cwd workspace_io))

let read_text workspace_io ~max_bytes ~follow_final path =
  let stat =
    if follow_final then Mentat_workspace_io.File.stat workspace_io path
    else Mentat_workspace_io.File.lstat workspace_io path
  in
  match stat with
  | Error error -> fail (Fs_error.failure error) (Fs_error.message error)
  | Ok stat when stat.Eio.File.Stat.kind <> `Regular_file ->
      fail `Invalid_input
        (Printf.sprintf "%s: expected a regular file, found %s"
           (Workspace.Path.display path)
           (Stat_kind.kind_name stat.Eio.File.Stat.kind))
  | Ok _ -> (
      match Mentat_workspace_io.File.load workspace_io path ~max_bytes with
      | Error error -> fail (Fs_error.failure error) (Fs_error.message error)
      | Ok source
        when Text_helpers.looks_binary source
             || not (String.is_valid_utf_8 source) ->
          fail `Invalid_input
            (Workspace.Path.display path ^ ": file is not UTF-8 text")
      | Ok source -> Ok source)

(* Provenance from a .pkg build directory. *)

let pkg_dir_of_path abs_str =
  let rec find = function
    | ".pkg" :: dir :: _ -> Some dir
    | _ :: rest -> find rest
    | [] -> None
  in
  find (String.split_on_char '/' abs_str)

let parse_pkg_dir dir =
  match String.rindex_opt dir '-' with
  | None -> None
  | Some di -> (
      let hash = String.sub dir (di + 1) (String.length dir - di - 1) in
      let name_ver = String.sub dir 0 di in
      match String.index_opt name_ver '.' with
      | None -> None
      | Some pi ->
          let package = String.sub name_ver 0 pi in
          let version =
            String.sub name_ver (pi + 1) (String.length name_ver - pi - 1)
          in
          Some (package, version, hash))

let dependency_origin_of_pkg ~library abs_str =
  let root =
    match String.split_on_char '.' library with [] -> library | r :: _ -> r
  in
  match Option.bind (pkg_dir_of_path abs_str) parse_pkg_dir with
  | Some (package, version, hash) ->
      Output.Dependency
        {
          package;
          version;
          install =
            Output.Pkg_build { build_hash = hash; ambiguous_builds = false };
        }
  | None ->
      Output.Dependency
        {
          package = root;
          version = "unknown";
          install =
            Output.Pkg_build
              { build_hash = "unknown"; ambiguous_builds = false };
        }

(* Universe resolution via dune describe. *)

let component_unit_named component target =
  List.find_opt
    (fun unit ->
      String.equal
        (Ocaml.Module_name.to_string (Project.Compilation_unit.name unit))
        target)
    (Project.Component.units component)

let unit_source_path unit =
  match Project.Compilation_unit.intf unit with
  | Some path -> Some (path, true)
  | None -> (
      match Project.Compilation_unit.impl unit with
      | Some path -> Some (path, false)
      | None -> None)

let external_names project =
  List.map Project.Component.name (Project.external_components project)

let local_names project =
  List.map Project.Component.name (Project.local_components project)

let sublibraries_of project library =
  let prefix = library ^ "." in
  external_names project
  |> List.filter (fun n -> String.starts_with ~prefix n)
  |> List.sort String.compare

(* Locate the components matching [library] under [scope]. *)
let match_components project (scope : Input.scope) library =
  let locals =
    if scope = Input.Deps then []
    else
      List.filter
        (fun c -> String.equal (Project.Component.name c) library)
        (Project.local_components project)
  in
  let externals =
    if scope = Input.Workspace then []
    else
      List.filter
        (fun c -> String.equal (Project.Component.name c) library)
        (Project.external_components project)
  in
  (locals, externals)

let stdlib_libraries = [ "stdlib"; "compiler-libs"; "threads" ]

let is_stdlib_query library =
  List.mem library stdlib_libraries
  || String.starts_with ~prefix:"compiler-libs." library

(* Reading a resolved compilation unit. *)

type source_read = {
  sr_source : string;
  sr_kind : parse_kind;
  sr_display : string;
  sr_interface : bool;
  sr_abs : string;
}

let read_in_workspace_unit workspace_io ~max_bytes unit =
  match unit_source_path unit with
  | None -> None
  | Some (path, interface) -> (
      match read_text workspace_io ~max_bytes ~follow_final:false path with
      | Error failure -> Some (Error failure)
      | Ok source -> (
          match
            ( Mentat_workspace_io.to_abs workspace_io path,
              Address.provider workspace_io path )
          with
          | Error error, _ ->
              Some (fail `Failed (Workspace.Resolve_error.message error))
          | _, Error message -> Some (fail `Failed message)
          | Ok absolute, Ok display ->
              Some
                (Ok
                   {
                     sr_source = source;
                     sr_kind = (if interface then Interface else Implementation);
                     sr_display = display;
                     sr_interface = interface;
                     sr_abs = Lpath.Abs.to_string absolute;
                   })))

type run_error = Cancelled | Run_failed of failure

let captured_text captured =
  Mentat_workspace_io.Command.Captured.render captured

let command_detail outcome =
  let stderr =
    captured_text outcome.Mentat_workspace_io.Command.stderr
    |> Text_helpers.bounded_diagnostic ~max_bytes:max_detail_bytes
  in
  if String.is_empty stderr then
    captured_text outcome.Mentat_workspace_io.Command.stdout
    |> Text_helpers.bounded_diagnostic ~max_bytes:max_detail_bytes
  else stderr

let command_error error =
  Mentat_workspace_io.Command.Error.message error
  |> Text_helpers.bounded_diagnostic ~max_bytes:max_detail_bytes

let run_command workspace_io ~clock ~program ~args ~label ~cwd ~cancelled =
  let timeout = Eio.Time.Timeout.seconds clock command_timeout_seconds in
  match
    Mentat_workspace_io.Command.run workspace_io ?cwd
      ~capture:(Mentat_workspace_io.Command.Limit command_capture_bytes)
      ~timeout ~cancelled (program @ args)
  with
  | Error error ->
      Error
        (Run_failed
           {
             kind = `Unavailable;
             message = label ^ " launch failed: " ^ command_error error;
           })
  | Ok outcome -> (
      match outcome.Mentat_workspace_io.Command.termination with
      | Mentat_workspace_io.Command.Stopped -> Error Cancelled
      | Mentat_workspace_io.Command.Timed_out ->
          Error
            (Run_failed
               {
                 kind = `Timed_out;
                 message =
                   Printf.sprintf "%s timed out after %.0fms" label
                     (command_timeout_seconds *. 1000.);
               })
      | Mentat_workspace_io.Command.Output_limit { stream; limit } ->
          let stream =
            match stream with
            | Mentat_workspace_io.Command.Stdout -> "stdout"
            | Mentat_workspace_io.Command.Stderr -> "stderr"
          in
          Error
            (Run_failed
               {
                 kind = `Failed;
                 message =
                   Printf.sprintf "%s %s exceeded %d-byte output limit" label
                     stream limit;
               })
      | Mentat_workspace_io.Command.Supervision_failed error ->
          Error
            (Run_failed
               {
                 kind = `Failed;
                 message =
                   label ^ " supervision failed: "
                   ^ (Format.asprintf "%a" Eio.Exn.pp_err error
                     |> Text_helpers.bounded_diagnostic
                          ~max_bytes:max_detail_bytes);
               })
      | Mentat_workspace_io.Command.Exited (`Signaled signal) ->
          Error
            (Run_failed
               {
                 kind = `Failed;
                 message =
                   Printf.sprintf "%s terminated by signal %d" label signal;
               })
      | Mentat_workspace_io.Command.Exited (`Exited code) ->
          if code <> 0 then
            let detail = command_detail outcome in
            Error
              (Run_failed
                 {
                   kind = `Failed;
                   message =
                     (if String.is_empty detail then
                        Printf.sprintf "%s exited with status %d" label code
                      else detail);
                 })
          else if
            not
              (Mentat_workspace_io.Command.Captured.is_complete
                 outcome.Mentat_workspace_io.Command.stdout)
          then
            Error
              (Run_failed
                 { kind = `Failed; message = label ^ " stdout was incomplete" })
          else if
            not
              (Mentat_workspace_io.Command.Captured.is_complete
                 outcome.Mentat_workspace_io.Command.stderr)
          then
            Error
              (Run_failed
                 { kind = `Failed; message = label ^ " stderr was incomplete" })
          else Ok (captured_text outcome.Mentat_workspace_io.Command.stdout))

(* Opam-switch fallback: locate the library directory with [ocamlfind query] and
   read the requested [.mli]/[.ml] through the workspace capability. *)
let ocamlfind_query workspace_io ~clock ~program ~cancelled library =
  match
    run_command workspace_io ~clock ~program
      ~args:[ "query"; "-format"; "%d\n%v"; library ]
      ~label:"ocamlfind query" ~cwd:None ~cancelled
  with
  | Error Cancelled -> Error Cancelled
  | Error (Run_failed { kind = `Unavailable | `Timed_out; _ } as error) ->
      Error error
  | Error
      (Run_failed
         {
           kind =
             `Invalid_input | `Permission_denied | `Not_found | `Stale | `Failed;
           _;
         }) ->
      Ok None
  | Ok stdout when not (String.is_valid_utf_8 stdout) ->
      Error
        (Run_failed
           {
             kind = `Failed;
             message = "ocamlfind query returned non-UTF-8 output";
           })
  | Ok stdout -> (
      match String.split_on_char '\n' (String.trim stdout) with
      | dir :: version :: _ -> Ok (Some (String.trim dir, String.trim version))
      | [ dir ] -> Ok (Some (String.trim dir, "unknown"))
      | [] -> Ok None)

let read_switch_source workspace_io ~clock ~ocamlfind_program
    ~opam_switch_prefix ~max_bytes ~cancelled ~library ~main rel =
  match
    ocamlfind_query workspace_io ~clock ~program:ocamlfind_program ~cancelled
      library
  with
  | Error Cancelled -> Error Cancelled
  | Error (Run_failed failure) -> Error (Run_failed failure)
  | Ok None ->
      Error
        (Run_failed
           {
             kind = `Not_found;
             message =
               Printf.sprintf "could not locate library %S with ocamlfind"
                 library;
           })
  | Ok (Some (lib_dir, version)) -> (
      match opam_switch_prefix with
      | None ->
          Error
            (Run_failed
               {
                 kind = `Unavailable;
                 message = "opam switch source fallback is not configured";
               })
      | Some prefix -> (
          let switch_lib = Filename.concat prefix "lib" in
          match
            ( Mentat_workspace_io.resolve_path workspace_io switch_lib,
              Mentat_workspace_io.resolve_path workspace_io lib_dir )
          with
          | Ok switch_path, Ok lib_path
            when Workspace.Path.is_within ~root:switch_path lib_path ->
              let module_file =
                match rel with
                | [] -> String.uncapitalize_ascii main
                | segment :: _ -> String.uncapitalize_ascii segment
              in
              let nested = match rel with [] -> [] | _ :: rest -> rest in
              let candidates =
                [
                  Filename.concat lib_dir (module_file ^ ".mli");
                  Filename.concat lib_dir (module_file ^ ".ml");
                ]
              in
              let rec try_read = function
                | [] ->
                    Error
                      (Run_failed
                         {
                           kind = `Not_found;
                           message =
                             Printf.sprintf "%s: no readable source under %s"
                               module_file lib_dir;
                         })
                | path :: rest -> (
                    match
                      Mentat_workspace_io.resolve_path workspace_io path
                    with
                    | Ok source_path
                      when Workspace.Path.is_within ~root:lib_path source_path
                      -> (
                        match
                          read_text workspace_io ~max_bytes ~follow_final:false
                            source_path
                        with
                        | Error _ -> try_read rest
                        | Ok source ->
                            let interface = Filename.check_suffix path ".mli" in
                            let package =
                              match String.split_on_char '.' library with
                              | [] -> library
                              | root :: _ -> root
                            in
                            Ok
                              ( {
                                  sr_source = source;
                                  sr_kind =
                                    (if interface then Interface
                                     else Implementation);
                                  sr_display = path;
                                  sr_interface = interface;
                                  sr_abs = path;
                                },
                                Output.Dependency
                                  {
                                    package;
                                    version;
                                    install = Output.Opam_switch { prefix };
                                  },
                                nested ))
                    | Ok _ | Error _ -> try_read rest)
              in
              try_read candidates
          | Ok _, Ok _ ->
              Error
                (Run_failed
                   {
                     kind = `Failed;
                     message =
                       Printf.sprintf
                         "ocamlfind reported %s outside configured switch %s"
                         lib_dir switch_lib;
                   })
          | Error error, _ ->
              Error
                (Run_failed
                   {
                     kind = `Unavailable;
                     message = Workspace.Resolve_error.message error;
                   })
          | Ok _, Error error ->
              Error
                (Run_failed
                   {
                     kind = `Failed;
                     message =
                       "ocamlfind reported an invalid library directory: "
                       ^ Workspace.Resolve_error.message error;
                   })))

(* Descent within a parsed file. *)

let rec descend nodes = function
  | [] -> Ok nodes
  | segment :: rest -> (
      match
        List.find_opt
          (fun node -> is_module_node node && String.equal node.n_name segment)
          nodes
      with
      | Some node -> descend node.n_children rest
      | None -> Error nodes)

(* Rendering a resolved query into Output.t. *)

let next_input input ~returned ~offset ~total =
  let next_offset = offset + returned in
  if next_offset > total then None
  else
    Some
      (Input.make ~scope:(Input.scope input) ?package:(Input.package input)
         ?depth:(Input.depth input) ~offset:next_offset
         ~limit:(Option.value ~default:default_limit (Input.limit input))
         ?max_source_bytes:(Input.max_source_bytes input)
         (Input.query input))

let page_and_build input ~origin ~library ~level ~source_path
    ~interface_available ~synopsis ~modules ~sublibraries items =
  let offset = Option.value ~default:1 (Input.offset input) in
  let limit = Option.value ~default:default_limit (Input.limit input) in
  let total = List.length items in
  let page = items |> List.drop (offset - 1) |> List.take limit in
  let returned = List.length page in
  let status =
    match next_input input ~returned ~offset ~total with
    | None -> Output.Complete
    | Some next -> Output.Partial { next }
  in
  Tool.Result.completed
    ~output:
      {
        Output.level;
        origin;
        library;
        source_path;
        interface_available;
        synopsis;
        modules;
        sublibraries;
        items = page;
        offset;
        total = Output.Exact total;
        status;
      }
    ()

let render input ~origin ~library ~level ~read ~descent ~focus ~sublibraries =
  match
    match parse ~kind:read.sr_kind ~filename:read.sr_display read.sr_source with
    | value -> Ok value
    | exception exn -> Error (parse_error_message exn)
  with
  | Error message -> fail `Failed (read.sr_display ^ ": " ^ message)
  | Ok (top_nodes, file_synopsis) -> (
      let synopsis =
        if level = Output.Library_overview then file_synopsis else None
      in
      match descend top_nodes descent with
      | Error members ->
          (* Unknown module path: report the nearest enclosing member list. *)
          Ok
            (page_and_build input ~origin ~library ~level:Output.Module_outline
               ~source_path:read.sr_display
               ~interface_available:read.sr_interface ~synopsis:None
               ~modules:(List.map (fun node -> node.n_name) members)
               ~sublibraries [])
      | Ok members -> (
          match focus with
          | Some ident -> (
              match
                List.find_opt
                  (fun node -> String.equal node.n_name ident)
                  members
              with
              | Some node ->
                  let sibling_names =
                    List.filter_map
                      (fun n ->
                        if String.equal n.n_name ident then None
                        else Some n.n_name)
                      members
                  in
                  Ok
                    (page_and_build input ~origin ~library
                       ~level:Output.Item_focus ~source_path:read.sr_display
                       ~interface_available:read.sr_interface ~synopsis:None
                       ~modules:sibling_names ~sublibraries
                       [ focus_item read.sr_source node ])
              | None ->
                  (* Unknown identifier: report the module's member names. *)
                  Ok
                    (page_and_build input ~origin ~library
                       ~level:Output.Module_outline ~source_path:read.sr_display
                       ~interface_available:read.sr_interface ~synopsis:None
                       ~modules:(List.map (fun n -> n.n_name) members)
                       ~sublibraries []))
          | None ->
              let depth = Option.value ~default:0 (Input.depth input) in
              let items =
                flatten ~source:read.sr_source ~max_depth:depth ~scope:[]
                  members
              in
              let modules =
                if level = Output.Library_overview then submodule_names members
                else []
              in
              Ok
                (page_and_build input ~origin ~library ~level
                   ~source_path:read.sr_display
                   ~interface_available:read.sr_interface ~synopsis ~modules
                   ~sublibraries items)))

(* Merlin fallback (mid-edit / unparseable files, path form only). *)

let json_member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let decode_json codec json =
  match Json.decode codec json with Ok value -> Some value | Error _ -> None

let json_string name json =
  Option.bind (json_member name json) (decode_json Jsont.string)

let json_bool name json =
  Option.bind (json_member name json) (decode_json Jsont.bool)

let json_children name json =
  Option.bind (json_member name json) (decode_json (Jsont.list Jsont.json))

let merlin_item_kind = function
  | "Value" -> Some Item.Value
  | "Type" -> Some Item.Type
  | "Module" -> Some Item.Module
  | "Modtype" -> Some Item.Module_type
  | "Exn" -> Some Item.Exception
  | "Class" -> Some Item.Class
  | "ClassType" -> Some Item.Class_type
  | _ -> None

let rec merlin_items ~max_depth ~scope jsons =
  List.concat_map
    (fun json ->
      match (json_string "name" json, json_string "kind" json) with
      | Some name, Some kind_string -> (
          match merlin_item_kind kind_string with
          | None -> []
          | Some kind ->
              let children =
                Option.value ~default:[] (json_children "children" json)
              in
              let module_kind =
                match kind with
                | Item.Module | Item.Module_type -> true
                | _ -> false
              in
              let has_children = module_kind && not (List.is_empty children) in
              let depth = List.length scope in
              let path = scope @ [ name ] in
              let expand = has_children && depth < max_depth in
              let typ = json_string "type" json in
              let signature =
                match (kind, has_children) with
                | Item.Module, true ->
                    Printf.sprintf "module %s : sig ... end" name
                | Item.Module_type, true ->
                    Printf.sprintf "module type %s = sig ... end" name
                | _ -> (
                    match typ with
                    | Some typ -> typ
                    | None -> Item.kind_to_string kind ^ " " ^ name)
              in
              let child_count =
                if has_children && not expand then Some (List.length children)
                else None
              in
              let item =
                {
                  Item.kind;
                  path;
                  depth;
                  signature;
                  deprecated =
                    Option.value ~default:false (json_bool "deprecated" json);
                  child_count;
                  doc = None;
                  doc_truncated = false;
                }
              in
              if expand then
                item :: merlin_items ~max_depth ~scope:path children
              else [ item ])
      | _ -> [])
    jsons

type outline_error = Outline_cancelled | Outline_failed of string

let merlin_outline workspace_io ~clock ~program ~cwd ~filename ~source
    ~cancelled =
  match
    Merlin.run workspace_io ~clock ~program ~cwd ~command:"outline"
      ~args:[ "-filename"; filename ] ~source ~cancelled
  with
  | Error Merlin.Cancelled -> Error Outline_cancelled
  | Error error -> Error (Outline_failed (Merlin.error_message error))
  | Ok value -> (
      match decode_json (Jsont.list Jsont.json) value with
      | Some items -> Ok items
      | None -> Error (Outline_failed "Merlin outline value is not a list"))

(* Path form. *)

let run_path_form workspace_io ~clock ~program ~max_bytes ~cancelled input =
  match Mentat_workspace_io.resolve_path workspace_io (Input.query input) with
  | Error error ->
      Tool.Result.failed `Invalid_input (Workspace.Resolve_error.message error)
  | Ok path -> (
      match read_text workspace_io ~max_bytes ~follow_final:true path with
      | Error { kind; message } -> Tool.Result.failed kind message
      | Ok _ when cancelled () -> interrupted ()
      | Ok source -> (
          let display =
            match Address.provider workspace_io path with
            | Ok display -> display
            | Error _ -> Workspace.Path.display path
          in
          let interface = Filename.check_suffix display ".mli" in
          let kind = if interface then Interface else Implementation in
          match Mentat_workspace_io.to_abs workspace_io path with
          | Error error ->
              Tool.Result.failed `Failed (Workspace.Resolve_error.message error)
          | Ok abs -> (
              let abs = Lpath.Abs.to_string abs in
              let read =
                {
                  sr_source = source;
                  sr_kind = kind;
                  sr_display = display;
                  sr_interface = interface;
                  sr_abs = abs;
                }
              in
              let merlin_fallback parser_message =
                match current_root_path workspace_io with
                | None ->
                    Tool.Result.failed `Failed "workspace root is unavailable"
                | Some cwd -> (
                    match
                      merlin_outline workspace_io ~clock ~program ~cwd
                        ~filename:abs ~source ~cancelled
                    with
                    | Error Outline_cancelled -> Tool.Result.cancelled ()
                    | Error (Outline_failed _) ->
                        Tool.Result.failed `Invalid_input parser_message
                    | Ok _ when cancelled () -> interrupted ()
                    | Ok jsons ->
                        let max_depth =
                          Option.value ~default:0 (Input.depth input)
                        in
                        let items = merlin_items ~max_depth ~scope:[] jsons in
                        page_and_build input ~origin:Output.Workspace_file
                          ~library:None ~level:Output.File_outline
                          ~source_path:display ~interface_available:interface
                          ~synopsis:None ~modules:[] ~sublibraries:[] items)
              in
              (* Parser-first: only fall back to Merlin when the parser cannot
             handle the file (mid-edit unparseable source). *)
              match parse ~kind ~filename:display source with
              | exception exn ->
                  merlin_fallback (display ^ ": " ^ parse_error_message exn)
              | _ when cancelled () -> interrupted ()
              | _ -> (
                  match
                    render input ~origin:Output.Workspace_file ~library:None
                      ~level:Output.File_outline ~read ~descent:[] ~focus:None
                      ~sublibraries:[]
                  with
                  | Ok result -> result
                  | Error { kind; message } -> Tool.Result.failed kind message))
          ))

(* Name form. *)

(* Split a capitalized module path into (library, module_segments, focus),
   honoring the [package] hint. *)
let resolve_library_of_segments ~package ~focus segments =
  let module_segments, focus_ident =
    match focus with
    | true -> (
        match List.rev segments with
        | last :: rest -> (List.rev rest, Some last)
        | [] -> (segments, None))
    | false -> (segments, None)
  in
  let library =
    match package with
    | Some package -> package
    | None -> (
        match module_segments with
        | root :: _ -> library_of_module_root root
        | [] -> "")
  in
  (library, module_segments, focus_ident)

let strip_main_prefix ~main segments =
  match segments with
  | first :: rest when String.equal first main -> rest
  | _ -> segments

(* Choose the compilation unit + nested descent for a module path relative to a
   resolved component. *)
let choose_unit component ~main rel =
  match rel with
  | [] -> (
      match component_unit_named component main with
      | Some unit -> Some (unit, [])
      | None -> (
          (* single-module libraries: the sole unit is the main module *)
          match Project.Component.units component with
          | [ unit ] -> Some (unit, [])
          | _ -> None))
  | p1 :: rest -> (
      match component_unit_named component (main ^ "__" ^ p1) with
      | Some unit -> Some (unit, rest)
      | None -> (
          (* nested-in-main: parse the main module and descend the whole rel *)
          match component_unit_named component main with
          | Some unit -> Some (unit, rel)
          | None -> (
              match Project.Component.units component with
              | [ unit ] -> Some (unit, rel)
              | _ -> None)))

let dependency_origin ~library read =
  if match pkg_dir_of_path read.sr_abs with Some _ -> true | None -> false
  then dependency_origin_of_pkg ~library read.sr_abs
  else
    let root =
      match String.split_on_char '.' library with [] -> library | r :: _ -> r
    in
    Output.Dependency
      {
        package = root;
        version = "unknown";
        install = Output.Opam_switch { prefix = "unknown" };
      }

let resolve_name_form workspace_io ~clock ~max_bytes ~ocamlfind_program
    ~opam_switch_prefix ~project ~cancelled input form =
  let scope = Input.scope input in
  let package = Input.package input in
  (* Determine library candidate, module segments, focus. *)
  let library, module_segments, focus, level =
    match form with
    | Library library -> (library, [], None, Output.Library_overview)
    | Module_path segments ->
        let library, module_segments, _ =
          resolve_library_of_segments ~package ~focus:false segments
        in
        let level =
          if List.length module_segments <= 1 && package = None then
            Output.Library_overview
          else Output.Module_outline
        in
        (library, module_segments, None, level)
    | Focused segments ->
        let library, module_segments, focus =
          resolve_library_of_segments ~package ~focus:true segments
        in
        (library, module_segments, focus, Output.Item_focus)
    | Path -> assert false
  in
  if is_stdlib_query library then
    fail `Invalid_input
      (Printf.sprintf
         "%s is part of the OCaml toolchain (stdlib/compiler-libs), not a \
          project component; it is out of scope. Use web_fetch on ocaml.org \
          for toolchain docs."
         library)
  else
    let locals, externals = match_components project scope library in
    match (locals, externals) with
    | [], [] ->
        let candidates = local_names project @ external_names project in
        let matches = close_matches ~candidates library in
        let hint =
          match matches with
          | [] -> ""
          | matches -> "; did you mean " ^ String.concat ", " matches ^ "?"
        in
        let package_hint =
          match form with
          | (Module_path _ | Focused _) when package = None ->
              " If the module lives in a differently-named library, pass \
               `package`."
          | _ -> ""
        in
        fail `Not_found
          (Printf.sprintf "no library %S in this project's module universe%s.%s"
             library hint package_hint)
    | _ :: _, _ :: _ ->
        let provenance_of c =
          match Project.Component.kind c with
          | Project.Component.Kind.Local_library ->
              "workspace library " ^ Project.Component.name c
          | _ -> "dependency " ^ Project.Component.name c
        in
        let candidates =
          List.map provenance_of locals @ List.map provenance_of externals
        in
        fail `Invalid_input
          (Printf.sprintf
             "%S matches more than one component (%s); re-issue with scope = \
              workspace or scope = deps."
             library
             (String.concat "; " candidates))
    | [ component ], [] | [], [ component ] -> (
        let is_local =
          Project.Component.kind component
          = Project.Component.Kind.Local_library
        in
        let main = main_module_of_library library in
        let rel = strip_main_prefix ~main module_segments in
        let sublibraries =
          if level = Output.Library_overview && not is_local then
            sublibraries_of project library
          else []
        in
        (* Prefer the in-workspace units (local libraries and .pkg deps); fall
           back to the opam-switch read seam for a dependency whose source lives
           outside the workspace. *)
        let in_workspace =
          match choose_unit component ~main rel with
          | None -> None
          | Some (unit, nested) -> (
              match read_in_workspace_unit workspace_io ~max_bytes unit with
              | None -> None
              | Some (Ok read) -> Some (Ok (read, nested))
              | Some (Error failure) -> Some (Error failure))
        in
        match in_workspace with
        | Some (Error failure) -> Error failure
        | Some (Ok (read, nested)) ->
            let origin =
              if is_local then Output.Workspace_library
              else dependency_origin ~library read
            in
            render input ~origin ~library:(Some library) ~level ~read
              ~descent:nested ~focus ~sublibraries
        | None -> (
            if is_local then
              fail `Not_found
                (Printf.sprintf "could not locate the source of %S" library)
            else
              match opam_switch_prefix with
              | None ->
                  fail `Unavailable
                    "dependency source is outside the workspace and no opam \
                     switch prefix was configured"
              | Some _ -> (
                  match
                    read_switch_source workspace_io ~clock ~ocamlfind_program
                      ~opam_switch_prefix ~max_bytes ~cancelled ~library ~main
                      rel
                  with
                  | Error Cancelled ->
                      Error { kind = `Failed; message = "tool call cancelled" }
                  | Error (Run_failed failure) -> Error failure
                  | Ok (read, origin, nested) ->
                      render input ~origin ~library:(Some library) ~level ~read
                        ~descent:nested ~focus ~sublibraries)))
    | _ :: _ :: _, _ | _, _ :: _ :: _ ->
        fail `Failed "ambiguous component resolution"

(* Permissions. *)

let switch_lib_root opam_switch_prefix =
  Option.map (fun prefix -> Filename.concat prefix "lib") opam_switch_prefix

let permissions workspace_io ~execution ~opam_switch_prefix input =
  let confinement = Confinement.custom_access execution in
  match classify (Input.query input) with
  | Path -> (
      match
        Mentat_workspace_io.resolve_path workspace_io (Input.query input)
      with
      | Error _ -> []
      | Ok path ->
          let accesses =
            [ Permission.Access.path ~op:`Read path; confinement ]
          in
          [ Permission.Request.of_accesses ~source:name accesses ])
  | Library _ | Module_path _ | Focused _ ->
      let project_read =
        match current_root_path workspace_io with
        | None -> []
        | Some path -> [ Permission.Access.path ~op:`Read path ]
      in
      let switch_accesses =
        match switch_lib_root opam_switch_prefix with
        | None -> []
        | Some lib_root -> (
            match Mentat_workspace_io.resolve_path workspace_io lib_root with
            | Error _ -> []
            | Ok path -> [ Permission.Access.path ~op:`Read path ])
      in
      let accesses = project_read @ switch_accesses @ [ confinement ] in
      [ Permission.Request.of_accesses ~source:name accesses ]

(* run. *)

let logical_workspace workspace_io =
  let cwd = Mentat_workspace_io.cwd workspace_io in
  let root_path = Workspace.Path.root_of cwd in
  match Mentat_workspace_io.to_abs workspace_io root_path with
  | Error error -> Error (Workspace.Resolve_error.message error)
  | Ok root_dir ->
      let root =
        Workspace.Root.make ~key:(Workspace.Path.root_key cwd) root_dir
      in
      Ok (Workspace.single ~cwd:(Workspace.Path.rel cwd) root)

(* The refusal while a supervised build watch holds dune's build lock: the
   universe command ([dune describe workspace]) takes that lock and would
   fail with dune's own advice — which suggests deleting [_build/.lock],
   exactly what a caller must never do while a watch runs — so name queries
   answer honestly and point at the lock-free alternatives. Path queries
   never reach this command and stay available. *)
let watch_lock_message =
  "the build watch holds dune's build lock, and the docs universe needs \
   `dune describe`, which cannot run beside it; use ocaml_find_definitions \
   or ocaml_type_at for name lookups, or query ocaml_docs by path"

let resolve_universe workspace_io ~clock ~dune_program ~dune_lock_held
    ~cancelled =
  if dune_lock_held () then
    Error (Run_failed { kind = `Unavailable; message = watch_lock_message })
  else
  match logical_workspace workspace_io with
  | Error message -> Error (Run_failed { kind = `Failed; message })
  | Ok workspace -> (
      match
        run_command workspace_io ~clock ~program:dune_program
          ~args:[ "describe"; "workspace"; "--root"; "."; "--with-deps" ]
          ~label:"dune describe workspace"
          ~cwd:(Some (Workspace.root_path workspace))
          ~cancelled
      with
      | Error _ as error -> error
      | Ok _ when cancelled () -> Error Cancelled
      | Ok stdout -> (
          match
            Mentat_ocaml_dune_describe.of_workspace_output ~workspace stdout
          with
          | Ok project -> Ok project
          | Error error ->
              Error
                (Run_failed
                   {
                     kind = `Failed;
                     message =
                       "could not resolve the project module universe: "
                       ^ Text_helpers.bounded_diagnostic
                           ~max_bytes:max_detail_bytes
                           (Mentat_ocaml_dune_describe.Error.message error);
                   })))

let run workspace_io ~clock ~merlin_program ~dune_program ~ocamlfind_program
    ~opam_switch_prefix ~dune_lock_held ~cancelled input =
  if cancelled () then interrupted ()
  else
    let max_bytes =
      Option.value
        (Input.max_source_bytes input)
        ~default:default_max_source_bytes
    in
    match classify (Input.query input) with
    | Path ->
        run_path_form workspace_io ~clock ~program:merlin_program ~max_bytes
          ~cancelled input
    | (Library _ | Module_path _ | Focused _) as form -> (
        match
          resolve_universe workspace_io ~clock ~dune_program ~dune_lock_held
            ~cancelled
        with
        | Error Cancelled -> interrupted ()
        | Error (Run_failed { kind; message }) ->
            Tool.Result.failed kind message
        | Ok project -> (
            if cancelled () then interrupted ()
            else
              match
                resolve_name_form workspace_io ~clock ~max_bytes
                  ~ocamlfind_program ~opam_switch_prefix ~project ~cancelled
                  input form
              with
              | Ok _ when cancelled () -> interrupted ()
              | Ok result -> result
              | Error { kind; message } ->
                  if cancelled () then interrupted ()
                  else Tool.Result.failed kind message))

let validate_program label program =
  if List.is_empty program then
    invalid_arg ("Ocaml.Docs.make: " ^ label ^ " prefix must not be empty");
  List.iteri
    (fun index token ->
      if String.is_empty token then
        invalid_arg
          (Printf.sprintf "Ocaml.Docs.make: %s token %d must not be empty" label
             index);
      if String.contains token '\x00' then
        invalid_arg
          (Printf.sprintf "Ocaml.Docs.make: %s token %d must not contain NUL"
             label index))
    program

let validate_switch_prefix = function
  | None -> ()
  | Some prefix -> (
      if String.is_empty prefix then
        invalid_arg "Ocaml.Docs.make: opam switch prefix must not be empty";
      if String.contains prefix '\x00' then
        invalid_arg "Ocaml.Docs.make: opam switch prefix must not contain NUL";
      match Lpath.Abs.of_string prefix with
      | Ok path when String.equal (Lpath.Abs.to_string path) prefix -> ()
      | Ok _ ->
          invalid_arg "Ocaml.Docs.make: opam switch prefix must be normalized"
      | Error error ->
          invalid_arg
            ("Ocaml.Docs.make: invalid opam switch prefix: "
           ^ Lpath.Error.message error))

let make workspace_io ~clock ~merlin_program ~dune_program ~ocamlfind_program
    ~opam_switch_prefix ?(dune_lock_held = fun () -> false) () =
  validate_program "Merlin program" merlin_program;
  validate_program "Dune program" dune_program;
  validate_program "ocamlfind program" ocamlfind_program;
  validate_switch_prefix opam_switch_prefix;
  let execution = Confinement.confined workspace_io in
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(permissions workspace_io ~execution ~opam_switch_prefix)
    ~run:(fun ~cancelled input ->
      run workspace_io ~clock ~merlin_program ~dune_program ~ocamlfind_program
        ~opam_switch_prefix ~dune_lock_held ~cancelled input)
    ()
