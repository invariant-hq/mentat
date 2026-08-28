(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "mentat.oauth2" ~doc:"OAuth 2.0 Eio transport"

module Log = (val Logs.src_log log_src : Logs.LOG)

type response = Oauth2.Response.t

module Error = struct
  type transport =
    [ `Network_unavailable
    | `Invalid_endpoint_identity
    | `Response_body_read_failed ]

  type t = [ Oauth2.Response.decode_error | `Transport of transport ]

  let pp_transport fmt = function
    | `Network_unavailable ->
        Format.pp_print_string fmt "network transport unavailable"
    | `Invalid_endpoint_identity ->
        Format.pp_print_string fmt "invalid HTTPS endpoint identity"
    | `Response_body_read_failed ->
        Format.pp_print_string fmt "OAuth response body could not be read"

  let pp fmt = function
    | `Transport e -> pp_transport fmt e
    | `Oauth _ ->
        Format.pp_print_string fmt "OAuth request rejected by provider"
    | `Malformed _ -> Format.pp_print_string fmt "malformed OAuth response"
    | `Http response ->
        Format.fprintf fmt "HTTP error %d: body length %d"
          response.Oauth2.Response.status
          (String.length response.Oauth2.Response.body)
end

let has_header name headers =
  List.exists
    (fun header ->
      let key = fst header in
      String.equal (String.lowercase_ascii key) name)
    headers

let form_headers headers =
  if has_header "content-type" headers then headers
  else ("Content-Type", "application/x-www-form-urlencoded") :: headers

let default_max_response_body_size = 1_048_576

let response_body ~max_response_body_size body =
  let max_size =
    if max_response_body_size = max_int then max_int
    else max_response_body_size + 1
  in
  match Eio.Buf_read.(parse take_all) ~max_size body with
  | Ok body -> Ok body
  | Error (`Msg _) -> Error `Response_body_read_failed

let read_response_body ~max_response_body_size body =
  match response_body ~max_response_body_size body with
  | result -> result
  | exception (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) ->
      Error `Network_unavailable

exception Invalid_endpoint_identity

let transport_error ~host error =
  let reason =
    match error with
    | `Network_unavailable -> "network-unavailable"
    | `Invalid_endpoint_identity -> "invalid-endpoint-identity"
    | `Response_body_read_failed -> "response-body-read-failed"
  in
  Log.debug (fun m -> m "oauth request failed host=%s reason=%s" host reason);
  Error error

(* Cohttp-eio currently reports resolver failure through [Failure]. Normalize
   only the dependency call: unrelated failures in request construction,
   response handling, and decoders remain programming faults. *)
let cohttp_post http_client ~sw ~headers ~body uri =
  match Cohttp_eio.Client.post http_client ~sw ~headers ~body uri with
  | response -> Ok response
  | exception
      (Failure _ | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ | End_of_file) ->
      Error `Network_unavailable

let post http_client ~sw
    ?(max_response_body_size = default_max_response_body_size) ~uri
    ?(headers = []) ~body () =
  if max_response_body_size < 0 then
    invalid_arg "OAuth response body limit must not be negative"
  else (
    Eio.Switch.check sw;
    let host = Option.value ~default:"<none>" (Uri.host uri) in
    try
      Eio.Switch.run ~name:"oauth2-post" @@ fun request_sw ->
      let headers = Cohttp.Header.of_list (form_headers headers) in
      let body = Cohttp_eio.Body.of_string body in
      match cohttp_post http_client ~sw:request_sw ~headers ~body uri with
      | Error error -> transport_error ~host error
      | Ok (response, body) -> (
          let status =
            Cohttp.Code.code_of_status (Cohttp.Response.status response)
          in
          let headers =
            Cohttp.Header.to_list (Cohttp.Response.headers response)
          in
          match read_response_body ~max_response_body_size body with
          | Error e -> transport_error ~host e
          | Ok body ->
              Log.info (fun m ->
                  m "oauth request finished host=%s status=%d body_bytes=%d"
                    host status (String.length body));
              Ok
                {
                  Oauth2.Response.status;
                  Oauth2.Response.headers;
                  Oauth2.Response.body;
                })
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Eio.Time.Timeout | Eio.Io _ -> transport_error ~host `Network_unavailable
    | Invalid_endpoint_identity ->
        transport_error ~host `Invalid_endpoint_identity)

