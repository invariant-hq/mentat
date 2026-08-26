(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind
let api_version = "2022-11-28"
let max_body_bytes = 8 * 1024 * 1024

(* The stored excerpt of a non-2xx body: short and byte-wise printable ASCII,
   so a server-controlled body can neither spread an error over the terminal
   nor plant bytes a JSON encoder refuses. *)
let excerpt_bytes = 400

let excerpt body =
  let body =
    if String.length body <= excerpt_bytes then body
    else String.sub body 0 excerpt_bytes
  in
  String.map (fun c -> if c >= ' ' && c <= '~' then c else ' ') body

module Error = struct
  type kind =
    | Response of { status : int; body : string }
    | Transport of string
    | Unresolved_host of string

  type t = kind

  let kind t = t

  let message = function
    | Response { status; body } ->
        if String.equal body "" then
          Printf.sprintf "GitHub API responded %d" status
        else Printf.sprintf "GitHub API responded %d: %s" status body
    | Transport reason -> reason
    | Unresolved_host reason -> reason

  let pp ppf t = Format.pp_print_string ppf (message t)
  let transport reason = Transport reason
  let unresolved_host reason = Unresolved_host reason
end

type reply = { status : int; headers : (string * string) list; body : string }

type http =
  meth:[ `GET | `PATCH | `POST ] ->
  url:string ->
  headers:(string * string) list ->
  body:string option ->
  (reply, Error.t) result

type t = { http : http; token : string; base_url : string; base : Uri.t }

let of_http ?(base_url = "https://api.github.com") ~token http =
  let rec strip url =
    if String.length url > 0 && url.[String.length url - 1] = '/' then
      strip (String.sub url 0 (String.length url - 1))
    else url
  in
  let base_url = strip base_url in
  { http; token; base_url; base = Uri.of_string base_url }

let request_headers t ~write =
  ("authorization", "Bearer " ^ t.token)
  :: ("accept", "application/vnd.github+json")
  :: ("x-github-api-version", api_version)
  :: ("user-agent", "mentat")
  ::
  (if write then [ ("content-type", "application/json") ] else [])

let url_of_path t ~path =
  if String.length path = 0 || path.[0] <> '/' then
    invalid_arg
      (Printf.sprintf "GitHub API path must start with '/', got %S" path)
  else t.base_url ^ path

(* The one funnel every verb uses: send, enforce the body bound, and turn a
   non-2xx reply into its [Response] error. *)
let request t ~meth ~url ~write ~body =
  let* reply = t.http ~meth ~url ~headers:(request_headers t ~write) ~body in
  if String.length reply.body > max_body_bytes then
    Error
      (Error.transport
         (Printf.sprintf "%s: response body exceeds %d bytes" url
            max_body_bytes))
  else if reply.status < 200 || reply.status >= 300 then
    Error (Error.Response { status = reply.status; body = excerpt reply.body })
  else Ok reply

let decode_json ~url body =
  match Jsont_bytesrw.decode_string Jsont.json body with
  | Ok json -> Ok json
  | Error reason ->
      Error
        (Error.transport
           (Printf.sprintf "%s: response is not JSON: %s" url (excerpt reason)))

let get t ~path =
  let url = url_of_path t ~path in
  let* reply = request t ~meth:`GET ~url ~write:false ~body:None in
  decode_json ~url reply.body

(* The reply's [rel="next"] target, if any. GitHub sends one Link header;
   every occurrence is scanned regardless. *)
let next_target reply =
  reply.headers
  |> List.concat_map (fun (name, value) ->
      if String.equal (String.lowercase_ascii name) "link" then
        Cohttp.Link.of_string value
      else [])
  |> List.find_map (fun { Cohttp.Link.arc; target; _ } ->
      if
        (not arc.Cohttp.Link.Arc.reverse)
        && List.exists
             (fun rel -> rel = Cohttp.Link.Rel.next)
             arc.Cohttp.Link.Arc.relation
      then Some target
      else None)

let same_origin t uri =
  Option.equal String.equal (Uri.scheme t.base) (Uri.scheme uri)
  && Option.equal String.equal (Uri.host t.base) (Uri.host uri)
  && Option.equal Int.equal (Uri.port t.base) (Uri.port uri)

let get_paginated t ~path ~max_pages =
  if max_pages < 1 then
    invalid_arg (Printf.sprintf "max_pages must be positive, got %d" max_pages);
  let first = url_of_path t ~path in
  let rec loop acc url remaining =
    let* reply = request t ~meth:`GET ~url ~write:false ~body:None in
    let* json = decode_json ~url reply.body in
    let acc = json :: acc in
    match next_target reply with
    | None -> Ok (List.rev acc)
    | Some target ->
        if not (same_origin t target) then
          (* The link target is server-controlled and lands in terminal-bound
             error text, so it rides the same excerpt discipline as response
             bodies. *)
          Error
            (Error.transport
               (Printf.sprintf "%s: pagination link leaves the API origin: %s"
                  url
                  (excerpt (Uri.to_string target))))
        else if remaining <= 1 then
          Error
            (Error.transport
               (Printf.sprintf
                  "%s: pagination still unfinished after %d pages" first
                  max_pages))
        else loop acc (Uri.to_string target) (remaining - 1)
  in
  loop [] first max_pages

let send t ~meth ~path ~body =
  let url = url_of_path t ~path in
  let* payload =
    match Jsont_bytesrw.encode_string Jsont.json body with
    | Ok payload -> Ok payload
    | Error reason ->
        Error (Error.transport ("request body failed to encode: " ^ reason))
  in
  let* reply = request t ~meth ~url ~write:true ~body:(Some payload) in
  if String.equal reply.body "" then Ok (reply.status, None)
  else
    let* json = decode_json ~url reply.body in
    Ok (reply.status, Some json)

let post t ~path ~body = send t ~meth:`POST ~path ~body
let patch t ~path ~body = send t ~meth:`PATCH ~path ~body

(* The production requester: one connection per request under its own switch,
   the response read whole under the body bound before the switch closes.
   Non-cancellation exceptions classify through [Mentat_llm_http], whose
   messages are display-safe and never carry request headers. *)
let requester client : http =
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
      Eio.Buf_read.(parse take_all) ~max_size:(max_body_bytes + 1) body_flow
    with
    | Ok body -> Ok { status; headers = response_headers; body }
    | Error (`Msg reason) ->
        Error
          (Error.transport
             (Printf.sprintf "%s: response body read failed: %s" url reason))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> (
      match Mentat_llm_http.error_of_exn exn with
      | Mentat_llm_http.Unresolved_host reason ->
          Error (Error.unresolved_host reason)
      | Mentat_llm_http.Transport reason -> Error (Error.transport reason)
      (* [error_of_exn] never mints [Response]; the arm keeps the match
         total. *)
      | Mentat_llm_http.Response _ ->
          Error (Error.transport (Mentat_llm_http.transport_message exn)))

let make ?base_url ~token net =
  match Oauth2_eio.make_tls_client net with
  | Error `System_ca_unavailable ->
      Error (Error.transport "system CA bundle unavailable")
  | Error `Tls_configuration_failed ->
      Error (Error.transport "TLS client configuration failed")
  | Ok client -> Ok (of_http ?base_url ~token (requester client))
