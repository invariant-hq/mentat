(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The effectful frontend connection.

    [mentat.client] is the one effectful surface a frontend holds: session pull
    feeds ({!Feed}), command submission ({!submit}), the typed
    request/completion flows (accounts, settings, session lifecycle, manual
    compaction, review), and the read-only snapshots ({!sessions}, {!session},
    {!configuration}, {!model_readiness}, …). It links [mentat.protocol], the
    pure value vocabularies its flows and facts name, and [eio] — and
    {b never an engine, store, or transport}. That exclusion is the boundary
    invariant the library is admitted under: every effect enters through the
    {!Driver.t} injection record, and every result-bearing operation settles
    through {!Mentat_protocol.Error.t}. Returned driver errors cross unchanged.
    If an injected result-bearing operation raises, cancellation is re-raised
    and any other exception becomes an operation-labelled
    {!Mentat_protocol.Error.Unavailable} without exposing exception text.

    The same abstract {!t} is constructed over the injected engine and
    executable responders; frontends cannot tell which responder owns an
    operation. Cleanup-only operations and the infallible live
    {!possibly_mutating} condition are intentionally outside the result
    contract.

    {b Deliberate non-goals.} No client operation force-stops a running turn or
    an in-flight callback. There is no amend-or-write flow and no generic
    config-field setter: a session's metadata changes only through the named
    {!rename}/{!archive}/{!restore}/{!delete} actions and its settings only
    through {!set_model}/{!set_permission_review}, never an arbitrary patch
    carrying a field name and payload. Editing unsent input is a frontend-local
    draft, never a client operation. *)

type t
(** The one handle a frontend holds. Transport-neutral: constructed solely from
    {!Driver.t}; frontends cannot tell which injected responder serves an
    operation. *)

(** {1:feeds Feeds and submission} *)

