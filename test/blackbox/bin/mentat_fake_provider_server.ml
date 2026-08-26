(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Json = Jsont.Json

type options = {
  script : string;
  capture : string;
  port_file : string;
  accept_timeout_s : float;
  unordered : bool;
  port : int;
      (* 0 binds an ephemeral port. A fixed port lets a later server pick up
         where an exhausted one left off on the same base URL — the shape a
         daemon-frozen provider environment forces on multi-stage fixtures. *)
}

type request = {
  request_line_text : string;
  headers : (string * string) list;
  body : string;
}

type expectation = {
  request_line : string option;
  body_contains : string list;
  body_not_contains : string list;
}

type reply =
  | Sse of Jsont.json  (** Responses-API completion wrapped as one SSE event. *)
  | Chat of Jsont.json
      (** Chat-Completions completion streamed as OpenAI-compatible chunk SSE —
          the wire shape the ollama provider (and any OpenAI-compat server)
          speaks at [/v1/chat/completions]. *)
  | Http of { status : int; body : Jsont.json }
      (** Plain HTTP reply with a JSON body, for non-streaming endpoints. *)

type script_item = {
  expect : expectation option;
  delay_ms : int option;
  stream_delay_ms : int option;
  delta_delay_ms : int option;
  reply : reply;
}

let fail message =
  prerr_endline ("mentat_fake_provider_server: " ^ message);
  exit 2

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> fail ("JSON encode failed: " ^ message)

let json_of_string path line =
  match Jsont_bytesrw.decode_string Jsont.json line with
  | Ok json -> json
  | Error message -> fail (path ^ ": JSON decode failed: " ^ message)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field object_name name json =
  match object_field name json with
  | None -> None
  | Some (Jsont.String (value, _)) -> Some value
  | Some value ->
      fail
        (Printf.sprintf "%s.%s must be a string, got %s" object_name name
           (json_string value))

let string_list_field object_name name json =
  match object_field name json with
  | None -> []
  | Some (Jsont.Array (items, _)) ->
      List.mapi
        (fun index -> function
          | Jsont.String (value, _) -> value
          | value ->
              fail
                (Printf.sprintf "%s.%s[%d] must be a string, got %s" object_name
                   name index (json_string value)))
        items
  | Some value ->
      fail
        (Printf.sprintf "%s.%s must be an array of strings, got %s" object_name
           name (json_string value))

let expectation_of_json json =
  {
    request_line = string_field "expect" "request_line" json;
    body_contains = string_list_field "expect" "body_contains" json;
    body_not_contains = string_list_field "expect" "body_not_contains" json;
  }

let int_field object_name name json =
  match object_field name json with
  | None -> None
  | Some value -> (
      match Json.decode Jsont.int value with
      | Ok value -> Some value
      | Error _ ->
          fail (Printf.sprintf "%s.%s must be an integer" object_name name))

let script_item_of_json json =
  let expect =
    match object_field "expect" json with
    | None -> None
    | Some expect -> Some (expectation_of_json expect)
  in
  let delay_ms = int_field "script item" "delay_ms" json in
  let stream_delay_ms = int_field "script item" "stream_delay_ms" json in
  let delta_delay_ms = int_field "script item" "delta_delay_ms" json in
  match object_field "http" json with
  | Some http ->
      let status = Option.value (int_field "http" "status" http) ~default:200 in
      let body =
        Option.value (object_field "json" http) ~default:(Json.object' [])
      in
      {
        expect;
        delay_ms;
        stream_delay_ms;
        delta_delay_ms;
        reply = Http { status; body };
      }
  | None -> (
      match object_field "chat" json with
      | Some chat ->
          {
            expect;
            delay_ms;
            stream_delay_ms;
            delta_delay_ms;
            reply = Chat chat;
          }
      | None -> (
          match object_field "response" json with
          | None ->
              {
                expect = None;
                delay_ms;
                stream_delay_ms;
                delta_delay_ms;
                reply = Sse json;
              }
          | Some response ->
              {
                expect;
                delay_ms;
                stream_delay_ms;
                delta_delay_ms;
                reply = Sse response;
              }))

let read_lines path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let rec loop acc =
        match input_line input with
        | line ->
            let line = String.trim line in
            if String.is_empty line then loop acc else loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let load_script path =
  match List.map (json_of_string path) (read_lines path) with
  | [] -> fail (path ^ ": script must contain at least one response")
  | items -> List.map script_item_of_json items

let strip_cr line =
  if String.ends_with ~suffix:"\r" line then String.drop_last 1 line else line

let split_header line =
  match String.split_first ~sep:":" line with
  | None -> (String.lowercase_ascii line, "")
  | Some (name, value) ->
      let name = String.lowercase_ascii name in
      let value = String.trim value in
      (name, value)

let header request name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    request.headers

let read_http_request fd : request =
  let input = Unix.in_channel_of_descr fd in
  let request_line = input_line input |> strip_cr in
  let rec read_headers acc =
    let line = input_line input |> strip_cr in
    if String.is_empty line then List.rev acc
    else read_headers (split_header line :: acc)
  in
  let headers = read_headers [] in
  let request : request =
    { request_line_text = request_line; headers; body = "" }
  in
  let content_length =
    match header request "content-length" with
    | None -> 0
    | Some value -> Option.value (int_of_string_opt value) ~default:0
  in
  let body = really_input_string input content_length in
  { request_line_text = request_line; headers; body }

let mkdir_p path =
  let rec loop path =
    if String.is_empty path || Sys.file_exists path then ()
    else (
      loop (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  loop path

let write_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () -> output_string output content)

let capture_request capture index request =
  let path = Filename.concat capture (Printf.sprintf "request-%d.json" index) in
  write_file path request.body;
  let headers_path =
    Filename.concat capture (Printf.sprintf "request-%d.headers" index)
  in
  request.headers
  |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\n")
  |> String.concat "" |> write_file headers_path

(* Non-fatal expectation test, for unordered matching. *)
let expectation_matches (expectation : expectation) (request : request) =
  Option.fold ~none:true
    ~some:(fun expected -> String.equal expected request.request_line_text)
    expectation.request_line
  && List.for_all
       (fun substring -> String.includes ~affix:substring request.body)
       expectation.body_contains
  && List.for_all
       (fun substring -> not (String.includes ~affix:substring request.body))
       expectation.body_not_contains

let check_expectation index (expectation : expectation) (request : request) =
  let request_label = Printf.sprintf "request %d" index in
  Option.iter
    (fun expected ->
      if not (String.equal expected request.request_line_text) then
        fail
          (Printf.sprintf "%s: expected request line %S, got %S" request_label
             expected request.request_line_text))
    expectation.request_line;
  List.iter
    (fun substring ->
      if not (String.includes ~affix:substring request.body) then
        fail
          (Printf.sprintf "%s: expected body to contain %S" request_label
             substring))
    expectation.body_contains;
  List.iter
    (fun substring ->
      if String.includes ~affix:substring request.body then
        fail
          (Printf.sprintf "%s: expected body not to contain %S" request_label
             substring))
    expectation.body_not_contains

let sse_event response =
  let data =
    Json.object'
      [
        Json.mem (Json.name "type") (Json.string "response.completed");
        Json.mem (Json.name "response") response;
      ]
  in
  "event: response.completed\n" ^ "data: " ^ json_string data ^ "\n\n"

let json_array = function
  | Jsont.Array (items, _) -> items
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Object _ ->
      []

(* A visible fragment of a completed Responses payload, streamed as deltas
   before the terminal event. The terminal [response.completed] still carries
   the whole payload, so fragments are display-only and never change the
   collected response. *)
type fragment = Text of string | Reasoning of string

let response_fragments response =
  match object_field "output" response with
  | None -> []
  | Some output ->
      json_array output
      |> List.concat_map (fun item ->
          match string_field "output item" "type" item with
          | Some "message" -> (
              match object_field "content" item with
              | None -> []
              | Some content ->
                  json_array content
                  |> List.filter_map (fun part ->
                      match string_field "content part" "type" part with
                      | Some "output_text" ->
                          Option.map
                            (fun text -> Text text)
                            (string_field "content part" "text" part)
                      | _ -> None))
          | Some "reasoning" -> (
              match object_field "summary" item with
              | None -> []
              | Some summary ->
                  json_array summary
                  |> List.filter_map (fun part ->
                      Option.map
                        (fun text -> Reasoning text)
                        (string_field "summary part" "text" part)))
          | _ -> [])

(* Split [s] into up to three UTF-8-safe chunks so a single fragment streams as
   several deltas. A split never breaks a codepoint; boundaries are arbitrary
   because the terminal response, not the concatenated deltas, is authoritative. *)
let chunk_text s =
  let n = String.length s in
  if n = 0 then []
  else
    let starts =
      let rec loop i acc =
        if i >= n then List.rev acc
        else
          let c = Char.code (String.get s i) in
          let width =
            if c < 0x80 then 1
            else if c < 0xE0 then 2
            else if c < 0xF0 then 3
            else 4
          in
          loop (min n (i + width)) (i :: acc)
      in
      Array.of_list (loop 0 [])
    in
    let total = Array.length starts in
    let parts = min 3 total in
    let per = (total + parts - 1) / parts in
    let rec build i acc =
      if i >= total then List.rev acc
      else
        let stop_index = min total (i + per) in
        let start = starts.(i) in
        let stop = if stop_index >= total then n else starts.(stop_index) in
        build stop_index (String.sub s start (stop - start) :: acc)
    in
    build 0 []

let sse_delta name delta =
  let data =
    Json.object'
      [
        Json.mem (Json.name "type") (Json.string name);
        Json.mem (Json.name "delta") (Json.string delta);
      ]
  in
  "event: " ^ name ^ "\ndata: " ^ json_string data ^ "\n\n"

(* The completed payload split into its streamed OpenAI Responses delta events —
   visible text and reasoning fragments in output order, one string per event —
   and the terminal [response.completed] event that follows them. Keeping the
   deltas as a list (rather than one joined blob) lets the server pace them two
   ways: [stream_delay_ms] holds the whole delta run before the terminal event,
   and [delta_delay_ms] sleeps between individual deltas (see {!send_reply}). The
   collected response stays exactly the terminal payload regardless of pacing. *)
let sse_parts response =
  let deltas =
    response_fragments response
    |> List.concat_map (fun fragment ->
        let name, text =
          match fragment with
          | Text text -> ("response.output_text.delta", text)
          | Reasoning text -> ("response.reasoning_summary_text.delta", text)
        in
        List.map (sse_delta name) (chunk_text text))
  in
  (deltas, sse_event response)

(* One Chat-Completions stream chunk: [{id, object, model, choices:[{index,
   delta, finish_reason?}]}] as a bare [data:] SSE frame. A [None] finish reason
   is omitted rather than sent as JSON null — an OpenAI-compat client reads an
   absent field identically and it keeps the encoder null-free. *)
let chat_chunk ~id ~model ~delta ~finish_reason =
  let choice_fields =
    [
      Json.mem (Json.name "index") (Json.number 0.);
      Json.mem (Json.name "delta") delta;
    ]
    @
    match finish_reason with
    | None -> []
    | Some reason ->
        [ Json.mem (Json.name "finish_reason") (Json.string reason) ]
  in
  let chunk =
    Json.object'
      [
        Json.mem (Json.name "id") (Json.string id);
        Json.mem (Json.name "object") (Json.string "chat.completion.chunk");
        Json.mem (Json.name "model") (Json.string model);
        Json.mem (Json.name "choices")
          (Json.list [ Json.object' choice_fields ]);
      ]
  in
  "data: " ^ json_string chunk ^ "\n\n"

let chat_field name text = Json.object' [ Json.mem (Json.name name) text ]

(* One tool-call delta: [{tool_calls:[{index, id, type:"function",
   function:{name, arguments}}]}]. [arguments] is a JSON-encoded string, exactly
   as an OpenAI-compatible server frames function arguments. *)
let tool_call_delta index item =
  let name = Option.value (string_field "tool_call" "name" item) ~default:"" in
  let arguments =
    Option.value (string_field "tool_call" "arguments" item) ~default:"{}"
  in
  let id =
    Option.value
      (string_field "tool_call" "id" item)
      ~default:(Printf.sprintf "call_%d" index)
  in
  chat_field "tool_calls"
    (Json.list
       [
         Json.object'
           [
             Json.mem (Json.name "index") (Json.number (float_of_int index));
             Json.mem (Json.name "id") (Json.string id);
             Json.mem (Json.name "type") (Json.string "function");
             Json.mem (Json.name "function")
               (Json.object'
                  [
                    Json.mem (Json.name "name") (Json.string name);
                    Json.mem (Json.name "arguments") (Json.string arguments);
                  ]);
           ];
       ])

(* The completed chat payload split into its streamed chunk events (one string
   per chunk) and the terminal [data: [DONE]] — mirroring {!sse_parts} so
   [stream_delay_ms] and [delta_delay_ms] pace a chat reply the same way. The
   [chat] object is a simplified completion:
   [content]/[reasoning] stream as content and reasoning deltas, [tool_calls] as
   function-call deltas, an optional [usage] object rides a final choices-empty
   chunk, and [finish_reason] (default ["stop"]) closes the single choice. *)
let chat_parts chat =
  let id =
    Option.value (string_field "chat" "id" chat) ~default:"chatcmpl-fake"
  in
  let model =
    Option.value (string_field "chat" "model" chat) ~default:"fake-model"
  in
  let finish_reason =
    Option.value (string_field "chat" "finish_reason" chat) ~default:"stop"
  in
  let text_chunks field name =
    match string_field "chat" field chat with
    | None -> []
    | Some text ->
        List.map
          (fun piece ->
            chat_chunk ~id ~model
              ~delta:(chat_field name (Json.string piece))
              ~finish_reason:None)
          (chunk_text text)
  in
  let reasoning_chunks = text_chunks "reasoning" "reasoning" in
  let content_chunks = text_chunks "content" "content" in
  let tool_call_chunks =
    match object_field "tool_calls" chat with
    | Some (Jsont.Array (items, _)) ->
        List.mapi
          (fun index item ->
            chat_chunk ~id ~model
              ~delta:(tool_call_delta index item)
              ~finish_reason:None)
          items
    | Some _ | None -> []
  in
  let final =
    chat_chunk ~id ~model ~delta:(Json.object' [])
      ~finish_reason:(Some finish_reason)
  in
  let usage_chunks =
    match object_field "usage" chat with
    | None -> []
    | Some usage ->
        [
          (let chunk =
             Json.object'
               [
                 Json.mem (Json.name "id") (Json.string id);
                 Json.mem (Json.name "object")
                   (Json.string "chat.completion.chunk");
                 Json.mem (Json.name "model") (Json.string model);
                 Json.mem (Json.name "choices") (Json.list []);
                 Json.mem (Json.name "usage") usage;
               ]
           in
           "data: " ^ json_string chunk ^ "\n\n");
        ]
  in
  let chunks =
    reasoning_chunks @ content_chunks @ tool_call_chunks @ [ final ]
    @ usage_chunks
  in
  (chunks, "data: [DONE]\n\n")

let status_reason = function
  | 200 -> "OK"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 402 -> "Payment Required"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 429 -> "Too Many Requests"
  | 500 -> "Internal Server Error"
  | 503 -> "Service Unavailable"
  | _ -> "Status"

let http_head ?(status = 200) ?(content_type = "text/event-stream")
    ~content_length () =
  let headers =
    [
      ("Content-Type", content_type);
      ("Content-Length", string_of_int content_length);
      ("Connection", "close");
    ]
  in
  let header_text =
    headers
    |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n")
    |> String.concat ""
  in
  Printf.sprintf "HTTP/1.1 %d %s\r\n%s\r\n" status (status_reason status)
    header_text

let http_response ?status ?content_type body =
  http_head ?status ?content_type ~content_length:(String.length body) () ^ body

let write_all fd text =
  let bytes = Bytes.of_string text in
  let rec loop offset =
    if offset < Bytes.length bytes then
      let written = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + written)
  in
  loop 0

let port_of_socket socket =
  match Unix.getsockname socket with
  | Unix.ADDR_INET (address, port) ->
      ignore (Unix.string_of_inet_addr address);
      port
  | Unix.ADDR_UNIX path -> fail ("expected inet socket, got unix socket " ^ path)

let accept_request socket index timeout =
  match Unix.select [ socket ] [] [] timeout with
  | [], _, _ ->
      fail
        (Printf.sprintf "timed out waiting for request %d after %.1fs" index
           timeout)
  | _ ->
      let accepted = Unix.accept socket in
      fst accepted

let sleep_ms ms = Unix.sleepf (float_of_int ms /. 1000.)

(* Stream [deltas] then [terminal] as one event-stream body, honoring both pacing
   knobs. [stream_delay_ms] holds the whole delta run before the terminal event;
   [delta_delay_ms] sleeps between individual deltas so a client observes a
   sustained token cadence rather than one burst. Content-Length always spans the
   whole body, so every split is invisible to the client beyond the delivery gap.
   With neither knob set the head and body go out in a single write, byte-for-byte
   the pre-pacing path. *)
let send_streamed client ~delta_delay_ms ~stream_delay_ms deltas terminal =
  match (delta_delay_ms, stream_delay_ms) with
  | None, None ->
      write_all client (http_response (String.concat "" deltas ^ terminal))
  | _ ->
      let content_length =
        List.fold_left
          (fun acc delta -> acc + String.length delta)
          (String.length terminal) deltas
      in
      write_all client (http_head ~content_length ());
      List.iteri
        (fun index delta ->
          if index > 0 then Option.iter sleep_ms delta_delay_ms;
          write_all client delta)
        deltas;
      Option.iter sleep_ms stream_delay_ms;
      write_all client terminal

let send_reply client item =
  match item.reply with
  | Http { status; body } ->
      write_all client
        (http_response ~status ~content_type:"application/json"
           (json_string body))
  | Sse response ->
      let deltas, terminal = sse_parts response in
      send_streamed client ~delta_delay_ms:item.delta_delay_ms
        ~stream_delay_ms:item.stream_delay_ms deltas terminal
  | Chat chat ->
      let chunks, terminal = chat_parts chat in
      send_streamed client ~delta_delay_ms:item.delta_delay_ms
        ~stream_delay_ms:item.stream_delay_ms chunks terminal

let handle_client options client item ~arrival request =
  capture_request options.capture arrival request;
  Option.iter
    (fun delay_ms -> Unix.sleepf (float_of_int delay_ms /. 1000.))
    item.delay_ms;
  send_reply client item

(* Sequential service: request N must satisfy script item N. *)
let serve_ordered options socket items =
  List.iteri
    (fun index item ->
      let client = accept_request socket (index + 1) options.accept_timeout_s in
      Fun.protect
        ~finally:(fun () -> Unix.close client)
        (fun () ->
          let request = read_http_request client in
          Option.iter
            (fun expectation ->
              check_expectation (index + 1) expectation request)
            item.expect;
          handle_client options client item ~arrival:(index + 1) request))
    items

(* Unordered service: each arriving request consumes the first pending item
   whose expectation it satisfies (an item with no expectation matches any
   request). Concurrent callers — a parent session and its detached children —
   arrive in nondeterministic order; matching by content keeps the script
   deterministic. Captures are numbered by arrival order. *)
let serve_unordered options socket items =
  let pending = Array.of_list (List.map Option.some items) in
  let total = Array.length pending in
  let match_index request =
    let rec loop i =
      if i >= total then None
      else
        match pending.(i) with
        | Some item
          when Option.fold ~none:true
                 ~some:(fun expectation ->
                   expectation_matches expectation request)
                 item.expect ->
            Some (i, item)
        | Some _ | None -> loop (i + 1)
    in
    loop 0
  in
  for arrival = 1 to total do
    let client = accept_request socket arrival options.accept_timeout_s in
    Fun.protect
      ~finally:(fun () -> Unix.close client)
      (fun () ->
        let request = read_http_request client in
        match match_index request with
        | None ->
            fail
              (Printf.sprintf
                 "request %d matched no pending script item; body: %s" arrival
                 (String.sub request.body 0
                    (min 400 (String.length request.body))))
        | Some (i, item) ->
            pending.(i) <- None;
            handle_client options client item ~arrival request)
  done

(* One-shot loopback HTTP GET: the "browser" of OAuth browser-login fixtures,
   which must hit the CLI's local callback listener without depending on curl.
   With [~body:false] it prints the response status code; with [~body:true] it
   prints the response body, so a fixture can assert the served callback page. *)
let run_get ~body url =
  let rest =
    match String.split_first ~sep:"://" url with
    | Some ("http", rest) -> rest
    | Some (scheme, _) -> fail ("--get supports http URLs only, got " ^ scheme)
    | None -> fail "--get URL must be an absolute http:// URL"
  in
  let authority, target =
    match String.split_first ~sep:"/" rest with
    | None -> (rest, "/")
    | Some (authority, path) -> (authority, "/" ^ path)
  in
  let host, port =
    match String.split_first ~sep:":" authority with
    | None -> (authority, 80)
    | Some (host, port) -> (
        match int_of_string_opt port with
        | Some port -> (host, port)
        | None -> fail ("invalid port in " ^ url))
  in
  (match host with
  | "localhost" | "127.0.0.1" -> ()
  | host -> fail ("--get supports loopback hosts only, got " ^ host));
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
      write_all socket
        (Printf.sprintf
           "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" target
           authority);
      let input = Unix.in_channel_of_descr socket in
      let status_line = input_line input |> strip_cr in
      (* Read to EOF (Connection: close), keeping every line so the body can be
         printed after the CRLF that ends the headers. *)
      let lines = ref [] in
      (try
         while true do
           lines := (input_line input |> strip_cr) :: !lines
         done
       with End_of_file -> ());
      let lines = List.rev !lines in
      if body then
        let rec after_headers = function
          | "" :: rest -> rest
          | _ :: rest -> after_headers rest
          | [] -> []
        in
        List.iter print_endline (after_headers lines)
      else
        match String.split_on_char ' ' status_line with
        | _ :: code :: _ -> print_endline code
        | [ _ ] | [] -> fail ("unexpected status line: " ^ status_line))

let serve options items =
  mkdir_p options.capture;
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, options.port));
      Unix.listen socket 8;
      write_file options.port_file (string_of_int (port_of_socket socket));
      if options.unordered then serve_unordered options socket items
      else serve_ordered options socket items)

let usage =
  "Usage: mentat_fake_provider_server --script FILE --capture DIR --port-file \
   FILE\n\
  \       mentat_fake_provider_server --get URL\n\
  \       mentat_fake_provider_server --get-body URL"

type mode = Serve of options | Get of { url : string; body : bool }

let parse_args () =
  let script = ref None in
  let capture = ref None in
  let port_file = ref None in
  let get = ref None in
  let get_body = ref false in
  let accept_timeout_s = ref 10. in
  let unordered = ref false in
  let port = ref 0 in
  let set option value slot =
    match !slot with
    | None -> slot := Some value
    | Some _ -> fail ("duplicate " ^ option)
  in
  let rec loop = function
    | [] -> ()
    | "--script" :: value :: rest ->
        set "--script" value script;
        loop rest
    | "--responses" :: value :: rest ->
        set "--responses" value script;
        loop rest
    | "--capture" :: value :: rest ->
        set "--capture" value capture;
        loop rest
    | "--port-file" :: value :: rest ->
        set "--port-file" value port_file;
        loop rest
    | "--get" :: value :: rest ->
        set "--get" value get;
        loop rest
    | "--get-body" :: value :: rest ->
        set "--get-body" value get;
        get_body := true;
        loop rest
    | "--unordered" :: rest ->
        unordered := true;
        loop rest
    | "--port" :: value :: rest -> (
        match int_of_string_opt value with
        | Some value when value > 0 ->
            port := value;
            loop rest
        | _ -> fail "--port must be a positive port number")
    | "--accept-timeout" :: value :: rest -> (
        match float_of_string_opt value with
        | Some value when value > 0. ->
            accept_timeout_s := value;
            loop rest
        | _ -> fail "--accept-timeout must be a positive number")
    | "--help" :: [] ->
        print_endline usage;
        exit 0
    | option :: _ when String.starts_with ~prefix:"--" option ->
        fail ("unknown option " ^ option)
    | arg :: _ -> fail ("unexpected argument " ^ arg)
  in
  let argv = Array.to_list Sys.argv |> List.tl in
  loop argv;
  match (!get, !script, !capture, !port_file) with
  | Some url, None, None, None -> Get { url; body = !get_body }
  | Some _, _, _, _ -> fail "--get cannot be combined with server options"
  | None, Some script, Some capture, Some port_file ->
      Serve
        {
          script;
          capture;
          port_file;
          accept_timeout_s = !accept_timeout_s;
          unordered = !unordered;
          port = !port;
        }
  | None, _, _, _ -> fail usage

let () =
  match parse_args () with
  | Get { url; body } -> run_get ~body url
  | Serve options ->
      let items = load_script options.script in
      serve options items