let send http_client ~sw ?max_response_body_size request =
  match
    post http_client ~sw ?max_response_body_size
      ~uri:(Oauth2.Request.uri request)
      ~headers:(Oauth2.Request.headers request)
      ~body:(Oauth2.Request.body request)
      ()
  with
  | Error e -> Error (`Transport e)
  | Ok response ->
      Oauth2.Request.decode request response
      |> Result.map_error (fun e -> (e :> Error.t))

type https =
  Uri.t -> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t -> Tls_eio.t

type tls_error = [ `System_ca_unavailable | `Tls_configuration_failed ]

let make_https () =
  Mirage_crypto_rng_unix.use_default ();
  match Ca_certs.authenticator () with
  | Error (`Msg _) -> Error `System_ca_unavailable
  | Ok authenticator -> (
      match Tls.Config.client ~authenticator () with
      | Error (`Msg _) -> Error `Tls_configuration_failed
      | Ok default_tls_config ->
          let tls_config uri =
            match Uri.host uri with
            | None -> raise Invalid_endpoint_identity
            | Some name -> (
                match Ipaddr.of_string name with
                | Ok ip -> (
                    match Tls.Config.client ~authenticator ~ip () with
                    | Ok tls_config -> (tls_config, None)
                    | Error (`Msg _) -> raise Invalid_endpoint_identity)
                | Error _ -> (
                    match Domain_name.of_string name with
                    | Error (`Msg _) -> raise Invalid_endpoint_identity
                    | Ok domain -> (
                        match Domain_name.host domain with
                        | Error (`Msg _) -> raise Invalid_endpoint_identity
                        | Ok host -> (default_tls_config, Some host))))
          in
          let handler uri raw =
            let tls_config, host = tls_config uri in
            Tls_eio.client_of_flow ?host tls_config raw
          in
          Ok handler)

let make_client ?https net = Cohttp_eio.Client.make ~https net

let make_tls_client net =
  match make_https () with
  | Error error -> Error error
  | Ok https -> Ok (make_client ~https net)

