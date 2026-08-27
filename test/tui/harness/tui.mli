(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Deterministic complete-screen sessions for the next TUI.

    [run] drives {!Mentat_tui.Runtime.run} in Mosaic's headless Matrix backend
    with a fake {!Mentat_client.Driver.t} and narrow
    {!Mentat_tui.Runtime.Local.t} callbacks. Launch queries, session
    attach/replay, persistence, and explicitly supplied turn, model, and account
    scripts therefore cross the same Runtime composition boundary as the
    executable. Unknown effects fail loudly instead of being silently mocked. *)

module Mutation_script : sig
  (** Independent claim-scope mutation evidence for scripted turns.

      These fixtures author evidence through [Mentat_edit.apply] and
      [Mentat_mutation.Event], not through a tool result. The harness joins that
      owner state to the correlated tool settlement only through
      [Mentat_protocol.Projection]. *)

  module Change : sig
    type t
    (** The type for one valid text-file transition. *)

    val create : path:Lpath.Rel.t -> contents:string -> t
    (** [create ~path ~contents] records [path] changing from missing to the
        complete UTF-8 [contents]. *)

    val update : path:Lpath.Rel.t -> before:string -> after:string -> t
    (** [update ~path ~before ~after] records one complete UTF-8 rewrite.

        Raises [Invalid_argument] when [before] and [after] are equal. *)

    val delete : path:Lpath.Rel.t -> before:string -> t
    (** [delete ~path ~before] records the complete UTF-8 file at [path]
        becoming missing. *)
  end

  type t
  (** The type for one tool claim's independently observed mutation outcome. *)

  val make :
    call_id:string ->
    ?changes:Change.t list ->
    ?observed:Lpath.Rel.t list ->
    unit ->
    t
  (** [make ~call_id ?changes ?observed ()] records exact transitions and opaque
      observed paths for the direct claim derived from [call_id]. At least one
      arm must be non-empty. Exact paths and observed paths must be unique and
      disjoint. *)
end

module Turn_script : sig
  type tool
  (** One model-requested tool call and its durable terminal result. *)

  val tool :
    call:Mentat_llm.Tool.Call.t ->
    result:Mentat_tool.Output.t Mentat_tool.Result.t ->
    tool
  (** [tool ~call ~result] is one direct tool step in a scripted provider turn.
      The call's input becomes the claim's canonical input. *)

  val ambiguous_tool : call:Mentat_llm.Tool.Call.t -> tool
  (** [ambiguous_tool ~call] is a direct claim whose callback outcome was not
      recorded. Independent {!Mutation_script} evidence may still correlate with
      the claim. *)

  type t
  (** One expected user prompt, its live provider progress, and the durable
      settlement released by {!finish_turn}. *)

  val complete :
    ?model:Mentat_llm.Model.t ->
    ?reasoning_effort:Mentat_llm.Request.Options.Reasoning_effort.t ->
    ?reasoning_deltas:string list ->
    ?assistant_deltas:string list ->
    ?downloads:Mentat_protocol.Progress.Model_download.t list ->
    ?retries:Mentat_llm.Event.Retry.t list ->
    ?reasoning_summary:string list ->
    ?usage:Mentat_llm.Usage.t ->
    ?task_boards:Mentat_session.Task.Board.t list ->
    ?notices:Mentat_session.Notice.t list ->
    ?tools:tool list ->
    ?mutations:Mutation_script.t list ->
    prompt:string ->
    string ->
    t
  (** [complete ~prompt text] starts and holds a successful turn. [model]
      defaults to the harness model and [reasoning_effort] defaults to absent;
      both enter through the exact sealed [Turn_started] contract. Progress
      deltas are folded before the held frame. [downloads], when present, are
      folded as model-artifact preparation pulses immediately after the turn's
      [Started] pulse, so a held frame with no assistant deltas renders the live
      download line. [retries], when present, are folded as retry-announcement
      pulses after [downloads] and before any delta, so a held frame with no
      assistant deltas renders the live retry line. The first [task_boards]
      value, when present, enters as the durable
      {!Mentat_protocol.Fact.Journal_task_board} fact; release subsequent
      whole-board replacements in order with {!next_task_board}. Each [notices]
      value enters as a durable {!Mentat_session.Event.Workspace_notice}
      recorded against the turn immediately after its [Turn_started], exactly as
      the engine records the observations a turn starts with; a script places
      none later in the turn. Each [tools] entry is emitted through the real
      [Tool_started]/[Tool_returned] lifecycle before the terminal assistant
      response; {!ambiguous_tool} emits [Tool_ambiguous] instead. [mutations] is
      an independent mutation-owner script whose call ids must name unique
      entries in [tools]. It is lowered through the real edit and mutation
      owners, then joined by the real protocol projection. [text] and
      [reasoning_summary] become authoritative only at {!finish_turn}. *)

  val fail :
    ?reasoning_deltas:string list ->
    ?assistant_deltas:string list ->
    ?task_boards:Mentat_session.Task.Board.t list ->
    prompt:string ->
    Mentat_llm.Error.t ->
    t
  (** [fail ~prompt error] starts and holds a provider-failed turn.
      [task_boards] has the same whole-board release contract as {!complete}. *)
end

module Decision_continuation : sig
  type t
  (** A post-decision provider continuation for one exact active turn. *)

  val tools : turn:Mentat_session.Turn.Id.t -> Turn_script.tool list -> t
  (** [tools ~turn steps] continues [turn] with the non-empty ordered tool
      lifecycle [steps] immediately after its pending decision resolves.

      Raises [Invalid_argument] if [steps] is empty. *)
end

module Login_script : sig
  type t
  (** One expected interactive login and its exact client results. *)

  val make :
    provider:Mentat_llm.Provider.t ->
    method_:Mentat_provider.Auth.Login.Id.t ->
    (Mentat_client.Login.step, Mentat_protocol.Error.t) result list ->
    t
  (** [make ~provider ~method_ steps] scripts one login command. [steps] must be
      non-empty, contain zero or more progress values followed by exactly one
      terminal [Saved]/[Cancelled]/[Error], and contain no result after
      settlement. *)
end

module Compaction_script : sig
  type t
  (** One exact manual-compaction result at the client boundary. *)

  val installed :
    reason:Mentat_session.Compaction.Reason.t ->
    request_digest:Mentat_digest.t ->
    summary_messages:Mentat_llm.Message.t list ->
    summarized_upto:int ->
    ?usage:Mentat_llm.Usage.t ->
    ?context:Mentat_session.Compaction.Context_tokens.t ->
    unit ->
    t
  (** [installed ... ()] returns [Installed] and delivers a durable compaction
      through the admitted main feed before command completion. The harness
      appends a continuation turn and the summary provider claim first, then
      constructs the compaction with that exact derived claim. All other fields
      are the values supplied here and are validated by the owner constructor.
      This preserves the session invariant that a compaction honestly closes its
      currently open summary request. *)

  val skipped : t
  (** [skipped] returns [Skipped] without delivering a compaction fact. *)

  val failed : Mentat_protocol.Error.t -> t
  (** [failed error] returns the exact structured client [error]. *)
end

module Lifecycle_script : sig
  type t
  (** One exact browser lifecycle command and its correlated client result. *)

  val rename :
    session:Mentat_session.Id.t ->
    title:string ->
    (unit, Mentat_protocol.Error.t) result ->
    t
  (** [rename ~session ~title result] expects the exact title replacement for
      [session] and returns [result]. *)

  val archive :
    session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result -> t
  (** [archive ~session result] expects the exact archive operation. *)

  val restore :
    session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result -> t
  (** [restore ~session result] expects the exact restore operation. *)

  val delete :
    session:Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result -> t
  (** [delete ~session result] expects the exact permanent delete operation. *)
end

module Child_observation : sig
  type t =
    | Live
    | Drill  (** The controlled child-feed role whose facts a test releases. *)
end

module Model_readiness : sig
  val of_providers :
    Mentat_provider.t list ->
    discoveries:Mentat_provider.Account.Discovery.t list ->
    Mentat_provider.Model_readiness.t
  (** [of_providers providers ~discoveries] constructs the provider owner's
      exact effective readiness snapshot from [providers] and [discoveries].

      Raises [Invalid_argument] under the owner constructors' duplicate-provider
      and discovery-coverage invariants. *)
end

type t
(** A live session, valid only inside the callback passed to {!run}. *)

val run :
  ?size:int * int ->
  ?env:Project.binding list ->
  ?reduced_motion:bool ->
  ?show_reasoning:bool ->
  ?overlay:Mentat_tui.Command.Overlay.t ->
  ?notify_policy:Mentat_tui.App.notify_policy ->
  ?notify:(title:string -> body:string -> unit) ->
  ?palette:Mentat_tui.Theme.Palette.t ->
  ?sessions:(Project.t -> Mentat_session.t list) ->
  ?session_diagnostics:Mentat_diagnostic.t list ->
  ?history:string ->
  ?draft:string ->
  ?session:Mentat_session.Id.t ->
  ?possibly_mutating:bool ->
  ?child_sessions:(Project.t -> Mentat_session.t list) ->
  ?drop_first_start:bool ->
  ?enumerate_files:(unit -> (Lpath.Rel.t list, Mentat_diagnostic.t) result) ->
  ?file_enumeration:bool ->
  ?local_shell:bool ->
  ?edit_in_editor:(string -> string) ->
  ?browser:bool ->
  ?image_attach:bool ->
  ?attach_responses:
    (Mentat_llm.Content.t, Mentat_protocol.Attach.Error.t) result list ->
  ?clipboard_image:string * string ->
  ?image_max_count:int ->
  ?child_observation_error:Mentat_protocol.Error.t ->
  ?providers:Mentat_provider.t list ->
  ?readiness:Mentat_provider.Account.Discovery.t list ->
  ?readiness_responses:Mentat_provider.Account.Discovery.t list list ->
  ?readiness_results:
    (Mentat_provider.Account.Discovery.t list, Mentat_protocol.Error.t) result
    list ->
  ?model_readiness_results:
    (Mentat_provider.Model_readiness.t, Mentat_protocol.Error.t) result list ->
  ?save_api_key:
    (Mentat_llm.Provider.t ->
    key:string ->
    (Mentat_provider.Account.t, Mentat_protocol.Error.t) result) ->
  ?logout:
    (Mentat_llm.Provider.t ->
    (Mentat_provider.Account.Logout.t, Mentat_protocol.Error.t) result) ->
  ?login_scripts:Login_script.t list ->
  ?model_selections:Mentat_provider.Selector.t list ->
  ?permission_reviews:Mentat_permission.Review_behavior.t list ->
  ?decision_answers:Mentat_session.Decision.Answer.t list ->
  ?decision_continuations:Decision_continuation.t list ->
  ?turns:Turn_script.t list ->
  ?compactions:Compaction_script.t list ->
  ?review:(string * string option * string option) list ->
  ?workspace_glance:Textdiff.stats option * Mentat_workspace.Health.t ->
  ?running_processes:(unit -> Mentat_protocol.Process.View.t list) ->
  ?user_commands:(Mentat_protocol.User_command.t * string) list ->
  ?lifecycle_results:Lifecycle_script.t list ->
  ?hold_lifecycle_results:bool ->
  ?screen_session_results:(unit, Mentat_protocol.Error.t) result list ->
  ?hold_screen_session_results:bool ->
  ?queue_edit_results:(unit, Mentat_protocol.Error.t) result list ->
  ?hold_queue_edit_results:bool ->
  ?session_view_results:(unit, Mentat_protocol.Error.t) result list ->
  ?hold_session_view_results:bool ->
  ?configuration_results:
    (Mentat_config.Resolved.View.t, Mentat_protocol.Error.t) result list ->
  ?hold_settings_queries:bool ->
  ?hold_decision_resolution:bool ->
  ?snapshot:(Project.t -> trusted:bool -> Mentat_tui.Snapshot.t) ->
  ?trusted:bool ->
  ?home:(Project.t -> Lpath.Abs.t option) ->
  name:string ->
  (t -> unit) ->
  unit
(** [run ~name f] starts a fresh Home UI at a pinned instant and calls [f] after
    launch. [sessions project] is the exact owner data returned by the Home,
    quick-switch, and browser session queries; constructing it from [project]
    keeps every summary and replay document anchored to the rendered workspace.
    Browser rename, archive, restore, and delete effects update these documents
    and settle their exact request before the application issues its correlated
    refresh. An active-session rename updates the same owner document, so later
    local detach and listing queries observe the renamed document.
    [lifecycle_results], when present, is the exact ordered command-and-result
    script for those effects; an [Error] leaves the owner document unchanged.
    Omitting it accepts valid lifecycle effects as successful. When
    [hold_lifecycle_results] is [true], each result remains at the fake-client
    boundary until {!finish_lifecycle_result}; a second operation reaching that
    boundary while one is held fails immediately. Browser and slash-command fork
    mint a deterministic child and follow that child through the normal
    application result path while retaining the exact parent document in
    subsequent owner listings. A local detach likewise retains its current
    document. Complete-screen goldens replace volatile started ids with
    [session-visual-00001], [session-visual-00002], and so on, and forked ids
    with [session-fork-0000001], [session-fork-0000002], and so on. These
    readable labels occupy the same 20 terminal columns as Runtime's volatile
    ids; replacement verifies and keeps that extent, so canonicalization cannot
    move later cells and disguise a layout regression. [session_diagnostics] is
    the exact report-only diagnostic tail returned by every successful
    session-list query. [screen_session_results], when present, is the exact
    ordered success/failure script for full-browser list queries; [Ok ()]
    snapshots the current owner documents at the query boundary. Omitting it
    makes those queries succeed. When [hold_screen_session_results] is [true],
    results remain at that boundary until {!finish_screen_session_result} or
    {!finish_latest_screen_session_result}; releasing the latest result first
    exposes stale-query correlation without fabricating reducer state. [history]
    is the raw persisted JSONL returned at launch. [draft], when present, seeds
    the composer through the [--draft] startup input; absence launches with an
    empty composer. [show_reasoning] is the launch-time reasoning visibility
    supplied to the real application and defaults to [true]. It controls both
    live reasoning progress and durable reasoning blocks without changing
    assistant prose. [session], when present, is the exact session resumed
    through Runtime's startup path; it must be supplied by [sessions project].
    [possibly_mutating] is the exact recovery condition returned while attaching
    that resumed session and defaults to [false]. It is never applied to a newly
    created or forked session. [child_sessions project] supplies validated
    delegated-session documents to Runtime's child-feed manager. Each live
    observation and drill-in must follow one of these exact ids from
    [`Beginning]; its projected facts remain held until {!next_child_fact} or
    {!drain_child} releases them. Duplicate ids and an observation without a
    matching document fail loudly. [drop_first_start] defaults to [false]; when
    [true], the first fake-client create request never returns and submits no
    prompt, modeling a Runtime candidate made stale by a later session-follow
    desire. [enumerate_files] services the one correlated recursive
    path-completion request when [file_enumeration] is [true]; it returns the
    fixture's root-relative regular-file list. [local_shell],
    [file_enumeration], and [browser] default to [false]; enabling one supplies
    the corresponding executable-local capability to the mounted application.
    The Matrix backend treats clipboard-copy commands as best-effort no-ops.
    [image_attach] defaults to [false]; when [true], the executable-local image
    path resolver is supplied so the application advertises image attachment and
    an image [@]-mention attaches. [attach_responses] is the exact ordered
    script the fake attach responder returns; an exhausted or omitted script
    yields a canned media block whose MIME type follows the source, and unused
    scripted responses fail when [f] returns. [clipboard_image], when present,
    is the constant [(media_type, bytes)] a clipboard image probe returns, so a
    paste attaches it. [image_max_count] is the launch-fixed images-per-input
    cap the composer pre-warns against and defaults to [20].
    [child_observation_error], when present, admits each child observation and
    delivers the scripted client-follow error through its current generation.
    [providers] supplies the exact launch-fixed declarations and [readiness] a
    repeatable live account discovery result; readiness defaults to one missing
    OpenAI account. [readiness_responses], when supplied instead, is an exact
    successful response script. [readiness_results] is the corresponding exact
    script when a query must fail. Every query consumes one result, exhaustion
    fails immediately, and unused results fail when [f] returns. These three
    readiness inputs are mutually exclusive. [model_readiness_results] is the
    independent ordered script for the provider owner's complete effective
    model-readiness query. Omission returns a structured unavailable result;
    exhaustion and unused scripted results fail immediately. When settings
    queries are held, model-readiness results join that same release boundary.
    [snapshot], when supplied, builds the exact launch snapshot from the
    deterministic test project. Otherwise the harness constructs its standard
    [dev], [openai/gpt-5.5 medium] snapshot with a positive context window and
    [danger-full-access] sandbox. [home] is the launch-fixed path spelling
    boundary for that standard snapshot; it defaults to the parent of the
    deterministic project root and never reads process [HOME]. A supplied
    [snapshot] owns its own home fact. [save_api_key] and [logout] validate the
    matching direct commands and prepare their exact results when supplied;
    tests release those held results with {!finish_save_api_key} and
    {!finish_logout}. [login_scripts] is consumed in exact command order, and
    each result advances only when {!next_login_step} is called.
    [decision_answers] is the exact sequence accepted by the fake client's
    answer command. Each answer is checked against the active session's pending
    owner decision, resolved as the local user, appended to that session, and
    returned through the real command-result and fact paths. When
    [hold_decision_resolution] is [true], that exact answer remains at the
    command boundary until {!acknowledge_decision}, {!resolve_decision}, or
    {!fail_decision} settles it; the default acknowledges and durably resolves
    it immediately. [decision_continuations] is an ordered script for
    post-resolution provider work. Each entry must name the exact active turn
    whose decision just resolved; it then emits its complete tool lifecycles
    through the real session and projected-fact paths. A turn mismatch or an
    unused continuation fails the test. [turns] is consumed in exact
    submitted-prompt order. [compactions] is consumed at the exact
    manual-compaction boundary. An [Installed] script emits its durable fact
    through the current admitted feed before returning the correlated result;
    skipped and failed scripts emit no fact. An extra, missing, or unused
    compaction fails the test. [queue_edit_results], when supplied, is consumed
    at the exact client boundary for each [Replace_queued] or [Clear_queued]
    effect. Omitting it makes those edits succeed; supplying it makes an extra
    edit, a missing edit, or an unused result fail the test. A failed result
    leaves the durable queue untouched and returns through the real correlated
    command-failure path. [hold_queue_edit_results] defaults to [false]; when
    [true], each result remains at that boundary until
    {!finish_queue_edit_result} releases it. [session_view_results], when
    supplied, is the exact ordered success or structured-failure script for
    active-session detail queries. Omitting it makes those queries succeed from
    the current owner document. When [hold_session_view_results] is [true], each
    result remains at the client boundary until {!finish_session_view_results};
    opening a surface while the first result is held therefore exercises honest
    loading without fabricating reducer state. An extra query, unused scripted
    result, or unreleased result fails loudly. [configuration_results], when
    supplied, is the corresponding exact ordered success or structured-failure
    script for effective configuration queries. Omitting it preserves the
    harness's unavailable configuration response. An extra query or unused
    result fails loudly. [model_selections] is the exact sequence of selectors
    accepted by the fake client's model setter; an extra, missing, or different
    command fails the test. [permission_reviews] is the corresponding exact
    sequence accepted by the fake client's permission-review setter. Each
    request remains held until {!finish_permission_review}; an accepted review
    becomes the sealed review of subsequent scripted turns, while a rejected
    review leaves the preceding effective value unchanged.

    Goal-screen commands likewise remain at the exact fake-client boundary.
    {!acknowledge_goal_mutation} delivers admission without changing the owner
    document; {!commit_goal_mutation} then appends the captured update to that
    document and publishes its projected journal fact. Tests may instead use
    {!fail_goal_mutation}. Model-owned declaration, blocking, completion, and
    budget transitions enter through {!update_goal}, which uses the same real
    document append and fact path. *)

val finish_settings_queries : t -> unit
(** [finish_settings_queries t] releases configuration, readiness, and session
    detail responses held after opening settings. It raises [Invalid_argument]
    when no response is held. *)

val finish_session_view_results : t -> unit
(** [finish_session_view_results t] releases every exact active-session detail
    result currently held at the fake-client boundary. It raises
    [Invalid_argument] when none is held. Call {!settle} afterwards before
    printing the loaded or structured-failure frame. *)

val finish_lifecycle_result : t -> unit
(** [finish_lifecycle_result t] releases the exact held rename, archive,
    restore, or delete result. It raises [Invalid_argument] when none is held.
*)

val finish_screen_session_result : t -> unit
(** [finish_screen_session_result t] releases the oldest held full-browser
    listing result. It raises [Invalid_argument] when none is held. *)

val finish_latest_screen_session_result : t -> unit
(** [finish_latest_screen_session_result t] releases the newest held
    full-browser listing result. It raises [Invalid_argument] when none is held.
    This is the deliberate out-of-order seam for stale-correlation visuals. *)

val fail_local_shell : t -> Mentat_diagnostic.t -> unit
(** [fail_local_shell t diagnostic] settles the current local-shell capability
    with [diagnostic]. It raises [Invalid_argument] when no run is pending. *)

val acknowledge_decision : t -> unit
(** [acknowledge_decision t] acknowledges the held answer command without
    emitting its durable resolution fact. *)

val resolve_decision : t -> unit
(** [resolve_decision t] emits the durable resolution for the held answer and
    retires the harness operation. *)

val fail_decision : t -> Mentat_protocol.Error.t -> unit
(** [fail_decision t error] rejects the held answer through its exact request.
*)

val keys : t -> string -> unit
(** [keys t bytes] feeds raw terminal bytes through Matrix's input parser. *)

val enter : t -> unit
(** [enter t] sends the terminal Enter key. *)

val paste : t -> string -> unit
(** [paste t text] sends [text] through terminal bracketed-paste framing. *)

val settle : t -> unit
(** [settle t] waits for queued terminal input, commands, messages, and
    rendering to quiesce without moving virtual time. A wake observed before the
    application leaves its preceding idle generation is crossed before
    settlement can return. *)

val fail_next_resume : t -> Mentat_protocol.Error.t -> unit
(** [fail_next_resume t error] makes the next fake-client follow request fail
    before Runtime changes the admitted session. *)

val lose_feed : t -> message:string -> unit
(** [lose_feed t ~message] makes the current fake-client feed return a terminal
    structured error. Call {!settle} afterwards. *)

val hold_feed_pull : t -> unit
(** [hold_feed_pull t] blocks the current fake-client feed after Runtime has
    entered its next pull. A later session replacement can retire that exact
    feed while the pull remains in flight; use {!lose_retired_feed} to settle
    the old pull. *)

val lose_retired_feed : t -> message:string -> unit
(** [lose_retired_feed t ~message] settles an in-flight pull from a feed that
    Runtime has since retired with a terminal structured error. It raises
    [Invalid_argument] unless {!hold_feed_pull} captured such a pull before the
    replacement. Call {!settle} afterwards. *)

val advance : t -> float -> unit
(** [advance t seconds] moves virtual time forward and settles the resulting
    timer and animation work. *)

val now : t -> float
(** [now t] is the harness virtual clock in seconds — the launch instant plus
    every {!advance}. The frame-observability primitive: read it at a chosen
    point (before feeding a key, after a settle) to stamp the virtual span the
    harness attributes to that work. In-process the clock moves only through
    {!advance} and animation cadence, so a pure render commits at the instant it
    is requested; a real wall render span is the pty harness's, not this. *)

val launch_now : t -> float
(** [launch_now t] is the virtual instant the runtime handed back its probe —
    the launch mark of the boot span (see [Runtime.run]'s [?probe]). In-process
    the clock does not advance during boot, so [now t -. launch_now t] measured
    over the first settle is zero by construction: the first frame is
    synchronous, never gated behind a timer. The boot span's wall figure is the
    pty harness's. *)

val output_bytes : t -> int
(** [output_bytes t] is the number of bytes the renderer has committed to the
    output stream so far. It grows exactly when a frame paints, so a caller
    detects a frame commit as an increase between two reads — the in-process
    counterpart of the pty harness's frame-commit stamp. *)

val resize : t -> width:int -> height:int -> unit
(** [resize t ~width ~height] changes the complete terminal allocation. *)

val screen : t -> string
(** [screen t] is the complete current terminal grid. Use only for readiness
    polling; visual expectations must call {!print}. *)

val screen_ansi : t -> string
(** [screen_ansi t] is the current frame as ANSI-styled text, keeping the
    per-cell colour that {!screen} and {!print} discard. Session ids are not
    canonicalized, so use it for frames that carry none (e.g. Home). It exists
    for theme tests that must observe a role's resolved colour in the output. *)

val print : t -> unit
(** [print t] prints every normalized terminal row with one-based numbering. *)

val cursor : t -> (int * int) option
(** [cursor t] is the terminal cursor's one-based row and column when a frame
    left it visible, and [None] when it is hidden. The cursor is a stream effect
    a real terminal displays over the grid, so it never appears in {!screen} or
    {!print} output. *)

val next_child_fact :
  ?observation:Child_observation.t -> t -> Mentat_session.Id.t -> unit
(** [next_child_fact ?observation t child] releases the next exact committed
    fact from [child]'s current scripted observation. [observation] defaults to
    {!Child_observation.Live}; pass {!Child_observation.Drill} for the read-only
    replay. The boundary wakes Runtime before awaiting an observation whose
    attach command is still in flight. Call {!settle} after release before
    printing. It raises [Invalid_argument] if no fact remains. *)

val drain_child :
  ?observation:Child_observation.t -> t -> Mentat_session.Id.t -> unit
(** [drain_child ?observation t child] releases every remaining exact committed
    fact from [child]'s current scripted observation. [observation] has the same
    default and pending-attach wake behavior as {!next_child_fact}. Call
    {!settle} after release before printing. It raises [Invalid_argument] if no
    fact remains. *)

val finish_turn : t -> unit
(** [finish_turn t] releases the current scripted provider settlement. It raises
    [Invalid_argument] when no scripted turn is held or a scripted task-board
    replacement remains unreleased. Call {!settle} afterwards before printing
    the settled frame. *)

val finish_queue_edit_result : t -> unit
(** [finish_queue_edit_result t] releases the exact result held for the active
    queued-draft replacement or clear. It raises [Invalid_argument] when no
    queued-draft edit is awaiting a result. Call {!settle} afterwards. *)

val next_task_board : t -> unit
(** [next_task_board t] commits and delivers the next scripted whole-board
    replacement through the active session journal and feed. It raises
    [Invalid_argument] when no turn is held or no replacement remains. Call
    {!settle} afterwards before printing the resulting frame. *)

val finish_model_selection : t -> (unit, Mentat_protocol.Error.t) result -> unit
(** [finish_model_selection t result] releases the currently held fake-client
    model setter. It raises [Invalid_argument] when no model selection is
    pending. Call {!settle} afterwards. *)

val finish_permission_review :
  t -> (unit, Mentat_protocol.Error.t) result -> unit
(** [finish_permission_review t result] releases the currently held fake-client
    permission-review setter. [Ok ()] updates the harness's next-turn review
    value; [Error _] preserves the prior value. It raises [Invalid_argument]
    when no review is pending. Call {!settle} afterwards. *)

val acknowledge_goal_mutation : t -> unit
(** [acknowledge_goal_mutation t] returns [Ok ()] for the exact held goal
    command without mutating its owner document. The Goal screen must therefore
    remain pending for its authoritative fact. It raises [Invalid_argument] if
    no command is pending or that command was already acknowledged. Call
    {!settle} afterwards before printing the acknowledged frame. *)

val commit_goal_mutation : t -> unit
(** [commit_goal_mutation t] appends the acknowledged command's exact goal
    update to the active session document and publishes the resulting
    [Journal_goal] fact. It raises [Invalid_argument] if no command is pending
    or admission has not first been acknowledged. Call {!settle} afterwards
    before printing the authoritative projection. *)

val fail_goal_mutation : t -> Mentat_protocol.Error.t -> unit
(** [fail_goal_mutation t error] rejects the exact held goal command without
    changing its owner document. It raises [Invalid_argument] if no command is
    pending. Call {!settle} afterwards before printing the structured error. *)

val update_goal : t -> Mentat_session.Goal.Update.t -> unit
(** [update_goal t update] appends a model- or engine-owned lifecycle [update]
    to the real active session document and publishes the corresponding
    [Journal_goal] fact. Replay validates the transition and a malformed fixture
    fails loudly. Call {!settle} afterwards before printing. *)

val next_login_step : t -> unit
(** [next_login_step t] delivers the next exact result for the active scripted
    interactive login. It raises [Invalid_argument] when no login is active.
    Call {!settle} afterwards. *)

val opened_urls : t -> Uri.t list
(** [opened_urls t] is the chronological list of exact URL values observed at
    the executable-local browser boundary. The harness retains them only for the
    lifetime of this test and never writes them to a transcript. *)

val finish_save_api_key : t -> unit
(** [finish_save_api_key t] releases the exact result prepared by the active
    scripted API-key save. It raises [Invalid_argument] unless that operation is
    active. The submitted secret is validated by the supplied [run] interpreter
    and is not retained by the harness. *)

val finish_logout : t -> unit
(** [finish_logout t] releases the exact result prepared by the active scripted
    logout. It raises [Invalid_argument] unless that operation is active. *)
