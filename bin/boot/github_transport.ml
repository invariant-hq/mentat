(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The production requester: one connection per request under its own switch,
   the response read whole under the body bound before the switch closes.
   Non-cancellation exceptions classify through [Mentat_llm_http], whose
   messages are display-safe and never carry request headers. *)
let requester client : Github.Api.http =
 fun ~meth ~url ~headers ~body ->
  let meth =
    match meth with `GET -> `GET | `PATCH -> `PATCH | `POST -> `POST
  in
  try
    Eio.Switch.run ~name:"github-api" @@ fun sw ->
    let headers = Cohttp.Header.of_list headers in
    let body = Option.map Cohttp_eio.Body.of_string body in
    let response, body_flow =
      Cohttp_eio.Client.call client ~sw ~headers ?body meth
        (Uri.of_string url)
    in
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    let response_headers =
      Cohttp.Header.to_list (Cohttp.Response.headers response)
    in
    match
      Eio.Buf_read.(parse take_all)
        ~max_size:(Github.Api.max_body_bytes + 1)
        body_flow
    with
    | Ok body ->
        Ok { Github.Api.status; headers = response_headers; body }
    | Error (`Msg reason) ->
        Error
          (Github.Api.Error.transport
             (Printf.sprintf "%s: response body read failed: %s" url reason))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> (
      match Mentat_llm_http.error_of_exn exn with
      | Mentat_llm_http.Unresolved_host reason
      | Mentat_llm_http.Transport reason ->
          Error (Github.Api.Error.transport reason)
      (* [error_of_exn] never mints [Response]; the arm keeps the match
         total. *)
      | Mentat_llm_http.Response _ ->
          Error
            (Github.Api.Error.transport
               (Mentat_llm_http.transport_message exn)))

let make ?base_url ?token net =
  match Oauth2_eio.make_tls_client net with
  | Error `System_ca_unavailable ->
      Error (Github.Api.Error.transport "system CA bundle unavailable")
  | Error `Tls_configuration_failed ->
      Error (Github.Api.Error.transport "TLS client configuration failed")
  | Ok client ->
      Ok
        (Github.Api.of_http ?base_url ~user_agent:"mentat" ?token
           (requester client))
