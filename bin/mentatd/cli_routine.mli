(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [routine] command group: standing, unattended review grants.

    A routine is one directory of owner-written policy under the config home;
    these verbs are its owner surface. [routine add PATH|DIR] validates a
    routine (a directory, or a path to its [routine.json]), installs it under
    its own name, and — for a webhook routine — mints its ingress URL token
    and webhook secret where absent, printing the URL path to paste into
    GitHub settings; re-adding replaces the policy files and keeps the
    identity, so owner edits never move the webhook URL. [routine list]
    renders the roster — name, policy digest, enabled, last disposition —
    with a broken routine shown as its load error, never omitted.
    [routine runs NAME] prints the disposition receipts, one line each;
    [routine status \[NAME\]] renders the durable-record fold per routine:
    spend and spawn counts over their trailing fence windows against the
    budget, and the most recent receipt. [routine remove NAME] deletes the
    routine's configuration — secrets and webhook identity included, so a
    later re-add mints a fresh URL — and deliberately keeps the state home's
    record, naming it: receipts and claim markers are the audit trail.

    [routine fire NAME --event FILE | --sweep] runs the fire pipeline in
    this process — gate, identity claim, receipts, budget fences, checkout
    provisioning, the sealed review run, publication, alerts — so a crontab
    line is a complete review routine with no resident node. It needs the
    routine's [secrets/read-token] for its GitHub reads and spawns the run
    and publication children from the [mentat] binary beside this
    executable ([MENTAT_BIN] overrides); a bare fire is refused,
    since every version-1 routine reviews pull requests and has nothing to
    run without a delivery. The other verbs need no workspace, session
    store, or network: they read and write the config and state homes only.

    Exit codes: 0 when every event was disposed (a run's own failure is a
    receipt and an alert, never this exit); 1 when a routine, file, or
    receipt log cannot be read, written, or validated, or the pipeline's
    machinery failed; 2 when a name, path, or flag combination is
    malformed; 130 when the owner interrupted a fire. *)

val cmd : int Cmdliner.Cmd.t
