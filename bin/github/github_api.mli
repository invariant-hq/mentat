(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Bounded GitHub REST client.

    A thin, retry-free wrapper over the in-tree HTTPS stack: every request
    carries the caller's token as a [Bearer] authorization, the GitHub JSON
    accept header, and the pinned {!api_version}; every response body is read
    under {!max_body_bytes} and refused past it. Non-[2xx] answers and
    failures to obtain a reply are the two error classes
    ({!Error.type-kind}); there is no retry policy — a caller that wants
    convergence re-observes and re-issues.

    The HTTP effect is one injected closure ({!type-http}): {!make} builds
    the production requester over the system trust store with per-request
    endpoint verification, and {!of_http} is the lower-level seam for tests
    and alternative transports. The token reaches exactly one place — the
    authorization header of each request — and no error message or excerpt
    minted here carries it. *)

(** {1:errors Errors} *)

module Error : sig
  (** Client errors. *)

  (** The class of a client {!type-t}. *)
  type kind =
    | Response of { status : int; body : string }
        (** The request reached the API host and was answered non-[2xx].
            [body] is a short excerpt of the response body: truncated, with
            every byte outside printable ASCII replaced by a space, so it is
            a single display- and JSON-safe line. *)
    | Transport of string
        (** No reply was obtained; the string is a display-safe reason.
            Covers transit failures, a host the resolver rejects, a
            response body over {!max_body_bytes}, and a [2xx] body that is
            not JSON. An unresolvable-host arm would earn its place back
            the day a retry policy wants to skip retrying it; no consumer
            retries today. *)

  type t
  (** The type for client errors. *)

  val kind : t -> kind
  (** [kind error] is [error]'s class. *)

  val message : t -> string
  (** [message error] is a one-line human-readable description of [error]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf error] formats [error]'s message. *)

  val transport : string -> t
  (** [transport reason] is a {!Transport} error — the constructor a
      {!type-http} closure reports transit failures with. *)
end

(** {1:clients Clients} *)

val api_version : string
(** The [X-GitHub-Api-Version] value stamped on every request. *)

val max_body_bytes : int
(** The inclusive response-body byte bound, 8 MiB. A longer body is refused
    as a {!Error.Transport} error, never truncated. *)

type reply = { status : int; headers : (string * string) list; body : string }
(** The type for raw transport replies: any HTTP status, the response headers
    as received, and the complete response body. *)

type http =
  meth:[ `GET | `PATCH | `POST ] ->
  url:string ->
  headers:(string * string) list ->
  body:string option ->
  (reply, Error.t) result
(** An HTTP requester. It sends one request and returns the raw reply for
    whatever status the server answered; only a failure to obtain a reply is
    an error, reported through {!Error.transport}. Status interpretation,
    the body bound, and pagination all sit above the closure. *)

type t
(** The type for GitHub clients. A client holds its requester, token, and API
    base; it owns no connections. *)

val of_http : ?base_url:string -> token:string -> http -> t
(** [of_http ~token http] is a client over the caller-owned requester [http].
    [base_url] (default [https://api.github.com], trailing slashes dropped)
    prefixes every request path. Production callers construct with {!make};
    [of_http] is the seam for tests and alternative transports. *)

val make : ?base_url:string -> token:string -> _ Eio.Net.t -> (t, Error.t) result
(** [make ~token net] is a client whose requester opens one connection per
    request over [net], with TLS from the system CA bundle and endpoint
    identity verified against each request's host. Redirects are not
    followed — a [3xx] answer is a {!Error.Response} like any other
    non-[2xx] — so the authorization header goes only where the client
    itself asked. [base_url] as in {!of_http}; it exists for GitHub
    Enterprise hosts and local test servers, and an [http://] base is served
    unencrypted. Errors with {!Error.Transport} when the system trust store
    yields no TLS configuration. *)

(** {1:requests Requests} *)

val get : t -> path:string -> (Jsont.json, Error.t) result
(** [get t ~path] requests [path] — absolute under the client's base, so
    [/]-leading — and decodes the [2xx] response body as JSON. A non-[2xx]
    answer is {!Error.Response}; a body over {!max_body_bytes} or one that
    is not JSON is {!Error.Transport}. Raises [Invalid_argument] when
    [path] does not start with [/]. *)

val get_paginated :
  t -> path:string -> max_pages:int -> (Jsont.json list, Error.t) result
(** [get_paginated t ~path ~max_pages] is {!get} across pagination: the
    first page at [path], each further page at the response's [Link] header
    [rel="next"] target, pages in request order. A next target naming a
    different scheme, host, or port than the client's base is refused — the
    authorization header follows every page request, so a served link must
    not be able to carry it off the API origin. A chain still unfinished
    after [max_pages] pages errors rather than truncating silently. Raises
    [Invalid_argument] when [path] does not start with [/] or [max_pages]
    is not positive. *)

val post :
  t ->
  path:string ->
  body:Jsont.json ->
  (int * Jsont.json option, Error.t) result
(** [post t ~path ~body] sends [body] as JSON to [path] and, on a [2xx]
    answer, returns the status and the response body decoded as JSON —
    [None] when the body is empty. Errors and raises as {!get}. *)

val patch :
  t ->
  path:string ->
  body:Jsont.json ->
  (int * Jsont.json option, Error.t) result
(** [patch t ~path ~body] is {!post} with the [PATCH] method. *)
