(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

module Cred = Mentat_provider.Credential

let log_src =
  Logs.Src.create "mentat.provider_runtime.auth"
    ~doc:"Credential login and refresh flows"

module Log = (val Logs.src_log log_src : Logs.LOG)

let user_error_message message =
  match String.index_opt message ':' with
  | None -> message
  | Some i ->
      String.trim (String.sub message (i + 1) (String.length message - i - 1))

module Error = struct
  type t =
    | Invalid_request of string
    | Network of string
    | Protocol of string
    | Rejected of string
    | Timeout of string
    | Not_refreshable

  let oauth2_callback_message = function
    | `Oauth _ -> "authorization rejected by provider"
    | `Missing field -> "authorization callback missing " ^ field
    | `Duplicate field -> "authorization callback duplicates " ^ field
    | `State_mismatch -> "authorization callback state mismatch"
    | `Redirect_uri_mismatch -> "authorization callback redirect URI mismatch"

  let http_error_message error =
    Format.asprintf "%a" Oauth2_eio.Error.pp_transport error

  let malformed_message context _malformed = context ^ ": malformed response"

  let response_message context response =
    Printf.sprintf "%s: HTTP error %d: body length %d" context
      response.Oauth2.Response.status
      (String.length response.Oauth2.Response.body)

  let of_oauth2 = function
    | `Transport error -> Network (http_error_message error)
    | `Oauth _ -> Rejected "OAuth request rejected by provider"
    | `Malformed malformed ->
        Protocol (malformed_message "malformed OAuth response" malformed)
    | `Http response -> Protocol (response_message "OAuth response" response)

  let message = function
    | Invalid_request message -> message
    | Network message -> message
    | Protocol message -> message
    | Rejected message -> message
    | Timeout message -> message
    | Not_refreshable -> "secret is not refreshable"
end

module OAuth_secret = struct
  let timestamp_add seconds now = Int64.add now (Int64.of_int seconds)

  let require_bearer_token token =
    let token_type = Oauth2.Token.token_type token in
    if String.equal (String.lowercase_ascii token_type) "bearer" then Ok ()
    else Error (Error.Protocol "unsupported OAuth token type")

  (* Generic OAuth secret construction. Provider-specific interpretation, such as
     extracting OpenAI account ids, lives in {!Openai_chatgpt}. *)
  let oauth_token ~now token =
    let* () = require_bearer_token token in
    let access_token = Oauth2.Token.access_token token in
    let refresh_token = Oauth2.Token.refresh_token token in
    let expires_at =
      Option.map
        (fun seconds -> timestamp_add seconds now)
        (Oauth2.Token.expires_in token)
    in
    match Cred.Secret.oauth ~access_token ?refresh_token ?expires_at () with
    | secret -> Ok secret
    | exception Invalid_argument message ->
        Error
          (Error.Protocol
             ("invalid OAuth token secret: " ^ user_error_message message))
end

module Http = struct
  type t = {
    client : Cohttp_eio.Client.t;
    clock : float Eio.Time.clock_ty Eio.Std.r;
    timeout_s : float;
  }

  let make ~(clock : _ Eio.Time.clock) ~timeout_s client =
    if Float.compare timeout_s 0.0 <= 0 then
      invalid_arg "OAuth HTTP timeout_s must be positive";
    { client; clock :> float Eio.Time.clock_ty Eio.Std.r; timeout_s }

  let default_timeout_s = 30.0

  let tls_client ~stdenv =
    match Oauth2_eio.make_tls_client (Eio.Stdenv.net stdenv) with
    | Ok client ->
        Ok
          (make ~clock:(Eio.Stdenv.clock stdenv) ~timeout_s:default_timeout_s
             client)
    | Error (`System_ca_unavailable | `Tls_configuration_failed) ->
        Error (Error.Network "OAuth TLS setup failed")

  type timeout = Timed_out

  let with_deadline t f =
    match Eio.Time.with_timeout t.clock t.timeout_s (fun () -> Ok (f ())) with
    | Ok result -> Ok result
    | Error `Timeout -> Error Timed_out

  let timeout_error timeout_s =
    Error.Timeout (Printf.sprintf "OAuth request timed out after %gs" timeout_s)

  let post t ~sw ~uri ?(headers = []) ~body () =
    match
      with_deadline t (fun () ->
          Oauth2_eio.post t.client ~sw ~uri ~headers ~body ())
    with
    | Ok (Ok response) -> Ok response
    | Ok (Error error) -> Error (Error.Network (Error.http_error_message error))
    | Error Timed_out -> Error (timeout_error t.timeout_s)

  type send_error = Timeout of float | OAuth of Oauth2_eio.Error.t

  let send t ~sw request =
    match with_deadline t (fun () -> Oauth2_eio.send t.client ~sw request) with
    | Ok (Ok response) -> Ok response
    | Ok (Error error) -> Error (OAuth error)
    | Error Timed_out -> Error (Timeout t.timeout_s)

  let send_error = function
    | Timeout timeout_s -> timeout_error timeout_s
    | OAuth error -> Error.of_oauth2 error
end

module Local_callback = struct
  (* The loopback callback is the only mentat surface a browser ever renders, so
     it earns the brand rather than a bare sentence: the paprika heap mark and
     wordmark, a monospace terminal face, and an outcome-tinted ❯
     cursor. Everything is inlined and asset-free — the page is served from a
     one-shot loopback server with no network reachable and must render offline.
     Every interpolated value is HTML-escaped; the callback query is
     attacker-influenceable. *)

  let html_escape s =
    let buffer = Buffer.create (String.length s + 8) in
    String.iter
      (function
        | '&' -> Buffer.add_string buffer "&amp;"
        | '<' -> Buffer.add_string buffer "&lt;"
        | '>' -> Buffer.add_string buffer "&gt;"
        | '"' -> Buffer.add_string buffer "&quot;"
        | '\'' -> Buffer.add_string buffer "&#39;"
        | c -> Buffer.add_char buffer c)
      s;
    Buffer.contents buffer

  let page_styles =
    {css|
    :root {
      color-scheme: light dark;
      --bg: #f6f5f4;
      --card: #ffffff;
      --border: #e7e4e1;
      --strong: #1c1c1c;
      --muted: #6f6f6f;
      --faint: #9a958f;
      --accent: #d6603c;
      --ok: #2f9e5f;
      --err: #d64545;
      --chip-bg: #f3f1ef;
      --chip-border: #e7e4e1;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d0d0d;
        --card: #161616;
        --border: #282828;
        --strong: #ededed;
        --muted: #949494;
        --faint: #6f6f6f;
        --accent: #d6603c;
        --ok: #4dd980;
        --err: #ff5f5f;
        --chip-bg: #1a1a1a;
        --chip-border: #2b2b2b;
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; height: 100%; }
    body {
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 24px;
      background: var(--bg);
      color: var(--muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, "Cascadia Code", Consolas, "Liberation Mono", monospace;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
    }
    .card {
      width: min(100%, 25rem);
      padding: 2.25rem 1.75rem 1.75rem;
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 12px;
      text-align: center;
    }
    .mark { font-size: 1.9rem; line-height: 1; color: var(--accent); }
    .wordmark {
      margin-top: 0.5rem;
      font-size: 0.8125rem;
      letter-spacing: 0.34em;
      text-indent: 0.34em;
      color: var(--faint);
    }
    .headline { margin: 1.75rem 0 0; font-size: 1rem; font-weight: 600; color: var(--strong); }
    .cursor { color: var(--accent); }
    .card[data-outcome="ok"] .cursor { color: var(--ok); }
    .card[data-outcome="fail"] .cursor { color: var(--err); }
    .message { margin: 0.5rem 0 0; font-size: 0.875rem; color: var(--muted); }
    .detail {
      margin: 1rem 0 0;
      padding: 0.625rem 0.75rem;
      text-align: left;
      font-size: 0.8125rem;
      color: var(--strong);
      background: var(--chip-bg);
      border: 1px solid var(--chip-border);
      border-radius: 8px;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
    .guide { margin: 1.25rem 0 0; font-size: 0.8125rem; color: var(--faint); }
    |css}

  let auto_close_script =
    {js|<script>setTimeout(function(){try{window.close()}catch(e){}},2500)</script>|js}

  let render ~outcome ~title ~headline ?message ?detail ?guide ?(script = "") ()
      =
    let outcome_attr = match outcome with `Ok -> "ok" | `Fail -> "fail" in
    let paragraph class_ = function
      | None -> ""
      | Some text ->
          Printf.sprintf {|<p class="%s">%s</p>|} class_ (html_escape text)
    in
    let detail_block =
      match detail with
      | None -> ""
      | Some text ->
          Printf.sprintf {|<pre class="detail">%s</pre>|} (html_escape text)
    in
    Printf.sprintf
      {|<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex">
<title>%s</title>
<style>%s</style>
</head>
<body>
<main class="card" data-outcome="%s" role="status" aria-live="polite">
<div class="mark" aria-hidden="true">▂▄▆▄▂</div>
<div class="wordmark">mentat</div>
<h1 class="headline"><span class="cursor" aria-hidden="true">❯</span> %s</h1>
%s%s%s
</main>
%s</body>
</html>|}
      (html_escape title) page_styles outcome_attr (html_escape headline)
      (paragraph "message" message)
      detail_block (paragraph "guide" guide) script

  let html_success ~provider () =
    let headline =
      match provider with
      | Some provider -> "signed in to " ^ provider
      | None -> "signed in"
    in
    render ~outcome:`Ok ~title:"mentat — signed in" ~headline
      ~message:"return to your terminal — you can close this tab."
      ~script:auto_close_script ()

  let html_denied ~provider ~error ~description () =
    let message =
      match provider with
      | Some provider -> provider ^ " denied the authorization request."
      | None -> "the provider denied the authorization request."
    in
    let detail =
      match description with
      | Some description when not (String.equal description "") ->
          error ^ ": " ^ description
      | Some _ | None -> error
    in
    render ~outcome:`Fail ~title:"mentat — sign-in failed"
      ~headline:"sign-in failed" ~message ~detail
      ~guide:"close this tab and run the login again in your terminal." ()

  let html_unverified ~provider () =
    let message =
      match provider with
      | Some provider -> "this " ^ provider ^ " callback couldn't be verified."
      | None -> "this callback couldn't be verified."
    in
    render ~outcome:`Fail ~title:"mentat — sign-in failed"
      ~headline:"sign-in failed" ~message
      ~guide:"it may be stale or from another sign-in — run the login again." ()

  let html_not_found () =
    render ~outcome:`Fail ~title:"mentat" ~headline:"not found"
      ~message:"this is the mentat sign-in callback."
      ~guide:"nothing to do here — you can close this tab." ()

  (* The listener mechanics live in [Oauth2_eio.Loopback]; this wrapper
     injects the branded pages and folds the listener's errors into this
     leaf's error sum. *)
  let await_once ~stdenv ?provider ?on_ready ?accept ?serve ~redirect_uri
      ~timeout_s () =
    let respond = function
      | Oauth2_eio.Loopback.Granted -> html_success ~provider ()
      | Oauth2_eio.Loopback.Denied { error; description } ->
          html_denied ~provider ~error ~description ()
      | Oauth2_eio.Loopback.Unverified -> html_unverified ~provider ()
      | Oauth2_eio.Loopback.Not_found -> html_not_found ()
    in
    match
      Oauth2_eio.Loopback.await_once ~net:(Eio.Stdenv.net stdenv)
        ~clock:(Eio.Stdenv.clock stdenv) ?on_ready ?accept ?serve ~respond
        ~redirect_uri ~timeout_s ()
    with
    | Ok callback -> Ok callback
    | Error (`Invalid_redirect_uri reason) ->
        Error (Error.Invalid_request ("browser redirect URI: " ^ reason))
    | Error `Listener_unavailable ->
        Error (Error.Network "callback listener unavailable")
    | Error `Timed_out ->
        Error (Error.Timeout "browser authorization timed out")
end

module Openai_chatgpt = struct
  module Config = struct
    type t = {
      issuer : Uri.t;
      client_id : string;
      expires_in : int;
      poll_interval : int;
    }

    let default_issuer = Uri.of_string "https://auth.openai.com"
    let default_client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
    let default_expires_in = 900
    let default_poll_interval = 5

    let valid_scheme = function
      | Some scheme ->
          String.equal (String.lowercase_ascii scheme) "https"
          || String.equal (String.lowercase_ascii scheme) "http"
      | None -> false

    let invalid_config message =
      Error (Error.Invalid_request ("OpenAI ChatGPT auth config: " ^ message))

    let check_issuer issuer =
      if not (valid_scheme (Uri.scheme issuer)) then
        invalid_config "issuer must use http or https"
      else if Option.is_none (Uri.host issuer) then
        invalid_config "issuer must have a host"
      else if Option.is_some (Uri.verbatim_query issuer) then
        invalid_config "issuer must not have a query"
      else if Option.is_some (Uri.fragment issuer) then
        invalid_config "issuer must not have a fragment"
      else Ok ()

    let check_non_empty field = function
      | "" -> invalid_config (field ^ " must not be empty")
      | _ -> Ok ()

    let check_non_negative field value =
      if value < 0 then invalid_config (field ^ " must not be negative")
      else Ok ()

    let make ?(issuer = default_issuer) ?(client_id = default_client_id)
        ?(expires_in = default_expires_in)
        ?(poll_interval = default_poll_interval) () =
      let* () = check_issuer issuer in
      let* () = check_non_empty "client_id" client_id in
      let* () = check_non_negative "expires_in" expires_in in
      let* () = check_non_negative "poll_interval" poll_interval in
      Ok { issuer; client_id; expires_in; poll_interval }

    let default =
      {
        issuer = default_issuer;
        client_id = default_client_id;
        expires_in = default_expires_in;
        poll_interval = default_poll_interval;
      }

    let client_id t = t.client_id
    let expires_in t = t.expires_in
    let poll_interval t = t.poll_interval

    let trim_right_slashes path =
      let rec loop i =
        if i <= 0 then ""
        else if Char.equal (String.unsafe_get path (i - 1)) '/' then loop (i - 1)
        else String.sub path 0 i
      in
      loop (String.length path)

    let append_path issuer suffix =
      let base = trim_right_slashes (Uri.path issuer) in
      let suffix =
        if String.starts_with ~prefix:"/" suffix then suffix else "/" ^ suffix
      in
      let uri = Uri.with_path issuer (base ^ suffix) in
      Uri.with_fragment (Uri.with_query' uri []) None

    let user_code_endpoint t =
      append_path t.issuer "/api/accounts/deviceauth/usercode"

    let device_token_endpoint t =
      append_path t.issuer "/api/accounts/deviceauth/token"

    let oauth_token_endpoint t = append_path t.issuer "/oauth/token"
    let oauth_revoke_endpoint t = append_path t.issuer "/oauth/revoke"
    let verification_uri t = append_path t.issuer "/codex/device"
    let device_redirect_uri t = append_path t.issuer "/deviceauth/callback"
  end

  let malformed ?field ?raw message =
    ({ Oauth2.field; Oauth2.message; Oauth2.raw } : Oauth2.malformed)

  let protocol_malformed malformed =
    Error.Protocol
      (Error.malformed_message "malformed OpenAI ChatGPT auth response"
         malformed)

  let malformed_error ?field ?raw message =
    protocol_malformed (malformed ?field ?raw message)

  let non_empty_string field json =
    let* value = Oauth2.Json.string field json in
    if String.equal value "" then
      Error (malformed ~field ~raw:json "expected non-empty string")
    else Ok value

  let int_string field json =
    match json with
    | Jsont.String (value, _) -> (
        match int_of_string_opt value with
        | Some value -> Ok value
        | None -> Error (malformed ~field ~raw:json "expected integer"))
    | value -> Oauth2.Json.int field value

  let non_negative_int_string field json =
    let* value = int_string field json in
    if value >= 0 then Ok value
    else Error (malformed ~field ~raw:json "expected non-negative integer")

  let http_error response =
    Error.Protocol
      (Error.response_message "OpenAI ChatGPT auth response" response)

  let oauth_error _error = Error.Rejected "OAuth request rejected by provider"

  module Json = struct
    let mem name value = Jsont.Json.mem (Jsont.Json.name name) value
    let string value = Jsont.Json.string value
    let object' fields = Jsont.Json.object' fields

    let encode json =
      match Jsont_bytesrw.encode_string Jsont.json json with
      | Ok body -> Ok body
      | Error _ -> Error (Error.Invalid_request "cannot encode OAuth request")
  end

  let response_decode_error = function
    | `Oauth error -> Error (oauth_error error)
    | `Http response -> Error (http_error response)
    | `Malformed malformed -> Error (protocol_malformed malformed)

  let decode_oauth_or_http response =
    response_decode_error (Oauth2.Response.error_of_non_success response)

  let decode_success_json parse response =
    if Oauth2.Response.is_success response then
      match Oauth2.Response.json response with
      | Error malformed -> Error (protocol_malformed malformed)
      | Ok json -> Result.map_error protocol_malformed (parse json)
    else decode_oauth_or_http response

  let post http ~sw ~uri ?(headers = []) ~body () =
    Http.post http ~sw ~uri ~headers ~body ()

  let post_json http ~sw ~uri json =
    match Json.encode json with
    | Error error -> Error error
    | Ok body ->
        post http ~sw ~uri
          ~headers:[ ("Content-Type", "application/json") ]
          ~body ()

  let post_form http ~sw ~uri params =
    post http ~sw ~uri ~body:(Oauth2.encode_form params) ()

  let timestamp_add seconds now = Int64.add now (Int64.of_int seconds)
  let expires_at ~now = Option.map (fun seconds -> timestamp_add seconds now)

  let jwt_payload id_token =
    let segments = String.split_on_char '.' id_token in
    match List.nth_opt segments 1 with
    | Some payload when List.length segments >= 2 ->
        Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet payload
    | Some _ | None -> Error (`Msg "expected JWT with at least two segments")

  let string_field name json =
    match Oauth2.Json.field name json with
    | Some (Jsont.String (value, _)) when not (String.equal value "") ->
        Some value
    | Some (Jsont.Null _)
    | Some (Jsont.Bool _)
    | Some (Jsont.Number _)
    | Some (Jsont.String _)
    | Some (Jsont.Array _)
    | Some (Jsont.Object _)
    | None ->
        None

  let account_id_of_id_token id_token =
    match jwt_payload id_token with
    | Error (`Msg _) -> None
    | Ok payload -> (
        match Jsont_bytesrw.decode_string Jsont.json payload with
        | Error _ -> None
        | Ok json -> (
            match string_field "chatgpt_account_id" json with
            | Some account_id -> Some account_id
            | None -> (
                match Oauth2.Json.field "https://api.openai.com/auth" json with
                | Some auth -> string_field "chatgpt_account_id" auth
                | None -> None)))

  let account_id_of_tokens ~id_token ~access_token =
    match Option.bind id_token account_id_of_id_token with
    | Some account_id -> Some account_id
    | None -> account_id_of_id_token access_token

  let secret_of_oauth_parts ~access_token ?refresh_token ?expires_at ?account_id
      () =
    match
      Cred.Secret.oauth ~access_token ?refresh_token ?expires_at ?account_id ()
    with
    | secret -> Ok secret
    | exception Invalid_argument message ->
        Error (malformed_error ("invalid token secret: " ^ message))

  type token = {
    access_token : string;
    refresh_token : string;
    expires_at : int64 option;
    account_id : string option;
  }

  let parse_token ~now json =
    let* id_token = Oauth2.Json.required "id_token" non_empty_string json in
    let* access_token =
      Oauth2.Json.required "access_token" non_empty_string json
    in
    let* refresh_token =
      Oauth2.Json.required "refresh_token" non_empty_string json
    in
    let* expires_in =
      Oauth2.Json.optional "expires_in" non_negative_int_string json
    in
    Ok
      {
        access_token;
        refresh_token;
        expires_at = expires_at ~now expires_in;
        account_id = account_id_of_id_token id_token;
      }

  let secret_of_token token =
    secret_of_oauth_parts ~access_token:token.access_token
      ~refresh_token:token.refresh_token ?expires_at:token.expires_at
      ?account_id:token.account_id ()

  let secret_of_oauth_token ~now oauth_token =
    let* () = OAuth_secret.require_bearer_token oauth_token in
    let access_token = Oauth2.Token.access_token oauth_token in
    let refresh_token = Oauth2.Token.refresh_token oauth_token in
    let id_token = Oauth2.Token.field_string "id_token" oauth_token in
    let account_id = account_id_of_tokens ~id_token ~access_token in
    let expires_at = expires_at ~now (Oauth2.Token.expires_in oauth_token) in
    secret_of_oauth_parts ~access_token ?refresh_token ?expires_at ?account_id
      ()

  let decode_token ~now response =
    let* token = decode_success_json (parse_token ~now) response in
    secret_of_token token

  type code_exchange = {
    authorization_code : string;
    code_challenge : string;
    code_verifier : string;
  }

  let parse_code_exchange json =
    let* authorization_code =
      Oauth2.Json.required "authorization_code" non_empty_string json
    in
    let* code_challenge =
      Oauth2.Json.required "code_challenge" non_empty_string json
    in
    let* code_verifier =
      Oauth2.Json.required "code_verifier" non_empty_string json
    in
    Ok { authorization_code; code_challenge; code_verifier }

  let pkce_of_code_exchange code =
    match Oauth2.Pkce.of_verifier code.code_verifier with
    | Error (`Invalid_verifier reason) ->
        Error
          (malformed_error ~field:"code_verifier"
             ("invalid PKCE verifier: " ^ reason))
    | Ok pkce ->
        if String.equal (Oauth2.Pkce.challenge pkce) code.code_challenge then
          Ok pkce
        else
          Error
            (malformed_error ~field:"code_challenge"
               "does not match code_verifier")

  let exchange_authorization_code http ~sw ~now config code =
    let* pkce = pkce_of_code_exchange code in
    let params =
      [
        ("grant_type", "authorization_code");
        ("code", code.authorization_code);
        ("redirect_uri", Uri.to_string (Config.device_redirect_uri config));
        ("client_id", Config.client_id config);
        ("code_verifier", Oauth2.Pkce.verifier pkce);
      ]
    in
    let* response =
      post_form http ~sw ~uri:(Config.oauth_token_endpoint config) params
    in
    decode_token ~now response

  type current = {
    access_token : string;
    expires_at : int64 option;
    account_id : string option;
  }

  let refreshable_secret secret =
    Cred.Secret.expose secret
      ~api_key:(fun ~key:_ -> Error Error.Not_refreshable)
      ~bearer:(fun ~token:_ -> Error Error.Not_refreshable)
      ~oauth:(fun ~access_token ~refresh_token ~expires_at ~account_id ->
        match refresh_token with
        | None -> Error Error.Not_refreshable
        | Some refresh_token ->
            Ok
              ( ({ access_token; expires_at; account_id } : current),
                refresh_token ))

  type refresh_response = {
    refresh_id_token : string option;
    refresh_access_token : string option;
    refresh_refresh_token : string option;
    refresh_expires_at : int64 option;
  }

  let parse_refresh_response ~now json =
    let* id_token = Oauth2.Json.optional "id_token" non_empty_string json in
    let* access_token =
      Oauth2.Json.optional "access_token" non_empty_string json
    in
    let* refresh_token =
      Oauth2.Json.optional "refresh_token" non_empty_string json
    in
    let* expires_in =
      Oauth2.Json.optional "expires_in" non_negative_int_string json
    in
    Ok
      {
        refresh_id_token = id_token;
        refresh_access_token = access_token;
        refresh_refresh_token = refresh_token;
        refresh_expires_at = expires_at ~now expires_in;
      }

  let refresh_response_secret (current : current) ~current_refresh_token
      (response : refresh_response) =
    let access_token =
      Option.value response.refresh_access_token ~default:current.access_token
    in
    let refresh_token =
      Option.value response.refresh_refresh_token ~default:current_refresh_token
    in
    let expires_at =
      match response.refresh_expires_at with
      | Some expires_at -> Some expires_at
      | None ->
          if Option.is_some response.refresh_access_token then None
          else current.expires_at
    in
    let account_id =
      match response.refresh_id_token with
      | Some id_token -> (
          match account_id_of_id_token id_token with
          | Some account_id -> Some account_id
          | None -> current.account_id)
      | None -> current.account_id
    in
    secret_of_oauth_parts ~access_token ~refresh_token ?expires_at ?account_id
      ()

  let refresh ~http ~sw ~now config secret =
    let* current, refresh_token = refreshable_secret secret in
    let body =
      Json.object'
        [
          Json.mem "client_id" (Json.string (Config.client_id config));
          Json.mem "grant_type" (Json.string "refresh_token");
          Json.mem "refresh_token" (Json.string refresh_token);
        ]
    in
    let* response =
      post_json http ~sw ~uri:(Config.oauth_token_endpoint config) body
    in
    let* refresh_response =
      decode_success_json (parse_refresh_response ~now) response
    in
    let* secret =
      refresh_response_secret current ~current_refresh_token:refresh_token
        refresh_response
    in
    Log.info (fun m ->
        m "oauth token refreshed has_expiry=%b"
          (Option.is_some refresh_response.refresh_expires_at));
    Ok secret

  let revocable_secret secret =
    Cred.Secret.expose secret
      ~api_key:(fun ~key:_ -> Error Error.Not_refreshable)
      ~bearer:(fun ~token:_ -> Error Error.Not_refreshable)
      ~oauth:(fun ~access_token ~refresh_token ~expires_at:_ ~account_id:_ ->
        match refresh_token with
        | Some refresh_token -> Ok (refresh_token, "refresh_token")
        | None -> Ok (access_token, "access_token"))

  let revoke ~http ~sw config secret =
    let* token, token_type_hint = revocable_secret secret in
    let body =
      Json.object'
        [
          Json.mem "client_id" (Json.string (Config.client_id config));
          Json.mem "token" (Json.string token);
          Json.mem "token_type_hint" (Json.string token_type_hint);
        ]
    in
    let* response =
      post_json http ~sw ~uri:(Config.oauth_revoke_endpoint config) body
    in
    if Oauth2.Response.is_success response then (
      Log.info (fun m -> m "oauth token revoked");
      Ok ())
    else decode_oauth_or_http response
end

module Authorization_code = struct
  type t = {
    client : Oauth2.Client.t;
    token_endpoint : Uri.t;
    authorization : Oauth2.Authorization.t;
    authorization_uri : Uri.t;
    redirect_uri : Uri.t;
  }

  type token_profile = Generic | Openai_chatgpt

  let authorization_uri t = t.authorization_uri
  let redirect_uri t = t.redirect_uri

  let start ~random ~client ~authorization_endpoint ~token_endpoint
      ~redirect_uri ~scope ~extra ~pkce =
    let redirect_uri =
      match redirect_uri with
      | Some redirect_uri -> Ok redirect_uri
      | None ->
          Error
            (Error.Invalid_request
               "browser auth protocol requires an explicit redirect URI")
    in
    let pkce = if pkce then Some (Oauth2.Pkce.generate ~random) else None in
    let state = Oauth2.State.generate ~random in
    let* redirect_uri = redirect_uri in
    match
      Oauth2.Authorization.make ~client ~endpoint:authorization_endpoint
        ~redirect_uri ~state ?pkce ~scope ~extra ()
    with
    | Error (`Reserved name) ->
        Error
          (Error.Invalid_request ("reserved authorization parameter: " ^ name))
    | Ok authorization ->
        Log.info (fun m ->
            m "authorization flow started endpoint_host=%s"
              (Option.value ~default:"<none>" (Uri.host authorization_endpoint)));
        Ok
          {
            client;
            token_endpoint;
            authorization;
            authorization_uri = Oauth2.Authorization.uri authorization;
            redirect_uri = Oauth2.Authorization.redirect_uri authorization;
          }

  (* State is validated before OAuth errors surface, so an [`Oauth] result can
     only come from a state-matched — genuine — callback: the provider denied it,
     and the flow must see that denial rather than keep waiting. Everything else
     is a stray or forged request. *)
  let accepts_callback t callback =
    match Oauth2.Authorization.callback t.authorization callback with
    | Ok _ | Error (`Oauth _) -> true
    | Error
        (`Missing _ | `Duplicate _ | `State_mismatch | `Redirect_uri_mismatch)
      ->
        false

  let complete ~http ~sw t ~callback =
    match Oauth2.Authorization.callback t.authorization callback with
    | Error (`Oauth _) ->
        Error (Error.Rejected "authorization rejected by provider")
    | Error error ->
        Error (Error.Invalid_request (Error.oauth2_callback_message error))
    | Ok code -> (
        let grant = Oauth2.Authorization.grant code in
        match
          Oauth2.Grant.request ~client:t.client ~endpoint:t.token_endpoint grant
          |> Http.send http ~sw
        with
        | Ok token ->
            Log.info (fun m ->
                m "authorization code exchanged endpoint_host=%s"
                  (Option.value ~default:"<none>" (Uri.host t.token_endpoint)));
            Ok token
        | Error error -> Error (Http.send_error error))

  let complete_secret ~http ~sw t ~callback ~now ~profile =
    let* token = complete ~http ~sw t ~callback in
    let now = now () in
    match profile with
    | Generic -> OAuth_secret.oauth_token ~now token
    | Openai_chatgpt -> Openai_chatgpt.secret_of_oauth_token ~now token
end

module Device_code = struct
  type challenge = {
    verification_uri : Uri.t;
    verification_uri_complete : Uri.t option;
    user_code : string;
  }

  type schedule = {
    expires_at : int64;
    expires_in : int;
    interval : int;
    next_poll_after : int64;
  }

  (* The state closes over its transport so {!poll} needs no protocol declaration
     or configuration. Standard OAuth carries the [Oauth2.Device.t] grant plus its
     client and token endpoint; the OpenAI flow carries the config and device
     identifier. *)
  type transport =
    | Oauth2 of {
        device : Oauth2.Device.t;
        client : Oauth2.Client.t;
        token_endpoint : Uri.t;
      }
    | Openai of { config : Openai_chatgpt.Config.t; device_auth_id : string }

  type t = { schedule : schedule; challenge : challenge; transport : transport }
  type poll = Authorized of Cred.Secret.t | Pending of t | Expired

  let timestamp_add seconds now = Int64.add now (Int64.of_int seconds)
  let challenge t = t.challenge
  let expires_in t = t.schedule.expires_in

  let next_poll_delay_s ~now t =
    let delay = Int64.sub t.schedule.next_poll_after now in
    if Int64.compare delay 0L <= 0 then 0
    else if Int64.compare delay (Int64.of_int max_int) > 0 then max_int
    else Int64.to_int delay

  let with_next_poll ~now t =
    {
      t with
      schedule =
        {
          t.schedule with
          next_poll_after = timestamp_add t.schedule.interval now;
        };
    }

  let with_slow_down ~now t =
    let interval = t.schedule.interval + 5 in
    {
      t with
      schedule =
        {
          t.schedule with
          interval;
          next_poll_after = timestamp_add interval now;
        };
    }

  let start_oauth2 ~http ~sw ~now ~client ~device_endpoint ~token_endpoint
      ~scope ~extra =
    match
      Oauth2.Device.request ~client ~endpoint:device_endpoint ~scope ~extra ()
    with
    | Error (`Reserved name) ->
        Error (Error.Invalid_request ("reserved OAuth parameter: " ^ name))
    | Ok request -> (
        match Http.send http ~sw request with
        | Ok device ->
            let interval = Oauth2.Device.interval device in
            let expires_in = Oauth2.Device.expires_in device in
            let expires_at = timestamp_add expires_in now in
            Log.info (fun m ->
                m "device flow started expires_at=%Ld interval=%d" expires_at
                  interval);
            Ok
              {
                schedule =
                  {
                    expires_at;
                    expires_in;
                    interval;
                    next_poll_after = timestamp_add interval now;
                  };
                challenge =
                  {
                    verification_uri = Oauth2.Device.verification_uri device;
                    verification_uri_complete =
                      Oauth2.Device.verification_uri_complete device;
                    user_code = Oauth2.Device.user_code device;
                  };
                transport = Oauth2 { device; client; token_endpoint };
              }
        | Error error -> Error (Http.send_error error))

  let expired_code code =
    String.equal code "expired_token"
    || String.equal code "expired_device_code"
    || String.equal code "device_expired"

  let poll_oauth2 ~http ~sw ~now t device client token_endpoint =
    let grant = Oauth2.Grant.device_code device in
    match
      Oauth2.Grant.request ~client ~endpoint:token_endpoint grant
      |> Http.send http ~sw
    with
    | Ok token ->
        Log.info (fun m -> m "device authorization completed");
        let* secret = OAuth_secret.oauth_token ~now token in
        Ok (Authorized secret)
    | Error (Http.OAuth (`Oauth error)) -> (
        match Oauth2.Device.classify_poll_error error with
        | `Authorization_pending ->
            Log.debug (fun m -> m "device poll pending");
            Ok (Pending (with_next_poll ~now t))
        | `Slow_down ->
            Log.debug (fun m -> m "device poll slow_down, backing off");
            Ok (Pending (with_slow_down ~now t))
        | `Other error when expired_code (Oauth2.Error.code error) ->
            Log.info (fun m -> m "device code expired");
            Ok Expired
        | `Other _ -> Error (Error.Rejected "device authorization rejected"))
    | Error error -> Error (Http.send_error error)

  type user_code_response = {
    parsed_device_auth_id : string;
    parsed_user_code : string;
    parsed_expires_in : int;
    parsed_interval : int;
  }

  let user_code json =
    let* user_code =
      Oauth2.Json.optional "user_code" Openai_chatgpt.non_empty_string json
    in
    match user_code with
    | Some value -> Ok value
    | None -> (
        let* alt =
          Oauth2.Json.optional "usercode" Openai_chatgpt.non_empty_string json
        in
        match alt with
        | Some value -> Ok value
        | None ->
            Error
              (Openai_chatgpt.malformed ~field:"user_code"
                 "missing required field"))

  let parse_user_code config json =
    let* device_auth_id =
      Oauth2.Json.required "device_auth_id" Openai_chatgpt.non_empty_string json
    in
    let* user_code = user_code json in
    let* expires_in =
      Oauth2.Json.optional "expires_in" Openai_chatgpt.non_negative_int_string
        json
    in
    let* interval =
      Oauth2.Json.optional "interval" Openai_chatgpt.non_negative_int_string
        json
    in
    Ok
      {
        parsed_device_auth_id = device_auth_id;
        parsed_user_code = user_code;
        parsed_expires_in =
          Option.value expires_in
            ~default:(Openai_chatgpt.Config.expires_in config);
        parsed_interval =
          Option.value interval
            ~default:(Openai_chatgpt.Config.poll_interval config);
      }

  let start_openai_chatgpt ~http ~sw ~now config =
    let body =
      Openai_chatgpt.Json.object'
        [
          Openai_chatgpt.Json.mem "client_id"
            (Openai_chatgpt.Json.string
               (Openai_chatgpt.Config.client_id config));
        ]
    in
    let* response =
      Openai_chatgpt.post_json http ~sw
        ~uri:(Openai_chatgpt.Config.user_code_endpoint config)
        body
    in
    let* parsed =
      Openai_chatgpt.decode_success_json (parse_user_code config) response
    in
    let expires_at = timestamp_add parsed.parsed_expires_in now in
    Log.info (fun m ->
        m "chatgpt device flow started expires_at=%Ld interval=%d" expires_at
          parsed.parsed_interval);
    Ok
      {
        schedule =
          {
            expires_at;
            expires_in = parsed.parsed_expires_in;
            interval = parsed.parsed_interval;
            next_poll_after = timestamp_add parsed.parsed_interval now;
          };
        challenge =
          {
            verification_uri = Openai_chatgpt.Config.verification_uri config;
            verification_uri_complete = None;
            user_code = parsed.parsed_user_code;
          };
        transport =
          Openai { config; device_auth_id = parsed.parsed_device_auth_id };
      }

  let poll_openai ~http ~sw ~now t ~config ~device_auth_id =
    let body =
      Openai_chatgpt.Json.object'
        [
          Openai_chatgpt.Json.mem "device_auth_id"
            (Openai_chatgpt.Json.string device_auth_id);
          Openai_chatgpt.Json.mem "user_code"
            (Openai_chatgpt.Json.string t.challenge.user_code);
        ]
    in
    let* response =
      Openai_chatgpt.post_json http ~sw
        ~uri:(Openai_chatgpt.Config.device_token_endpoint config)
        body
    in
    match response.Oauth2.Response.status with
    | 403 | 404 ->
        Log.debug (fun m -> m "chatgpt device poll pending");
        Ok (Pending (with_next_poll ~now t))
    | _ when Oauth2.Response.is_success response ->
        let* code =
          match Oauth2.Response.json response with
          | Error malformed ->
              Error (Openai_chatgpt.protocol_malformed malformed)
          | Ok json ->
              Result.map_error Openai_chatgpt.protocol_malformed
                (Openai_chatgpt.parse_code_exchange json)
        in
        let* secret =
          Openai_chatgpt.exchange_authorization_code http ~sw ~now config code
        in
        Log.info (fun m -> m "chatgpt device authorization completed");
        Ok (Authorized secret)
    | _ -> Openai_chatgpt.decode_oauth_or_http response

  let poll ~http ~sw ~now t =
    if Int64.compare now t.schedule.expires_at >= 0 then (
      Log.info (fun m -> m "device code expired");
      Ok Expired)
    else
      match t.transport with
      | Oauth2 { device; client; token_endpoint } ->
          poll_oauth2 ~http ~sw ~now t device client token_endpoint
      | Openai { config; device_auth_id } ->
          poll_openai ~http ~sw ~now t ~config ~device_auth_id
end