module Loopback = struct
  type outcome =
    | Granted
    | Denied of { error : string; description : string option }
    | Unverified
    | Not_found

  type error =
    [ `Invalid_redirect_uri of string
    | `Listener_unavailable
    | `Timed_out ]

  let pp_error fmt = function
    | `Invalid_redirect_uri reason ->
        Format.fprintf fmt "invalid redirect URI: %s" reason
    | `Listener_unavailable ->
        Format.pp_print_string fmt "callback listener unavailable"
    | `Timed_out -> Format.pp_print_string fmt "authorization timed out"

  exception Callback_failed of exn * Printexc.raw_backtrace

  (* The default pages: unbranded single sentences. Every interpolated value
     is HTML-escaped; the callback query is attacker-influenceable. *)
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

  let page ~title body =
    Printf.sprintf
      {|<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="robots" content="noindex"><title>%s</title></head>
<body><p>%s</p></body>
</html>|}
      (html_escape title) body

  let default_respond = function
    | Granted ->
        page ~title:"signed in"
          "Authorization received. Return to the application &mdash; you \
           can close this tab."
    | Denied { error; description } ->
        let detail =
          match description with
          | Some description when not (String.equal description "") ->
              error ^ ": " ^ description
          | Some _ | None -> error
        in
        page ~title:"authorization denied"
          (Printf.sprintf
             "The provider denied the authorization request (%s)."
             (html_escape detail))
    | Unverified ->
        page ~title:"callback not verified"
          "This callback couldn&#39;t be verified. It may be stale or from \
           another sign-in &mdash; run the sign-in again."
    | Not_found ->
        page ~title:"not found"
          "This is a sign-in callback listener. Nothing to do here &mdash; \
           you can close this tab."

  let callback_absolute_uri ~redirect_uri request_uri =
    redirect_uri |> fun uri ->
    Uri.with_path uri (Uri.path request_uri) |> fun uri ->
    Uri.with_query uri (Uri.query request_uri) |> fun uri ->
    Uri.with_fragment uri (Uri.fragment request_uri)

  let callback_port redirect_uri =
    match Uri.port redirect_uri with
    | Some port -> Ok port
    | None ->
        Error
          (`Invalid_redirect_uri "redirect URI must include an explicit port")

  let callback_hosts redirect_uri =
    match Uri.host redirect_uri with
    | Some "127.0.0.1" -> Ok [ Eio.Net.Ipaddr.V4.loopback ]
    | Some "::1" -> Ok [ Eio.Net.Ipaddr.V6.loopback ]
    | Some "localhost" ->
        Ok [ Eio.Net.Ipaddr.V4.loopback; Eio.Net.Ipaddr.V6.loopback ]
    | Some host ->
        Error (`Invalid_redirect_uri ("unsupported redirect host: " ^ host))
    | None -> Error (`Invalid_redirect_uri "redirect URI must include a host")

  let respond_html ~status body =
    Cohttp_eio.Server.respond_string
      ~headers:
        (Cohttp.Header.of_list [ ("Content-Type", "text/html; charset=utf-8") ])
      ~status ~body ()

  let listen_all net sw hosts port =
    let listen host =
      Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true (`Tcp (host, port))
    in
    let rec loop sockets = function
      | [] -> (
          match sockets with
          | [] -> Error `Listener_unavailable
          | _ :: _ -> Ok (List.rev sockets))
      | host :: hosts -> (
          match listen host with
          | socket -> loop (socket :: sockets) hosts
          | exception (Eio.Io _ | Unix.Unix_error _) ->
              Log.debug (fun m -> m "callback host bind failed");
              loop sockets hosts)
    in
    loop [] hosts

  let await_once ~net ~clock ?(on_ready = fun () -> ())
      ?(accept = fun _ -> true) ?(serve = fun ~path:_ -> None)
      ?(respond = default_respond) ~redirect_uri ~timeout_s () =
    let ( let* ) = Result.bind in
    let* hosts = callback_hosts redirect_uri in
    let* port = callback_port redirect_uri in
    Eio.Switch.run ~name:"oauth2-loopback" @@ fun sw ->
    let stop, stop_resolver = Eio.Promise.create () in
    let result, result_resolver = Eio.Promise.create () in
    let server_failure, server_failure_resolver = Eio.Promise.create () in
    let resolve_server_failure exn =
      if not (Eio.Promise.is_resolved result) then
        let failure =
          match exn with
          | Callback_failed (exn, backtrace) -> `Raise (exn, backtrace)
          | Eio.Cancel.Cancelled _ -> `Raise (exn, Printexc.get_raw_backtrace ())
          | Eio.Io _ | Unix.Unix_error _ -> `Network
          | exn -> `Raise (exn, Printexc.get_raw_backtrace ())
        in
        ignore (Eio.Promise.try_resolve server_failure_resolver failure)
    in
    (* [on_ready], [accept], [serve], and [respond] are caller code: a raise
       is a caller fault, carried out of the server fiber with its
       backtrace rather than classified as a listener failure. *)
    let guarded f =
      match f () with
      | value -> value
      | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          raise (Callback_failed (exn, backtrace))
    in
    let accept callback = guarded (fun () -> accept callback) in
    let serve ~path = guarded (fun () -> serve ~path) in
    let respond outcome = guarded (fun () -> respond outcome) in
    let server =
      Cohttp_eio.Server.make
        ~callback:(fun connection request body ->
          ignore connection;
          ignore body;
          let request_uri = Cohttp.Request.uri request in
          if String.equal (Uri.path request_uri) (Uri.path redirect_uri) then
            let callback = callback_absolute_uri ~redirect_uri request_uri in
            if not (accept callback) then (
              Log.info (fun m -> m "unaccepted authorization callback ignored");
              respond_html ~status:`Bad_request (respond Unverified))
            else if Eio.Promise.try_resolve result_resolver (Ok callback) then (
              Log.info (fun m -> m "authorization callback received");
              (* A provider that denies the request still redirects to the
                 callback — with [?error=] in place of a code and a matching
                 state, so it is accepted and settled here as failed. The page
                 must show the denial, not a success. *)
              match Uri.get_query_param callback "error" with
              | Some error when not (String.equal error "") ->
                  respond_html ~status:`OK
                    (respond
                       (Denied
                          {
                            error;
                            description =
                              Uri.get_query_param callback "error_description";
                          }))
              | Some _ | None -> respond_html ~status:`OK (respond Granted))
            else respond_html ~status:`Bad_request (respond Unverified)
          else
            match serve ~path:(Uri.path request_uri) with
            | Some page -> respond_html ~status:`OK page
            | None -> respond_html ~status:`Not_found (respond Not_found))
        ()
    in
    let* sockets = listen_all net sw hosts port in
    List.iter
      (fun socket ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
            (match
               Cohttp_eio.Server.run ~stop ~on_error:resolve_server_failure
                 socket server
             with
            | () -> ()
            | exception exn -> resolve_server_failure exn);
            `Stop_daemon))
      sockets;
    on_ready ();
    Log.info (fun m -> m "local callback server listening port=%d" port);
    Fun.protect
      ~finally:(fun () -> ignore (Eio.Promise.try_resolve stop_resolver ()))
      (fun () ->
        let settled =
          Eio.Fiber.first
            (fun () ->
              `Settled
                (Eio.Fiber.first
                   (fun () -> `Callback (Eio.Promise.await result))
                   (fun () ->
                     `Server_failure (Eio.Promise.await server_failure))))
            (fun () ->
              Eio.Time.sleep clock timeout_s;
              `Timed_out)
        in
        match settled with
        | `Timed_out -> Error `Timed_out
        | `Settled (`Callback callback) -> callback
        | `Settled (`Server_failure `Network) -> Error `Listener_unavailable
        | `Settled (`Server_failure (`Raise (exn, backtrace))) ->
            Printexc.raise_with_backtrace exn backtrace)
end
