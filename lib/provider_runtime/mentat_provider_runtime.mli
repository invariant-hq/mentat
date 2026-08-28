(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The effectful provider leaf.

    [mentat.provider_runtime] turns the pure declarations of [mentat.provider]
    into live provider calls, credential I/O, and OAuth flows. It is the one
    archive that links a provider transport, a TLS stack, an OAuth runtime, and
    credential storage; nothing above it links any of that, so a lightweight
    build that excludes network, TLS, and credential storage simply does not
    link this archive. Everything the executable composes derives from one
    registration list built once by {!create}, so constructing a value {e is}
    the coverage proof.

    The pure vocabulary of [mentat.provider] (declarations,
    {!Mentat_provider.Model}, {!Mentat_provider.Credential},
    {!Mentat_provider.Account}) and of [mentat.llm] ({!Mentat_llm.Client},
    {!Mentat_llm.Request}, {!Mentat_llm.Error}) is the only currency at the
    boundary. The runtime mints a bespoke shape only for its own operation
    errors and the local-model artifact vocabulary. The engine reaches providers
    only through the port the executable adapts from {!Mentat_llm.Client.t};
    this leaf never names the provider port.

    {b Secret confinement.} No [message], [pp], or diagnostic anywhere in this
    library emits a secret, token, authorization code, PKCE verifier, device
    identifier, or request or response body, and every account, login, and
    logout value crossing the surface is credential-free. Credential bytes reach
    only [config_dir/auth.json], never the session store or the engine. *)

(** {1 Errors} *)

module Store_error = Store_error
(** Failure of the credential file machinery around [auth.json]. *)

module Error = Error
(** Structured client, credential, store, and login-operation failures. *)

module Artifact = Artifact
(** The provider-neutral local-model artifact vocabulary (status, progress, and
    download outcome). The executable adapts these values onto the protocol's
    model-download flow at the composition edge. *)

(** {1 The assembled runtime} *)

type t
(** The registration list, its built drivers, and the credential store bound
    to its file. Constructed once at startup, after the sandbox is sealed. *)

val create : config_dir:Eio.Fs.dir_ty Eio.Path.t -> t
(** [create ~config_dir] assembles the built-in providers exactly once and
    binds the credential store to [config_dir/auth.json]. The executable
    resolves [config_dir] and hands in the capability; the runtime owns the
    filename, never path policy. Performs no I/O — the store file is read
    lazily. Raises [Invalid_argument] on built-in drift (a provider declared
    twice, or a declared provider-defined login protocol with no driver
    handler), so a malformed built-in never yields a [t]. This is the coverage
    check. *)

val catalog : t -> Mentat_provider.Catalog.t
(** [catalog t] is the validated built-in provider catalog. It is constructed
    once by {!create} from the same registrations that drive runtime effects. *)

(** {1 Provider client construction} *)

val client :
  t ->
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  now:Mentat_provider.Credential.timestamp ->
  ?base_url:string ->
  ?auth_base_url:string ->
  ?process:Mentat_provider.Credential.t list ->
  ?on_artifact_progress:(Artifact.Progress.t -> unit) ->
  environment:(string * string) list ->
  ?name:Mentat_provider.Credential.Name.t ->
  Mentat_llm.Model.t ->
  (Mentat_llm.Client.t, Error.t) result
