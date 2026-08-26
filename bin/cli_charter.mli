(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [charter] command group: standing, unattended review grants.

    A charter is one directory of owner-written policy under the config home;
    these verbs are its owner surface. [charter add PATH|DIR] validates a
    charter (a directory, or a path to its [charter.json]), installs it under
    its own name, and — for a webhook charter — mints its ingress URL token
    and webhook secret where absent, printing the URL path to paste into
    GitHub settings; re-adding replaces the policy files and keeps the
    identity, so owner edits never move the webhook URL. [charter list]
    renders the roster — name, policy digest, enabled, last disposition —
    with a broken charter shown as its load error, never omitted.
    [charter runs NAME] prints the disposition receipts, one line each;
    [charter status \[NAME\]] renders the durable-record fold per charter:
    spend and spawn counts over their trailing fence windows against the
    budget, and the most recent receipt. [charter remove NAME] deletes the
    charter's configuration — secrets and webhook identity included, so a
    later re-add mints a fresh URL — and deliberately keeps everything under
    the state home, naming it: receipts and run roots are the audit trail.

    [charter fire] is registered but refuses in this build; the fire
    pipeline arrives with the node work.

    None of the verbs needs a workspace, a session store, or the network:
    they read and write the config and state homes only.

    Exit codes: 0 on success; 1 when a charter, file, or receipt log cannot
    be read, written, or validated; 2 when a name or path argument is
    malformed. *)

val cmd : int Cmdliner.Cmd.t
