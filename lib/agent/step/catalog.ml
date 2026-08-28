(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_string s = Jsont.Json.string s
let json_list values = Jsont.Json.list values

let string_schema =
  json_obj [ ("type", json_string "string"); ("minLength", Jsont.Json.int 1) ]

let enum_schema values =
  json_obj
    [
      ("type", json_string "string");
      ("enum", json_list (List.map json_string values));
    ]

let array_schema items =
  json_obj [ ("type", json_string "array"); ("items", items) ]

let object_schema ?(required = []) properties =
  json_obj
    [
      ("type", json_string "object");
      ("properties", json_obj properties);
      ("required", json_list (List.map json_string required));
      ("additionalProperties", Jsont.Json.bool false);
    ]

module Verb = struct
  type t =
    | Todo_write
    | Ask_user
    | Propose_plan
    | Spawn
    | Wait
    | Send
    | Follow_up

  let reserved =
    [ Todo_write; Ask_user; Propose_plan; Spawn; Wait; Send; Follow_up ]

  let name = function
    | Todo_write -> "todo_write"
    | Ask_user -> "ask_user"
    | Propose_plan -> "propose_plan"
    | Spawn -> "spawn"
    | Wait -> "wait"
    | Send -> "send"
    | Follow_up -> "follow_up"

  let description = function
    | Todo_write -> Mentat_prompts.Tools.todo_write
    | Ask_user -> Mentat_prompts.Tools.ask_user
    | Propose_plan -> Mentat_prompts.Tools.propose_plan
    | Spawn -> Mentat_prompts.Tools.spawn
    | Wait -> Mentat_prompts.Tools.wait
    | Send -> Mentat_prompts.Tools.send
    | Follow_up -> Mentat_prompts.Tools.follow_up

  let input_schema = function
    | Todo_write ->
        object_schema ~required:[ "tasks" ]
          [
            ( "tasks",
              array_schema
                (object_schema ~required:[ "id"; "content" ]
                   [
                     ("id", string_schema);
                     ("content", string_schema);
                     ( "status",
                       enum_schema
                         [ "pending"; "in_progress"; "completed"; "cancelled" ]
                     );
                     ("priority", enum_schema [ "high"; "medium"; "low" ]);
                   ]) );
          ]
    | Ask_user ->
        object_schema ~required:[ "prompt" ]
          [ ("prompt", string_schema); ("choices", array_schema string_schema) ]
    | Propose_plan ->
        object_schema ~required:[ "body" ]
          [ ("title", string_schema); ("body", string_schema) ]
    | Spawn ->
        object_schema ~required:[ "task" ]
          [
            ("task", string_schema);
            ("description", string_schema);
            ("role", enum_schema [ "general"; "explore"; "review"; "verify" ]);
          ]
    | Wait ->
        object_schema ~required:[ "children" ]
          [ ("children", array_schema string_schema) ]
    | Send ->
        object_schema ~required:[ "to"; "message" ]
          [ ("to", string_schema); ("message", string_schema) ]
    | Follow_up ->
        object_schema ~required:[ "child"; "message" ]
          [ ("child", string_schema); ("message", string_schema) ]

  let declaration v =
    Mentat_llm.Tool.make ~name:(name v) ~description:(description v)
      ~input_schema:(input_schema v) ()
end

module Error = struct
  type t =
    | Duplicate_name of string
    | Reserved_name of string
    | Duplicate_verb of Verb.t

  let message = function
    | Duplicate_name name -> "duplicate tool name: " ^ name
    | Reserved_name name -> "tool name is reserved by the engine: " ^ name
    | Duplicate_verb verb -> "duplicate engine verb: " ^ Verb.name verb

  let pp ppf e = Format.pp_print_string ppf (message e)
end

type t = { tools : Mentat_tool.t list; verbs : Verb.t list }

let output_tool_name = "structured_output"

(* The record itself, never a captured stream: the input of the last
   [structured_output] claim in the head turn, and only when that turn
   completed, since completion is what proves the claim was the
   schema-conforming terminating answer. *)
let claim session =
  let state = Mentat_session.state session in
  match Mentat_session.State.settled_head state with
  | Some (turn, Some Mentat_session.Turn.Outcome.Completed) ->
      let head = Mentat_session.Turn.id turn in
      List.fold_left
        (fun acc (started, _settled) ->
          if
            Mentat_session.Turn.Id.equal
              (Mentat_session.Tool_claim.Started.turn started)
              head
            && String.equal
                 (Mentat_llm.Tool.Call.name
                    (Mentat_session.Tool_claim.Started.call started))
                 output_tool_name
          then Some (Mentat_session.Tool_claim.Started.input started)
          else acc)
        None
        (Mentat_session.State.tool_claims state)
  | Some (_, _) | None -> None

let tool_name tool = Mentat_llm.Tool.name (Mentat_tool.declaration tool)

let is_verb_name name =
  List.exists (fun v -> String.equal (Verb.name v) name) Verb.reserved
  || String.equal name output_tool_name

let check_verbs verbs =
  let rec loop seen = function
    | [] -> Ok ()
    | verb :: rest ->
        if List.mem verb seen then Error (Error.Duplicate_verb verb)
        else loop (verb :: seen) rest
  in
  loop [] verbs

let make ~verbs tools =
  let rec check_tools seen = function
    | [] -> Ok { tools; verbs }
    | tool :: rest ->
        let name = tool_name tool in
        if is_verb_name name then Error (Error.Reserved_name name)
        else if List.exists (String.equal name) seen then
          Error (Error.Duplicate_name name)
        else check_tools (name :: seen) rest
  in
  match check_verbs verbs with
  | Error _ as error -> error
  | Ok () -> check_tools [] tools

let declarations t =
  List.map Mentat_tool.declaration t.tools @ List.map Verb.declaration t.verbs

let resolve t name =
  match List.find_opt (fun v -> String.equal (Verb.name v) name) t.verbs with
  | Some verb -> Some (`Verb verb)
  | None -> (
      match
        List.find_opt (fun tool -> String.equal (tool_name tool) name) t.tools
      with
      | Some tool -> Some (`Executable tool)
      | None -> None)
