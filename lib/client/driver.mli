(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The construction seam — {b not} a frontend API.

    A [Driver.t] is a record of typed effect-carrying functions, one sub-record
    per owning cone, injected once into {!Mentat_client.make}. It is
    multi-source: the engine fills exactly {!Session}; the executable's
    composition root fills {!Accounts}, {!Settings}, {!Lifecycle}, {!Review},
    and {!Workspace} over the provider runtime, config IO, the store's metadata
    surface, and the workspace git and dune surfaces. The frontend cannot tell
    which field came from where — that indistinguishability is the seam's
    purpose. Every result-bearing field settles through
    {!Mentat_protocol.Error.t}; the library names no engine, store, or transport
    type. The client preserves returned errors, re-raises cancellation, and maps
    another exception from a result-bearing field to an operation-labelled
    {!Mentat_protocol.Error.Unavailable} without exposing exception text. The
    plain [Session.possibly_mutating] condition and cleanup callbacks are
    outside that result contract.

    The seam's raw feed and login-step records are {!Feed.seam} and
    {!Login.steps}, placed on their wrappers so this module depends on {!Feed}
    and {!Login} rather than forming a cycle. *)

(** The type for a manual compaction outcome. *)
type compaction_result =
  | Installed  (** The compaction fact is durable and projected on the feed. *)
  | Skipped  (** No compaction was needed; nothing was installed. *)

