(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

module Error = struct
  type t = { message : string; hints : string list }

  let message t = t.message
  let hints t = t.hints
  let diagnostic t = Mentat_diagnostic.of_text ~hints:t.hints t.message
  let pp ppf t = Format.pp_print_string ppf t.message
end

let error_t ?(hints = []) message = { Error.message; hints }
let error ?hints message = Error (error_t ?hints message)

(* [Provider.make]'s [Invalid_argument] payload may carry its function prefix
   (possibly twice through re-raising); strip both occurrences. *)
let invalid_provider_id id message =
  let message =
    List.fold_left
      (fun message prefix ->
        if String.starts_with ~prefix message then
          String.drop_first (String.length prefix) message
        else message)
      message
      [ "Mentat_llm.Provider.make: "; "Mentat_llm.Provider.make: " ]
  in
  error (Printf.sprintf "invalid provider id %S: %s" id message)

(* Product value vocabulary owned by config. [sandbox.mode] and [sandbox.read]
   are product posture, not [mentat.sandbox] policy: the sandbox foundation
   models the policy algebra a mode lowers to, and config owns the mode/read
   vocabulary itself. *)
module Mode = struct
  type t = Read_only | Workspace_write | Danger_full_access | External_sandbox

  let all = [ Read_only; Workspace_write; Danger_full_access; External_sandbox ]

  let to_string = function
    | Read_only -> "read-only"
    | Workspace_write -> "workspace-write"
    | Danger_full_access -> "danger-full-access"
    | External_sandbox -> "external-sandbox"

  let of_string = function
    | "read-only" -> Some Read_only
    | "workspace-write" -> Some Workspace_write
    | "danger-full-access" -> Some Danger_full_access
    | "external-sandbox" -> Some External_sandbox
    | _ -> None

  let equal a b =
    match (a, b) with
    | Read_only, Read_only
    | Workspace_write, Workspace_write
    | Danger_full_access, Danger_full_access
    | External_sandbox, External_sandbox ->
        true
    | (Read_only | Workspace_write | Danger_full_access | External_sandbox), _
      ->
        false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Dune_watch = struct
  type t = Auto | Observe | Off

  let all = [ Auto; Observe; Off ]

  let to_string = function
    | Auto -> "auto"
    | Observe -> "observe"
    | Off -> "off"

  let of_string = function
    | "auto" -> Some Auto
    | "observe" -> Some Observe
    | "off" -> Some Off
    | _ -> None

  let equal a b =
    match (a, b) with
    | Auto, Auto | Observe, Observe | Off, Off -> true
    | (Auto | Observe | Off), _ -> false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Read = struct
  type t = Project | All

  let all = [ Project; All ]
  let to_string = function Project -> "project" | All -> "all"

  let of_string = function
    | "project" -> Some Project
    | "all" -> Some All
    | _ -> None

  let equal a b =
    match (a, b) with
    | Project, Project | All, All -> true
    | (Project | All), _ -> false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Env_inherit = struct
  type t = Allowlist | All

  let all = [ Allowlist; All ]
  let to_string = function Allowlist -> "allowlist" | All -> "all"

  let of_string = function
    | "allowlist" -> Some Allowlist
    | "all" -> Some All
    | _ -> None

  let equal a b =
    match (a, b) with
    | Allowlist, Allowlist | All, All -> true
    | (Allowlist | All), _ -> false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

(* Notification vocabulary owned by config. The TUI notify fields store the
   validated spellings; the reducer reads these typed enums back through
   {!of_string} rather than carrying its own sum types: the TUI links the config
   vocabulary, not config IO. *)
module Notify = struct
  module Channel = struct
    type t = Off | Bell | Osc9 | Osc777 | Auto | Command

    let all = [ Off; Bell; Osc9; Osc777; Auto; Command ]

    let to_string = function
      | Off -> "off"
      | Bell -> "bell"
      | Osc9 -> "osc9"
      | Osc777 -> "osc777"
      | Auto -> "auto"
      | Command -> "command"

    let values = List.map to_string all

    let of_string = function
      | "off" -> Some Off
      | "bell" -> Some Bell
      | "osc9" -> Some Osc9
      | "osc777" -> Some Osc777
      | "auto" -> Some Auto
      | "command" -> Some Command
      | _ -> None

    let equal a b = a = b
    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end

  module When = struct
    type t = Unfocused | Always

    let all = [ Unfocused; Always ]
    let to_string = function Unfocused -> "unfocused" | Always -> "always"
    let values = List.map to_string all

    let of_string = function
      | "unfocused" -> Some Unfocused
      | "always" -> Some Always
      | _ -> None

    let equal a b = a = b
    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end

  module Event = struct
    type t = Turn_done | Decision

    let all = [ Turn_done; Decision ]
    let to_string = function Turn_done -> "turn-done" | Decision -> "decision"
    let values = List.map to_string all

    let of_string = function
      | "turn-done" -> Some Turn_done
      | "decision" -> Some Decision
      | _ -> None

    let equal a b = a = b
    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end
end

(* [decode_enum ~what ~all ~to_string of_string value] parses a closed enum from
   user text. On failure the hints list an [all]-ordered candidate set plus a
   {!Mentat_diagnostic.did_you_mean} nudge, and the message reads
   [unknown <what>: <value>]. The exact wording is a pinned diagnostic contract
   (config cram [errors.t]); do not alter it. *)
let decode_enum ~what ~all ~to_string of_string value =
  match of_string value with
  | Some x -> Ok x
  | None ->
      let allowed = List.map to_string all in
      error
        ~hints:
          (("expected one of: " ^ String.concat ", " allowed)
          :: Mentat_diagnostic.did_you_mean value ~candidates:allowed)
        ("unknown " ^ what ^ ": " ^ value)

let permission_unattended_of_string =
  decode_enum ~what:"permission unattended policy"
    ~all:Mentat_permission.Unattended.all
    ~to_string:Mentat_permission.Unattended.to_string
    Mentat_permission.Unattended.of_string

let sandbox_mode_of_string =
  decode_enum ~what:"sandbox mode" ~all:Mode.all ~to_string:Mode.to_string
    Mode.of_string

let sandbox_require_of_string =
  decode_enum ~what:"sandbox requirement" ~all:Mentat_sandbox.Requirement.all
    ~to_string:Mentat_sandbox.Requirement.to_string
    Mentat_sandbox.Requirement.of_string

let sandbox_read_of_string =
  decode_enum ~what:"sandbox read scope" ~all:Read.all ~to_string:Read.to_string
    Read.of_string

let sandbox_network_of_string =
  decode_enum ~what:"sandbox network" ~all:Mentat_sandbox.Policy.Network.all
    ~to_string:Mentat_sandbox.Policy.Network.to_string
    Mentat_sandbox.Policy.Network.of_string

let reasoning_effort_of_string =
  decode_enum ~what:"reasoning effort"
    ~all:Mentat_llm.Request.Options.Reasoning_effort.all
    ~to_string:Mentat_llm.Request.Options.Reasoning_effort.to_string
    Mentat_llm.Request.Options.Reasoning_effort.of_string

(* [tools.editor] and [workspace.tooling] are closed-vocabulary string fields:
   their domain value stays a validated string. The [decode_enum] machinery
   over the identity codec keeps the pinned error wording. *)
let string_enum_of_string ~what ~spellings value =
  decode_enum ~what ~all:spellings ~to_string:Fun.id
    (fun v -> if List.mem v spellings then Some v else None)
    value

let tools_editor_spellings = [ "auto"; "apply-patch"; "string-replace" ]
let workspace_tooling_spellings = [ "auto"; "on"; "off" ]
let web_search_provider_spellings = [ "exa"; "parallel"; "off" ]
let tui_diff_layout_spellings = [ "auto"; "unified"; "split" ]

let tui_diff_layout_of_string =
  string_enum_of_string ~what:"diff layout" ~spellings:tui_diff_layout_spellings

let tools_editor_of_string =
  string_enum_of_string ~what:"tools editor" ~spellings:tools_editor_spellings

let sandbox_env_inherit_of_string =
  decode_enum ~what:"sandbox env inheritance" ~all:Env_inherit.all
    ~to_string:Env_inherit.to_string Env_inherit.of_string

let workspace_tooling_of_string =
  string_enum_of_string ~what:"workspace tooling mode"
    ~spellings:workspace_tooling_spellings

let dune_watch_of_string =
  decode_enum ~what:"dune watch mode" ~all:Dune_watch.all
    ~to_string:Dune_watch.to_string Dune_watch.of_string

let web_search_provider_of_string =
  string_enum_of_string ~what:"web search provider"
    ~spellings:web_search_provider_spellings

let notify_channel_of_string =
  string_enum_of_string ~what:"notify channel" ~spellings:Notify.Channel.values

let notify_when_of_string =
  string_enum_of_string ~what:"notify focus policy"
    ~spellings:Notify.When.values

let with_error_context context = function
  | Ok _ as ok -> ok
  | Error error ->
      Error
        (error_t ~hints:(Error.hints error)
           (context ^ ": " ^ Error.message error))

let absolute_path_jsont =
  Jsont.map ~kind:"absolute path"
    ~dec:(fun raw ->
      match Lpath.Abs.of_string raw with
      | Ok path -> path
      | Error error ->
          Jsont.Error.msg Jsont.Meta.none (Lpath.Error.message error))
    ~enc:Lpath.Abs.to_string Jsont.string

module Source = struct
  type t =
    | User of { path : Lpath.Abs.t }
    | Project of { path : Lpath.Abs.t }
    | Project_local of { path : Lpath.Abs.t }
    | Extra_file of { path : Lpath.Abs.t }
    | Env of { name : string }
    | Override
    | Default of { reason : string }

  let path_string = Lpath.Abs.to_string

  let pp ppf = function
    | User { path } -> Format.fprintf ppf "user %s" (path_string path)
    | Project { path } -> Format.fprintf ppf "project %s" (path_string path)
    | Project_local { path } ->
        Format.fprintf ppf "project-local %s" (path_string path)
    | Extra_file { path } ->
        Format.fprintf ppf "extra-file %s" (path_string path)
    | Env { name } -> Format.fprintf ppf "env %s" name
    | Override -> Format.pp_print_string ppf "override"
    | Default { reason } -> Format.fprintf ppf "default %s" reason

  let kind_string = function
    | User _ -> "user"
    | Project _ -> "project"
    | Project_local _ -> "project-local"
    | Extra_file _ -> "extra"
    | Env _ -> "env"
    | Override -> "override"
    | Default _ -> "default"

  (* The single-[path] cases; [enc_case] routes each to its own encoder, so the
     other constructors are unreachable. *)
  let source_path = function
    | User { path }
    | Project { path }
    | Project_local { path }
    | Extra_file { path } ->
        path
    | Env _ | Override | Default _ -> assert false

  let jsont =
    let path_case ~kind ~name make =
      Jsont.Object.map ~kind make
      |> Jsont.Object.mem "path" absolute_path_jsont ~enc:source_path
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map name ~dec:Fun.id
    in
    let user =
      path_case ~kind:"user config source" ~name:"user" (fun path ->
          User { path })
    in
    let project =
      path_case ~kind:"project config source" ~name:"project" (fun path ->
          Project { path })
    in
    let project_local =
      path_case ~kind:"project-local config source" ~name:"project_local"
        (fun path -> Project_local { path })
    in
    let extra_file =
      path_case ~kind:"extra config source" ~name:"extra_file" (fun path ->
          Extra_file { path })
    in
    let env =
      Jsont.Object.map ~kind:"env config source" (fun name -> Env { name })
      |> Jsont.Object.mem "name" Jsont.string ~enc:(function
        | Env { name } -> name
        | User _ | Project _ | Project_local _ | Extra_file _ | Override
        | Default _ ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "env" ~dec:Fun.id
    in
    let override =
      Jsont.Object.map ~kind:"override config source" Override
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "override" ~dec:Fun.id
    in
    let default =
      Jsont.Object.map ~kind:"default config source" (fun reason ->
          Default { reason })
      |> Jsont.Object.mem "reason" Jsont.string ~enc:(function
        | Default { reason } -> reason
        | User _ | Project _ | Project_local _ | Extra_file _ | Env _ | Override
          ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "default" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ user; project; project_local; extra_file; env; override; default ]
    in
    let enc_case = function
      | User _ as source -> Jsont.Object.Case.value user source
      | Project _ as source -> Jsont.Object.Case.value project source
      | Project_local _ as source ->
          Jsont.Object.Case.value project_local source
      | Extra_file _ as source -> Jsont.Object.Case.value extra_file source
      | Env _ as source -> Jsont.Object.Case.value env source
      | Override as source -> Jsont.Object.Case.value override source
      | Default _ as source -> Jsont.Object.Case.value default source
    in
    Jsont.Object.map ~kind:"config source" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Origin = struct
  type t = { source : Source.t; shadowed : Source.t list }

  let make ~source ~shadowed = { source; shadowed }
  let source t = t.source
  let shadowed t = t.shadowed

  let pp ppf t =
    match t.shadowed with
    | [] -> Source.pp ppf t.source
    | shadowed ->
        Format.fprintf ppf "%a; overrides: %a" Source.pp t.source
          Format.(
            pp_print_list
              ~pp_sep:(fun ppf () -> pp_print_string ppf ", ")
              Source.pp)
          shadowed

  let jsont =
    Jsont.Object.map ~kind:"config origin" (fun source shadowed ->
        make ~source ~shadowed)
    |> Jsont.Object.mem "source" Source.jsont ~enc:source
    |> Jsont.Object.mem "shadowed" (Jsont.list Source.jsont) ~enc:shadowed
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

(* Value parsing and rendering helpers, shared by the textual parsers
   (CLI [set]), the JSON leaf decoders (file load and validation), and the
   typed value checks. Error wording is pinned; see [decode_enum]. *)

let env_non_empty getenv name =
  match getenv name with
  | Some value when not (String.is_empty value) -> Some value
  | Some _ | None -> None

let default_shell_program getenv =
  if String.equal Filename.dir_sep "\\" then
    Option.value (env_non_empty getenv "COMSPEC") ~default:"cmd"
  else Option.value (env_non_empty getenv "SHELL") ~default:"/bin/sh"

let max_json_safe_int = 9_007_199_254_740_991
let max_json_safe_int_float = 9_007_199_254_740_991.

let check_positive_int field value =
  if value <= 0 then error (field ^ " must be positive")
  else if value > max_json_safe_int then
    error (field ^ " must be at most " ^ string_of_int max_json_safe_int)
  else Ok value

let json_number_to_positive_int field value =
  if not (Float.is_integer value) then error (field ^ " must be an integer")
  else if value <= 0. then error (field ^ " must be positive")
  else if value > max_json_safe_int_float then
    error (field ^ " must be at most " ^ string_of_int max_json_safe_int)
  else Ok (int_of_float value)

let default_instructions_project_max_bytes = 32 * 1024
let default_skills_catalog_max_bytes = 8 * 1024
let default_web_fetch_max_bytes = 5 * 1024 * 1024
let default_web_output_max_chars = 100_000
let default_web_timeout_ms = 30_000
let default_web_max_timeout_ms = 120_000
let default_image_max_bytes = 5 * 1024 * 1024
let default_image_max_dimension = 8000
let default_image_max_count = 20

let parse_selector field raw =
  let raw = String.trim raw in
  match Mentat_provider.Selector.of_string raw with
  | Ok selector -> Ok selector
  | Error e -> error (field ^ " " ^ Mentat_provider.Selector.Error.message e)

let json_mem name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_object_fields = function
  | Jsont.Object (fields, _) -> Some fields
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_string = function Jsont.String (value, _) -> Some value | _ -> None

(* JSON leaf decoders shared by file loading and validation. [label] is the
   error-label prefix, for example "<source> run.max_steps". *)

let decode_string_leaf label leaf =
  match json_string leaf with
  | Some "" -> error (label ^ " must not be empty")
  | Some value -> Ok value
  | None -> error (label ^ " must be a string")

let decode_selector_leaf label leaf =
  match json_string leaf with
  | Some "" -> error (label ^ " must not be empty")
  | Some raw -> parse_selector label raw
  | None -> error (label ^ " must be a string")

let decode_vocab_leaf label of_string leaf =
  match json_string leaf with
  | Some value -> with_error_context label (of_string value)
  | None -> error (label ^ " must be a string")

let decode_bool_leaf label = function
  | Jsont.Bool (value, _) -> Ok value
  | Jsont.Null _ | Jsont.Number _ | Jsont.String _ | Jsont.Object _
  | Jsont.Array _ ->
      error (label ^ " must be a boolean")

let decode_positive_int_leaf label = function
  | Jsont.Number (value, _) -> json_number_to_positive_int label value
  | Jsont.Null _ | Jsont.Bool _ | Jsont.String _ | Jsont.Object _
  | Jsont.Array _ ->
      error (label ^ " must be an integer")

let json_null = Jsont.Json.null ()

let json_of_string_list values =
  Jsont.Json.list (List.map (fun value -> Jsont.Json.string value) values)

let string_list_to_text values =
  match Jsont_bytesrw.encode_string Jsont.json (json_of_string_list values) with
  | Ok text -> text
  | Error message -> invalid_arg message

let decode_string_list_leaf label = function
  | Jsont.Array (elements, _) ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | element :: rest ->
            let* value = decode_string_leaf label element in
            collect (value :: acc) rest
      in
      collect [] elements
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Object _ ->
      error (label ^ " must be a JSON array of strings")

let parse_string key raw =
  if String.is_empty raw then error (key ^ " must not be empty") else Ok raw

let parse_int key raw =
  match int_of_string_opt raw with
  | None -> error (key ^ " must be an integer")
  | Some value -> check_positive_int key value

let parse_bool key raw =
  match raw with
  | "true" -> Ok true
  | "false" -> Ok false
  | _ -> error (key ^ " must be true or false")

let parse_string_list key raw =
  match Jsont_bytesrw.decode_string Jsont.json raw with
  | Error _ ->
      error
        (key ^ " must be a JSON array of strings, for example [\"/a\", \"/b\"]")
  | Ok json -> decode_string_list_leaf key json

let check_string_elements label values =
  if List.exists String.is_empty values then error (label ^ " must not be empty")
  else Ok values

let validate_sandbox_roots label values =
  let valid spelling =
    String.equal spelling "~"
    || String.starts_with ~prefix:"~/" spelling
    || Result.is_ok (Lpath.Abs.of_string spelling)
  in
  let rec loop index = function
    | [] -> Ok values
    | spelling :: rest ->
        if valid spelling then loop (index + 1) rest
        else
          error
            (Printf.sprintf
               "%s[%d] must be absolute, \"~\", or start with \"~/\"" label
               index)
  in
  loop 0 values

(* [ocaml.merlin_program] is an argv prefix that reaches the Merlin transport
   and its execution permission. An empty list or an empty/NUL token would raise
   [Invalid_argument] mid-call there instead of refusing cleanly, so reject both
   at parse. *)
let validate_merlin_program key = function
  | [] -> error (key ^ " must not be empty")
  | values ->
      if
        List.exists
          (fun v -> String.is_empty v || String.contains v '\000')
          values
      then error (key ^ " elements must be non-empty and must not contain NUL")
      else Ok values

(* One [Type.Id.t] per domain type. Typed field reads recover a stored value's
   type by comparing the id of the queried field with the id of the field that
   stored it; the two ids are physically the same whenever the field names match
   (see [find]), so a shared per-type id is sufficient and no per-field witness
   is needed. *)
let string_id : string Type.Id.t = Type.Id.make ()
let bool_id : bool Type.Id.t = Type.Id.make ()
let int_id : int Type.Id.t = Type.Id.make ()
let selector_id : Mentat_provider.Selector.t Type.Id.t = Type.Id.make ()

let reasoning_id : Mentat_llm.Request.Options.Reasoning_effort.t Type.Id.t =
  Type.Id.make ()

let unattended_id : Mentat_permission.Unattended.t Type.Id.t = Type.Id.make ()
let mode_id : Mode.t Type.Id.t = Type.Id.make ()
let dune_watch_id : Dune_watch.t Type.Id.t = Type.Id.make ()
let require_id : Mentat_sandbox.Requirement.t Type.Id.t = Type.Id.make ()
let read_id : Read.t Type.Id.t = Type.Id.make ()
let env_inherit_id : Env_inherit.t Type.Id.t = Type.Id.make ()
let network_id : Mentat_sandbox.Policy.Network.t Type.Id.t = Type.Id.make ()
let string_list_id : string list Type.Id.t = Type.Id.make ()

(* A codec is the value-shape half of a field: how its domain value renders and
   parses as text (CLI [set_text]/[text]), how it validates as an
   already-typed value ([check], backing the typed [set]), and how it decodes
   and encodes as a JSON leaf (file load and write), plus the equality and
   type witness the binding map needs. Environment parsing, the built-in
   default, and the workspace-shared flag are per-field and live on the field
   [spec]. *)
type 'a codec = {
  type_id : 'a Type.Id.t;
  equal : 'a -> 'a -> bool;
  to_text : 'a -> string;
  parse_text : label:string -> string -> ('a, Error.t) result;
  check : label:string -> 'a -> ('a, Error.t) result;
  encode_json : 'a -> Jsont.json;
  decode_json : label:string -> Jsont.json -> ('a, Error.t) result;
  values : string list option;
      (* The closed vocabulary [parse_text], [check], and [decode_json] accept,
         in presentation order, or [None] when the codec parses an open shape
         (free strings, integers, lists). This is the single source for a
         field's allowed spellings: it lives on the codec beside the parser,
         so a value drawn from it always validates. *)
}

let string_codec =
  {
    type_id = string_id;
    equal = String.equal;
    to_text = Fun.id;
    parse_text = (fun ~label raw -> parse_string label raw);
    check = (fun ~label value -> parse_string label value);
    encode_json = (fun value -> Jsont.Json.string value);
    decode_json = (fun ~label leaf -> decode_string_leaf label leaf);
    values = None;
  }

let selector_codec =
  {
    type_id = selector_id;
    equal = Mentat_provider.Selector.equal;
    to_text = Mentat_provider.Selector.to_string;
    parse_text = (fun ~label raw -> parse_selector label raw);
    check = (fun ~label:_ value -> Ok value);
    encode_json =
      (fun value ->
        Jsont.Json.string (Mentat_provider.Selector.to_string value));
    decode_json = (fun ~label leaf -> decode_selector_leaf label leaf);
    values = None;
  }

let bool_codec =
  {
    type_id = bool_id;
    equal = Bool.equal;
    to_text = string_of_bool;
    parse_text = (fun ~label raw -> parse_bool label raw);
    check = (fun ~label:_ value -> Ok value);
    encode_json = (fun value -> Jsont.Json.bool value);
    decode_json = (fun ~label leaf -> decode_bool_leaf label leaf);
    values = Some [ "true"; "false" ];
  }

let int_codec =
  {
    type_id = int_id;
    equal = Int.equal;
    to_text = string_of_int;
    parse_text = (fun ~label raw -> parse_int label raw);
    check = (fun ~label value -> check_positive_int label value);
    encode_json = (fun value -> Jsont.Json.int value);
    decode_json = (fun ~label leaf -> decode_positive_int_leaf label leaf);
    values = None;
  }

let string_list_codec =
  {
    type_id = string_list_id;
    equal = List.equal String.equal;
    to_text = string_list_to_text;
    parse_text = (fun ~label raw -> parse_string_list label raw);
    check = (fun ~label values -> check_string_elements label values);
    encode_json = json_of_string_list;
    decode_json = (fun ~label leaf -> decode_string_list_leaf label leaf);
    values = None;
  }

(* A validated string list: [string_list_codec] with one [validate] run at
   every boundary — text, stored value, and JSON alike. The validator owns
   element checking too; one that wants the shared token-shape check
   composes {!check_string_elements} itself. *)
let validated_string_list_codec validate =
  {
    string_list_codec with
    parse_text =
      (fun ~label raw ->
        let* values = parse_string_list label raw in
        validate label values);
    check = (fun ~label values -> validate label values);
    decode_json =
      (fun ~label leaf ->
        let* values = decode_string_list_leaf label leaf in
        validate label values);
  }

let sandbox_roots_codec =
  validated_string_list_codec (fun label values ->
      let* values = check_string_elements label values in
      validate_sandbox_roots label values)

(* [dune.targets] entries are passed verbatim after [dune build --watch], and
   the field is workspace-shared — so a leading dash would let a project
   config smuggle dune flags ([-j1], [--force], a second [--root]) into the
   supervised argv under a knob documented as targets. *)
let validate_dune_targets label values =
  let rec loop index = function
    | [] -> Ok values
    | target :: rest ->
        if String.starts_with ~prefix:"-" target then
          error
            (Printf.sprintf "%s[%d] is a dune flag, not a build target: %s"
               label index target)
        else loop (index + 1) rest
  in
  loop 0 values

(* [dune.lint_command]: the linter's argv prefix, or [[]] to disable the
   runner — emptiness is a meaning here, not a mistake, so only the token
   shapes are validated. *)
let validate_lint_command key = function
  | [] -> Ok []
  | values -> validate_merlin_program key values

let lint_command_codec = validated_string_list_codec validate_lint_command

let dune_targets_codec =
  validated_string_list_codec (fun label values ->
      let* values = check_string_elements label values in
      validate_dune_targets label values)

let merlin_codec = validated_string_list_codec validate_merlin_program

(* A closed enum whose domain value has a dedicated type. Typed values need no
   [check]: the type is the invariant. [values] enumerates the enum's
   spellings, in [all] order, so a vocab codec's allowed set is derived from
   the same [all]/[to_text] the parser validates against — no separate
   spelling table to drift. *)
let vocab_codec ~type_id ~equal ~to_text ~all ~of_text =
  {
    type_id;
    equal;
    to_text;
    parse_text = (fun ~label:_ raw -> of_text raw);
    check = (fun ~label:_ value -> Ok value);
    encode_json = (fun value -> Jsont.Json.string (to_text value));
    decode_json = (fun ~label leaf -> decode_vocab_leaf label of_text leaf);
    values = Some (List.map to_text all);
  }

let reasoning_codec =
  vocab_codec ~type_id:reasoning_id ~equal:( = )
    ~to_text:Mentat_llm.Request.Options.Reasoning_effort.to_string
    ~all:Mentat_llm.Request.Options.Reasoning_effort.all
    ~of_text:reasoning_effort_of_string

let unattended_codec =
  vocab_codec ~type_id:unattended_id ~equal:Mentat_permission.Unattended.equal
    ~to_text:Mentat_permission.Unattended.to_string
    ~all:Mentat_permission.Unattended.all
    ~of_text:permission_unattended_of_string

let sandbox_mode_codec =
  vocab_codec ~type_id:mode_id ~equal:Mode.equal ~to_text:Mode.to_string
    ~all:Mode.all ~of_text:sandbox_mode_of_string

let sandbox_require_codec =
  vocab_codec ~type_id:require_id ~equal:Mentat_sandbox.Requirement.equal
    ~to_text:Mentat_sandbox.Requirement.to_string
    ~all:Mentat_sandbox.Requirement.all ~of_text:sandbox_require_of_string

let sandbox_read_codec =
  vocab_codec ~type_id:read_id ~equal:Read.equal ~to_text:Read.to_string
    ~all:Read.all ~of_text:sandbox_read_of_string

let sandbox_network_codec =
  vocab_codec ~type_id:network_id ~equal:Mentat_sandbox.Policy.Network.equal
    ~to_text:Mentat_sandbox.Policy.Network.to_string
    ~all:Mentat_sandbox.Policy.Network.all ~of_text:sandbox_network_of_string

(* A closed enum kept as a validated string, with no dedicated domain type.
   [spellings] is both the accepted set and the exposed vocabulary; the typed
   [check] validates the same spelling set the text parser accepts. *)
let string_enum_codec ~spellings of_text =
  {
    type_id = string_id;
    equal = String.equal;
    to_text = Fun.id;
    parse_text = (fun ~label:_ raw -> of_text raw);
    check = (fun ~label:_ value -> of_text value);
    encode_json = (fun value -> Jsont.Json.string value);
    decode_json = (fun ~label leaf -> decode_vocab_leaf label of_text leaf);
    values = Some spellings;
  }

let tools_editor_codec =
  string_enum_codec ~spellings:tools_editor_spellings tools_editor_of_string

let sandbox_env_inherit_codec =
  vocab_codec ~type_id:env_inherit_id ~equal:Env_inherit.equal
    ~to_text:Env_inherit.to_string ~all:Env_inherit.all
    ~of_text:sandbox_env_inherit_of_string

let workspace_tooling_codec =
  string_enum_codec ~spellings:workspace_tooling_spellings
    workspace_tooling_of_string

let dune_watch_codec =
  vocab_codec ~type_id:dune_watch_id ~equal:Dune_watch.equal
    ~to_text:Dune_watch.to_string ~all:Dune_watch.all
    ~of_text:dune_watch_of_string

let tui_diff_layout_codec =
  string_enum_codec ~spellings:tui_diff_layout_spellings
    tui_diff_layout_of_string

let web_search_provider_codec =
  string_enum_codec ~spellings:web_search_provider_spellings
    web_search_provider_of_string

let notify_channel_codec =
  string_enum_codec ~spellings:Notify.Channel.values notify_channel_of_string

let notify_when_codec =
  string_enum_codec ~spellings:Notify.When.values notify_when_of_string

module Field = struct
  (* Phantom indexes for a field's defaultedness. A [defaulted] field carries a
     built-in default in its [spec] row, so resolved reads of it are total; an
     [optional] field carries none. The [default] witness below ties the index
     to the table, so the invariant is compiler-checked per row. *)
  type defaulted = |
  type optional = |

  type ('a, 'd) t =
    | Model : (Mentat_provider.Selector.t, optional) t
    | Small_model : (Mentat_provider.Selector.t, optional) t
    | Reasoning : (Mentat_llm.Request.Options.Reasoning_effort.t, optional) t
    | Tui_thinking : (bool, defaulted) t
    | Tui_mouse : (bool, defaulted) t
    | Notify_enabled : (bool, defaulted) t
    | Notify_channel : (string, defaulted) t
    | Notify_when : (string, defaulted) t
    | Notify_command : (string list, defaulted) t
    | Notify_on : (string list, defaulted) t
    | Tui_theme : (string, defaulted) t
    | Tui_theme_dark : (string, defaulted) t
    | Tui_theme_light : (string, defaulted) t
    | Tui_diff_layout : (string, defaulted) t
    | Provider_base_url : Mentat_llm.Provider.t -> (string, optional) t
    | Run_max_steps : (int, optional) t
    | Run_subagent_max_concurrent : (int, defaulted) t
    | Run_subagent_max_depth : (int, defaulted) t
    | Run_subagent_max_exchanges : (int, defaulted) t
    | Permission_unattended : (Mentat_permission.Unattended.t, defaulted) t
    | Sandbox_mode : (Mode.t, optional) t
    | Sandbox_require : (Mentat_sandbox.Requirement.t, defaulted) t
    | Sandbox_read : (Read.t, defaulted) t
    | Sandbox_readable_roots : (string list, defaulted) t
    | Sandbox_writable_roots : (string list, defaulted) t
    | Sandbox_network : (Mentat_sandbox.Policy.Network.t, defaulted) t
    | Sandbox_env_inherit : (Env_inherit.t, defaulted) t
    | Sandbox_env_exclude : (string list, defaulted) t
    | Sandbox_env_include_only : (string list, defaulted) t
    | Shell : (string, defaulted) t
    | Compaction_auto : (bool, defaulted) t
    | Revert_merge : (bool, defaulted) t
    | Notices_fswatch : (bool, defaulted) t
    | Notices_cr_comments : (bool, defaulted) t
    | Notices_dune_diagnostics : (bool, defaulted) t
    | Dune_watch : (Dune_watch.t, defaulted) t
    | Dune_targets : (string list, defaulted) t
    | Dune_lint_command : (string list, defaulted) t
    | Workspace_tooling : (string, defaulted) t
    | Instructions_global : (bool, defaulted) t
    | Instructions_project : (bool, defaulted) t
    | Instructions_claude_md : (bool, defaulted) t
    | Instructions_project_max_bytes : (int, defaulted) t
    | Skills_enabled : (bool, defaulted) t
    | Skills_builtin : (bool, defaulted) t
    | Skills_project : (bool, defaulted) t
    | Skills_compat : (bool, defaulted) t
    | Skills_disabled : (string list, defaulted) t
    | Skills_paths : (string list, defaulted) t
    | Skills_catalog_max_bytes : (int, defaulted) t
    | Commands_enabled : (bool, defaulted) t
    | Commands_project : (bool, defaulted) t
    | Commands_compat : (bool, defaulted) t
    | Commands_disabled : (string list, defaulted) t
    | Tools_editor : (string, defaulted) t
    | Ocaml_merlin_program : (string list, defaulted) t
    | Web_enabled : (bool, defaulted) t
    | Web_allow_private_network : (bool, defaulted) t
    | Web_fetch_max_bytes : (int, defaulted) t
    | Web_output_max_chars : (int, defaulted) t
    | Web_timeout_ms : (int, defaulted) t
    | Web_max_timeout_ms : (int, defaulted) t
    | Web_search_provider : (string, defaulted) t
    | Web_exa_api_key : (string, optional) t
    | Web_parallel_api_key : (string, optional) t
    | Image_max_bytes : (int, defaulted) t
    | Image_max_dimension : (int, defaulted) t
    | Image_max_count : (int, defaulted) t

  type any = Any : ('a, 'd) t -> any

  let model = Model
  let small_model = Small_model
  let reasoning = Reasoning
  let tui_thinking = Tui_thinking
  let tui_mouse = Tui_mouse
  let notify_enabled = Notify_enabled
  let notify_channel = Notify_channel
  let notify_when = Notify_when
  let notify_command = Notify_command
  let notify_on = Notify_on
  let tui_theme = Tui_theme
  let tui_theme_dark = Tui_theme_dark
  let tui_theme_light = Tui_theme_light
  let tui_diff_layout = Tui_diff_layout
  let provider_base_url provider = Provider_base_url provider
  let run_max_steps = Run_max_steps
  let run_subagent_max_concurrent = Run_subagent_max_concurrent
  let run_subagent_max_depth = Run_subagent_max_depth
  let run_subagent_max_exchanges = Run_subagent_max_exchanges
  let permission_unattended = Permission_unattended
  let sandbox_mode = Sandbox_mode
  let sandbox_require = Sandbox_require
  let sandbox_read = Sandbox_read
  let sandbox_readable_roots = Sandbox_readable_roots
  let sandbox_writable_roots = Sandbox_writable_roots
  let sandbox_network = Sandbox_network
  let sandbox_env_inherit = Sandbox_env_inherit
  let sandbox_env_exclude = Sandbox_env_exclude
  let sandbox_env_include_only = Sandbox_env_include_only
  let shell = Shell
  let compaction_auto = Compaction_auto
  let revert_merge = Revert_merge
  let notices_fswatch = Notices_fswatch
  let notices_cr_comments = Notices_cr_comments
  let notices_dune_diagnostics = Notices_dune_diagnostics
  let dune_watch = Dune_watch
  let dune_targets = Dune_targets
  let dune_lint_command = Dune_lint_command
  let workspace_tooling = Workspace_tooling
  let instructions_global = Instructions_global
  let instructions_project = Instructions_project
  let instructions_claude_md = Instructions_claude_md
  let instructions_project_max_bytes = Instructions_project_max_bytes
  let skills_enabled = Skills_enabled
  let skills_builtin = Skills_builtin
  let skills_project = Skills_project
  let skills_compat = Skills_compat
  let skills_disabled = Skills_disabled
  let skills_paths = Skills_paths
  let skills_catalog_max_bytes = Skills_catalog_max_bytes
  let commands_enabled = Commands_enabled
  let commands_project = Commands_project
  let commands_compat = Commands_compat
  let commands_disabled = Commands_disabled
  let tools_editor = Tools_editor
  let ocaml_merlin_program = Ocaml_merlin_program
  let web_enabled = Web_enabled
  let web_allow_private_network = Web_allow_private_network
  let web_fetch_max_bytes = Web_fetch_max_bytes
  let web_output_max_chars = Web_output_max_chars
  let web_timeout_ms = Web_timeout_ms
  let web_max_timeout_ms = Web_max_timeout_ms
  let web_search_provider = Web_search_provider
  let web_exa_api_key = Web_exa_api_key
  let web_parallel_api_key = Web_parallel_api_key
  let image_max_bytes = Image_max_bytes
  let image_max_dimension = Image_max_dimension
  let image_max_count = Image_max_count

  let name : type a d. (a, d) t -> string = function
    | Model -> "model"
    | Small_model -> "small_model"
    | Reasoning -> "reasoning"
    | Tui_thinking -> "tui.thinking"
    | Tui_mouse -> "tui.mouse"
    | Notify_enabled -> "notify.enabled"
    | Notify_channel -> "notify.channel"
    | Notify_when -> "notify.when"
    | Notify_command -> "notify.command"
    | Notify_on -> "notify.on"
    | Tui_theme -> "tui.theme"
    | Tui_theme_dark -> "tui.theme_dark"
    | Tui_theme_light -> "tui.theme_light"
    | Tui_diff_layout -> "tui.diff_layout"
    | Provider_base_url provider ->
        "providers." ^ Mentat_llm.Provider.id provider ^ ".base_url"
    | Run_max_steps -> "run.max_steps"
    | Run_subagent_max_concurrent -> "run.subagent_max_concurrent"
    | Run_subagent_max_depth -> "run.subagent_max_depth"
    | Run_subagent_max_exchanges -> "run.subagent_max_exchanges"
    | Permission_unattended -> "permission.unattended"
    | Sandbox_mode -> "sandbox.mode"
    | Sandbox_require -> "sandbox.require"
    | Sandbox_read -> "sandbox.read"
    | Sandbox_readable_roots -> "sandbox.readable_roots"
    | Sandbox_writable_roots -> "sandbox.writable_roots"
    | Sandbox_network -> "sandbox.network"
    | Sandbox_env_inherit -> "sandbox.env_inherit"
    | Sandbox_env_exclude -> "sandbox.env_exclude"
    | Sandbox_env_include_only -> "sandbox.env_include_only"
    | Shell -> "shell"
    | Compaction_auto -> "compaction.auto"
    | Revert_merge -> "revert.merge"
    | Notices_fswatch -> "notices.fswatch"
    | Notices_cr_comments -> "notices.cr_comments"
    | Notices_dune_diagnostics -> "notices.dune_diagnostics"
    | Dune_watch -> "dune.watch"
    | Dune_targets -> "dune.targets"
    | Dune_lint_command -> "dune.lint_command"
    | Workspace_tooling -> "workspace.tooling"
    | Instructions_global -> "instructions.global"
    | Instructions_project -> "instructions.project"
    | Instructions_claude_md -> "instructions.claude_md"
    | Instructions_project_max_bytes -> "instructions.project_max_bytes"
    | Skills_enabled -> "skills.enabled"
    | Skills_builtin -> "skills.builtin"
    | Skills_project -> "skills.project"
    | Skills_compat -> "skills.compat"
    | Skills_disabled -> "skills.disabled"
    | Skills_paths -> "skills.paths"
    | Skills_catalog_max_bytes -> "skills.catalog_max_bytes"
    | Commands_enabled -> "commands.enabled"
    | Commands_project -> "commands.project"
    | Commands_compat -> "commands.compat"
    | Commands_disabled -> "commands.disabled"
    | Tools_editor -> "tools.editor"
    | Ocaml_merlin_program -> "ocaml.merlin_program"
    | Web_enabled -> "web.enabled"
    | Web_allow_private_network -> "web.allow_private_network"
    | Web_fetch_max_bytes -> "web.fetch_max_bytes"
    | Web_output_max_chars -> "web.output_max_chars"
    | Web_timeout_ms -> "web.timeout_ms"
    | Web_max_timeout_ms -> "web.max_timeout_ms"
    | Web_search_provider -> "web.search_provider"
    | Web_exa_api_key -> "web.exa_api_key"
    | Web_parallel_api_key -> "web.parallel_api_key"
    | Image_max_bytes -> "image.max_bytes"
    | Image_max_dimension -> "image.max_dimension"
    | Image_max_count -> "image.max_count"

  let equal a b = String.equal (name a) (name b)

  (* [scheme://userinfo@host/…] with the credential-bearing userinfo replaced.
     The scan is deliberately narrow — the authority is what follows ["://"] up
     to the next ['/'], ['?'] or ['#'], and the credential a URL can carry lives
     only before that authority's last ['@'] — so a value that is not a URL, or
     one that carries no userinfo, renders verbatim. *)
  let without_userinfo url =
    let len = String.length url in
    let rec authority_start i =
      if i + 2 >= len then None
      else if url.[i] = ':' && url.[i + 1] = '/' && url.[i + 2] = '/' then
        Some (i + 3)
      else authority_start (i + 1)
    in
    let rec authority_end i =
      if i >= len then i
      else match url.[i] with '/' | '?' | '#' -> i | _ -> authority_end (i + 1)
    in
    let rec last_at i stop found =
      if i >= stop then found
      else last_at (i + 1) stop (if url.[i] = '@' then Some i else found)
    in
    match authority_start 0 with
    | None -> url
    | Some start -> (
        match last_at start (authority_end start) None with
        | None -> url
        | Some at ->
            (* [at] is the ['@'], so the tail keeps its own separator. *)
            let tail = String.sub url at (len - at) in
            String.sub url 0 start ^ "[REDACTED]" ^ tail)

  (* What the diagnostic values-with-origins view may show of a value. [None]
     withholds it entirely. Enumerated in full — never a wildcard default — so
     adding a field is a compile-time obligation to classify it, keeping "never
     emit a secret" a construction fact rather than a forgotten default.

     An API key shows nothing. A provider base URL shows its endpoint with any
     userinfo stripped: the credential a URL can carry
     ([https://user:token@host]) lives only there, while the host is the whole
     answer to "which endpoint is this talking to" — and withholding the answer
     to that is how a wrong endpoint stays invisible. *)
  let shown : type a d. (a, d) t -> a -> a option =
   fun field value ->
    match field with
    | Web_exa_api_key | Web_parallel_api_key -> None
    | Provider_base_url _ -> Some (without_userinfo value)
    | Model | Small_model | Reasoning | Tui_thinking | Tui_mouse
    | Notify_enabled | Notify_channel | Notify_when | Notify_command | Notify_on
    | Tui_theme | Tui_theme_dark | Tui_theme_light | Tui_diff_layout
    | Run_max_steps | Run_subagent_max_concurrent | Run_subagent_max_depth
    | Run_subagent_max_exchanges | Permission_unattended | Sandbox_mode
    | Sandbox_require | Sandbox_read | Sandbox_readable_roots
    | Sandbox_writable_roots | Sandbox_network | Sandbox_env_inherit
    | Sandbox_env_exclude | Sandbox_env_include_only | Shell | Compaction_auto
    | Revert_merge | Notices_fswatch | Notices_cr_comments
    | Notices_dune_diagnostics | Dune_watch | Dune_targets | Dune_lint_command
    | Workspace_tooling
    | Instructions_global | Instructions_project | Instructions_claude_md
    | Instructions_project_max_bytes | Skills_enabled | Skills_builtin
    | Skills_project | Skills_compat | Skills_disabled | Skills_paths
    | Skills_catalog_max_bytes | Commands_enabled | Commands_project
    | Commands_compat | Commands_disabled | Tools_editor | Ocaml_merlin_program
    | Web_enabled | Web_allow_private_network | Web_fetch_max_bytes
    | Web_output_max_chars | Web_timeout_ms | Web_max_timeout_ms
    | Web_search_provider | Image_max_bytes | Image_max_dimension
    | Image_max_count ->
        Some value

  (* The non-provider-family fields, in the stable order exposed by {!all}. The
     provider base URL family is a parameterized field spliced in after
     [reasoning] by key-ordered surfaces (see [with_provider_family]). *)
  let all =
    [
      Any Model;
      Any Small_model;
      Any Reasoning;
      Any Tui_thinking;
      Any Tui_mouse;
      Any Notify_enabled;
      Any Notify_channel;
      Any Notify_when;
      Any Notify_command;
      Any Notify_on;
      Any Tui_theme;
      Any Tui_theme_dark;
      Any Tui_theme_light;
      Any Tui_diff_layout;
      Any Run_max_steps;
      Any Run_subagent_max_concurrent;
      Any Run_subagent_max_depth;
      Any Run_subagent_max_exchanges;
      Any Permission_unattended;
      Any Sandbox_mode;
      Any Sandbox_require;
      Any Sandbox_read;
      Any Sandbox_readable_roots;
      Any Sandbox_writable_roots;
      Any Sandbox_network;
      Any Sandbox_env_inherit;
      Any Sandbox_env_exclude;
      Any Sandbox_env_include_only;
      Any Shell;
      Any Compaction_auto;
      Any Revert_merge;
      Any Notices_fswatch;
      Any Notices_cr_comments;
      Any Notices_dune_diagnostics;
      Any Dune_watch;
      Any Dune_targets;
      Any Dune_lint_command;
      Any Workspace_tooling;
      Any Instructions_global;
      Any Instructions_project;
      Any Instructions_claude_md;
      Any Instructions_project_max_bytes;
      Any Skills_enabled;
      Any Skills_builtin;
      Any Skills_project;
      Any Skills_compat;
      Any Skills_disabled;
      Any Skills_paths;
      Any Skills_catalog_max_bytes;
      Any Commands_enabled;
      Any Commands_project;
      Any Commands_compat;
      Any Commands_disabled;
      Any Tools_editor;
      Any Ocaml_merlin_program;
      Any Web_enabled;
      Any Web_allow_private_network;
      Any Web_fetch_max_bytes;
      Any Web_output_max_chars;
      Any Web_timeout_ms;
      Any Web_max_timeout_ms;
      Any Web_search_provider;
      Any Web_exa_api_key;
      Any Web_parallel_api_key;
      Any Image_max_bytes;
      Any Image_max_dimension;
      Any Image_max_count;
    ]

  let supported_key_spellings =
    List.concat_map
      (fun (Any field) ->
        name field
        ::
        (match field with
        | Reasoning -> [ "providers.<provider>.base_url" ]
        | _ -> []))
      all

  let supported_key_hint =
    "supported keys: " ^ String.concat ", " supported_key_spellings

  (* Scalar keys derive from {!all} and {!name}: a key names a field iff some
     field in [all] spells it. [permission.rules] is matched first — it is
     structured config, absent from [all], and needs its own structured hint —
     and the provider base URL family and did-you-mean fallback close the rest.
     Keeping this a lookup over [all] (rather than a parallel string table) means
     a new field is reachable by [config get/set] the moment it enters [all]. *)
  let of_string key =
    match key with
    | "permission.rules" ->
        error
          ~hints:
            [
              "permission rules are structured config: edit the config file \
               directly, then inspect with `mentat permission list` and remove \
               with `mentat permission remove`";
            ]
          "config key permission.rules is not a scalar value"
    | _ -> (
        match
          List.find_opt (fun (Any field) -> String.equal (name field) key) all
        with
        | Some any -> Ok any
        | None -> (
            match String.split_on_char '.' key with
            | [ "providers"; provider; "base_url" ] -> (
                try
                  Ok
                    (Any (Provider_base_url (Mentat_llm.Provider.make provider)))
                with Invalid_argument message ->
                  invalid_provider_id provider message)
            | "providers" :: _ ->
                error
                  ~hints:
                    [
                      "provider keys are spelled providers.<provider>.base_url";
                      supported_key_hint;
                    ]
                  ("unknown config key: " ^ key)
            | _ ->
                error
                  ~hints:
                    (Mentat_diagnostic.did_you_mean key
                       ~candidates:supported_key_spellings
                    @ [ supported_key_hint ])
                  ("unknown config key: " ^ key)))

  (* The per-field description: its codec, its optional environment override
     (variable name and parser), whether workspace config may set it, and its
     built-in default. The [default] witness is indexed by the field's
     defaultedness, so a [defaulted] field cannot omit its default and an
     [optional] field cannot smuggle one in — the table is compiler-checked
     row by row. Adding a config field touches six sites here — the [t]
     constructor, its lowercase value binding, its [name] case, its [shown]
     classification (the security arm: what a diagnostic view may show of a
     value that can carry a credential), its [all] entry, and its [spec] row —
     plus the value's
     [val] in the .mli. [of_string] is not among them: it derives from [all] and
     [name]. *)
  type ('a, 'd) default =
    | Default :
        ((string -> string option) -> 'a * string)
        -> ('a, defaulted) default
    | No_default : ('a, optional) default

  type ('a, 'd) spec = {
    codec : 'a codec;
    env : (string * (string -> ('a, Error.t) result)) option;
    shared : bool;
    default : ('a, 'd) default;
  }

  let optional ?env ?(shared = false) codec =
    { codec; env; shared; default = No_default }

  let defaulted ?env ?(shared = false) ~default codec =
    { codec; env; shared; default = Default default }

  let builtin field value _getenv = (value, "built-in " ^ name field)

  let provider_env_var provider =
    "MENTAT_"
    ^ (String.uppercase_ascii (Mentat_llm.Provider.id provider)
      |> String.map (function ('A' .. 'Z' | '0' .. '9') as c -> c | _ -> '_'))
    ^ "_BASE_URL"

  let spec : type a d. (a, d) t -> (a, d) spec =
   fun field ->
    match field with
    | Model ->
        optional selector_codec ~shared:true
          ~env:("MENTAT_MODEL", parse_selector "MENTAT_MODEL")
    | Small_model ->
        optional selector_codec ~shared:true
          ~env:("MENTAT_SMALL_MODEL", parse_selector "MENTAT_SMALL_MODEL")
    | Reasoning ->
        optional reasoning_codec ~shared:true
          ~env:("MENTAT_REASONING", reasoning_effort_of_string)
    | Tui_thinking -> defaulted bool_codec ~default:(builtin field true)
    | Tui_mouse ->
        defaulted bool_codec ~default:(fun getenv ->
            match env_non_empty getenv "MENTAT_DISABLE_MOUSE" with
            | Some _ -> (false, "MENTAT_DISABLE_MOUSE")
            | None -> builtin field true getenv)
    | Notify_enabled -> defaulted bool_codec ~default:(builtin field true)
    | Notify_channel ->
        defaulted notify_channel_codec
          ~default:(builtin field Notify.Channel.(to_string Auto))
    | Notify_when ->
        defaulted notify_when_codec
          ~default:(builtin field Notify.When.(to_string Unfocused))
    | Notify_command -> defaulted string_list_codec ~default:(builtin field [])
    | Notify_on ->
        defaulted string_list_codec ~default:(builtin field Notify.Event.values)
    | Tui_theme -> defaulted string_codec ~default:(builtin field "mentat-dark")
    | Tui_theme_dark ->
        defaulted string_codec ~default:(builtin field "mentat-dark")
    | Tui_theme_light ->
        defaulted string_codec ~default:(builtin field "mentat-light")
    | Tui_diff_layout ->
        defaulted tui_diff_layout_codec ~default:(builtin field "auto")
    | Provider_base_url provider ->
        optional string_codec
          ~env:(provider_env_var provider, parse_string (name field))
    | Run_max_steps ->
        optional int_codec ~shared:true
          ~env:
            ( "MENTAT_MAX_STEPS",
              fun raw ->
                match int_of_string_opt raw with
                | None -> error "MENTAT_MAX_STEPS must be a positive integer"
                | Some value -> check_positive_int "MENTAT_MAX_STEPS" value )
    | Run_subagent_max_concurrent ->
        defaulted int_codec ~default:(builtin field 4)
    | Run_subagent_max_depth -> defaulted int_codec ~default:(builtin field 2)
    | Run_subagent_max_exchanges ->
        defaulted int_codec ~default:(builtin field 8)
    | Permission_unattended ->
        defaulted unattended_codec ~shared:true
          ~default:(builtin field Mentat_permission.Unattended.Block)
          ~env:("MENTAT_PERMISSION_UNATTENDED", permission_unattended_of_string)
    | Sandbox_mode ->
        optional sandbox_mode_codec
          ~env:("MENTAT_SANDBOX_MODE", sandbox_mode_of_string)
    | Sandbox_require ->
        defaulted sandbox_require_codec
          ~default:(builtin field Mentat_sandbox.Requirement.Enforced)
          ~env:("MENTAT_SANDBOX_REQUIRE", sandbox_require_of_string)
    | Sandbox_read ->
        defaulted sandbox_read_codec
          ~default:(builtin field Read.Project)
          ~env:("MENTAT_SANDBOX_READ", sandbox_read_of_string)
    | Sandbox_readable_roots ->
        defaulted sandbox_roots_codec ~default:(builtin field [])
    | Sandbox_writable_roots ->
        defaulted sandbox_roots_codec ~default:(builtin field [])
    | Sandbox_network ->
        defaulted sandbox_network_codec
          ~default:(builtin field Mentat_sandbox.Policy.Network.Restricted)
          ~env:("MENTAT_SANDBOX_NETWORK", sandbox_network_of_string)
    | Sandbox_env_inherit ->
        defaulted sandbox_env_inherit_codec
          ~default:(builtin field Env_inherit.Allowlist)
          ~env:("MENTAT_SANDBOX_ENV_INHERIT", sandbox_env_inherit_of_string)
    | Sandbox_env_exclude ->
        defaulted string_list_codec ~default:(builtin field [])
    | Sandbox_env_include_only ->
        defaulted string_list_codec ~default:(builtin field [])
    | Shell ->
        defaulted string_codec
          ~env:("MENTAT_SHELL", parse_string "shell")
          ~default:(fun getenv ->
            let reason =
              if String.equal Filename.dir_sep "\\" then
                match env_non_empty getenv "COMSPEC" with
                | Some _ -> "COMSPEC"
                | None -> "built-in shell"
              else
                match env_non_empty getenv "SHELL" with
                | Some _ -> "SHELL"
                | None -> "built-in shell"
            in
            (default_shell_program getenv, reason))
    | Compaction_auto -> defaulted bool_codec ~default:(builtin field true)
    | Revert_merge -> defaulted bool_codec ~default:(builtin field true)
    | Notices_fswatch -> defaulted bool_codec ~default:(builtin field true)
    | Notices_cr_comments -> defaulted bool_codec ~default:(builtin field true)
    | Notices_dune_diagnostics ->
        defaulted bool_codec ~default:(builtin field true)
    | Dune_watch ->
        defaulted dune_watch_codec ~shared:true
          ~default:(builtin field Dune_watch.Auto)
          ~env:("MENTAT_DUNE_WATCH", dune_watch_of_string)
    | Dune_targets ->
        defaulted dune_targets_codec ~shared:true
          ~default:(builtin field [ "@check" ])
    | Dune_lint_command ->
        defaulted lint_command_codec ~shared:true
          ~default:
            (builtin field [ "litany"; "check"; "--no-build"; "--trust-build" ])
    | Workspace_tooling ->
        defaulted workspace_tooling_codec ~shared:true
          ~default:(builtin field "auto")
          ~env:("MENTAT_WORKSPACE_TOOLING", workspace_tooling_of_string)
    | Instructions_global -> defaulted bool_codec ~default:(builtin field true)
    | Instructions_project -> defaulted bool_codec ~default:(builtin field true)
    | Instructions_claude_md ->
        defaulted bool_codec ~default:(builtin field true)
    | Instructions_project_max_bytes ->
        defaulted int_codec
          ~default:(builtin field default_instructions_project_max_bytes)
    | Skills_enabled -> defaulted bool_codec ~default:(builtin field true)
    | Skills_builtin -> defaulted bool_codec ~default:(builtin field true)
    | Skills_project -> defaulted bool_codec ~default:(builtin field true)
    | Skills_compat -> defaulted bool_codec ~default:(builtin field true)
    | Skills_disabled -> defaulted string_list_codec ~default:(builtin field [])
    | Skills_paths -> defaulted string_list_codec ~default:(builtin field [])
    | Skills_catalog_max_bytes ->
        defaulted int_codec
          ~default:(builtin field default_skills_catalog_max_bytes)
    | Commands_enabled -> defaulted bool_codec ~default:(builtin field true)
    | Commands_project -> defaulted bool_codec ~default:(builtin field true)
    | Commands_compat -> defaulted bool_codec ~default:(builtin field true)
    | Commands_disabled ->
        defaulted string_list_codec ~default:(builtin field [])
    | Tools_editor ->
        defaulted tools_editor_codec ~shared:true
          ~default:(builtin field "auto")
    | Ocaml_merlin_program ->
        (* The built-in ["ocamlmerlin"] mirrors [Mentat_tools.Ocaml_merlin]'s
           [default_program], the ground truth for the Merlin transport. The
           pure core inlines the constant rather than link the resource
           library. *)
        defaulted merlin_codec ~default:(builtin field [ "ocamlmerlin" ])
    | Web_enabled -> defaulted bool_codec ~default:(builtin field false)
    | Web_allow_private_network ->
        defaulted bool_codec ~default:(builtin field false)
    | Web_fetch_max_bytes ->
        defaulted int_codec ~default:(builtin field default_web_fetch_max_bytes)
    | Web_output_max_chars ->
        defaulted int_codec
          ~default:(builtin field default_web_output_max_chars)
    | Web_timeout_ms ->
        defaulted int_codec ~default:(builtin field default_web_timeout_ms)
    | Web_max_timeout_ms ->
        defaulted int_codec ~default:(builtin field default_web_max_timeout_ms)
    | Web_search_provider ->
        defaulted web_search_provider_codec ~default:(builtin field "exa")
    | Web_exa_api_key ->
        optional string_codec
          ~env:("MENTAT_EXA_API_KEY", parse_string "web.exa_api_key")
    | Web_parallel_api_key ->
        optional string_codec
          ~env:("MENTAT_PARALLEL_API_KEY", parse_string "web.parallel_api_key")
    | Image_max_bytes ->
        defaulted int_codec ~default:(builtin field default_image_max_bytes)
    | Image_max_dimension ->
        defaulted int_codec ~default:(builtin field default_image_max_dimension)
    | Image_max_count ->
        defaulted int_codec ~default:(builtin field default_image_max_count)

  let codec : type a d. (a, d) t -> a codec = fun field -> (spec field).codec

  let env_var : type a d.
      (a, d) t -> (string * (string -> (a, Error.t) result)) option =
   fun field -> (spec field).env

  let default : type a d. (a, d) t -> (a, d) default =
   fun field -> (spec field).default

  (* [values] is derived from the spec table, so a field's allowed spellings
     live once — on the codec, beside the parser that accepts them. *)
  let values field = (codec field).values
  let allowed_in_workspace field = (spec field).shared
end

(* Fields keyed in key-order surfaces list the provider base URL family after
   [reasoning]. *)
let with_provider_family providers =
  List.concat_map
    (fun (Field.Any field as any) ->
      any :: (match field with Field.Reasoning -> providers | _ -> []))
    Field.all

(* The configuration carrier: a heterogeneous map of field bindings keyed by
   field name, plus the structured [permission.rules]. Rules are outside the
   field-key system: they are a concat-merged monoid, not a replace-on-merge
   scalar, and are never addressable through a {!Field.t}. *)

module Name_map = Map.Make (String)

type binding = B : ('a, 'd) Field.t * 'a -> binding

type t = {
  scalars : binding Name_map.t;
  rules : Mentat_permission.Policy.Rule.t list;
}

let empty = { scalars = Name_map.empty; rules = [] }

let find : type a d. (a, d) Field.t -> t -> a option =
 fun field t ->
  match Name_map.find_opt (Field.name field) t.scalars with
  | None -> None
  | Some (B (stored, value)) -> (
      (* The stored field has the same name as [field], hence the same
         constructor and the same per-type id, so this witness always holds;
         the [None] arm is unreachable but keeps the recovery total. *)
      match
        Type.Id.provably_equal (Field.codec field).type_id
          (Field.codec stored).type_id
      with
      | Some Type.Equal -> Some value
      | None -> None)

(* Internal unvalidated update; the public [set]/[set_text] validate first,
   and the file decoder validates through the codec's [decode_json]. *)
let set_binding field value t =
  match value with
  | None -> { t with scalars = Name_map.remove (Field.name field) t.scalars }
  | Some value ->
      {
        t with
        scalars = Name_map.add (Field.name field) (B (field, value)) t.scalars;
      }

let set field value t =
  let* value = (Field.codec field).check ~label:(Field.name field) value in
  Ok (set_binding field (Some value) t)

let set_text field raw t =
  let* value = (Field.codec field).parse_text ~label:(Field.name field) raw in
  Ok (set_binding field (Some value) t)

let unset field t = set_binding field None t
let text field t = Option.map (Field.codec field).to_text (find field t)

let json field t =
  match find field t with
  | Some value -> (Field.codec field).encode_json value
  | None -> json_null

let permission_rules t = t.rules
let set_permission_rules rules t = { t with rules }

let binding_equal (B (fa, va)) (B (fb, vb)) =
  match
    Type.Id.provably_equal (Field.codec fa).type_id (Field.codec fb).type_id
  with
  | Some Type.Equal -> (Field.codec fa).equal va vb
  | None -> false

let equal a b =
  Name_map.equal binding_equal a.scalars b.scalars
  && List.equal Mentat_permission.Policy.Rule.equal a.rules b.rules

let merge ~low ~high =
  {
    scalars =
      Name_map.union (fun _name _low high -> Some high) low.scalars high.scalars;
    (* Rules concatenate high before low: the merged layer's rules are the
       effective durable order, mirroring first-match precedence. *)
    rules =
      (match (low.rules, high.rules) with
      | rules, [] | [], rules -> rules
      | low, high -> high @ low);
  }

let merge_all layers =
  List.fold_left (fun low high -> merge ~low ~high) empty layers

let provider_base_url ~provider t = find (Field.Provider_base_url provider) t

let provider_base_urls t =
  Name_map.bindings t.scalars
  |> List.filter_map
       (fun
         (_name, B (field, value)) : (Mentat_llm.Provider.t * string) option ->
         match field with
         | Field.Provider_base_url provider -> Some (provider, value)
         | _ -> None)
  |> List.sort (fun (a, _) (b, _) -> Mentat_llm.Provider.compare a b)

(* Configured provider fields, ordered by provider id. *)
let provider_keys t =
  provider_base_urls t
  |> List.map (fun (provider, _) ->
      Field.Any (Field.Provider_base_url provider))

(* Configured fields in key order, with the provider family after
   [reasoning]. *)
let keys t =
  let providers = provider_keys t in
  List.concat_map
    (fun (Field.Any field as any) ->
      (if Name_map.mem (Field.name field) t.scalars then [ any ] else [])
      @ match field with Field.Reasoning -> providers | _ -> [])
    Field.all

let origins_of_layers layers =
  List.fold_left
    (fun origins (source, layer) ->
      List.fold_left
        (fun origins (Field.Any field as any) ->
          let name = Field.name field in
          let shadowed =
            match Name_map.find_opt name origins with
            | None -> []
            | Some (_, origin) -> Origin.source origin :: Origin.shadowed origin
          in
          Name_map.add name (any, Origin.make ~source ~shadowed) origins)
        origins (keys layer))
    Name_map.empty layers

let origin_with_defaults getenv origins =
  List.fold_left
    (fun origins (Field.Any field as any) ->
      match Field.default field with
      | Field.No_default -> origins
      | Field.Default default ->
          let name = Field.name field in
          if Name_map.mem name origins then origins
          else
            let _value, reason = default getenv in
            Name_map.add name
              (any, Origin.make ~source:(Source.Default { reason }) ~shadowed:[])
              origins)
    origins Field.all

(* File report order: top-level scalar fields, then the provider family, then
   nested sections, all derived from the field list. Loading, validation, and
   the file encoder fold the same order, so first-error reports, collect-all
   reports, and written field order stay aligned. *)
type file_unit = Key of Field.any | Providers | Section of string

let field_path field = String.split_on_char '.' (Field.name field)

let file_units =
  let top_level, sections =
    List.fold_left
      (fun (top_level, sections) (Field.Any field as any) ->
        match field_path field with
        | [ _ ] -> (top_level @ [ Key any ], sections)
        | head :: _ :: _ when not (List.exists (String.equal head) sections) ->
            (top_level, sections @ [ head ])
        | _ -> (top_level, sections))
      ([], []) Field.all
  in
  top_level @ (Providers :: List.map (fun head -> Section head) sections)

let section_keys head =
  List.filter
    (fun (Field.Any field) ->
      match field_path field with
      | seg :: _ :: _ -> String.equal seg head
      | _ -> false)
    Field.all

let decode_file_key source json (Field.Any field) config =
  let name = Field.name field in
  let* leaf =
    match field_path field with
    | [ name ] -> Ok (json_mem name json)
    | [ section; name ] -> (
        match json_mem section json with
        | None -> Ok None
        | Some (Jsont.Object _ as inner) -> Ok (json_mem name inner)
        | Some _ -> error (source ^ " " ^ section ^ " must be an object"))
    | _ -> assert false
  in
  match leaf with
  | None -> Ok config
  | Some leaf ->
      let* value =
        (Field.codec field).decode_json ~label:(source ^ " " ^ name) leaf
      in
      Ok (set_binding field (Some value) config)

let load_providers source json config =
  match json_mem "providers" json with
  | None -> Ok config
  | Some (Jsont.Object (providers, _)) ->
      List.fold_left
        (fun acc ((name, _), value) ->
          let* config = acc in
          let* provider =
            try Ok (Mentat_llm.Provider.make name)
            with Invalid_argument message -> invalid_provider_id name message
          in
          match json_object_fields value with
          | None -> error (source ^ " providers." ^ name ^ " must be an object")
          | Some _ -> (
              match json_mem "base_url" value with
              | None -> Ok config
              | Some leaf ->
                  let field = Field.Provider_base_url provider in
                  let* url =
                    (Field.codec field).decode_json
                      ~label:(source ^ " providers." ^ name ^ ".base_url")
                      leaf
                  in
                  Ok (set_binding field (Some url) config)))
        (Ok config) providers
  | Some _ -> error (source ^ " providers must be an object")

(* [permission.rules] parses here, is written by [config_to_fields], and is
   never addressable through a {!Field.t}. Duplicate rules within one layer
   are load errors so the effective evaluation order never carries silent
   repeats. *)
let check_duplicate_rule_ids label rules =
  let module Rule = Mentat_permission.Policy.Rule in
  let rec loop seen = function
    | [] -> Ok ()
    | rule :: rest ->
        let id = Rule.id rule in
        if List.exists (Rule.Id.equal id) seen then
          error (label ^ " contains duplicate rule " ^ Rule.Id.to_string id)
        else loop (id :: seen) rest
  in
  loop [] rules

let permission_rules_jsont =
  let make version items =
    if version <> 1 then
      Jsont.Error.msg Jsont.Meta.none
        ("unknown permission rules version: " ^ string_of_int version);
    items
  in
  Jsont.Object.map ~kind:"permission rules" make
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun _ -> 1)
  |> Jsont.Object.mem "items"
       Jsont.(list Mentat_permission.Policy.Rule.jsont)
       ~enc:Fun.id
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let decode_permission_rules source json config =
  match json_mem "permission" json with
  | None
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Array _ ) ->
      (* A non-object [permission] is reported by the keyed decoders. *)
      Ok config
  | Some (Jsont.Object _ as inner) -> (
      match json_mem "rules" inner with
      | None -> Ok config
      | Some (Jsont.Array _) ->
          error
            (source
           ^ " permission.rules uses the obsolete unversioned array format; \
              use { \"version\": 1, \"items\": [...] }")
      | Some leaf -> (
          let label = source ^ " permission.rules" in
          match Jsont.Json.decode permission_rules_jsont leaf with
          | Error message -> error (label ^ ": " ^ message)
          | Ok rules ->
              let* () = check_duplicate_rule_ids label rules in
              Ok (set_permission_rules rules config)))

let of_json ~source json =
  match json with
  | Jsont.Object _ ->
      let* config =
        List.fold_left
          (fun acc unit ->
            let* config = acc in
            match unit with
            | Key key -> decode_file_key source json key config
            | Providers -> load_providers source json config
            | Section head ->
                List.fold_left
                  (fun acc key ->
                    let* config = acc in
                    decode_file_key source json key config)
                  (Ok config) (section_keys head))
          (Ok empty) file_units
      in
      decode_permission_rules source json config
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      error (source ^ " config must be a JSON object")

let of_text ~source text =
  if String.is_empty text then Ok empty
  else
    match Jsont_bytesrw.decode_string Jsont.json text with
    | Error message -> error (source ^ ": " ^ message)
    | Ok json -> of_json ~source json

(* Collect-all validation over the same file units the loader folds. *)

let unknown_field_t source name = error_t (source ^ " unknown field: " ^ name)
let errors_of_result = function Ok _ -> [] | Error error -> [ error ]

let validate_providers source json =
  match json_mem "providers" json with
  | None -> []
  | Some (Jsont.Object (providers, _)) ->
      List.concat_map
        (fun ((name, _), value) ->
          let id_errors =
            errors_of_result
              (try Ok (Mentat_llm.Provider.make name)
               with Invalid_argument message ->
                 invalid_provider_id name message)
          in
          match json_object_fields value with
          | None ->
              id_errors
              @ [
                  error_t (source ^ " providers." ^ name ^ " must be an object");
                ]
          | Some _ -> (
              match json_mem "base_url" value with
              | None -> id_errors
              | Some leaf ->
                  id_errors
                  @ errors_of_result
                      (decode_string_leaf
                         (source ^ " providers." ^ name ^ ".base_url")
                         leaf)))
        providers
  | Some _ -> [ error_t (source ^ " providers must be an object") ]

let unknown_object_field_errors source allowed json =
  match json_object_fields json with
  | None -> []
  | Some fields ->
      List.filter_map
        (fun ((name, _), _value) ->
          if List.exists (String.equal name) allowed then None
          else Some (unknown_field_t source name))
        fields

let validate_provider_unknown_fields source json =
  match json_mem "providers" json with
  | Some (Jsont.Object (providers, _)) ->
      List.concat_map
        (fun ((name, _), value) ->
          match json_object_fields value with
          | None -> []
          | Some _ ->
              unknown_object_field_errors
                (source ^ " providers." ^ name)
                [ "base_url" ] value)
        providers
  | None | Some _ -> []

let validate ~source json =
  match json with
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      [ error_t (source ^ " config must be a JSON object") ]
  | Jsont.Object _ ->
      let key_errors key =
        errors_of_result (decode_file_key source json key empty)
      in
      List.concat_map
        (function
          | Key key -> key_errors key
          | Providers -> validate_providers source json
          | Section head -> (
              match json_mem head json with
              | None -> []
              | Some (Jsont.Object _) ->
                  List.concat_map key_errors (section_keys head)
              | Some _ ->
                  [ error_t (source ^ " " ^ head ^ " must be an object") ]))
        file_units
      @ errors_of_result (decode_permission_rules source json empty)

(* The keys a file carries that the reader will skip: members no field spells,
   and — in a workspace layer — the supported keys the shared allowlist drops
   there. Neither is a value error, which is why they live beside [validate]
   rather than in it; both are text the author believes is live. *)
let ignored_in_workspace source json =
  match of_json ~source json with
  | Error _ -> (* [validate] owns the shape report. *) []
  | Ok config ->
      let keys =
        List.filter_map
          (fun (Field.Any field) ->
            let name = Field.name field in
            if Field.allowed_in_workspace field then None
            else
              Some
                (error_t
                   (Printf.sprintf
                      "%s %s is ignored in a workspace config file; set it in \
                       the user config with `mentat config set %s`"
                      source name name)))
          (keys config)
      in
      let rules =
        match permission_rules config with
        | [] -> []
        | _ ->
            [
              error_t
                (source
               ^ " permission.rules is ignored in a workspace config file");
            ]
      in
      keys @ rules

let ignored_keys ?(workspace = false) ~source json =
  match json with
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      []
  | Jsont.Object _ ->
      let top_level_allowed =
        List.map
          (function
            | Key (Field.Any field) -> Field.name field
            | Providers -> "providers"
            | Section head -> head)
          file_units
      in
      let section_unknown_errors =
        List.concat_map
          (function
            | Key _ | Providers -> []
            | Section head -> (
                match json_mem head json with
                | Some (Jsont.Object _ as inner) ->
                    let structured_members =
                      (* Members handled outside the scalar key system must not
                         also produce unknown-member reports.
                         [permission.rules] is the only such member. *)
                      match head with
                      | "permission" -> [ "rules" ]
                      | _ -> []
                    in
                    unknown_object_field_errors
                      (source ^ " " ^ head)
                      (List.map
                         (fun (Field.Any field) ->
                           String.concat "." (List.tl (field_path field)))
                         (section_keys head)
                      @ structured_members)
                      inner
                | None | Some _ -> []))
          file_units
      in
      unknown_object_field_errors source top_level_allowed json
      @ section_unknown_errors
      @ validate_provider_unknown_fields source json
      @ if workspace then ignored_in_workspace source json else []

(* The pure splice behind [plan]: unknown members in the original JSON keep
   their value and nesting; supported members are re-emitted in file-unit
   order; supported empty containers are removed. *)

let make_mem name value = Jsont.Json.mem (Jsont.Json.name name) value
let json_object fields = Jsont.Json.object' fields
let mem_name ((name, _), _) = name

let remove_key key fields =
  List.filter (fun mem -> not (String.equal (mem_name mem) key)) fields

let find_key key fields =
  List.find_map
    (fun ((name, _), value) ->
      if String.equal name key then Some value else None)
    fields

let object_fields = function
  | Jsont.Object (fields, _) -> fields
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      []

let rec set_path parts value fields =
  match parts with
  | [] -> fields
  | [ key ] -> make_mem key value :: remove_key key fields
  | key :: rest ->
      let nested =
        match find_key key fields with
        | None -> []
        | Some value -> object_fields value
      in
      make_mem key (json_object (set_path rest value nested))
      :: remove_key key fields

let rec unset_path parts fields =
  match parts with
  | [] -> fields
  | [ key ] -> remove_key key fields
  | key :: rest -> (
      match find_key key fields with
      | None -> fields
      | Some value ->
          let nested = unset_path rest (object_fields value) in
          let fields = remove_key key fields in
          if List.is_empty nested then fields
          else make_mem key (json_object nested) :: fields)

let path_parts key =
  List.filter
    (fun part -> not (String.is_empty part))
    (String.split_on_char '.' key)

let set_member key value fields = set_path (path_parts key) value fields
let unset_member key fields = unset_path (path_parts key) fields
let string_json value = Jsont.Json.string value

let update_optional key enc value fields =
  match value with
  | None -> unset_member key fields
  | Some value -> set_member key (enc value) fields

let write_provider_base_urls config fields =
  let providers =
    object_fields
      (Option.value (find_key "providers" fields) ~default:(json_object []))
  in
  let providers =
    List.fold_left
      (fun providers ((name, _), value) ->
        let provider =
          try Some (Mentat_llm.Provider.make name)
          with Invalid_argument _ -> None
        in
        match provider with
        | None -> providers
        | Some provider ->
            let key = Mentat_llm.Provider.id provider in
            let provider_fields = object_fields value in
            let provider_fields =
              update_optional "base_url" string_json
                (provider_base_url ~provider config)
                provider_fields
            in
            let providers = remove_key key providers in
            if List.is_empty provider_fields then providers
            else make_mem key (json_object provider_fields) :: providers)
      providers providers
  in
  let providers =
    List.fold_left
      (fun providers (provider, base_url) ->
        let key = Mentat_llm.Provider.id provider in
        let provider_fields =
          match find_key key providers with
          | None -> []
          | Some value -> object_fields value
        in
        let provider_fields =
          set_member "base_url" (string_json base_url) provider_fields
        in
        make_mem key (json_object provider_fields) :: remove_key key providers)
      providers
      (provider_base_urls config)
  in
  if List.is_empty providers then remove_key "providers" fields
  else
    make_mem "providers" (json_object providers)
    :: remove_key "providers" fields

let permission_rules_json rules =
  match Jsont.Json.encode permission_rules_jsont rules with
  | Ok json -> json
  | Error message ->
      (* Rules in a configuration were validated at decode or construction
         time, so a failed re-encode is a programmer bug, not file input. *)
      invalid_arg ("permission.rules encode failed: " ^ message)

let config_to_fields config fields =
  let apply fields (Field.Any field) =
    match json field config with
    | Jsont.Null _ -> unset_member (Field.name field) fields
    | value -> set_member (Field.name field) value fields
  in
  List.fold_left
    (fun fields unit ->
      match unit with
      | Providers -> fields
      | Key key -> apply fields key
      | Section head -> List.fold_left apply fields (section_keys head))
    fields file_units
  |> write_provider_base_urls config
  |> fun fields ->
  match permission_rules config with
  | [] -> unset_member "permission.rules" fields
  | rules -> set_member "permission.rules" (permission_rules_json rules) fields

module Plan = struct
  type t = Unchanged | Write of string
end

(* The [""] original scaffolds a minimal object. Unknown members keep their
   value and nesting (the [fields] fold splices in place); member order is not
   preserved — see the .mli law. *)
let plan ~source ~original ~f =
  let* fields =
    if String.is_empty original then Ok []
    else
      match Jsont_bytesrw.decode_string Jsont.json original with
      | Error message -> error (source ^ ": " ^ message)
      | Ok (Jsont.Object (fields, _)) -> Ok fields
      | Ok
          ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
          | Jsont.Array _ ) ->
          error (source ^ " must contain a JSON object")
  in
  let* old_config = of_json ~source (json_object fields) in
  let* new_config = f old_config in
  if equal old_config new_config then Ok Plan.Unchanged
  else
    let spliced = json_object (List.rev (config_to_fields new_config fields)) in
    match Jsont_bytesrw.encode_string Jsont.json spliced with
    | Error message -> error message
    | Ok encoded -> Ok (Plan.Write (encoded ^ "\n"))

module Warning = struct
  type kind =
    | Ignored_project_key
    | Ignored_project_rules
    | Ignored_project_budget
    | Invalid_project_config
    | Project_config_disabled

  type t = {
    kind : kind;
    source : Source.t;
    key : Field.any option;
    message : string;
  }

  let kind_to_string = function
    | Ignored_project_key -> "ignored_project_key"
    | Ignored_project_rules -> "ignored_project_rules"
    | Ignored_project_budget -> "ignored_project_budget"
    | Invalid_project_config -> "invalid_project_config"
    | Project_config_disabled -> "project_config_disabled"

  let kind_string t = kind_to_string t.kind

  let kind_of_string = function
    | "ignored_project_key" -> Some Ignored_project_key
    | "ignored_project_rules" -> Some Ignored_project_rules
    | "ignored_project_budget" -> Some Ignored_project_budget
    | "invalid_project_config" -> Some Invalid_project_config
    | "project_config_disabled" -> Some Project_config_disabled
    | _ -> None

  let source_kind_and_path = function
    | Source.User { path } -> ("user", Lpath.Abs.to_string path)
    | Source.Project { path } -> ("project", Lpath.Abs.to_string path)
    | Source.Project_local { path } ->
        ("project_local", Lpath.Abs.to_string path)
    | Source.Extra_file { path } -> ("extra_file", Lpath.Abs.to_string path)
    | Source.Env { name } -> ("env", name)
    | Source.Override -> ("override", "")
    | Source.Default { reason } -> ("default", reason)

  let source_of_kind_and_path kind path =
    let file make =
      match Lpath.Abs.of_string path with
      | Ok path -> Ok (make path)
      | Error error -> Error (Lpath.Error.message error)
    in
    match kind with
    | "user" -> file (fun path -> Source.User { path })
    | "project" -> file (fun path -> Source.Project { path })
    | "project_local" -> file (fun path -> Source.Project_local { path })
    | "extra_file" -> file (fun path -> Source.Extra_file { path })
    | "env" -> Ok (Source.Env { name = path })
    | "override" -> Ok Source.Override
    | "default" -> Ok (Source.Default { reason = path })
    | _ -> Error ("unknown config diagnostic source: " ^ kind)

  let message t = t.message
  let source t = t.source
  let field t = t.key
  let key_name = function Field.Any field -> Field.name field

  let ignored_project_rules ~count source =
    {
      kind = Ignored_project_rules;
      source;
      key = None;
      message =
        Printf.sprintf
          "permission.rules is ignored in workspace config: %d rule%s dropped \
           (workspace config cannot carry permission rules)"
          count
          (if count = 1 then "" else "s");
    }

  let ignored_project_budget key ~cap source =
    {
      kind = Ignored_project_budget;
      source;
      key = Some key;
      message =
        Printf.sprintf
          "%s is ignored because workspace config may tighten but not widen it \
           (effective limit: %d)"
          (key_name key) cap;
    }

  let invalid_project_config ~reason source =
    {
      kind = Invalid_project_config;
      source;
      key = None;
      message = "workspace config file ignored: " ^ reason;
    }

  let project_config_disabled ~status source =
    {
      kind = Project_config_disabled;
      source;
      key = None;
      message = "workspace config file disabled: workspace trust is " ^ status;
    }

  let ignored_project_key key source =
    {
      kind = Ignored_project_key;
      source;
      key = Some key;
      message =
        Printf.sprintf
          "%s is ignored because shared project config may only set: %s"
          (key_name key)
          (Field.all
          |> List.filter_map (fun (Field.Any field) ->
              if Field.allowed_in_workspace field then Some (Field.name field)
              else None)
          |> String.concat ", ");
    }

  let make_mem name value = Jsont.Json.mem (Jsont.Json.name name) value

  let to_json t =
    let source_kind, path = source_kind_and_path t.source in
    let key_field =
      match t.key with
      | None -> []
      | Some key -> [ make_mem "key" (Jsont.Json.string (key_name key)) ]
    in
    Jsont.Json.object'
      ([
         make_mem "kind" (Jsont.Json.string (kind_to_string t.kind));
         make_mem "source" (Jsont.Json.string source_kind);
         make_mem "path" (Jsont.Json.string path);
       ]
      @ key_field
      @ [ make_mem "message" (Jsont.Json.string t.message) ])

  let decode_error message = Jsont.Error.msg Jsont.Meta.none message

  let require_string_field context name json =
    match json_mem name json with
    | Some (Jsont.String (value, _)) -> value
    | Some _ -> decode_error (context ^ " " ^ name ^ " must be a string")
    | None -> decode_error (context ^ " missing " ^ name)

  let optional_string_field context name json =
    match json_mem name json with
    | None -> None
    | Some (Jsont.String (value, _)) -> Some value
    | Some _ -> decode_error (context ^ " " ^ name ^ " must be a string")

  let of_json json =
    match json_object_fields json with
    | None -> decode_error "config diagnostic must be an object"
    | Some _ ->
        let kind_raw = require_string_field "config diagnostic" "kind" json in
        let kind =
          match kind_of_string kind_raw with
          | Some kind -> kind
          | None -> decode_error ("unknown config diagnostic kind: " ^ kind_raw)
        in
        let source_kind =
          require_string_field "config diagnostic" "source" json
        in
        let path = require_string_field "config diagnostic" "path" json in
        let source =
          match source_of_kind_and_path source_kind path with
          | Ok source -> source
          | Error message -> decode_error message
        in
        let key =
          match optional_string_field "config diagnostic" "key" json with
          | None -> None
          | Some raw -> (
              match Field.of_string raw with
              | Ok key -> Some key
              | Error error -> decode_error (Error.message error))
        in
        let message = require_string_field "config diagnostic" "message" json in
        { kind; source; key; message }

  let jsont =
    Jsont.map ~kind:"config diagnostic" ~dec:of_json ~enc:to_json Jsont.json

  let diagnostic t =
    let source_kind, path = source_kind_and_path t.source in
    let attribution =
      if String.is_empty path then source_kind else source_kind ^ ": " ^ path
    in
    (* [of_text] keeps the first message line primary; a multi-line
       [invalid_project_config] reason overflows into context above the
       attribution. *)
    Mentat_diagnostic.of_text (t.message ^ "\n" ^ attribution)

  let pp ppf t =
    let source_kind, path = source_kind_and_path t.source in
    match (t.kind, t.key) with
    | Ignored_project_key, Some key ->
        Format.fprintf ppf "%s config key ignored in workspace config: %s (%s)"
          source_kind (key_name key) path
    | ( ( Ignored_project_rules | Ignored_project_budget
        | Invalid_project_config | Project_config_disabled ),
        _ ) ->
        Format.fprintf ppf "%s (%s: %s)" t.message source_kind path
    | Ignored_project_key, None -> Format.pp_print_string ppf t.message
end

(* The field-resolution result, a self-contained snapshot: [layer] is the
   merged configured values (no defaults); [effective_layer] is [layer] over a
   defaults layer resolved eagerly at resolution, so a read never needs the
   environment getter again. Plus the origins map, the per-source durable rule
   groups, and the warning facts. *)
type resolved = {
  layer : t;
  effective_layer : t;
  origins : (Field.any * Origin.t) Name_map.t;
  rule_groups : (Source.t * Mentat_permission.Policy.Rule.t list) list;
  warnings : Warning.t list;
}

module Resolved = struct
  type t = resolved

  let configured field t = find field t.layer

  (* Shadows the configuration-level [find]: resolved reads consult the
     effective layer, which has the built-in defaults baked in. *)
  let find field t = find field t.effective_layer

  let get : type a. (a, Field.defaulted) Field.t -> t -> a =
   fun field t ->
    match find field t with
    | Some value -> value
    | None ->
        (* [resolve] bakes every built-in default into [effective_layer], and
           the [defaulted] index proves [field] declares one. *)
        assert false

  let text field t = Option.map (Field.codec field).to_text (find field t)

  let origin field t =
    Option.map snd (Name_map.find_opt (Field.name field) t.origins)

  let origins t = Name_map.bindings t.origins |> List.map snd
  let warnings t = t.warnings
  let permission_rules t = t.rule_groups

  module View = struct
    module Value = struct
      type t = Shown of { text : string; json : Jsont.json } | Redacted
    end

    module Entry = struct
      type t = { key : string; value : Value.t; origin : Origin.t }

      let key t = t.key
      let value t = t.value
      let origin t = t.origin

      let jsont =
        Jsont.Object.map ~kind:"config value"
          (fun key redacted text json origin ->
            let value =
              if redacted then Value.Redacted
              else
                Value.Shown
                  {
                    text = Option.value text ~default:"";
                    json = Option.value json ~default:(Jsont.Json.null ());
                  }
            in
            { key; value; origin })
        |> Jsont.Object.mem "key" Jsont.string ~enc:key
        |> Jsont.Object.mem "redacted" Jsont.bool ~enc:(fun t ->
            match t.value with Value.Redacted -> true | Value.Shown _ -> false)
        |> Jsont.Object.opt_mem "text" Jsont.string ~enc:(fun t ->
            match t.value with
            | Value.Shown { text; _ } -> Some text
            | Value.Redacted -> None)
        |> Jsont.Object.opt_mem "json" Jsont.json ~enc:(fun t ->
            match t.value with
            | Value.Shown { json; _ } -> Some json
            | Value.Redacted -> None)
        |> Jsont.Object.mem "origin" Origin.jsont ~enc:origin
        |> Jsont.Object.error_unknown |> Jsont.Object.finish
    end

    module Permission_rule = struct
      module Rule = Mentat_permission.Policy.Rule

      type t = { id : Rule.Id.t; rule : Rule.t; source : Source.t }

      let make ~source rule = { id = Rule.id rule; rule; source }
      let id t = t.id
      let rule t = t.rule
      let source t = t.source

      let source_equal a b =
        match (a, b) with
        | Source.User { path = a }, Source.User { path = b }
        | Source.Project { path = a }, Source.Project { path = b }
        | Source.Project_local { path = a }, Source.Project_local { path = b }
        | Source.Extra_file { path = a }, Source.Extra_file { path = b } ->
            Lpath.Abs.equal a b
        | Source.Env { name = a }, Source.Env { name = b } -> String.equal a b
        | Source.Override, Source.Override -> true
        | Source.Default { reason = a }, Source.Default { reason = b } ->
            String.equal a b
        | ( ( Source.User _ | Source.Project _ | Source.Project_local _
            | Source.Extra_file _ | Source.Env _ | Source.Override
            | Source.Default _ ),
            _ ) ->
            false

      let equal a b =
        Rule.Id.equal a.id b.id && Rule.equal a.rule b.rule
        && source_equal a.source b.source

      let pp ppf t =
        Format.fprintf ppf "@[<hov>{ id = %a; source = %a; rule = %a }@]"
          Rule.Id.pp t.id Source.pp t.source Rule.pp t.rule

      let source_can_contribute = function
        | Source.User _ | Source.Extra_file _ -> true
        | Source.Project _ | Source.Project_local _ | Source.Env _
        | Source.Override | Source.Default _ ->
            false

      let decode id rule source =
        if not (Rule.Id.equal id (Rule.id rule)) then
          Jsont.Error.msg Jsont.Meta.none
            "permission rule row id does not match its rule";
        if not (source_can_contribute source) then
          Jsont.Error.msg Jsont.Meta.none
            "permission rule row source must be user or extra_file";
        { id; rule; source }

      let jsont =
        Jsont.Object.map ~kind:"resolved permission rule" decode
        |> Jsont.Object.mem "id" Rule.Id.jsont ~enc:id
        |> Jsont.Object.mem "rule" Rule.jsont ~enc:rule
        |> Jsont.Object.mem "source" Source.jsont ~enc:source
        |> Jsont.Object.error_unknown |> Jsont.Object.finish
    end

    type t = {
      entries : Entry.t list;
      permission_rules : Permission_rule.t list;
      warnings : Warning.t list;
    }

    let entries (t : t) = t.entries
    let permission_rules (t : t) = t.permission_rules
    let warnings (t : t) = t.warnings

    let jsont =
      Jsont.Object.map ~kind:"configuration"
        (fun entries permission_rules warnings ->
          { entries; permission_rules; warnings })
      |> Jsont.Object.mem "entries" (Jsont.list Entry.jsont) ~enc:entries
      |> Jsont.Object.mem "permission_rules"
           (Jsont.list Permission_rule.jsont)
           ~enc:permission_rules
      |> Jsont.Object.mem "warnings" (Jsont.list Warning.jsont) ~enc:warnings
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
  end

  (* Redaction happens here, at the owner, before the value reaches the codec:
     a withheld field's entry is [Redacted], which carries no slot for the
     value, and a partly-shown one reaches the codec already stripped, so no
     wire form can leak a credential embedded in it. *)
  let view t =
    let entries =
      origins t
      |> List.map (fun (Field.Any field, origin) ->
          let value =
            match find field t with
            (* [origins] lists only fields with an effective value. *)
            | None -> assert false
            | Some v -> (
                match Field.shown field v with
                | None -> View.Value.Redacted
                | Some v ->
                    View.Value.Shown
                      {
                        text = (Field.codec field).to_text v;
                        json = (Field.codec field).encode_json v;
                      })
          in
          { View.Entry.key = Field.name field; value; origin })
    in
    let permission_rule_rows =
      permission_rules t
      |> List.concat_map (fun (source, rules) ->
          List.map (View.Permission_rule.make ~source) rules)
    in
    {
      View.entries;
      permission_rules = permission_rule_rows;
      warnings = warnings t;
    }
end

(* The environment layer is one fold over the field list; the provider base URL
   family contributes its wired providers -- the cloud endpoints a user may
   proxy plus the OpenAI-compatible [ollama] endpoint a self-hosted server
   (llama.cpp, vLLM, LM Studio) is reached through. Each variable parses with
   its field's environment parser, so per-variable error wording lives on the
   field description. *)
let env_named_layers getenv =
  let env_fields =
    with_provider_family
      (List.map
         (fun id ->
           Field.Any (Field.Provider_base_url (Mentat_llm.Provider.make id)))
         [ "openai"; "anthropic"; "ollama" ])
  in
  let* layers =
    List.fold_left
      (fun acc (Field.Any field) ->
        let* layers = acc in
        match Field.env_var field with
        | None -> Ok layers
        | Some (name, parse) -> (
            match getenv name with
            | None | Some "" -> Ok layers
            | Some value ->
                let* value = parse value in
                Ok
                  ((Source.Env { name }, set_binding field (Some value) empty)
                  :: layers)))
      (Ok []) env_fields
  in
  Ok (List.rev layers)

let filter_shared_project_layer source config =
  List.fold_left
    (fun (config, ignored) (Field.Any field as any) ->
      if Field.allowed_in_workspace field then (config, ignored)
      else (set_binding field None config, (any, source) :: ignored))
    (config, []) (keys config)
  |> fun (config, ignored) -> (config, List.rev ignored)

(* Trust permits workspace layers to participate but does not make repository
   content authoritative. Scalar keys outside the shared allowlist drop,
   [permission.rules] never load from the workspace, and [run.max_steps] may
   tighten but not widen the non-workspace effective value. Every drop surfaces
   as a diagnostic. *)
let sanitize_workspace_layer ~run_max_steps_cap source config =
  let config, ignored_keys = filter_shared_project_layer source config in
  let config, ignored_rules =
    match permission_rules config with
    | [] -> (config, [])
    | rules -> (set_permission_rules [] config, [ (source, List.length rules) ])
  in
  let config, ignored_budgets =
    match (find Field.run_max_steps config, run_max_steps_cap) with
    | Some value, Some cap when value > cap ->
        ( set_binding Field.run_max_steps None config,
          [ (Field.Any Field.run_max_steps, source, cap) ] )
    | (Some _ | None), _ -> (config, [])
  in
  (config, ignored_keys, ignored_rules, ignored_budgets)

let validate_merged_layer config =
  let timeout_ms =
    Option.value
      (find Field.web_timeout_ms config)
      ~default:default_web_timeout_ms
  in
  let max_timeout_ms =
    Option.value
      (find Field.web_max_timeout_ms config)
      ~default:default_web_max_timeout_ms
  in
  if timeout_ms > max_timeout_ms then
    error "web.timeout_ms must not exceed web.max_timeout_ms"
  else Ok ()

type workspace_file =
  | Loaded of Lpath.Abs.t * t
  | Invalid of Lpath.Abs.t * string
  | Absent

type workspace_config =
  | Trusted of { project : workspace_file; project_local : workspace_file }
  | Disabled of {
      status : string;
      project : Lpath.Abs.t option;
      project_local : Lpath.Abs.t option;
    }

let resolve ~env ~user ~extra ~workspace_config ~overrides =
  let getenv = env in
  let user_path, user = user in
  let user_source = Source.User { path = user_path } in
  let extra_layers =
    match extra with
    | None -> []
    | Some (path, config) -> [ (Source.Extra_file { path }, config) ]
  in
  let* env_layers = env_named_layers getenv in
  let override_layers =
    (* Durable rules load only from file layers: a runtime override that
       carries rules contributes none (see the [resolve] contract). *)
    List.map
      (fun config -> (Source.Override, set_permission_rules [] config))
      overrides
  in
  let non_workspace_layers =
    ((user_source, user) :: extra_layers) @ env_layers @ override_layers
  in
  let* () =
    non_workspace_layers |> List.map snd |> merge_all |> validate_merged_layer
  in
  (* Trusted workspace layers still pass through the shared-key filter, rule
     stripping, and budget clamp. The clamp reads the non-workspace effective
     [run.max_steps] as its ceiling. *)
  let run_max_steps_cap =
    find Field.run_max_steps (merge_all (List.map snd non_workspace_layers))
  in
  let ( workspace_entries,
        ignored_keys,
        ignored_rules,
        ignored_budgets,
        invalid_files,
        disabled_status,
        disabled_files ) =
    match workspace_config with
    | Trusted { project; project_local } ->
        (* [resolve] mints the provenance {!Source.t} for each slot from its
           path; an [Absent] slot contributes no layer and no source. *)
        let sanitize make_source = function
          | Loaded (path, config) ->
              let source = make_source path in
              let config, keys, rules, budgets =
                sanitize_workspace_layer ~run_max_steps_cap source config
              in
              ([ (source, config) ], keys, rules, budgets, [])
          | Invalid (path, reason) ->
              let source = make_source path in
              ([ (source, empty) ], [], [], [], [ (source, reason) ])
          | Absent -> ([], [], [], [], [])
        in
        let p_entries, p_keys, p_rules, p_budgets, p_invalid =
          sanitize (fun path -> Source.Project { path }) project
        in
        let pl_entries, pl_keys, pl_rules, pl_budgets, pl_invalid =
          sanitize (fun path -> Source.Project_local { path }) project_local
        in
        ( p_entries @ pl_entries,
          p_keys @ pl_keys,
          p_rules @ pl_rules,
          p_budgets @ pl_budgets,
          p_invalid @ pl_invalid,
          "",
          [] )
    | Disabled { status; project; project_local } ->
        let present =
          List.filter_map Fun.id
            [
              Option.map (fun path -> Source.Project { path }) project;
              Option.map
                (fun path -> Source.Project_local { path })
                project_local;
            ]
        in
        ([], [], [], [], [], status, present)
  in
  let layers =
    ((user_source, user) :: workspace_entries)
    @ extra_layers @ env_layers @ override_layers
  in
  let layer = merge_all (List.map snd layers) in
  let origins = origins_of_layers layers |> origin_with_defaults getenv in
  let rule_groups =
    (* Non-workspace file layers only, in descending precedence: env layers
       cannot carry rules by construction, override layers had theirs stripped
       above, and workspace layers had theirs stripped by
       [sanitize_workspace_layer]. Flattening this list equals the merged
       layer's rules because [merge] concatenates high-first. *)
    List.filter_map
      (fun (source, config) ->
        match permission_rules config with
        | [] -> None
        | rules -> Some (source, rules))
      (extra_layers @ [ (user_source, user) ])
  in
  let warnings =
    List.map
      (Warning.project_config_disabled ~status:disabled_status)
      disabled_files
    @ List.map
        (fun (source, reason) -> Warning.invalid_project_config ~reason source)
        invalid_files
    @ List.map
        (fun (key, source) -> Warning.ignored_project_key key source)
        ignored_keys
    @ List.map
        (fun (source, count) -> Warning.ignored_project_rules ~count source)
        ignored_rules
    @ List.map
        (fun (key, source, cap) ->
          Warning.ignored_project_budget key ~cap source)
        ignored_budgets
  in
  (* Bake the built-in defaults into the effective layer eagerly, so a read of
     the snapshot never needs [getenv] again. *)
  let defaults_layer =
    List.fold_left
      (fun acc (Field.Any field) ->
        match Field.default field with
        | Field.No_default -> acc
        | Field.Default default ->
            set_binding field (Some (fst (default getenv))) acc)
      empty Field.all
  in
  let effective_layer = merge ~low:defaults_layer ~high:layer in
  Ok { layer; effective_layer; origins; rule_groups; warnings }
