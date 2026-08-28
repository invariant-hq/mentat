(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Eio transport for pure OAuth 2.0 requests.

    The {!Oauth2} library constructs protocol values and form-encoded
    {!Oauth2.Request.t} descriptions without performing I/O. This module is the
    Eio boundary: it sends those descriptions with Cohttp, bounds response
    bodies, maps transport failures into structured errors, and provides HTTPS
    client construction.

    The usual path is to build a {!Oauth2.Client.t} and a protocol value with
    {!Oauth2.Grant}, {!Oauth2.Device}, or {!Oauth2.Revocation}, create a client
    with {!make_tls_client} or {!make_client}, then call {!send}. Use {!post}
    for provider-specific endpoints that are not represented by
    {!Oauth2.Request.t}. *)

(** {1:errors Responses and Errors} *)

type response = Oauth2.Response.t
(** Raw HTTP response metadata and bounded body.

    Values may contain provider diagnostics. They may also contain
    secret-bearing OAuth response data when returned from low-level functions.
*)

module Error : sig
  type transport =
    [ `Network_unavailable
    | `Invalid_endpoint_identity
    | `Response_body_read_failed ]
  (** Transport failure before OAuth decoding.

      [`Network_unavailable] covers expected Eio network/timeout failures,
      Cohttp connection or resolver rejection, and TLS peer alerts, failures, or
      early handshake close; [`Invalid_endpoint_identity] covers a missing or
      invalid HTTPS host; [`Response_body_read_failed] covers bounded
      response-reader rejection. The cases carry no request, response, provider,
      or exception text. They do not cover pure OAuth request construction
      errors. Eio cancellation and unrelated exceptions are re-raised by request
      functions. *)

  type t = [ Oauth2.Response.decode_error | `Transport of transport ]
  (** OAuth request execution error.

      Extends {!Oauth2.Response.decode_error} with [`Transport _], introduced by
      this module when HTTP execution fails before any OAuth response is
      decoded. The [`Oauth _], [`Malformed _], and [`Http _] cases are pure
      response-decoder errors from {!Oauth2.Response}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics.

      The formatter does not print HTTP response bodies or headers, tokens,
      request bodies, OAuth error fields, malformed response details, or
      exception text. *)

  val pp_transport : Format.formatter -> transport -> unit
  (** [pp_transport ppf e] formats a payload-free transport category. *)
end

(** {1:execution Request Execution} *)

val post :
  Cohttp_eio.Client.t ->
  sw:Eio.Switch.t ->
  ?max_response_body_size:int ->
  uri:Uri.t ->
  ?headers:(string * string) list ->
  body:string ->
  unit ->
  (response, Error.transport) result
(** [post http ~sw ?max_response_body_size ~uri ?headers ~body ()] sends one raw
    HTTP POST and returns the raw response.

    [body] is sent unchanged. The [Content-Type] header is set to
    [application/x-www-form-urlencoded] unless [headers] already contains a
    [content-type] header, compared case-insensitively.

    [max_response_body_size] is an inclusive byte limit applied while reading
    the response body; the default is 1 MiB. A response rejected by the bounded
    reader is [Error `Response_body_read_failed].

    [sw] must be live when the request starts. Expected Eio transport failures
    become payload-free {!Error.transport} values. Eio cancellation and
    unrelated exceptions are re-raised. Per-request resources are released
    before [post] returns.

    Raises [Invalid_argument] if [max_response_body_size] is negative. *)

