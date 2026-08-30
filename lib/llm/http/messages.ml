(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Http = Transport
module Llm = Mentat_llm

let log_src =
  Logs.Src.create "mentat.llm.messages" ~doc:"Messages protocol endpoints"

module Log = (val Logs.src_log log_src : Logs.LOG)

let api = Llm.Model.Api.make "messages"
let default_max_retries = 2
let default_stream_max_retries = 5

type t = {
  provider : Llm.Provider.t;
  label : string;
  headers : (string * string) list;
  timeout_s : float option;
  max_retries : int option;
  max_stream_retries : int option;
  terminal : (Http.response -> bool) option;
  classify : (status:int -> body:string -> Llm.Error.kind option) option;
  cache : bool;
  sampling : bool;
  endpoint : string;
  sw : Eio.Switch.t;
  env : Eio_unix.Stdenv.base;
}

(* Error strings carry the consuming provider's name; deriving it from the
   namespace keeps the codec neutral without changing any consumer's text. *)
let label_of provider = String.capitalize_ascii (Llm.Provider.id provider)

let make ~provider ?(headers = []) ?timeout_s ?max_retries ?max_stream_retries
    ?terminal ?classify ~cache ~sampling ~endpoint ~sw ~env () =
  {
    provider;
    label = label_of provider;
    headers;
    timeout_s;
    max_retries;
    max_stream_retries;
    terminal;
    classify;
    cache;
    sampling;
    endpoint;
    sw;
    env;
  }

(* The raw wire boundary: HTTP request construction, SSE decode, and the
   pre-stream retry loop. *)

module Wire_error = struct
  type t = Response of Http.response | Transport of string | Decode of string
end

let wire_headers t attempt =
  t.headers
  @ [
      ("content-type", "application/json");
      ("accept", "text/event-stream");
      ("anthropic-version", "2023-06-01");
      ("user-agent", "mentat-llm-messages/0");
      ("x-stainless-retry-count", string_of_int attempt);
    ]

let error_of_http = function
  | Http.Response response -> Wire_error.Response response
  | Http.Transport message | Http.Unresolved_host message ->
      Wire_error.Transport message

let stream_post t ~on_retry ~body =
  let max_retries =
    Option.value t.max_retries ~default:default_max_retries
  in
  Retry.pre_stream ~clock:t.env#clock ~max_retries ?terminal:t.terminal
    ~on_retry (fun ~attempt ->
      Http.post_stream ~sw:t.sw ~env:t.env ~url:t.endpoint
        ~headers:(wire_headers t attempt) ~body)
  |> Result.map_error error_of_http

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let int_member name value = json_member name (Jsont.Json.int value)
let number_member name value = json_member name (Jsont.Json.number value)
let list_member name value = json_member name (Jsont.Json.list value)

let add_opt member name value fields =
  match value with None -> fields | Some value -> member name value :: fields

module Wire = struct
  type request = {
    model : string;
    system : Jsont.json list;
    messages : Jsont.json list;
    tools : Jsont.json list;
    tool_choice : Jsont.json option;
    thinking : Jsont.json option;
    output_config : Jsont.json option;
    max_tokens : int;
    temperature : float option;
    stream : bool;
  }

  type event = { name : string; data : Jsont.json }

  let body request =
    let fields =
      [
        string_member "model" request.model;
        list_member "messages" request.messages;
        int_member "max_tokens" request.max_tokens;
        bool_member "stream" request.stream;
      ]
    in
    let fields =
      match request.system with
      | [] -> fields
      | system -> list_member "system" system :: fields
    in
    let fields =
      match request.tools with
      | [] -> fields
      | tools -> list_member "tools" tools :: fields
    in
    let fields = add_opt json_member "tool_choice" request.tool_choice fields in
    let fields = add_opt json_member "thinking" request.thinking fields in
    let fields =
      add_opt json_member "output_config" request.output_config fields
    in
    let fields =
      add_opt number_member "temperature" request.temperature fields
    in
    Jsont.Json.object' (List.rev fields)

  let event_type = function
    | Jsont.Object (fields, _) -> (
        match Jsont.Json.find_mem "type" fields with
        | Some (_, Jsont.String (value, _)) -> Some value
        | Some _ | None -> None)
    | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
    | Jsont.Array _ ->
        None

  let decode_sse_event ~label name raw_data =
    match Jsont_bytesrw.decode_string Jsont.json raw_data with
    | Error message ->
        Error
          (Wire_error.Decode (label ^ " stream JSON decode failed: " ^ message))
    | Ok data -> (
        match (name, event_type data) with
        | "", None ->
            Error (Wire_error.Decode (label ^ " stream event missing type"))
        | "", Some name | name, _ -> Ok { name; data })

  let next ~label stream =
    match Http.Sse.next stream with
    | None -> None
    | Some (Ok { Http.Sse.name; data }) ->
        Some (decode_sse_event ~label name data)
    | Some (Error message) -> Some (Error (Wire_error.Transport message))

  let create_stream ~on_retry t request =
    match Jsont_bytesrw.encode_string Jsont.json (body request) with
    | Error message ->
        Error (Wire_error.Decode ("JSON encode failed: " ^ message))
    | Ok body -> Result.map Http.Sse.make (stream_post t ~on_retry ~body)
end

(* The semantic translation: checked requests to wire shapes, wire events to
   live events and the terminal response. *)

let llm_error ~provider ?(phase = Llm.Error.Startup) ?status ?request_id
    ?redacted_body kind message =
  Llm.Error.make ~kind ~phase ~provider ?status ?request_id ?redacted_body
    message

let invalid_request ~provider message =
  Error (llm_error ~provider Llm.Error.Invalid_request message)

let unsupported ~provider message =
  Error (llm_error ~provider Llm.Error.Unsupported message)

let decode_error ~provider message =
  Error (llm_error ~provider ~phase:Llm.Error.Stream Llm.Error.Decode message)

let stream_error ~provider kind message =
  llm_error ~provider ~phase:Llm.Error.Stream kind message

let cancelled_error ~provider ~label ?(phase = Llm.Error.Startup) () =
  llm_error ~provider ~phase Llm.Error.Cancelled (label ^ " request cancelled")

let timeout_error ~provider ~label ~phase seconds =
  llm_error ~provider ~phase Llm.Error.Timeout
    (Printf.sprintf "%s request timed out after %gs" label seconds)

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message -> invalid_arg ("JSON encode failed: " ^ message)

let json_of_string ~provider ~label text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok json -> Ok json
  | Error message ->
      decode_error ~provider (label ^ " JSON decode failed: " ^ message)

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

let result_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match f value with
        | Error error -> Error error
        | Ok value -> loop (value :: acc) rest)
  in
  loop [] values

let encode_image_source ~provider ~label media_type = function
  | `Base64 data ->
      Ok
        (Jsont.Json.object'
           [
             string_member "type" "base64";
             string_member "media_type" media_type;
             string_member "data" data;
           ])
  | `Uri url ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "url"; string_member "url" url ])
  | `Ref _ ->
      invalid_request ~provider
        ("unresolved content reference reached " ^ label ^ " provider")

let encode_user_content ~provider ~label = function
  | Llm.Content.Text text ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "text"; string_member "text" text ])
  | Llm.Content.Media { source = `Ref _; _ } ->
      invalid_request ~provider
        ("unresolved content reference reached " ^ label ^ " provider")
  | Llm.Content.Media { media_type; source } ->
      if not (String.starts_with ~prefix:"image/" media_type) then
        unsupported ~provider (label ^ " Messages supports image media only")
      else
        Result.map
          (fun source ->
            Jsont.Json.object'
              [ string_member "type" "image"; json_member "source" source ])
          (encode_image_source ~provider ~label media_type source)

