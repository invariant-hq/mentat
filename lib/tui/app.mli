(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure state, update, and complete-screen rendering for the terminal UI.

    [App] is the Elm shell at the frontend boundary. It owns only drafts,
    navigation, transient correlation, and presentation state. Durable
    conversation truth enters through {!fact}; droppable animation enters
    through {!progress}; every effect leaves as a typed {!command}. The module
    performs no client call, filesystem access, environment read, clock read, or
    durable session/turn identifier generation. App-owned request and auth
    tokens are transient correlations only.

    Runtime integrations construct the model with {!init}, interpret every
    returned command, and fold completions through the correlated message
    constructors below. Render with {!view} and install {!subscriptions}.
    Commands in one returned list may begin and complete in any order; one
    command therefore owns every ordering-sensitive effect. Issuing a second
    query for a single owner replaces its accepted token, so the earlier
    completion is stale. *)

type capabilities = {
  local_shell : bool;
      (** Whether leading [!] enters the executable-local shell surface. *)
  file_enumeration : bool;
      (** Whether [@] can enumerate workspace-relative paths. Free-text [@]
          remains available when this is [false]. *)
  browser : bool;  (** Whether URLs can be opened by the executable. *)
  external_editor : bool;
      (** Whether the editor chord (Ctrl+X Ctrl+E by default) opens the composer
          draft in an external editor. *)
  notify_command : bool;
      (** Whether the executable supplied an external notification-command hook,
          so the reducer may resolve the [command] notification channel. *)
  image_attach : bool;
      (** Whether the executable can attach images: [@]-mentioning an image file
          reads and stores it as a model-visible attachment instead of inserting
          a text reference, and a paste probes the OS clipboard for an image. *)
}
(** Availability of optional executable-local effects.

    These booleans advertise paths the executable actually supplied. They are
    not client capabilities and carry no function values into the pure shell. *)

type notify_policy = {
  notify_enabled : bool;  (** Whether notifications fire at all. *)
  notify_channel : Mentat_config.Notify.Channel.t;
      (** The configured delivery channel; [Auto] resolves to bell plus OSC 9.
      *)
  notify_focus : Mentat_config.Notify.When.t;
      (** When to fire relative to terminal focus. *)
  notify_on : Mentat_config.Notify.Event.t list;
      (** The events that raise a notification. *)
}
(** Launch-fixed notification policy, resolved by the executable from the
    [notify.*] configuration and injected before the first frame. The reducer
    decides against it and emits a fully-resolved {!Notify} command; the runtime
    only encodes and writes. The [command] channel's argv is not carried here —
    it lives in the executable's notification hook, advertised through
    {!capabilities.notify_command}. *)

(** {1:model Model and effects} *)

type t
(** The immutable application model. *)

type msg
(** An application input. Values come from the runtime, {!view}, or
    {!subscriptions}. *)

type request
(** An opaque shell-minted token correlating one transient command completion.

    A token has no protocol or durable meaning. The runtime receives it in a
    {!command} and must return the same value through the matching completion
    constructor. *)

val equal_request : request -> request -> bool
(** [equal_request left right] is equality on opaque correlation tokens. The
    runtime uses the initiating Start/Resume/Fork request as the admitted feed
    identity rather than minting a second identifier. *)

(** The source of an image the shell asks the executable to attach. Its bytes
    reach a model-visible {!Mentat_llm.Content.t} through {!attached}. *)
type image_source =
  | Attach_path of Lpath.Rel.t
      (** A workspace-relative image file the executable reads through its
          workspace boundary. *)
  | Attach_clipboard
      (** A request to probe the OS clipboard out-of-band for an image, which
          the executable performs; the pure shell never reads the clipboard. *)

(** Runtime effects. No constructor carries a client, flow, callback, host, or
    store value. *)
