(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap

type observed_request = {
  resource : string;
  content_type : string option;
  body : string;
}

let max_test_body_bytes = 2_097_152
let string_of_error error = Format.asprintf "%a" Oauth2_eio.Error.pp error

let string_of_transport error =
  Format.asprintf "%a" Oauth2_eio.Error.pp_transport error

let read_body body =
  Eio.Buf_read.(of_flow ~max_size:max_test_body_bytes body |> take_all)

let header_value headers name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    headers

let request_content_type request =
  Http.Header.get (Http.Request.headers request) "content-type"

let respond_string ?(headers = []) ~status ~body () =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list headers)
    ~status ~body ()

let with_server env callback f =
  Eio.Switch.run @@ fun sw ->
  let stop, stop_resolver = Eio.Promise.create () in
  let server_error = ref None in
  let socket =
    Eio.Net.listen env#net ~sw ~backlog:16 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let server =
    Cohttp_eio.Server.make
      ~callback:(fun conn request body ->
        ignore conn;
        callback request body)
      ()
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run ~stop
        ~on_error:(fun exn -> server_error := Some exn)
        socket server;
      `Stop_daemon);
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (address, port) ->
        ignore address;
        port
    | `Unix path -> failf "expected TCP listening socket, got Unix path %S" path
  in
  let base_uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d" port) in
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve stop_resolver ();
      match !server_error with None -> () | Some exn -> raise exn)
    (fun () -> f ~sw ~base_uri)

let check_observed expected = function
  | None -> failf "server did not observe a request"
  | Some observed -> expected observed

let client env = Oauth2_eio.make_client env#net

type tls_body_fault = Peer_alert | Peer_failure

