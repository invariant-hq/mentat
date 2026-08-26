(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The resident charter node — the daemon-side consumer of the charter
    layer.

    One value, assembled once at daemon boot over the shared composition,
    owns everything the fire pipeline needs to run resident: the pipeline
    environment with the daemon's stop seam and trace log wired in, the
    per-fire repository connection builder holding the read credential, the
    webhook ingress the wire family routes through, and the pump that
    drives admitted deliveries to their dispositions.

    {b The 202 contract.} The intake is split at the pipeline's durability
    point. {!val-ingress}'s [deliver] callback runs on the serving fiber
    and performs only {!Charter_fire.admit_delivery} — the size fence, the
    narrow decode, and the durable delivery receipt — then hands the
    admitted event to the node's queue and answers accepted: the wire's
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

    Charter state is never cached: the ingress resolver re-reads the
    installed charters on every request, [deliver] re-loads the addressed
    charter per delivery, and the repository connection is rebuilt per fire
    with a fresh credential read — an owner's edit is in force at the next
    event. *)

type t
(** The type for resident charter nodes. *)

val create :
  Composition.shared ->
  stop:Stop_signal.t ->
  ?github_base_url:string ->
  ?git_url:string ->
  unit ->
  (t, string) result
(** [create shared ~stop ?github_base_url ?git_url ()] assembles the node
    over the daemon's shared composition. [stop] is the daemon's stop flag,
    threaded onto the pipeline's stop seam: a requested stop reads as a
    stop request in a reaping fire, and the seam's force arm never fires
    here — a second signal exits the process at the handler, and the boot
    reconcile settles whatever that leaves. Pipeline narration goes to the
    trace log, each line prefixed with the charter it concerns.

    [github_base_url] is the API base for every GitHub read and for the
    publication child — validated configuration from the daemon's own
    surface, deliberately never the ambient [MENTAT_GITHUB_BASE_URL]: an
    environment-writable API base would redirect Bearer-token requests, so
    the variable is scrubbed from the child environment and, when a base is
    configured here, rewritten to it — reads and publication then address
    one validated host ({!child_environment}). [git_url] overrides the
    remote every checkout fetches from (the charter's repository on
    github.com otherwise) — the explicit-override seam, never payload data.
    [Error message] when no [mentat] sibling binary resolves, so a node
    that could never spawn a run is refused at boot. *)

val env : t -> name:string -> Charter_fire.env
(** [env t ~name] is the pipeline environment for one fire of charter
    [name]: the node's process-scoped effects, narration prefixed
    [charter <name>: ] — one resident process speaks for many charters, so
    the prefix is the line's provenance. *)

val reconcile_env : t -> Charter_fire.env
(** [reconcile_env t] is the pipeline environment for the reconcile fold's
    drivers: the node's process-scoped effects with narration un-prefixed —
    the fold speaks for many charters in one pass and prefixes each line
    with the charter it concerns itself, exactly as {!val-env} would. *)

val repo : t -> Charter_store.Loaded.t -> (Charter_fire.Repo.t, string) result
(** [repo t loaded] is the per-fire connection to [loaded]'s repository:
    the injected GitHub reads over a client holding the charter's read
    credential, and the fetch remote. Built fresh per fire — the credential
    is re-read from the charter's [secrets/read-token] on every call, so a
    rotated token is in force at the next event; nothing here retains a
    returned value, and no caller may either. [Error message] when the
    charter holds no read credential or the client cannot be
    constructed. *)

val ingress : t -> Mentat_server.Ingress.t
(** [ingress t] is the webhook ingress the wire family routes through. Its
    callbacks keep the serving fiber prompt: [resolve] folds the installed
    charters fresh per request, naming each unloadable charter in the trace
    log — a broken charter answers to no id; [deliver] re-loads the
    addressed charter, admits the delivery, and hands the admitted event to
    the pump's queue, per the module's 202 contract. A delivery whose
    [X-GitHub-Event] header names a foreign kind ([ping], say) is answered
    [202] and noted in the trace log only — the receipt log speaks charter
    facts, and the header, while unverified, is a verified sender's claim
    about its own delivery ({!event_route}). A verified delivery for a
    disabled charter is admitted — arrival is a fact — then receipted
    skipped-disabled without reaching the queue. Deliveries rejected at the
    wire over their signature are counted and noted in the trace log. *)

val pump : t -> unit
(** [pump t] consumes the queue and drives each admitted event to its
    disposition: the repository connection is rebuilt, then the pipeline's
    decision half runs with the current-head check on — one event at a
    time, in admission order, under the policy closure that admitted it,
    so a delivery's receipt, claim, and run carry one digest even when the
    owner edits the charter while the event waits. A machinery failure is
    receipted refused and narrated; it never stops the pump. [pump]
    returns only by cancellation — run it as a racing branch beside the
    serve loop. Cancellation at any instant is safe: every receipt written
    before the cancel is durable, and an event caught between receipt and
    disposition is the boot reconcile's to finish. Once a stop is
    requested, remaining entries are drained without starting new work,
    each noted for a later pass. *)

(** {1:folds Pure pieces}

    The node's decision folds that touch no effect, exposed for direct
    unit testing. *)

val resolution :
  Charter_store.Binding.t list ->
  ingress_id:string ->
  Mentat_server.Ingress.resolution
(** [resolution bindings ~ingress_id] is the resolver's answer: the secret
    and enabled state of the binding whose minted id is [ingress_id], or
    unknown when none matches. *)

val event_route : string option -> [ `Admit | `Foreign of string ]
(** [event_route header] routes a delivery on its [X-GitHub-Event] header:
    [`Admit] for [pull_request] and for an absent header — the narrow
    decode is the arbiter then — and [`Foreign kind] for any other kind. *)

val child_environment :
  (string * string) list ->
  github_base_url:string option ->
  (string * string) list
(** [child_environment base ~github_base_url] is the node's child
    environment: [base] with [MENTAT_GITHUB_BASE_URL] removed — a child
    must not take an API base from the daemon's ambient environment — and,
    when [github_base_url] is configured, bound to it instead, so the
    publication child posts to the host the node reads from. *)