val send :
  Cohttp_eio.Client.t ->
  sw:Eio.Switch.t ->
  ?max_response_body_size:int ->
  'a Oauth2.Request.t ->
  ('a, Error.t) result
(** [send http ~sw ?max_response_body_size request] sends [request] and decodes
    its response.

    The URI, headers, and body come from {!Oauth2.Request.uri},
    {!Oauth2.Request.headers}, and {!Oauth2.Request.body}. Transport failures
    from {!post} become [`Transport _]. Decoder failures from
    {!Oauth2.Request.decode} are preserved as [`Oauth _], [`Malformed _], or
    [`Http _]. Eio cancellation is re-raised as in {!post}.

    This function does not validate or rewrite request parameters. Build
    requests with {!Oauth2.Grant.request}, {!Oauth2.Device.request}, or
    {!Oauth2.Revocation.request} when the standard reserved-parameter checks are
    required. *)

(** {1:https HTTPS Clients} *)

type https
(** HTTPS connector for {!make_client}.

    A value wraps the TLS configuration used when Cohttp opens [https://] URIs.
    It does not own the Eio network environment or request switches. *)

type tls_error = [ `System_ca_unavailable | `Tls_configuration_failed ]
(** Payload-free system TLS setup failure. *)

val make_https : unit -> (https, tls_error) result
(** [make_https ()] builds an HTTPS connector using the system CA bundle.

    The connector initializes the default Mirage crypto RNG before TLS use and
    constructs a client TLS configuration with CA authentication. Each HTTPS
    request validates the endpoint against the URI host, using DNS-name
    verification for host names and IP verification for IP literals.

    Errors with [`System_ca_unavailable] or [`Tls_configuration_failed] if the
    corresponding system setup cannot be constructed. The connector rejects an
    [https://] URI with no host, or with a host that cannot be interpreted as a
    DNS name or IP literal; when used through {!post} or {!send}, that rejection
    is [`Invalid_endpoint_identity]. Endpoint identity verification is not
    silently disabled. *)

val make_client : ?https:https -> _ Eio.Net.t -> Cohttp_eio.Client.t
(** [make_client ?https net] builds a Cohttp Eio client.

    [net] is used for connections made by later requests and is not owned by the
    returned value. Without [https], [https://] URIs are unsupported by the
    client. *)

val make_tls_client : _ Eio.Net.t -> (Cohttp_eio.Client.t, tls_error) result
(** [make_tls_client net] is [make_client ~https net] with [https] from
    {!make_https}.

    Errors are the TLS setup errors from {!make_https}. The returned client has
    the same network ownership and request-time URI validation behavior as
    {!make_client} and {!make_https}. *)

(** {1:loopback The loopback redirect listener} *)

(** A one-shot listener for the browser's authorization redirect.

    An authorization-code flow on a native host registers a loopback
    redirect URI, opens the authorization URI in the user's browser, and
    waits for the provider to redirect the browser back. {!await_once} is
    that wait: it binds the loopback address and port of the redirect URI,
    serves HTTP until the first request on the redirect path that the
    caller's [accept] guard admits, and returns that request's absolute URI
    — carrying the authorization code or the provider's denial, so the
    result is secret-bearing. Callback validation and the code exchange
    stay above this module; pair [accept] with {!Oauth2.State} matching and
    hand the returned URI to {!Oauth2.Authorization.callback}. *)
module Loopback : sig
  (** How the listener classified one request, for the page the browser is
      shown. The classification is display routing only — the flow's result
      is the returned URI, and callback fields are checked above this
      module. *)
  type outcome =
    | Granted
        (** The accepted callback carries no [error] field: the provider
            granted authorization. *)
    | Denied of { error : string; description : string option }
        (** The accepted callback carries an OAuth [error] field (a
            provider that denies still redirects, with a matching state):
            the code and description are decoded query values, straight
            from the request — escape them before embedding in markup. *)
    | Unverified
        (** A request on the redirect path that [accept] refused, or one
            that arrived after the shot was consumed. Answered [400];
            never consumes the shot. *)
    | Not_found
        (** A request off the redirect path that [serve] did not answer.
            Answered [404]; never consumes the shot. *)

  type error =
    [ `Invalid_redirect_uri of string
    | `Listener_unavailable
    | `Timed_out ]
  (** Listener failure.

      [`Invalid_redirect_uri reason] means the redirect URI names no
      loopback host or no explicit port; the reason is display-safe.
      [`Listener_unavailable] covers a loopback bind that fails and a
      listener I/O failure before a callback settles. [`Timed_out] means
      no accepted callback arrived in time. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error ppf e] formats [e] for diagnostics. *)

  val await_once :
    net:_ Eio.Net.t ->
    clock:_ Eio.Time.clock ->
    ?on_ready:(unit -> unit) ->
    ?accept:(Uri.t -> bool) ->
    ?serve:(path:string -> string option) ->
    ?respond:(outcome -> string) ->
    redirect_uri:Uri.t ->
    timeout_s:float ->
    unit ->
    (Uri.t, error) result
  (** [await_once ~net ~clock ~redirect_uri ~timeout_s ()] binds the
      loopback address and port of [redirect_uri], waits for the first
      accepted request on its path, and returns the absolute callback URI
      — secret-bearing, since it carries the flow's one-shot code.

      [redirect_uri] must name an explicit port and a loopback host:
      [127.0.0.1], [::1], or [localhost], which binds both address
      families and accepts whichever the browser dials (a bind is reported
      only when no family binds). [on_ready] fires once the socket is
      listening — the moment to open the browser.

      [accept] (default: accept everything) guards the shot: a request on
      the redirect path is returned only when [accept] admits its absolute
      URI, so a state-checking guard makes a stray or forged callback a
      {!Unverified} page instead of the result. A provider denial
      redirects with a matching state, so it is accepted and returned like
      a grant — the caller reads the [error] field. Refused and late
      requests never consume the shot.

      [serve ~path] hands the browser a page from the same one-shot
      listener: consulted for a request off the callback path, its
      [Some page] is answered [200] as HTML, its [None] falls through to
      the {!Not_found} page. Serving never consumes the shot.

      [respond outcome] is the HTML body the browser is answered with;
      the default pages are unbranded single sentences. Statuses are
      fixed: {!Granted} and {!Denied} answer [200], {!Unverified} [400],
      {!Not_found} [404].

      [Error `Timed_out] when no accepted request arrives within
      [timeout_s]. Fiber cancellation is re-raised rather than reported
      as a failure. Exceptions raised by [on_ready], [accept], [serve],
      or [respond] are likewise re-raised as caller faults. *)
end
