(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The projection reads members straight off the raw input JSON rather than a
   tool's private input codec, which lives with the tool. Member names are the
   ones each tool declares in its input schema; a mismatch degrades to [None]
   rather than a wrong argument. *)

let member name = function
  | Jsont.Object (members, _) ->
      List.find_map
        (fun ((candidate, _), value) ->
          if String.equal candidate name then Some value else None)
        members
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

(* An empty string member is treated as absent so a header never shows an empty
   argument in parentheses. *)
let string_member name json =
  match member name json with
  | Some (Jsont.String (value, _)) when String.length value > 0 -> Some value
  | Some
      ( Jsont.String _ | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
      | Jsont.Array _ | Jsont.Object _ )
  | None ->
      None

let int_member name json =
  match member name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (int_of_float value)
  | Some
      ( Jsont.Number _ | Jsont.Null _ | Jsont.Bool _ | Jsont.String _
      | Jsont.Array _ | Jsont.Object _ )
  | None ->
      None

let string_list_member name json =
  match member name json with
  | Some (Jsont.Array (items, _)) ->
      let strings =
        List.filter_map
          (function
            | Jsont.String (value, _) when String.length value > 0 -> Some value
            | Jsont.String _ | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
            | Jsont.Array _ | Jsont.Object _ ->
                None)
          items
      in
      if strings = [] then None else Some strings
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Object _ )
  | None ->
      None

let quote value = "\"" ^ value ^ "\""
let arrow = " \u{2192} "

(* A byte cap on the projected argument bounds a pathological input before the
   consumer normalizes it; the cut backs up to a UTF-8 scalar boundary so a
   scalar is never split. The consumer width-truncates the remainder. *)
let max_argument_bytes = 160

let clip text =
  if String.length text <= max_argument_bytes then text
  else
    let rec boundary index =
      if index <= 0 then 0
      else if Char.code text.[index] land 0xC0 = 0x80 then boundary (index - 1)
      else index
    in
    String.sub text 0 (boundary max_argument_bytes) ^ "\u{2026}"

let location json =
  match string_member "path" json with
  | None -> None
  | Some path -> (
      match (int_member "line" json, int_member "column" json) with
      | Some line, Some column ->
          Some (Printf.sprintf "%s:%d:%d" path line column)
      | (Some _ | None), (Some _ | None) -> Some path)

let search json =
  match string_member "pattern" json with
  | None -> None
  | Some pattern -> (
      let pattern = quote pattern in
      match string_list_member "paths" json with
      | None -> Some pattern
      | Some paths -> Some (pattern ^ " in " ^ String.concat ", " paths))

let glob json =
  match string_member "pattern" json with
  | None -> None
  | Some pattern -> (
      match string_member "path" json with
      | None -> Some pattern
      | Some path -> Some (pattern ^ " in " ^ path))

let replace json =
  match (string_member "pattern" json, string_member "template" json) with
  | Some pattern, Some template -> Some (pattern ^ arrow ^ template)
  | Some pattern, None -> Some pattern
  | None, (Some _ | None) -> None

let rename json =
  match string_member "new_name" json with
  | None -> location json
  | Some new_name -> (
      match location json with
      | Some location -> Some (location ^ arrow ^ new_name)
      | None -> Some new_name)

let find_definitions json =
  match string_member "identifier" json with
  | Some identifier -> Some identifier
  | None -> location json

let spawn json =
  match string_member "description" json with
  | Some description -> Some description
  | None -> string_member "task" json

let wait json =
  match string_list_member "children" json with
  | None -> None
  | Some children -> Some (String.concat ", " children)

let headline ~tool ~input =
  let projected =
    match tool with
    | "read_file" | "edit_file" | "write_file" | "ocaml_ast_edit" ->
        string_member "path" input
    | "search_text" | "ocaml_search_expressions" -> search input
    | "glob" -> glob input
    | "shell" -> string_member "command" input
    | "shell_output" | "shell_kill" -> string_member "handle" input
    | "web_fetch" -> string_member "url" input
    | "web_search" -> Option.map quote (string_member "query" input)
    | "ocaml_replace_expressions" -> replace input
    | "ocaml_rename" -> rename input
    | "ocaml_eval" -> string_member "code" input
    | "ocaml_docs" -> string_member "query" input
    | "ocaml_type_at" | "ocaml_find_references" -> location input
    | "ocaml_find_definitions" -> find_definitions input
    | "skill" -> string_member "name" input
    | "spawn" -> spawn input
    | "wait" -> wait input
    | "send_message" | "follow_up" -> string_member "child" input
    (* These built-ins have no header argument: [apply_patch] carries its paths
       inside the patch envelope, and the task board, plan, and question render
       from their own facts. *)
    | "apply_patch" | "todo_write" | "propose_plan" | "ask_user" -> None
    | _ -> None
  in
  Option.map clip projected