let tls_body_fault_client fault =
  let module Flow = struct
    type tag = [ `Generic ]
    type t = { mutable response : string option; fault : tls_body_fault }

    let read_methods = []

    let single_read t buffer =
      match t.response with
      | Some response ->
          t.response <- None;
          let count = min (String.length response) (Cstruct.length buffer) in
          Cstruct.blit_from_string response 0 buffer 0 count;
          count
      | None -> (
          match t.fault with
          | Peer_alert -> raise (Tls_eio.Tls_alert Tls.Packet.HANDSHAKE_FAILURE)
          | Peer_failure ->
              raise
                (Tls_eio.Tls_failure
                   (`Fatal (`Decode "LEAKMARKER-tls-body-failure"))))

    let single_write _ buffers =
      List.fold_left
        (fun total buffer -> total + Cstruct.length buffer)
        0 buffers

    let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
    let shutdown _ _ = ()
    let close _ = ()
    let setsockopt _ _ _ = failwith "setsockopt: unused"
    let getsockopt _ _ = failwith "getsockopt: unused"
  end in
  let handler = Eio.Net.Pi.stream_socket (module Flow) in
  Cohttp_eio.Client.make_generic (fun ~sw:_ _uri ->
      let response = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n" in
      Eio.Resource.T ({ Flow.response = Some response; fault }, handler))

let with_early_close_peer env f =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen env#net ~sw ~backlog:1 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> failf "expected TCP listening socket, got Unix path %S" path
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Switch.run @@ fun connection_sw ->
      let flow, _ = Eio.Net.accept ~sw:connection_sw socket in
      Eio.Flow.close flow;
      `Stop_daemon);
  f ~sw (Uri.of_string (Printf.sprintf "https://127.0.0.1:%d/token" port))

let token_request endpoint =
  let oauth_client = Oauth2.Client.make ~id:"mentat-client" () in
  let grant = Oauth2.Grant.client_credentials () in
  Oauth2.Grant.request ~client:oauth_client ~endpoint grant

let test_post_preserves_response_and_sets_form_content_type env () =
  let observed = ref None in
  with_server env
    (fun request body ->
      observed :=
        Some
          {
            resource = Http.Request.resource request;
            content_type = request_content_type request;
            body = read_body body;
          };
      respond_string
        ~headers:[ ("x-oauth2-test", "preserved") ]
        ~status:`Accepted ~body:"preserved body" ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/post" in
      match
        Oauth2_eio.post (client env) ~sw ~uri ~body:"grant_type=test" ()
      with
      | Error error -> failf "%s" (string_of_transport error)
      | Ok response ->
          equal int ~msg:"status" 202 response.Oauth2.Response.status;
          equal (option string) ~msg:"response header" (Some "preserved")
            (header_value response.Oauth2.Response.headers "x-oauth2-test");
          equal string ~msg:"response body" "preserved body"
            response.Oauth2.Response.body);
  check_observed
    (fun request ->
      equal string ~msg:"resource" "/post" request.resource;
      equal (option string) ~msg:"content type"
        (Some "application/x-www-form-urlencoded") request.content_type;
      equal string ~msg:"request body" "grant_type=test" request.body)
    !observed

let test_post_preserves_caller_content_type env () =
  let observed = ref None in
  with_server env
    (fun request body ->
      observed :=
        Some
          {
            resource = Http.Request.resource request;
            content_type = request_content_type request;
            body = read_body body;
          };
      respond_string ~status:`OK ~body:"{}" ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/json" in
      match
        Oauth2_eio.post (client env) ~sw ~uri
          ~headers:[ ("Content-Type", "application/json") ]
          ~body:{|{"grant_type":"test"}|} ()
      with
      | Error error -> failf "%s" (string_of_transport error)
      | Ok response ->
          equal int ~msg:"status" 200 response.Oauth2.Response.status);
  check_observed
    (fun request ->
      equal string ~msg:"resource" "/json" request.resource;
      equal (option string) ~msg:"content type" (Some "application/json")
        request.content_type;
      equal string ~msg:"request body" {|{"grant_type":"test"}|} request.body)
    !observed

let test_post_rejects_oversized_body env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:(String.make 1_048_577 'x') ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/large" in
      match
        Oauth2_eio.post (client env) ~sw ~uri ~body:"grant_type=test" ()
      with
      | Error `Response_body_read_failed -> ()
      | Error error ->
          failf "expected response-body failure, got %s"
            (string_of_transport error)
      | Ok response ->
          failf "expected oversized response failure, got status %d"
            response.Oauth2.Response.status)

let test_post_accepts_exact_response_body_limit env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:(String.make 16 'x') ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/exact" in
      match
        Oauth2_eio.post (client env) ~sw ~max_response_body_size:16 ~uri
          ~body:"grant_type=test" ()
      with
      | Error error -> failf "%s" (string_of_transport error)
      | Ok response ->
          equal int ~msg:"exact response size" 16
            (String.length response.Oauth2.Response.body))

let test_post_rejects_negative_response_body_limit env () =
  let observed = ref false in
  with_server env
    (fun request body ->
      observed := true;
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:"unreachable" ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/negative-limit" in
      match
        Oauth2_eio.post (client env) ~sw ~max_response_body_size:(-1) ~uri
          ~body:"grant_type=test" ()
      with
      | exception Invalid_argument _ ->
          is_false ~msg:"negative response limit does not send request"
            !observed
      | Error error ->
          failf "expected Invalid_argument, got %s" (string_of_transport error)
      | Ok response ->
          failf "expected negative limit failure, got status %d"
            response.Oauth2.Response.status)

let test_post_reraises_cancellation env () =
  let accepted, accepted_resolver = Eio.Promise.create () in
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      ignore (Eio.Promise.try_resolve accepted_resolver ());
      Eio.Fiber.await_cancel ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/slow" in
      let cancel_context, cancel_context_resolver = Eio.Promise.create () in
      let result =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Cancel.sub @@ fun cancel_context ->
            Eio.Promise.resolve cancel_context_resolver cancel_context;
            Oauth2_eio.post (client env) ~sw ~uri ~body:"grant_type=test" ())
      in
      Eio.Promise.await accepted;
      Eio.Cancel.cancel
        (Eio.Promise.await cancel_context)
        (Failure "test cancellation");
      match Eio.Promise.await_exn result with
      | exception Eio.Cancel.Cancelled _ -> ()
      | Error error ->
          failf "cancellation was wrapped as transport error: %s"
            (string_of_transport error)
      | Ok response ->
          failf "expected cancellation, got status %d"
            response.Oauth2.Response.status)

let test_post_lowers_resolver_failure_without_payload env () =
  Eio.Switch.run @@ fun sw ->
  let marker = String.make 64 'a' in
  let uri = Uri.of_string ("http://" ^ marker ^ ".invalid/token") in
  match
    Oauth2_eio.post (client env) ~sw ~uri ~body:"LEAKMARKER-request-body" ()
  with
  | Error `Network_unavailable ->
      let rendered = string_of_transport `Network_unavailable in
      is_false ~msg:"resolver diagnostics carry no request or host payload"
        (String.includes ~affix:"LEAKMARKER" rendered
        || String.includes ~affix:marker rendered)
  | Error error ->
      failf "expected network-unavailable, got %s" (string_of_transport error)
  | Ok response ->
      failf "expected resolver failure, got status %d"
        response.Oauth2.Response.status

let test_post_lowers_tls_body_failures env () =
  Eio.Time.with_timeout_exn env#clock 1.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  List.iter
    (fun fault ->
      match
        Oauth2_eio.post
          (tls_body_fault_client fault)
          ~sw
          ~uri:(Uri.of_string "http://provider.example/token")
          ~body:"grant_type=test" ()
      with
      | Error `Network_unavailable -> ()
      | Error error ->
          failf "expected network-unavailable, got %s"
            (string_of_transport error)
      | Ok response ->
          failf "expected TLS body failure, got status %d"
            response.Oauth2.Response.status)
    [ Peer_alert; Peer_failure ]

