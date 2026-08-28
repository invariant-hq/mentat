(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind
let api_version = "2022-11-28"
let max_body_bytes = 8 * 1024 * 1024
let default_user_agent = "github"

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
  type kind = Response of { status : int; body : string } | Transport of string

  type t = kind

  let kind t = t

  let message = function
    | Response { status; body } ->
        if String.equal body "" then
          Printf.sprintf "GitHub API responded %d" status
        else Printf.sprintf "GitHub API responded %d: %s" status body
    | Transport reason -> reason

  let pp ppf t = Format.pp_print_string ppf (message t)
  let transport reason = Transport reason
end

type reply = { status : int; headers : (string * string) list; body : string }

type http =
  meth:[ `GET | `PATCH | `POST ] ->
  url:string ->
  headers:(string * string) list ->
  body:string option ->
  (reply, Error.t) result

type t = {
  http : http;
  token : string option;
  user_agent : string;
  base_url : string;
  base : Uri.t;
}

let of_http ?(base_url = "https://api.github.com")
    ?(user_agent = default_user_agent) ?token http =
  let rec strip url =
    if String.length url > 0 && url.[String.length url - 1] = '/' then
      strip (String.sub url 0 (String.length url - 1))
    else url
  in
  let base_url = strip base_url in
  { http; token; user_agent; base_url; base = Uri.of_string base_url }

let request_headers t ~write =
  (match t.token with
  | Some token -> [ ("authorization", "Bearer " ^ token) ]
  | None -> [])
  @ ("accept", "application/vnd.github+json")
    :: ("x-github-api-version", api_version)
    :: ("user-agent", t.user_agent)
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

(* A hand-rolled reading of the Link header's [rel="next"] target. The full
   RFC 8288 grammar is not needed: only the value splitting has to be exact,
   because both quoted parameter values and the bracketed URI target may
   contain commas and semicolons that must not split a link. Parameters other
   than [rel] — [rev] included — are ignored, so a link related only in
   reverse never matches. *)
module Link = struct
  (* Split [value] on top-level [separator]: commas and semicolons inside
     ["…"] (with backslash escapes) or [<…>] separate nothing. *)
  let split_outside separator value =
    let length = String.length value in
    let segments = ref [] in
    let start = ref 0 in
    let in_quote = ref false in
    let in_target = ref false in
    let i = ref 0 in
    while !i < length do
      (match value.[!i] with
      | '\\' when !in_quote -> incr i
      | '"' -> if !in_target then () else in_quote := not !in_quote
      | '<' when not !in_quote -> in_target := true
      | '>' when not !in_quote -> in_target := false
      | c when Char.equal c separator && (not !in_quote) && not !in_target ->
          segments := String.sub value !start (!i - !start) :: !segments;
          start := !i + 1
      | _ -> ());
      incr i
    done;
    List.rev (String.sub value !start (length - !start) :: !segments)

  let unquote value =
    let length = String.length value in
    if
      length >= 2
      && Char.equal value.[0] '"'
      && Char.equal value.[length - 1] '"'
    then (
      let buffer = Buffer.create (length - 2) in
      let i = ref 1 in
      while !i < length - 1 do
        (match value.[!i] with
        | '\\' when !i + 1 < length - 1 ->
            incr i;
            Buffer.add_char buffer value.[!i]
        | c -> Buffer.add_char buffer c);
        incr i
      done;
      Buffer.contents buffer)
    else value

  (* One [<target>; param; …] segment's target, when its [rel] parameter
     names [next] among its space-separated relation types. *)
  let next_of_segment segment =
    match split_outside ';' segment with
    | [] -> None
    | target :: params ->
        let target = String.trim target in
        let bracketed =
          String.length target >= 2
          && Char.equal target.[0] '<'
          && Char.equal target.[String.length target - 1] '>'
        in
        if not bracketed then None
        else
          let rel_names_next param =
            match String.index_opt param '=' with
            | None -> false
            | Some eq ->
                let name =
                  String.lowercase_ascii (String.trim (String.sub param 0 eq))
                in
                String.equal name "rel"
                && String.sub param (eq + 1) (String.length param - eq - 1)
                   |> String.trim |> unquote |> String.split_on_char ' '
                   |> List.exists (fun rel ->
                       String.equal (String.lowercase_ascii rel) "next")
          in
          if List.exists rel_names_next params then
            Some (String.sub target 1 (String.length target - 2))
          else None

  let next value = List.find_map next_of_segment (split_outside ',' value)
end

(* The reply's [rel="next"] target, if any. GitHub sends one Link header;
   every occurrence is scanned regardless. *)
let next_target reply =
  reply.headers
  |> List.find_map (fun (name, value) ->
      if String.equal (String.lowercase_ascii name) "link" then
        Option.map Uri.of_string (Link.next value)
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
