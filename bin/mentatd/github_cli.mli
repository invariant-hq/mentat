(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [mentatd github] command group — the owner-facing surface of the
    client-owned GitHub App.

    Four verbs over the owner-level credential home: [setup] drives GitHub's
    app-manifest flow (the browser opens on GitHub's pre-filled create page,
    one click, the one-shot loopback listener receives the conversion code,
    the credential home is written atomically); [status] is the doctor —
    the local half needs no network, the network half proves the App exists,
    the key signs, and the installations cover the App routines; [repoint]
    and [rotate-secret] re-derive GitHub's one hook config from local files
    and upsert it whole. The verbs live on [mentatd] because the App exists
    to serve routines, and routines are the unattended layer's
    configuration. *)

val cmd : int Cmdliner.Cmd.t
(** [cmd] is the [github] command group. *)
