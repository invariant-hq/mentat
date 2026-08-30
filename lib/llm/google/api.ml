(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Http = Mentat_llm_http

let api = "gemini"
let default_base_url = "https://generativelanguage.googleapis.com/v1beta"
let default_max_retries = 2
let default_stream_max_retries = 5
let max_honored_retry_delay = 60.

module Error = struct
  type response = Http.response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  type t = Response of response | Transport of string | Decode of string
end

module Client = struct
  type auth = Api_key of string

  type t = {
    config : Config.t;
    auth : auth;
    sw : Eio.Switch.t;
    env : Eio_unix.Stdenv.base;
  }

  let make config ~sw ~env ~auth () = { config; auth; sw; env }
  let config t = t.config
  let sw t = t.sw
  let env t = t.env
  let auth_header t = match t.auth with Api_key key -> ("x-goog-api-key", key)
end

(* Gemini quota errors carry the wait in the response body as RetryInfo
   ("retryDelay": "42s"), usually without a Retry-After header. Honoring it,
   bounded by [max_honored_retry_delay], is what makes rate-limited keys usable;
   gemini-cli applies the same max(server delay, backoff) rule. The body is
   scanned textually so a malformed error document degrades to plain backoff. *)

(* Exhausted daily or zero-valued quotas cannot recover within a request's
   lifetime: retrying only stalls the turn for the full honored delay.
   gemini-cli classifies these as terminal quota errors and fails fast; the
   raw error body is scanned for the same signals (a per-day quota id or a
   zero quota value). This fast-fail is pre-stream-only: it feeds the ?terminal
   hook of stream_post's pre-stream retry alone, so a quota that classified
   during the stream phase (RESOURCE_EXHAUSTED maps to Rate_limited, a retryable
   stream kind) would re-run to the stream budget rather than fail fast. *)
let terminal_quota body =
  let contains pattern =
    match Str.search_forward (Str.regexp pattern) body 0 with
    | _ -> true
    | exception Not_found -> false
  in
  contains {|PerDay|}
  || contains {|"quotaValue"[ 	]*:[ 	]*"0"|}
  || contains {|limit: 0[^0-9]|}

let retry_delay_of_body body =
  match
    Str.search_forward
      (Str.regexp {|"retryDelay"[ 	]*:[ 	]*"\([0-9.]+\)s"|})
      body 0
  with
  | exception Not_found -> None
  | _ -> (
      match float_of_string_opt (Str.matched_group 1 body) with
      | Some delay when delay > 0. ->
          Some (Float.min delay max_honored_retry_delay)
      | Some _ | None -> None)

let headers t attempt =
  [
    Client.auth_header t;
    ("content-type", "application/json");
    ("accept", "text/event-stream");
    ("user-agent", "mentat-llm-google/0");
    ("x-stainless-retry-count", string_of_int attempt);
  ]

let error_of_http = function
  | Http.Response response -> Error.Response response
  | Http.Transport message | Http.Unresolved_host message ->
      Error.Transport message

let stream_post t ~on_retry ~path ~body =
  let config = Client.config t in
  let base_url =
    Option.value (Config.base_url config) ~default:default_base_url
  in
  let max_retries =
    Option.value (Config.max_retries config) ~default:default_max_retries
  in
  Http.Retry.pre_stream ~clock:(Client.env t)#clock ~max_retries
    ~terminal:(fun response ->
      response.Error.status = 429 && terminal_quota response.Error.body)
    ~body_delay:(fun response -> retry_delay_of_body response.Error.body)
    ~on_retry
    (fun ~attempt ->
      Http.post_stream ~sw:(Client.sw t) ~env:(Client.env t)
        ~url:(base_url ^ path) ~headers:(headers t attempt) ~body)
  |> Result.map_error error_of_http

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let list_member name value = json_member name (Jsont.Json.list value)

let add_opt member name value fields =
  match value with None -> fields | Some value -> member name value :: fields

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> Ok value
  | Error message -> Error (Error.Decode ("JSON encode failed: " ^ message))

module Generate_content = struct
  type request = {
    model : string;
    contents : Jsont.json list;
    system_instruction : Jsont.json option;
    tools : Jsont.json list;
    tool_config : Jsont.json option;
    generation_config : Jsont.json option;
  }

  type event = { data : Jsont.json }
  type stream = Http.Sse.t

  let close = Http.Sse.close

  let body (request : request) =
    let fields = [ list_member "contents" request.contents ] in
    let fields =
      add_opt json_member "systemInstruction" request.system_instruction fields
    in
    let fields =
      match request.tools with
      | [] -> fields
      | tools -> list_member "tools" tools :: fields
    in
    let fields = add_opt json_member "toolConfig" request.tool_config fields in
    let fields =
      add_opt json_member "generationConfig" request.generation_config fields
    in
    Jsont.Json.object' (List.rev fields)

  let decode_sse_event raw_data =
    match Jsont_bytesrw.decode_string Jsont.json raw_data with
    | Error message ->
        Error
          (Error.Decode ("Google Gemini stream JSON decode failed: " ^ message))
    | Ok data -> Ok { data }

  let next stream =
    match Http.Sse.next stream with
    | None -> None
    | Some (Ok { Http.Sse.data; _ }) -> Some (decode_sse_event data)
    | Some (Error message) -> Some (Error (Error.Transport message))

  let create_stream
      ?(on_retry = fun ~attempt:_ ~limit:_ ~delay:_ ~reason:_ -> ()) client
      request =
    match json_string (body request) with
    | Error error -> Error error
    | Ok body ->
        let model = Uri.pct_encode request.model in
        let path = "/models/" ^ model ^ ":streamGenerateContent?alt=sse" in
        Result.map Http.Sse.make (stream_post client ~on_retry ~path ~body)
end