module Feed = Feed
(** One session's cancellable pull feed. *)

val follow_session :
  sw:Eio.Switch.t ->
  t ->
  Mentat_session.Id.t ->
  from:Feed.from ->
  (Feed.t, Mentat_protocol.Error.t) result
(** [follow_session ~sw t id ~from] attaches a feed to [id], bound to [sw]:
    releasing [sw] closes it. [`Beginning] replays then tails; [`Now] tails from
    the current head; [`After p] resumes strictly after [p]. Observation before
    admission: a caller may follow a session before {!submit} returns. *)

val submit :
  t -> Mentat_protocol.Command.t -> (unit, Mentat_protocol.Error.t) result
(** [submit t command] returns only after durable admission: the command's
    admission fact is committed when [Ok ()] returns; the completing fact
    arrives on the feed, correlated by turn or decision id. A backend that
    cannot prove admission returns an explicit failure — never a queue promise.
    Turn-id idempotency makes retry safe. *)

val answer_unattended :
  t ->
  session:Mentat_session.Id.t ->
  decision:Mentat_session.Decision.Id.t ->
  (unit, Mentat_protocol.Error.t) result
(** [answer_unattended t ~session ~decision] is the unattended-policy denial —
    the only answer that principal may give, engine-enforced and replay-checked.
    Calling it stamps [Unattended_policy]; a {!submit} of an [Answer_decision]
    stamps [Local_user]. Two routes are required because a command carries no
    principal. *)

val faulted : t -> session:Mentat_session.Id.t -> Mentat_diagnostic.t option
(** [faulted t ~session] is [Some diagnostic] iff this process drives [session]
    and its driver has contained a fault — a pollable signal a frontend can
    surface without submitting work only to have it refused. [None] for a
    session this process does not drive, or one running normally. *)

val possibly_mutating : t -> session:Mentat_session.Id.t -> bool
(** [possibly_mutating t ~session] is [true] iff this process drives [session]
    and its recovery settled an open tool claim ambiguously with no covering
    checkpoint since — the attach-time warning. [false] for a session this
    process does not drive: a meaningful answer, not an error, so a plain
    [bool]. A live condition read, not a committed fact. *)

(** {1:reads Read-only snapshots}

    Each read forwards to the field its owning responder fills, the same idiom
    as the write operations: no request GADT, no downcast. A read never writes;
    anything that writes travels a command or a request/completion flow. Reads
    reuse owner values whole; the client mints no mirror. *)

val pending_decision :
  t ->
  Mentat_session.Id.t ->
  (Mentat_session.Decision.Requested.t option, Mentat_protocol.Error.t) result
(** [pending_decision t session] is [session]'s pending decision, if any — the
    same session-owned packed value the feed carries. It exists for attach-time
    snapshots such as headless [reply], not as a second decision lifecycle. *)

val running_processes :
  t ->
  Mentat_session.Id.t ->
  (Mentat_protocol.Process.View.t list, Mentat_protocol.Error.t) result
(** [running_processes t session] is a live snapshot of [session]'s background
    processes — the [shell] tool's [background:true] children still running —
    for the side pane and the between-turns reminder. Derived on demand from the
    driving process's ephemeral registry, never persisted; a session this
    process does not drive answers the empty view. *)

val change_diff :
  t ->
  session:Mentat_session.Id.t ->
  change:Mentat_mutation.Change.Id.t ->
  (Textdiff.Hunk.t list, Mentat_protocol.Error.t) result
(** [change_diff t ~session ~change] is the before/after hunks of one recorded
    change row. A settlement fact's mutation evidence carries each change's id
    and path, so a per-change diff correlates to a filename for free; before and
    after bytes are fetched here, never inlined into every fact. *)

val tail :
  t ->
  ?n:int ->
  Mentat_session.Id.t ->
  (Mentat_protocol.Transcript.Tail.t, Mentat_protocol.Error.t) result
(** [tail t ?n session] is [session]'s bounded first paint: the feed head, the
    pending decision, and the last [n] committed facts oldest-first, with the
    position to page backward from — the O(view) attach a frontend renders
    instead of replaying the whole feed. [n] defaults to
    {!Mentat_protocol.Transcript.Tail.default_n} and is clamped to
    {!Mentat_protocol.Transcript.Tail.max_n}. The head and the last fact's
    position coincide; the head is the SSE resume token a follow then continues
    from. *)

val page :
  t ->
  ?n:int ->
  Mentat_session.Id.t ->
  before:Mentat_protocol.Position.t option ->
  (Mentat_protocol.Transcript.Page.t, Mentat_protocol.Error.t) result
(** [page t ?n session ~before] is one older page of [session]'s transcript for
    scroll-up: the last [n] committed facts strictly before [before], oldest
    first, with its own backward continuation ([None] at the feed's beginning).
    [before] is [Some p] from a prior page's continuation, or [None] to read the
    newest page before the head. A [p] naming no committed fact of [session]'s
    feed is [Error (Invalid_position _)], never a silently truncated page — the
    one membership check {!Mentat_protocol.Projection.after} enforces. [n]
    defaults and clamps as in {!tail}. *)

val undo :
  t ->
  session:Mentat_session.Id.t ->
  op:[ `Undo | `Redo | `Cancel ] ->
  (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result
(** [undo t ~session ~op] runs one reversible undo step over [session] at its
    idle point: [`Undo] steps the durable boundary back one user turn (reverting
    its files and hiding its messages), [`Redo] forward one (clearing the
    boundary past the last undone turn), and [`Cancel] un-reverts and clears it.
    The outcome is the file revert's — a settlement, a clean no-op, or a
    [Refused] carrying a drift refusal or a "nothing to undo/redo" message to
    flash. The armed state and transcript seam are driven by the projected
    [Fact.Undo] the boundary emits, so they survive quit/resume. *)

val revert :
  t ->
  session:Mentat_session.Id.t ->
  scope:Mentat_mutation.Revert.Scope.t ->
  (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result
(** [revert t ~session ~scope] reverts Mentat-authored workspace changes in
    [session]'s mutation history under the session's fence. [scope] selects the
    work — the latest revertable turn, a recorded change id, or a path. The
    outcome is a settlement naming the confirmed counts (a partial apply leaves
    an ambiguous target as a value, never a silent failure), a clean no-op when
    the scope resolved to nothing, or the refusal messages when preparation
    refused before touching a file. *)

val export :
  t -> session:Mentat_session.Id.t -> (string, Mentat_protocol.Error.t) result
(** [export t ~session] is [session]'s complete, integrity-verified NDJSON
    export bundle as one string — the JSON export the offline
    [session export --format json] writes, delivered as a value. It is bounded:
    a session whose bundle would exceed the size guard is
    [Error (Unavailable _)] naming the offline streaming twin, rather than
    buffering without limit. *)

val account_readiness :
  t ->
  (Mentat_provider.Account.Discovery.t list, Mentat_protocol.Error.t) result
(** [account_readiness t] is each declared provider route's discovery, in
    catalog order. A rejected credential remains a structured
    {!Mentat_provider.Account.Discovery.Resolution_failed} value beside healthy
    routes. *)

val model_readiness :
  ?refresh:bool ->
  t ->
  (Mentat_provider.Model_readiness.t, Mentat_protocol.Error.t) result
(** [model_readiness t] is the effective, credential-free model catalog in the
    provider owner's {!Mentat_provider.Model_readiness.t}. Provider routes and
    models retain catalog declaration order; static selection eligibility,
    checked availability, authentication requirements, and exact provider-local
    discovery failures cross without mirrors. [refresh] (default [false])
    re-observes server-owned model listings before projecting, bounded by the
    per-provider observation deadline. *)

val configuration :
  t -> (Mentat_config.Resolved.View.t, Mentat_protocol.Error.t) result
(** [configuration t] is the effective configuration as a values-with-origins
    snapshot: every effective field paired with its value and provenance, plus
    the non-fatal warnings, in the config owner's serializable
    {!Mentat_config.Resolved.View.t}. Secret-bearing fields are redacted at the
    owner, so the result is credential-free by construction.

    It is re-read from disk on each call, so a just-persisted settings write
    shows here immediately; execution, by contrast, adopts a configuration
    change only at the next turn boundary. Reading it back is not proof a
    running turn has acted on it. *)

val sessions :
  t ->
  Mentat_session.Listing.t ->
  ( Mentat_session.Summary.t list * Mentat_diagnostic.t list,
    Mentat_protocol.Error.t )
  result
(** [sessions t listing] is the saved-session summaries matching [listing],
    newest [updated_at] first. The result's first component contains every
    healthy selected summary; its second contains one reportable diagnostic for
    every corrupt entry in the unfiltered store scan. Corrupt entries cannot be
    classified by lifecycle, cwd, or search, so diagnostics are never filtered
    with rows. *)

val session :
  t ->
  Mentat_session.Id.t ->
  (Mentat_session.Session_view.t, Mentat_protocol.Error.t) result
(** [session t id] is [id]'s single-session detail view — the drill-in
    projection a [session show] renders. *)

val review_state :
  t ->
  scope:Mentat_review.Scope.t ->
  (Mentat_review.View.t, Mentat_protocol.Error.t) result
(** [review_state t ~scope] is the workspace review's state as the review
    owner's serializable {!Mentat_review.View.t}: the feature labels, per-file
    change and coverage summary, verdict and freshness, cursor, and derived
    counts, with [scope] recorded as the focused scope and its reviewed state.
    It carries no feature content — before/after texts, hunks, and CR
    occurrences are fetched separately, never inlined into every state read. *)

val review_diff :
  t ->
  path:Lpath.Rel.t ->
  (Mentat_review.File_diff.t option, Mentat_protocol.Error.t) result
(** [review_diff t ~path] is [path]'s reviewable diff body — its change status,
    line-diff hunks (or opaque marker), and before/after texts — as the review
    owner's {!Mentat_review.File_diff.t}, or [None] when the feature does not
    change [path]. The per-file drill-in behind the diff pane, the review twin
    of {!change_diff}; {!review_state} never inlines it. *)

val review_crs :
  t -> (Mentat_review.Cr.View.t list, Mentat_protocol.Error.t) result
(** [review_crs t] is the review's CR occurrences as serializable
    {!Mentat_review.Cr.View.t} values in occurrence order, each carrying a
    stable {!Mentat_review.Cr.Ref.t} in place of its process-local source span.
    The frontend addresses a CR by that ref through the review-compose flow. *)

val workspace_glance :
  t ->
  ( Textdiff.stats option * Mentat_workspace.Health.t,
    Mentat_protocol.Error.t )
  result
(** [workspace_glance t] is the ambient workspace status glance: the git
    worktree change summary against the review base — changed files with summed
    line additions and deletions as {!Textdiff.stats}, or [None] when the
    workspace is not a git worktree or git is unavailable — paired with the
    dune watch status {!Mentat_workspace.Health.t}, which is
    {!Mentat_workspace.Health.Off} [Disabled] when [workspace.tooling] is
    disabled. Both are derived on demand: the responder re-reads git and the
    watch observer's snapshot per call, and a frontend holds the answer as a
    last observation, never persisted derived state. *)

val workspace_dune :
  t -> (Mentat_workspace.Health.t, Mentat_protocol.Error.t) result
(** [workspace_dune t] is the watch status alone — the dune half of
    {!workspace_glance} without the git read, cheap enough for a frontend to
    poll on a short tick while the watch is starting, building, or
    restarting. *)

val workspace_dune_control :
  t ->
  op:[ `Restart | `Stop ] ->
  (Mentat_workspace.Health.t, Mentat_protocol.Error.t) result
(** [workspace_dune_control t ~op] drives the supervised build watch:
    restart forgives a terminal state and cycles a fresh watch, stop ends
    supervision for the session. Answers with the status after the verb. *)

(** {1:commands User commands}

    Both queries are read-only snapshots re-read from disk per call, so a
    just-added command file appears immediately. Neither is a session intent:
    expansion writes nothing durable and the completion list is a snapshot. They
    forward to the responders {!make} requires; a backend that supports no
    commands supplies responders returning a typed error rather than omitting
    them, so a missing feature is a visible decision, never a silent gap. *)

val user_commands :
  t -> (Mentat_protocol.User_command.t list, Mentat_protocol.Error.t) result
(** [user_commands t] is the active user commands for completion, project scope
    before user scope, each scope in name order — the palette's row source. *)

val expand_command :
  t ->
  name:string ->
  arguments:string ->
  (Mentat_llm.Content.t list, Mentat_protocol.Error.t) result
(** [expand_command t ~name ~arguments] is the expansion of [/name arguments] as
    user-turn content, ready to submit as [Command.prompt ~input]. It is
    {!Mentat_protocol.Error.Unknown_command} when no active command has that
    name, and the empty list when the expansion is blank for the given arguments
    (the caller's prompt constructor rejects that as an empty prompt). A pure
    query today; the server-side home for any future expansion-time IO. *)

val attach :
  t ->
  session:Mentat_session.Id.t ->
  Mentat_protocol.Attach.source ->
  (Mentat_llm.Content.t, Mentat_protocol.Attach.Error.t) result
(** [attach t ~session source] turns an image into a model-visible
    {!Mentat_llm.Content.t} media block (source [`Ref]) the frontend holds in
    its draft and later includes in a prompt: it reads (for
    {!Mentat_protocol.Attach.Path}) or accepts (for
    {!Mentat_protocol.Attach.Bytes}) the image, downscales it on oversize,
    validates it against [session]'s configured caps, and stores its bytes as a
    session attachment. The stored blob is orphan until a prompt references it.
    It is an executable-provided injection point (like {!user_commands}), not an
    engine command, and writes fence-free — a headless [-i] attaches before the
    run fence, a TUI attach with no active turn. *)

(** {1:accounts Accounts}

    Login and credential flows over the provider runtime. {!save_api_key} and
    {!logout} return only after their durable credential change settles,
    carrying canonical provider-owned account facts. The interactive {!login}
    reports typed progress and settlement through {!Login}. *)

module Login = Login
(** One interactive login's typed progress and settlement. *)

val login :
  sw:Eio.Switch.t ->
  t ->
  provider:Mentat_llm.Provider.t ->
  method_:Mentat_provider.Auth.Login.Id.t ->
  (Login.t, Mentat_protocol.Error.t) result
(** [login ~sw t ~provider ~method_] starts an interactive login (browser,
    device), bound to [sw]: releasing [sw] cancels it. It yields canonical
    {!Mentat_provider.Auth.Login.Progress.t} values inside [Login.Progress]; the
    frontend opens any browser URL itself. URL opening is an OS spawn,
    frontend-local, never a client call. *)

val save_api_key :
  t ->
  provider:Mentat_llm.Provider.t ->
  key:string ->
  (Mentat_provider.Account.t, Mentat_protocol.Error.t) result
(** [save_api_key t ~provider ~key] is the non-interactive api-key method: a
    direct completion returning the exact credential-free observation of the
    committed secret. The key stays in the frontend buffer. A secret cannot ride
    a pull-only {!Login.step}, so api-key is a direct save.

    Returns [Error Invalid_api_key] without invoking the driver if [key] is
    empty. The error carries and renders no secret. *)

val logout :
  t ->
  ?revoke:bool ->
  Mentat_llm.Provider.t ->
  (Mentat_provider.Account.Logout.t, Mentat_protocol.Error.t) result
(** [logout t ?revoke provider] clears [provider]'s stored credential and
    returns its exact post-settlement discovery. [revoke] defaults to [false];
    [true] also requests remote revocation and reports the structured remote and
    conditional local outcome. *)

(** {1:settings Settings}

    Session-scoped writes; effective at the session's next turn. Model and
    review writes land in that session's respective overlay and reach only its
    next turn — [set_model ~session:a] never retargets another session. *)

val set_model :
  t ->
  session:Mentat_session.Id.t ->
  ?reasoning_effort:Mentat_llm.Request.Options.Reasoning_effort.t ->
  Mentat_provider.Selector.t ->
  (unit, Mentat_protocol.Error.t) result
(** [set_model t ~session ?reasoning_effort selector] sets [session]'s model and
    reasoning effort as one selection, effective at its next turn. The current
    turn keeps its sealed selection. [reasoning_effort] defaults to absent,
    which requests the provider/model default rather than inheriting the global
    configured effort. Success acknowledges only the process-local next-turn
    setting; the exact model and effective reasoning accepted by a turn arrive
    through [Turn_started].

    Returns {!Mentat_protocol.Error.Session_not_found}, [Archived], or [Deleted]
    when [session] is not live. An unknown, unavailable, or effort-incompatible
    selection returns [Unavailable] without changing the preceding selection. *)

val set_permission_review :
  t ->
  session:Mentat_session.Id.t ->
  Mentat_permission.Review_behavior.t ->
  (unit, Mentat_protocol.Error.t) result
(** [set_permission_review t ~session review] changes whether permission reviews
    are enforced for [session], effective at its next turn. It does not change
    the headless {!Mentat_permission.Unattended.t} fallback policy. *)

val set_default_model :
  t ->
  ?reasoning_effort:Mentat_llm.Request.Options.Reasoning_effort.t ->
  Mentat_provider.Selector.t ->
  (unit, Mentat_protocol.Error.t) result
(** [set_default_model t ?reasoning_effort selector] durably sets the
    {b user's default} model and optional reasoning effort — sessionless, unlike
    {!set_model}. It validates [selector] through the catalog, then writes the
    user config file through the same atomic path [mentat config set] uses; a
    concurrent offline write serialises on the rename (last-writer-wins). The
    new default reaches every live session at its next turn, where configuration
    re-stages from disk. An unknown or effort-incompatible selection returns
    [Unavailable] without writing. This is the one named durable settings field;
    the client offers no generic config setter. *)

val set_ui_theme : t -> string -> (unit, Mentat_protocol.Error.t) result
(** [set_ui_theme t theme] durably writes [tui.theme] to the user config file —
    sessionless, through the same atomic path [mentat config set] uses. The name
    is not validated against a catalog: an unknown theme falls back at TUI
    launch. The user layer is outranked by the project layers, so a caller that
    must know whether the write is effective should re-read {!configuration} and
    inspect [tui.theme]'s provenance. Like {!set_default_model}, a named durable
    settings field, not a generic config setter. *)

(** {1:lifecycle Session lifecycle}

    Client-minted ids; non-destructive fork/rewind. *)

val create :
  t ->
  id:Mentat_session.Id.t ->
  ?title:string ->
  unit ->
  (unit, Mentat_protocol.Error.t) result
(** [create t ~id ?title ()] creates a session with client-minted [id] — the
    caller may follow it before this returns. The workspace root the metadata
    records is supplied by the composition root, not passed here: paths stay off
    the client surface. Returns [Error Invalid_title] without invoking the
    driver if [title] is [Some ""]. *)

val rename :
  t ->
  session:Mentat_session.Id.t ->
  title:string ->
  (unit, Mentat_protocol.Error.t) result
(** [rename t ~session ~title] sets [session]'s title. Returns
    [Error Invalid_title] without invoking the driver if [title] is empty. *)

val archive :
  t -> session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result
(** [archive t ~session] archives [session]. Reversible: {!restore} undoes it.
    Archiving a session another process actively drives loses the store CAS and
    returns [Busy] or [Unavailable]; the frontend does not archive a live
    session. *)

val restore :
  t -> session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result
(** [restore t ~session] restores an archived [session], undoing {!archive}. *)

val delete :
  t -> session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result
(** [delete t ~session] deletes [session]. Terminal — unlike {!archive} it has
    no inverse. Like {!archive}, a delete against a session another process
    actively drives loses the store CAS and returns [Busy] or [Unavailable]. *)

val fork :
  t ->
  session:Mentat_session.Id.t ->
  into:Mentat_session.Id.t ->
  unit ->
  (unit, Mentat_protocol.Error.t) result
(** [fork t ~session ~into ()] is non-destructive: a new session [into] with
    [session]'s journal as its copied prefix; [session] and its open feeds are
    untouched. Client-minted [into]; returns [unit] (the caller holds the id).
*)

val rewind :
  t ->
  session:Mentat_session.Id.t ->
  into:Mentat_session.Id.t ->
  anchor:Mentat_session.Anchor.t ->
  (unit, Mentat_protocol.Error.t) result
(** [rewind t ~session ~into ~anchor] is like {!fork} but cut at [anchor] (a
    turn id plus edge). Mints a new session; the source journal is never
    rewritten, so no open feed is invalidated. *)

(** {1:compaction Manual compaction} *)

(** The type for a manual compaction outcome. *)
type compaction_result = Driver.compaction_result =
  | Installed
      (** Returns after the compaction fact is durable and {b also} projects
          [Fact.Compaction] on the feed. *)
  | Skipped  (** No compaction was needed; nothing installed. *)

val compact :
  t ->
  session:Mentat_session.Id.t ->
  turn:Mentat_session.Turn.Id.t ->
  (compaction_result, Mentat_protocol.Error.t) result
(** [compact t ~session ~turn] runs the manual compaction flow under the
    caller's client-minted compaction [turn] id. [Installed] and [Skipped] are
    successful outcomes; operational failure uses the outer structured
    {!Mentat_protocol.Error.t}. Find-or-create on [turn]: replaying the same id
    returns the already-installed or re-derived result without a second
    compaction, and an id already naming a non-compaction turn is
    {!Mentat_protocol.Error.Turn_id_reused}. The caller mints [turn]; the client
    forwards it unchanged. *)

(** {1:review Review}

    A completed flow over the workspace review — not session-scoped, no session
    fact. The {!review_state} read returns the resulting state. *)

val review :
  t -> Mentat_review.Command.t -> (unit, Mentat_protocol.Error.t) result
(** [review t command] applies one review-state transition (a scope mark, a
    whole-feature verdict, or a cursor move) to the workspace review and returns
    only after the resulting state is durably recorded. A review-store or
    workspace failure is reported as {!Mentat_protocol.Error.Unavailable}. *)

val review_compose :
  t -> Mentat_review.Cr.Edit.t -> (unit, Mentat_protocol.Error.t) result
(** [review_compose t edit] applies a wire-safe {!Mentat_review.Cr.Edit.t} — a
    CR add, replace, or remove — to the worktree source and returns only after
    the refreshed review is durably recorded. The responder re-resolves each
    occurrence ref against a freshly loaded snapshot; a moved source, a file
    with no comment syntax, or a store/workspace failure is reported as
    {!Mentat_protocol.Error.Unavailable}. *)

(** {1:construction Construction} *)

(** The construction seam; not a frontend API. *)

module Driver = Driver
(** The multi-source injection seam. *)

val make :
  user_commands:
    (unit ->
    (Mentat_protocol.User_command.t list, Mentat_protocol.Error.t) result) ->
  expand_command:
    (name:string ->
    arguments:string ->
    (Mentat_llm.Content.t list, Mentat_protocol.Error.t) result) ->
  attach:
    (session:Mentat_session.Id.t ->
    Mentat_protocol.Attach.source ->
    (Mentat_llm.Content.t, Mentat_protocol.Attach.Error.t) result) ->
  Driver.t ->
  t
(** [make ~user_commands ~expand_command driver] is the client backed by
    [driver]. Its operations forward to [driver]'s responders: each read
    ({!sessions}, {!session}, {!configuration}, …) forwards to its owning
    sub-record's field, {!follow_session} wraps the returned session feed under
    its [~sw], and {!login} boxes {!Driver.Accounts}'s raw login steps into the
    abstract {!Login.t}.

    [user_commands] and [expand_command] back the two user-command queries. They
    are required injection points rather than {!Driver.t} fields so a backend
    that constructs a {!Driver.t} without a client-side command cone (the
    daemon, until it wires discovery) links unchanged, yet every composition
    must consciously supply them: a backend that supports no commands passes
    responders returning a typed error, a visible decision the type forces
    rather than an omission that silently drops the feature. *)
