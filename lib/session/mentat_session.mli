(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable sessions and pure replay state — the journal.

    [mentat.session] owns the sole durable truth of a conversation. A session is
    an ordered sequence of seventeen inert {!Event.t} facts, and everything a
    reader needs is a pure fold of that sequence: {!State.t} reconstructs the
    transcript, the single open suspension, the decisions, and the product
    boards deterministically, with no clock, randomness, or IO — byte-identical
    events replay to equal states. The library also defines the sealed turn
    {!Contract.t} and the domain vocabularies whose facts live in the journal —
    decisions, plans, tasks, delegations, the next-turn queue, and compaction.

    {b What the journal deliberately does not own.} Execution belongs to the
    engine ([mentat.session.run]): this library records that a provider call or
    a tool call was claimed and how it settled, but launches nothing and holds
    no fiber. Rendering belongs to the protocol: {!Event.t} is projected into
    client facts elsewhere. Persistence belongs to the store: a session is inert
    data with no cursor, file handle, or lock. Enabling all three, events are
    {e identity-free and timestamp-free} — an event carries no session id and no
    wall-clock time; timestamps live only in {!Metadata}. The consequence is
    that events are transfer-survivable across fork, rewind, and export, and
    elapsed time, where a surface wants it, derives at a higher layer from
    {!Metadata}.

    {b The readable-without-engine firewall.} One flat, private,
    pattern-matchable {!Event.t} sum carries the whole product vocabulary, so
    [eval], [trace], and the protocol projector match it directly and never link
    the planner.

    Construct sessions with {!create} or {!make} and inspect the reconstructed
    projection with {!state}. Metadata and lifecycle changes are session
    updates, not semantic events: they do not modify {!state}, {!events}, or the
    transcript. Low-level import and replay code appends raw facts through
    {!append} and {!append_all}; ordinary active-turn mutations are the
    [mentat.session.run] library's job. *)

module Id = Id
(** Session identifiers. *)

module Time = Time
(** Durable session timestamps. *)

module Metadata = Metadata
(** Durable session metadata. *)

module Principal = Principal
(** Decision-resolving authorities. *)

module Contract = Contract
(** The sealed turn execution contract. *)

module Turn = Turn
(** Accepted model/tool loop facts. *)

module Provider_request = Provider_request
(** Durable provider-request claims. *)

module Tool_claim = Tool_claim
(** Durable executable tool claims. *)

module Question = Question
(** Reviewer questions. *)

module Plan = Plan
(** Plan proposals and answers. *)

module Decision = Decision
(** The one decision lifecycle. *)

module Task = Task
(** The durable task board. *)

module Delegation = Delegation
(** Subagent delegation edges. *)

module Origin = Origin
(** Message provenance — who sent a queued input. *)

module Queue = Queue
(** The next-turn queue. *)

module Compaction = Compaction
(** Durable model-replay compactions. *)

module Notice = Notice
(** Durable workspace observations. *)

module Undo = Undo
(** Durable undo-boundary updates. *)

module Event = Event
(** Durable session events. *)

module State = State
(** Pure reconstructed session state. *)

module Anchor = Anchor
(** Stable, replay-valid rewind positions. *)

(** {1:errors Errors} *)

module Error : sig
  (** Session operation errors. *)

  type t =
    | State of State.Error.t
        (** One known semantic event failed while appending to the session. *)
    | Replay of State.Replay_error.t
        (** Batch replay failed at a located event. *)
    | Archived  (** The operation requires a non-archived session. *)
    | Deleted  (** The operation requires a non-deleted session. *)
    | Active_turn of Turn.Id.t
        (** The operation requires no active unfinished turn. *)
    | Unknown_turn of Turn.Id.t
        (** An anchor named a turn that is not present in the session. *)
    | Turn_not_finished of Turn.Id.t
        (** An {!Anchor.After} anchor named a turn with no terminal outcome. *)
    | Delegated_session of Delegation.Id.t
        (** Fork and rewind require a root session. The named delegation owns
            this session's authority, so branching it without a new parent edge
            would silently upgrade that authority. *)
    | Branch_copy_out_of_range of { copied_events : int; event_count : int }
        (** Fork metadata claims a copied prefix longer than the document's
            complete event log. *)
    | Branch_reset_mismatch of {
        index : int;
        expected : Event.t;
        found : Event.t option;
      }
        (** The generated reset suffix first differs at zero-based event
            [index]. [expected] is the required reset event and [found] is the
            event there, or [None] when the document ended first. *)
    | Unexpected_delegation_detachment of { index : int }
        (** A delegation detachment appears outside the one canonical current
            branch reset suffix, at zero-based event [index]. *)
    | Unsupported_version of { found : int; supported : int }
        (** A decoded document declared a version other than the one this build
            supports; the version gate rejects it before any member is decoded.
        *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. *)
end

(** {1:sessions Sessions} *)

type t
(** The type for a durable saved session: its id, metadata, semantic event log,
    and a validated {!State.t} projection of that log. *)

val create :
  id:Id.t ->
  ?title:string ->
  ?delegated_from:Metadata.Delegated_from.t ->
  cwd:Lpath.Abs.t ->
  created_at:Time.t ->
  unit ->
  t
(** [create ~id ?title ?delegated_from ~cwd ~created_at ()] is a new active
    session with no semantic events. [delegated_from] records the parent edge an
    independently attached subagent must verify before execution.

    Raises [Invalid_argument] if [title] is empty. *)

val make :
  id:Id.t -> metadata:Metadata.t -> events:Event.t list -> (t, Error.t) result
(** [make ~id ~metadata ~events] is a session reconstructed from saved parts, or
    [Error (Replay e)] if [events] is not a valid replay. Fork metadata must
    name an in-range copied prefix, and the events immediately after that prefix
    must contain the entire reset suffix generated from its queue and live
    delegation projections. Any missing or different reset event, root
    detachment, or later detachment returns its structured branch error. *)

val id : t -> Id.t
(** [id t] is [t]'s session id. *)

val metadata : t -> Metadata.t
(** [metadata t] is [t]'s durable metadata. *)

val events : t -> Event.t list
(** [events t] is [t]'s semantic event log in application order. *)

val state : t -> State.t
(** [state t] is [t]'s validated replay projection. *)

val accepts_mail : origin:Origin.t option -> t -> bool
(** [accepts_mail ~origin t] is [true] iff [t] accepts a queue entry
    attributed to [origin] — the one accept judgment every queue admission
    runs, whether a live driver admits the entry or a sender appends it to
    [t]'s dormant journal under the run fence, so the two admissions cannot
    drift. Admitted: the owner (an absent origin, {!Origin}), [t]'s recorded
    delegation parent, and [t]'s own recorded delegation children; a
    {!Origin.Trigger} origin is refused. Acceptance gates admission only —
    an admitted origin remains attribution, never authority. *)

val media_refs : t -> Mentat_digest.Content_ref.t list
(** [media_refs t] is the content references of every model-visible media block
    [t]'s document carries — across the prompt's [Turn_started], queued inputs,
    injected messages, and returned tool outputs — deduplicated, in document
    order. Fork and rewind copy these attachment blobs into the child so a
    branch is self-contained, and export includes them in the bundle; both walk
    exactly this projection. *)

module Metrics : sig
  (** Machine-readable session spend and activity metrics. *)

  type t = private {
    usage : Mentat_llm.Usage.t;
        (** Lane-wise sum of provider-reported usage: appended responses,
            retained interrupted prose, and installed compaction summaries. *)
    responses : int;  (** Number of provider responses. *)
    turns : int;  (** Number of terminal turn events. *)
    tool_calls : int;  (** Number of returned executable tool calls. *)
    tool_failures : int;
        (** Number of returned executable tool calls that failed. *)
    tool_rejections : int;
        (** Number of tool calls answered with an error result without a claim.
        *)
    tool_calls_by_name : (string * int) list;
        (** Returned tool-call counts by name, sorted by name. *)
    permission_denials : int;  (** Number of denied permission decisions. *)
  }
  (** The type for cumulative session metrics. Counts are non-negative. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same metrics. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats metrics for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps metrics to JSON objects, rejecting negative counters,
      failures exceeding calls, and duplicate, empty, or unsorted tool names. *)
end

val metrics : t -> Metrics.t
(** [metrics session] is the cumulative metrics projection of [session]'s
    validated event log.

    Raises [Invalid_argument] if an integer lane overflows. *)

(** {1:projections Listing and detail projections} *)

module Summary : sig
  (** A presentation-neutral row for listing saved sessions.

      A summary is the cheap projection a session list, recents strip, or picker
      renders. {!of_session} reads the session's already-validated {!State.t};
      it never replays the journal a second time, so a summary carries only what
      a list surface shows and nothing that would need a transcript scan. Values
      are immutable snapshots and do not track later store updates. *)

  type source = t
  (** The session a summary projects — an alias for {!Mentat_session.t}. *)

  module Phase : sig
    (** A session's coarse run phase, as a list surface shows it. *)
    type t =
      | Idle  (** No active unfinished turn. *)
      | Working  (** An active turn is running with no open suspension. *)
      | Waiting
          (** An active turn is blocked on a provider, tool, or decision. *)

    val to_string : t -> string
    (** [to_string t] is [idle], [working], or [waiting]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same phase. *)

    val pp : Format.formatter -> t -> unit
    (** [pp] formats a phase for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps a phase to its stable tag, rejecting unknown tags. *)
  end

  type t
  (** The type for one saved-session summary. Immutable; every field is sourced
      without a second replay. *)

  val of_session : source -> t
  (** [of_session session] is the list projection of [session]. [O(events)]:
      only [turns] and [preview] traverse the already-built {!State.t}; the rest
      is [O(1)]. It performs no replay of its own — the scan that produced
      [session] already validated it. *)

  val id : t -> Id.t
  (** [id t] is [t]'s session id. *)

  val title : t -> string option
  (** [title t] is [t]'s user-facing title, if one is set. *)

  val preview : t -> string option
  (** [preview t] is the first user turn's prompt text, normalized for one-line
      display, if the session has one. The identifying label, not the latest
      activity (that is {!Session_view.last_text}). *)

  val lifecycle : t -> Metadata.Status.t
  (** [lifecycle t] is [t]'s saved lifecycle status. *)

  val phase : t -> Phase.t
  (** [phase t] is [t]'s coarse run phase, derived from the active turn and its
      suspension. *)

  val root : t -> Mentat_workspace.Root.t
  (** [root t] is the workspace [t] was created under, projected from its
      metadata. Listing scope compares {!Mentat_workspace.Root.key}, never the
      directory. *)

  val cwd : t -> Lpath.Abs.t
  (** [cwd t] is the absolute directory [t] was created under, i.e.
      {!Mentat_workspace.Root.dir} [(root t)] — a display and search projection,
      not a workspace identity. *)

  val turns : t -> int
  (** [turns t] is the accepted-turn count, including an active unfinished turn
      — the conversational round-count a list renders. *)

  val forked_from : t -> Metadata.Forked_from.t option
  (** [forked_from t] is [t]'s fork lineage, if it was forked. *)

  val delegated_from : t -> Metadata.Delegated_from.t option
  (** [delegated_from t] is [t]'s delegation lineage, if it is a delegated
      child. *)

  val created_at : t -> Time.t
  (** [created_at t] is [t]'s saved creation time. *)

  val updated_at : t -> Time.t
  (** [updated_at t] is [t]'s saved last-update time. The recency key; a
      consumer computes age from it against its own clock. *)

  val display_title : t -> string
  (** [display_title t] is [title t], or [t]'s id text when untitled. *)

  val matches : query:string -> t -> bool
  (** [matches ~query t] is [true] iff [query] occurs (case-insensitively, ASCII
      folding) as a substring of [t]'s id, title, preview, or cwd. Metadata and
      preview only — never a transcript scan, so search adds no cost over a
      plain list. *)

  val compare_recency : t -> t -> int
  (** [compare_recency a b] orders newest [updated_at] first, with the id as a
      total tie-break. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] carry the same summary data. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a summary for diagnostics. Not stable syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps a summary to a JSON object, rejecting unknown members. A
      decoded summary round-trips the projected fields; it does not re-derive
      the [of_session] invariants. *)
end

module Session_view : sig
  (** A single-session detail projection for [session show] and TUI drill-in.

      Everything in {!Summary} plus execution detail a one-session view can
      afford: its cost is one session's replay and metric fold, never amortized
      across a list. *)

  type source = t
  (** The session a view projects — an alias for {!Mentat_session.t}. *)

  module Waiting : sig
    (** The kind of open suspension a waiting session sits on — a light display
        token, not the suspension payload (that is the [pending_decision]
        query). *)
    type t = Awaiting_provider | Awaiting_tool | Awaiting_decision

    val to_string : t -> string
    (** [to_string t] is [awaiting_provider], [awaiting_tool], or
        [awaiting_decision]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same waiting kind. *)

    val pp : Format.formatter -> t -> unit
    (** [pp] formats a waiting kind for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps a waiting kind to its stable tag, rejecting unknown tags.
    *)
  end

  type t
  (** The type for one session's detail projection. *)

  val of_session : source -> t
  (** [of_session session] is the detail projection. [O(events)] over the
      already-built state and metric fold; one session, so unbounded detail is
      affordable. *)

  val summary : t -> Summary.t
  (** [summary t] is the shared list projection carried inside the view. *)

  val active_model : t -> Mentat_llm.Model.t option
  (** [active_model t] is the active turn's model, or the most recently started
      turn's when none is active. *)

  val last_outcome : t -> Turn.Outcome.t option
  (** [last_outcome t] is the most recently finished turn's terminal outcome. *)

  val waiting : t -> Waiting.t option
  (** [waiting t] is the kind of open suspension the session sits on, if any. *)

  val workflow_mode : t -> Contract.Mode.t option
  (** [workflow_mode t] is the active or most recent turn's product mode. *)

  val last_text : t -> string option
  (** [last_text t] is the session-wide latest model prose ({!State.final_text})
      — the drill-in's "last activity", distinct from {!Summary.preview}. *)

  val metrics : t -> Metrics.t
  (** [metrics t] is the raw session spend and activity. A context-window fill
      percentage needs the model's provider-owned context limit and is computed
      by the frontend, never here — the session library takes no provider
      dependency. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] carry the same view data. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a view for diagnostics. Not stable syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps a view to a JSON object composing owner codecs, rejecting
      unknown members. *)
end

module Listing : sig
  (** A saved-session listing request and its one pure interpretation.

      A listing is the filter and ordering intent a session index carries
      frontend → responder. The user drives its fields
      ([--all -n 10 --archived]), so it is plain data reusing owner values,
      never a mirror. {!select} interprets it over already-projected
      {!Summary.t} values. *)

  type t = {
    scope : [ `Cwd | `All ];
        (** [`Cwd] keeps only the summaries whose workspace root shares the
            responder's host root key; [`All] spans every workspace. The
            frontend supplies the intent, never a foreign path — the responder
            resolves the host root. *)
    lifecycles : Metadata.Status.t list;
        (** The lifecycle statuses to keep, an additive set (default [[Active]],
            [--archived]/[--deleted] add their status). Empty keeps nothing. *)
    search : string option;
        (** Optional case-insensitive substring over id, title, preview, and
            cwd. [Some ""] matches every summary. *)
    limit : int option;
        (** Maximum rows, newest first; [None] is unlimited. A negative limit
            selects no rows. *)
  }
  (** The type for a listing request. *)

  val select : cwd:Lpath.Abs.t -> t -> Summary.t list -> Summary.t list
  (** [select ~cwd listing summaries] is the one pure interpretation of a
      listing: requested lifecycles, then workspace-root scope, optional text
      search, descending recency, then limit. A [`Cwd] scope keeps a summary
      when {!Mentat_workspace.Root.of_dir} [cwd] shares its {!Summary.root}'s
      key, so membership tracks workspace identity rather than path text. A
      delegated child is excluded — a subagent transcript is addressable only
      through its parent's threads surface, never a session listing. It authors
      no defaults and performs no validation, so search always happens before
      the row cap. *)
end

val set_title : string option -> t -> t
(** [set_title title t] is [t] with title [title]. Does not change [updated_at].

    Raises [Invalid_argument] if [title] is [Some ""]. *)

val touch : Time.t -> t -> t
(** [touch time t] is [t] with its saved update time set to [time].

    Raises [Invalid_argument] if [time] is before the creation time. *)

val archive : t -> (t, Error.t) result
(** [archive t] is [t] marked archived. Idempotent on an archived session;
    {!Error.Active_turn} if [t] has an active turn and {!Error.Deleted} if it is
    deleted. Delegated children may be archived; {!Error.Delegated_session}
    restricts fork and rewind authority only. *)

val restore : t -> (t, Error.t) result
(** [restore t] is [t] marked active. Idempotent on an active session;
    {!Error.Deleted} if deleted. *)

val delete : t -> (t, Error.t) result
(** [delete t] is [t] marked deleted. Idempotent on a deleted session;
    {!Error.Active_turn} if [t] has an active turn. *)

val fork :
  id:Id.t ->
  ?title:string ->
  cwd:Lpath.Abs.t ->
  created_at:Time.t ->
  t ->
  (t, Error.t) result
(** [fork ~id ?title ~cwd ~created_at t] is a new active session with [t]'s
    events as a copied prefix plus a branch reset suffix: a
    {!Queue.Update.Cleared} when the prefix's queue is non-empty, and
    {!Event.Delegations_detached} when the prefix owns delegated children. The
    branch retains historical child calls and results but starts with no live
    child ownership. Its lineage points to [t] with [copied_events] set to the
    prefix length.

    {!Error.Active_turn} if [t] has an active turn, {!Error.Deleted} if it is
    deleted, or {!Error.Delegated_session} if it is a delegated child. Raises
    [Invalid_argument] if [title] is empty. *)

(** {1:rewind Rewind} *)

val resolve_anchor : Anchor.t -> t -> (int, Error.t) result
(** [resolve_anchor anchor t] is the copied-event prefix length [anchor] names
    in [t]. {!Anchor.Before} cuts at the [Turn_started] index; {!Anchor.After}
    just past the [Turn_finished] index. {!Error.Unknown_turn} for an absent
    turn, {!Error.Turn_not_finished} for an {!Anchor.After} on an unfinished
    turn.

    The rewind preview seam, with {!dropped_turns}: a frontend resolves and
    shows what a non-destructive rewind drops before submitting it. *)

val dropped_turns : Anchor.t -> t -> (Turn.Id.t list, Error.t) result
(** [dropped_turns anchor t] is the turns [anchor] drops, in start order — a
    suffix of {!State.turns}. Fails as {!resolve_anchor}. *)

val rewind :
  id:Id.t ->
  ?title:string ->
  cwd:Lpath.Abs.t ->
  created_at:Time.t ->
  Anchor.t ->
  t ->
  (t, Error.t) result
(** [rewind ~id ?title ~cwd ~created_at anchor t] is a new active session whose
    copied prefix is [t]'s events up to [anchor], plus the same branch reset
    suffix as {!fork}. When [anchor] names the last boundary this is exactly
    {!fork}. It returns {!Error.Active_turn}, {!Error.Deleted}, or
    {!Error.Delegated_session} under the same conditions as {!fork}, and
    {!Error.Unknown_turn} or {!Error.Turn_not_finished} when [anchor] cannot
    name a completed prefix. Raises [Invalid_argument] if [title] is empty. *)

val jsont : t Jsont.t
(** [jsont] maps a session to JSON at the {e minimal covering version}: a
    document is encoded at the lowest schema version whose reader can interpret
    all of its content, so a document that uses no sealed feature still decodes
    in an older reader, while one that does raises the version enough that an
    older reader refuses at the version gate rather than misreading it. Decoding
    parses the raw document, rejects any version outside the supported
    [[base_version, max_version]] range up front ({!Error.Unsupported_version})
    — before any other member is decoded — then validates semantic replay,
    metadata, and nested payloads and rejects unknown members. A version outside
    the range fails loudly rather than being partially interpreted.

    Duplicate object members are not detected: the underlying [jsont] takes the
    last occurrence and silently drops earlier ones. Callers that must reject
    malformed duplicate-keyed documents have to pre-validate the raw JSON. *)

val append : Event.t -> t -> (t, Error.t) result
(** [append event t] is [t] with [event] appended.

    {!Error.Archived} or {!Error.Deleted} if [t] is not active;
    [Error (State e)] on a replay-invariant violation. A
    {!Event.Delegations_detached} supplied by a caller returns
    {!Error.Unexpected_delegation_detachment}; {!fork} and {!rewind} are the
    ordinary producers of canonical branch reset events, while {!make} and
    {!jsont} validate reconstructed documents structurally. *)

val append_all : Event.t list -> t -> (t, Error.t) result
(** [append_all events t] appends [events] in order, returning the first located
    replay error with its absolute event-log index; on error no partial session
    is returned. As with {!append}, a caller-supplied delegation detachment
    returns {!Error.Unexpected_delegation_detachment}. *)
