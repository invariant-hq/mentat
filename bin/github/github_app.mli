(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The GitHub App's API surface: the app JWT, the manifest flow's documents,
    the conversion exchange, the installation-token mints, and the hook-config
    projection.

    Everything here is either pure (the JWT encoding, the manifest and entry
    page, the hook-URL derivation) or one bounded call over {!Github_api} —
    no retries, no caches, no disk. Credential custody lives with the boot
    store; this module receives key bytes and returns tokens, and none of
    its error messages carry either. *)

(** The RS256 app JWT — the credential that authenticates App-level calls. *)
module Jwt : sig
  val skew_s : int
  (** Seconds the [iat] claim is backdated, absorbing clock skew: 60. *)

  val lifetime_s : int
  (** Seconds from now to the [exp] claim: 540 — under GitHub's 10-minute
      cap with a minute to spare. *)

  val make :
    issuer:string -> key_pem:string -> now:float -> (string, string) result
  (** [make ~issuer ~key_pem ~now] is the signed app JWT: header
      [{"alg":"RS256","typ":"JWT"}], claims [iat = now − skew], [exp = now +
      lifetime], [iss = issuer] (the App's client id — GitHub's preferred
      issuer; the numeric app id is also accepted), each segment base64url
      without padding, signed RSASSA-PKCS1-v1.5-SHA256 over the first two
      segments. Deterministic — no randomness on the signing path — so one
      pinned vector keeps the encoding honest. [Error message] when
      [key_pem] does not decode to an RSA private key or is too small to
      sign with; the message never carries key material. *)
end

(** The app-manifest flow's documents. *)
module Manifest : sig
  val app_name : suffix:string -> string
  (** [app_name ~suffix] is the generated App name the create page is
      pre-filled with, [mentat-review-<suffix>] — App names are global, so
      the caller passes fresh randomness; the owner can edit it in place on
      GitHub's page, and the conversion returns whatever was chosen. *)

  val web_base : api_base:string -> string
  (** [web_base ~api_base] is the browser-facing host the create page lives
      on: [https://github.com] for the public API base, and for a GHES base
      the host with its [/api/v3] suffix stripped. *)

  val create_url : web_base:string -> org:string option -> state:string -> string
  (** [create_url ~web_base ~org ~state] is the GitHub page the entry page
      posts the manifest to: [<web_base>/settings/apps/new?state=<state>],
      or the organization's create page under [org]. *)

  val hook_url : public_url:string option -> ingress_id:string -> string
  (** [hook_url ~public_url ~ingress_id] is the webhook target the manifest
      (and every later hook-config upsert) carries:
      [<public_url>/ingress/github/<ingress_id>] when the owner has a
      public URL, else the RFC 2606 placeholder
      [https://unrouted.invalid/ingress/github/<ingress_id>] — the hook is
      born active with an unroutable target, because the hook-config PATCH
      can re-point a URL but cannot flip [active], and an inactive-at-birth
      hook would need a by-hand GitHub settings visit. *)

  val json :
    name:string ->
    homepage:string ->
    redirect_url:string ->
    hook_url:string ->
    string
  (** [json ~name ~homepage ~redirect_url ~hook_url] is the manifest
      document the create page consumes, encoded: [public: false] (only
      this owner installs it), the [pull_request] event, and the three
      permissions — contents read, pull requests write, metadata read. *)

  val entry_page : create_url:string -> manifest:string -> string
  (** [entry_page ~create_url ~manifest] is the HTML page the loopback
      listener serves the browser: a form carrying [manifest] in its one
      [manifest] field, posting to [create_url], submitted by script on
      load with a visible button as the no-script fallback. *)
end

(** The manifest conversion — the one unauthenticated call. *)
module Conversion : sig
  type t = {
    app_id : int;  (** The created App's numeric id. *)
    slug : string;  (** The URL slug — the [<slug>[bot]] posting identity. *)
    name : string;  (** The name actually chosen on GitHub's page. *)
    client_id : string;  (** The client id — the preferred JWT issuer. *)
    html_url : string;  (** The App's page. *)
    webhook_secret : string option;
        (** The App-level HMAC key GitHub minted; checked live whether it
            is ever omitted when the hook target is a placeholder. *)
    pem : string;  (** The RS256 private key, PEM. *)
  }
  (** The type for conversion results. The client secret GitHub also
      returns is deliberately not carried: it authenticates user-to-server
      OAuth flows this design never performs, and an unused credential on
      disk is pure liability. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] reads a conversion response narrowly — the carried
      members and nothing else. An [Error] names the missing or ill-typed
      member; it never carries the key or secret bytes. *)

  val exchange : Github_api.t -> code:string -> (t, string) result
  (** [exchange api ~code] is [POST /app-manifests/<code>/conversions] —
      unauthenticated by design, so [api] should carry no token — decoded
      with {!decode}. The code is one-shot and expires within the hour;
      a spent or expired code is GitHub's 404, passed through as the
      client's display-safe message. *)
end

(** Installation-token mints — A3: every mint is narrowed. *)
module Mint : sig
  val installation_id :
    Github_api.t ->
    repo:string ->
    (int, [ `No_installation | `Error of string ]) result
  (** [installation_id api ~repo] resolves the App's installation covering
      [repo] ([owner/name]) — [GET /repos/<repo>/installation] under a JWT
      client. [`No_installation] is GitHub's 404: the App is not installed
      there, and the caller names the install page. *)

  type scope =
    | Read
        (** [contents: read], [pull_requests: read] — the git fetch and the
            three API reads. *)
    | Write  (** [pull_requests: write] — the poster child alone. *)

  val access_token :
    Github_api.t ->
    installation_id:int ->
    repo:string ->
    scope:scope ->
    (string, string) result
  (** [access_token api ~installation_id ~repo ~scope] mints one
      installation token — [POST /app/installations/<id>/access_tokens]
      under a JWT client — narrowed in the request body to [repo]'s name
      and [scope]'s permissions: the read mint cannot write, the write mint
      reaches one repository's pull requests, and either dies within the
      hour. The token lives only in process memory; no error message
      carries it. *)
end

(** The hook-config projection — GitHub's hook config as a function of the
    credential home's files (A8). *)
module Hook : sig
  val upsert : Github_api.t -> url:string -> secret:string -> (unit, string) result
  (** [upsert api ~url ~secret] writes the {e complete} hook config —
      [PATCH /app/hook/config] under a JWT client with [url], [secret],
      and [content_type: json] — so re-running any verb that calls it
      converges. A failure leaves local truth ahead of GitHub; the caller
      says "re-run". *)

  val current_url : Github_api.t -> (string, string) result
  (** [current_url api] is the live hook config's URL —
      [GET /app/hook/config] — the doctor's drift probe. The config read
      never returns the secret, so secret drift is invisible here and
      surfaces as the ingress 401 counter instead. *)
end

(** The doctor's App-level reads. *)
module Doctor : sig
  val app_identity : Github_api.t -> (string * string, string) result
  (** [app_identity api] is the App's [(slug, name)] from [GET /app] under
      a fresh JWT — proof the App still exists and the stored key still
      signs. *)

  val installations : Github_api.t -> ((int * string) list, string) result
  (** [installations api] is the App's installations as
      [(id, account login)] rows, across pagination — where the owner
      installed it. *)
end
