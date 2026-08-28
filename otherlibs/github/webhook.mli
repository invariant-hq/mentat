(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Webhook delivery verification.

    GitHub signs each webhook delivery with an HMAC-SHA256 over the raw
    request body, keyed by the hook's shared secret, and presents it in the
    [X-Hub-Signature-256] header as [sha256=<hex>]. {!verify} checks one
    delivery against one secret. *)

val verify : secret:string -> signature:string -> body:string -> bool
(** [verify ~secret ~signature ~body] is [true] iff [signature] is the
    well-formed [X-Hub-Signature-256] value for [body] under [secret]:
    the literal [sha256=] prefix followed by the lowercase or uppercase
    hex encoding of [HMAC-SHA256(secret, body)].

    [body] must be the raw request bytes exactly as received — the
    signature does not survive any re-encoding. The digest comparison
    runs in constant time in the position of the first differing byte,
    so timing cannot narrow a forged digest. The hex grammar is strict —
    exactly 64 hex digits, no whitespace — and a malformed [signature]
    is [false], indistinguishable from a clean mismatch, so a caller that
    answers every [false] identically leaks nothing about why a delivery
    was refused. *)
