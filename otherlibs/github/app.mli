(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** A GitHub App's API surface: the app JWT, the manifest flow's documents,
    the conversion exchange, narrowed installation-token mints, the
    hook-config projection, and the App-level identity reads.

    Everything here is either pure (the JWT encoding, the manifest and entry
    page) or one bounded call over {!Api} — no retries, no caches, no disk.
    Credential custody stays with the caller; this module receives key bytes
    and returns tokens, and none of its error messages carry either. *)

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

(** The app-manifest flow's documents.

    GitHub's manifest flow creates an App in one browser round-trip: the
    caller serves {!entry_page}, whose form posts {!val-json} to
    {!create_url}; GitHub redirects back with a one-shot code the caller
    exchanges through {!Conversion}. *)
module Manifest : sig
  val web_base : api_base:string -> string
  (** [web_base ~api_base] is the browser-facing host the create page lives
      on: [https://github.com] for the public API base, and for a GitHub
      Enterprise base the host with its [/api/v3] suffix stripped. *)

  val create_url : web_base:string -> org:string option -> state:string -> string
  (** [create_url ~web_base ~org ~state] is the GitHub page the entry page
      posts the manifest to: [<web_base>/settings/apps/new?state=<state>],
      or the organization's create page under [org]. *)

  val json :
    name:string ->
    homepage:string ->
    redirect_url:string ->
    hook_url:string ->
    events:string list ->
    permissions:(string * string) list ->
    string
  (** [json ~name ~homepage ~redirect_url ~hook_url ~events ~permissions]
      is the manifest document the create page consumes, encoded. [events]
      are the webhook event names the App subscribes to; [permissions] are
      [(permission, access)] pairs such as [("contents", "read")]. The
      manifest pins [public: false] — only the creating account installs
      the App — and a hook that is active at birth, so a caller with no
      routable hook target yet should pass a placeholder URL and re-point
      the hook config later ({!Hook.upsert}): the hook-config update can
      move the URL but cannot flip [active], and an inactive-at-birth hook
      could only be enabled by hand in GitHub's settings. *)

  val entry_page : create_url:string -> manifest:string -> string
  (** [entry_page ~create_url ~manifest] is an HTML page to serve the
      browser: a form carrying [manifest] in its one [manifest] field,
      posting to [create_url], submitted by script on load with a visible
      button as the no-script fallback. *)
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
        (** The App-level HMAC key GitHub minted; observed live whether it
            is ever omitted when the hook target is a placeholder. *)
    pem : string;  (** The RS256 private key, PEM. *)
  }
  (** The type for conversion results. The client secret GitHub also
      returns is deliberately not carried: it authenticates user-to-server
      OAuth flows this module does not implement, and an unused credential
      on disk is pure liability. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] reads a conversion response narrowly — the carried
      members and nothing else. An [Error] names the missing or ill-typed
      member; it never carries the key or secret bytes. *)

  val exchange : Api.t -> code:string -> (t, string) result
  (** [exchange api ~code] is [POST /app-manifests/<code>/conversions] —
      unauthenticated by design, so [api] should carry no token — decoded
      with {!decode}. The code is one-shot and expires within the hour;
      a spent or expired code is GitHub's 404, passed through as the
      client's display-safe message. *)
end

(** Installation-token mints — every mint is narrowed. *)
module Mint : sig
  val installation_id :
    Api.t ->
    repo:string ->
    (int, [ `No_installation | `Error of string ]) result
  (** [installation_id api ~repo] resolves the App's installation covering
      [repo] ([owner/name]) — [GET /repos/<repo>/installation] under a JWT
      client. [`No_installation] is GitHub's 404: the App is not installed
      there, and the caller decides what to tell the user. *)

  val access_token :
    Api.t ->
    installation_id:int ->
    repo:string ->
    permissions:(string * string) list ->
    (string, string) result
  (** [access_token api ~installation_id ~repo ~permissions] mints one
      installation token — [POST /app/installations/<id>/access_tokens]
      under a JWT client — narrowed in the request body to [repo]'s name
      and exactly [permissions], given as [(permission, access)] pairs
      such as [("pull_requests", "write")]: the token reaches one
      repository with the named accesses and nothing else, and dies within
      the hour. The token lives only in process memory; no error message
      carries it. *)
end

(** The hook-config projection — GitHub's App-level hook config rewritten
    whole from the caller's stored truth. *)
module Hook : sig
  val upsert : Api.t -> url:string -> secret:string -> (unit, string) result
  (** [upsert api ~url ~secret] writes the {e complete} hook config —
      [PATCH /app/hook/config] under a JWT client with [url], [secret],
      and [content_type: json] — so re-running any caller that derives the
      config from its own records converges. A failure leaves the caller's
      records ahead of GitHub; re-running repairs it. *)

  val current_url : Api.t -> (string, string) result
  (** [current_url api] is the live hook config's URL —
      [GET /app/hook/config] — for drift checks against the caller's
      records. The config read never returns the secret, so secret drift
      is invisible here and surfaces only as signature rejections on the
      receiving endpoint. *)
end

(** {1:identity App-level reads} *)

val identity : Api.t -> (string * string, string) result
(** [identity api] is the App's [(slug, name)] from [GET /app] under a
    fresh JWT — proof the App still exists and the stored key still
    signs. *)

val installations : Api.t -> ((int * string) list, string) result
(** [installations api] is the App's installations as
    [(id, account login)] rows, across pagination — where the App's owner
    installed it. *)
