(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [github] command group: publishing agent results to GitHub.

    [github review] is the publishing half of a review run, kept always dry:
    the findings document arrives on standard input, the reviewed unified diff
    and the already-posted comments arrive as files, and standard output
    carries one compact JSON envelope holding the GitHub API requests that
    would publish the review — the command itself performs no network IO, so
    it has no retry policy and no partial-failure state. The caller (normally
    a CI workflow) sends the requests.

    The envelope's members: [review] is the thread requests, one per blocking
    finding that anchors to the diff and is not already posted; [summary] is
    the single sticky summary request; [threads_safe] is [false] exactly when
    the document carries a blocking finding but no thread is posted this run
    and no blocking finding's fingerprint is already on the pull request —
    the signature of a diff that does not correspond to the head the findings
    were produced at. When [threads_safe] is false no thread requests are
    emitted; the flag names why the list is empty. Each request is an object
    with [label] (the finding's fingerprint, or null), [method], [path], and
    [body] members.

    [--base-label REF] names, for display in the summary comment only, what
    the head was reviewed against; it defaults to "the merge base".
    [--origin TOKEN] is the token stamped into the emitted comment markers so
    coexisting publishers can tell their comments apart; it defaults to
    ["ci"].

    Exit codes: 0 with the envelope on success; 1 when the findings document,
    diff, or posted listing does not decode, or an input file cannot be read;
    2 when a flag is missing or malformed. *)

val cmd : int Cmdliner.Cmd.t