let test_post_lowers_tls_handshake_close env () =
  with_early_close_peer env @@ fun ~sw uri ->
  let client =
    match Oauth2_eio.make_tls_client env#net with
    | Ok client -> client
    | Error `System_ca_unavailable -> failf "system CAs unavailable"
    | Error `Tls_configuration_failed -> failf "TLS configuration failed"
  in
  match Oauth2_eio.post client ~sw ~uri ~body:"grant_type=test" () with
  | Error `Network_unavailable -> ()
  | Error error ->
      failf "expected network-unavailable, got %s" (string_of_transport error)
  | Ok response ->
      failf "expected early handshake close, got status %d"
        response.Oauth2.Response.status

let test_pp_error_redacts_http_body () =
  let response =
    {
      Oauth2.Response.status = 400;
      Oauth2.Response.headers = [ ("Content-Type", "LEAKMARKER-content-type") ];
      Oauth2.Response.body = {|{"access_token":"secret-token"}|};
    }
  in
  let rendered = string_of_error (`Http response) in
  is_true ~msg:"status is printed" (String.includes ~affix:"400" rendered);
  is_true ~msg:"body length is printed"
    (String.includes ~affix:"body length" rendered);
  is_false ~msg:"provider-controlled content type is redacted"
    (String.includes ~affix:"LEAKMARKER" rendered);
  is_false ~msg:"token body is redacted"
    (String.includes ~affix:"secret-token" rendered);
  is_false ~msg:"raw body shape is redacted"
    (String.includes ~affix:"access_token" rendered)

let test_pp_error_redacts_provider_oauth_details () =
  let marker = "LEAKMARKER-provider-oauth-detail" in
  let error =
    Oauth2.Error.make ~code:marker ~description:marker
      ~uri:(Uri.of_string ("https://provider.example/" ^ marker))
      ()
  in
  let rendered = string_of_error (`Oauth error) in
  equal string ~msg:"OAuth rejection is categorical"
    "OAuth request rejected by provider" rendered;
  is_false ~msg:"provider-controlled OAuth fields are absent"
    (String.includes ~affix:marker rendered)

let test_send_decodes_success env () =
  with_server env
    (fun request body ->
      equal string ~msg:"token path" "/token" (Http.Request.resource request);
      equal string ~msg:"token body"
        "client_id=mentat-client&grant_type=client_credentials" (read_body body);
      respond_string ~status:`OK
        ~body:
          {|{"access_token":"access-123","token_type":"Bearer","expires_in":3600,"scope":"repo user"}|}
        ())
    (fun ~sw ~base_uri ->
      let request = token_request (Uri.with_path base_uri "/token") in
      match Oauth2_eio.send (client env) ~sw request with
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error)
      | Ok token ->
          equal string ~msg:"access token" "access-123"
            (Oauth2.Token.access_token token);
          equal string ~msg:"token type" "Bearer"
            (Oauth2.Token.token_type token);
          equal (option int) ~msg:"expires in" (Some 3600)
            (Oauth2.Token.expires_in token);
          equal
            (option (list string))
            ~msg:"scope"
            (Some [ "repo"; "user" ])
            (Oauth2.Token.scope token))

