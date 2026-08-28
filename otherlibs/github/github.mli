(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** GitHub REST client, App machinery, and webhook verification.

    {!Api} is the bounded REST client every other module speaks through; its
    HTTP transport is one injected closure, so this library performs no I/O
    of its own. {!App} covers a GitHub App's lifecycle: the RS256 app JWT,
    the app-manifest creation flow, the manifest-code conversion, narrowed
    installation-token mints, and the App-level webhook configuration.
    {!Reads} is a small set of pull-request queries. {!Webhook} verifies a
    webhook delivery's signature over the raw body in constant time.

    NAMING: opam release name TBD; [github] is taken upstream. *)

module Api = Api
module App = App
module Reads = Reads
module Webhook = Webhook
