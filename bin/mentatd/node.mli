(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The resident routine node — the daemon-side consumer of the routine
    layer.

    One value, assembled once at daemon boot over the shared composition,
    owns everything the fire pipeline needs to run resident: the pipeline
    environment with the daemon's stop seam and trace log wired in, the
    per-fire repository connection builder holding the read credential, the
    webhook ingress the wire family routes through, and the pump that
    drives admitted deliveries to their dispositions.

    {b The 202 contract.} The intake is split at the pipeline's durability
    point. {!val-ingress}'s [deliver] callback runs on the serving fiber
    and performs only {!Mentat_boot.Routine_fire.admit_delivery} — the size
    fence, the narrow decode, and the durable delivery receipt — then hands
    the admitted event to the node's queue and answers accepted: the wire's
    [202] means the delivery receipt is on disk, never that a run was
    gated, spawned, or finished. Everything after the receipt — gate, head
    check, fences, claim, checkout, run, publication — happens on {!pump}'s
    fiber, one event at a time.

    {b Backpressure.} The queue never blocks the serving fiber. Admission
    is capped instead: a delivery arriving while the queue holds its bound
    is refused {e before} any receipt is written — a content-free [500], so
    the sender's hook log shows the pressure — because a backlog deeper
    than the cap is worthless anyway: the pump's current-head check refuses
    a delivery whose head has moved on, and a still-open head re-enters on
    every sweep pass. Nothing admitted is ever discarded: once the delivery
    receipt is durable, the event is either disposed by the pump or — after
    a crash or a stop — owned by the boot reconcile and the sweep.

    Routine state is never cached: the ingress resolver re-reads the
    installed routines on every request, [deliver] re-loads the addressed
    routine per delivery, and the repository connection is rebuilt per fire
    with a fresh credential read — an owner's edit is in force at the next
    event. *)

type t
(** The type for resident routine nodes. *)

val create :
  Mentat_boot.Composition.shared ->
  broker:Mentat_broker.t ->
  stop:Mentat_boot.Stop_signal.t ->
  ?github_base_url:string ->
  ?git_base:string ->
  unit ->
  (t, string) result