let test_send_forwards_basic_auth_header env () =
  with_server env
    (fun request body ->
      equal string ~msg:"token path" "/token" (Http.Request.resource request);
      equal (option string) ~msg:"authorization header"
        (Some "Basic YmFzaWMtY2xpZW50OmJhc2ljLXNlY3JldA==")
        (Http.Header.get (Http.Request.headers request) "authorization");
      let body = read_body body in
      is_false ~msg:"client id omitted from basic body"
        (String.includes ~affix:"client_id" body);
      is_false ~msg:"client secret omitted from basic body"
        (String.includes ~affix:"client_secret" body);
      equal string ~msg:"token body" "grant_type=client_credentials" body;
      respond_string ~status:`OK
        ~body:{|{"access_token":"access-123","token_type":"Bearer"}|} ())
    (fun ~sw ~base_uri ->
      let oauth_client =
        Oauth2.Client.make ~id:"basic-client"
          ~auth:(`Secret_basic "basic-secret") ()
      in
      let request =
        Oauth2.Grant.client_credentials ()
        |> Oauth2.Grant.request ~client:oauth_client
             ~endpoint:(Uri.with_path base_uri "/token")
      in
      match Oauth2_eio.send (client env) ~sw request with
      | Ok token ->
          equal string ~msg:"access token" "access-123"
            (Oauth2.Token.access_token token)
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error))

let test_send_maps_oauth_error_before_http env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`Bad_request
        ~body:
          {|{"error":"invalid_grant","error_description":"authorization code expired"}|}
        ())
    (fun ~sw ~base_uri ->
      let request = token_request (Uri.with_path base_uri "/token") in
      match Oauth2_eio.send (client env) ~sw request with
      | Error (`Oauth error) ->
          equal string ~msg:"oauth code" "invalid_grant"
            (Oauth2.Error.code error);
          equal (option string) ~msg:"oauth description"
            (Some "authorization code expired")
            (Oauth2.Error.description error)
      | Error (`Http response) ->
          failf "expected OAuth error before HTTP %d"
            response.Oauth2.Response.status
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error)
      | Ok _token -> failf "expected OAuth error")

let test_send_maps_malformed_success_json env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:{|{"token_type":"Bearer"}|} ())
    (fun ~sw ~base_uri ->
      let request = token_request (Uri.with_path base_uri "/token") in
      match Oauth2_eio.send (client env) ~sw request with
      | Error (`Malformed malformed) ->
          equal (option string) ~msg:"malformed field" (Some "access_token")
            malformed.Oauth2.field
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error)
      | Ok _token -> failf "expected malformed token response")

let revocation token = Oauth2.Revocation.make ~token ()

