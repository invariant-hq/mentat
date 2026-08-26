(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The daemon host and its wire.

    [mentat.server] promotes the composition root's host side behind a socket,
    so a remote TUI, a headless CLI, or a programmatic client speaks the exact
    {!Mentat_client.Driver.t} it already speaks in-process — now over a wire. It
    owns both directions of one endpoint-descriptor table: {!serve} dispatches a
    wire request to a {!Mentat_client.Driver.t}'s fields and streams its feeds;
    {!connect} fills a {!Mentat_client.Driver.t} from a socket, handed to
    {!Mentat_client.make}. One table serving both derivations is what keeps them
    from drifting; {!connect}'s first exercised consumer is the parity test that
    proves behavioural identity.

    It links {!Mentat_protocol}, {!Mentat_client}, a socket transport, and [eio]
    — and
    {b never an engine, a store, a provider transport, or a rendering surface}.
    That exclusion is the boundary invariant it is admitted under. A frontend
    links {!Mentat_client}, never this library, so the frontend firewall is
    untouched: only the composition root consumes both directions.

    The unix-socket transport, the loopback browser edge ({!Web}), and the
    parity harness all ship. *)

(** {1:tokens Connection tokens}

    A per-daemon bearer secret. Possession is an all-or-nothing grant to run
    code as the user: a valid token resolves [Local_user], who may approve a
    shell-executing tool call. Token secrecy is the security model. *)

module Token : sig
  type t
  (** The type for a connection token. *)

  val generate : unit -> t
  (** [generate ()] is a fresh CSPRNG token of at least 128 bits, drawn from
      [Mirage_crypto_rng] (never stdlib [Random]). A daemon regenerates it on
      every start, so token rotation is a restart. *)

  val of_string : string -> t
  (** [of_string s] is the token spelled [s] — the value a client reads from the
      discovery file to present at the handshake. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s wire spelling, for writing the discovery file. *)

  val equal : t -> t -> bool
  (** [equal a b] compares in {b constant time}, independent of where the first
      differing byte lies, so a comparison cannot leak the token by timing. *)
end

(** {1:origins Origin allow-listing}

    The [Origin]/[Host] allowlist {!Web.serve} checks unconditionally on every
    authenticated browser request, loopback included: a bearer credential is not
    enough against a confused-deputy browser or DNS rebinding. The JSON wire
    carries no browser and no ambient-credentialled origin, so only the browser
    edge consults it. *)

module Origin : sig
  type t
  (** The type for an allow-listed browser origin. *)

  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
end

(** {1:bind The sole listener constructor}

    [Bind] is the only way to describe a listener, for both this JSON wire and
    the future [mentat.web] browser surface. Each constructor carries everything
    its safety requires, and both bind the local machine only — a unix socket or
    the loopback interface. A public (non-loopback) listener is deliberately
    absent: if one ever lands it enters here as a new constructor carrying its
    own safety requirements, so an open agent port without them can never
    type-check. *)

module Bind : sig
  type t
  (** The type for a listener description. It doubles as the dial target
      {!connect} reaches the daemon through. *)

  val unix : dir:Lpath.Abs.t -> t
  (** [unix ~dir] is a unix-domain socket at [dir]/[mentat.sock]. The auth
      boundary is the filesystem: [dir] is created (and asserted) mode 0700 and
      the socket 0600, so only the daemon's own uid can traverse to and open the
      socket; no token is needed. {b Stage-1 status:} the additional
      [SO_PEERCRED]/[getpeereid] peer-uid check is {b not} performed — neither
      Eio nor the stdlib exposes it without a C stub, and this campaign adds
      none, so it is deferred; the 0700/0600 discipline is the enforced same-uid
      boundary in the meantime. *)

  val loopback : port:int option -> token:Token.t -> t
  (** [loopback ~port ~token] binds 127.0.0.1 only. [None] requests an ephemeral
      port (written to the discovery file). A token is required. *)

  val socket_path : dir:Lpath.Abs.t -> string
  (** [socket_path ~dir] is the native path of the socket a {!unix} bind at
      [dir] creates. The socket's leaf name is owned here; consumers that
      display, dial, or remove the endpoint derive the path rather than
      restating the literal. *)

  val remove_endpoint : dir:Lpath.Abs.t -> unit
  (** [remove_endpoint ~dir] best-effort removes the on-disk residue a {!unix}
      bind leaves once its server is gone: the socket file, then [dir] itself.
      A path that resists — a non-empty or foreign directory — is left behind
      as diagnosable residue; never an error. *)
