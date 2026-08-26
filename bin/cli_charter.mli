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
    later re-add mints a fresh URL — and deliberately keeps the state home's
    record, naming it: receipts and claim markers are the audit trail.

    [charter fire NAME --event FILE | --sweep] runs the fire pipeline in
    this process — gate, identity claim, receipts, budget fences, checkout
    provisioning, the sealed review run, publication, alerts — so a crontab
    line is a complete review charter with no resident node. It needs the
    charter's [secrets/read-token] for its GitHub reads and spawns the run
    and publication children from this executable; a bare fire is refused,
    since every version-1 charter reviews pull requests and has nothing to
    run without a delivery. The other verbs need no workspace, session
    store, or network: they read and write the config and state homes only.

    Exit codes: 0 when every event was disposed (a run's own failure is a
    receipt and an alert, never this exit); 1 when a charter, file, or
    receipt log cannot be read, written, or validated, or the pipeline's
    machinery failed; 2 when a name, path, or flag combination is
    malformed; 130 when the owner interrupted a fire. *)

val cmd : int Cmdliner.Cmd.t