(* A reasoning part is replayable to the Messages protocol only when it carries
   the opaque continuity state the API validates: [encrypted] round-trips as a
   [redacted_thinking] block, [signature] as a signed [thinking] block. A signed
   thinking block replays verbatim even when its text is empty (models with
   [display: omitted] return the signature over empty thinking text), so the
   text falls back to [""] rather than blocking the block. A part with neither —
   for example one recorded by another provider — is not replayable and is
   dropped rather than sent as an unsigned thinking block the API would reject. *)
let encode_assistant_part = function
  | Llm.Message.Assistant.Text text ->
      Ok
        [
          Jsont.Json.object'
            [ string_member "type" "text"; string_member "text" text ];
        ]
  | Llm.Message.Assistant.Tool_call call ->
      Ok
        [
          Jsont.Json.object'
            [
              string_member "type" "tool_use";
              string_member "id" (Llm.Tool.Call.id call);
              string_member "name" (Llm.Tool.Call.name call);
              json_member "input" (Llm.Tool.Call.input call);
            ];
        ]
  | Llm.Message.Assistant.Reasoning reasoning -> (
      match Llm.Message.Assistant.Reasoning.encrypted reasoning with
      | Some data ->
          Ok
            [
              Jsont.Json.object'
                [
                  string_member "type" "redacted_thinking";
                  string_member "data" data;
                ];
            ]
      | None -> (
          match Llm.Message.Assistant.Reasoning.signature reasoning with
          | None -> Ok []
          | Some signature ->
              let thinking =
                match Llm.Message.Assistant.Reasoning.text reasoning with
                | Some text -> text
                | None ->
                    Option.value
                      (Llm.Message.Assistant.Reasoning.summary reasoning)
                      ~default:""
              in
              Ok
                [
                  Jsont.Json.object'
                    [
                      string_member "type" "thinking";
                      string_member "thinking" thinking;
                      string_member "signature" signature;
                    ];
                ]))

