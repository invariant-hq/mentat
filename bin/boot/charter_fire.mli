(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The charter fire pipeline — one triggering event driven from decoded
    delivery to durable receipts.

    One code path, two invoking processes: [mentat charter fire] runs the
    pipeline in the invoking process itself, and the resident node runs the
    identical path when a webhook delivery arrives. The steps are fixed:
    decode or synthesize the event, gate it (including the current-head
    check), claim its identity, record the delivery, fold the budget fences
    over receipts, refuse a layout that would put secrets under the run's
    read roots, mint the derived session id, provision the checkout, spawn
    the sealed review run, reap it, stamp usage and derived cost into the
    disposition receipt, publish through the connector, record the egress,
    and alert once per transition. Every decision becomes a receipt line
    before the pipeline returns — a fire that spends money always leaves a
    disposition, on interrupt included.

    GitHub reads are injected as closures ({!Github.t}), so this module
    takes no HTTP dependency: the caller constructs them over whatever
    client it links, holding the read credential. The write credential never
    enters this process at all — publication rides two short-lived children
    of the [mentat] binary, the tokenless renderer ([github review]) and the
    poster ([github publish]), and the write token is read from the
    charter's [secrets/write-token] into the poster child's environment
    only. An absent write token skips publication and says so in the egress
    receipt; it never fails the run.

    Checkout provisioning invokes [git] directly, hardened on every
    invocation: no system or global configuration, no terminal prompt, an
    empty hooks path, [protocol.ext.allow=never], and — for an [http(s)]
    remote — [protocol.file.allow=never], with the read token supplied
    per-invocation through environment-scoped configuration, never argv and
    never a remote URL. A non-HTTP remote (the owner explicitly naming a
    local repository, which is also the test seam) leaves the file protocol
    at git's own submodule-refusing default, since the URL comes from the
    caller, never from a payload. The fetch brings the base branch and
    [refs/pull/N/head] with full history — the merge base the reviewed diff
    anchors on cannot be resolved from a shallow pair — and the payload's
    head commit itself is checked out, so the tree reviewed, the receipts,
    and the anchors all name one commit; a head the fetched ref no longer
    contains is receipted [superseded]. *)

(** Injected GitHub reads. *)
module Github : sig
  type open_pr = {
    number : int;  (** The pull request number, at least 1. *)
    head_sha : string;  (** The current head commit hash. *)
    base_ref : string;  (** The base branch name. *)
    draft : bool;  (** Whether the pull request is a draft. *)
    author_association : string;
        (** The author's association, GitHub's uppercase token. *)
  }
  (** One open pull request, as the sweep listing reports it. *)

  type t = {
    current_head : number:int -> (string, string) result;
        (** [current_head ~number] is the pull request's current head commit
            hash, or a display-safe failure reason. The gate refuses a
            delivery whose head this answer has moved past. *)
    open_prs : unit -> (open_pr list, string) result;
        (** [open_prs ()] lists the watched repository's open pull requests,
            for the sweep. *)
    posted : number:int -> (string, string) result;
        (** [posted ~number] is the JSON array of comments the publishing
            identity already posted on the pull request — each an object
            with [id] and [body] members, pre-filtered by the caller to its
            own posting identity — the renderer's upsert input. *)
  }
  (** The type for injected GitHub reads. All three run with the read
      credential (or none); none of them writes. *)
end

type env = {
  dirs : User_dirs.t;  (** The resolved user directories. *)
  store : Mentat_store.t;  (** The opened session store, for journal reads. *)
  catalog : Mentat_provider.Catalog.t;
      (** The provider catalog, pricing the reaped run's usage. *)
  stdenv : Eio_unix.Stdenv.base;  (** Ambient capabilities. *)
  environment : (string * string) list;
      (** The child environment base. Children never receive [GITHUB_TOKEN]
          or [GH_TOKEN] from it, and git invocations additionally shed every
          [GIT_*] variable. *)
  mentat_bin : string;
      (** The [mentat] binary the run and publication children exec — the
          invoking executable itself for the CLI, the sibling binary for the
          node. *)
  git_url : string;
      (** The remote the checkout fetches from. The caller derives it from
          the charter's validated repository (or an explicit override), never
          from a payload. *)
  github : Github.t;  (** The injected GitHub reads. *)
}
(** The type for pipeline environments: everything effectful the pipeline
    composes over, so the two invoking binaries differ only in how they
    build this record. *)

type outcome =
  | Disposed
      (** The event was driven to a disposition — spawned and reaped,
          skipped, dup, fenced, superseded, or refused — and every receipt
          the disposition owes is durable. A run that failed semantically is
          [Disposed]: its failure is receipted and alerted, and the record,
          not this exit, is the outcome surface. *)
  | Interrupted
      (** The owner interrupted the fire; the run child was reaped and its
          disposition receipted before returning. *)

val fire_event :
  env -> Charter_store.Loaded.t -> body:string -> (outcome, string) result
(** [fire_event env loaded ~body] drives the delivery [body] — the bytes of
    a GitHub [pull_request] webhook payload, fenced exactly as the ingress
    fences them (the same size cap, the same narrow decode) — through the
    pipeline under [loaded]. [Error message] is a machinery failure: the
    pipeline itself could not do its job (an unwritable receipt, an
    unreachable remote, a failed spawn) — receipted as [refused] wherever an
    identity exists to receipt against, and distinct from every run outcome,
    which is [Disposed]. *)

val fire_sweep : env -> Charter_store.Loaded.t -> (outcome, string) result
(** [fire_sweep env loaded] performs one open-PR listing and drives a
    synthesized delivery for every head that holds no receipt under the
    current policy digest, each through the same path as {!fire_event} (the
    listing is the head read, so the current-head check is not repeated).
    Heads already receipted are passed over silently — the sweep observes,
    it never re-decides. Events are driven in listing order; the first
    machinery failure stops the sweep. *)

(** {1:folds Pure pieces}

    The pipeline's decision folds that touch no effect, exposed for direct
    unit testing. *)

val sweep_events :
  Mentat_charter.Charter.Trigger.Webhook.t ->
  repo:string ->
  Github.open_pr list ->
  Mentat_charter.Event.Pull_request.t list
(** [sweep_events arm ~repo prs] synthesizes the deliveries a sweep drives:
    one [pull_request] event per listed head, in listing order, carrying the
    first review-class action ([opened], [reopened], [ready_for_review], or
    [synchronize]) the arm admits — the sweep asks whether a head wants
    review, and the admitted action names the moment the charter subscribed
    to. An arm admitting no review-class action synthesizes nothing. *)

val findings_of_log : string -> string option
(** [findings_of_log bytes] is the findings document carried by the run
    log [bytes] — the [output] member of the last [turn.finished] line,
    re-encoded minified — or [None] when no line carries one. Lines that do
    not parse are passed over: the log is a stream tail, and the settled
    line is the one that matters. *)

val summary_method_of_envelope : string -> [ `Post | `Patch ] option
(** [summary_method_of_envelope bytes] is the publication envelope's summary
    request method — [`Post] creates the summary comment, [`Patch] converges
    an existing one — or [None] when [bytes] is not an envelope. *)

val publish_threads_posted : string -> int
(** [publish_threads_posted bytes] counts the thread requests the poster's
    outcome log [bytes] reports answered [2xx] — the labeled lines; the
    summary line carries a null label and is not a thread. *)

val publish_summary_ok : string -> bool
(** [publish_summary_ok bytes] is [true] iff the poster's outcome log
    [bytes] reports the summary request — the null-labeled line — answered
    [2xx]. *)
