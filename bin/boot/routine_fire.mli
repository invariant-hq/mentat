(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The routine fire pipeline — one triggering event driven from decoded
    delivery to durable receipts.

    One code path, two invoking processes: [mentatd routine fire] runs the
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
      folds the budget fences, decodes and pre-flights the recorded
      contract (the output schema and the {!Run_policy_overlay} lowering —
      a contract no activation could serve refuses before anything is
      claimed or spent), commits the run-claim, refuses a layout
      that would put secrets under the run's read roots, mints the derived
      session id, provisions the checkout, creates the run session with
      the routine's recorded contract, mails it the trigger prompt,
      supervises it through the process broker to its conclusion, stamps
      usage and derived cost into the disposition receipt, publishes
      through the connector, records the egress, and alerts once per
      transition. The run is an ordinary served session — attachable and
      mailable while it works, resumable after.

    {!fire_event} is their composition, and a sweep drives {!dispose}
    directly on synthesized events — the sweep observes open heads, it
    admits no delivery.

    The run-claim marker is taken at {e spawn commitment} — after the gate,
    the head check, the fences, and the contract pre-flight have all
    admitted the event, immediately before the session mint and the
    checkout — so a refusal that is not a commitment never claims: a draft
    that goes ready re-enters, a fenced head re-enters when a later pass
    finds its window freed, and a broken contract re-enters once the
    routine is repaired. The
    fence fold, the claim, and the spawned receipt are serialized under a
    per-routine lock, so concurrent fires cannot each read the pre-spawn
    counts and jointly overshoot a cap. Budget fences admit every delivery
    as webhook-shaped ([`Webhook] to {!Fence.admit}): a replay and a sweep
    process the same deliveries a webhook would, and their rate is set by
    whoever opens pull requests, never by the invoking transport.

    Every decision becomes a receipt line before the pipeline returns — a
    fire that spends money always leaves a disposition, on a stop request
    included: a cancelled run's supervision still concludes, and the reaped
    disposition is written, with whatever cost the journal holds, before
    returning.

    GitHub reads and credentials are injected as closures inside a per-fire
    {!Repo.t}, so this module takes no HTTP dependency and never chooses an
    auth mode: the caller constructs the reads over whatever client it
    links, and the two credential closures answer from wherever the
    routine's mode says — a PAT routine's [secrets/] files, or an App
    routine's per-fire installation-token mints. The write credential is
    obtained only at publish time and rides no further than the poster
    child — publication is two short-lived children of the [mentat]
    binary, the tokenless renderer ([github review]) and the poster
    ([github publish]), and the write credential enters the poster child's
    environment only. A write closure answering [None] (a PAT routine with
    no [secrets/write-token]) skips publication and says so in the egress
    receipt; it never fails the run. A write closure answering [Error] (an
    App mint refused) is a machinery failure like a refused post: the
    receipt is owed no egress line, so the sweep's publisher re-entry
    re-mints and retries, spending nothing.

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

(** The per-fire connection to the routine's repository. *)
module Repo : sig
  type t = {
    git_url : string;
        (** The remote the checkout fetches from. The caller derives it
            from the routine's validated repository (or an explicit
            override), never from a payload. *)
    github : Github.t;  (** The injected GitHub reads. *)
    git_token : unit -> (string option, string) result;
        (** The credential the checkout's git fetch rides — per-invocation
            environment-scoped configuration, never argv and never a URL.
            The PAT arm re-reads [secrets/read-token]; the App arm answers
            the fire's read mint. [Ok None] fetches unauthenticated (a
            local fixture remote). *)
    write_token : unit -> (string option, string) result;
        (** The publish-time write credential, called only when a
            publication is owed and handed to the poster child's
            environment alone. The PAT arm reads [secrets/write-token]
            ([Ok None] when absent — publication is skipped and receipted
            so); the App arm mints a fresh write-scoped installation token,
            and a refused mint is [Error] — no egress line lands, so the
            sweep re-enters the publisher. *)
  }
  (** The type for per-fire connections. Deliberately not part of
      {!type-env}: the closures hold or mint the credentials and the URL
      encodes the watched repository, and the store's law is that an
      owner's edit is in force at the next event — so a resident node must
      rebuild this value per delivery, never hold one per routine. The
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
      (** The [mentat] binary the publication children exec — the sibling of
          the invoking executable for both the CLI fire and the node,
          [MENTAT_BIN] overriding. The run itself is not a child of this
          binary's choosing: the broker spawns its activation. *)
  broker : Mentat_broker.t;
      (** The process broker the fire mails and supervises run sessions
          through — the invoking process's one broker: the node passes the
          daemon's, the CLI fire builds its own spawn-capable one. *)
  stop : unit -> [ `None | `Stop | `Force ];
      (** The stop seam, polled while a supervised run is awaited. A stop
          request maps onto the broker's cancel ladder — the wire interrupt
          first, then the bounded signals — and the supervision concludes
          through its ordinary sinks, so the reaped disposition is written
          on every stop path before the pipeline returns. Answers never
          regress: once [`Stop], never [`None]; once [`Force], always
          [`Force]. The pipeline reads the answer as a boolean projection —
          [`Stop] and [`Force] alike request the stop; the three-state
          vocabulary belongs to the invoking process's signal seam, and a
          new arm would change nothing here. *)
  say : string -> unit;
      (** The narration line sink. The CLI prints to standard output; a
          node routes to its log. Lines carry no trailing newline. *)
}
(** The type for pipeline environments: the process-scoped effects the
    pipeline composes over, built once per process by either invoking
    binary. Everything routine- or delivery-scoped rides {!Repo.t} and the
    loaded routine instead. *)

val named_env : env -> name:string -> env
(** [named_env env ~name] is [env] with every narration line prefixed
    [routine <name>: ] — one resident process speaks for many routines, so
    the prefix is the line's provenance. *)

type outcome =
  | Disposed
      (** The event was driven to a disposition — spawned and reaped,
          skipped, dup, fenced, superseded, or refused — and every receipt
          the disposition owes is durable. A run that failed semantically is
          [Disposed]: its failure is receipted and alerted, and the record,
          not this exit, is the outcome surface. *)
  | Interrupted
      (** A stop request reached the pipeline mid-run; the run was
          cancelled and its disposition receipted before returning. *)

val max_event_bytes : int
(** The inclusive delivery-body byte cap, 1 MiB. Every intake — [--event]
    bytes, a live webhook body — is fenced by this one constant, so the two
    paths refuse the same oversized payload. *)

val admit_delivery :
  env ->
  Routine_store.Loaded.t ->
  body:string ->
  (Mentat_routine.Event.Pull_request.t, string) result
(** [admit_delivery env loaded ~body] admits the delivery [body] — the
    bytes of a GitHub [pull_request] webhook payload — as far as the
    durable delivery receipt: the size fence, the narrow decode, and the
    appended delivery line, nothing else. Cheap and network-free, so an
    ingress listener answers its 202 on this half alone. The decoded event
    is returned for {!dispose}; an [Error] is an oversized body, a routine
    with no webhook arm, a payload the narrow decode refuses, or an
    unwritable receipt log. *)

val dispose :
  env ->
  repo:Repo.t ->
  ?on_reap:(unit -> unit) ->
  Routine_store.Loaded.t ->
  event:Mentat_routine.Event.Pull_request.t ->
  check_head:bool ->
  (outcome, string) result
(** [dispose env ~repo loaded ~event ~check_head] drives the admitted
    [event] to its disposition — the pump half; see the module preamble for
    the fixed step order. [check_head] is [true] for a delivered event (the
    current-head read refuses a stale delivery before it can claim) and
    [false] for a sweep-synthesized one, whose listing was the head read.
    [on_reap], when given, is called once, immediately after a run's
    reaped disposition receipt is durable and before publication — the
    signal a resident caller turns into a prompt reconcile re-entry, since
    everything after the reap (the findings read, the publication, the
    egress) can fail while the money is already spent. An event disposed
    without a run never calls it. The reaped append re-checks the record
    under the routine's fire lock — the run's fence frees before its
    supervision concludes, so a concurrent reconcile pass may settle the
    record recovered first; exactly one reaped line lands per digest and
    identity, and the loser narrates, still signals [on_reap], and leaves
    the record's owed publication or alert to the sweep. A settled run
    whose journal carries no findings document closes with a failed alert
    and a none-needed egress line. [Error message] is a machinery failure:
    the pipeline itself could not do its job (an unwritable receipt, an
    unreachable remote, an undeliverable trigger mail) — receipted as
    [refused] wherever an identity exists to receipt against, and distinct
    from every run outcome, which is [Disposed]. *)

val fire_event :
  env ->
  repo:Repo.t ->
  Routine_store.Loaded.t ->
  body:string ->
  (outcome, string) result
(** [fire_event env ~repo loaded ~body] is {!admit_delivery} composed with
    {!dispose} — the whole pipeline in one call, the CLI's [--event] path
    and the shape the node's two fibers reassemble. *)

val fire_sweep :
  env -> repo:Repo.t -> Routine_store.Loaded.t -> (outcome, string) result
(** [fire_sweep env ~repo loaded] performs one open-PR listing and
    interprets {!Mentat_routine.Record.sweep_action} over each head's
    receipts (the listing is the head read, so the current-head check is
    not repeated; no delivery receipt is admitted — the sweep observes, it
    never re-delivers): a head whose run-claim is not held under the
    current policy digest — or whose claim has no spawned line, a
    committer that died between claim and spawn — is driven through
    {!dispose} whole, whose admission adopts an abandoned commitment; an
    identity that ran to a publishable settle and holds no egress receipt
    re-enters the {e publisher} only — the upsert is idempotent, so
    finishing an interrupted publication spends nothing and mints no run —
    and a settled head whose journal carries no findings document closes
    with an alert and a none-needed egress line instead of re-entering
    forever.
    Heads a gate skipped or a fence refused hold no claim and re-enter on
    every pass, so a draft that goes ready is reviewed and a fenced head
    runs when its window frees. Events are driven in listing order; the
    first machinery failure stops the sweep, and a stop request observed
    before a drive stops committing new runs ([Ok Interrupted]) — the beat
    finishes the fold. *)

val alert_identity :
  env ->
  Routine_store.Loaded.t ->
  digest:string ->
  identity:string ->
  transition:Mentat_routine.Receipt.Transition.t ->
  session:string option ->
  (unit, string) result
(** [alert_identity env loaded ~digest ~identity ~transition ~session]
    fires the identity-scoped alert for [transition] — the alert receipt,
    then the routine's notify hook — unless the record already carries one
    for [transition] under [digest] and [identity], in which case nothing
    happens: the dedup rides the receipt log, read, checked, and appended
    under the routine's fire lock (the hook fires outside it), so the call
    is idempotent and two concurrent passes re-deriving the same owed alert
    land one line and one hook firing. [digest] is the
    policy the alerted run was spawned under — which for a recovered run
    may not be the policy in force — so an old policy's failure never
    spends the new policy's one alert. *)

val probe_fence : Mentat_store.t -> session:string -> Mentat_routine.Record.fence
(** [probe_fence store ~session] reads [session]'s run fence, non-blocking,
    in the reconcile tables' vocabulary: free, held, or unprobeable. The
    fence, never a stored pid, is the liveness truth — fences release on
    holder death, so a free fence over a spawned-but-unreaped run means no
    process anywhere is left to write the record's reaped line. *)

val settle_recovered :
  env ->
  Routine_store.Loaded.t ->
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
    policy in force — so the spawn/reap pair stays whole under one digest,
    and its alert dedups under that same digest. The journal head, not the
    unobservable exit status, carries the truth: a settled head stamps
    exit 0, making the run's findings publishable to the next sweep's
    publisher re-entry; every other head stamps 255 and alerts, [parked]
    for a parked head and [failed] otherwise — the identity's claim is
    spent, so the alert is the only surface the owner has left. Settling is
    serialized under the routine's fire lock, where the record and the
    fence are both re-read: a record already reaped is left untouched, and
    a fence that re-reads held or unprobeable — the owner attached the
    orphaned session between the caller's probe and the lock — is narrated
    and left to its holder, never settled over. *)

(** {1:folds Pure pieces}

    The pipeline's decision folds that touch no effect, exposed for direct
    unit testing. *)

val sweep_events :
  Mentat_routine.Routine.Trigger.Webhook.t ->
  repo:string ->
  Github.open_pr list ->
  Mentat_routine.Event.Pull_request.t list
(** [sweep_events arm ~repo prs] synthesizes the deliveries a sweep drives:
    one [pull_request] event per listed head, in listing order, carrying the
    first review-class action ({!Mentat_routine.Event.Identity.review_class})
    the arm admits — the sweep asks whether a head wants review, and the
    admitted action names the moment the routine subscribed to. An arm
    admitting no review-class action synthesizes nothing. *)

val trigger_mail_id :
  source:string -> digest:string -> key:string -> Mentat_session.Queue.Id.t
(** [trigger_mail_id ~source ~digest ~key] is the queue-entry id the trigger
    prompt is mailed under — derived from the trigger identity, so a double
    fire lands the same entry once and the admission's recorded-enqueue
    dedup absorbs the rest. Pure and deterministic; the adoption of a torn
    claim re-mails the same id. *)

val findings_of_session : Mentat_session.t -> string option
(** [findings_of_session session] is the findings document [session]'s
    journal carries — the input of the last structured-output claim in the
    head turn, re-encoded minified — or [None] when the head turn did not
    complete or terminated without one. Completion is required because it is
    what proves the claim was the schema-conforming terminating answer, not
    a rejected attempt an unfinished or failed turn left behind. *)