type command =
  | Quit  (** Exit the terminal application. *)
  | Attach_image of { request : request; source : image_source }
      (** Read (for {!Attach_path}) or probe the clipboard for (for
          {!Attach_clipboard}) an image, store it as a session attachment, and
          settle [request] through {!attached}. The runtime supplies the session
          — the active one, or the not-yet-created next session for a first
          prompt — since the attachment blob is fence-free and orphan until a
          later prompt references it. *)
  | Start_session of {
      request : request;
      prompt : string;
      media : Mentat_llm.Content.t list;
      mode : Mentat_session.Contract.Mode.t;
      history : Draft.History_entry.t option;
      goal : Mentat_protocol.Command.goal option;
      model :
        (Mentat_provider.Selector.t
        * Mentat_llm.Request.Options.Reasoning_effort.t option)
        option;
    }
      (** Mint a session and turn, create the session, follow it from [`Now],
          and only then submit [media] ahead of [prompt]. This ordering is the
          observation-before-admission law for the first prompt. Report the
          minted session with {!session_followed}; durable turn activity still
          begins only at {!Fact.Turn_started}. When [history] is present, the
          runtime attributes that entry to the same minted session before any
          asynchronous create/follow work begins. [goal], when present, is the
          user-declared objective that rides this first prompt; the engine mints
          its id at admission. [media] is the attached images' content blocks,
          placed ahead of the prompt text. [model], when present, is the
          selection the user staged before this session existed: the runtime
          applies it after create and before the first submit, so the first turn
          seals on the staged model; a refusal settles [request] through
          {!command_failed} without submitting the prompt. *)
  | Prompt of {
      request : request;
      session : Mentat_session.Id.t;
      prompt : string;
      media : Mentat_llm.Content.t list;
      mode : Mentat_session.Contract.Mode.t;
      goal : Mentat_protocol.Command.goal option;
    }
      (** Mint and submit a prompt turn in idle [session], with [media] ahead of
          the prompt text. The runtime owns client-safe turn-id generation; the
          resulting exact id enters the shell through {!Fact.Turn_started}.
          [goal], when present, is the user-declared objective that rides this
          turn; the engine mints its id at admission and rejects a second
          declaration over a live goal. *)
  | Queue_next of {
      request : request;
      session : Mentat_session.Id.t;
      prompt : string;
      media : Mentat_llm.Content.t list;
    }
      (** Submit [prompt] with [media] through [Command.queue_next] while a
          feed-proven turn is active. The queue becomes visible only through
          {!Fact.Journal_queue}. *)
  | Replace_queued of {
      request : request;
      session : Mentat_session.Id.t;
      inputs : Mentat_llm.Content.t list list;
    }
      (** Replace the queue through [Command.replace_queued], preserving the
          exact order and content of every remaining non-empty input. *)
  | Clear_queued of { request : request; session : Mentat_session.Id.t }
      (** Empty the queue through [Command.clear_queued]. This is distinct from
          an empty replacement so destructive intent remains explicit. *)
  | Interrupt of { session : Mentat_session.Id.t }
      (** Submit the one cooperative interrupt command. There is no forced
          interrupt intent. *)
  | Detach_session
      (** Stop following the current session after a local clear or switch. A
          local clear keeps that exact session durable and leaves its identity
          in the new chat's visible acknowledgement. *)
  | Resume_session of { request : request; session : Mentat_session.Id.t }
      (** Follow [session] from [`Beginning]. Replay and live delivery use the
          same {!fact} fold. *)
  | Fork_session of { request : request; session : Mentat_session.Id.t }
      (** Mint a child, fork [session], then follow the child from [`Beginning].
          Report the child with {!session_followed}. *)
  | Rewind_session of {
      request : request;
      source : Mentat_session.Id.t;
      anchor : Mentat_session.Anchor.t;
      prompt : string;
      media : Mentat_llm.Content.t list;
      mode : Mentat_session.Contract.Mode.t;
      history : Draft.History_entry.t option;
      goal : Mentat_protocol.Command.goal option;
    }
      (** Mint a child, rewind [source] at [anchor] into it, follow the child
          from [`Beginning], and only then submit [media] ahead of [prompt] as
          its first turn. This is {!Fork_session} plus an anchor and a trailing
          edited prompt. Report the child with {!session_followed}; durable turn
          activity still begins only at {!Fact.Turn_started}. [history], when
          present, attributes the seeded-and-edited draft to the child before
          create/follow work begins, exactly as on {!Start_session}. [goal],
          when present, is the user-declared objective riding this first turn.
      *)
  | Compact_session of { request : request; session : Mentat_session.Id.t }
      (** Run manual compaction. An installed compaction also arrives as a
          durable fact. Fold the typed [Installed]/[Skipped] result with
          {!compaction_finished}. *)
  | Undo_step of {
      request : request;
      session : Mentat_session.Id.t;
      op : [ `Undo | `Redo | `Cancel ];
    }
      (** Run one reversible undo step over the session at its idle point:
          [`Undo] steps the durable boundary back one user turn (reverting its
          files), [`Redo] forward one, [`Cancel] un-reverts and clears it. The
          armed state, transcript seam, and composer reload are driven by the
          projected [Fact.Undo] the step emits; only a drift or "nothing to
          undo/redo" refusal comes back to flash. *)
  | Rename_session of {
      request : request;
      session : Mentat_session.Id.t;
      title : string;
    }
      (** Set the explicit display title of [session]. Fold acknowledgement or
          failure through the correlated command-result constructors. *)
  | Archive_session of { request : request; session : Mentat_session.Id.t }
      (** Move the exact active [session] to the archived lifecycle. *)
  | Restore_session of { request : request; session : Mentat_session.Id.t }
      (** Restore the exact archived [session] to the active lifecycle. *)
  | Delete_session of { request : request; session : Mentat_session.Id.t }
      (** Permanently delete the exact idle, non-deleted [session]. *)
  | Load_home_sessions of request
      (** Query the complete active, current-workspace summary set for Home.
          Home applies top-level lineage eligibility before selecting its newest
          resumable summary. *)
  | Load_quick_sessions of request
      (** Query active, current-workspace summaries for the quick switcher. *)
  | Load_screen_sessions of request
      (** Query active, archived, and deleted summaries for the browser. *)
  | Load_session_view of { request : request; session : Mentat_session.Id.t }
      (** Query the exact single-session detail projection. *)
  | Load_pending_decision of {
      request : request;
      session : Mentat_session.Id.t;
    }
      (** Query the exact pending decision after attach so a resumed blocked
          session can reopen its dialog. *)
  | Load_configuration of request
      (** Query the credential-free effective configuration view. *)
  | Load_account_readiness of request
      (** Query exact provider-owned account discoveries and return them with
          {!account_readiness_loaded}, preserving [request] unchanged.

          This request has its own correlation lane. Its matching completion
          updates the global all-accounts-missing fact and the current Auth or
          Settings owner. When Settings is retained beneath an open Model panel,
          only that retained return screen is updated: account readiness never
          settles or refreshes {!Model_panel.t}. *)
  | Load_model_readiness of { request : request; refresh : bool }
      (** Query the provider-owned effective model-readiness snapshot and return
          it with {!model_readiness_loaded}, preserving [request] unchanged.
          [refresh] re-observes server-owned model listings before projecting;
          the panel's reload chord sets it, the opening load does not.

          Opening the Model panel issues this command in an independent
          correlation lane. A panel reload retains its exact state and return
          owner while replacing the lane's current token, so an older settlement
          becomes stale. A matching completion may update only the Model panel
          that is current when the result is folded; it does not change Auth,
          Settings, or the global all-accounts-missing fact. *)
  | Load_review_state of { request : request; scope : Mentat_review.Scope.t }
      (** Query the workspace review state at a focus scope. The review surface
          is workspace-scoped, so no constructor here carries a session. *)
  | Load_review_diff of { request : request; path : Lpath.Rel.t }
      (** Query the focused file's reviewable diff body. *)
  | Load_review_crs of request
      (** Query the review's CR occurrence views, in occurrence order. *)
  | Load_workspace_glance of request
      (** Query the ambient workspace status glance — the git worktree change
          summary against the review base and the tooling build-health verdict —
          for the wide-terminal side pane. Answered with
          {!workspace_glance_loaded}. Issued at session start and each turn
          settle; the result is held as a last observation, never persisted. *)
  | Load_workspace_dune of request
      (** Query the watch status alone — the glance's dune half without the
          git read. Answered with {!workspace_dune_loaded}. Issued on a short
          tick while the watch is starting, building, or restarting, so the
          row follows the watch between turn boundaries. *)
  | Dune_control of { request : request; op : [ `Restart | `Stop ] }
      (** Drive the supervised build watch; answers through
          {!workspace_dune_loaded} with the status after the verb. *)
  | Load_running_processes of {
      request : request;
      session : Mentat_session.Id.t;
    }
      (** Query [session]'s live background processes — the [shell] tool's
          [background:true] children — for the side pane's "running" section.
          Answered with {!running_processes_loaded}. Issued at session
          activation and each turn settle; the result is held as a last
          observation, never persisted, and reset on every session switch. *)
  | Submit_review_command of {
      request : request;
      command : Mentat_review.Command.t;
    }
      (** Apply one review mark, verdict, or cursor move to the workspace
          review. *)
  | Submit_review_compose of {
      request : request;
      edit : Mentat_review.Cr.Edit.t;
    }  (** Apply one CR add, replace, or remove to the worktree source. *)
  | Answer_decision of {
      request : request;
      session : Mentat_session.Id.t;
      decision : Mentat_session.Decision.Id.t;
      answer : Mentat_session.Decision.Answer.t;
    }
      (** Submit the one local-user decision answer. The TUI's principal is
          always [Local_user], so a decision is always resolved by submitting;
          the headless [answer_unattended] denial route is never used. The
          dialog stays open until the matching {!Fact.Decision_resolved}. *)
  | Set_model of {
      request : request;
      session : Mentat_session.Id.t;
      selector : Mentat_provider.Selector.t;
      reasoning_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
    }
      (** Ask the shell to accept [selector] and [reasoning_effort] for
          [session]'s next turn and settle [request] through
          {!command_succeeded} or {!command_failed}. [reasoning_effort] is
          [None] to follow the model default. Success acknowledges only the
          accepted setting; the exact effective model and effort enter through
          {!Fact.Turn_started}, never through a snapshot replacement in the
          completion. *)
  | Set_permission_review of {
      request : Settings_screen.mutation;
      session : Mentat_session.Id.t;
      review : Mentat_permission.Review_behavior.t;
    }
      (** Request [review] for [session]'s next turn. Return [request] unchanged
          through {!settings_mutation_finished}. *)
  | Persist_ui_theme of { request : request; name : string }
      (** Write [name] to [tui.theme] in the user config layer, then report the
          effective provenance through {!ui_theme_persisted}: [Ok None] when the
          write is effective, or [Ok (Some (layer, value))] when a higher config
          layer shadows it. Sessionless. *)
  | Goal_pause of {
      request : Goal_screen.mutation;
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
    }
      (** Pause the exact displayed active [goal]. Return [request] unchanged
          through {!goal_mutation_finished}; durable state still waits for a
          goal fact and session-detail refresh. [session] is the active owner at
          confirmation time; activating another session closes every screen, so
          a retained Goal screen cannot silently retarget this pair. *)
  | Goal_edit of {
      request : Goal_screen.mutation;
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
      objective : string;
    }  (** Replace the exact displayed unfinished [goal]'s objective. *)
  | Goal_resume of {
      request : Goal_screen.mutation;
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
      budget : int option;
    }
      (** Resume the exact displayed paused, blocked, or budget-limited [goal],
          optionally replacing its token budget. *)
  | Goal_clear of {
      request : Goal_screen.mutation;
      session : Mentat_session.Id.t;
      goal : Mentat_session.Goal.Id.t;
    }
      (** Clear the exact displayed unfinished [goal] after the screen's
          destructive confirmation. *)
  | Auth_save_api_key of {
      attempt : Auth_panel.attempt;
      provider : Mentat_llm.Provider.t;
      key : string;
    }
      (** Save [key] for [provider] and settle [attempt] with
          {!auth_save_api_key_finished}. The secret exists only in this one-shot
          command and never enters application state or a session transcript. *)
  | Auth_begin_login of {
      attempt : Auth_panel.attempt;
      provider : Mentat_llm.Provider.t;
      method_ : Mentat_provider.Auth.Login.Id.t;
    }
      (** Start one typed interactive login and return ephemeral progress and
          terminal values through {!auth_login_step}; start or pull failures use
          {!auth_login_failed}. *)
  | Auth_logout of {
      attempt : Auth_panel.attempt;
      provider : Mentat_llm.Provider.t;
    }
      (** Log [provider] out with the client's default [revoke=false] policy and
          settle [attempt] with {!auth_logout_finished}. *)
  | Auth_cancel of Auth_panel.attempt
      (** Cancel the exact active interactive login. *)
  | Load_prompt_history of request
      (** Read and decode the shared prompt history. *)
  | Load_user_commands of request
      (** Read the active custom-command catalog through the client for the
          slash palette, settling with {!user_commands_loaded}. *)
  | Expand_command of {
      request : request;
      name : string;
      arguments : string;
      entry : Draft.History_entry.t;
    }
      (** Expand the custom command [name] with [arguments] through the client
          and settle with {!command_expanded}. [entry] is the invocation's
          history entry, carried through so history records [/name arguments]
          while the expanded text drives the turn. *)
  | Append_prompt_history of {
      session : Mentat_session.Id.t option;
      entry : Draft.History_entry.t;
    }
      (** Persist one committed or discarded draft with its session attribution
          captured by the reducer. [None] denotes a draft that did not belong to
          an installed session; the runtime uses its non-session history
          identity rather than inferring a future session from mutable state. *)
  | Enumerate_files of request
      (** Invoke the advertised channel-3 recursive file enumeration capability
          once per open [@] completion; the bounded, ignore-pruned file list
          settles through {!files_loaded}. *)
  | Run_local_shell of { request : request; command : string }
      (** Invoke the advertised channel-3 sandbox-scoped local shell. This is
          never submitted as a session tool call or fact. *)
  | Cancel_local_shell of request
      (** Cooperatively cancel the correlated local shell process. *)
  | Edit_in_editor of { request : request; text : string }
      (** Invoke the advertised external-editor capability. [text] is the
          fully-expanded plain-text draft (pastes inlined, file refs as [@path]
          literals). Correlated; the runtime suspends the terminal around it and
          settles it with {!editor_finished}. Never a session fact. *)
  | Notify of {
      channels : [ `Bell | `Osc9 | `Osc777 | `Command ] list;
      title : string;
      body : string;
    }
      (** The reducer's fully-decided notification: it already fired the policy
          gate (enabled, event selected, focus per [notify.when]) and resolved
          [notify.channel] to the concrete [channels] to emit. The runtime only
          encodes each channel and writes — bell and OSC to the terminal,
          [`Command] to the notification hook — and re-decides nothing. *)
  | Copy_text of string
      (** Request a best-effort clipboard copy. The runtime may ignore this
          command when the platform has no clipboard integration. *)
  | Copy_selection
      (** Copy the terminal's current text selection to the clipboard. A no-op
          when nothing is selected. *)
  | Query_color_scheme
      (** Ask the terminal whether it uses a light or dark colour scheme, under
          [tui.theme = "auto"] only. The reply arrives as a color-scheme
          subscription event; terminals that do not answer leave the seeded dark
          member in place. *)
  | Open_url of { attempt : Auth_panel.attempt; url : Uri.t }
      (** Invoke the advertised browser capability for an exact login URL. *)
  | Observe_child of { request : request; child : Mentat_session.Id.t }
      (** Ask {!Child_feeds} to replay and follow a delegated child from
          [`Beginning]. *)
  | Drill_child of { request : request; child : Mentat_session.Id.t }
      (** Ask {!Child_feeds} to replace its drill feed with a replay from
          [`Beginning]. *)
  | Close_child_drill of {
      child : Mentat_session.Id.t;
      generation : Child_feeds.Generation.t;
    }  (** Stop the exact read-only drill generation. *)
  | Close_child_pane
      (** Stop every child observation when the owning pane is discarded. *)

(** {1:feed Feed inputs} *)

val fact :
  session:Mentat_session.Id.t ->
  request:request ->
  now:float ->
  Mentat_protocol.Fact.t ->
  msg
(** [fact ~session ~request ~now value] folds one committed feed fact only while
    the reducer owns that exact main observation. Delayed messages from a
    replaced observation are inert. [now] is a finite, nonnegative Unix
    timestamp in seconds supplied by the runtime.

    An accepted {!Fact.Turn_started} retires the transient notice from an
    earlier operation. Failure notices already rendered into the transcript
    remain durable history.

    A task-board fact replaces the chat's durable live-board projection whole.
    Open work remains visible after turn settlement or interruption; an empty
    board or a board containing only completed and cancelled tasks removes the
    live tenant. Starting, resuming, or forking into another chat clears the
    previous session's projection before replay installs that session's latest
    board. *)

val progress :
  session:Mentat_session.Id.t ->
  request:request ->
  now:float ->
  Mentat_protocol.Progress.t ->
  msg
(** [progress ~session ~request ~now value] folds one droppable pulse only for
    the exact installed observation. It can alter only live presentation state.
*)

val feed_failed :
  session:Mentat_session.Id.t ->
  request:request ->
  message:string ->
  login_needed:bool ->
  msg
(** [feed_failed ~session ~request ~message ~login_needed] terminally detaches
    the exact installed observation. Stale failures are inert. The reducer
    preserves the accepted transcript and session identity but refuses further
    prompts until an explicit resume successfully attaches a feed; exact
    [/sessions] text or a Sessions palette selection remains submittable through
    the composer as that recovery path. Successful recovery removes the
    detached-feed footer notice; an attachment outside this recovery state
    preserves unrelated notices. [login_needed] may open the authentication
    repair surface. *)

val operation_failed : message:string -> login_needed:bool -> msg
(** [operation_failed ~message ~login_needed] reports a client operation failure
    that did not invalidate the installed feed. *)

(** {1:command-results Correlated command results} *)

val session_followed :
  request:request ->
  session:Mentat_session.Id.t ->
  possibly_mutating:bool ->
  msg
(** [session_followed ~request ~session ~possibly_mutating] atomically installs
    the correlated start, resume, or fork observation. A correlated fork also
    records a transcript boundary naming the exact child and source session
    identities before child replay begins. Stale requests cannot replace the
    reducer's active observation or append that boundary. An accepted admission
    retires transient notice state from the preceding session before replay
    installs the admitted session's transcript. [possibly_mutating] is the
    client's exact attach-time recovery-ambiguity answer and remains visibly
    warned until the shell leaves that session. *)

val command_succeeded : request:request -> msg
(** [command_succeeded ~request] acknowledges a correlated client command that
    has no additional response value. A model-setting acknowledgement is shown
    only while its exact target session remains active, and says that the
    setting applies to the next turn. Durable UI state still waits for facts or
    owner-query refreshes. A successful correlated prompt submission retires an
    earlier transient notice while leaving transcript failure history intact. *)

val command_failed : request:request -> Mentat_protocol.Error.t -> msg
(** [command_failed ~request error] folds a structured client failure for the
    correlated command. Stale completions and model-setting failures for an
    inactive target session are inert. A failed queued-draft edit restores the
    exact prior composer entry only while the optimistic recovered entry is
    unchanged; later user edits are never overwritten. A browser lifecycle
    failure remains visible over its retained session rows and unlocks the
    pending row; it is never reduced to a hidden chat-only flash. *)

val compaction_finished :
  request:request ->
  (Mentat_client.compaction_result, Mentat_protocol.Error.t) result ->
  msg
(** [compaction_finished ~request result] preserves the client's exact manual
    compaction outcome. [Skipped] is a successful visible no-op; [Installed]
    waits for the matching durable compaction fact for transcript history. *)

val ui_theme_persisted :
  request:request ->
  ((string * string) option, Mentat_protocol.Error.t) result ->
  msg
(** [ui_theme_persisted ~request result] reports a [tui.theme] write from the
    /theme picker. [Ok None] flashed nothing beyond the commit;
    [Ok (Some (layer, value))] warns that a higher config [layer] pins
    [tui.theme] to [value], so the write will not take effect next launch;
    [Error _] reports a failed write. *)

val settings_mutation_finished :
  request:Settings_screen.mutation ->
  (unit, Mentat_protocol.Error.t) result ->
  msg
(** [settings_mutation_finished ~request result] returns the opaque screen token
    unchanged. The screen validates its captured exact session before accepting
    the result. *)

val goal_mutation_finished :
  request:Goal_screen.mutation -> (unit, Mentat_protocol.Error.t) result -> msg
(** [goal_mutation_finished ~request result] returns the opaque goal-screen
    token unchanged. Client success acknowledges admission only; the screen
    remains pending until an authoritative session-detail refresh changes its
    exact goal projection. *)

val capability_failed : request:request -> Mentat_diagnostic.t -> msg
(** [capability_failed ~request diagnostic] folds a structured failure from an
    advertised executable-local capability. *)

val attached :
  request:request ->
  (Mentat_llm.Content.t, Mentat_protocol.Attach.Error.t) result ->
  msg
(** [attached ~request result] folds the outcome of an {!Attach_image} command
    correlated by [request]. On success the returned media block is inserted as
    an atomic [[Image #N]] element in the composer whose attach is still
    pending; a rejection or failure surfaces as a transient notice. A stale or
    unknown [request] is inert (an empty-clipboard probe returns [Not_an_image]
    and is silently ignored). *)

(** {1:query-results Query results} *)

val home_sessions_loaded :
  request:request ->
  ( Mentat_session.Summary.t list * Mentat_diagnostic.t list,
    Mentat_protocol.Error.t )
  result ->
  msg
(** [home_sessions_loaded ~request result] folds an accepted Home-recents
    listing. A later Home request makes this completion stale. Healthy rows and
    report-only diagnostics are retained together. Multiple diagnostics keep
    explicit semantic separators after Home's one-line normalization. *)

val quick_sessions_loaded :
  request:request ->
  ( Mentat_session.Summary.t list * Mentat_diagnostic.t list,
    Mentat_protocol.Error.t )
  result ->
  msg
(** [quick_sessions_loaded ~request result] folds an accepted quick-switcher
    listing only while that panel still owns [request]. Healthy rows and
    report-only diagnostics are retained together, with explicit semantic
    separators between warnings after one-line normalization. *)

val screen_sessions_loaded :
  request:request ->
  ( Mentat_session.Summary.t list * Mentat_diagnostic.t list,
    Mentat_protocol.Error.t )
  result ->
  msg
(** [screen_sessions_loaded ~request result] folds an accepted full-browser
    listing only while that screen still owns [request]. Healthy rows and
    report-only diagnostics are retained together, with explicit semantic
    separators between warnings after one-line normalization. A post-lifecycle
    listing failure unlocks the pending row while keeping the preceding rows
    visible; stale results cannot clear or replace a newer browser. *)

val session_view_loaded :
  request:request ->
  session:Mentat_session.Id.t ->
  (Mentat_session.Session_view.t, Mentat_protocol.Error.t) result ->
  msg
(** [session_view_loaded] folds the detail projection only when both request and
    exact session identity still match. On the Goal screen an initial failure
    becomes its structured unavailable state, while a refresh failure retains
    the preceding exact goal projection and reports the complete diagnostic.
    Other surfaces keep their existing command-failure presentation. *)

val running_processes_loaded :
  request:request ->
  session:Mentat_session.Id.t ->
  (Mentat_protocol.Process.View.t list, Mentat_protocol.Error.t) result ->
  msg
(** [running_processes_loaded] folds the side pane's background-process view
    only when both request and exact session identity still match, so a stale
    poll from a since-switched session is dropped. A fresh observation replaces
    the held list; a failure keeps the previous one, the poll being ambient like
    the workspace glance (it surfaces no error). *)

val pending_decision_loaded :
  request:request ->
  session:Mentat_session.Id.t ->
  (Mentat_session.Decision.Requested.t option, Mentat_protocol.Error.t) result ->
  msg
(** [pending_decision_loaded] reopens only an owner-supported exact request.
    [None] invents no fallback dialog. *)

val configuration_loaded :
  request:request ->
  (Mentat_config.Resolved.View.t, Mentat_protocol.Error.t) result ->
  msg
(** [configuration_loaded ~request result] folds the exact effective
    configuration into the settings owner, including a settings screen retained
    beneath model selection. A stale request is ignored; refresh failure
    preserves a previously accepted owner value. *)

val account_readiness_loaded :
  request:request ->
  (Mentat_provider.Account.Discovery.t list, Mentat_protocol.Error.t) result ->
  msg
(** [account_readiness_loaded ~request result] folds exact account discoveries
    only when [request] is the current account-readiness request. Success
    updates the global all-accounts-missing fact and the current Auth or
    Settings owner. If the Model panel retains Settings as its return, that
    retained Settings value is refreshed without changing the Model-panel state.
    Failure preserves the preceding global fact and follows the owning Auth or
    Settings refresh-failure behavior. A stale result is ignored and cannot
    clear or replace the newer request. *)

val model_readiness_loaded :
  request:request ->
  (Mentat_provider.Model_readiness.t, Mentat_protocol.Error.t) result ->
  msg
(** [model_readiness_loaded ~request result] folds only when [request] is the
    current model-readiness request. A matching success installs the exact
    provider-owned snapshot into the currently open Model panel. A matching
    failure passes the complete diagnostic through {!Model_panel.failed}, which
    retains any preceding successful snapshot during refresh. If no Model panel
    is current, the matching request is retired without changing another
    surface. A stale result is ignored and cannot clear or replace a newer
    model-readiness request. *)

val review_state_loaded :
  request:request ->
  (Mentat_review.View.t, Mentat_protocol.Error.t) result ->
  msg
(** [review_state_loaded ~request result] folds a review-state read only while
    [request] is the open review's current query generation. *)

val review_diff_loaded :
  request:request ->
  path:Lpath.Rel.t ->
  (Mentat_review.File_diff.t option, Mentat_protocol.Error.t) result ->
  msg
(** [review_diff_loaded ~request ~path result] folds a focused-file diff body. A
    body for a path the cursor no longer focuses is dropped. *)

val review_crs_loaded :
  request:request ->
  (Mentat_review.Cr.View.t list, Mentat_protocol.Error.t) result ->
  msg
(** [review_crs_loaded ~request result] folds the review's CR occurrence views.
*)

val workspace_glance_loaded :
  request:request ->
  ( Textdiff.stats option * Mentat_workspace.Health.t,
    Mentat_protocol.Error.t )
  result ->
  msg
(** [workspace_glance_loaded ~request result] folds the ambient workspace-status
    glance only while [request] is the current glance generation. A success
    replaces the held observation — the worktree change summary and the tooling
    verdict — a failure keeps the previous one (retry in place, no blank flash),
    and a stale result is dropped. *)

val workspace_dune_loaded :
  request:request ->
  (Mentat_workspace.Health.t, Mentat_protocol.Error.t) result ->
  msg
(** [workspace_dune_loaded ~request result] folds a watch-status poll only
    while [request] is the current generation, with {!workspace_glance_loaded}'s
    replace-on-success, keep-on-failure law. *)

val review_command_finished :
  request:request -> (unit, Mentat_protocol.Error.t) result -> msg
(** [review_command_finished ~request result] reports a review command's
    outcome. Success is silent; a failure surfaces as a review notice. *)

val review_compose_finished :
  request:request -> (unit, Mentat_protocol.Error.t) result -> msg
(** [review_compose_finished ~request result] reports a CR edit's outcome. A
    failure re-opens the draft with the problem when the dialog is still open.
*)

(** {1:auth-results Authentication results} *)

val auth_login_step :
  attempt:Auth_panel.attempt -> Mentat_client.Login.step -> msg
(** [auth_login_step ~attempt step] folds one exact interactive-login step. An
    accepted [Saved account] settles the panel from [account] and reissues the
    full account-readiness query for every other surface. *)

val auth_login_failed :
  attempt:Auth_panel.attempt -> Mentat_protocol.Error.t -> msg
(** [auth_login_failed ~attempt error] folds one structured start or pull
    failure for the exact interactive login. *)

val auth_save_api_key_finished :
  attempt:Auth_panel.attempt ->
  (Mentat_provider.Account.t, Mentat_protocol.Error.t) result ->
  msg
(** [auth_save_api_key_finished ~attempt result] folds the exact correlated
    account returned by an API-key save, or its structured error. An accepted
    success reissues the full account-readiness query. *)

val auth_logout_finished :
  attempt:Auth_panel.attempt ->
  (Mentat_provider.Account.Logout.t, Mentat_protocol.Error.t) result ->
  msg
(** [auth_logout_finished ~attempt result] folds the exact correlated logout
    settlement, or its structured error. An accepted success reissues the full
    account-readiness query. *)

val auth_url_opened : attempt:Auth_panel.attempt -> msg
(** [auth_url_opened ~attempt] acknowledges a frontend-local browser open only
    for the matching live login. *)

val auth_url_open_failed : attempt:Auth_panel.attempt -> message:string -> msg
(** [auth_url_open_failed ~attempt ~message] folds a frontend-local browser
    failure only for the matching live login. *)

(** {1:local-results Local persistence and capability results} *)

val prompt_history_loaded : request:request -> string -> msg
(** [prompt_history_loaded ~request contents] decodes the raw persisted JSONL
    history and installs its canonical entries. Rejections remain visible as a
    non-fatal diagnostic. History's private representation does not cross the
    executable boundary. *)

val user_commands_loaded :
  request:request ->
  (Mentat_protocol.User_command.t list, Mentat_protocol.Error.t) result ->
  msg
(** [user_commands_loaded ~request result] installs the custom-command catalog
    snapshot for the palette, or, on failure, leaves the previous snapshot in
    place — a benign staleness, not a surfaced error. *)

val command_expanded :
  request:request ->
  entry:Draft.History_entry.t ->
  (Mentat_llm.Content.t list, Mentat_protocol.Error.t) result ->
  msg
(** [command_expanded ~request ~entry result] submits the expansion of a custom
    command as a user turn. An empty expansion or a client error is reported as
    a non-fatal flash and no turn is sent. *)

val files_loaded :
  request:request -> (Lpath.Rel.t list, Mentat_diagnostic.t) result -> msg
(** [files_loaded ~request result] folds the one recursive enumeration result
    only into the exact still-open mention generation. [Ok files] is the
    capability's bounded, ignore-pruned regular-file list in root-relative path
    order. Recoverable authority and filesystem failures remain structured until
    this presentation fold. *)

val local_shell_finished :
  request:request -> (Tool_block.t, Mentat_diagnostic.t) result -> msg
(** [local_shell_finished] settles a correlated local shell row. Its block is
    local presentation history, never a durable session fact. An accepted
    successful block retires the previous transient notice while preserving
    failure blocks already rendered into the transcript. *)

val editor_finished :
  request:request -> (string, Mentat_diagnostic.t) result -> msg
(** [editor_finished ~request result] settles a correlated external-editor
    invocation. On success the returned buffer replaces the draft as a plain
    draft (cursor at end, no atom rebinding); on failure the draft is left
    untouched and the structured error surfaces as a transient notice. *)

(** {1:child-feeds Child feed inputs} *)

val child_observation_started :
  request:request ->
  observation:Child_feeds.observation ->
  child:Mentat_session.Id.t ->
  generation:Child_feeds.Generation.t ->
  msg
(** [child_observation_started] installs the exact generation returned by
    {!Child_feeds.follow_live} or {!Child_feeds.drill} only for its correlated
    request. *)

val child_feed :
  observation:Child_feeds.observation ->
  generation:Child_feeds.Generation.t ->
  child:Mentat_session.Id.t ->
  (Mentat_client.Feed.outcome, Mentat_protocol.Error.t) result ->
  msg
(** [child_feed] folds an exact child-feed outcome. Mismatched generations are
    stale and ignored. Committed facts and progress retain their owner types;
    [Closed] and structured errors remain explicit edge states.

    A live child's unresolved decision renders as blocked rather than working.
    An error accepted for its current live generation both marks that child
    unavailable and enters the parent error presentation. Errors from stale
    generations affect neither surface. Its first accepted transition from no
    outcome to a terminal outcome appends one parent-transcript event naming the
    delegated task and outcome. Replayed or duplicate settlement facts cannot
    append that event again while the projection already owns its terminal
    outcome, and drill-in replay never writes into the parent transcript. *)

(** {1:elm Elm loop} *)

val set_palette : Theme.Palette.t -> t -> t
(** [set_palette palette t] swaps the active color palette. Because [t.palette]
    is the only threaded source of color, this single-field update recolors the
    whole TUI on the next frame; it backs the /theme picker's live preview. *)

val init :
  now:float ->
  startup:Startup.t ->
  capabilities:capabilities ->
  reduced_motion:bool ->
  show_reasoning:bool ->
  overlay:Command.Overlay.t ->
  notify_policy:notify_policy ->
  palette:Theme.Palette.t ->
  theme_name:string ->
  themes:Theme.Preset.t list ->
  theme_auto:(Theme.Palette.t * Theme.Palette.t) option ->
  image_max_count:int ->
  t * command list
(** [init ~now ~startup ~capabilities ~reduced_motion ~show_reasoning ~overlay
     ~notify_policy ~palette ~theme_name ~themes ~image_max_count] is the
    initial model and ordered startup effects. [palette] is the resolved
    starting palette; [theme_name] its resolved [tui.theme] name (for the /theme
    picker's preselection and commit); [themes] the resolved theme catalog
    (built-in presets merged with user files) the picker previews from.
    [theme_auto] is [Some (dark, light)] only under [tui.theme = "auto"]: the
    resolved members the palette follows the terminal between. Under auto
    [palette] is seeded to [dark] and startup issues {!Query_color_scheme}; a
    hand pick in the /theme picker disarms following for the session.
    [image_max_count] is the launch-fixed cap on attached images per input,
    resolved from [image.max_count]. [overlay] is the launch-fixed keybinding
    overlay the executable resolved from the user's keybindings file over the
    registry defaults ({!Command.Overlay}). [notify_policy] is the launch-fixed
    notification policy resolved from configuration. [capabilities] is the exact
    set of optional executable-local paths available for this model's lifetime.
    A requested resumed session remains pending until the runtime successfully
    installs its replay from [`Beginning]; only then are its detail projection
    and pending decision requested. A fresh launch loads recents, readiness,
    history, and a saved draft; [Startup.Submit] additionally issues the
    observation-before-admission command before the first frame.

    Raises [Invalid_argument] if [now] is negative or non-finite. *)

val update : msg -> t -> t * command list
(** [update message t] folds one input and returns ordered effects. Facts alone
    change {!Turn.in_flight}; submission acknowledgements never do. Dialogs
    close only on their exact durable decision resolution. Unsupported and
    absent capability paths remain inert or display an honest explanation. Enter
    on an unmatched slash completion submits its literal draft as an ordinary
    prompt. Ctrl+C discards and persists a nonblank draft before it can arm
    quitting, and cancels a live interactive login before either action; Escape
    leaves an empty executable-local shell draft before walking the interrupt
    ladder. Reverse-history search borrows a cleared composer and restores the
    saved draft when cancelled.

    Transcript page requests remain pending until the measured viewport consumes
    and acknowledges them; acknowledgements retire only the matching request, so
    stale callbacks cannot erase a newer page action. An accepted prompt uses
    its App-owned request identity to issue a keyed sticky reset, clearing any
    older unconsumed page request and returning to the live tail. Ordinary facts
    and progress never reset a manually parked transcript, and a sticky-reset
    acknowledgement retires only its matching request. *)

val view : t -> msg Mosaic.t
(** [view t] renders the complete terminal UI: Home, transcript and live tail,
    composer, activity strips/pane, modal panel, or full screen. The root grows
    and shrinks within the allocation supplied by Mosaic; child surfaces own
    their intrinsic sizing, clipping, wrapping, and scrolling. Tiny allocations
    retain an identifying action or surface glyph rather than an anonymous
    ellipsis. A drilled child is identified by its exact delegation task and
    parent relationship above the replaying transcript; Escape returns to the
    unchanged parent view. *)

val terminal_title : t -> string
(** [terminal_title t] is the product name and workspace leaf prefixed by an
    idle or alternating active marker, so a host multiplexer names the tab. *)

val subscriptions : t -> msg Mosaic.Sub.t
(** [subscriptions t] installs global modal key routing, animation, turn/notice
    timers, and paste interception for the surface that owns input. A focused
    Mosaic widget retains every key whose default it prevented; the application
    classifies only unclaimed keys, including modal navigation and
    application-only bindings.

    No subscription reads a clock or performs an external effect. *)