(** The engine-filled session cone: each field backs the identically-named
    {!Mentat_client} operation, except [follow] (backs
    {!Mentat_client.follow_session}, minus its [~sw]). The reads
    [pending_decision] and [change_diff] back {!Mentat_client.pending_decision}
    and {!Mentat_client.change_diff}. Every field reaches the session's journal
    or its single-writer fence; only the engine may. Returned as one value by
    the engine's [val driver]. *)
module Session : sig
  type t = {
    submit :
      Mentat_protocol.Command.t -> (unit, Mentat_protocol.Error.t) result;
        (** [submit command] admits [command] durably before returning [Ok ()].
            The command carries its target session. *)
    follow :
      Mentat_session.Id.t ->
      from:Feed.from ->
      (Feed.seam, Mentat_protocol.Error.t) result;
        (** [follow session ~from] is the raw pull-feed seam for [session]. The
            client wrapper owns the switch that bounds the public feed. *)
    answer_unattended :
      session:Mentat_session.Id.t ->
      decision:Mentat_session.Decision.Id.t ->
      (unit, Mentat_protocol.Error.t) result;
        (** [answer_unattended ~session ~decision] durably denies [decision] as
            unattended policy. It is distinct from a local-user answer. *)
    possibly_mutating : session:Mentat_session.Id.t -> bool;
        (** [possibly_mutating ~session] is [true] iff this process drives
            [session] and recovery found an unresolved mutation risk. *)
    faulted : session:Mentat_session.Id.t -> Mentat_diagnostic.t option;
        (** [faulted ~session] is [Some diagnostic] iff this process drives
            [session] and its driver has contained a fault; [None] otherwise. *)
    fork :
      session:Mentat_session.Id.t ->
      into:Mentat_session.Id.t ->
      (unit, Mentat_protocol.Error.t) result;
        (** [fork ~session ~into] durably creates [into] from the complete
            journal of [session], without changing [session]. *)
    rewind :
      session:Mentat_session.Id.t ->
      into:Mentat_session.Id.t ->
      anchor:Mentat_session.Anchor.t ->
      (unit, Mentat_protocol.Error.t) result;
        (** [rewind ~session ~into ~anchor] durably creates [into] from
            [session]'s journal cut at [anchor], without changing [session]. *)
    compact :
      session:Mentat_session.Id.t ->
      turn:Mentat_session.Turn.Id.t ->
      (compaction_result, Mentat_protocol.Error.t) result;
        (** [compact ~session ~turn] runs manual compaction under the
            client-minted compaction [turn] id and reports whether it installed
            a durable compaction fact. Find-or-create: replaying the same [turn]
            returns the already-installed [Installed] or re-derived [Skipped]
            result without a second compaction; a [turn] that names a
            non-compaction turn is {!Mentat_protocol.Error.Turn_id_reused}. *)
    pending_decision :
      Mentat_session.Id.t ->
      ( Mentat_session.Decision.Requested.t option,
        Mentat_protocol.Error.t )
      result;
        (** [pending_decision session] is [Some decision] when [session] is
            awaiting a decision and [None] otherwise. *)
    running_processes :
      Mentat_session.Id.t ->
      (Mentat_protocol.Process.View.t list, Mentat_protocol.Error.t) result;
        (** [running_processes session] is a live snapshot of [session]'s
            background processes — the [shell] tool's [background:true] children
            still running — for the side pane and the between-turns reminder.
            Derived on demand from the driving process's ephemeral registry,
            never persisted; a session this process does not drive answers the
            empty view. Backs {!Mentat_client.running_processes}. *)
    change_diff :
      session:Mentat_session.Id.t ->
      change:Mentat_mutation.Change.Id.t ->
      (Textdiff.Hunk.t list, Mentat_protocol.Error.t) result;
        (** [change_diff ~session ~change] is the bounded diff for [change] in
            [session]'s mutation history. *)
    tail :
      ?n:int ->
      Mentat_session.Id.t ->
      (Mentat_protocol.Transcript.Tail.t, Mentat_protocol.Error.t) result;
        (** [tail ?n session] is [session]'s bounded first paint: the feed head,
            the pending decision, and the last [n] facts
            ({!Mentat_protocol.Transcript.Tail.default_n} when omitted, clamped
            to {!Mentat_protocol.Transcript.Tail.max_n}). Served O(page) from
            the live hub, or one O(J) journal fold when the session is not
            driven. *)
    page :
      ?n:int ->
      Mentat_session.Id.t ->
      before:Mentat_protocol.Position.t option ->
      (Mentat_protocol.Transcript.Page.t, Mentat_protocol.Error.t) result;
        (** [page ?n session ~before] is one older page of [session]'s
            transcript: the last [n] facts strictly before [before] ([None]
            reads before the head). A [before] naming no committed fact of the
            feed is [Error (Invalid_position _)], the same membership check
            {!Mentat_protocol.Projection.after} enforces. *)
    revert :
      session:Mentat_session.Id.t ->
      scope:Mentat_mutation.Revert.Scope.t ->
      (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result;
        (** [revert ~session ~scope] applies a revert over [session]'s recorded
            mutation history under the session's fence: [scope] (the latest
            revertable turn, a change id, or a path) resolves to the affected
            changes and restores them. The outcome names the settlement, a clean
            no-op when nothing matched, or the preparation-refusal messages when
            it refused before touching a file. Runs at the driven session's idle
            point (the R6 online cone), or through the offline twin's own fence
            when this process does not drive it. *)
    undo :
      session:Mentat_session.Id.t ->
      op:[ `Undo | `Redo | `Cancel ] ->
      (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result;
        (** [undo ~session ~op] runs one undo step over [session] at its idle
            point: [`Undo] steps the durable undo boundary back one user turn
            (reverting its files), [`Redo] forward one (past the last undone
            turn it clears the boundary), and [`Cancel] un-reverts and clears
            it. The outcome is the file revert's — a settlement, a clean no-op,
            or a [Refused] carrying a drift refusal or a "nothing to undo/redo"
            message to flash. The armed state and transcript seam are pure
            functions of the projected [Fact.Undo] the boundary append emits. *)
    export :
      session:Mentat_session.Id.t -> (string, Mentat_protocol.Error.t) result;
        (** [export ~session] is [session]'s complete, integrity-verified NDJSON
            bundle as one value — a read under the fence when driven, a
            fence-free view otherwise. Bounded by a size guard: a session whose
            bundle would exceed the threshold is [Error (Unavailable _)] naming
            the offline streaming twin, rather than buffering an unbounded
            value. *)
  }
end

(** The executable-filled account cone, over [mentat.provider_runtime]. Each
    field backs the identically-named {!Mentat_client} operation, except [login]
    (backs {!Mentat_client.login}, returning the raw {!Login.steps} the facade
    boxes); [account_readiness] and [model_readiness] back the reads of the same
    name. *)
module Accounts : sig
  type t = {
    login :
      provider:Mentat_llm.Provider.t ->
      method_:Mentat_provider.Auth.Login.Id.t ->
      (Login.steps, Mentat_protocol.Error.t) result;
        (** [login ~provider ~method_] starts the provider's interactive login
            and returns its raw pull steps. {!Mentat_client.login} boxes them
            into the abstract {!Login.t}. *)
    save_api_key :
      provider:Mentat_llm.Provider.t ->
      key:string ->
      (Mentat_provider.Account.t, Mentat_protocol.Error.t) result;
        (** [save_api_key ~provider ~key] validates, persists, and checks an API
            key before returning the exact credential-free account observation
            of the committed secret. The responder must not retain [key]. *)
    logout :
      ?revoke:bool ->
      Mentat_llm.Provider.t ->
      (Mentat_provider.Account.Logout.t, Mentat_protocol.Error.t) result;
        (** [logout ?revoke provider] removes the provider's stored credential
            and returns its exact post-settlement discovery. [revoke] defaults
            to [false]; [true] also requests remote revocation and reports its
            structured settlement. *)
    account_readiness :
      unit ->
      (Mentat_provider.Account.Discovery.t list, Mentat_protocol.Error.t) result;
        (** [account_readiness ()] is the current credential-free discovery of
            the declared providers in catalog order. Resolution failures remain
            provider-local values rather than erasing healthy routes. *)
    model_readiness :
      ?refresh:bool ->
      unit ->
      (Mentat_provider.Model_readiness.t, Mentat_protocol.Error.t) result;
        (** [model_readiness ?refresh ()] is the exact provider-owned readiness
            snapshot {!Mentat_client.model_readiness} returns. Provider and
            model order, owner-defined facts, and resolution failures are
            preserved. [refresh] (default [false]) re-observes server-owned
            model listings before projecting. *)
  }
end

(** The executable-filled settings cone, over [mentat.config] plus the
    per-session model and review overlays the responder keeps. Session-scoped
    writes take effect at the session's next turn. The setter fields back their
    identically named {!Mentat_client} operations; [configuration] backs
    {!Mentat_client.configuration}. *)
module Settings : sig
  type t = {
    set_model :
      session:Mentat_session.Id.t ->
      ?reasoning_effort:Mentat_llm.Request.Options.Reasoning_effort.t ->
      Mentat_provider.Selector.t ->
      (unit, Mentat_protocol.Error.t) result;
        (** Sets the model and optional reasoning effort as one exact selection
            for the session's next turn. An omitted effort requests the
            provider/model default; it does not inherit a configured effort. *)
    set_permission_review :
      session:Mentat_session.Id.t ->
      Mentat_permission.Review_behavior.t ->
      (unit, Mentat_protocol.Error.t) result;
        (** [set_permission_review ~session review] changes permission-review
            behavior for [session]'s next turn. It does not change unattended
            policy. *)
    configuration :
      unit -> (Mentat_config.Resolved.View.t, Mentat_protocol.Error.t) result;
        (** [configuration ()] is the effective credential-free configuration
            with each value's origin. *)
    set_default_model :
      ?reasoning_effort:Mentat_llm.Request.Options.Reasoning_effort.t ->
      Mentat_provider.Selector.t ->
      (unit, Mentat_protocol.Error.t) result;
        (** [set_default_model ?reasoning_effort selector] durably writes the
            user's default model (and optional reasoning effort) to the user
            config file — {b sessionless}, unlike {!set_model}. Validated
            through the catalog before the write; a concurrent offline
            [config set] serialises on the atomic rename (last-writer-wins). It
            takes effect at every live session's next turn, where config
            re-stages from disk. *)
    set_ui_theme : theme:string -> (unit, Mentat_protocol.Error.t) result;
        (** [set_ui_theme ~theme] durably writes [tui.theme] to the user config
            file — {b sessionless}, the same write path [config set] uses. The
            name is not validated against a catalog: an unknown theme falls back
            at TUI launch. It is outranked by the project layers, so the caller
            should check the effective provenance after the write. *)
  }
end

(** The executable-filled lifecycle cone, over the store's metadata surface.
    Each field backs the identically-named {!Mentat_client} operation. The
    read-only [sessions]/[session] fields back the reads of the same name; the
    composition root fills them by composing the store's exact scan with
    {!Mentat_session.Summary.of_session} /
    {!Mentat_session.Session_view.of_session} and the
    {!Mentat_session.Listing.select} policy. *)
module Lifecycle : sig
  type t = {
    create :
      id:Mentat_session.Id.t ->
      title:string option ->
      (unit, Mentat_protocol.Error.t) result;
        (** [create ~id ~title] durably creates the client-named session [id].
        *)
    rename :
      session:Mentat_session.Id.t ->
      title:string ->
      (unit, Mentat_protocol.Error.t) result;
        (** [rename ~session ~title] durably replaces [session]'s title. *)
    archive :
      session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
        (** [archive ~session] durably marks [session] archived. *)
    restore :
      session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
        (** [restore ~session] durably returns an archived [session] to the
            active state. *)
    delete :
      session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
        (** [delete ~session] durably marks [session] deleted. Deletion has no
            inverse. *)
    sessions :
      listing:Mentat_session.Listing.t ->
      ( Mentat_session.Summary.t list * Mentat_diagnostic.t list,
        Mentat_protocol.Error.t )
      result;
        (** [sessions ~listing] is the healthy session index selected and
            ordered by [listing], plus one reportable diagnostic for every
            corrupt entry in the unfiltered scan. *)
    session :
      Mentat_session.Id.t ->
      (Mentat_session.Session_view.t, Mentat_protocol.Error.t) result;
        (** [session id] is the credential-free detail view of [id]. *)
  }
end

(** The executable-filled review cone, over [mentat.review] plus the review
    store and the workspace git surface. The review is workspace-scoped, not
    session-scoped (a review is over a worktree diff, not a conversation), so no
    field carries a session id and no completion is a session fact. [apply]
    backs {!Mentat_client.review}; [state] backs {!Mentat_client.review_state}.
*)
module Review : sig
  type t = {
    apply : Mentat_review.Command.t -> (unit, Mentat_protocol.Error.t) result;
        (** [apply command] applies one review-state transition — a scope mark,
            a whole-feature verdict, or a cursor move — and durably records the
            resulting review state before returning [Ok ()]. Not session-scoped
            and no session fact; the [review_state] read returns the result. *)
    state :
      scope:Mentat_review.Scope.t ->
      (Mentat_review.View.t, Mentat_protocol.Error.t) result;
        (** [state ~scope] is the current workspace review projected to the
            review owner's serializable {!Mentat_review.View.t}, with [scope]
            recorded as the focused scope. It carries no feature content. *)
    diff :
      path:Lpath.Rel.t ->
      (Mentat_review.File_diff.t option, Mentat_protocol.Error.t) result;
        (** [diff ~path] is [path]'s reviewable diff body as
            {!Mentat_review.File_diff.t}, or [None] when the feature does not
            change [path]. Backs {!Mentat_client.review_diff}. *)
    crs :
      unit -> (Mentat_review.Cr.View.t list, Mentat_protocol.Error.t) result;
        (** [crs ()] is the review's CR occurrences as serializable
            {!Mentat_review.Cr.View.t} values in occurrence order. Backs
            {!Mentat_client.review_crs}. *)
    compose : Mentat_review.Cr.Edit.t -> (unit, Mentat_protocol.Error.t) result;
        (** [compose edit] applies a wire-safe {!Mentat_review.Cr.Edit.t} — a CR
            add, replace, or remove — to the worktree and durably records the
            refreshed review before returning [Ok ()]. The responder re-resolves
            each ref against a fresh snapshot, so a moved source fails loud and
            the frontend re-queries. Backs {!Mentat_client.review_compose}. *)
  }
end

(** The executable-filled workspace cone, over [mentat.workspace_io]'s git
    surface and the composition's dune-RPC probe. It is workspace-scoped, not
    session-scoped — a worktree summary and a build-health verdict belong to the
    checkout, not a conversation — so no field carries a session id. [glance]
    backs {!Mentat_client.workspace_glance}. *)
module Workspace : sig
  type t = {
    glance :
      unit -> (Textdiff.stats option, Mentat_protocol.Error.t) result;
        (** [glance ()] is the git worktree change summary against the review
            base, or [None] when the workspace is not a git worktree or git is
            unavailable. It re-reads git per call and holds no cache; the
            frontend keeps the result as a last observation. *)
    dune : unit -> (Mentat_workspace.Health.t, Mentat_protocol.Error.t) result;
        (** [dune ()] is the watch status — the one wire carrier of the dune
            row's fact, a memory read of the attach observer's snapshot with
            no git involved, so a frontend polls it at the event moments and
            on a tick alike. Backs {!Mentat_client.workspace_dune}. *)
    dune_control :
      op:[ `Restart | `Stop ] ->
      (Mentat_workspace.Health.t, Mentat_protocol.Error.t) result;
        (** [dune_control ~op] is the user's verb over the supervised build
            watch: [`Restart] forgives a terminal state — gave up, a blocked
            file watcher, a stop — and cycles a fresh watch from the probe;
            [`Stop] ends supervision for the session. Both answer with the
            status after the verb, so a frontend refreshes its row from the
            reply; with no supervisor (the lane off) both are observations
            only. Backs {!Mentat_client.workspace_dune_control}. *)
  }
end

type t = {
  session : Session.t;
      (** The engine-owned session journal, feed, and fenced mutation cone. *)
  accounts : Accounts.t;  (** The executable-owned provider-account cone. *)
  settings : Settings.t;
      (** The executable-owned effective configuration and session-settings
          cone. *)
  lifecycle : Lifecycle.t;  (** The executable-owned session metadata cone. *)
  review : Review.t;  (** The executable-owned workspace review cone. *)
  workspace : Workspace.t;
      (** The executable-owned workspace status-glance cone. *)
}
(** The full injection record the composition root assembles. *)
