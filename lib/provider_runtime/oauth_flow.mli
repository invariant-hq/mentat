(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Authentication protocol interpreters for provider-declared login methods.

    This interprets the pure login-protocol declarations of
    [Mentat_provider.Auth.Login.Protocol] into provider/source-free
    [Mentat_provider.Credential.Secret.t] values from OAuth 2.0
    authorization-code and device-code grants, including OpenAI ChatGPT's
    non-standard device authorization. It also serves the local browser
    callback. It is not a workflow runner — it does not prompt, open browsers,
    sleep between polls, choose UI, or mutate the credential store; {!Login}
    composes these primitives into the orchestration.

    In-progress OAuth values are secret-bearing: they may hold state, PKCE
    verifiers, authorization codes, device identifiers, refresh tokens, access
    tokens, or user codes. Only the challenge and display fields documented here
    are safe to expose. *)

module Error : sig
  (** Structured auth runtime errors. Diagnostics carry no credential material,
      request or response bodies, authorization codes, PKCE verifiers, or device
      identifiers. Provider OAuth rejection fields and raw exception text are
      reduced to fixed categories. This sum is private to the leaf; it is
      projected to [Mentat_provider.Account.Problem.t] (refresh/revoke) and to
      the outer runtime login diagnostic. *)
  type t =
    | Invalid_request of string
        (** A local protocol parameter or callback is invalid. *)
    | Network of string  (** TLS, connection, or listener I/O failed. *)
    | Protocol of string
        (** A provider response is malformed or unsupported. *)
    | Rejected of string  (** The provider denied the OAuth request. *)
    | Timeout of string  (** A bounded request or callback wait expired. *)
    | Not_refreshable
        (** The supplied credential has no OAuth refresh token. *)

  val message : t -> string
  (** [message t] is a human-readable diagnostic for [t]. It carries no
      credential material, request or response body, or authorization code. *)
end

module Http : sig
  (** Deadline-bound HTTP for authentication runtimes, wrapping
      [mentat_oauth2_eio].

      The short 30-second deadline is the auth policy: login and refresh are
      fast round-trips, unlike the provider transports' streaming clients that
      this client is deliberately kept distinct from. *)

  type t
  (** A deadline-bound TLS HTTP client for the auth endpoints. *)

  val tls_client : stdenv:Eio_unix.Stdenv.base -> (t, Error.t) result
  (** [tls_client ~stdenv] is a 30-second deadline-bound TLS HTTP client, or
      [Network] if TLS construction fails. *)
end

