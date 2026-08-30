(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared HTTP transport mechanics for LLM providers.

    This library owns the shared Eio/Cohttp/TLS mechanics and SSE framing used
    by HTTP-backed provider adapters. Provider authentication, retry policy,
    response interpretation, and protocol decoding remain above this module. *)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}
(** A non-successful HTTP response. [body] is bounded to 64 KiB. *)

type error =
  | Response of response
  | Transport of string
      (** An HTTP response failure or an error establishing the response stream.
      *)
  | Unresolved_host of string
      (** The host name has no address. Distinguished from {!Transport} because
          a retry reaches the same answer: the resolver rejected the name
          itself, rather than failing in a way a later attempt could survive. *)

val header_value : (string * string) list -> string -> string option
(** [header_value headers name] is the value of the first header matching
    [name], compared case-insensitively. *)

val transport_message : exn -> string
(** [transport_message exn] renders a transport-layer exception as a concise,
    human-readable message. The common Eio network failures (connection refused,
    host resolution, timeout, reset) become short phrases rather than the
    multi-line [Eio.Io (Net …)] dump their default representation produces; TLS
    and configuration failures pass through their own printers, and an unknown
    exception degrades to a trimmed [Printexc] representation. Do not pass
    [Eio.Cancel.Cancelled] — re-raise it instead. *)

val error_of_exn : exn -> error
(** [error_of_exn exn] classifies a transport-layer exception, carrying the
    message {!transport_message} renders for it.

    A resolver that rejects the host name itself — no such name, or a name with
    no address — is {!Unresolved_host}; every other failure, including a
    resolver that is merely unwell, is {!Transport} and so keeps its retry. Do
    not pass [Eio.Cancel.Cancelled] — re-raise it instead. *)

val post_stream :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  url:string ->
  headers:(string * string) list ->
  body:string ->
  (Eio.Flow.source_ty Eio.Std.r, error) result
(** [post_stream ~sw ~env ~url ~headers ~body] posts [body] and returns the
    successful response body as a byte stream.

    Cancellation propagates. Other transport failures are returned as
    {!Transport} with a message rendered by {!transport_message}; non-[2xx]
    responses are returned as {!Response}. *)

module Retry_after : sig
  val delay : now:float -> (string * string) list -> float option
  (** [delay ~now headers] is the delay requested by [Retry-After-Ms] or
      [Retry-After].

      Milliseconds take precedence over numeric seconds, which take precedence
      over IMF-fixdate interpreted against [now] in POSIX seconds. Header names
      match case-insensitively. Negative delays are clamped to zero and invalid
      values are ignored. The result is deliberately not bounded: deciding how
      long a model request may wait is provider policy. *)
end

module Sse : sig
  type event = { name : string; data : string }
  (** One SSE event. [name] is empty when the event has no [event] field;
      multiple [data] fields are joined with a newline. *)

  type t
  (** An SSE reader over an HTTP response body. *)

  val make : Eio.Flow.source_ty Eio.Std.r -> t
  (** [make source] reads SSE events from [source]. *)

  val next : t -> (event, string) result option
  (** [next t] is the next event carrying data, or [None] at end of input or
      after {!close}. Fields other than [event] and [data] are ignored. A read
      failure is trapped as [Some (Error message)], with [message] rendered by
      {!transport_message}; [Eio.Cancel.Cancelled] propagates. *)

  val close : t -> unit
  (** [close t] stops [t] locally: every subsequent {!next} is [None]. [close]
      is idempotent. The underlying HTTP flow remains owned by the Eio/Cohttp
      call. *)
end
