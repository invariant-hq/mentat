(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Mentat_llm
module Config = Config

let log_src = Logs.Src.create "mentat.llm.openai" ~doc:"OpenAI provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make Api.api
let model id = Llm.Model.make ~provider ~api ~id

module Credential = struct
  type t = Api_key of string | Bearer of string

  let contains_newline value =
    String.exists (function '\n' | '\r' -> true | _ -> false) value

  let check_header_value fn value =
    if String.is_empty value then
      invalid_arg ("Mentat_llm_openai.Credential." ^ fn ^ ": empty value");
    if contains_newline value then
      invalid_arg
        ("Mentat_llm_openai.Credential." ^ fn ^ ": value contains newline")

  let api_key key =
    check_header_value "api_key" key;
    Api_key key

  let bearer token =
    check_header_value "bearer" token;
    Bearer token

  let api_auth = function
    | Api_key key -> Api.Client.Api_key key
    | Bearer token -> Api.Client.Bearer token
end

let llm_error ?(phase = Llm.Error.Startup) ?status ?request_id ?redacted_body
    kind message =
  Llm.Error.make ~kind ~phase ~provider ?status ?request_id ?redacted_body
    message

let invalid_request message =
  Error (llm_error Llm.Error.Invalid_request message)

let unsupported message = Error (llm_error Llm.Error.Unsupported message)

let decode_error message =
  Error (llm_error ~phase:Llm.Error.Stream Llm.Error.Decode message)

let stream_error kind message = llm_error ~phase:Llm.Error.Stream kind message

let cancelled_error ?(phase = Llm.Error.Startup) () =
  llm_error ~phase Llm.Error.Cancelled "OpenAI request cancelled"

let timeout_error ~phase seconds =
  llm_error ~phase Llm.Error.Timeout
    (Printf.sprintf "OpenAI request timed out after %gs" seconds)

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message -> invalid_arg ("JSON encode failed: " ^ message)

let json_of_string text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok json -> Ok json
  | Error message -> decode_error ("OpenAI JSON decode failed: " ^ message)

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
let list_member name value = json_member name (Jsont.Json.list value)

let encode_content = function
  | Llm.Content.Text text ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "input_text"; string_member "text" text ])
  | Llm.Content.Media { media_type; source } -> (
      match source with
      | `Ref _ ->
          invalid_request "unresolved content reference reached OpenAI provider"
      | (`Uri _ | `Base64 _) as source ->
          if not (String.starts_with ~prefix:"image/" media_type) then
            unsupported "OpenAI Responses supports image media only"
          else
            let image_url =
              match source with
              | `Uri uri -> uri
              | `Base64 data -> "data:" ^ media_type ^ ";base64," ^ data
            in
            Ok
              (Jsont.Json.object'
                 [
                   string_member "type" "input_image";
                   string_member "image_url" image_url;
                 ]))

let encode_assistant_part = function
  | Llm.Message.Assistant.Text text ->
      Ok
        [
          Jsont.Json.object'
            [
              string_member "role" "assistant";
              json_member "content"
                (Jsont.Json.list
                   [
                     Jsont.Json.object'
                       [
                         string_member "type" "output_text";
                         string_member "text" text;
                       ];
                   ]);
            ];
        ]
  | Llm.Message.Assistant.Tool_call call ->
      Ok
        [
          Jsont.Json.object'
            [
              string_member "type" "function_call";
              string_member "call_id" (Llm.Tool.Call.id call);
              string_member "name" (Llm.Tool.Call.name call);
              string_member "arguments" (json_string (Llm.Tool.Call.input call));
            ];
        ]
  | Llm.Message.Assistant.Reasoning reasoning ->
      (* We send store=false for full-transcript replay, so OpenAI response
         item ids are not server-persisted. Retain ids in transcripts for
         diagnostics, but do not replay them as input items. Without encrypted
         state, a previous reasoning item is not replayable. *)
      begin match Llm.Message.Assistant.Reasoning.encrypted reasoning with
      | None -> Ok []
      | Some encrypted ->
          let fields =
            [
              string_member "type" "reasoning";
              string_member "encrypted_content" encrypted;
            ]
          in
          let fields =
            match Llm.Message.Assistant.Reasoning.summary reasoning with
            | None -> list_member "summary" [] :: fields
            | Some summary ->
                list_member "summary"
                  [
                    Jsont.Json.object'
                      [
                        string_member "type" "summary_text";
                        string_member "text" summary;
                      ];
                  ]
                :: fields
          in
          let fields =
            match Llm.Message.Assistant.Reasoning.text reasoning with
            | None -> fields
            | Some text ->
                list_member "content"
                  [
                    Jsont.Json.object'
                      [
                        string_member "type" "reasoning_text";
                        string_member "text" text;
                      ];
                  ]
                :: fields
          in
          Ok [ Jsont.Json.object' (List.rev fields) ]
      end

let encode_tool_result result =
  let content = Llm.Tool.Result.content result in
  let output =
    match content with
    | [] -> Ok (Jsont.Json.string "")
    | blocks ->
        if
          List.for_all
            (function
              | Llm.Content.Text _ -> true | Llm.Content.Media _ -> false)
            blocks
        then
          Ok
            (Jsont.Json.string
               (String.concat "\n" (Llm.Tool.Result.texts result)))
        else
          Result.map
            (fun blocks -> Jsont.Json.list blocks)
            (result_map encode_content blocks)
  in
  Result.map
    (fun output ->
      [
        Jsont.Json.object'
          [
            string_member "type" "function_call_output";
            string_member "call_id" (Llm.Tool.Result.call_id result);
            json_member "output" output;
          ];
      ])
    output

let encode_message = function
  | Llm.Message.System text ->
      Ok
        [
          Jsont.Json.object'
            [ string_member "role" "system"; string_member "content" text ];
        ]
  | Llm.Message.Developer text ->
      Ok
        [
          Jsont.Json.object'
            [ string_member "role" "developer"; string_member "content" text ];
        ]
  | Llm.Message.User content ->
      Result.map
        (fun content ->
          [
            Jsont.Json.object'
              [ string_member "role" "user"; list_member "content" content ];
          ])
        (result_map encode_content content)
  | Llm.Message.Assistant assistant ->
      Result.map List.concat
        (result_map encode_assistant_part
           (Llm.Message.Assistant.parts assistant))
  | Llm.Message.Tool_result result -> encode_tool_result result

let encode_tool tool =
  let fields =
    [
      string_member "type" "function";
      string_member "name" (Llm.Tool.name tool);
      json_member "parameters" (Llm.Tool.input_schema tool);
    ]
  in
  let fields =
    match Llm.Tool.description tool with
    | None -> fields
    | Some description -> string_member "description" description :: fields
  in
  Jsont.Json.object' fields

let encode_tool_choice = function
  | Llm.Request.Options.Auto -> Jsont.Json.string "auto"
  | Llm.Request.Options.No_tools -> Jsont.Json.string "none"
  | Llm.Request.Options.Required -> Jsont.Json.string "required"
  | Llm.Request.Options.Tool name ->
      Jsont.Json.object'
        [ string_member "type" "function"; string_member "name" name ]

let encode_reasoning_effort = function
  | Llm.Request.Options.Reasoning_effort.Disabled -> Ok "none"
  | Llm.Request.Options.Reasoning_effort.Minimal -> Ok "minimal"
  | Llm.Request.Options.Reasoning_effort.Low -> Ok "low"
  | Llm.Request.Options.Reasoning_effort.Medium -> Ok "medium"
  | Llm.Request.Options.Reasoning_effort.High -> Ok "high"
  | Llm.Request.Options.Reasoning_effort.Extra_high -> Ok "xhigh"
  | Llm.Request.Options.Reasoning_effort.Max -> Ok "max"

let encode_response_format = function
  | Llm.Request.Options.Text -> None
  | Llm.Request.Options.Json_schema { name; schema; strict } ->
      Some
        (Jsont.Json.object'
           [
             json_member "format"
               (Jsont.Json.object'
                  [
                    string_member "type" "json_schema";
                    string_member "name" name;
                    json_member "schema" schema;
                    bool_member "strict" strict;
                  ]);
           ])

let instruction_text messages =
  let rec loop instructions input = function
    | [] ->
        let instructions =
          match List.rev instructions with
          | [] -> None
          | instructions -> Some (String.concat "\n\n" instructions)
        in
        (instructions, List.rev input)
    | Llm.Message.System text :: rest | Llm.Message.Developer text :: rest ->
        loop (text :: instructions) input rest
    | message :: rest -> loop instructions (message :: input) rest
  in
  loop [] [] messages

let encode_request request =
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    unsupported
      ("OpenAI provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let options = Llm.Request.options request in
    (* Instruction hoisting is prelude-only so the instructions field stays
       byte-stable for the whole session: a system or developer message
       appended mid-session rides along as an ordinary input item instead of
       rewriting instructions and invalidating the cached prompt prefix. *)
    let instructions, prelude =
      instruction_text
        (Llm.Request.Prelude.messages (Llm.Request.prelude request))
    in
    let messages =
      prelude @ Llm.Transcript.messages (Llm.Request.transcript request)
    in
    match result_map encode_message messages with
    | Error error -> Error error
    | Ok input_nested ->
        let tools =
          match Llm.Request.tools request with
          | [] -> []
          | tools -> List.map encode_tool tools
        in
        let reasoning_result =
          match Llm.Request.Options.reasoning_effort options with
          | None -> Ok None
          | Some effort ->
              Result.map
                (fun encoded ->
                  (* Request a reasoning summary so the model returns the
                     human-readable ∴ thinking text; without this field the
                     Responses API emits reasoning but no summary. A disabled
                     effort reasons not at all, so it asks for no summary. *)
                  let fields = [ string_member "effort" encoded ] in
                  let fields =
                    match effort with
                    | Llm.Request.Options.Reasoning_effort.Disabled -> fields
                    | _ -> fields @ [ string_member "summary" "auto" ]
                  in
                  Some (Jsont.Json.object' fields))
                (encode_reasoning_effort effort)
        in
        Result.map
          (fun reasoning ->
            let include_items =
              match reasoning with
              | None -> []
              | Some _ -> [ "reasoning.encrypted_content" ]
            in
            {
              Api.Responses.model = Llm.Model.id model;
              instructions;
              input = List.concat input_nested;
              tools;
              tool_choice =
                encode_tool_choice (Llm.Request.Options.tool_choice options);
              reasoning;
              include_items;
              text =
                encode_response_format
                  (Llm.Request.Options.response_format options);
              prompt_cache_key = Llm.Request.cache_key request;
              max_output_tokens = Llm.Request.Options.max_output_tokens options;
              temperature =
                (if Option.is_some reasoning then None
                 else Llm.Request.Options.temperature options);
              stream = true;
              store = false;
            })
          reasoning_result

let usage_of_json json =
  let raw_input = Option.value (int_field "input_tokens" json) ~default:0 in
  let raw_output = Option.value (int_field "output_tokens" json) ~default:0 in
  let cache_read =
    match object_field "input_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "cached_tokens" details) ~default:0
  in
  let reasoning =
    match object_field "output_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "reasoning_tokens" details) ~default:0
  in
  let input = max 0 (raw_input - cache_read) in
  let output = max 0 (raw_output - reasoning) in
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ()

let parse_tool_input raw =
  match json_of_string raw with
  | Ok json -> Ok json
  | Error error ->
      Error
        (llm_error ~phase:(Llm.Error.phase error) Llm.Error.Decode
           ("OpenAI function call arguments are not valid JSON: "
          ^ Llm.Error.message error))

let decode_message_item item =
  let content = Option.value (list_field "content" item) ~default:[] in
  let decode_content content =
    match string_field "type" content with
    | Some "output_text" ->
        Option.map Llm.Message.Assistant.text_part (string_field "text" content)
    | Some "refusal" ->
        Option.map Llm.Message.Assistant.text_part
          (string_field "refusal" content)
    | Some _ | None -> None
  in
  Ok (List.filter_map decode_content content)

let decode_tool_item item =
  let call_id = Option.value (string_field "call_id" item) ~default:"" in
  let name = Option.value (string_field "name" item) ~default:"" in
  let raw_input = Option.value (string_field "arguments" item) ~default:"{}" in
  if String.is_empty call_id || String.is_empty name then
    decode_error "OpenAI function_call item is missing call_id or name"
  else
    match parse_tool_input raw_input with
    | Error error -> Error error
    | Ok input ->
        Ok
          [
            Llm.Message.Assistant.tool_call
              (Llm.Tool.Call.make ~id:call_id ~name ~input ());
          ]

let text_parts name item =
  Option.value (list_field name item) ~default:[]
  |> List.filter_map (string_field "text")

let decode_reasoning_item item =
  let id = string_field "id" item in
  let encrypted = string_field "encrypted_content" item in
  let summary =
    match String.concat "\n" (text_parts "summary" item) with
    | "" -> None
    | summary -> Some summary
  in
  let text =
    match String.concat "\n" (text_parts "content" item) with
    | "" -> None
    | text -> Some text
  in
  match (id, summary, text, encrypted) with
  | None, None, None, None -> Ok []
  | _ -> (
      match
        Llm.Message.Assistant.Reasoning.make ?id ?summary ?text ?encrypted ()
      with
      | reasoning -> Ok [ Llm.Message.Assistant.reasoning_part reasoning ]
      | exception Invalid_argument message ->
          decode_error ("OpenAI reasoning item is malformed: " ^ message))

let decode_output ?fallback response =
  let output =
    match list_field "output" response with
    | Some (_ :: _ as output) -> output
    | Some [] | None -> Option.value fallback ~default:[]
  in
  let decode_item item =
    match string_field "type" item with
    | Some "message" -> decode_message_item item
    | Some "function_call" -> decode_tool_item item
    | Some "reasoning" -> decode_reasoning_item item
    | Some _ | None -> Ok []
  in
  Result.map List.concat (result_map decode_item output)

let stop_reason response parts =
  match string_field "status" response with
  | Some "incomplete" -> (
      match
        Option.bind
          (object_field "incomplete_details" response)
          (string_field "reason")
      with
      | Some "max_output_tokens" -> Some Llm.Response.Stop.length
      | Some "content_filter" -> Some Llm.Response.Stop.content_filter
      | Some reason ->
          Some
            (Option.value
               (Llm.Response.Stop.of_label reason)
               ~default:(Llm.Response.Stop.other "provider_stop"))
      | None -> Some (Llm.Response.Stop.other "incomplete"))
  | Some "failed" -> Some (Llm.Response.Stop.other "failed")
  | Some "cancelled" -> Some (Llm.Response.Stop.other "cancelled")
  | Some _ | None ->
      if
        List.exists
          (function
            | Llm.Message.Assistant.Tool_call _ -> true
            | Llm.Message.Assistant.Text _ | Llm.Message.Assistant.Reasoning _
              ->
                false)
          parts
      then Some Llm.Response.Stop.tool_call
      else if Option.value (bool_field "end_turn" response) ~default:true then
        Some Llm.Response.Stop.end_turn
      else None

let final_response ?(reasoning_summary = []) ?output_items requested_model
    response =
  match decode_output ?fallback:output_items response with
  | Error error -> Error error
  | Ok [] -> decode_error "OpenAI response produced no assistant parts"
  | Ok parts ->
      let assistant = Llm.Message.Assistant.make parts in
      Ok
        (Llm.Response.make ~model:requested_model
           ?response_model:(string_field "model" response)
           ?response_id:(string_field "id" response)
           ?provider_stop:(string_field "status" response)
           ?stop:(stop_reason response parts)
           ?usage:(Option.map usage_of_json (object_field "usage" response))
           ~reasoning_summary assistant)

let error_kind_of_status = function
  | 400 -> Llm.Error.Invalid_request
  | 401 | 403 -> Llm.Error.Auth
  | 408 -> Llm.Error.Timeout
  | 409 -> Llm.Error.Transport
  | 413 -> Llm.Error.Context_overflow
  | 429 -> Llm.Error.Rate_limited
  | status when status >= 500 -> Llm.Error.Provider
  | _ -> Llm.Error.Provider

let error_kind_of_provider_code = function
  | "context_length_exceeded" -> Some Llm.Error.Context_overflow
  | "insufficient_quota" -> Some Llm.Error.Quota
  | "rate_limit_exceeded" | "slow_down" | "server_is_overloaded" ->
      Some Llm.Error.Rate_limited
  | "content_policy_violation" | "safety_violation" | "cyber_policy" ->
      Some Llm.Error.Content_policy
  | "invalid_prompt" | "invalid_request_error" -> Some Llm.Error.Invalid_request
  | "usage_not_included" -> Some Llm.Error.Provider
  | _ -> None

let provider_error_json json =
  match object_field "error" json with
  | Some _ as error -> error
  | None -> Option.bind (object_field "response" json) (object_field "error")

let provider_error_kind fallback json =
  match provider_error_json json with
  | None -> fallback
  | Some error_json -> (
      match
        Option.bind (string_field "code" error_json) error_kind_of_provider_code
      with
      | Some kind -> kind
      | None -> (
          match
            Option.bind
              (string_field "type" error_json)
              error_kind_of_provider_code
          with
          | Some kind -> kind
          | None -> fallback))

let provider_error_message default json =
  match provider_error_json json with
  | Some error_json -> Option.value (string_field "message" error_json) ~default
  | None ->
      Option.value
        (string_field "message" json)
        ~default:(Option.value (string_field "detail" json) ~default)

let header_value headers name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    headers

let request_id headers =
  match header_value headers "openai-request-id" with
  | Some _ as value -> value
  | None -> header_value headers "x-request-id"

let redacted_body body =
  if String.is_empty body then None
  else
    Some
      ("<redacted OpenAI error body: "
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
        | Ok json ->
            ( provider_error_kind fallback json,
              provider_error_message "OpenAI request failed" json )
        | Error _ ->
            ( fallback,
              if String.is_empty response.Api.Error.body then
                "OpenAI request failed"
              else "OpenAI request failed with non-JSON error body" )
      in
      let redacted_body = redacted_body response.Api.Error.body in
      llm_error ~phase ~status:response.Api.Error.status ?request_id
        ?redacted_body kind message

type partial = {
  mutable call_id : string option;
  mutable name : string option;
  mutable raw_input : string;
  mutable emitted_tool : bool;
}

let partial () =
  { call_id = None; name = None; raw_input = ""; emitted_tool = false }

let partial_at table key =
  match Hashtbl.find_opt table key with
  | Some partial -> partial
  | None ->
      let partial = partial () in
      Hashtbl.add table key partial;
      partial

let tool_call_of_partial partial =
  match (partial.call_id, partial.name) with
  | Some id, Some name -> (
      let raw_input =
        if String.is_empty partial.raw_input then "{}" else partial.raw_input
      in
      match parse_tool_input raw_input with
      | Error error -> Error error
      | Ok input -> (
          match Llm.Tool.Call.make ~id ~name ~input () with
          | call -> Ok call
          | exception Invalid_argument message ->
              decode_error ("OpenAI function_call item is malformed: " ^ message)
          ))
  | None, _ -> decode_error "OpenAI streamed function_call is missing call_id"
  | _, None -> decode_error "OpenAI streamed function_call is missing name"

let consume_events ~cancelled ~elapsed ~on_event requested_model api_stream =
  let partials = Hashtbl.create 8 in
  let reasoning_summary = Buffer.create 128 in
  let output_items = ref [] in
  let result = ref None in
  let emit event = on_event event in
  let fail error = result := Some (Error error) in
  let emit_tool_call partial =
    if not partial.emitted_tool then
      match tool_call_of_partial partial with
      | Error error -> fail error
      | Ok call ->
          partial.emitted_tool <- true;
          emit (Llm.Event.tool_call call)
  in
  let field_string_or name ~default json =
    Option.value (string_field name json) ~default
  in
  let output_item_key item json =
    field_string_or "id"
      ~default:(field_string_or "output_index" ~default:"0" json)
      item
  in
  let argument_key json =
    Option.value
      (string_field "item_id" json)
      ~default:
        (Option.value
           (Option.map string_of_int (int_field "output_index" json))
           ~default:"0")
  in
  let delta json = field_string_or "delta" ~default:"" json in
  let emit_usage response =
    Option.iter
      (fun usage -> emit (Llm.Event.usage usage))
      (Option.map usage_of_json (object_field "usage" response))
  in
  let handle event =
    if Option.is_none !result then
      match event with
      | Error error -> fail (api_error ~phase:Llm.Error.Stream error)
      | Ok ({ Api.Responses.name; data = json } : Api.Responses.event) -> (
          (match object_field "response" json with
          | None -> ()
          | Some response -> emit_usage response);
          match name with
          | "response.output_text.delta" ->
              let delta = delta json in
              if not (String.is_empty delta) then
                emit (Llm.Event.text_delta delta)
          | "response.reasoning_summary_text.delta"
          | "response.reasoning_summary.delta" ->
              let delta = delta json in
              if not (String.is_empty delta) then (
                Buffer.add_string reasoning_summary delta;
                emit (Llm.Event.reasoning_summary_delta delta))
          | "response.output_item.added" | "response.output_item.done" -> (
              match object_field "item" json with
              | None -> ()
              | Some item ->
                  if String.equal name "response.output_item.done" then
                    output_items := item :: !output_items;
                  if
                    Option.equal String.equal (string_field "type" item)
                      (Some "function_call")
                  then (
                    let key = output_item_key item json in
                    let partial = partial_at partials key in
                    partial.call_id <- string_field "call_id" item;
                    partial.name <- string_field "name" item;
                    Option.iter
                      (fun raw_input -> partial.raw_input <- raw_input)
                      (string_field "arguments" item);
                    if String.equal name "response.output_item.done" then
                      emit_tool_call partial))
          | "response.function_call_arguments.delta" ->
              let key = argument_key json in
              let delta = delta json in
              let partial = partial_at partials key in
              partial.raw_input <- partial.raw_input ^ delta;
              if not (String.is_empty delta) then
                emit
                  (Llm.Event.tool_input_delta
                     (Llm.Event.Tool_input.make ~key ?call_id:partial.call_id
                        ?name:partial.name ~input_delta:delta ()))
          | "response.function_call_arguments.done" ->
              let key = argument_key json in
              let partial = partial_at partials key in
              Option.iter
                (fun raw_input -> partial.raw_input <- raw_input)
                (string_field "arguments" json);
              let raw_input =
                if String.is_empty partial.raw_input then "{}"
                else partial.raw_input
              in
              begin match parse_tool_input raw_input with
              | Ok _ -> ()
              | Error error -> fail error
              end
          | "response.completed" | "response.incomplete" -> (
              match object_field "response" json with
              | None ->
                  fail
                    (stream_error Llm.Error.Decode
                       "OpenAI terminal event is missing response")
              | Some response -> (
                  let reasoning_summary =
                    if Buffer.length reasoning_summary = 0 then []
                    else [ Buffer.contents reasoning_summary ]
                  in
                  match
                    final_response ~reasoning_summary
                      ~output_items:(List.rev !output_items) requested_model
                      response
                  with
                  | Error error -> fail error
                  | Ok response ->
                      Log.info (fun m ->
                          let usage =
                            Option.value
                              (Llm.Response.usage response)
                              ~default:Llm.Usage.zero
                          in
                          m
                            "request finished model=%s stop=%s input=%d \
                             output=%d duration=%.0fms"
                            (Llm.Model.id requested_model)
                            (Option.fold ~none:"none"
                               ~some:Llm.Response.Stop.label
                               (Llm.Response.stop response))
                            usage.Llm.Usage.input usage.Llm.Usage.output
                            (elapsed ()));
                      result := Some (Ok response)))
          | "response.failed" | "error" ->
              fail
                (stream_error
                   (provider_error_kind Llm.Error.Provider json)
                   (provider_error_message "OpenAI stream error" json))
          | "response.created" | "response.in_progress" | "response.queued"
          | "response.output_text.done" | "response.content_part.added"
          | "response.content_part.done" | "response.reasoning_text.delta"
          | "response.reasoning_text.done"
          | "response.reasoning_summary_text.done"
          | "response.reasoning_summary.done" ->
              ()
          | _ -> ())
  in
  let rec consume () =
    match !result with
    | Some result -> result
    | None when cancelled () ->
        Log.debug (fun m ->
            m "request cancelled model=%s" (Llm.Model.id requested_model));
        Error (cancelled_error ~phase:Llm.Error.Stream ())
    | None -> (
        match Api.Responses.next api_stream with
        | Some event ->
            handle event;
            consume ()
        | None ->
            Log.debug (fun m ->
                m "stream ended without response.completed model=%s"
                  (Llm.Model.id requested_model));
            Error
              (stream_error Llm.Error.Malformed_stream
                 "OpenAI stream ended without response.completed"))
  in
  Fun.protect ~finally:(fun () -> Api.Responses.close api_stream) consume

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
              Api.Responses.create_stream ~on_retry api_client api_request
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
          ( Eio.Switch.run ~name:"openai.request" @@ fun sw ->
            perform_request ~sw ~env config credential ~phase ~cancelled
              ~on_event request ))
  with
  | Ok result -> result
  | Error `Timeout ->
      Error (timeout_error ~phase:!phase (Config.timeout_s config))

let client ~env ?(config = Config.default) ~credential () =
  Llm.Client.make ~provider ~apis:[ api ] ~run:(run ~env config credential)
