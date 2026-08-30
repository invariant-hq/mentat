(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "mentat.llm.chat-completions"
    ~doc:"OpenAI-compatible Chat Completions protocol"

module Log = (val Logs.src_log log_src : Logs.LOG)
module Llm = Mentat_llm
module Http = Transport
module Options = Llm.Request.Options

let ( let* ) = Result.bind
let api = Llm.Model.Api.make "chat-completions"

module Error = struct
  type response = { status : int; body : string }
  type t = Response of response | Transport of string | Decode of string
end

let default_max_retries = 2
let default_stream_max_retries = 5

type t = {
  provider : Llm.Provider.t;
  base_url : string;
  headers : (string * string) list;
  timeout_s : float option;
  max_retries : int;
  max_stream_retries : int;
  terminal : (Http.response -> bool) option;
  classify : (status:int -> body:string -> Llm.Error.kind option) option;
  sw : Eio.Switch.t;
  env : Eio_unix.Stdenv.base;
}

let make ~provider ?(headers = []) ?timeout_s
    ?(max_retries = default_max_retries) ?max_stream_retries ?terminal
    ?classify ~base_url ~sw ~env () =
  (* [max_retries = 0] is the caller's blanket "no retries" and silences the
     stream re-run too, the way the Responses and Messages transports read it. *)
  let max_stream_retries =
    match (max_retries, max_stream_retries) with
    | 0, _ -> 0
    | _, Some retries -> retries
    | _, None -> default_stream_max_retries
  in
  {
    provider;
    base_url;
    headers;
    timeout_s;
    max_retries;
    max_stream_retries;
    terminal;
    classify;
    sw;
    env;
  }

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let int_member name value = json_member name (Jsont.Json.int value)
let number_member name value = json_member name (Jsont.Json.number value)
let list_member name value = json_member name (Jsont.Json.list value)

module Chat = struct
  type request = {
    model : string;
    messages : Jsont.json list;
    tools : Jsont.json list;
    tool_choice : Jsont.json option;
    response_format : Jsont.json option;
    reasoning_effort : string option;
    max_tokens : int option;
    temperature : float option;
  }

  type event = Chunk of Jsont.json | Done

  let add_opt member name value fields =
    match value with
    | None -> fields
    | Some value -> member name value :: fields

  let body request =
    let fields =
      [
        string_member "model" request.model;
        list_member "messages" request.messages;
        bool_member "stream" true;
        json_member "stream_options"
          (Jsont.Json.object' [ bool_member "include_usage" true ]);
      ]
    in
    let fields =
      match request.tools with
      | [] -> fields
      | tools -> list_member "tools" tools :: fields
    in
    let fields = add_opt json_member "tool_choice" request.tool_choice fields in
    let fields =
      add_opt json_member "response_format" request.response_format fields
    in
    let fields =
      add_opt string_member "reasoning_effort" request.reasoning_effort fields
    in
    let fields = add_opt int_member "max_tokens" request.max_tokens fields in
    let fields =
      add_opt number_member "temperature" request.temperature fields
    in
    Jsont.Json.object' (List.rev fields)

  let decode_sse_event (event : Http.Sse.event) =
    match event.Http.Sse.data with
    | "[DONE]" -> Ok Done
    | raw -> (
        match Jsont_bytesrw.decode_string Jsont.json raw with
        | Error message ->
            Error (Error.Decode ("chat stream JSON decode failed: " ^ message))
        | Ok json -> Ok (Chunk json))

  let next stream =
    match Http.Sse.next stream with
    | None -> None
    | Some (Ok event) -> Some (decode_sse_event event)
    | Some (Error message) -> Some (Error (Error.Transport message))

  let create_stream ~on_retry client request =
    match Jsont_bytesrw.encode_string Jsont.json (body request) with
    | Error message -> Error (Error.Decode ("JSON encode failed: " ^ message))
    | Ok body -> (
        let headers attempt =
          client.headers
          @ [
              ("content-type", "application/json");
              ("accept", "text/event-stream");
              ("x-stainless-retry-count", string_of_int attempt);
            ]
        in
        match
          Retry.pre_stream ~clock:client.env#clock
            ~max_retries:client.max_retries ?terminal:client.terminal ~on_retry
            (fun ~attempt ->
              Http.post_stream ~sw:client.sw ~env:client.env
                ~url:(client.base_url ^ "/v1/chat/completions")
                ~headers:(headers attempt) ~body)
        with
        | Ok flow -> Ok (Http.Sse.make flow)
        | Error http_error ->
            let error =
              match http_error with
              | Http.Response response ->
                  Error.Response
                    {
                      Error.status = response.Http.status;
                      body = response.Http.body;
                    }
              | Http.Transport message | Http.Unresolved_host message ->
                  Error.Transport message
            in
            (match error with
            | Error.Response { Error.status; _ } ->
                Log.debug (fun m -> m "chat request failed status=%d" status)
            | Error.Transport message ->
                Log.debug (fun m ->
                    m "chat request transport error: %s" message)
            | Error.Decode message ->
                Log.debug (fun m -> m "chat request decode error: %s" message));
            Error error)
end

let provider_id t = Llm.Provider.id t.provider

let llm_error t ?(phase = Llm.Error.Startup) ?status kind message =
  Llm.Error.make ~kind ~phase ~provider:t.provider ?status message

let unsupported t message = Error (llm_error t Llm.Error.Unsupported message)

let invalid_request t message =
  Error (llm_error t Llm.Error.Invalid_request message)

let stream_error t kind message =
  llm_error t ~phase:Llm.Error.Stream kind message

let cancelled_error t ?(phase = Llm.Error.Startup) () =
  llm_error t ~phase Llm.Error.Cancelled (provider_id t ^ " request cancelled")

let timeout_error t ~phase seconds =
  llm_error t ~phase Llm.Error.Timeout
    (Printf.sprintf "%s request timed out after %gs" (provider_id t) seconds)

(* Chat Completions carries image media in a user message's multimodal content
   array, but has no tool-result media slot: [~allow_image] is [true] for user
   content and [false] for tool results. A [`Ref] never encodes (resolution
   happens above [mentat.llm]); a non-image media block is unsupported. *)
let media_encodable ~allow_image = function
  | Llm.Content.Media { media_type; source = `Uri _ | `Base64 _ } ->
      allow_image && String.starts_with ~prefix:"image/" media_type
  | Llm.Content.Media { source = `Ref _; _ } | Llm.Content.Text _ -> true

let check_request ~provider request =
  let error kind message = Error (Llm.Error.make ~kind ~provider message) in
  let provider_id = Llm.Provider.id provider in
  let check_content ~allow_image what content =
    if
      List.exists
        (function
          | Llm.Content.Media { source = `Ref _; _ } -> true
          | Llm.Content.Text _ | Llm.Content.Media _ -> false)
        content
    then
      error Llm.Error.Invalid_request
        ("unresolved content reference reached " ^ provider_id ^ " provider")
    else if not (List.for_all (media_encodable ~allow_image) content) then
      error Llm.Error.Unsupported
        (provider_id ^ " models support text "
        ^ (if allow_image then "and image " else "")
        ^ what ^ " only")
    else Ok ()
  in
  let check_message = function
    | Llm.Message.User content ->
        check_content ~allow_image:true "user content" content
    | Llm.Message.Tool_result result ->
        check_content ~allow_image:false "tool results"
          (Llm.Tool.Result.content result)
    | Llm.Message.System _ | Llm.Message.Developer _ | Llm.Message.Assistant _
      ->
        Ok ()
  in
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    error Llm.Error.Unsupported
      (provider_id ^ " provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let* () =
      List.fold_left
        (fun result message ->
          let* () = result in
          check_message message)
        (Ok ())
        (Llm.Request.messages request)
    in
    match Options.reasoning_effort (Llm.Request.options request) with
    | None
    | Some
        ( Options.Reasoning_effort.Disabled | Options.Reasoning_effort.Low
        | Options.Reasoning_effort.Medium | Options.Reasoning_effort.High ) ->
        Ok ()
    | Some
        ( Options.Reasoning_effort.Minimal | Options.Reasoning_effort.Extra_high
        | Options.Reasoning_effort.Max ) ->
        error Llm.Error.Unsupported
          (provider_id ^ " models support reasoning effort low, medium, or high")

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message ->
      invalid_arg
        ("Mentat_llm_http.Chat_completions: JSON encode failed: " ^ message)

let json_of_string text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok _ as ok -> ok
  | Error message -> Error message

let text_of_content t ~what blocks =
  let rec loop acc = function
    | [] -> Ok (String.concat "\n" (List.rev acc))
    | Llm.Content.Text text :: rest -> loop (text :: acc) rest
    | Llm.Content.Media { source = `Ref _; _ } :: _ ->
        invalid_request t
          ("unresolved content reference reached " ^ provider_id t ^ " provider")
    | Llm.Content.Media _ :: _ ->
        unsupported t (provider_id t ^ " models support text " ^ what ^ " only")
  in
  loop [] blocks

let result_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match f value with
        | Ok mapped -> loop (mapped :: acc) rest
        | Error _ as error -> error)
  in
  loop [] values

let role_message role content =
  Jsont.Json.object'
    [ string_member "role" role; string_member "content" content ]

(* A single user-content block as a Chat Completions multimodal part: text as
   [{type:"text",…}], an image as [{type:"image_url", image_url:{url:…}}] with a
   [data:] URL for inline base64. Mirrors the Responses adapter's image part. *)
let encode_user_part t = function
  | Llm.Content.Text text ->
      Ok
        (Jsont.Json.object'
           [ string_member "type" "text"; string_member "text" text ])
  | Llm.Content.Media { media_type; source } -> (
      match source with
      | `Ref _ ->
          invalid_request t
            ("unresolved content reference reached " ^ provider_id t
           ^ " provider")
      | (`Uri _ | `Base64 _) as source ->
          if not (String.starts_with ~prefix:"image/" media_type) then
            unsupported t
              (provider_id t
             ^ " models support text and image user content only")
          else
            let url =
              match source with
              | `Uri uri -> uri
              | `Base64 data -> "data:" ^ media_type ^ ";base64," ^ data
            in
            Ok
              (Jsont.Json.object'
                 [
                   string_member "type" "image_url";
                   json_member "image_url"
                     (Jsont.Json.object' [ string_member "url" url ]);
                 ]))

(* Reasoning replays as [reasoning_content] beside the assistant content —
   the field interleaved-thinking chat models emit and read back; a part with
   neither text nor summary has nothing this dialect can carry. *)
let encode_assistant assistant =
  let texts, reasonings, calls =
    List.fold_left
      (fun (texts, reasonings, calls) part ->
        match part with
        | Llm.Message.Assistant.Text text -> (text :: texts, reasonings, calls)
        | Llm.Message.Assistant.Tool_call call ->
            (texts, reasonings, call :: calls)
        | Llm.Message.Assistant.Reasoning reasoning -> (
            match
              match Llm.Message.Assistant.Reasoning.text reasoning with
              | Some _ as text -> text
              | None -> Llm.Message.Assistant.Reasoning.summary reasoning
            with
            | Some text when not (String.is_empty text) ->
                (texts, text :: reasonings, calls)
            | Some _ | None -> (texts, reasonings, calls)))
      ([], [], [])
      (Llm.Message.Assistant.parts assistant)
  in
  let texts = List.rev texts
  and reasonings = List.rev reasonings
  and calls = List.rev calls in
  if List.is_empty texts && List.is_empty reasonings && List.is_empty calls
  then []
  else
    let encode_call call =
      Jsont.Json.object'
        [
          string_member "id" (Llm.Tool.Call.id call);
          string_member "type" "function";
          json_member "function"
            (Jsont.Json.object'
               [
                 string_member "name" (Llm.Tool.Call.name call);
                 string_member "arguments"
                   (json_string (Llm.Tool.Call.input call));
               ]);
        ]
    in
    let fields = [ string_member "role" "assistant" ] in
    let fields =
      match texts with
      | [] -> fields
      | texts -> string_member "content" (String.concat "\n" texts) :: fields
    in
    let fields =
      match reasonings with
      | [] -> fields
      | reasonings ->
          string_member "reasoning_content" (String.concat "\n" reasonings)
          :: fields
    in
    let fields =
      match calls with
      | [] -> fields
      | calls -> list_member "tool_calls" (List.map encode_call calls) :: fields
    in
    [ Jsont.Json.object' (List.rev fields) ]

let encode_message t = function
  | Llm.Message.System text | Llm.Message.Developer text ->
      Ok [ role_message "system" text ]
  | Llm.Message.User content ->
      if
        List.exists
          (function Llm.Content.Media _ -> true | Llm.Content.Text _ -> false)
          content
      then
        let* parts = result_map (encode_user_part t) content in
        Ok
          [
            Jsont.Json.object'
              [ string_member "role" "user"; list_member "content" parts ];
          ]
      else
        let* text = text_of_content t ~what:"user content" content in
        Ok [ role_message "user" text ]
  | Llm.Message.Assistant assistant -> Ok (encode_assistant assistant)
  | Llm.Message.Tool_result result ->
      let* text =
        text_of_content t ~what:"tool results" (Llm.Tool.Result.content result)
      in
      Ok
        [
          Jsont.Json.object'
            [
              string_member "role" "tool";
              string_member "tool_call_id" (Llm.Tool.Result.call_id result);
              string_member "content" text;
            ];
        ]

let encode_tool tool =
  let fields =
    [
      string_member "name" (Llm.Tool.name tool);
      json_member "parameters" (Llm.Tool.input_schema tool);
    ]
  in
  let fields =
    match Llm.Tool.description tool with
    | None -> fields
    | Some description -> string_member "description" description :: fields
  in
  Jsont.Json.object'
    [
      string_member "type" "function";
      json_member "function" (Jsont.Json.object' (List.rev fields));
    ]

let encode_tool_choice = function
  | Options.Auto -> None
  | Options.No_tools -> Some (Jsont.Json.string "none")
  | Options.Required -> Some (Jsont.Json.string "required")
  | Options.Tool name ->
      Some
        (Jsont.Json.object'
           [
             string_member "type" "function";
             json_member "function"
               (Jsont.Json.object' [ string_member "name" name ]);
           ])

let encode_response_format = function
  | Options.Text -> None
  | Options.Json_schema { name; schema; strict } ->
      Some
        (Jsont.Json.object'
           [
             string_member "type" "json_schema";
             json_member "json_schema"
               (Jsont.Json.object'
                  [
                    string_member "name" name;
                    json_member "schema" schema;
                    bool_member "strict" strict;
                  ]);
           ])

let encode_reasoning_effort t = function
  | None | Some Options.Reasoning_effort.Disabled -> Ok None
  | Some Options.Reasoning_effort.Low -> Ok (Some "low")
  | Some Options.Reasoning_effort.Medium -> Ok (Some "medium")
  | Some Options.Reasoning_effort.High -> Ok (Some "high")
  | Some
      ( Options.Reasoning_effort.Minimal | Options.Reasoning_effort.Extra_high
      | Options.Reasoning_effort.Max ) ->
      unsupported t
        (provider_id t ^ " models support reasoning effort low, medium, or high")

let encode_request t request =
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    unsupported t
      (provider_id t ^ " provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let options = Llm.Request.options request in
    let* messages_nested =
      result_map (encode_message t) (Llm.Request.messages request)
    in
    let* reasoning_effort =
      encode_reasoning_effort t (Options.reasoning_effort options)
    in
    Ok
      {
        Chat.model = Llm.Model.id model;
        messages = List.concat messages_nested;
        tools = List.map encode_tool (Llm.Request.tools request);
        tool_choice = encode_tool_choice (Options.tool_choice options);
        response_format =
          encode_response_format (Options.response_format options);
        reasoning_effort;
        max_tokens = Options.max_output_tokens options;
        temperature = Options.temperature options;
      }

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some _ | None -> None

let int_field name json =
  match object_field name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (Float.to_int value)
  | Some _ | None -> None

let list_field name json =
  match object_field name json with
  | Some (Jsont.Array (values, _)) -> Some values
  | Some _ | None -> None

let usage_of_json json =
  let prompt = Option.value (int_field "prompt_tokens" json) ~default:0 in
  let completion =
    Option.value (int_field "completion_tokens" json) ~default:0
  in
  let cache_read =
    match object_field "prompt_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "cached_tokens" details) ~default:0
  in
  let reasoning =
    match object_field "completion_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "reasoning_tokens" details) ~default:0
  in
  let input = max 0 (prompt - cache_read) in
  let output = max 0 (completion - reasoning) in
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ()

let api_error t ?(phase = Llm.Error.Startup) = function
  | Error.Transport message -> llm_error t ~phase Llm.Error.Transport message
  | Error.Decode message -> llm_error t ~phase Llm.Error.Decode message
  | Error.Response response ->
      (* An OpenAI-compatible endpoint is not always a local daemon: the same
         protocol reaches gateways that authenticate and meter, so the statuses
         that carry a distinct meaning are classified rather than flattened into
         a provider failure. [Rate_limited] in particular is what tells the
         stream re-run that a mid-stream capacity fault is worth another
         attempt. Anything else is the provider failing opaquely. *)
      let classified =
        Option.bind t.classify (fun classify ->
            classify ~status:response.Error.status ~body:response.Error.body)
      in
      let kind =
        match classified with
        | Some kind -> kind
        | None -> (
            match response.Error.status with
            | 400 -> Llm.Error.Invalid_request
            | 401 | 403 -> Llm.Error.Auth
            | 402 -> Llm.Error.Quota
            | 408 -> Llm.Error.Timeout
            | 413 -> Llm.Error.Context_overflow
            | 429 -> Llm.Error.Rate_limited
            | _ -> Llm.Error.Provider)
      in
      let default = provider_id t ^ " request failed" in
      let message =
        match Jsont_bytesrw.decode_string Jsont.json response.Error.body with
        | Ok json -> (
            match object_field "error" json with
            | Some error_json -> (
                let message =
                  Option.value (string_field "message" error_json) ~default
                in
                match string_field "type" error_json with
                | Some type_ -> type_ ^ ": " ^ message
                | None -> message)
            | None -> Option.value (string_field "message" json) ~default)
        | Error _ -> default
      in
      llm_error t ~phase ~status:response.Error.status kind message

type partial = {
  mutable call_id : string option;
  mutable name : string option;
  input : Buffer.t;
}

let consume_events t ~cancelled ~on_event requested_model api_stream =
  let partials : (int, partial) Hashtbl.t = Hashtbl.create 4 in
  let call_order = ref [] in
  let content = Buffer.create 256 in
  let reasoning = Buffer.create 256 in
  let finish_reason = ref None in
  let response_model = ref None in
  let response_id = ref None in
  let usage = ref None in
  let partial_at index =
    match Hashtbl.find_opt partials index with
    | Some partial -> partial
    | None ->
        let partial =
          { call_id = None; name = None; input = Buffer.create 64 }
        in
        Hashtbl.add partials index partial;
        call_order := index :: !call_order;
        partial
  in
  let record_ids json =
    (match (!response_model, string_field "model" json) with
    | None, (Some _ as value) -> response_model := value
    | _ -> ());
    match (!response_id, string_field "id" json) with
    | None, (Some _ as value) -> response_id := value
    | _ -> ()
  in
  let handle_tool_call_delta json =
    let index = Option.value (int_field "index" json) ~default:0 in
    let partial = partial_at index in
    (match string_field "id" json with
    | Some id when not (String.is_empty id) -> partial.call_id <- Some id
    | Some _ | None -> ());
    match object_field "function" json with
    | None -> ()
    | Some fn -> (
        (match string_field "name" fn with
        | Some name when not (String.is_empty name) -> partial.name <- Some name
        | Some _ | None -> ());
        match string_field "arguments" fn with
        | Some delta when not (String.is_empty delta) ->
            Buffer.add_string partial.input delta;
            on_event
              (Llm.Event.tool_input_delta
                 (Llm.Event.Tool_input.make ~key:(string_of_int index)
                    ?call_id:partial.call_id ?name:partial.name
                    ~input_delta:delta ()))
        | Some _ | None -> ())
  in
  let handle_delta delta =
    (match string_field "content" delta with
    | Some text when not (String.is_empty text) ->
        Buffer.add_string content text;
        on_event (Llm.Event.text_delta text)
    | Some _ | None -> ());
    (match
       match string_field "reasoning_content" delta with
       | Some _ as value -> value
       | None -> string_field "reasoning" delta
     with
    | Some text when not (String.is_empty text) ->
        Buffer.add_string reasoning text;
        on_event (Llm.Event.reasoning_summary_delta text)
    | Some _ | None -> ());
    match list_field "tool_calls" delta with
    | None -> ()
    | Some calls -> List.iter handle_tool_call_delta calls
  in
  let handle_chunk json =
    record_ids json;
    (match object_field "usage" json with
    | Some (Jsont.Object _ as usage_json) ->
        let value = usage_of_json usage_json in
        usage := Some value;
        on_event (Llm.Event.usage value)
    | Some _ | None -> ());
    match list_field "choices" json with
    | None | Some [] -> ()
    | Some (choice :: _) ->
        (match string_field "finish_reason" choice with
        | Some reason when not (String.is_empty reason) ->
            finish_reason := Some reason
        | Some _ | None -> ());
        Option.iter handle_delta (object_field "delta" choice)
  in
  let finalize_call index =
    let partial = Hashtbl.find partials index in
    match partial.name with
    | None ->
        Error
          (stream_error t Llm.Error.Decode
             (provider_id t ^ " stream tool call is missing a function name"))
    | Some name -> (
        let id =
          Option.value partial.call_id
            ~default:(Printf.sprintf "%s_call_%d" (provider_id t) index)
        in
        let raw_input =
          match Buffer.contents partial.input with "" -> "{}" | raw -> raw
        in
        match json_of_string raw_input with
        | Error message ->
            Error
              (stream_error t Llm.Error.Decode
                 (provider_id t ^ " tool-call arguments are not valid JSON: "
                ^ message))
        | Ok input -> (
            match Llm.Tool.Call.make ~id ~name ~input () with
            | call -> Ok call
            | exception Invalid_argument message ->
                Error
                  (stream_error t Llm.Error.Decode
                     (provider_id t ^ " tool call is malformed: " ^ message))))
  in
  let finalize () =
    let* calls = result_map finalize_call (List.rev !call_order) in
    List.iter (fun call -> on_event (Llm.Event.tool_call call)) calls;
    let parts = [] in
    let parts =
      match Buffer.contents content with
      | "" -> parts
      | text -> Llm.Message.Assistant.text_part text :: parts
    in
    let parts =
      match Buffer.contents reasoning with
      | "" -> parts
      | text ->
          Llm.Message.Assistant.reasoning_part
            (Llm.Message.Assistant.Reasoning.make ~text ())
          :: parts
    in
    let parts =
      List.rev parts @ List.map Llm.Message.Assistant.tool_call calls
    in
    let assistant =
      match parts with
      | [] -> Llm.Message.Assistant.empty
      | parts -> Llm.Message.Assistant.make parts
    in
    let stop =
      match !finish_reason with
      | Some "stop" | None ->
          Some
            (if List.is_empty calls then Llm.Response.Stop.end_turn
             else Llm.Response.Stop.tool_call)
      | Some "tool_calls" -> Some Llm.Response.Stop.tool_call
      | Some "length" -> Some Llm.Response.Stop.length
      | Some "content_filter" -> Some Llm.Response.Stop.content_filter
      | Some other ->
          Some
            (Option.value
               (Llm.Response.Stop.of_label other)
               ~default:(Llm.Response.Stop.other "provider_stop"))
    in
    let response =
      Llm.Response.make ~model:requested_model ?response_model:!response_model
        ?response_id:!response_id ?provider_stop:!finish_reason ?stop
        ?usage:!usage assistant
    in
    Log.info (fun m ->
        let usage = Option.value !usage ~default:Llm.Usage.zero in
        m "request finished provider=%s model=%s stop=%s input=%d output=%d"
          (provider_id t)
          (Llm.Model.id requested_model)
          (Option.value !finish_reason ~default:"none")
          usage.Llm.Usage.input usage.Llm.Usage.output);
    Ok response
  in
  let rec consume () =
    if cancelled () then (
      Log.debug (fun m ->
          m "request cancelled provider=%s model=%s" (provider_id t)
            (Llm.Model.id requested_model));
      Error (cancelled_error t ~phase:Llm.Error.Stream ()))
    else
      match Chat.next api_stream with
      | Some (Ok (Chat.Chunk json)) ->
          handle_chunk json;
          consume ()
      | Some (Ok Chat.Done) -> finalize ()
      | Some (Error error) -> Error (api_error t ~phase:Llm.Error.Stream error)
      | None ->
          if Option.is_some !finish_reason then finalize ()
          else
            Error
              (stream_error t Llm.Error.Malformed_stream
                 (provider_id t ^ " stream ended without completion"))
  in
  Fun.protect ~finally:(fun () -> Http.Sse.close api_stream) consume

let perform_response t ~phase ~cancelled ~on_event request =
  if cancelled () then Error (cancelled_error t ())
  else
    let model = Llm.Request.model request in
    let* () = check_request ~provider:t.provider request in
    let* api_request = encode_request t request in
    Log.info (fun m ->
        m "request started provider=%s model=%s" (provider_id t)
          (Llm.Model.id model));
    Retry.stream ~clock:t.env#clock ~cancelled ~max_retries:t.max_stream_retries
      ~on_event
      ~open_stream:(fun ~on_retry ->
        match Chat.create_stream ~on_retry t api_request with
        | Error error -> Error (api_error t error)
        | Ok api_stream ->
            phase := Llm.Error.Stream;
            Ok api_stream)
      ~consume:(fun ~on_event api_stream ->
        consume_events t ~cancelled ~on_event model api_stream)

let run t ~cancelled ~on_event request =
  let phase = ref Llm.Error.Startup in
  match t.timeout_s with
  | None -> perform_response t ~phase ~cancelled ~on_event request
  | Some timeout_s -> (
      match
        Eio.Time.with_timeout (Eio.Stdenv.clock t.env) timeout_s (fun () ->
            Ok (perform_response t ~phase ~cancelled ~on_event request))
      with
      | Ok result -> result
      | Error `Timeout -> Error (timeout_error t ~phase:!phase timeout_s))
