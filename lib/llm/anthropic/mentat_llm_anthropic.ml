(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Mentat_llm
module Messages = Mentat_llm_http.Messages
module Config = Config

let provider = Llm.Provider.make "anthropic"
let api = Messages.api
let model id = Llm.Model.make ~provider ~api ~id
let default_base_url = "https://api.anthropic.com/v1"

module Credential = struct
  type t = Api_key of string | Bearer of string

  let contains_newline value =
    String.exists (function '\n' | '\r' -> true | _ -> false) value

  let check_header_value fn value =
    if String.is_empty value then
      invalid_arg ("Mentat_llm_anthropic.Credential." ^ fn ^ ": empty value");
    if contains_newline value then
      invalid_arg
        ("Mentat_llm_anthropic.Credential." ^ fn ^ ": value contains newline")

  let api_key key =
    check_header_value "api_key" key;
    Api_key key

  let bearer token =
    check_header_value "bearer" token;
    Bearer token

  let header = function
    | Api_key key -> ("x-api-key", key)
    | Bearer token -> ("authorization", "Bearer " ^ token)
end

(* Anthropic's first-party dialect rulings on the shared codec: cache
   breakpoints are always planted, and sampling parameters travel only
   alongside an explicitly disabled thinking — current Claude models run
   adaptive thinking otherwise and reject them. *)
let run config credential ~env ~cancelled ~on_event request =
  Eio.Switch.run ~name:"anthropic.request" @@ fun sw ->
  let base_url = Option.value (Config.base_url config) ~default:default_base_url in
  let endpoint =
    Messages.make ~provider
      ~headers:[ Credential.header credential ]
      ~timeout_s:(Config.timeout_s config)
      ?max_retries:(Config.max_retries config)
      ?max_stream_retries:(Config.max_stream_retries config)
      ~cache:true ~sampling:false
      ~endpoint:(base_url ^ "/messages")
      ~sw ~env ()
  in
  Messages.run endpoint ~cancelled ~on_event request

let client ~env ?(config = Config.default) ~credential () =
  Llm.Client.make ~provider ~apis:[ api ] ~run:(run config credential ~env)
