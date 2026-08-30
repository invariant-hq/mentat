(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Mentat_llm
module Config = Config

let log_src = Logs.Src.create "mentat.llm.google" ~doc:"Google Gemini provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let provider = Llm.Provider.make "google"
let api = Llm.Model.Api.make Api.api
let model id = Llm.Model.make ~provider ~api ~id

module Credential = struct
  type t = Api_key of string

  let contains_newline value =
    String.exists (function '\n' | '\r' -> true | _ -> false) value

  let check_header_value fn value =
    if String.is_empty value then
      invalid_arg ("Mentat_llm_google.Credential." ^ fn ^ ": empty value");
    if contains_newline value then
      invalid_arg
        ("Mentat_llm_google.Credential." ^ fn ^ ": value contains newline")

  let api_key key =
    check_header_value "api_key" key;
    Api_key key

  let api_auth = function Api_key key -> Api.Client.Api_key key
end

let llm_error ?(phase = Llm.Error.Startup) ?status ?request_id ?redacted_body
    kind message =
  Llm.Error.make ~kind ~phase ~provider ?status ?request_id ?redacted_body
    message

let unsupported message = Error (llm_error Llm.Error.Unsupported message)

let invalid_request message =
  Error (llm_error Llm.Error.Invalid_request message)

let stream_error kind message = llm_error ~phase:Llm.Error.Stream kind message

let cancelled_error ?(phase = Llm.Error.Startup) () =
  llm_error ~phase Llm.Error.Cancelled "Google Gemini request cancelled"

let timeout_error ~phase seconds =
  llm_error ~phase Llm.Error.Timeout
    (Printf.sprintf "Google Gemini request timed out after %gs" seconds)

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message -> invalid_arg ("JSON encode failed: " ^ message)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let bool_field name json =
  match object_field name json with
  | Some (Jsont.Bool (value, _)) -> Some value
  | Some
      ( Jsont.Null _ | Jsont.Number _ | Jsont.String _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let int_field name json =
  match object_field name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (int_of_float value)
  | Some (Jsont.String (value, _)) -> int_of_string_opt value
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let list_field name json =
  match object_field name json with
  | Some (Jsont.Array (items, _)) -> Some items
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Object _ )
  | None ->
      None

let result_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match f value with
        | Error error -> Error error
        | Ok value -> loop (value :: acc) rest)
  in
  loop [] values

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let int_member name value = json_member name (Jsont.Json.int value)
let number_member name value = json_member name (Jsont.Json.number value)
let list_member name value = json_member name (Jsont.Json.list value)

let add_opt member name value fields =
  match value with None -> fields | Some value -> member name value :: fields

let json_object fields =
  Jsont.Json.object'
    (List.map (fun (name, value) -> json_member name value) fields)