(** [create shared ~broker ~stop ?github_base_url ?git_base ()] assembles
    the node over the daemon's shared composition. [broker] is the daemon's
    one process broker, through which every fire mails and supervises its
    run session. [stop] is the daemon's stop flag, threaded onto the
    pipeline's stop seam: a requested stop reads as a stop request in a
    supervising fire, and the seam's force arm never fires here — a second
    signal exits the process at the handler, and the boot reconcile settles
    whatever that leaves. Pipeline narration goes to the trace log, each
    line prefixed with the routine it concerns.

    [github_base_url] is the API base for every GitHub read and for the
    publication child — validated configuration from the daemon's own
    surface, deliberately never the ambient [MENTAT_GITHUB_BASE_URL]: an
    environment-writable API base would redirect Bearer-token requests, so
    the variable is scrubbed from the child environment and, when a base is
    configured here, rewritten to it — reads and publication then address
    one validated host ({!child_environment}). [git_base] overrides the git
    host prefix every checkout's remote is derived from
    ([https://github.com] otherwise): the remote is
    [<base>/<owner>/<repo>.git] per routine ({!checkout_url}), so one flag
    serves routines over many repositories — the explicit-override seam,
    never payload data. [Error message] when no [mentat] sibling binary
    resolves, so a node that could never spawn a run is refused at boot. *)

val reconcile_env : t -> Mentat_boot.Routine_fire.env
(** [reconcile_env t] is the pipeline environment for the reconcile fold's
    drivers: the node's process-scoped effects with narration un-prefixed —
    the fold speaks for many routines in one pass and prefixes each line
    with the routine it concerns itself, exactly as {!val-env} would. *)

val repo :
  t ->
  Mentat_boot.Routine_store.Loaded.t ->
  (Mentat_boot.Routine_fire.Repo.t, string) result
(** [repo t loaded] is the per-fire connection to [loaded]'s repository —
    {!Github_auth.repo} over the node's validated API base and derived
    remote: the injected reads and credential closures for whichever auth
    mode the routine's files select (PAT files winning, else the
    owner-level App, else the refusal naming both exits). Built fresh per
    fire — credentials are re-read or re-minted on every call, so a
    rotated token or replaced key is in force at the next event; nothing
    here retains a returned value, and no caller may either. *)

val ingress : t -> Mentat_server.Ingress.t
(** [ingress t] is the webhook ingress the wire family routes through. Its
    callbacks keep the serving fiber prompt: [resolve] folds the installed
    routines fresh per request and is side-effect minimal on that
    unauthenticated input — a broken routine answers to no id, silently;
    the dashboard and the reconcile beat name it — while [deliver] re-loads
    the addressed routine, routes the verified body ({!event_route}),
    admits the delivery, and hands the admitted event to the pump's queue,
    per the module's 202 contract. Beside the per-routine ids the resolver
    scans one more source: the App's own ingress id, answering the App's
    webhook secret with enabled true while the credential home loads. A
    delivery on that id is routed {e after} verification by its payload's
    repository ({!app_route}) to every App-mode webhook routine watching
    it, each receipted before the 202 — N3 per routine, any receipt
    failure the same 500 — and a repository no App routine watches is a
    trace note and a 202, the owner having installed the App more widely
    than they routine. PAT routines are excluded from App routing: they
    have their own id and repo webhook, and routing both would receipt one
    arrival twice. A recognizable ping, or a foreign-kind
    body under a foreign-kind header, is answered [202] and noted in the
    trace log only — the receipt log speaks routine facts; a body the
    narrow decode refuses under a pull-request-claiming or absent header is
    refused. A verified delivery for a disabled routine is admitted —
    arrival is a fact — then receipted skipped-disabled without reaching
    the queue. Deliveries rejected at the wire over their signature are
    counted and noted in the trace log. *)

val pump : t -> after_reap:(Mentat_boot.Routine_store.Loaded.t -> unit) -> unit
(** [pump t ~after_reap] consumes the queue and drives each admitted event
    to its disposition: the repository connection is rebuilt, then the
    pipeline's decision half runs with the current-head check on — one
    event at a time, in admission order, under the policy closure that
    admitted it, so a delivery's receipt, claim, and run carry one digest
    even when the owner edits the routine while the event waits. A
    machinery failure is receipted refused and narrated; it never stops
    the pump. [after_reap loaded] runs on the pump's own fiber after any
    event whose dispose reaped a run child, unless a stop was requested
    meanwhile — the caller wires it to the routine's reconcile re-entry,
    so a publication that failed after the money was spent, or a delivery
    the full intake queue refused while the run held the pump, converges
    now rather than on the periodic beat. Its exceptions are caught and
    narrated like the pipeline's own. [pump] returns only by
    cancellation — run it as a racing branch beside the serve loop.
    Cancellation at any instant is safe: every receipt written before the
    cancel is durable, and an event caught between receipt and disposition
    is the boot reconcile's to finish. Once a stop is requested, remaining
    entries are drained without starting new work, each noted for a later
    pass. *)

(** {1:folds Pure pieces}

    The node's decision folds that touch no effect, exposed for direct
    unit testing. *)

val resolution :
  Mentat_boot.Routine_store.Binding.t list ->
  ingress_id:string ->
  Mentat_server.Ingress.resolution
(** [resolution bindings ~ingress_id] is the resolver's answer: the secret
    and enabled state of the binding whose minted id is [ingress_id], or
    unknown when none matches. *)

val event_route :
  string option ->
  body:string ->
  [ `Admit | `Ping | `Foreign of string | `Malformed of string ]
(** [event_route header ~body] routes a delivery on its verified body; the
    unverified [X-GitHub-Event] header may only confirm. [`Admit] when the
    narrow decode admits [body] as a pull-request event — whatever the
    header claims, since the HMAC covers the body alone and a relabeled
    signed delivery must never turn a 202 into a silent drop. When the
    decode refuses: [`Ping] for a recognizable ping body
    ({!Mentat_routine.Event.ping}); [`Foreign kind] when the header names a
    non-pull-request kind the refusing body is consistent with; and
    [`Malformed reason] — a refusal — when the header claimed
    [pull_request] or was absent. *)

val app_route :
  Mentat_boot.Routine_store.Loaded.t list ->
  app_mode:(Mentat_boot.Routine_store.Loaded.t -> bool) ->
  repo:string ->
  Mentat_boot.Routine_store.Loaded.t list
(** [app_route loadeds ~app_mode ~repo] is the routines a verified App
    delivery for [repo] selects: the webhook-armed routines watching
    [repo] that [app_mode] admits, in roster order. The predicate is
    injected so the fold stays pure; the caller passes the mode selector's
    App half (no PAT files, under a loaded credential home). Routines
    without a webhook arm never match — a delivery is webhook material,
    whatever else the routine admits. *)

val checkout_url : git_base:string option -> repo:string -> string
(** [checkout_url ~git_base ~repo] is the remote a routine watching [repo]
    fetches its checkout from: [<base>/<repo>.git], where the base is
    [git_base] (a trailing ['/'] tolerated) or [https://github.com] when
    none is configured. *)

val child_environment :
  (string * string) list ->
  github_base_url:string option ->
  (string * string) list
(** [child_environment base ~github_base_url] is the node's child
    environment: [base] with [MENTAT_GITHUB_BASE_URL] removed — a child
    must not take an API base from the daemon's ambient environment — and,
    when [github_base_url] is configured, bound to it instead, so the
    publication child posts to the host the node reads from. *)