module Local_callback : sig
  (** The loopback listener that awaits the browser's authorization-code
      callback. *)

  val await_once :
    stdenv:Eio_unix.Stdenv.base ->
    ?provider:string ->
    ?on_ready:(unit -> unit) ->
    ?accept:(Uri.t -> bool) ->
    ?serve:(path:string -> string option) ->
    redirect_uri:Uri.t ->
    timeout_s:float ->
    unit ->
    (Uri.t, Error.t) result
  (** [await_once ~stdenv ~redirect_uri ~timeout_s ()] binds the loopback
      address and port of [redirect_uri], waits for the first accepted request
      on its path, and returns the absolute callback URI — which carries the
      authorization code and is secret-bearing. [on_ready] fires once the socket
      is listening; [accept] rejects stray or forged callbacks.
      [Error (Timeout _)] when no accepted request arrives within [timeout_s];
      [Error (Invalid_request _)] when [redirect_uri] lacks an explicit loopback
      host or port. Fiber cancellation is re-raised rather than reported as a
      failure. Exceptions raised by [on_ready], [accept], or [serve] are
      likewise re-raised as caller faults.

      [serve ~path] lets a flow hand the browser an entry page from the same
      one-shot listener: consulted for a request off the callback path, its
      [Some page] is answered [200] as HTML, its [None] falls through to the
      branded not-found page. Serving never consumes the shot. The GitHub
      app-manifest flow uses it to serve the auto-submitting create-page
      form; plain OAuth flows leave it absent.

      [provider] is the human-readable provider name woven into the branded HTML
      the browser is served on success, denial, or a stray callback. It is
      display copy only; the flow's outcome never depends on it. *)
end

module Openai_chatgpt : sig
  (** OpenAI ChatGPT's non-standard device authorization, token refresh, and
      revocation. The generic OAuth 2.0 interpreters cover the standard grants;
      only this provider's bespoke device flow and token shape need a dedicated
      handler. *)

  module Config : sig
    (** Endpoint and client configuration for the ChatGPT auth flow. *)

    type t
    (** A validated ChatGPT auth configuration: issuer, client id, and the
        default challenge lifetime and poll interval. *)

    val default : t
    (** [default] uses issuer [https://auth.openai.com] and the built-in public
        client id. *)

    val make :
      ?issuer:Uri.t ->
      ?client_id:string ->
      ?expires_in:int ->
      ?poll_interval:int ->
      unit ->
      (t, Error.t) result
    (** [make ()] is an OpenAI ChatGPT auth configuration. [issuer] defaults to
        [https://auth.openai.com]; the reroot seam passes a test issuer here.
        [Invalid_request] when [issuer] is not an http(s) URL with a host and no
        query or fragment, [client_id] is empty, or a lifetime is negative. *)
  end

  val refresh :
    http:Http.t ->
    sw:Eio.Switch.t ->
    now:int64 ->
    Config.t ->
    Mentat_provider.Credential.Secret.t ->
    (Mentat_provider.Credential.Secret.t, Error.t) result
  (** [refresh ~http ~sw ~now config secret] exchanges the OAuth refresh token
      for a fresh secret, carrying forward the refresh token, expiry, and
      account id when the response omits them. [Not_refreshable] for a non-OAuth
      secret or one without a refresh token; [Network] or [Timeout] on transport
      failure; [Protocol]/[Rejected] on a malformed or denied response. *)

  val revoke :
    http:Http.t ->
    sw:Eio.Switch.t ->
    Config.t ->
    Mentat_provider.Credential.Secret.t ->
    (unit, Error.t) result
  (** [revoke ~http ~sw config secret] asks the issuer to revoke [secret]'s
      refresh token (falling back to its access token). [Ok ()] on success;
      [Not_refreshable] for a non-OAuth secret; transport errors as for
      {!refresh}. *)
end

module Authorization_code : sig
  (** The OAuth 2.0 authorization-code grant with PKCE: start a flow, hand the
      user the authorization URI, accept the loopback callback, and exchange the
      code for a secret. *)

  type t
  (** Started authorization-code state. Holds the PKCE verifier and anti-forgery
      state, so it is secret-bearing until completed. *)

  (** Post-exchange token interpretation. [Openai_chatgpt] additionally mines
      the id token for the ChatGPT account id. *)
  type token_profile = Generic | Openai_chatgpt

  val start :
    random:Oauth2.random ->
    client:Oauth2.Client.t ->
    authorization_endpoint:Uri.t ->
    token_endpoint:Uri.t ->
    redirect_uri:Uri.t option ->
    scope:string list ->
    extra:(string * string) list ->
    pkce:bool ->
    (t, Error.t) result
  (** [start ~random ~client …] begins a flow, generating the PKCE pair (when
      [pkce]) and the anti-forgery state from [random]. [Invalid_request] when
      [redirect_uri] is [None] or a supplied parameter is reserved. Exceptions
      raised by [random] are re-raised as programmer faults. *)

  val authorization_uri : t -> Uri.t
  (** [authorization_uri t] is the URI the user opens to authorize.
      Display-safe. *)

  val redirect_uri : t -> Uri.t
  (** [redirect_uri t] is the loopback callback URI the flow listens on. *)

  val accepts_callback : t -> Uri.t -> bool
  (** [accepts_callback t callback] is [true] iff [callback] carries [t]'s state
      — a genuine callback, including a state-matched provider denial — and
      [false] for a stray, forged, or state-mismatched request. It is the
      loopback listener's [accept] guard against the stray-callback hazard. *)

  val complete_secret :
    http:Http.t ->
    sw:Eio.Switch.t ->
    t ->
    callback:Uri.t ->
    now:(unit -> int64) ->
    profile:token_profile ->
    (Mentat_provider.Credential.Secret.t, Error.t) result
  (** [complete_secret ~http ~sw t ~callback ~now ~profile] validates
      [callback], exchanges its code at the token endpoint, samples [now] after
      the exchange, and interprets the token per [profile]. [Rejected] when the
      provider denied authorization, [Invalid_request] on a malformed callback,
      [Network] or [Timeout] on transport failure, [Protocol] on a malformed
      token. *)
end

module Device_code : sig
  (** OAuth 2.0 device authorization: start a flow, show the user the
      verification URI and code, then poll until the grant is authorized,
      expires, or is rejected. One poll loop serves both the standard grant and
      OpenAI ChatGPT's variant. *)

  type t
  (** Device-authorization state closing over its transport, so {!poll} needs no
      protocol declaration. Secret-bearing (it carries the device identifier).
  *)

  type challenge = {
    verification_uri : Uri.t;  (** The URI the user opens to enter the code. *)
    verification_uri_complete : Uri.t option;
        (** The URI with the code pre-filled, when the provider supplies one. *)
    user_code : string;  (** The code the user enters. Display-safe. *)
  }
  (** The display fields of a device challenge — all safe to show. *)

  (** The outcome of one {!poll}. *)
  type poll =
    | Authorized of Mentat_provider.Credential.Secret.t
        (** The user authorized; the minted secret is ready to persist. *)
    | Pending of t
        (** Not yet authorized; poll again after {!next_poll_delay_s}. *)
    | Expired  (** The device code expired; the flow must restart. *)

  val start_oauth2 :
    http:Http.t ->
    sw:Eio.Switch.t ->
    now:int64 ->
    client:Oauth2.Client.t ->
    device_endpoint:Uri.t ->
    token_endpoint:Uri.t ->
    scope:string list ->
    extra:(string * string) list ->
    (t, Error.t) result
  (** [start_oauth2 …] requests a standard device grant and returns its initial
      state and challenge. [Invalid_request] on a reserved parameter; [Network]
      or [Timeout] on transport failure. *)

  val start_openai_chatgpt :
    http:Http.t ->
    sw:Eio.Switch.t ->
    now:int64 ->
    Openai_chatgpt.Config.t ->
    (t, Error.t) result
  (** [start_openai_chatgpt ~http ~sw ~now config] requests ChatGPT's device
      grant, defaulting [expires_in] and [interval] from [config] when the
      server omits them. *)

  val poll :
    http:Http.t -> sw:Eio.Switch.t -> now:int64 -> t -> (poll, Error.t) result
  (** [poll ~http ~sw ~now t] performs one token-endpoint poll: [Authorized]
      once the user completes, [Pending] (advancing the interval, backing off on
      a slow-down signal) while waiting, [Expired] past the deadline. [Error] on
      provider rejection or a transport or protocol failure. The caller paces
      polls with {!next_poll_delay_s}. *)

  val challenge : t -> challenge
  (** [challenge t] is [t]'s display challenge. *)

  val expires_in : t -> int
  (** [expires_in t] is the seconds the device code stays valid from its start.
  *)

  val next_poll_delay_s : now:int64 -> t -> int
  (** [next_poll_delay_s ~now t] is the seconds to wait before the next {!poll},
      [0] when a poll is already due. *)
end