(** [client t … model] builds a ready-to-call client for [model]'s provider. It
    resolves the credential (precedence via [Mentat_provider.resolve_credential]
    over the passed [process]/[environment] snapshots and the store snapshot the
    runtime loads), proactively refreshes a near-expiry OAuth token, calls the
    driver's [build_client] with [?base_url], and wraps the result with the
    reactive refresh policy and, for local providers, the artifact-prepare gate.
    A provider-local resolution failure returns {!Error.Credential}; a
    mandatory-auth provider with no candidate returns
    {!Error.Missing_credential}; and an optional-auth provider (ollama/local)
    builds a bare client. The executable invokes [client] for each claimed
    provider request, then adapts the result to the provider port with
    [Mentat_llm.Client.response]. Construction therefore reloads the stored
    credential for every request; a completed save or logout affects the next
    call. A construction error occurs after the provider claim and the
    executable maps it onto the port with {!Error.to_llm}.

    The built client never blocks on interactive re-auth: its only auth-adjacent
    effect during a call is the one non-interactive reactive refresh (refresh,
    rebuild, and retry the same request once on a [Startup]-phase [Auth]
    failure). The client is confined to that request. Local artifact preparation
    remains safe under this lifetime: preparation is idempotent, an installed
    artifact takes the filesystem-status fast path, concurrent installers use
    distinct verified candidates, and local managed servers are owned by [sw]
    rather than by a client value. [on_artifact_progress], when supplied,
    receives that preparation's progress so the executable can adapt it onto the
    protocol's model-download flow; it fires only while a local provider fetches
    a missing artifact and never for an already-installed model or a remote
    provider. Noticing a blocked account and starting a {!Login.run} is the
    executable's. *)

(** {1 Account discovery} *)

val discover_accounts :
  t ->
  ?process:Mentat_provider.Credential.t list ->
  environment:(string * string) list ->
  unit ->
  (Mentat_provider.Account.Discovery.t list, Store_error.t) result
(** [discover_accounts t ~environment ()] reads the credential store once and
    resolves every catalog declaration from the supplied process/environment
    snapshots. The result preserves catalog order and cardinality; one malformed
    provider candidate remains a [Resolution_failed] entry without erasing
    healthy discoveries. A shared store failure is the outer [Store_error.t].
    [process] defaults to [[]]. Network-free. *)

(** {1 Server listings}

    Providers whose model sets are server-owned publish them through the
    driver check. The runtime retains each provider's last good listing in
    memory for the process lifetime, scoped by the credential fingerprint and
    base URL it was observed under; nothing is persisted, and a rotated
    credential or moved endpoint drops its stale listing. *)

val refresh_listings :
  t ->
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?providers:Mentat_llm.Provider.t list ->
  ?base_url:(Mentat_llm.Provider.t -> string option) ->
  ?auth_base_url:(Mentat_llm.Provider.t -> string option) ->
  ?process:Mentat_provider.Credential.t list ->
  environment:(string * string) list ->
  unit ->
  (unit, Store_error.t) result
(** [refresh_listings t ~sw ~env ?providers ?base_url ?auth_base_url ?process
     ~environment ()] observes every selected provider once, in parallel
    fibers, and retains the resulting listings. Credentials resolve from the
    supplied snapshots exactly as {!discover_accounts} does; a required-auth
    provider with no resolved credential, a provider whose resolution fails,
    and a provider without a check are skipped, not failed. [providers]
    defaults to every catalog provider. A shared store failure is the outer
    error; per-provider observation problems surface through account checks,
    not here. *)

val listings :
  t ->
  ?providers:Mentat_llm.Provider.t list ->
  ?process:Mentat_provider.Credential.t list ->
  ?base_url:(Mentat_llm.Provider.t -> string option) ->
  ?auth_base_url:(Mentat_llm.Provider.t -> string option) ->
  environment:(string * string) list ->
  unit ->
  ( (Mentat_llm.Provider.t * Mentat_provider.Listing.t) list,
    Store_error.t )
  result
(** [listings t ?providers ?process ?base_url ?auth_base_url ~environment ()]
    is the retained listing of every selected provider whose slot still
    matches the provider's currently resolving credential fingerprint and
    endpoint overrides, in catalog order. [providers] defaults to the whole
    catalog. Feed the result to
    [Mentat_provider.Model_readiness.of_catalog]'s [listings]. Network-free.
*)

(** {1 The interactive login flow} *)

module Login : sig
  (** Public login/logout orchestration over {!t}. This authority facade keeps
      the private runtime representation out of the public surface while using
      the provider library's account and logout vocabularies directly. *)

  module Progress = Mentat_provider.Auth.Login.Progress
  (** Canonical ephemeral login progress. The frontend opens the browser and
      renders the challenge; the runtime never opens a browser. These display
      capabilities must not be logged, transcribed into a session, or stored. *)

  type terminal =
    | Saved of Mentat_provider.Account.t
        (** An interactive flow minted and durably settled a credential. *)
    | Cancelled
        (** Explicit cancellation won before a local credential existed. *)

  val run :
    t ->
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    provider:Mentat_llm.Provider.t ->
    method_id:Mentat_provider.Auth.Login.Id.t ->
    ?name:Mentat_provider.Credential.Name.t ->
    ?base_url:string ->
    ?auth_base_url:string ->
    ?cancel:unit Eio.Promise.t ->
    progress:(Progress.t -> unit) ->
    unit ->
    (terminal, Error.t) result
  (** Interpret the provider's declared login protocol run-to-completion,
      emitting {!Progress.t} values and settling the exact persisted credential.
      A completed protocol yields [Saved], cancellation yields [Cancelled], and
      every dispatch, protocol, store, or applicable base-URL failure is a
      structured [Error]. [name] defaults to
      [Mentat_provider.Credential.Name.default]; absent [cancel] means only
      fiber cancellation can preempt the flow. API-key and external methods are
      not interactive; use {!save_api_key} for API keys. Explicit cancellation
      races callback waiting, TLS setup, and token exchange until a local secret
      exists; after that point the flow settles or returns an outer error. OAuth
      expiry timestamps use the runtime clock at the protocol effect that
      produces them. *)

  val save_api_key :
    t ->
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    provider:Mentat_llm.Provider.t ->
    ?name:Mentat_provider.Credential.Name.t ->
    ?base_url:string ->
    ?auth_base_url:string ->
    key:string ->
    unit ->
    (Mentat_provider.Account.t, Error.t) result
  (** [save_api_key t … ~key ()] validates that [provider] is registered and its
      declaration accepts API keys, then observes and persists the candidate
      under the provider/name credential lock. Empty or invalid UTF-8 key text
      is a structured error. The sole store edit is cancellation-protected and
      the returned account is the observation of the exact committed secret.
      [auth_base_url] reroots a check that observes the provider's console
      rather than its gateway root. [name] defaults to
      [Mentat_provider.Credential.Name.default]. *)

  val logout :
    t ->
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    provider:Mentat_llm.Provider.t ->
    ?name:Mentat_provider.Credential.Name.t ->
    ?revoke:bool ->
    ?auth_base_url:string ->
    ?process:Mentat_provider.Credential.t list ->
    environment:(string * string) list ->
    unit ->
    (Mentat_provider.Account.Logout.t, Error.t) result
  (** [logout t ~sw ~env ~provider ?name ?revoke ?auth_base_url ?process
       ~environment ()] removes one stored credential and returns discovery from
      the exact post-settlement store snapshot plus the supplied source
      snapshots. [name] defaults to [Mentat_provider.Credential.Name.default],
      [revoke] to [false], [auth_base_url] to the provider's issuer, and
      [process] to [[]].

      With [~revoke:true], settlement conditionally removes only the observed
      secret, so a concurrently superseding credential remains stored and is
      reported as [Mentat_provider.Account.Logout.Superseded]. The runtime never
      reads the process environment itself. Cancellation during the remote
      revoke can leave provider state unknown and may be retried; only a
      returned value attests the local settlement. *)
end

(** The one-shot loopback listener, published narrowly for flows outside
    the provider login that need a browser round-trip — the GitHub
    app-manifest setup is the consumer. The full OAuth interpreter stays
    private; this facade carries exactly the callback await. *)
module Loopback : sig
  val await_once :
    stdenv:Eio_unix.Stdenv.base ->
    ?provider:string ->
    ?on_ready:(unit -> unit) ->
    ?accept:(Uri.t -> bool) ->
    ?serve:(path:string -> string option) ->
    redirect_uri:Uri.t ->
    timeout_s:float ->
    unit ->
    (Uri.t, string) result
  (** [await_once ~stdenv ~redirect_uri ~timeout_s ()] binds the loopback
      address and port of [redirect_uri] and waits for the first request on
      its path that [accept] admits, returning the absolute callback URI —
      secret-bearing, since it carries the flow's one-time code. Stray or
      unaccepted requests are answered and never consume the shot;
      [serve ~path] may hand the browser an entry page for a request off
      the callback path ([Some page] answers 200 as HTML); [on_ready]
      fires once the socket listens; the wait expires loudly after
      [timeout_s]. [Error message] is display-safe: the timeout, a bind
      failure, or a malformed redirect URI. *)
end

(** {1 Local model artifacts (local providers only)} *)

module Local : sig
  val status : t -> Mentat_llm.Model.t -> Artifact.Status.t option
  (** [None] for a remote (non-local) provider. *)

  val download :
    t ->
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    force:bool ->
    observe:(Artifact.Progress.t -> unit) ->
    Mentat_llm.Model.t ->
    Artifact.Download_outcome.t
  (** The explicit, force-able download flow. [Not_downloadable] for a provider
      with no local artifact. Implicit first-request preparation is transparent
      inside {!client}'s local client. *)
end