let test_revoke_success_and_http_error env () =
  let oauth_client = Oauth2.Client.make ~id:"mentat-client" () in
  with_server env
    (fun request body ->
      equal string ~msg:"revocation success path" "/revoke-ok"
        (Http.Request.resource request);
      equal string ~msg:"revocation success body"
        "client_id=mentat-client&token=token-ok" (read_body body);
      respond_string ~status:`No_content ~body:"" ())
    (fun ~sw ~base_uri ->
      let endpoint = Uri.with_path base_uri "/revoke-ok" in
      match
        Oauth2.Revocation.request ~client:oauth_client ~endpoint
          (revocation "token-ok")
        |> Oauth2_eio.send (client env) ~sw
      with
      | Ok () -> ()
      | Error error ->
          failf "unexpected revoke error: %s" (string_of_error error));
  with_server env
    (fun request body ->
      equal string ~msg:"revocation error path" "/revoke-error"
        (Http.Request.resource request);
      equal string ~msg:"revocation error body"
        "client_id=mentat-client&token=token-error" (read_body body);
      respond_string ~status:`Internal_server_error ~body:"plain failure" ())
    (fun ~sw ~base_uri ->
      let endpoint = Uri.with_path base_uri "/revoke-error" in
      match
        Oauth2.Revocation.request ~client:oauth_client ~endpoint
          (revocation "token-error")
        |> Oauth2_eio.send (client env) ~sw
      with
      | Error (`Http response) ->
          equal int ~msg:"status" 500 response.Oauth2.Response.status;
          equal string ~msg:"body" "plain failure" response.Oauth2.Response.body
      | Error error ->
          failf "unexpected revoke error: %s" (string_of_error error)
      | Ok () -> failf "expected HTTP revocation error")

let test_device_authorization_reserved_extra_is_pure_error env () =
  ignore env;
  let oauth_client = Oauth2.Client.make ~id:"mentat-client" () in
  let endpoint = Uri.of_string "http://127.0.0.1:1/device" in
  let extra = [ ("client_id", "conflict") ] in
  match Oauth2.Device.request ~client:oauth_client ~endpoint ~extra () with
  | Error (`Reserved name) ->
      equal string ~msg:"reserved parameter" "client_id" name
  | Ok _request -> failf "expected invalid request"

(* The loopback redirect listener. Each test binds an ephemeral port first,
   then aims the listener at it; the browser's dial is a plain [post] against
   the same loopback, so the listener's answers are asserted as raw
   responses. *)

let free_port env =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen env#net ~sw ~backlog:1 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> port
  | `Unix path -> failf "expected TCP listening socket, got Unix path %S" path

let string_of_loopback_error error =
  Format.asprintf "%a" Oauth2_eio.Loopback.pp_error error

(* Dial each target in order once the listener is ready, recording the raw
   answers; the requests ride [on_ready] so no request can race the bind,
   and [join] holds the test until the last answer is read — the listener
   settles the moment it accepts a callback, before the browser's fiber has
   necessarily read the final page. *)
let dialing env sw targets =
  let answers = ref [] in
  let http = client env in
  let finished, finish = Eio.Promise.create () in
  let on_ready () =
    Eio.Fiber.fork ~sw (fun () ->
        List.iter
          (fun target ->
            match
              Oauth2_eio.post http ~sw ~uri:(Uri.of_string target) ~body:"" ()
            with
            | Ok response -> answers := response :: !answers
            | Error error ->
                failf "loopback dial failed: %s" (string_of_transport error))
          targets;
        Eio.Promise.resolve finish ())
  in
  let join () = Eio.Promise.await finished in
  (answers, join, on_ready)

let test_loopback_grant_round_trip env () =
  Eio.Switch.run @@ fun sw ->
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  let answers, join, on_ready =
    dialing env sw
      [
        Printf.sprintf "http://127.0.0.1:%d/callback?code=abc&state=s1" port;
      ]
  in
  match
    Oauth2_eio.Loopback.await_once ~net:env#net ~clock:env#clock ~on_ready
      ~redirect_uri ~timeout_s:5.0 ()
  with
  | Error error -> failf "await_once: %s" (string_of_loopback_error error)
  | Ok callback -> (
      join ();
      equal (option string) ~msg:"the callback carries the code" (Some "abc")
        (Uri.get_query_param callback "code");
      equal (option string) ~msg:"the callback carries the state" (Some "s1")
        (Uri.get_query_param callback "state");
      equal string ~msg:"the callback keeps the redirect URI's authority"
        (Printf.sprintf "http://127.0.0.1:%d/callback" port)
        (Uri.to_string (Uri.with_query callback []));
      match !answers with
      | [ response ] ->
          equal int ~msg:"a grant answers 200" 200
            response.Oauth2.Response.status;
          is_true ~msg:"the default page names the grant"
            (let body = response.Oauth2.Response.body in
             let sub = "Authorization received" in
             let n = String.length sub and h = String.length body in
             let rec go i =
               i + n <= h
               && (String.equal (String.sub body i n) sub || go (i + 1))
             in
             go 0)
      | answers -> failf "expected one answer, got %d" (List.length answers))

let contains_sub body sub =
  let n = String.length sub and h = String.length body in
  let rec go i =
    i + n <= h && (String.equal (String.sub body i n) sub || go (i + 1))
  in
  go 0

let test_loopback_denial_settles env () =
  Eio.Switch.run @@ fun sw ->
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  let answers, join, on_ready =
    dialing env sw
      [
        Printf.sprintf
          "http://127.0.0.1:%d/callback?error=access_denied&error_description=nope&state=s1"
          port;
      ]
  in
  match
    Oauth2_eio.Loopback.await_once ~net:env#net ~clock:env#clock ~on_ready
      ~redirect_uri ~timeout_s:5.0 ()
  with
  | Error error -> failf "await_once: %s" (string_of_loopback_error error)
  | Ok callback -> (
      join ();
      equal (option string) ~msg:"the denial is returned, not swallowed"
        (Some "access_denied")
        (Uri.get_query_param callback "error");
      match !answers with
      | [ response ] ->
          equal int ~msg:"a denial still answers 200" 200
            response.Oauth2.Response.status;
          is_true ~msg:"the default page names the denial"
            (contains_sub response.Oauth2.Response.body
               "access_denied: nope")
      | answers -> failf "expected one answer, got %d" (List.length answers))

let test_loopback_unverified_keeps_the_shot env () =
  Eio.Switch.run @@ fun sw ->
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  let answers, join, on_ready =
    dialing env sw
      [
        Printf.sprintf "http://127.0.0.1:%d/callback?code=evil&state=forged"
          port;
        Printf.sprintf "http://127.0.0.1:%d/callback?code=abc&state=s1" port;
      ]
  in
  let accept callback =
    Uri.get_query_param callback "state" = Some "s1"
  in
  match
    Oauth2_eio.Loopback.await_once ~net:env#net ~clock:env#clock ~on_ready
      ~accept ~redirect_uri ~timeout_s:5.0 ()
  with
  | Error error -> failf "await_once: %s" (string_of_loopback_error error)
  | Ok callback -> (
      join ();
      equal (option string)
        ~msg:"the refused callback never consumed the shot" (Some "abc")
        (Uri.get_query_param callback "code");
      match List.rev !answers with
      | [ refused; accepted ] ->
          equal int ~msg:"a refused callback answers 400" 400
            refused.Oauth2.Response.status;
          is_true ~msg:"the refused page says unverified"
            (contains_sub refused.Oauth2.Response.body "verified");
          equal int ~msg:"the accepted callback answers 200" 200
            accepted.Oauth2.Response.status
      | answers -> failf "expected two answers, got %d" (List.length answers))

let test_loopback_serve_seam env () =
  Eio.Switch.run @@ fun sw ->
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  let answers, join, on_ready =
    dialing env sw
      [
        Printf.sprintf "http://127.0.0.1:%d/" port;
        Printf.sprintf "http://127.0.0.1:%d/elsewhere" port;
        Printf.sprintf "http://127.0.0.1:%d/callback?code=abc" port;
      ]
  in
  let serve ~path =
    if String.equal path "/" then Some "<html>entry</html>" else None
  in
  match
    Oauth2_eio.Loopback.await_once ~net:env#net ~clock:env#clock ~on_ready
      ~serve ~redirect_uri ~timeout_s:5.0 ()
  with
  | Error error -> failf "await_once: %s" (string_of_loopback_error error)
  | Ok _ -> (
      join ();
      match List.rev !answers with
      | [ served; missed; _callback ] ->
          equal int ~msg:"a served page answers 200" 200
            served.Oauth2.Response.status;
          equal string ~msg:"the served page is the caller's"
            "<html>entry</html>" served.Oauth2.Response.body;
          equal int ~msg:"an unserved path answers 404" 404
            missed.Oauth2.Response.status
      | answers ->
          failf "expected three answers, got %d" (List.length answers))

let test_loopback_custom_respond env () =
  Eio.Switch.run @@ fun sw ->
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  let answers, join, on_ready =
    dialing env sw
      [ Printf.sprintf "http://127.0.0.1:%d/callback?code=abc" port ]
  in
  let respond = function
    | Oauth2_eio.Loopback.Granted -> "<html>branded</html>"
    | Oauth2_eio.Loopback.Denied _ | Oauth2_eio.Loopback.Unverified
    | Oauth2_eio.Loopback.Not_found ->
        "<html>other</html>"
  in
  match
    Oauth2_eio.Loopback.await_once ~net:env#net ~clock:env#clock ~on_ready
      ~respond ~redirect_uri ~timeout_s:5.0 ()
  with
  | Error error -> failf "await_once: %s" (string_of_loopback_error error)
  | Ok _ -> (
      join ();
      match !answers with
      | [ response ] ->
          equal string ~msg:"the injected page is served"
            "<html>branded</html>" response.Oauth2.Response.body
      | answers -> failf "expected one answer, got %d" (List.length answers))

let test_loopback_times_out env () =
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  match
    Oauth2_eio.Loopback.await_once ~net:env#net ~clock:env#clock
      ~redirect_uri ~timeout_s:0.05 ()
  with
  | Error `Timed_out -> ()
  | Error error -> failf "await_once: %s" (string_of_loopback_error error)
  | Ok _ -> failf "expected a timeout"

let test_loopback_refuses_bad_redirect_uris env () =
  let refuse uri =
    match
      Oauth2_eio.Loopback.await_once ~net:env#net ~clock:env#clock
        ~redirect_uri:(Uri.of_string uri) ~timeout_s:1.0 ()
    with
    | Error (`Invalid_redirect_uri _) -> ()
    | Error error ->
        failf "%s: unexpected error %s" uri (string_of_loopback_error error)
    | Ok _ -> failf "%s: expected a refusal" uri
  in
  refuse "http://127.0.0.1/callback";
  refuse "http://example.com:8917/callback";
  refuse "http:///callback"

let with_eio test () = Eio_main.run @@ fun env -> test env ()

let () =
  run "oauth2.eio"
    [
      group "post"
        [
          test ~timeout:3.0 "preserves raw response and default content type"
            (with_eio test_post_preserves_response_and_sets_form_content_type);
          test ~timeout:3.0 "preserves caller content type"
            (with_eio test_post_preserves_caller_content_type);
          test ~timeout:3.0 "rejects oversized response body"
            (with_eio test_post_rejects_oversized_body);
          test ~timeout:3.0 "accepts exact response body limit"
            (with_eio test_post_accepts_exact_response_body_limit);
          test ~timeout:3.0 "rejects negative response body limit"
            (with_eio test_post_rejects_negative_response_body_limit);
          test ~timeout:3.0 "re-raises cancellation"
            (with_eio test_post_reraises_cancellation);
          test ~timeout:3.0 "lowers DNS resolver failure without payload"
            (with_eio test_post_lowers_resolver_failure_without_payload);
          test ~timeout:3.0 "lowers TLS peer failures while reading the body"
            (with_eio test_post_lowers_tls_body_failures);
          test ~timeout:3.0 "lowers an early TLS handshake close"
            (with_eio test_post_lowers_tls_handshake_close);
        ];
      group "errors"
        [
          test "redacts HTTP body in pretty-printer"
            test_pp_error_redacts_http_body;
          test "redacts provider OAuth fields in pretty-printer"
            test_pp_error_redacts_provider_oauth_details;
        ];
      group "send"
        [
          test ~timeout:3.0 "decodes successful pure request"
            (with_eio test_send_decodes_success);
          test ~timeout:3.0 "forwards request headers"
            (with_eio test_send_forwards_basic_auth_header);
          test ~timeout:3.0 "maps OAuth JSON error before HTTP"
            (with_eio test_send_maps_oauth_error_before_http);
          test ~timeout:3.0 "maps malformed success JSON"
            (with_eio test_send_maps_malformed_success_json);
        ];
      group "standard requests"
        [
          test ~timeout:3.0 "revoke handles success and HTTP error"
            (with_eio test_revoke_success_and_http_error);
          test ~timeout:3.0
            "device authorization rejects reserved extra before transport"
            (with_eio test_device_authorization_reserved_extra_is_pure_error);
        ];
      group "loopback"
        [
          test ~timeout:10.0 "a granted callback round-trips"
            (with_eio test_loopback_grant_round_trip);
          test ~timeout:10.0 "a provider denial settles the shot"
            (with_eio test_loopback_denial_settles);
          test ~timeout:10.0 "an unaccepted callback keeps the shot"
            (with_eio test_loopback_unverified_keeps_the_shot);
          test ~timeout:10.0 "the serve seam answers off-path requests"
            (with_eio test_loopback_serve_seam);
          test ~timeout:10.0 "an injected respond replaces the pages"
            (with_eio test_loopback_custom_respond);
          test ~timeout:10.0 "the wait expires loudly"
            (with_eio test_loopback_times_out);
          test ~timeout:3.0 "malformed redirect URIs refuse"
            (with_eio test_loopback_refuses_bad_redirect_uris);
        ];
    ]
