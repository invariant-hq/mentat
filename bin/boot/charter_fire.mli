(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The charter fire pipeline — one triggering event driven from decoded
    delivery to durable receipts.

    One code path, two invoking processes: [mentat charter fire] runs the
    pipeline in the invoking process itself, and the resident node runs the
    identical path when a webhook delivery arrives. The pipeline is split at
    its durability point into the two halves a two-fiber intake needs:

    - {!admit_delivery} is the intake half — the node's {e serving fiber}.
      It fences the body's size, decodes it narrowly, and appends the
      delivery receipt: cheap, no network, so an ingress listener can
      answer its 202 immediately after it returns. Duplicate delivery
      lines across redeliveries are harmless log lines — the delivery
      receipt records arrival, it decides nothing.
    - {!dispose} is the decision half — the node's {e pump fiber}. It
      gates the event, probes the run-claim, checks the current head,
      folds the budget fences, commits the run-claim, refuses a layout
      that would put secrets under the run's read roots, mints the derived
      session id, provisions the checkout, spawns the sealed review run,
      reaps it, stamps usage and derived cost into the disposition
      receipt, publishes through the connector, records the egress, and
      alerts once per transition.

    {!fire_event} is their composition, and a sweep drives {!dispose}
    directly on synthesized events — the sweep observes open heads, it
    admits no delivery.

    The run-claim marker is taken at {e spawn commitment} — after the gate,
    the head check, and the fences have all admitted the event, immediately
    before the session mint and the checkout — so a refusal that is not a
    commitment never claims: a draft that goes ready re-enters, and a
    fenced head re-enters when a later pass finds its window freed. The
    fence fold, the claim, and the spawned receipt are serialized under a
    per-charter lock, so concurrent fires cannot each read the pre-spawn
    counts and jointly overshoot a cap. Budget fences admit every delivery
    as webhook-shaped ([`Webhook] to {!Fence.admit}): a replay and a sweep
    process the same deliveries a webhook would, and their rate is set by
    whoever opens pull requests, never by the invoking transport.

    Every decision becomes a receipt line before the pipeline returns — a
    fire that spends money always leaves a disposition, on a stop request
    included: a forced stop kills the child and still writes the reaped
    disposition, with whatever cost the journal holds, before returning.

    GitHub reads are injected as closures ({!Github.t}) inside a per-fire
    {!Repo.t}, so this module takes no HTTP dependency: the caller
    constructs them over whatever client it links, holding the read
    credential. The write credential never enters this process at all —
    publication rides two short-lived children of the [mentat] binary, the
    tokenless renderer ([github review]) and the poster ([github publish]),
    and the write token is read from the charter's [secrets/write-token]
    into the poster child's environment only. An absent write token skips
    publication and says so in the egress receipt; it never fails the run.

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
            hash, or a display-safe failure reason. The pipeline refuses a
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

(** The per-fire connection to the charter's repository. *)
module Repo : sig
  type t = {
    git_url : string;
        (** The remote the checkout fetches from. The caller derives it
            from the charter's validated repository (or an explicit
            override), never from a payload. *)
    github : Github.t;  (** The injected GitHub reads. *)
  }
  (** The type for per-fire connections. Deliberately not part of
      {!type-env}: the closures hold the read credential and the URL
      encodes the watched repository, and the store's law is that an
      owner's edit is in force at the next event — so a resident node must
      rebuild this value per delivery, never hold one per charter. The
      signature is that obligation. *)
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
  stop : unit -> [ `None | `Stop | `Force ];
      (** The stop seam, polled while a run child is being reaped. [`Stop]
          asks the pipeline to stop the run: the child is sent SIGINT once
          (after a short courtesy grace, in case the requester's own signal
          already reached it through a shared process group) and the reap
          continues to a normal disposition. [`Force] kills the child
          immediately; the reaped disposition is still written before the
          pipeline returns. The CLI wires its SIGINT count to this at the
          verb boundary; a node wires its drain. Answers never regress:
          once [`Stop], never [`None]; once [`Force], always [`Force]. *)
  say : string -> unit;
      (** The narration line sink. The CLI prints to standard output; a
          node routes to its log. Lines carry no trailing newline. *)
}
(** The type for pipeline environments: the process-scoped effects the
    pipeline composes over, built once per process by either invoking
    binary. Everything charter- or delivery-scoped rides {!Repo.t} and the
    loaded charter instead. *)

type outcome =
  | Disposed
      (** The event was driven to a disposition — spawned and reaped,
          skipped, dup, fenced, superseded, or refused — and every receipt
          the disposition owes is durable. A run that failed semantically is
          [Disposed]: its failure is receipted and alerted, and the record,
          not this exit, is the outcome surface. *)
  | Interrupted
      (** A stop request reached the pipeline mid-run; the run child was
          reaped and its disposition receipted before returning. *)

val max_event_bytes : int
(** The inclusive delivery-body byte cap, 1 MiB. Every intake — [--event]
    bytes, a live webhook body — is fenced by this one constant, so the two
    paths refuse the same oversized payload. *)

val admit_delivery :
  env ->
  Charter_store.Loaded.t ->
  body:string ->
  (Mentat_charter.Event.Pull_request.t, string) result
(** [admit_delivery env loaded ~body] admits the delivery [body] — the
    bytes of a GitHub [pull_request] webhook payload — as far as the
    durable delivery receipt: the size fence, the narrow decode, and the
    appended delivery line, nothing else. Cheap and network-free, so an
    ingress listener answers its 202 on this half alone. The decoded event
    is returned for {!dispose}; an [Error] is an oversized body, a charter
    with no webhook arm, a payload the narrow decode refuses, or an
    unwritable receipt log. *)

val dispose :
  env ->
  repo:Repo.t ->
  Charter_store.Loaded.t ->
  event:Mentat_charter.Event.Pull_request.t ->
  check_head:bool ->
  (outcome, string) result
(** [dispose env ~repo loaded ~event ~check_head] drives the admitted
    [event] to its disposition — the pump half; see the module preamble for
    the fixed step order. [check_head] is [true] for a delivered event (the
    current-head read refuses a stale delivery before it can claim) and
    [false] for a sweep-synthesized one, whose listing was the head read.
    [Error message] is a machinery failure: the pipeline itself could not
    do its job (an unwritable receipt, an unreachable remote, a failed
    spawn) — receipted as [refused] wherever an identity exists to receipt
    against, and distinct from every run outcome, which is [Disposed]. *)

val fire_event :
  env ->
  repo:Repo.t ->
  Charter_store.Loaded.t ->
  body:string ->
  (outcome, string) result
(** [fire_event env ~repo loaded ~body] is {!admit_delivery} composed with
    {!dispose} — the whole pipeline in one call, the CLI's [--event] path
    and the shape the node's two fibers reassemble. *)

val fire_sweep :
  env -> repo:Repo.t -> Charter_store.Loaded.t -> (outcome, string) result
(** [fire_sweep env ~repo loaded] performs one open-PR listing and drives a
    synthesized delivery through {!dispose} for every head whose run-claim
    is not held under the current policy digest (the listing is the head
    read, so the current-head check is not repeated; no delivery receipt is
    admitted — the sweep observes, it never re-delivers). A head whose
    claim is held is passed over silently, with two exceptions: a claim
    with no spawned line — a committer that died between claim and spawn —
    re-enters {!dispose} whole, whose admission adopts the abandoned
    commitment; and an identity that ran to settlement with findings and
    holds no egress receipt re-enters the {e publisher} only — the upsert
    is idempotent, so finishing an interrupted publication spends nothing
    and mints no run. Heads a gate skipped or a fence refused hold no claim
    and re-enter on every pass, so a draft that goes ready is reviewed and
    a fenced head runs when its window frees. Events are driven in listing
    order; the first machinery failure stops the sweep. *)

val settle_recovered :
  env ->
  Charter_store.Loaded.t ->
  identity:string ->
  digest:string ->
  session:string ->
  (unit, string) result
(** [settle_recovered env loaded ~identity ~digest ~session] writes the one
    reaped line a dead run's record owes — the honest settle a reconcile
    pass performs for a spawned disposition with no reaped line, once it
    has read the run fence for [session] as free: the child is gone and no
    reaper survives it. Nothing is signalled and nothing is spawned. The
    reaped disposition carries cause [recovered] and is stamped with
    [digest] — the policy the run was spawned under, which may not be the
    policy in force — so the spawn/reap pair stays whole under one digest.
    The journal head, not the unobservable exit status, carries the truth:
    a settled head stamps exit 0, making the run's findings publishable to
    the next sweep's publisher re-entry; every other head stamps 255 and
    alerts, [parked] for a parked head and [failed] otherwise — the
    identity's claim is spent, so the alert is the only surface the owner
    has left. Settling is serialized under the charter's fire lock and
    re-checked there, so concurrent passes finding the same orphan settle
    it once; a record already reaped is left untouched. *)

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
    first review-class action ({!Mentat_charter.Event.Identity.review_class})
    the arm admits — the sweep asks whether a head wants review, and the
    admitted action names the moment the charter subscribed to. An arm
    admitting no review-class action synthesizes nothing. *)

val findings_of_log : string -> string option
(** [findings_of_log bytes] is the findings document carried by the run
    log [bytes] — the [output] member of the last [turn.finished] line,
    re-encoded minified — or [None] when no line carries one. Lines that do
    not parse are passed over: the log is a stream tail, and the settled
    line is the one that matters. *)
