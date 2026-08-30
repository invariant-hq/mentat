(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let max_error_body_bytes = 65_536

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type error =
  | Response of response
  | Transport of string
  | Unresolved_host of string

let https ~authenticator =
  let tls_config =
    match Tls.Config.client ~authenticator () with
    | Error (`Msg message) -> failwith ("TLS configuration error: " ^ message)
    | Ok config -> config
  in
  fun uri raw ->
    let host =
      Uri.host uri
      |> Option.map (fun value -> Domain_name.(host_exn (of_string_exn value)))
    in
    Tls_eio.client_of_flow ?host tls_config raw

(* Eio wraps network failures as [Eio.Io (Eio.Net.E _, _)] whose default repr is
   a multi-line dump carrying the raw backend [Unix_error], so a refused
   connection would otherwise reach the user as an [Eio.Io Net Connection_failure
   Refused (...)] blob. Map the common network cases to concise phrases; TLS
   failures and our own [Failure] (TLS/X509 config) already read cleanly through
   their printers, and a genuinely-unknown exception degrades to a trimmed repr.
   [Eio.Cancel.Cancelled] is never rendered here — callers re-raise it before
   reaching this function. *)
let transport_message = function
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure (Eio.Net.Refused _)), _) ->
      "connection refused"
  | Eio.Io (Eio.Net.E (Eio.Net.Address_lookup_failed _), _) ->
      "could not resolve host"
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure Eio.Net.Timeout), _) ->
      "connection timed out"
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> "connection reset"
  | exn -> String.trim (Printexc.to_string exn)

(* A name the resolver rejects outright answers the same way however often it is
   asked, so it must not spend the retry budget. Only the two codes that mean
   "this name has no address" are permanent; a resolver that is merely unwell —
   temporarily unreachable, out of memory, misconfigured — keeps its retry, so
   an ambiguous failure errs toward trying again. *)
let unresolved_host = function
  | Eio.Io (Eio.Net.E (Eio.Net.Address_lookup_failed code), _) -> (
      Eio.Net.Getaddrinfo_error.(
        match code with
        | NONAME | NODATA -> true
        | ADDRFAMILY | AGAIN | BADFLAGS | BADHINTS | FAIL | FAMILY | MEMORY
        | OVERFLOW | PROTOCOL | SERVICE | SOCKTYPE | UNKNOWN ->
            false))
  | _ -> false

let error_of_exn exn =
  if unresolved_host exn then Unresolved_host (transport_message exn)
  else Transport (transport_message exn)

let cohttp_headers headers =
  List.fold_left
    (fun acc (name, value) -> Cohttp.Header.add acc name value)
    (Cohttp.Header.init ()) headers

let read_body body =
  let chunk = Cstruct.create 4096 in
  let buffer = Buffer.create 1024 in
  let rec loop remaining =
    if remaining > 0 then
      match Eio.Flow.single_read body chunk with
      | exception End_of_file -> ()
      | count ->
          let count = min count remaining in
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub chunk 0 count));
          loop (remaining - count)
  in
  loop max_error_body_bytes;
  Buffer.contents buffer

let post_stream ~sw ~env ~url ~headers ~body =
  try
    Mirage_crypto_rng_unix.use_default ();
    let authenticator =
      match Ca_certs.authenticator () with
      | Ok authenticator -> authenticator
      | Error (`Msg message) -> failwith ("X509 authenticator: " ^ message)
    in
    let client =
      Cohttp_eio.Client.make ~https:(Some (https ~authenticator)) env#net
    in
    let response, response_body =
      Cohttp_eio.Client.post client ~sw ~headers:(cohttp_headers headers)
        ~body:(Cohttp_eio.Body.of_string body)
        (Uri.of_string url)
    in
    let response =
      {
        status = Cohttp.Code.code_of_status (Cohttp.Response.status response);
        headers = Cohttp.Header.to_list (Cohttp.Response.headers response);
        body = "";
      }
    in
    if response.status < 200 || response.status >= 300 then
      Error (Response { response with body = read_body response_body })
    else Ok (response_body :> Eio.Flow.source_ty Eio.Std.r)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (error_of_exn exn)

let header_value headers name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    headers

module Retry_after = struct

  let month_number = function
    | "Jan" -> Some 1
    | "Feb" -> Some 2
    | "Mar" -> Some 3
    | "Apr" -> Some 4
    | "May" -> Some 5
    | "Jun" -> Some 6
    | "Jul" -> Some 7
    | "Aug" -> Some 8
    | "Sep" -> Some 9
    | "Oct" -> Some 10
    | "Nov" -> Some 11
    | "Dec" -> Some 12
    | _ -> None

  (* Days from 1970-01-01 for a proleptic Gregorian civil date (Howard
     Hinnant's algorithm). *)
  let days_from_civil ~year ~month ~day =
    let year = if month <= 2 then year - 1 else year in
    let era = (if year >= 0 then year else year - 399) / 400 in
    let year_of_era = year - (era * 400) in
    let day_of_year =
      (((153 * if month > 2 then month - 3 else month + 9) + 2) / 5) + day - 1
    in
    let day_of_era =
      (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100)
      + day_of_year
    in
    (era * 146097) + day_of_era - 719468

  (* IMF-fixdate only ("Sun, 06 Nov 1994 08:49:37 GMT"). *)
  let imf_fixdate text =
    let int_of value = int_of_string_opt value in
    match String.split_on_char ' ' (String.trim text) with
    | [ _weekday; day; month; year; time; "GMT" ] -> (
        match
          ( int_of day,
            month_number month,
            int_of year,
            String.split_on_char ':' time )
        with
        | Some day, Some month, Some year, [ hours; minutes; seconds ] -> (
            match (int_of hours, int_of minutes, int_of seconds) with
            | Some hours, Some minutes, Some seconds
              when day >= 1 && day <= 31 && hours < 24 && minutes < 60
                   && seconds < 61 ->
                Some
                  (float_of_int
                     ((days_from_civil ~year ~month ~day * 86_400)
                     + (hours * 3_600) + (minutes * 60) + seconds))
            | _ -> None)
        | _ -> None)
    | _ -> None

  let delay ~now headers =
    match header_value headers "retry-after-ms" with
    | Some value ->
        Option.map
          (fun ms -> Float.max 0. (float_of_int ms /. 1000.))
          (int_of_string_opt value)
    | None -> (
        match header_value headers "retry-after" with
        | None -> None
        | Some value -> (
            match int_of_string_opt (String.trim value) with
            | Some seconds -> Some (Float.max 0. (float_of_int seconds))
            | None ->
                Option.map
                  (fun date -> Float.max 0. (date -. now))
                  (imf_fixdate value)))
end

module Sse = struct
  (* The provider-facing SSE surface: an adapter over the pure [Sse] framing and
     its [sse_eio] byte-stream reader. [Sse.Event] carries an [id] the model
     stream never uses, so it is dropped here; [name] defaults to [""] for the
     event's default type, which the provider decoders already treat as the
     absence of an event name. ([Sse] inside this module denotes the [sse]
     library, not this adapter — the binding shadows only after it is defined.) *)
  type event = { name : string; data : string }
  type t = { reader : Sse_eio.Reader.t; mutable closed : bool }

  let make (source : Eio.Flow.source_ty Eio.Std.r) =
    { reader = Sse_eio.Reader.of_source source; closed = false }

  let close t = t.closed <- true

  let next t =
    if t.closed then None
    else
      match Sse_eio.Reader.next t.reader with
      | None -> None
      | Some { Sse.Event.name; data; _ } -> Some (Ok { name; data })
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn -> Some (Error (transport_message exn))
end