end

type listener
(** The type for a bound, listening socket. *)

val listen : sw:Eio.Switch.t -> net:_ Eio.Net.t -> Bind.t -> listener
(** [listen ~sw ~net bind] creates and binds the socket [bind] describes, ready
    for {!serve}. It performs the 0700 directory and 0600 socket discipline for
    a {!Bind.unix} target. *)

val port : listener -> int option
(** [port listener] is the TCP port a loopback [listener] bound — the daemon
    reads it to name the browser URL when the bind requested an ephemeral port.
    [None] for a {!Bind.unix} listener, which carries no port. *)

(** {1:ingress The webhook ingress}

    A content-neutral route family {!serve} mounts when given an {!Ingress.t} —
    the third pre-auth surface beside the handshake and [GET /health]:

    {v POST /ingress/github/<ingress-id> v}

    [<ingress-id>] is an opaque path token (a high-entropy capability, a second
    factor but never the authenticator). The family does exactly one thing:
    authenticate each delivery end-to-end — [X-Hub-Signature-256], an
    HMAC-SHA256 over the {b raw} request body, compared in constant time — and
    hand the verified bytes to the injected callback. Verification and routing
    live here;
    what a verified delivery {e means} (receipts, gates, spawning) is entirely
    the callback owner's.

    The family shares nothing with the other surfaces: it never consults the
    bearer token, the endpoint table, the handshake bindings, or the browser
    edge's cookie/[Origin] machinery — a valid wire token grants nothing under
    [/ingress/], and a valid delivery signature grants nothing outside it.

    Every refusal is answered, never raised, and {b content-free} (an empty
    body; an internet-facing endpoint gets garbage, and garbage deserves no
    detail): an id {!Ingress.resolution.Unknown} to the resolver is [404]; an
    absent [X-Hub-Signature-256], an undecodable one, and a clean mismatch are
    one indistinguishable [401] (the SHA-1 [X-Hub-Signature] is never
    consulted); a body over 1 MiB is [413], its read capped so the excess is
    never buffered; anything under [/ingress/] that is not the family's one
    route shape is [404]. A verified delivery answers by the callback:
    [`Accepted] is a content-free [202], [`Refused] a content-free [500]. *)

