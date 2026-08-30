(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Mentat_llm
module Chat_completions = Mentat_llm_http.Chat_completions

let provider = Llm.Provider.make "ollama"
let api = Chat_completions.api
let model id = Llm.Model.make ~provider ~api ~id
let invalid fn message = invalid_arg ("Mentat_llm_ollama." ^ fn ^ ": " ^ message)

let contains_newline value =
  String.exists (function '\n' | '\r' -> true | _ -> false) value

module Config = struct
  type t = {
    base_url : string;
    timeout_s : float;
    max_retries : int option;
    max_stream_retries : int option;
  }

  let default_base_url = "http://127.0.0.1:11434"
  let default_timeout_s = 1800.

  let check_max_retries field = function
    | Some retries when retries < 0 ->
        invalid "Config.make" (field ^ " must not be negative")
    | Some _ | None -> ()

  let make ?(base_url = default_base_url) ?(timeout_s = default_timeout_s)
      ?max_retries ?max_stream_retries () =
    if String.is_empty base_url then
      invalid "Config.make" "base_url must not be empty";
    if contains_newline base_url then
      invalid "Config.make" "base_url must not contain newline";
    let base_url = String.drop_last_while (Char.equal '/') base_url in
    if String.is_empty base_url then
      invalid "Config.make" "base_url must not be only slashes";
    if (not (Float.is_finite timeout_s)) || timeout_s <= 0. then
      invalid "Config.make" "timeout_s must be positive and finite";
    check_max_retries "max_retries" max_retries;
    check_max_retries "max_stream_retries" max_stream_retries;
    { base_url; timeout_s; max_retries; max_stream_retries }

  let default = make ()
  let base_url t = t.base_url
  let timeout_s t = t.timeout_s
  let max_retries t = t.max_retries
  let max_stream_retries t = t.max_stream_retries
end

module Credential = struct
  type t = Api_key of string | Bearer of string

  let check fn value =
    if String.is_empty value then invalid fn "value must not be empty";
    if contains_newline value then invalid fn "value must not contain newline"

  let api_key key =
    check "Credential.api_key" key;
    Api_key key

  let bearer token =
    check "Credential.bearer" token;
    Bearer token

  (* Both kinds authenticate as a bearer token: the daemon (and every
     OpenAI-compatible server behind the same endpoint shape) reads
     [Authorization: Bearer]. *)
  let header = function
    | Api_key value | Bearer value -> ("authorization", "Bearer " ^ value)
end

let client ~env ?(config = Config.default) ?credential () =
  let headers = Option.map Credential.header credential |> Option.to_list in
  let run ~cancelled ~on_event request =
    Eio.Switch.run ~name:"ollama.request" @@ fun sw ->
    let endpoint =
      Chat_completions.make ~provider ~headers
        ~timeout_s:(Config.timeout_s config)
        ?max_retries:(Config.max_retries config)
        ?max_stream_retries:(Config.max_stream_retries config)
        ~base_url:(Config.base_url config) ~sw ~env ()
    in
    Chat_completions.run endpoint ~cancelled ~on_event request
  in
  Llm.Client.make ~provider ~apis:[ api ] ~run
