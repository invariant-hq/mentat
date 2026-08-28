(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The production HTTP requester behind the GitHub client.

    The [github] library performs no I/O: its client runs over an injected
    requester. This adapter is the one production requester both binaries
    snap onto it — one connection per request, TLS from the system trust
    store with endpoint identity verified against each request's host, and
    display-safe transport messages. *)

val make :
  ?base_url:string ->
  ?token:string ->
  _ Eio.Net.t ->
  (Github.Api.t, Github.Api.Error.t) result
(** [make ~token net] is a GitHub client whose requester opens one
    connection per request over [net]. Redirects are not followed — a
    [3xx] answer is a response error like any other non-[2xx] — so the
    authorization header goes only where the client itself asked.
    [base_url] as in {!Github.Api.of_http}; an [http://] base is served
    unencrypted. Every request carries this product's user agent. Errors
    with a transport error when the system trust store yields no TLS
    configuration. *)