module Ingress : sig
  type resolution =
    | Resolved of { secret : string; enabled : bool }
        (** The configuration answering to an ingress id: the webhook secret
            its deliveries are verified against, and whether it is enabled. A
            disabled configuration {b still verifies} against the retained
            secret — disabling is owner intent, not hook failure, and an
            unverified delivery must not be able to observe even that much —
            and [enabled] is passed through to {!t.deliver} unread, so
            interpreting it (a skipped-disabled receipt, say) stays with the
            callback. *)
    | Unknown
        (** Nothing answers to the id (never minted, or removed): a
            content-free [404]. *)
  (** The type for the resolver's answer: one consistent snapshot — secret and
      enabled state read together — that both the verification and the
      delivery of a single request use. *)

  type t = {
    resolve : ingress_id:string -> resolution;
        (** Resolve an ingress id to its snapshot. Called once per
            syntactically well-formed request, before the body is read. *)
    deliver :
      ingress_id:string ->
      enabled:bool ->
      event:string option ->
      delivery_id:string option ->
      body:string ->
      [ `Accepted | `Refused of string ];
        (** Take custody of one {b verified} delivery: [body] is the exact raw
            bytes the signature was checked over, [enabled] the snapshot
            {!resolve} answered (so the decision is made on the state the
            signature was verified under, without a second resolve). [event]
            and [delivery_id] are the [X-GitHub-Event] and [X-GitHub-Delivery]
            header values as received, [None] when absent; {b headers are not
            covered by the body HMAC}, so both ride through unverified —
            useful identity for receipts (a [ping] versus a [pull_request], a
            delivery GUID before any payload decodes), never trusted input.
            [`Accepted] means custody is durable — answered as [202]
            immediately, before any interpretation work. [`Refused reason]
            means it is not (a receipt that cannot be written): answered as a
            content-free [500] so the sender retries or its log shows the
            failure; [reason] is logged, never sent. Report failure as
            [`Refused], never by raising — though a raise is caught into a
            content-free [500] with the exception logged, so it can never
            tear the connection down responseless. *)
    rejected : (ingress_id:string -> unit) option;
        (** Observe one delivery refused as a [401] — an absent, undecodable,
            or mismatched signature on a resolved id. [None] ignores
            refusals; the family still answers the [401] either way. The hook
            fires on the [401] path only — never for an [Unknown] id ([404])
            or an oversized body ([413]) — so a counter behind it meters
            exactly the forged-delivery pressure on a minted id. A raise is
            caught and logged; the [401] is answered regardless. *)
  }
  (** The type for the ingress configuration: the callbacks the family routes
      through. All run on the serving fiber; keep them prompt (resolve a
      handful of ids, append one receipt), never blocking on gate or run
      work. *)
end

(** {1:serve Serving a driver over the wire} *)

type target = {
  workspace : string option;
      (** The canonically-bound workspace root, echoed in the handshake so a
          client can refuse a wrong-checkout attach. [None] is an unbound
          connection (not offered in Stage 2 — see {!serve}). *)
  driver : Mentat_client.Driver.t;
      (** The driver this connection's requests dispatch to. The composition
          root's registry may hand back a composite whose session-cone fields
          route by session id; {!serve} neither knows nor cares. *)
  on_close : unit -> unit;
      (** Run exactly once when the connection ends — by normal close, error, or
          server cancellation. It must not raise; a raise is logged and
          swallowed. *)
}
(** The per-connection binding {!serve} establishes at the handshake: the driver
    a connection's requests reach, plus its teardown hook. *)

val serve :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?heartbeat_s:float ->
  ?ledger_cap:int ->
  ?ingress:Ingress.t ->
  driver_for:
    (workspace:string option ->
    environment:(string * string) list option ->
    (target, Mentat_protocol.Error.t) result) ->
  listener ->
  unit
(** [serve ~sw ~clock ?heartbeat_s ?ledger_cap ?ingress ~driver_for listener]
    runs the accept loop. Each connection's {b first} request must be
    [POST /handshake];
    [serve] calls [driver_for] with the requested workspace — and the
    environment the client offered, which matters only to the handshake that
    (re)boots a workspace instance; a live instance keeps the environment it
    booted with — and binds the returned {!target} to that connection's
    identity. Every later request on that connection — decoded, its descriptor
    resolved, the matching [driver] field invoked, the result encoded; a session
    feed streamed as SSE, the login flow as its own stream — dispatches to the
    bound driver. [driver_for] returning [Error] refuses the handshake with that
    structured error and leaves the connection unbound; a non-handshake request
    on an unbound connection is answered with a structured "not bound" error. A
    logical client spans several TCP connections (a feed GET, POST bursts),
    {b each with its own handshake and binding}; [on_close] therefore fires per
    connection, exactly once.

    The daemon refuses an {b absent} handshake workspace via its [driver_for]:
    the [workspace : string option] stays optional on the wire, but Stage 2
    binds no unbound connection until a real unbound consumer exists.

    [clock] paces the SSE keep-alive, whose idle interval is [heartbeat_s]
    seconds (default [15.]). It answers a pre-auth, content-free [GET /health].
    Given [ingress], it also mounts the {{!section-ingress}webhook ingress}
    family, which then owns every path under [/ingress/] — resolved before, and
    never through, the bearer check and the endpoint table; without [ingress]
    no such family exists and those paths answer as any other unknown route. It
    blocks until [sw] is cancelled.

    The request-id find-or-create ledger that dedups a lost-ack retry of a
    [Requires_request_id] operation is daemon-global and {b bounded}: it holds
    at most [ledger_cap] (default [1024]) outcomes and evicts the oldest, so it
    cannot grow for the daemon's lifetime. It is a backstop over the reconnect
    window, not an unbounded exactly-once guarantee; its key is the
    client-minted request-id alone, so collision safety rests on that id being a
    {b >=128-bit random} value (which {!connect} mints; a raw wire client
    carries the obligation).

    A mid-stream client disconnect promptly releases that connection's feed seam
    or login flow (so a hub becomes evictable rather than pinned); it is not
    held until [sw] teardown.

    The connection model supports N requests per connection unchanged, so a
    future client that reuses a handshaked connection for several requests needs
    no server change; Stage 2's {!connect} does not — it uses one connection per
    logical operation ({b handshake + one request}). *)

(** {1:web The browser edge}

    [Web] mounts a rendering surface — [mentat.web]'s HTML routes — behind
    [mentat.server]'s one shared network edge: the single-use-token →
    [SameSite=Strict], [HttpOnly] cookie exchange, the unconditional
    [Origin]/[Host] allow-listing on every authenticated request (the
    DNS-rebinding and CSRF defense), the strict Content-Security-Policy on every
    response, and URI-redacted logging. The surface is supplied as a
    {!Web.handler} the daemon backs with [mentat.web]; this library renders no
    HTML and links no rendering surface — the two surfaces share this edge, not
    a dispatcher. *)

module Web : sig
  type http = { status : int; headers : (string * string) list; body : string }
  (** One rendered response the surface produced (a [Mentat_web.Routes.Http.t],
      adapted at the daemon). The surface owns the [status], its content type,
      and the [body]; the edge layers the CSP and, on the token exchange, the
      session cookie. *)

  type frame = { id : int option; html : string }
  (** One rendered live fragment (a [Mentat_web.Routes.Frame.t], adapted). [id]
      is the committed sequence the edge writes as the SSE [id:], so a native
      [EventSource] resumes from it; [None] is a droppable live-region morph,
      which carries no [id:]. *)

  type from = [ `Beginning | `After of Mentat_protocol.Position.t ]
  (** A live-feed resume point, resolved from the request ([Last-Event-ID] on
      reconnect, else [?from=]) by the edge, always naming a committed position.
  *)

  type handler = {
    respond :
      meth:string ->
      path:string list ->
      query:(string * string list) list ->
      body:(string * string) list ->
      http;
        (** Route one non-streaming request — [path] split on ['/'] with empty
            segments dropped, [query] decoded, [body] the decoded form (a key to
            its last value) — to a rendered response. *)
    stream :
      sw:Eio.Switch.t ->
      session:Mentat_session.Id.t ->
      from:from ->
      emit:(frame -> unit) ->
      (unit, string) result;
        (** Follow [session]'s live render, pushing each frame to [emit] until
            the feed closes or faults, bound to [sw]. [Ok ()] ends the stream (a
            normal close, or an internal abort the surface logged);
            [Error message] ends it after the edge emits one terminal SSE
            [event: error] frame carrying [message] — the surface's honest
            attach fault, which the browser observes as an [EventSource] error
            and re-attaches from its last committed position. The edge frames
            and paces; the surface owns the projection and its faults. *)
  }

  val content_security_policy : string
  (** The strict CSP the edge stamps on {b every} response. Exported so the
      drift guard can hold it byte-identical to [mentat.web]'s in-page copy —
      the two libraries share no linkable home for one constant (the layering
      boundary forbids a shared link in either direction), so equality is
      enforced by test, not by construction. *)

  val serve :
    sw:Eio.Switch.t ->
    clock:_ Eio.Time.clock ->
    ?heartbeat_s:float ->
    token:Token.t ->
    on_rotate:(Token.t -> unit) ->
    origins:Origin.t list ->
    handler ->
    listener ->
    unit
  (** [serve ~sw ~clock ?heartbeat_s ~token ~on_rotate ~origins handler
       listener] runs the browser accept loop over [listener] (a loopback bind).
      Each request passes the shared edge before reaching [handler]:
      [GET /health] answers pre-auth and content-free; every other request is
      checked against the [origins] allowlist then authenticated — a valid
      session cookie proceeds, and a [?t=] matching the current entry token is
      exchanged for a [SameSite=Strict], [HttpOnly] cookie and a redirect that
      drops the token. The exchange {e consumes and rotates}: the presented
      token is replaced by a freshly minted successor handed to [on_rotate] for
      the owner to republish, so no token ever works twice while one live entry
      URL always exists — re-entry after cookie loss is reading the republished
      URL, not restarting the daemon. Anything else is [401].
      [GET /session/<id>/feed] streams [handler.stream] as SSE (committed frames
      carry their [id:], progress is id-less), pacing the idle keep-alive every
      [heartbeat_s] seconds (default [15.]); every other request routes to
      [handler.respond]. Every response carries the strict CSP. It blocks until
      [sw] is cancelled. *)
end

(** {1:connect Filling a driver from a socket} *)

(** A connection-setup failure, distinct from the per-operation
    {!Mentat_protocol.Error.t} a filled driver settles through. *)
module Error : sig
  type t =
    | Unsupported_version of { server_v : int }
        (** The daemon's floor is below the client's [v_max]; the handshake was
            refused with 409. *)
    | Transport of string
        (** The connection, handshake, or transport failed before any driver
            field could be reached. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a connect error for diagnostics. *)
end

val connect :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  ?workspace:string ->
  ?environment:(string * string) list ->
  Bind.t ->
  (Mentat_client.Driver.t, Error.t) result
(** [connect ~sw ~net ~clock ?workspace ?environment bind] dials the daemon
    [bind] describes, performs the version handshake — binding the connection to
    [workspace] and {b verifying the echo}: a daemon that binds a different
    canonical root than requested is a {!Error.Transport} (the wrong-checkout
    refusal) — and returns a complete {!Mentat_client.Driver.t} whose every
    field is a wire call through the shared descriptor table and whose feed and
    login fields re-materialise the SSE streams into the pull seams
    {!Mentat_client} wraps. [environment] is the invoking process's environment
    snapshot, offered on every handshake (any dial may be the one that re-boots
    an evicted instance); bindings either side cannot spell in UTF-8 are dropped
    rather than fatal. Hand the result to {!Mentat_client.make}; the frontend
    cannot tell it from an in-process fill. Cancellation of [sw], or a feed
    [close] / login [cancel], aborts the connection so the daemon releases its
    stream.

    {b Transport.} [connect] verifies the binding up front on a throwaway
    connection, then every driver-field call and every stream dials a {b fresh}
    connection, speaks its own [POST /handshake] on it (re-binding [workspace]),
    and makes its one request on that same connection — a single-shot closes
    after its response; a feed or login keeps the connection open for the
    stream's life. There is no client-side connection pool; the daemon supports
    reuse unchanged, so pooling is a later pure-client optimization.

    {b Lost-ack backstop and honest ambiguity.} For a [Requires_request_id]
    operation ([review_compose], and [submit]'s Queue_next/Replace_queued),
    [connect] mints one stable request-id per logical invocation and, on a
    {b transport} failure only, retries a bounded number of times reusing it —
    each retry redials and {b re-handshakes} before re-POSTing the same id — so
    the daemon's ledger dedups a lost ack and the effect runs once. A handshake
    refusal (a 409 version mismatch, a wrong-checkout echo) is definite and
    never retried; neither is a decoded error response. If the retries are
    exhausted the operation settles as {!Mentat_protocol.Error.Unavailable}
    naming the ambiguity:
    {b the operation may have been applied; re-follow to observe.} (A structural
    [Admission_unknown] arm stays gated on the protocol [Error] type gaining it
    — the durable-admission wave — and is disclosed in the Stage-1 status
    trail.) *)

(** {1:introspection Introspection}

    For the endpoint parity and name-coverage harness, not a routing surface. *)

val endpoint_names : string list
(** [endpoint_names] is the stable wire name of every single-shot descriptor
    row, in table order. The two streaming endpoints ([session.follow], the
    feed, and [accounts.login]) are not rows and are absent. *)

val requires_request_id_rows : string list
(** [requires_request_id_rows] is the wire name of every single-shot descriptor
    whose [idempotency] field is [Requires_request_id] — the row-level backstop
    surface both the dispatcher and {!connect} derive from that one field (no
    hardcoded parallel list). [session.submit]'s two duplicate variants
    (Queue_next, Replace_queued) are per-variant, not row-level, so they are
    absent here and classified by the one named per-variant predicate. *)

(** {1:flow_codecs The two client-owned flow codecs}

    The outcomes deferred until a transport carried them, minted here. Exposed
    so the wire golden corpus can pin their canonical shapes. *)

val endpoint_shapes :
  (string
  * (string -> (string, string) result)
  * (string -> (string, string) result))
  list
(** For every single-shot endpoint row (in {!table} order), its wire name paired
    with a canonical encoder for its request codec and its response codec. Each
    encoder decodes a representative JSON string through the row's own codec and
    re-encodes it with {!Jsont.Indent}, so the wire golden corpus can byte-pin a
    row's request and response {e shape} — the schema-drift tripwire that parity
    round-trips and name coverage alone do not give — without the test naming or
    constructing the private {!Codecs} request records. A representative JSON
    that does not decode through the row's codec is [Error]. *)

module Flow_codec : sig
  val compaction_result : Mentat_client.compaction_result Jsont.t
  (** The [compact] flow's outcome ([Installed]/[Skipped]). *)

  val login_step : Mentat_client.Login.step Jsont.t
  (** One step of the interactive login stream ([Progress]/[Saved]/[Cancelled]).
  *)
end

(** {1:discovery The daemon discovery file and claim}

    The per-user daemon's discovery file and claim-lock mechanics: the file
    format and its atomic-write discipline, and the claim that serialises daemon
    starts. The daemon binary owns the path policy and process spawning; this
    owns the how. *)

module Discovery : module type of Discovery