let object_members = function
  | Jsont.Object (fields, _) ->
      Some (List.map (fun ((name, _), value) -> (name, value)) fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let object_member name fields = List.assoc_opt name fields

let object_has name fields =
  match object_member name fields with Some _ -> true | None -> false

let object_set name value fields =
  (name, value)
  :: List.filter
       (fun (candidate, _) -> not (String.equal candidate name))
       fields

let object_remove name fields =
  List.filter (fun (candidate, _) -> not (String.equal candidate name)) fields

let string_json json =
  match json with
  | Jsont.String (value, _) -> value
  | Jsont.Number (value, _) ->
      if Float.is_integer value then string_of_int (int_of_float value)
      else string_of_float value
  | Jsont.Bool (true, _) -> "true"
  | Jsont.Bool (false, _) -> "false"
  | Jsont.Null _ -> "null"
  | Jsont.Object _ | Jsont.Array _ -> json_string json

let json_array items = Jsont.Json.list items

let has_combiner_fields fields =
  List.exists
    (fun name ->
      match object_member name fields with
      | Some (Jsont.Array _) -> true
      | Some _ | None -> false)
    [ "anyOf"; "oneOf"; "allOf" ]

let schema_intent_keys =
  [
    "type";
    "properties";
    "items";
    "prefixItems";
    "enum";
    "const";
    "$ref";
    "additionalProperties";
    "patternProperties";
    "required";
    "not";
    "if";
    "then";
    "else";
  ]

let has_schema_intent = function
  | Jsont.Object (raw_fields, _) ->
      let fields =
        List.map (fun ((name, _), value) -> (name, value)) raw_fields
      in
      has_combiner_fields fields
      || List.exists (fun key -> object_has key fields) schema_intent_keys
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      false

let rec sanitize_schema json =
  match json with
  | Jsont.Array (items, _) -> json_array (List.map sanitize_schema items)
  | Jsont.Object _ -> (
      match object_members json with
      | None -> json
      | Some fields ->
          let fields =
            List.map
              (fun (name, value) ->
                if String.equal name "enum" then
                  match value with
                  | Jsont.Array (items, _) ->
                      ( name,
                        json_array
                          (List.map
                             (fun item -> Jsont.Json.string (string_json item))
                             items) )
                  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
                  | Jsont.String _ | Jsont.Object _ ->
                      (name, sanitize_schema value)
                else (name, sanitize_schema value))
              fields
          in
          let fields =
            match
              (object_member "enum" fields, object_member "type" fields)
            with
            | Some (Jsont.Array _), Some (Jsont.String (type_, _))
              when String.equal type_ "integer" || String.equal type_ "number"
              ->
                object_set "type" (Jsont.Json.string "string") fields
            | _ -> fields
          in
          let fields =
            match
              ( object_member "type" fields,
                object_member "properties" fields,
                object_member "required" fields )
            with
            | ( Some (Jsont.String ("object", _)),
                Some (Jsont.Object (properties, _)),
                Some (Jsont.Array (required, _)) ) ->
                let property_names =
                  List.map (fun ((name, _), _) -> name) properties
                in
                let required =
                  List.filter_map
                    (function
                      | Jsont.String (field, _)
                        when List.exists (String.equal field) property_names ->
                          Some (Jsont.Json.string field)
                      | _ -> None)
                    required
                in
                object_set "required" (json_array required) fields
            | _ -> fields
          in
          let fields =
            match object_member "type" fields with
            | Some (Jsont.String ("array", _))
              when not (has_combiner_fields fields) ->
                let items =
                  Option.value
                    (object_member "items" fields)
                    ~default:(json_object [])
                in
                let items =
                  match object_members items with
                  | Some item_fields when not (has_schema_intent items) ->
                      json_object
                        (object_set "type"
                           (Jsont.Json.string "string")
                           item_fields)
                  | Some _ | None -> items
                in
                object_set "items" items fields
            | Some _ | None -> fields
          in
          let fields =
            match object_member "type" fields with
            | Some (Jsont.String (type_, _))
              when (not (String.equal type_ "object"))
                   && not (has_combiner_fields fields) ->
                fields |> object_remove "properties" |> object_remove "required"
            | Some _ | None -> fields
          in
          json_object fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _ -> json

let empty_gemini_object_schema fields =
  match object_member "type" fields with
  | Some (Jsont.String ("object", _)) ->
      let empty_properties =
        match object_member "properties" fields with
        | None -> true
        | Some (Jsont.Object (properties, _)) -> List.is_empty properties
        | Some _ -> false
      in
      let additional_properties =
        match object_member "additionalProperties" fields with
        | Some (Jsont.Bool (true, _)) -> true
        | Some _ | None -> false
      in
      empty_properties && not additional_properties
  | Some _ | None -> false

let optional_non_empty_array = function
  | Some (Jsont.Array ([], _)) | None -> None
  | Some value -> Some value

let project_type fields =
  match object_member "type" fields with
  | Some (Jsont.String _ as value) -> Some value
  | Some (Jsont.Array (items, _)) ->
      List.find_map
        (function
          | Jsont.String ("null", _) -> None
          | Jsont.String _ as value -> Some value
          | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
          | Jsont.Array _ ->
              None)
        items
  | Some _ | None -> None

let project_nullable fields =
  match object_member "type" fields with
  | Some (Jsont.Array (items, _)) ->
      if
        List.exists
          (function Jsont.String ("null", _) -> true | _ -> false)
          items
      then Some (Jsont.Json.bool true)
      else None
  | Some _ | None -> None

let rec project_schema json =
  match object_members (sanitize_schema json) with
  | None -> None
  | Some fields ->
      if empty_gemini_object_schema fields then None
      else
        let add_projected name value fields =
          match value with
          | None -> fields
          | Some value -> (name, value) :: fields
        in
        let project_schema_array name fields =
          match object_member name fields with
          | Some (Jsont.Array (items, _)) -> (
              match List.filter_map project_schema items with
              | [] -> None
              | items -> Some (json_array items))
          | Some _ | None -> None
        in
        let projected =
          []
          |> add_projected "description" (object_member "description" fields)
          |> add_projected "required"
               (optional_non_empty_array (object_member "required" fields))
          |> add_projected "format" (object_member "format" fields)
          |> add_projected "type" (project_type fields)
          |> add_projected "nullable" (project_nullable fields)
          |> add_projected "enum"
               (match object_member "const" fields with
               | Some value -> Some (json_array [ value ])
               | None -> object_member "enum" fields)
          |> add_projected "properties"
               (match object_member "properties" fields with
               | Some (Jsont.Object (properties, _)) ->
                   let properties =
                     List.filter_map
                       (fun ((name, _), value) ->
                         Option.map
                           (fun projected -> (name, projected))
                           (project_schema value))
                       properties
                   in
                   Some (json_object properties)
               | Some _ | None -> None)
          |> add_projected "items"
               (match object_member "items" fields with
               | Some (Jsont.Array (items, _)) -> (
                   match List.filter_map project_schema items with
                   | [] -> None
                   | items -> Some (json_array items))
               | Some item -> project_schema item
               | None -> None)
          |> add_projected "allOf" (project_schema_array "allOf" fields)
          |> add_projected "anyOf" (project_schema_array "anyOf" fields)
          |> add_projected "oneOf" (project_schema_array "oneOf" fields)
          |> add_projected "minLength" (object_member "minLength" fields)
        in
        Some (json_object (List.rev projected))

let gemini_tool_schema schema = project_schema schema

let encode_user_part = function
  | Llm.Content.Text text ->
      Ok (Jsont.Json.object' [ string_member "text" text ])
  | Llm.Content.Media { media_type; source = `Base64 data } ->
      Ok
        (Jsont.Json.object'
           [
             json_member "inlineData"
               (Jsont.Json.object'
                  [
                    string_member "mimeType" media_type;
                    string_member "data" data;
                  ]);
           ])
  | Llm.Content.Media { source = `Uri _; media_type = _ } ->
      unsupported "Google Gemini supports base64 inline media only"
  | Llm.Content.Media { source = `Ref _; media_type = _ } ->
      invalid_request "unresolved content reference reached Google provider"

(* Gemini 3 validates that the first functionCall part of each model turn
   carries a thought signature. Real signatures are round-tripped from
   {!Llm.Tool.Call.signature}; calls recorded without one (older sessions,
   histories produced by other providers) fall back to Google's documented
   skip constant, the same fallback gemini-cli ships. *)
let synthetic_thought_signature = "skip_thought_signature_validator"

let encode_tool_call_part ~first_call call =
  let signature =
    match Llm.Tool.Call.signature call with
    | Some _ as signature -> signature
    | None -> if first_call then Some synthetic_thought_signature else None
  in
  let fields =
    [
      json_member "functionCall"
        (Jsont.Json.object'
           [
             string_member "name" (Llm.Tool.Call.name call);
             json_member "args" (Llm.Tool.Call.input call);
           ]);
    ]
  in
  Jsont.Json.object' (add_opt string_member "thoughtSignature" signature fields)

(* A Gemini [thought] part carries neutral reasoning text; the replayable
   content is that text (or an OpenAI-style [summary]). A reasoning part with
   neither — for example a signed-but-textless thinking block recorded by
   Anthropic — has nothing to render as a Gemini thought and is dropped rather
   than blocking the whole request. *)
let encode_assistant_part = function
  | Llm.Message.Assistant.Text text ->
      Ok (Some (Jsont.Json.object' [ string_member "text" text ]))
  | Llm.Message.Assistant.Tool_call call ->
      Ok (Some (encode_tool_call_part ~first_call:false call))
  | Llm.Message.Assistant.Reasoning reasoning ->
      let text =
        match Llm.Message.Assistant.Reasoning.text reasoning with
        | Some text -> Some text
        | None -> Llm.Message.Assistant.Reasoning.summary reasoning
      in
      begin match text with
      | None -> Ok None
      | Some text ->
          let fields =
            [ string_member "text" text; bool_member "thought" true ]
          in
          let fields =
            add_opt string_member "thoughtSignature"
              (Llm.Message.Assistant.Reasoning.signature reasoning)
              fields
          in
          Ok (Some (Jsont.Json.object' (List.rev fields)))
      end

let encode_tool_result result =
  let content =
    match Llm.Tool.Result.content result with
    | [] -> Ok ""
    | blocks
      when List.exists
             (function
               | Llm.Content.Media { source = `Ref _; _ } -> true
               | Llm.Content.Text _ | Llm.Content.Media _ -> false)
             blocks ->
        invalid_request "unresolved content reference reached Google provider"
    | blocks ->
        if
          List.for_all
            (function
              | Llm.Content.Text _ -> true | Llm.Content.Media _ -> false)
            blocks
        then Ok (String.concat "\n" (Llm.Tool.Result.texts result))
        else unsupported "Google Gemini tool-result media is not supported"
  in
  Result.map
    (fun content ->
      Jsont.Json.object'
        [
          json_member "functionResponse"
            (Jsont.Json.object'
               [
                 string_member "name" (Llm.Tool.Result.name result);
                 json_member "response"
                   (Jsont.Json.object'
                      [
                        string_member "name" (Llm.Tool.Result.name result);
                        string_member "content" content;
                      ]);
               ]);
        ])
    content

let encode_message = function
  | Llm.Message.System text | Llm.Message.Developer text ->
      Ok (`System (Jsont.Json.object' [ string_member "text" text ]))
  | Llm.Message.User content ->
      Result.map
        (fun parts ->
          `Content
            (Jsont.Json.object'
               [ string_member "role" "user"; list_member "parts" parts ]))
        (result_map encode_user_part content)
  | Llm.Message.Assistant assistant ->
      let encode_parts parts =
        let rec loop acc ~first_call = function
          | [] -> Ok (List.rev acc)
          | Llm.Message.Assistant.Tool_call call :: rest ->
              loop
                (encode_tool_call_part ~first_call call :: acc)
                ~first_call:false rest
          | part :: rest -> (
              match encode_assistant_part part with
              | Error _ as error -> error
              | Ok None -> loop acc ~first_call rest
              | Ok (Some json) -> loop (json :: acc) ~first_call rest)
        in
        loop [] ~first_call:true parts
      in
      Result.map
        (fun parts ->
          `Content
            (Jsont.Json.object'
               [ string_member "role" "model"; list_member "parts" parts ]))
        (encode_parts (Llm.Message.Assistant.parts assistant))
  | Llm.Message.Tool_result result ->
      Result.map
        (fun part ->
          `Content
            (Jsont.Json.object'
               [ string_member "role" "user"; list_member "parts" [ part ] ]))
        (encode_tool_result result)

let split_messages messages =
  let rec loop system contents = function
    | [] -> Ok (List.rev system, List.rev contents)
    | message :: rest -> (
        match encode_message message with
        | Error error -> Error error
        | Ok (`System block) -> loop (block :: system) contents rest
        | Ok (`Content content) -> loop system (content :: contents) rest)
  in
  loop [] [] messages

let encode_tool tool =
  let fields = [ string_member "name" (Llm.Tool.name tool) ] in
  let fields =
    add_opt json_member "parameters"
      (gemini_tool_schema (Llm.Tool.input_schema tool))
      fields
  in
  let fields =
    match Llm.Tool.description tool with
    | None -> fields
    | Some description -> string_member "description" description :: fields
  in
  Jsont.Json.object' fields

let encode_tools tools =
  match tools with
  | [] -> []
  | tools ->
      [
        Jsont.Json.object'
          [ list_member "functionDeclarations" (List.map encode_tool tools) ];
      ]

let encode_tool_config tools = function
  | Llm.Request.Options.Auto ->
      if tools = [] then None
      else
        Some
          (Jsont.Json.object'
             [
               json_member "functionCallingConfig"
                 (Jsont.Json.object' [ string_member "mode" "AUTO" ]);
             ])
  | Llm.Request.Options.No_tools -> None
  | Llm.Request.Options.Required ->
      Some
        (Jsont.Json.object'
           [
             json_member "functionCallingConfig"
               (Jsont.Json.object' [ string_member "mode" "ANY" ]);
           ])
  | Llm.Request.Options.Tool name ->
      Some
        (Jsont.Json.object'
           [
             json_member "functionCallingConfig"
               (Jsont.Json.object'
                  [
                    string_member "mode" "ANY";
                    list_member "allowedFunctionNames"
                      [ Jsont.Json.string name ];
                  ]);
           ])

let thinking_budget = function
  | Llm.Request.Options.Reasoning_effort.Disabled -> Some 0
  | Llm.Request.Options.Reasoning_effort.Minimal -> Some 512
  | Llm.Request.Options.Reasoning_effort.Low -> Some 1_024
  | Llm.Request.Options.Reasoning_effort.Medium -> Some 8_192
  | Llm.Request.Options.Reasoning_effort.High -> Some 16_000
  | Llm.Request.Options.Reasoning_effort.Extra_high
  | Llm.Request.Options.Reasoning_effort.Max ->
      Some 24_576

let encode_thinking_config = function
  | None -> None
  | Some effort ->
      Some
        (Jsont.Json.object'
           ([
              bool_member "includeThoughts"
                (not Llm.Request.Options.(effort = Reasoning_effort.Disabled));
            ]
           |> add_opt int_member "thinkingBudget" (thinking_budget effort)
           |> List.rev))

let encode_generation_config options =
  let fields = [] in
  let fields =
    add_opt int_member "maxOutputTokens"
      (Llm.Request.Options.max_output_tokens options)
      fields
  in
  let fields =
    add_opt number_member "temperature"
      (Llm.Request.Options.temperature options)
      fields
  in
  let fields =
    add_opt json_member "thinkingConfig"
      (encode_thinking_config (Llm.Request.Options.reasoning_effort options))
      fields
  in
  match fields with [] -> None | fields -> Some (Jsont.Json.object' fields)

let encode_response_format = function
  | Llm.Request.Options.Text -> Ok ()
  | Llm.Request.Options.Json_schema _ ->
      unsupported "Google Gemini does not support response_format"

let encode_request request =
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    unsupported
      ("Google provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let options = Llm.Request.options request in
    match
      encode_response_format (Llm.Request.Options.response_format options)
    with
    | Error error -> Error error
    | Ok () -> (
        match split_messages (Llm.Request.messages request) with
        | Error error -> Error error
        | Ok (system, contents) ->
            let tools =
              match Llm.Request.Options.tool_choice options with
              | Llm.Request.Options.No_tools -> []
              | Llm.Request.Options.Auto | Llm.Request.Options.Required
              | Llm.Request.Options.Tool _ ->
                  Llm.Request.tools request
            in
            let system_instruction =
              match system with
              | [] -> None
              | parts -> Some (Jsont.Json.object' [ list_member "parts" parts ])
            in
            Ok
              {
                Api.Generate_content.model = Llm.Model.id model;
                contents;
                system_instruction;
                tools = encode_tools tools;
                tool_config =
                  encode_tool_config tools
                    (Llm.Request.Options.tool_choice options);
                generation_config = encode_generation_config options;
              })

let usage_of_json json =
  let raw_input = Option.value (int_field "promptTokenCount" json) ~default:0 in
  let cache_read =
    Option.value (int_field "cachedContentTokenCount" json) ~default:0
  in
  let reasoning =
    Option.value (int_field "thoughtsTokenCount" json) ~default:0
  in
  let output =
    Option.value (int_field "candidatesTokenCount" json) ~default:0
  in
  let input = max 0 (raw_input - cache_read) in
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ()

let merge_usage left right =
  match (left, right) with
  | None, usage | usage, None -> usage
  | Some left, Some right ->
      Some
        (Llm.Usage.make
           ~input:(max left.Llm.Usage.input right.Llm.Usage.input)
           ~output:(max left.Llm.Usage.output right.Llm.Usage.output)
           ~reasoning:(max left.Llm.Usage.reasoning right.Llm.Usage.reasoning)
           ~cache_read:
             (max left.Llm.Usage.cache_read right.Llm.Usage.cache_read)
           ~cache_write:
             (max left.Llm.Usage.cache_write right.Llm.Usage.cache_write)
           ())

let stop_reason finish_reason has_tool_calls =
  match finish_reason with
  | Some "STOP" ->
      Some
        (if has_tool_calls then Llm.Response.Stop.tool_call
         else Llm.Response.Stop.end_turn)
  | Some "MAX_TOKENS" -> Some Llm.Response.Stop.length
  | Some
      ( "IMAGE_SAFETY" | "RECITATION" | "SAFETY" | "BLOCKLIST"
      | "PROHIBITED_CONTENT" | "SPII" ) ->
      Some Llm.Response.Stop.content_filter
  | Some "MALFORMED_FUNCTION_CALL" -> Some (Llm.Response.Stop.other "error")
  | Some _ -> Some (Llm.Response.Stop.other "provider_stop")
  | None -> None

let error_kind_of_status = function
  | 400 -> Llm.Error.Invalid_request
  | 401 | 403 -> Llm.Error.Auth
  | 408 -> Llm.Error.Timeout
  | 409 -> Llm.Error.Transport
  | 413 -> Llm.Error.Context_overflow
  | 429 -> Llm.Error.Rate_limited
  | status when status >= 500 -> Llm.Error.Provider
  | _ -> Llm.Error.Provider

let error_kind_of_google_status = function
  | "UNAUTHENTICATED" | "PERMISSION_DENIED" -> Some Llm.Error.Auth
  | "RESOURCE_EXHAUSTED" -> Some Llm.Error.Rate_limited
  | "INVALID_ARGUMENT" | "FAILED_PRECONDITION" -> Some Llm.Error.Invalid_request
  | "DEADLINE_EXCEEDED" -> Some Llm.Error.Timeout
  | "ABORTED" | "UNAVAILABLE" -> Some Llm.Error.Transport
  | _ -> None

let request_id headers =
  match Mentat_llm_http.header_value headers "x-goog-request-id" with
  | Some _ as value -> value
  | None -> Mentat_llm_http.header_value headers "x-request-id"

let redacted_body body =
  if String.is_empty body then None
  else
    Some
      ("<redacted Google Gemini error body: "
      ^ string_of_int (String.length body)
      ^ " bytes>")

let api_error ?(phase = Llm.Error.Startup) = function
  | Api.Error.Transport message -> llm_error ~phase Llm.Error.Transport message
  | Api.Error.Decode message -> llm_error ~phase Llm.Error.Decode message
  | Api.Error.Response response ->
      let fallback = error_kind_of_status response.Api.Error.status in
      let request_id = request_id response.Api.Error.headers in
      let kind, message =
        match
          Jsont_bytesrw.decode_string Jsont.json response.Api.Error.body
        with
        | Ok json -> (
            match object_field "error" json with
            | Some error_json ->
                let kind =
                  Option.bind
                    (string_field "status" error_json)
                    error_kind_of_google_status
                  |> Option.value ~default:fallback
                in
                let message =
                  Option.value
                    (string_field "message" error_json)
                    ~default:"Google Gemini request failed"
                in
                (kind, message)
            | None ->
                ( fallback,
                  Option.value
                    (string_field "message" json)
                    ~default:"Google Gemini request failed" ))
        | Error _ ->
            ( fallback,
              if String.is_empty response.Api.Error.body then
                "Google Gemini request failed"
              else "Google Gemini request failed with non-JSON error body" )
      in
      let redacted_body = redacted_body response.Api.Error.body in
      llm_error ~phase ~status:response.Api.Error.status ?request_id
        ?redacted_body kind message

type state = {
  mutable parts : Llm.Message.Assistant.part list;
  mutable usage : Llm.Usage.t option;
  mutable finish_reason : string option;
  mutable response_id : string option;
  mutable response_model : string option;
  mutable next_tool_call_id : int;
  mutable error : Llm.Error.t option;
  reasoning_summary : Buffer.t;
  on_event : Llm.Event.t -> unit;
}

let state on_event =
  {
    parts = [];
    usage = None;
    finish_reason = None;
    response_id = None;
    response_model = None;
    next_tool_call_id = 0;
    error = None;
    reasoning_summary = Buffer.create 128;
    on_event;
  }

let emit state event = if Option.is_none state.error then state.on_event event
let fail state error = state.error <- Some error
let add_part state part = state.parts <- part :: state.parts

let add_text state text =
  if not (String.is_empty text) then (
    add_part state (Llm.Message.Assistant.text_part text);
    emit state (Llm.Event.text_delta text))

let add_reasoning state text =
  if not (String.is_empty text) then (
    Buffer.add_string state.reasoning_summary text;
    let reasoning = Llm.Message.Assistant.Reasoning.make ~text () in
    add_part state (Llm.Message.Assistant.reasoning_part reasoning);
    emit state (Llm.Event.reasoning_summary_delta text))

let add_tool_call state ?signature function_call =
  match string_field "name" function_call with
  | None ->
      fail state
        (stream_error Llm.Error.Decode
           "Google Gemini functionCall is missing name")
  | Some name ->
      let input =
        Option.value
          (object_field "args" function_call)
          ~default:(Jsont.Json.object' [])
      in
      (* Gemini does not assign call ids, so they are synthesized. The
         response id salts them: a per-response counter alone repeats across
         turns and collides with the session's unique tool-execution ids. *)
      let id =
        match state.response_id with
        | Some response_id ->
            "tool_" ^ response_id ^ "_" ^ string_of_int state.next_tool_call_id
        | None -> "tool_" ^ string_of_int state.next_tool_call_id
      in
      state.next_tool_call_id <- state.next_tool_call_id + 1;
      begin match Llm.Tool.Call.make ~id ~name ~input ?signature () with
      | call ->
          add_part state (Llm.Message.Assistant.tool_call call);
          emit state (Llm.Event.tool_call call)
      | exception Invalid_argument message ->
          fail state
            (stream_error Llm.Error.Decode
               ("Google Gemini functionCall is malformed: " ^ message))
      end

let handle_part state part =
  if Option.is_none state.error then
    match object_field "functionCall" part with
    | Some function_call ->
        let signature =
          match string_field "thoughtSignature" part with
          | Some "" | None -> None
          | Some _ as signature -> signature
        in
        add_tool_call state ?signature function_call
    | None -> (
        match string_field "text" part with
        | None -> ()
        | Some text ->
            if Option.value (bool_field "thought" part) ~default:false then
              add_reasoning state text
            else add_text state text)

let update_usage state usage_json =
  let usage = Option.map usage_of_json usage_json in
  state.usage <- merge_usage state.usage usage;
  Option.iter (fun usage -> emit state (Llm.Event.usage usage)) state.usage

let finish_response state requested_model =
  let parts = List.rev state.parts in
  let has_tool_calls =
    List.exists
      (function
        | Llm.Message.Assistant.Tool_call _ -> true
        | Llm.Message.Assistant.Text _ | Llm.Message.Assistant.Reasoning _ ->
            false)
      parts
  in
  let assistant =
    match parts with
    | [] -> Llm.Message.Assistant.empty
    | parts -> Llm.Message.Assistant.make parts
  in
  let reasoning_summary =
    if Buffer.length state.reasoning_summary = 0 then []
    else [ Buffer.contents state.reasoning_summary ]
  in
  match (state.finish_reason, has_tool_calls) with
  | None, false ->
      Error
        (stream_error Llm.Error.Malformed_stream
           "Google Gemini stream ended without finishReason")
  | _ ->
      let stop =
        match state.finish_reason with
        | None when has_tool_calls -> Some Llm.Response.Stop.tool_call
        | _ -> stop_reason state.finish_reason has_tool_calls
      in
      Ok
        (Llm.Response.make ~model:requested_model
           ?response_model:state.response_model ?response_id:state.response_id
           ?provider_stop:state.finish_reason ?stop ?usage:state.usage
           ~reasoning_summary assistant)

let handle_event state event =
  if Option.is_none state.error then (
    update_usage state
      (object_field "usageMetadata" event.Api.Generate_content.data);
    state.response_id <-
      Option.fold ~none:state.response_id
        ~some:(fun value -> Some value)
        (string_field "responseId" event.Api.Generate_content.data);
    state.response_model <-
      Option.fold ~none:state.response_model
        ~some:(fun value -> Some value)
        (string_field "modelVersion" event.Api.Generate_content.data);
    match list_field "candidates" event.Api.Generate_content.data with
    | None -> ()
    | Some candidates ->
        List.iter
          (fun candidate ->
            state.finish_reason <-
              Option.fold ~none:state.finish_reason
                ~some:(fun value -> Some value)
                (string_field "finishReason" candidate);
            match object_field "content" candidate with
            | None -> ()
            | Some content ->
                Option.value (list_field "parts" content) ~default:[]
                |> List.iter (handle_part state))
          candidates)

let consume_events ~cancelled ~elapsed ~on_event requested_model api_stream =
  let state = state on_event in
  let rec consume () =
    if cancelled () then (
      Log.debug (fun m ->
          m "request cancelled model=%s" (Llm.Model.id requested_model));
      Error (cancelled_error ~phase:Llm.Error.Stream ()))
    else
      match Api.Generate_content.next api_stream with
      | Some (Error error) -> Error (api_error ~phase:Llm.Error.Stream error)
      | Some (Ok event) ->
          handle_event state event;
          begin match state.error with
          | Some error -> Error error
          | None -> consume ()
          end
      | None ->
          begin match finish_response state requested_model with
          | Error error -> Error error
          | Ok response ->
              Log.info (fun m ->
                  let usage =
                    Option.value
                      (Llm.Response.usage response)
                      ~default:Llm.Usage.zero
                  in
                  m
                    "request finished model=%s stop=%s input=%d output=%d \
                     duration=%.0fms"
                    (Llm.Model.id requested_model)
                    (Option.fold ~none:"none" ~some:Llm.Response.Stop.label
                       (Llm.Response.stop response))
                    usage.Llm.Usage.input usage.Llm.Usage.output (elapsed ()));
              Ok response
          end
  in
  Fun.protect ~finally:(fun () -> Api.Generate_content.close api_stream) consume

let perform_request ~sw ~env config credential ~phase ~cancelled ~on_event
    request =
  if cancelled () then Error (cancelled_error ())
  else
    let model = Llm.Request.model request in
    match encode_request request with
    | Error error -> Error error
    | Ok api_request ->
        Log.info (fun m -> m "request started model=%s" (Llm.Model.id model));
        let clock = env#clock in
        let started = Eio.Time.now clock in
        let elapsed () = (Eio.Time.now clock -. started) *. 1000. in
        let api_client =
          Api.Client.make config ~sw ~env
            ~auth:(Credential.api_auth credential)
            ()
        in
        (* The stream budget is deeper than the pre-stream one (codex's split),
           but [max_retries = Some 0] is the caller's blanket "no retries" and
           silences the stream re-run too. *)
        let max_retries =
          match Config.max_retries config with
          | Some 0 -> 0
          | Some _ | None ->
              Option.value
                (Config.max_stream_retries config)
                ~default:Api.default_stream_max_retries
        in
        Mentat_llm_http.Retry.stream ~clock ~cancelled ~max_retries ~on_event
          ~open_stream:(fun ~on_retry ->
            match
              Api.Generate_content.create_stream ~on_retry api_client
                api_request
            with
            | Error error -> Error (api_error error)
            | Ok api_stream ->
                phase := Llm.Error.Stream;
                Ok api_stream)
          ~consume:(fun ~on_event api_stream ->
            consume_events ~cancelled ~elapsed ~on_event model api_stream)

let run ~env config credential ~cancelled ~on_event request =
  let phase = ref Llm.Error.Startup in
  match
    Eio.Time.with_timeout env#clock (Config.timeout_s config) (fun () ->
        Ok
          ( Eio.Switch.run ~name:"google.request" @@ fun sw ->
            perform_request ~sw ~env config credential ~phase ~cancelled
              ~on_event request ))
  with
  | Ok result -> result
  | Error `Timeout ->
      Error (timeout_error ~phase:!phase (Config.timeout_s config))

let client ~env ?(config = Config.default) ~credential () =
  Llm.Client.make ~provider ~apis:[ api ] ~run:(run ~env config credential)
