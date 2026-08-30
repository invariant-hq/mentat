(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Mentat_llm
module Chat_completions = Mentat_llm_http.Chat_completions
module Messages = Mentat_llm_http.Messages

let provider = Llm.Provider.make "opencode-go"
let chat_model id = Llm.Model.make ~provider ~api:Chat_completions.api ~id
let messages_model id = Llm.Model.make ~provider ~api:Messages.api ~id

let invalid fn message =
  invalid_arg ("Mentat_llm_opencode." ^ fn ^ ": " ^ message)

let contains_newline value =
  String.exists (function '\n' | '\r' -> true | _ -> false) value

module Config = struct
  type t = {
    base_url : string;
    timeout_s : float;
    max_retries : int option;
    max_stream_retries : int option;
  }

  let default_base_url = "https://opencode.ai/zen/go"
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

  (* Both kinds carry one secret; the header spelling is the route's. The
     chat-completions endpoint reads [Authorization: Bearer]; the messages
     endpoint reads the dialect's [x-api-key]. *)
  let header = function
    | Api_key value | Bearer value -> ("authorization", "Bearer " ^ value)

  let messages_header = function
    | Api_key value | Bearer value -> ("x-api-key", value)
end

(* The gateway disambiguates failures only in [error.type]: usage limits
   arrive as 429 and account problems — a lapsed subscription, an unknown
   model — as 401, so the status alone misclassifies both. The classifier
   reads the one token that tells them apart, and the terminal predicate stops
   the retry ladder on a limit no retry can outwait. *)

let error_type body =
  match Jsont_bytesrw.decode_string Jsont.json body with
  | Error _ -> None
  | Ok (Jsont.Object (fields, _)) -> (
      match Jsont.Json.find_mem "error" fields with
      | Some (_, Jsont.Object (error_fields, _)) -> (
          match Jsont.Json.find_mem "type" error_fields with
          | Some (_, Jsont.String (value, _)) -> Some value
          | Some _ | None -> None)
      | Some _ | None -> None)
  | Ok _ -> None

let quota_type = function
  | "GoUsageLimitError" | "FreeUsageLimitError" | "BlackUsageLimitError"
  | "CreditsError" | "MonthlyLimitError" | "UserLimitError" ->
      true
  | _ -> false

let quota_exhausted ~body =
  match error_type body with
  | Some type_ -> quota_type type_
  | None -> false

let classify_error ~status:_ ~body =
  match error_type body with
  | Some type_ when quota_type type_ -> Some Llm.Error.Quota
  | Some "ModelError" -> Some Llm.Error.Invalid_request
  | Some _ | None -> None

let terminal (response : Mentat_llm_http.response) =
  quota_exhausted ~body:response.Mentat_llm_http.body

let run_chat config credential ~env ~cancelled ~on_event request =
  Eio.Switch.run ~name:"opencode.request" @@ fun sw ->
  let endpoint =
    Chat_completions.make ~provider
      ~headers:[ Credential.header credential ]
      ~timeout_s:(Config.timeout_s config)
      ?max_retries:(Config.max_retries config)
      ?max_stream_retries:(Config.max_stream_retries config)
      ~terminal ~classify:classify_error
      ~base_url:(Config.base_url config) ~sw ~env ()
  in
  Chat_completions.run endpoint ~cancelled ~on_event request

(* The gateway's messages route honors cache breakpoints and accepts sampling
   parameters unconditionally, unlike the dialect's first party. *)
let run_messages config credential ~env ~cancelled ~on_event request =
  Eio.Switch.run ~name:"opencode.request" @@ fun sw ->
  let endpoint =
    Messages.make ~provider
      ~headers:[ Credential.messages_header credential ]
      ~timeout_s:(Config.timeout_s config)
      ?max_retries:(Config.max_retries config)
      ?max_stream_retries:(Config.max_stream_retries config)
      ~terminal ~classify:classify_error ~cache:true ~sampling:true
      ~endpoint:(Config.base_url config ^ "/v1/messages")
      ~sw ~env ()
  in
  Messages.run endpoint ~cancelled ~on_event request

let client ~env ?(config = Config.default) ~credential () =
  (* The acceptance gate admits only the two declared families, so any request
     reaching [run] that is not messages speaks chat completions. *)
  let run ~cancelled ~on_event request =
    let api = Llm.Model.api (Llm.Request.model request) in
    let arm =
      if Llm.Model.Api.equal api Messages.api then run_messages else run_chat
    in
    arm config credential ~env ~cancelled ~on_event request
  in
  Llm.Client.make ~provider ~apis:[ Chat_completions.api; Messages.api ] ~run