let encode_tool_result_content_item ~provider ~label = function
  | Llm.Content.Text text ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "text"; string_member "text" text ])
  | Llm.Content.Media { source = `Ref _; _ } ->
      invalid_request ~provider
        ("unresolved content reference reached " ^ label ^ " provider")
  | Llm.Content.Media { media_type; source } ->
      if not (String.starts_with ~prefix:"image/" media_type) then
        unsupported ~provider
          (label ^ " Messages tool-result media supports images only")
      else
        Result.map
          (fun source ->
            Jsont.Json.object'
              [ string_member "type" "image"; json_member "source" source ])
          (encode_image_source ~provider ~label media_type source)

let encode_tool_result_content ~provider ~label result =
  match Llm.Tool.Result.content result with
  | [] -> Ok (Jsont.Json.string "")
  | [ Llm.Content.Text text ] -> Ok (Jsont.Json.string text)
  | content ->
      Result.map
        (fun content -> Jsont.Json.list content)
        (result_map (encode_tool_result_content_item ~provider ~label) content)

let encode_tool_result ~provider ~label result =
  Result.map
    (fun content ->
      let fields =
        [
          string_member "type" "tool_result";
          string_member "tool_use_id" (Llm.Tool.Result.call_id result);
          json_member "content" content;
        ]
      in
      let fields =
        if Llm.Tool.Result.is_error result then
          bool_member "is_error" true :: fields
        else fields
      in
      Jsont.Json.object' fields)
    (encode_tool_result_content ~provider ~label result)

let encode_message ~provider ~label = function
  | Llm.Message.System text | Llm.Message.Developer text ->
      Ok
        (`System
           (Jsont.Json.object'
              [ string_member "type" "text"; string_member "text" text ]))
  | Llm.Message.User content ->
      Result.map
        (fun content ->
          `Message
            (Jsont.Json.object'
               [ string_member "role" "user"; list_member "content" content ]))
        (result_map (encode_user_content ~provider ~label) content)
  | Llm.Message.Assistant assistant ->
      Result.map
        (fun content ->
          `Message
            (Jsont.Json.object'
               [
                 string_member "role" "assistant"; list_member "content" content;
               ]))
        (Result.map List.concat
           (result_map encode_assistant_part
              (Llm.Message.Assistant.parts assistant)))
  | Llm.Message.Tool_result result ->
      Result.map
        (fun result ->
          `Message
            (Jsont.Json.object'
               [ string_member "role" "user"; list_member "content" [ result ] ]))
        (encode_tool_result ~provider ~label result)

let split_messages ~provider ~label messages =
  let rec loop system encoded = function
    | [] -> Ok (List.rev system, List.rev encoded)
    | message :: rest -> (
        match encode_message ~provider ~label message with
        | Error error -> Error error
        | Ok (`System block) -> loop (block :: system) encoded rest
        | Ok (`Message message) -> loop system (message :: encoded) rest)
  in
  loop [] [] messages

let encode_tool tool =
  let fields =
    [
      string_member "name" (Llm.Tool.name tool);
      json_member "input_schema" (Llm.Tool.input_schema tool);
    ]
  in
  let fields =
    match Llm.Tool.description tool with
    | None -> fields
    | Some description -> string_member "description" description :: fields
  in
  Jsont.Json.object' fields

let encode_tool_choice tools = function
  | Llm.Request.Options.Auto ->
      if tools = [] then None
      else Some (Jsont.Json.object' [ string_member "type" "auto" ])
  | Llm.Request.Options.No_tools -> None
  | Llm.Request.Options.Required ->
      Some (Jsont.Json.object' [ string_member "type" "any" ])
  | Llm.Request.Options.Tool name ->
      Some
        (Jsont.Json.object'
           [ string_member "type" "tool"; string_member "name" name ])

(* The effort ceiling for adaptive thinking. The ladder has no separate minimal
   rung, so [Minimal] folds into [low]. [Disabled] never reaches here —
   {!encode_thinking} switches thinking off before any effort is read — and maps
   to the lowest rung only to keep this total. *)
let encode_effort = function
  | Llm.Request.Options.Reasoning_effort.Disabled
  | Llm.Request.Options.Reasoning_effort.Minimal
  | Llm.Request.Options.Reasoning_effort.Low ->
      "low"
  | Llm.Request.Options.Reasoning_effort.Medium -> "medium"
  | Llm.Request.Options.Reasoning_effort.High -> "high"
  | Llm.Request.Options.Reasoning_effort.Extra_high -> "xhigh"
  | Llm.Request.Options.Reasoning_effort.Max -> "max"

(* Thinking is adaptive: the model paces its own reasoning within a ceiling set
   by [output_config.effort], a sibling of [thinking] rather than a member of
   it. The manual [{type: enabled, budget_tokens}] shape is rejected outright by
   every current model of this dialect, so no request builds a token budget.

   [display: summarized] is deliberate. These models default to [omitted],
   which streams signed but textless thinking blocks; mentat renders reasoning
   summaries in its transcript, so it asks for text it can show. The replay path
   still tolerates empty thinking text, so a signed block remains replayable
   either way. *)
let encode_thinking options =
  match Llm.Request.Options.reasoning_effort options with
  | None -> (None, None)
  | Some Llm.Request.Options.Reasoning_effort.Disabled ->
      (Some (Jsont.Json.object' [ string_member "type" "disabled" ]), None)
  | Some effort ->
      ( Some
          (Jsont.Json.object'
             [
               string_member "type" "adaptive";
               string_member "display" "summarized";
             ]),
        Some
          (Jsont.Json.object' [ string_member "effort" (encode_effort effort) ])
      )

(* Without the [sampling] ruling, sampling parameters travel only alongside an
   explicitly disabled thinking: models that run adaptive thinking whether
   [thinking] is absent or [adaptive] reject them in every other state. A
   consumer whose models sample normally passes [sampling:true] and the
   request's temperature goes through unconditionally. *)
let sampling_supported ~sampling options =
  sampling
  ||
  match Llm.Request.Options.reasoning_effort options with
  | Some Llm.Request.Options.Reasoning_effort.Disabled -> true
  | Some _ | None -> false

let encode_response_format ~provider ~label = function
  | Llm.Request.Options.Text -> Ok ()
  | Llm.Request.Options.Json_schema _ ->
      unsupported ~provider (label ^ " Messages does not support response_format")

(* Prompt caching: explicit ephemeral breakpoints, three of the protocol's four
   allowed markers, at the conventional breakpoints. The last tool caches the
   tool array, the last system block caches the tools+system prefix, and a
   marker that slides with the final message caches the whole conversation so
   far, so the next request's longer prefix reads it back. TTL is the provider
   default (5 minutes). Thinking blocks cannot carry markers; a request never
   ends on one, so the slide marker is skipped rather than relocated when it
   would land there. *)
let cache_control_member =
  json_member "cache_control"
    (Jsont.Json.object' [ string_member "type" "ephemeral" ])

let cacheable_block json =
  match string_field "type" json with
  | Some ("thinking" | "redacted_thinking") -> false
  | Some _ | None -> true

let with_cache_control json =
  match json with
  | Jsont.Object (members, meta) when cacheable_block json ->
      Jsont.Object (members @ [ cache_control_member ], meta)
  | Jsont.Object _ | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _
  | Jsont.String _ | Jsont.Array _ ->
      json

let mark_last mark items =
  match List.rev items with
  | [] -> []
  | last :: rest -> List.rev (mark last :: rest)

let mark_last_content_block message =
  match message with
  | Jsont.Object (members, meta) ->
      let members =
        List.map
          (fun (name, value) ->
            match (fst name, value) with
            | "content", Jsont.Array (blocks, blocks_meta) ->
                ( name,
                  Jsont.Array (mark_last with_cache_control blocks, blocks_meta)
                )
            | _ -> (name, value))
          members
      in
      Jsont.Object (members, meta)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      message

let encode_request ~provider ~label ~cache ~sampling request =
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    unsupported ~provider
      (label ^ " provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let options = Llm.Request.options request in
    let max_tokens =
      Option.value (Llm.Request.Options.max_output_tokens options) ~default:4096
    in
    match
      encode_response_format ~provider ~label
        (Llm.Request.Options.response_format options)
    with
    | Error error -> Error error
    | Ok () -> (
        match
          split_messages ~provider ~label (Llm.Request.messages request)
        with
        | Error error -> Error error
        | Ok (system, messages) ->
            let thinking, output_config = encode_thinking options in
            let tools =
              match Llm.Request.Options.tool_choice options with
              | Llm.Request.Options.No_tools -> []
              | Llm.Request.Options.Auto | Llm.Request.Options.Required
              | Llm.Request.Options.Tool _ ->
                  List.map encode_tool (Llm.Request.tools request)
            in
            let tools, system, messages =
              if cache then
                ( mark_last with_cache_control tools,
                  mark_last with_cache_control system,
                  mark_last mark_last_content_block messages )
              else (tools, system, messages)
            in
            Ok
              {
                Wire.model = Llm.Model.id model;
                system;
                messages;
                tools;
                tool_choice =
                  encode_tool_choice tools
                    (Llm.Request.Options.tool_choice options);
                thinking;
                output_config;
                max_tokens;
                temperature =
                  (if sampling_supported ~sampling options then
                     Llm.Request.Options.temperature options
                   else None);
                stream = true;
              })

let check_request ~provider request =
  Result.map
    (fun (_ : Wire.request) -> ())
    (encode_request ~provider ~label:(label_of provider) ~cache:false
       ~sampling:false request)

let usage_of_json json =
  let input = Option.value (int_field "input_tokens" json) ~default:0 in
  let output = Option.value (int_field "output_tokens" json) ~default:0 in
  let cache_read =
    Option.value (int_field "cache_read_input_tokens" json) ~default:0
  in
  let cache_write =
    Option.value (int_field "cache_creation_input_tokens" json) ~default:0
  in
  Llm.Usage.make ~input ~output ~cache_read ~cache_write ()

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

let parse_tool_input ~provider ~label raw =
  match json_of_string ~provider ~label raw with
  | Ok json -> Ok json
  | Error error ->
      Error
        (llm_error ~provider ~phase:(Llm.Error.phase error) Llm.Error.Decode
           (label ^ " tool_use input is not valid JSON: "
          ^ Llm.Error.message error))

let stop_reason = function
  | Some "end_turn" | Some "stop_sequence" -> Some Llm.Response.Stop.end_turn
  | Some "pause_turn" -> Some (Llm.Response.Stop.other "pause_turn")
  | Some "max_tokens" -> Some Llm.Response.Stop.length
  | Some "tool_use" -> Some Llm.Response.Stop.tool_call
  | Some "refusal" -> Some Llm.Response.Stop.refusal
  | Some reason ->
      Some
        (Option.value
           (Llm.Response.Stop.of_label reason)
           ~default:(Llm.Response.Stop.other "provider_stop"))
  | None -> None

let error_kind_of_status = function
  | 400 -> Llm.Error.Invalid_request
  | 401 | 403 -> Llm.Error.Auth
  | 402 -> Llm.Error.Quota
  | 408 -> Llm.Error.Timeout
  | 409 -> Llm.Error.Transport
  | 413 -> Llm.Error.Context_overflow
  | 429 -> Llm.Error.Rate_limited
  | status when status >= 500 -> Llm.Error.Provider
  | _ -> Llm.Error.Provider

let header_value headers name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    headers

let request_id headers =
  match header_value headers "request-id" with
  | Some _ as value -> value
  | None -> header_value headers "x-request-id"

let redacted_body ~label body =
  if String.is_empty body then None
  else
    Some
      ("<redacted " ^ label ^ " error body: "
      ^ string_of_int (String.length body)
      ^ " bytes>")

let api_error ~provider ~label ?classify ?(phase = Llm.Error.Startup) =
  function
  | Wire_error.Transport message ->
      llm_error ~provider ~phase Llm.Error.Transport message
  | Wire_error.Decode message ->
      llm_error ~provider ~phase Llm.Error.Decode message
  | Wire_error.Response response ->
      let classified =
        Option.bind classify (fun classify ->
            classify ~status:response.Http.status ~body:response.Http.body)
      in
      let kind =
        match classified with
        | Some kind -> kind
        | None -> error_kind_of_status response.Http.status
      in
      let request_id = request_id response.Http.headers in
      let message =
        match Jsont_bytesrw.decode_string Jsont.json response.Http.body with
        | Ok json -> (
            match object_field "error" json with
            | Some error_json ->
                let type_ = string_field "type" error_json in
                let message = string_field "message" error_json in
                begin match (type_, message) with
                | Some type_, Some message -> type_ ^ ": " ^ message
                | Some type_, None -> type_
                | None, Some message -> message
                | None, None -> label ^ " request failed"
                end
            | None ->
                Option.value
                  (string_field "message" json)
                  ~default:(label ^ " request failed"))
        | Error _ ->
            if String.is_empty response.Http.body then label ^ " request failed"
            else label ^ " request failed with non-JSON error body"
      in
      let redacted_body = redacted_body ~label response.Http.body in
      llm_error ~provider ~phase ~status:response.Http.status ?request_id
        ?redacted_body kind message

let error_kind_of_type = function
  | Some "authentication_error" | Some "permission_error" -> Llm.Error.Auth
  | Some "rate_limit_error" | Some "overloaded_error" -> Llm.Error.Rate_limited
  | Some "invalid_request_error" -> Llm.Error.Invalid_request
  | Some _ | None -> Llm.Error.Provider

type partial = {
  id : string;
  name : string;
  mutable start_input : string option;
  mutable raw_input : string;
  mutable emitted_tool : bool;
}

let partial ~id ~name =
  { id; name; start_input = None; raw_input = ""; emitted_tool = false }

let partial_at table index ~id ~name =
  match Hashtbl.find_opt table index with
  | Some partial -> partial
  | None ->
      let partial = partial ~id ~name in
      Hashtbl.add table index partial;
      partial

type reasoning_block = {
  mutable text : string;
  mutable encrypted : string option;
  mutable signature : string option;
}

let reasoning_block () = { text = ""; encrypted = None; signature = None }

let reasoning_at table index =
  match Hashtbl.find_opt table index with
  | Some reasoning -> reasoning
  | None ->
      let reasoning = reasoning_block () in
      Hashtbl.add table index reasoning;
      reasoning

let tool_call_of_partial ~provider ~label partial =
  let raw_input =
    if String.is_empty partial.raw_input then
      Option.value partial.start_input ~default:"{}"
    else partial.raw_input
  in
  match parse_tool_input ~provider ~label raw_input with
  | Error error -> Error error
  | Ok input -> (
      match Llm.Tool.Call.make ~id:partial.id ~name:partial.name ~input () with
      | call -> Ok call
      | exception Invalid_argument message ->
          decode_error ~provider (label ^ " tool_use is malformed: " ^ message))

let consume_events ~provider ~label ?classify ~cancelled ~elapsed ~on_event
    requested_model api_stream =
  let partials = Hashtbl.create 8 in
  let reasonings = Hashtbl.create 8 in
  let started_blocks = Hashtbl.create 8 in
  let stopped_blocks = Hashtbl.create 8 in
  let parts = ref [] in
  let part_order = ref 0 in
  let usage = ref None in
  let stop = ref None in
  let provider_stop = ref None in
  let response_id = ref None in
  let response_model = ref None in
  let reasoning_summary = Buffer.create 128 in
  let result = ref None in
  let emit event = on_event event in
  let fail error = result := Some (Error error) in
  let stream_error kind message = stream_error ~provider kind message in
  let add_part index part =
    let order = !part_order in
    incr part_order;
    parts := (index, order, part) :: !parts
  in
  let add_text index text =
    if not (String.is_empty text) then (
      add_part index (Llm.Message.Assistant.text_part text);
      emit (Llm.Event.text_delta text))
  in
  let add_reasoning index text =
    if not (String.is_empty text) then (
      let reasoning = reasoning_at reasonings index in
      reasoning.text <- reasoning.text ^ text;
      Buffer.add_string reasoning_summary text;
      emit (Llm.Event.reasoning_summary_delta text))
  in
  let add_signature index signature =
    if not (String.is_empty signature) then
      (reasoning_at reasonings index).signature <- Some signature
  in
  let add_redacted_reasoning index data =
    if not (String.is_empty data) then
      (reasoning_at reasonings index).encrypted <- Some data
  in
  let emit_tool_call index partial =
    if not partial.emitted_tool then
      match tool_call_of_partial ~provider ~label partial with
      | Error error -> fail error
      | Ok call ->
          partial.emitted_tool <- true;
          add_part index (Llm.Message.Assistant.tool_call call);
          emit (Llm.Event.tool_call call)
  in
  let field_string_or name ~default json =
    Option.value (string_field name json) ~default
  in
  let block_index json = Option.value (int_field "index" json) ~default:0 in
  let index_key index = string_of_int index in
  let reject_stopped index event =
    if Hashtbl.mem stopped_blocks index then (
      fail
        (stream_error Llm.Error.Decode
           (label ^ " " ^ event ^ " after content_block_stop"));
      true)
    else false
  in
  let reject_unstarted index event =
    if Hashtbl.mem started_blocks index then false
    else (
      fail
        (stream_error Llm.Error.Decode
           (label ^ " " ^ event ^ " without content_block_start"));
      true)
  in
  let update_usage usage_json =
    let update = Option.map usage_of_json usage_json in
    usage := merge_usage !usage update;
    Option.iter (fun usage -> emit (Llm.Event.usage usage)) !usage
  in
  let finish_response () =
    let reasoning_parts =
      Hashtbl.fold
        (fun index reasoning acc ->
          let text =
            if String.is_empty reasoning.text then None else Some reasoning.text
          in
          match (text, reasoning.encrypted, reasoning.signature) with
          | None, None, None -> acc
          | _ -> (
              match
                Llm.Message.Assistant.Reasoning.make ?text
                  ?encrypted:reasoning.encrypted ?signature:reasoning.signature
                  ()
              with
              | value ->
                  (index, -1, Llm.Message.Assistant.reasoning_part value) :: acc
              | exception Invalid_argument _ -> acc))
        reasonings []
    in
    let parts =
      !parts @ reasoning_parts
      |> List.sort
           (fun (left_index, left_order, _) (right_index, right_order, _) ->
             match Int.compare left_index right_index with
             | 0 -> Int.compare left_order right_order
             | order -> order)
      |> List.map (fun (_index, _order, part) -> part)
    in
    match parts with
    | [] ->
        decode_error ~provider (label ^ " response produced no assistant parts")
    | parts ->
        let assistant = Llm.Message.Assistant.make parts in
        let reasoning_summary =
          if Buffer.length reasoning_summary = 0 then []
          else [ Buffer.contents reasoning_summary ]
        in
        Ok
          (Llm.Response.make ~model:requested_model
             ?response_model:!response_model ?response_id:!response_id
             ?provider_stop:!provider_stop ?stop:!stop ?usage:!usage
             ~reasoning_summary assistant)
  in
  let handle event =
    if Option.is_none !result then
      match event with
      | Error error ->
          fail (api_error ~provider ~label ?classify ~phase:Llm.Error.Stream error)
      | Ok ({ Wire.name; data = json } : Wire.event) -> (
          match name with
          | "message_start" ->
              begin match object_field "message" json with
              | None -> ()
              | Some message ->
                  response_id := string_field "id" message;
                  response_model := string_field "model" message
              end;
              update_usage
                (Option.bind
                   (object_field "message" json)
                   (object_field "usage"))
          | "content_block_start" -> (
              let index = block_index json in
              if reject_stopped index "content_block_start" then ()
              else if Hashtbl.mem started_blocks index then
                fail
                  (stream_error Llm.Error.Decode
                     (label ^ " duplicate content_block_start"))
              else
                let () = Hashtbl.add started_blocks index () in
                match object_field "content_block" json with
                | None -> ()
                | Some block -> (
                    match string_field "type" block with
                    | Some "text" ->
                        Option.iter (add_text index) (string_field "text" block)
                    | Some "thinking" ->
                        Option.iter (add_reasoning index)
                          (string_field "thinking" block)
                    | Some "redacted_thinking" ->
                        Option.iter
                          (add_redacted_reasoning index)
                          (string_field "data" block)
                    | Some "tool_use" ->
                        begin match
                          (string_field "id" block, string_field "name" block)
                        with
                        | Some id, Some name ->
                            let partial = partial_at partials index ~id ~name in
                            Option.iter
                              (fun input ->
                                partial.start_input <- Some (json_string input))
                              (object_field "input" block)
                        | None, _ ->
                            fail
                              (stream_error Llm.Error.Decode
                                 (label ^ " tool_use block is missing id"))
                        | _, None ->
                            fail
                              (stream_error Llm.Error.Decode
                                 (label ^ " tool_use block is missing name"))
                        end
                    | Some _ | None -> ()))
          | "content_block_delta" -> (
              let index = block_index json in
              if reject_stopped index "content_block_delta" then ()
              else if reject_unstarted index "content_block_delta" then ()
              else
                match object_field "delta" json with
                | None -> ()
                | Some delta -> (
                    match string_field "type" delta with
                    | Some "text_delta" ->
                        Option.iter (add_text index) (string_field "text" delta)
                    | Some "thinking_delta" ->
                        Option.iter (add_reasoning index)
                          (string_field "thinking" delta)
                    | Some "input_json_delta" ->
                        let key = index_key index in
                        begin match Hashtbl.find_opt partials index with
                        | None ->
                            fail
                              (stream_error Llm.Error.Decode
                                 (label
                                ^ " input_json_delta without \
                                   content_block_start"))
                        | Some partial ->
                            let delta =
                              field_string_or "partial_json" ~default:"" delta
                            in
                            partial.raw_input <- partial.raw_input ^ delta;
                            if not (String.is_empty delta) then
                              emit
                                (Llm.Event.tool_input_delta
                                   (Llm.Event.Tool_input.make ~key
                                      ~call_id:partial.id ~name:partial.name
                                      ~input_delta:delta ()))
                        end
                    | Some "signature_delta" ->
                        Option.iter (add_signature index)
                          (string_field "signature" delta)
                    | Some _ | None -> ()))
          | "content_block_stop" ->
              let index = block_index json in
              if Hashtbl.mem stopped_blocks index then
                fail
                  (stream_error Llm.Error.Decode
                     (label ^ " duplicate content_block_stop"))
              else if reject_unstarted index "content_block_stop" then ()
              else (
                Hashtbl.add stopped_blocks index ();
                Option.iter (emit_tool_call index)
                  (Hashtbl.find_opt partials index))
          | "message_delta" ->
              update_usage (object_field "usage" json);
              begin match object_field "delta" json with
              | None -> ()
              | Some delta ->
                  provider_stop := string_field "stop_reason" delta;
                  stop := stop_reason !provider_stop
              end
          | "message_stop" ->
              begin match finish_response () with
              | Error error -> fail error
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
                        usage.Llm.Usage.input usage.Llm.Usage.output
                        (elapsed ()));
                  result := Some (Ok response)
              end
          | "error" ->
              let message =
                match object_field "error" json with
                | Some error_json -> (
                    match
                      ( string_field "type" error_json,
                        string_field "message" error_json )
                    with
                    | Some type_, Some message -> type_ ^ ": " ^ message
                    | Some type_, None -> type_
                    | None, Some message -> message
                    | None, None -> label ^ " stream error")
                | None ->
                    Option.value
                      (string_field "message" json)
                      ~default:(label ^ " stream error")
              in
              let kind =
                error_kind_of_type
                  (Option.bind
                     (object_field "error" json)
                     (string_field "type"))
              in
              fail (stream_error kind message)
          | "ping" -> ()
          | _ -> ())
  in
  let rec consume () =
    match !result with
    | Some result -> result
    | None when cancelled () ->
        Log.debug (fun m ->
            m "request cancelled model=%s" (Llm.Model.id requested_model));
        Error (cancelled_error ~provider ~label ~phase:Llm.Error.Stream ())
    | None -> (
        match Wire.next ~label api_stream with
        | Some event ->
            handle event;
            consume ()
        | None ->
            Log.debug (fun m ->
                m "stream ended without message_stop model=%s"
                  (Llm.Model.id requested_model));
            Error
              (stream_error Llm.Error.Malformed_stream
                 (label ^ " stream ended without message_stop")))
  in
  Fun.protect ~finally:(fun () -> Http.Sse.close api_stream) consume

let perform_request t ~phase ~cancelled ~on_event request =
  let provider = t.provider and label = t.label in
  if cancelled () then Error (cancelled_error ~provider ~label ())
  else
    let model = Llm.Request.model request in
    match
      encode_request ~provider ~label ~cache:t.cache ~sampling:t.sampling
        request
    with
    | Error error -> Error error
    | Ok api_request ->
        Log.info (fun m -> m "request started model=%s" (Llm.Model.id model));
        let clock = t.env#clock in
        let started = Eio.Time.now clock in
        let elapsed () = (Eio.Time.now clock -. started) *. 1000. in
        (* The stream budget is deeper than the pre-stream one, but
           [max_retries = Some 0] is the caller's blanket "no retries" and
           silences the stream re-run too. *)
        let max_retries =
          match t.max_retries with
          | Some 0 -> 0
          | Some _ | None ->
              Option.value t.max_stream_retries
                ~default:default_stream_max_retries
        in
        Retry.stream ~clock ~cancelled ~max_retries ~on_event
          ~open_stream:(fun ~on_retry ->
            match Wire.create_stream ~on_retry t api_request with
            | Error error ->
                Error (api_error ~provider ~label ?classify:t.classify error)
            | Ok api_stream ->
                phase := Llm.Error.Stream;
                Ok api_stream)
          ~consume:(fun ~on_event api_stream ->
            consume_events ~provider ~label ?classify:t.classify ~cancelled
              ~elapsed ~on_event model api_stream)

let run t ~cancelled ~on_event request =
  let phase = ref Llm.Error.Startup in
  let perform () = perform_request t ~phase ~cancelled ~on_event request in
  match t.timeout_s with
  | None -> perform ()
  | Some timeout_s -> (
      match
        Eio.Time.with_timeout t.env#clock timeout_s (fun () -> Ok (perform ()))
      with
      | Ok result -> result
      | Error `Timeout ->
          Error
            (timeout_error ~provider:t.provider ~label:t.label ~phase:!phase
               timeout_s))
