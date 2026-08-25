(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
module Session = Mentat_session
module Protocol = Mentat_protocol
module Provider = Mentat_llm.Provider
module Account = Mentat_provider.Account
module Account_phase = Account.Phase
module Discovery = Account.Discovery
module Change = Mentat_mutation.Change

type capabilities = {
  local_shell : bool;
  file_enumeration : bool;
  browser : bool;
  external_editor : bool;
  notify_command : bool;
  image_attach : bool;
}

(* Launch-fixed notification policy, resolved by the executable from the config
   [notify.*] fields and injected before the first frame. The reducer decides
   against it; the runtime only encodes and emits. The [command] channel's
   argv is not carried here — it lives in the executable's [Runtime.Local.notify]
   callback, advertised through [capabilities.notify_command]. *)
type notify_policy = {
  notify_enabled : bool;
  notify_channel : Mentat_config.Notify.Channel.t;
  notify_focus : Mentat_config.Notify.When.t;
  notify_on : Mentat_config.Notify.Event.t list;
}

type request = int64

let equal_request = Int64.equal

type image_source = Attach_path of Lpath.Rel.t | Attach_clipboard

type command =
  | Quit
  | Attach_image of { request : request; source : image_source }
  | Start_session of {
      request : request;
      prompt : string;
      media : Mentat_llm.Content.t list;
      mode : Session.Contract.Mode.t;
      history : Draft.History_entry.t option;
      model :
        (Mentat_provider.Selector.t
        * Mentat_llm.Request.Options.Reasoning_effort.t option)
        option;
    }
  | Prompt of {
      request : request;
      session : Session.Id.t;
      prompt : string;
      media : Mentat_llm.Content.t list;
      mode : Session.Contract.Mode.t;
    }
  | Queue_next of {
      request : request;
      session : Session.Id.t;
      prompt : string;
      media : Mentat_llm.Content.t list;
    }
  | Replace_queued of {
      request : request;
      session : Session.Id.t;
      inputs : Mentat_llm.Content.t list list;
    }
  | Clear_queued of { request : request; session : Session.Id.t }
  | Interrupt of { session : Session.Id.t }
  | Detach_session
  | Resume_session of { request : request; session : Session.Id.t }
  | Fork_session of { request : request; session : Session.Id.t }
  | Rewind_session of {
      request : request;
      source : Session.Id.t;
      anchor : Session.Anchor.t;
      prompt : string;
      media : Mentat_llm.Content.t list;
      mode : Session.Contract.Mode.t;
      history : Draft.History_entry.t option;
    }
  | Compact_session of { request : request; session : Session.Id.t }
  | Undo_step of {
      request : request;
      session : Session.Id.t;
      op : [ `Undo | `Redo | `Cancel ];
    }
  | Rename_session of {
      request : request;
      session : Session.Id.t;
      title : string;
    }
  | Archive_session of { request : request; session : Session.Id.t }
  | Restore_session of { request : request; session : Session.Id.t }
  | Delete_session of { request : request; session : Session.Id.t }
  | Load_home_sessions of request
  | Load_quick_sessions of request
  | Load_screen_sessions of request
  | Load_session_view of { request : request; session : Session.Id.t }
  | Load_pending_decision of { request : request; session : Session.Id.t }
  | Load_configuration of request
  | Load_account_readiness of request
  | Load_model_readiness of { request : request; refresh : bool }
  | Load_review_state of { request : request; scope : Mentat_review.Scope.t }
  | Load_review_diff of { request : request; path : Lpath.Rel.t }
  | Load_review_crs of request
  | Load_workspace_glance of request
  | Load_workspace_dune of request
  | Dune_control of { request : request; op : [ `Restart | `Stop ] }
  | Load_running_processes of { request : request; session : Session.Id.t }
  | Submit_review_command of {
      request : request;
      command : Mentat_review.Command.t;
    }
  | Submit_review_compose of {
      request : request;
      edit : Mentat_review.Cr.Edit.t;
    }
  | Answer_decision of {
      request : request;
      session : Session.Id.t;
      decision : Session.Decision.Id.t;
      answer : Session.Decision.Answer.t;
    }
  | Set_model of {
      request : request;
      session : Session.Id.t;
      selector : Mentat_provider.Selector.t;
      reasoning_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
    }
  | Set_permission_review of {
      request : Settings_screen.mutation;
      session : Session.Id.t;
      review : Mentat_permission.Review_behavior.t;
    }
  | Persist_ui_theme of { request : request; name : string }
  | Auth_save_api_key of {
      attempt : Auth_panel.attempt;
      provider : Provider.t;
      key : string;
    }
  | Auth_begin_login of {
      attempt : Auth_panel.attempt;
      provider : Provider.t;
      method_ : Mentat_provider.Auth.Login.Id.t;
    }
  | Auth_logout of { attempt : Auth_panel.attempt; provider : Provider.t }
  | Auth_cancel of Auth_panel.attempt
  | Load_prompt_history of request
  | Load_user_commands of request
  | Expand_command of {
      request : request;
      name : string;
      arguments : string;
      entry : Draft.History_entry.t;
    }
  | Append_prompt_history of {
      session : Session.Id.t option;
      entry : Draft.History_entry.t;
    }
  | Enumerate_files of request
  | Run_local_shell of { request : request; command : string }
  | Cancel_local_shell of request
  | Edit_in_editor of { request : request; text : string }
  | Notify of {
      channels : [ `Bell | `Osc9 | `Osc777 | `Command ] list;
      title : string;
      body : string;
    }
  | Copy_text of string
  | Copy_selection
  | Query_color_scheme
  | Open_url of { attempt : Auth_panel.attempt; url : Uri.t }
  | Observe_child of { request : request; child : Session.Id.t }
  | Drill_child of { request : request; child : Session.Id.t }
  | Close_child_drill of {
      child : Session.Id.t;
      generation : Child_feeds.Generation.t;
    }
  | Close_child_pane

type turn_origin = {
  origin_turn : Session.Turn.Id.t;
  origin_text : string;
      (* The user-submitted text that began this turn, joined from its content's
         text parts. Committed content is already paste/mention-expanded, so this
         is the honest plain-text round-trip a re-edit starts from. *)
  origin_prefix : int;
      (* The transcript block count just before this turn's blocks, so a rewind
         to this turn splits the folded document at the kept/dropped boundary. *)
  origin_index : int;
      (* This turn's zero-based position among all turns of every origin, so a
         rewind's discarded count spans the internal turns between it and the
         tail, not only the later user turns. *)
  origin_at : float;
      (* The fold-time clock when the turn started, for the picker's relative
         age. On replay this reads as the replay instant. *)
}
(* A per-session index of each user turn's origin, keyed by turn id. It is
   general chat-projection state, not rewind-private: the collapsed custom-command
   invocation rendering will consume the same association. Rewind reads it to
   list prior user turns and to seed the composer from a chosen one. *)

type chat = {
  chat_document : Transcript.t;
  chat_turn : Turn.t;
  task_board : Session.Task.Board.t option;
      (* The latest durable board with content. Unlike [chat_turn]'s per-turn
         projection, this survives settlement, interruption, and completion.
         Only a whole-board replacement with no items clears the live tenant. *)
  turn_origins : turn_origin list;
      (* Every user turn folded into this conversation, newest first. *)
  turn_count : int;
      (* The total number of turns of every origin folded into this
         conversation, so a rewind can count the internal turns it discards. *)
  expanded : bool;
  spinner : int;
  next_page : int;
  page : (int * [ `Up | `Down ]) option;
  tail_reset : request option;
}

type phase = Prelude | Chat of chat
type model_return = To_chat | To_settings of Settings_screen.t
type model_panel = { state : Model_panel.t; return : model_return }

type theme_panel = {
  theme_picker : Theme_panel.t;
  theme_saved : Theme.Palette.t;
      (* The palette in effect when the picker opened, restored verbatim on
         cancel so a preview never sticks after an escape. *)
}

type theme_auto = {
  auto_dark : Theme.Palette.t;
  auto_light : Theme.Palette.t;
  auto_armed : bool;
      (* Under [tui.theme = "auto"] the palette follows the terminal's reported
         colour scheme. A hand pick in the /theme panel — any preview or commit —
         disarms following for the session, so a late or unsolicited reply can
         never clobber the deliberate choice. *)
}

type panel =
  | Session_switch of Sessions_panel.t
  | Model of model_panel
  | Theme of theme_panel
  | Dialog of Dialog.t
  | Auth of Auth_panel.t

type screen =
  | Sessions of Sessions_screen.t
  | Settings of Settings_screen.t
  | Review of Review_screen.t

type surface = Conversing | Panel of panel | Screen of screen

type completion =
  | No_completion
  | Commands of Palette.t
  | Mention of Mention.t
  | History_search of {
      search : History.Search.t;
      saved : Draft.History_entry.t;
    }

type armed = Quit_armed | Clear_armed | Interrupt_armed

type armed_rewind = {
  rewind_anchor : Session.Turn.Id.t;
      (* The target user turn; a [Before] rewind drops it and everything later. *)
  rewind_prefix : int;
      (* The kept/dropped block boundary in the folded transcript, so the preview
         dims exactly the discarded tail. *)
  rewind_dropped : int;
      (* The count of user turns at or after the anchor, for the commit hint. *)
  rewind_restored : Draft.History_entry.t;
      (* The composer draft the arming replaced, restored verbatim on cancel. *)
}

(* The rewind flow is a single App-owned draft/selection phase: the
   picker chooses a prior user turn, then arming seeds the composer and previews
   the discarded tail until the user commits or cancels. *)
type rewind_flow = Picking of Rewind_panel.t | Armed of armed_rewind

(* The armed-undo ephemeral state, driven by the projected [Fact.Undo]: the
   durable boundary drives the transcript seam and model-view exclusion; this
   only carries what a resume cannot reconstruct — the composer draft the first
   undo replaced, restored verbatim on cancel or redo-to-empty. [undo_anchor] is
   the boundary the app has already re-seeded the composer for, so a repeated
   fact for the same anchor does not re-seed. *)
type armed_undo = {
  undo_anchor : Session.Turn.Id.t;
  undo_restored : Draft.History_entry.t;
}

type pending_kind =
  | Start
  | Submission
  | Resume
  | Fork of { parent : Session.Id.t }
  | Rewind of { source : Session.Id.t; draft : Draft.History_entry.t }
    (* A rewind-into-child follow, reserved exactly like [Fork]; its admission
         records the rewind seam naming the child and its source. [draft] is the
         edited message the commit stashed, restored to the composer if the
         rewind or its follow fails before admission so the edit is never lost. *)
  | Compact of { started : float }
    (* [started] is the composer-time clock the compacting status row counts
         from. A manual compaction is transparent on the feed, so the app owns
         its in-flight presentation from this pending rather than a turn. *)
  | Rename
  | Archive
  | Restore
  | Delete
  | Answer of Session.Decision.Id.t
  | Model_selection of {
      session : Session.Id.t;
      model : string;
      effort : string option;
    }
  | Queue_edit of {
      optimistic : Draft.History_entry.t;
      rollback : Draft.History_entry.t;
    }
  | Local_shell
  | Editor

type pending = { pending_token : request; pending_kind : pending_kind }

type child_projection = {
  child_document : Transcript.t;
  child_turn : Turn.t;
  child_outcome : Session.Turn.Outcome.t option;
  child_board : Session.Task.Board.t option;
      (* The child's latest durable task board, tracked exactly like a top-level
         chat so the drill pane renders the drilled child's tasks. *)
}

type child_entry = {
  edge : Session.Delegation.t;
  child_depth : int;
      (* The nesting depth in the delegation tree: [0] for a direct child of the
         active session, one more than the parent's depth for a child delegated
         by another observed child. The switcher indents rows by this depth. *)
  child_pending : request option;
  child_generation : Child_feeds.Generation.t option;
  child_projection : child_projection;
  child_closed : bool;
  child_error : Protocol.Error.t option;
}

type drill = {
  drill_edge : Session.Delegation.t;
  drill_request : request option;
  drill_generation : Child_feeds.Generation.t option;
  drill_projection : child_projection;
  drill_error : Protocol.Error.t option;
  drill_composer : Composer.t;
  drill_prompt : request option;
  drill_focus : int option;
      (* The switcher selection while this drill is open. It is the drill's own
         state, independent of the parent view's [strip_focus], so entering a
         drill always opens on an unfocused glance and a sibling switch never
         inherits a stale parent selection. *)
}

let drill_child drill = Session.Delegation.child drill.drill_edge

type t = {
  current_snapshot : Snapshot.t;
  provider_declarations : Mentat_provider.t list;
  effect_capabilities : capabilities;
  current_review : Mentat_permission.Review_behavior.t;
  draft_mode : Session.Contract.Mode.t;
  staged_model :
    (Mentat_provider.Selector.t
    * Mentat_llm.Request.Options.Reasoning_effort.t option)
    option;
      (* A picker selection made while no session is active — sessions are
         minted lazily by the first prompt, so there is nothing to bind yet. The
         model line adopts it immediately; it rides the next [Start_session],
         which applies it before the first submit, and entering an existing
         session discards it. *)
  active_session : Session.Id.t option;
  main_feed : (Session.Id.t * request) option;
  observation_lost : bool;
  session_view : Session.Session_view.t option;
  session_view_request : (request * Session.Id.t) option;
  pending_decision_request : (request * Session.Id.t) option;
  possibly_mutating : bool;
  all_accounts_missing : bool;
  account_readiness_request : request option;
  model_readiness_request : request option;
  configuration_request : request option;
  recents : Home.Recents.t;
  recents_request : request option;
  quick_sessions_request : request option;
  screen_sessions_request : request option;
  composer : Composer.t;
  history : History.Entry.t list;
  history_request : request option;
  user_commands : Protocol.User_command.t list;
      (* The custom-command catalog snapshot for the slash palette, loaded
         through the client once at TUI startup. Empty until that load returns.
         v1 has no file-watching and no reload: a command file added after
         startup is not seen this session (refresh-on-activation is a
         follow-up). *)
  user_commands_request : request option;
  help : bool;
  motion : Home.Motion.t;
  frame_accum : float;
  flash : string option;
  now : float;
  phase : phase;
  surface : surface;
  completion : completion;
  queue : Session.Queue.Entry.t list;
  changes : Change.t list;
  last_usage : Mentat_llm.Usage.t option;
      (* The most recent whole-response provider usage on the active feed. Its
         lane sum is the context-occupancy proxy the pane shows against the
         model's window — distinct from the cumulative session metrics. *)
  glance : Textdiff.stats option option;
      (* The last worktree observation: the git diff summary against the
         review base ([None] inside for a non-repository). Polled at session
         start and each turn settle and held as a last observation, never
         persisted derived state — the workspace owns the fact. Outer [None]
         until the first poll returns. *)
  glance_request : request option;
  dune_status : Mentat_workspace.Health.t option;
      (* The freshest watch-status observation — the dune query at the event
         moments, the tick, and the /dune verbs all write it; the side pane's
         dune row reads this alone. *)
  dune_request : request option;
  running : Mentat_protocol.Process.View.t list;
      (* The active session's live background processes (the [shell] tool's
         [background:true] children), projected on demand from the driver's
         registry at session activation and each turn settle. Held as a last
         observation, never persisted derived state; empty until the first poll
         returns and reset on every session switch so it never shows a prior
         session's processes. *)
  running_request : (request * Session.Id.t) option;
  children : child_entry list;
  strip_focus : int option;
  strip_hover : int option;
  drill : drill option;
  pending : pending list;
  enumeration_request : request option;
  attach_requests : (request * image_source) list;
      (* In-flight image-attach correlation tokens paired with their source. An
         [attached] completion is folded only while its request is still pending;
         a stale one is inert. A clipboard probe that finds no image is silent,
         so its source is remembered to distinguish it from a path attach. *)
  image_max_count : int;
      (* Launch-fixed cap on attached images per input, resolved from
         [image.max_count]. The composer pre-warns before exceeding it; the
         engine is the enforcing gate at prompt admission. *)
  next_request : int64;
  next_attempt : int;
  armed : armed option;
  rewind : rewind_flow option;
      (* The active rewind picker or armed-rewind draft state, mutually exclusive
         with an ordinary Conversing composer. [None] outside the flow. *)
  undo_armed : armed_undo option;
      (* The armed-undo composer bookkeeping, driven by [Fact.Undo]. [None] when
         no boundary is armed. *)
  show_reasoning : bool;
  overlay : Command.Overlay.t;
      (* Launch-fixed keybinding overlay, resolved by the executable from the
         user's keybindings file over the registry defaults. The registry rows
         and their scopes decide what is remappable; this only carries the
         overrides. *)
  pending_chord : Command.t option;
      (* The armed first press of a two-press chord (e.g. Ctrl+X of the editor
         chord) awaiting completion by the next key. [None] outside a chord. *)
  command_palette : bool;
      (* Whether the open [Commands] completion is the command palette (opened by
         Ctrl+G / Ctrl+P over the registry) rather than the slash palette (opened
         by [/]). Read only while [completion] is [Commands]. *)
  notify_policy : notify_policy;
      (* Launch-fixed notification policy the reducer decides against. *)
  palette : Theme.Palette.t;
      (* The active color palette, seeded from the theme the executable resolved
         and hot-swappable at runtime. Every widget view reads its colors from
         this rather than the module-level Theme constants, so a user theme —
         and a /theme switch — recolors the whole TUI in one field update. *)
  theme_name : string;
      (* The name of the active theme ([tui.theme]'s resolved value), for the
         /theme picker's preselection and its persisted commit. *)
  themes : Theme.Preset.t list;
      (* The theme catalog the executable resolved once at launch: the built-in
         presets merged with the user's theme files. The /theme picker previews
         and commits from this snapshot; a new user file appears next launch. *)
  theme_auto : theme_auto option;
      (* [Some] only under [tui.theme = "auto"]: the resolved dark/light members
         to swap between as the terminal reports its colour scheme, with the
         disarm latch. [None] pins the palette to the launch theme. *)
  terminal_focused : bool;
      (* Terminal focus, tracked from [Sub.on_focus]/[on_blur]. A terminal that
         never reports focus leaves this [false], so [Unfocused] policy fires —
         the notify-always fallback, never a silent drop. *)
  review_request : request option;
      (* The current review-query generation. A completion is folded into the
         open review screen only while its request matches; a user action mints
         a fresh generation, a completion-driven follow-up reuses it. *)
  cols : int;
  rows : int;
      (* The last known terminal grid size, tracked from [Mosaic.Sub.on_resize].
         The review screen's two-pane split and windowing need pixel extents;
         every other surface sizes itself with flex and ignores these. *)
}

type msg =
  | Composer_msg of Composer.msg
  | Palette_msg of Palette.msg
  | Mention_msg of Mention.msg
  | History_search_msg of History.Search.msg
  | Frame_tick of float
  | Clock_tick
  | Resized of { cols : int; rows : int }
  | Turn_tick
  | Flash_expired
  | Armed_expired
  | Ctrl_c
  | Escape
  | Toggle_expanded
  | Begin_history_search
  | Shift_tab
  | Transcript_paged of [ `Up | `Down ]
  | Arm_chord of Command.t
  | Disarm_chord
  | Run_command of Command.t
  | Open_command_palette
  | Edit_in_editor_requested
  | Terminal_focus of bool
  | Color_scheme of [ `Dark | `Light ]
  | Transcript_page_applied of int
  | Transcript_tail_reset_applied of request
  | Fact of {
      session : Session.Id.t;
      request : request;
      now : float;
      fact : Protocol.Fact.t;
    }
  | Progress of {
      session : Session.Id.t;
      request : request;
      now : float;
      progress : Protocol.Progress.t;
    }
  | Feed_failed of {
      session : Session.Id.t;
      request : request;
      message : string;
      login_needed : bool;
    }
  | Operation_failed of { message : string; login_needed : bool }
  | Session_followed of {
      request : request;
      session : Session.Id.t;
      possibly_mutating : bool;
    }
  | Command_succeeded of request
  | Command_failed of request * Protocol.Error.t
  | Compaction_finished of
      request * (Mentat_client.compaction_result, Protocol.Error.t) result
  | Settings_mutation_finished of
      Settings_screen.mutation * (unit, Protocol.Error.t) result
  | Capability_failed of request * Mentat_diagnostic.t
  | Attached of request * (Mentat_llm.Content.t, Protocol.Attach.Error.t) result
  | Home_sessions_loaded of
      request
      * ( Session.Summary.t list * Mentat_diagnostic.t list,
          Protocol.Error.t )
        result
  | Quick_sessions_loaded of
      request
      * ( Session.Summary.t list * Mentat_diagnostic.t list,
          Protocol.Error.t )
        result
  | Screen_sessions_loaded of
      request
      * ( Session.Summary.t list * Mentat_diagnostic.t list,
          Protocol.Error.t )
        result
  | Session_view_loaded of {
      request : request;
      session : Session.Id.t;
      result : (Session.Session_view.t, Protocol.Error.t) result;
    }
  | Pending_decision_loaded of {
      request : request;
      session : Session.Id.t;
      result : (Session.Decision.Requested.t option, Protocol.Error.t) result;
    }
  | Configuration_loaded of
      request * (Mentat_config.Resolved.View.t, Protocol.Error.t) result
  | Account_readiness_loaded of
      request * (Discovery.t list, Protocol.Error.t) result
  | Model_readiness_loaded of
      request * (Mentat_provider.Model_readiness.t, Protocol.Error.t) result
  | Review_state_loaded of
      request * (Mentat_review.View.t, Protocol.Error.t) result
  | Review_diff_loaded of {
      request : request;
      path : Lpath.Rel.t;
      result : (Mentat_review.File_diff.t option, Protocol.Error.t) result;
    }
  | Review_crs_loaded of
      request * (Mentat_review.Cr.View.t list, Protocol.Error.t) result
  | Workspace_glance_loaded of
      request * (Textdiff.stats option, Protocol.Error.t) result
  | Workspace_dune_loaded of
      request * (Mentat_workspace.Health.t, Protocol.Error.t) result
  | Workspace_dune_tick
  | Running_processes_loaded of {
      request : request;
      session : Session.Id.t;
      result : (Mentat_protocol.Process.View.t list, Protocol.Error.t) result;
    }
  | Review_command_finished of request * (unit, Protocol.Error.t) result
  | Review_compose_finished of request * (unit, Protocol.Error.t) result
  | Review_screen_msg of Review_screen.msg
  | Sessions_panel_msg of Sessions_panel.msg
  | Rewind_panel_msg of Rewind_panel.msg
  | Sessions_screen_msg of Sessions_screen.msg
  | Settings_screen_msg of Settings_screen.msg
  | Settings_paste of string
  | Model_panel_msg of Model_panel.msg
  | Threads_strip_msg of Threads_strip.msg
  | Model_paste of string
  | Theme_panel_msg of Theme_panel.msg
  | Theme_paste of string
  | Ui_theme_persisted of
      request * ((string * string) option, Protocol.Error.t) result
  | Dialog_msg of Dialog.msg
  | Dialog_key of Matrix.Input.Key.event
  | Auth_panel_msg of Auth_panel.msg
  | Auth_paste of string
  | Auth_login_step of Auth_panel.attempt * Mentat_client.Login.step
  | Auth_login_failed of Auth_panel.attempt * Protocol.Error.t
  | Auth_save_api_key_finished of
      Auth_panel.attempt * (Account.t, Protocol.Error.t) result
  | Auth_logout_finished of
      Auth_panel.attempt * (Account.Logout.t, Protocol.Error.t) result
  | Auth_url_opened of Auth_panel.attempt
  | Auth_url_open_failed of Auth_panel.attempt * string
  | Prompt_history_loaded of request * History.loaded
  | User_commands_loaded of
      request * (Protocol.User_command.t list, Protocol.Error.t) result
  | Command_expanded of {
      request : request;
      entry : Draft.History_entry.t;
      result : (Mentat_llm.Content.t list, Protocol.Error.t) result;
    }
  | Files_loaded of {
      request : request;
      result : (Lpath.Rel.t list, Mentat_diagnostic.t) result;
    }
  | Local_shell_finished of request * (Tool_block.t, Mentat_diagnostic.t) result
  | Editor_finished of request * (string, Mentat_diagnostic.t) result
  | Child_observation_started of {
      request : request;
      observation : Child_feeds.observation;
      child : Session.Id.t;
      generation : Child_feeds.Generation.t;
    }
  | Child_feed of {
      observation : Child_feeds.observation;
      generation : Child_feeds.Generation.t;
      child : Session.Id.t;
      outcome : (Mentat_client.Feed.outcome, Protocol.Error.t) result;
    }
  | Open_latest_change

let fact ~session ~request ~now fact = Fact { session; request; now; fact }

let progress ~session ~request ~now progress =
  Progress { session; request; now; progress }

let feed_failed ~session ~request ~message ~login_needed =
  Feed_failed { session; request; message; login_needed }

let operation_failed ~message ~login_needed =
  Operation_failed { message; login_needed }

let session_followed ~request ~session ~possibly_mutating =
  Session_followed { request; session; possibly_mutating }

let command_succeeded ~request = Command_succeeded request
let command_failed ~request error = Command_failed (request, error)
let compaction_finished ~request result = Compaction_finished (request, result)
let ui_theme_persisted ~request result = Ui_theme_persisted (request, result)

let settings_mutation_finished ~request result =
  Settings_mutation_finished (request, result)

let capability_failed ~request diagnostic =
  Capability_failed (request, diagnostic)

let attached ~request result = Attached (request, result)
let home_sessions_loaded ~request result = Home_sessions_loaded (request, result)

let quick_sessions_loaded ~request result =
  Quick_sessions_loaded (request, result)

let screen_sessions_loaded ~request result =
  Screen_sessions_loaded (request, result)

let session_view_loaded ~request ~session result =
  Session_view_loaded { request; session; result }

let running_processes_loaded ~request ~session result =
  Running_processes_loaded { request; session; result }

let pending_decision_loaded ~request ~session result =
  Pending_decision_loaded { request; session; result }

let configuration_loaded ~request result = Configuration_loaded (request, result)

let account_readiness_loaded ~request result =
  Account_readiness_loaded (request, result)

let model_readiness_loaded ~request result =
  Model_readiness_loaded (request, result)

let review_state_loaded ~request result = Review_state_loaded (request, result)

let review_diff_loaded ~request ~path result =
  Review_diff_loaded { request; path; result }

let review_crs_loaded ~request result = Review_crs_loaded (request, result)

let workspace_glance_loaded ~request result =
  Workspace_glance_loaded (request, result)

let workspace_dune_loaded ~request result =
  Workspace_dune_loaded (request, result)

let review_command_finished ~request result =
  Review_command_finished (request, result)

let review_compose_finished ~request result =
  Review_compose_finished (request, result)

let auth_login_step ~attempt step = Auth_login_step (attempt, step)
let auth_login_failed ~attempt error = Auth_login_failed (attempt, error)

let auth_save_api_key_finished ~attempt result =
  Auth_save_api_key_finished (attempt, result)

let auth_logout_finished ~attempt result = Auth_logout_finished (attempt, result)
let auth_url_opened ~attempt = Auth_url_opened attempt

let auth_url_open_failed ~attempt ~message =
  Auth_url_open_failed (attempt, message)

let prompt_history_loaded ~request contents =
  Prompt_history_loaded (request, History.load contents)

let user_commands_loaded ~request result = User_commands_loaded (request, result)

let command_expanded ~request ~entry result =
  Command_expanded { request; entry; result }

let files_loaded ~request result = Files_loaded { request; result }
let local_shell_finished ~request result = Local_shell_finished (request, result)
let editor_finished ~request result = Editor_finished (request, result)

let child_observation_started ~request ~observation ~child ~generation =
  Child_observation_started { request; observation; child; generation }

let child_feed ~observation ~generation ~child outcome =
  Child_feed { observation; generation; child; outcome }

let validate_now fn now =
  if (not (Float.is_finite now)) || now < 0. then
    invalid_arg ("App." ^ fn ^ ": now must be finite and nonnegative")

let error_text error =
  Protocol.Error.diagnostic error |> Mentat_diagnostic.to_string

let diagnostic_text = Mentat_diagnostic.to_string

let content_text content =
  List.filter_map
    (function
      | Mentat_llm.Content.Text text -> Some text
      | Mentat_llm.Content.Media { media_type; source } ->
          let location =
            match source with
            | `Uri _ -> "URI"
            | `Base64 _ -> "inline"
            | `Ref _ -> "attachment"
          in
          Some ("[media: " ^ media_type ^ " · " ^ location ^ "]"))
    content
  |> String.concat " "

let empty_chat ?(banner = true) ?tail_reset snapshot : chat =
  let transcript =
    if banner then
      Transcript.append Transcript.empty (Transcript.banner snapshot)
    else Transcript.empty
  in
  {
    chat_document = transcript;
    chat_turn = Turn.idle;
    task_board = None;
    turn_origins = [];
    turn_count = 0;
    expanded = false;
    spinner = 0;
    next_page = 0;
    page = None;
    tail_reset;
  }

let empty_child snapshot : child_projection =
  {
    child_document = (empty_chat ~banner:false snapshot).chat_document;
    child_turn = Turn.idle;
    child_outcome = None;
    child_board = None;
  }

let completion_open (t : t) =
  match t.completion with
  | No_completion -> false
  | Commands _ | Mention _ | History_search _ -> true

(* The command palette (opened by Ctrl+G / Ctrl+P over the registry) reuses the
   slash palette's completion widget, distinguished by this flag so rendering,
   Tab, and activation route through their command-palette variants. *)
let command_palette_open (t : t) =
  t.command_palette && match t.completion with Commands _ -> true | _ -> false

let same_request = equal_request

(* Fold a correlated load only while the request that carried it is the one
   still in flight; a stale or absent request folds to no change. The body
   clears its own request field. *)
let guard_request held request t body =
  match held with
  | Some current when same_request current request -> body t
  | None | Some _ -> (t, [])

(* The session-pinned variant: fold only while the request is current and its
   pinned session still matches, so a stale poll from a since-switched session
   is dropped. *)
let guard_request_session held request ~session t body =
  match held with
  | Some (current, expected)
    when same_request current request && Session.Id.equal expected session ->
      body t
  | None | Some _ -> (t, [])

let fresh_request (t : t) =
  if Int64.equal t.next_request Int64.max_int then
    invalid_arg "App: transient request space exhausted";
  (t.next_request, { t with next_request = Int64.succ t.next_request })

let fresh_attempt (t : t) =
  if Int.equal t.next_attempt max_int then
    invalid_arg "App: authentication attempt space exhausted";
  let attempt = Auth_panel.attempt t.next_attempt in
  (attempt, { t with next_attempt = t.next_attempt + 1 })

(* Review screen.

   The review surface is workspace-scoped, not session-scoped. It renders the
   review waist's values and expresses every change as a {!Review_screen.command}
   the runtime runs through the client. A single review-query generation
   ([t.review_request]) correlates completions: a user action mints a fresh
   generation, a completion-driven follow-up reuses it, so a completion from a
   superseded action is dropped. *)

let review_error error =
  Mentat_diagnostic.to_string (Protocol.Error.diagnostic error)

let review_effect ~request = function
  | Review_screen.Query_state scope -> Load_review_state { request; scope }
  | Review_screen.Query_diff path -> Load_review_diff { request; path }
  | Review_screen.Query_crs -> Load_review_crs request
  | Review_screen.Apply command -> Submit_review_command { request; command }
  | Review_screen.Compose edit -> Submit_review_compose { request; edit }

let apply_review_event ~request t screen (event : Review_screen.event) =
  match event with
  | Review_screen.Stay commands ->
      ( { t with surface = Screen (Review screen) },
        List.map (review_effect ~request) commands )
  | Review_screen.Close commands ->
      ( { t with surface = Conversing; review_request = None },
        List.map (review_effect ~request) commands )

let open_review ?focus t =
  let screen, commands = Review_screen.create ?focus () in
  let request, t = fresh_request t in
  ( { t with surface = Screen (Review screen); review_request = Some request },
    List.map (review_effect ~request) commands )

(* A user action mints a fresh generation. *)
let update_review_screen message screen t =
  let screen, event = Review_screen.update message screen in
  let request, t = fresh_request t in
  apply_review_event ~request
    { t with review_request = Some request }
    screen event

(* A completion reuses the generation it was issued under, and is dropped unless
   it is the current one over an open review. *)
let fold_review_completion ~request msg t =
  match (t.surface, t.review_request) with
  | Screen (Review screen), Some current when same_request current request ->
      let screen, event = Review_screen.update msg screen in
      apply_review_event ~request:current t screen event
  | (Conversing | Panel _ | Screen _), _ -> (t, [])

let add_pending request kind (t : t) =
  {
    t with
    pending =
      ({ pending_token = request; pending_kind = kind } : pending) :: t.pending;
  }

let take_pending request (t : t) =
  let found =
    List.find_opt
      (fun (pending : pending) -> same_request pending.pending_token request)
      t.pending
  in
  let pending =
    List.filter
      (fun (pending : pending) ->
        not (same_request pending.pending_token request))
      t.pending
  in
  (found, { t with pending })

let pending_request request (t : t) =
  List.exists
    (fun (pending : pending) -> same_request pending.pending_token request)
    t.pending

let model_selection_pending (t : t) =
  List.exists
    (function { pending_kind = Model_selection _; _ } -> true | _ -> false)
    t.pending

let answer_pending decision (t : t) =
  List.exists
    (function
      | { pending_kind = Answer candidate; _ } ->
          Session.Decision.Id.equal candidate decision
      | _ -> false)
    t.pending

let local_shell_request (t : t) =
  List.find_map
    (function
      | { pending_token; pending_kind = Local_shell } -> Some pending_token
      | _ -> None)
    t.pending

let editor_request (t : t) =
  List.find_map
    (function
      | { pending_token; pending_kind = Editor } -> Some pending_token
      | _ -> None)
    t.pending

let retire_chat_pending (t : t) =
  {
    t with
    pending =
      List.filter
        (function
          | {
              pending_kind =
                Start | Submission | Answer _ | Queue_edit _ | Local_shell;
              _;
            } ->
              false
          | _ -> true)
        t.pending;
  }

(* A drill and the main view never render their composers at once (see [view]):
   at most one is on screen, so the completion, prompt-history, and mention
   machinery folds through whichever composer is active. [active_composer]
   selects it and [set_active_composer] writes it back, so one code path drives
   both surfaces. *)
let active_composer (t : t) =
  match t.drill with Some drill -> drill.drill_composer | None -> t.composer

let set_active_composer composer (t : t) =
  match t.drill with
  | Some drill ->
      { t with drill = Some { drill with drill_composer = composer } }
  | None -> { t with composer }

(* Typing into either composer drops the switcher's keyboard focus, returning the
   arrows to prompt-history recall. The drill keeps its own [drill_focus], so the
   cleared field follows the active surface. *)
let clear_active_strip_focus (t : t) =
  match t.drill with
  | Some drill -> { t with drill = Some { drill with drill_focus = None } }
  | None -> { t with strip_focus = None }

let restore_draft entry (t : t) =
  let composer, _ =
    Composer.update (Composer.Restore_history entry) (active_composer t)
  in
  set_active_composer composer t

let set_draft text (t : t) =
  Draft.of_text text |> Draft.history_entry |> fun entry ->
  restore_draft entry t

let clear_composer (t : t) = set_draft "" t

(* The catalog row for [selector], resolved against the launch-fixed declarations
   exactly as the executable seeds them at startup. It owns the provider metadata
   the pane needs — the context-window denominator and the pricing behind the
   spend row — so a selector with no row (an unloaded provider) withholds both
   rather than guessing. *)
let model_catalog t selector =
  match
    Mentat_provider.Catalog.find
      (Mentat_provider.Catalog.make t.provider_declarations)
      selector
  with
  | Ok model -> Some model
  | Error _ -> None

let model_context_window t selector =
  Option.bind (model_catalog t selector) Mentat_provider.Model.context_window

let model_snapshot t turn (snapshot : Snapshot.t) =
  let contract = Session.Turn.contract turn in
  let model = Session.Contract.model contract in
  let context_window =
    model_context_window t (Mentat_provider.Selector.of_model model)
  in
  let provider = Mentat_llm.Model.provider model |> Provider.id in
  let model = provider ^ "/" ^ Mentat_llm.Model.id model in
  let effort =
    Session.Contract.options contract
    |> Mentat_llm.Request.Options.reasoning_effort
    |> Option.map Mentat_llm.Request.Options.Reasoning_effort.to_string
  in
  Snapshot.with_model ~model ~effort ?context_window snapshot

let initial_model ~now ~(startup : Startup.t) ~capabilities ~reduced_motion
    ~show_reasoning ~overlay ~notify_policy ~palette ~theme_name ~themes
    ~theme_auto ~image_max_count =
  {
    current_snapshot = Startup.snapshot startup;
    provider_declarations = Startup.providers startup;
    effect_capabilities = capabilities;
    current_review = Startup.permission_review startup;
    draft_mode = Startup.mode startup;
    staged_model = None;
    active_session = None;
    main_feed = None;
    observation_lost = false;
    session_view = None;
    session_view_request = None;
    pending_decision_request = None;
    possibly_mutating = false;
    all_accounts_missing = false;
    account_readiness_request = None;
    model_readiness_request = None;
    configuration_request = None;
    recents = Home.Recents.loading;
    recents_request = None;
    quick_sessions_request = None;
    screen_sessions_request = None;
    composer = Composer.init ~shell_enabled:capabilities.local_shell ();
    history = [];
    history_request = None;
    user_commands = [];
    user_commands_request = None;
    help = false;
    motion = Home.Motion.init ~reduced:reduced_motion;
    frame_accum = 0.;
    flash = None;
    now;
    phase = Prelude;
    surface = Conversing;
    completion = No_completion;
    queue = [];
    changes = [];
    last_usage = None;
    glance = None;
    glance_request = None;
    dune_status = None;
    dune_request = None;
    running = [];
    running_request = None;
    children = [];
    strip_focus = None;
    strip_hover = None;
    drill = None;
    pending = [];
    enumeration_request = None;
    attach_requests = [];
    image_max_count;
    next_request = 1L;
    next_attempt = 0;
    armed = None;
    rewind = None;
    undo_armed = None;
    show_reasoning;
    overlay;
    pending_chord = None;
    command_palette = false;
    notify_policy;
    palette;
    theme_name;
    themes;
    theme_auto;
    terminal_focused = false;
    review_request = None;
    cols = 80;
    rows = 24;
  }

let issue_home_sessions t =
  let request, t = fresh_request t in
  ( {
      t with
      recents = Home.Recents.refreshing t.recents;
      recents_request = Some request;
    },
    Load_home_sessions request )

let issue_account_readiness t =
  let request, t = fresh_request t in
  ( { t with account_readiness_request = Some request },
    Load_account_readiness request )

(* [refresh] re-observes server-owned model listings before projecting; the
   reload chord uses it, the opening load serves the retained snapshot. *)
let issue_model_readiness ?(refresh = false) t =
  let request, t = fresh_request t in
  ( { t with model_readiness_request = Some request },
    Load_model_readiness { request; refresh } )

let issue_configuration t =
  let request, t = fresh_request t in
  ({ t with configuration_request = Some request }, Load_configuration request)

let issue_workspace_glance t =
  let request, t = fresh_request t in
  ({ t with glance_request = Some request }, Load_workspace_glance request)

let issue_workspace_dune t =
  let request, t = fresh_request t in
  ({ t with dune_request = Some request }, Load_workspace_dune request)

(* The verb answers with the status after it, so it rides the same request
   slot and the same loaded message as the row's own query — one writer. *)
let issue_dune_control op t =
  let request, t = fresh_request t in
  ({ t with dune_request = Some request }, Dune_control { request; op })

(* The glance and the status query travel together at the event moments: the
   glance owns the worktree half, the dune query owns the row — one writer for
   each fact, so a slow glance can never regress a fresher status. *)
let issue_workspace_status t =
  let t, glance = issue_workspace_glance t in
  let t, dune = issue_workspace_dune t in
  (t, [ glance; dune ])

let issue_session_view session t =
  let request, t = fresh_request t in
  ( { t with session_view_request = Some (request, session) },
    Load_session_view { request; session } )

let issue_running_processes session t =
  let request, t = fresh_request t in
  ( { t with running_request = Some (request, session) },
    Load_running_processes { request; session } )

let session_view_matches session view =
  Session.Id.equal session
    (Session.Session_view.summary view |> Session.Summary.id)

let issue_pending_decision session t =
  let request, t = fresh_request t in
  ( { t with pending_decision_request = Some (request, session) },
    Load_pending_decision { request; session } )

let reserve_session_follow ~request kind t =
  let pending =
    List.filter
      (function
        | { pending_kind = Start; _ } -> Option.is_some t.active_session
        | { pending_kind = Resume | Fork _ | Rewind _; _ } -> false
        | _ -> true)
      t.pending
  in
  {
    t with
    pending = { pending_token = request; pending_kind = kind } :: pending;
  }

let begin_session_follow ~request kind t =
  let t = reserve_session_follow ~request kind t in
  (* A resume launched over the home stage commits to a session the moment the
     follow is issued, so paint the conversation surface immediately: the first
     frame is the session (a quiet banner-and-composer loading state) rather
     than a home frame that flashes until the replay lands. An in-flight chat
     keeps its transcript instead, so a switch that never gets admitted still
     preserves the projection it replaced. *)
  let phase =
    match t.phase with
    | Prelude -> Chat (empty_chat t.current_snapshot)
    | Chat _ as phase -> phase
  in
  {
    t with
    surface = Conversing;
    completion = No_completion;
    rewind = None;
    help = false;
    phase;
    motion = Home.Motion.freeze t.motion;
  }

(* The close every panel and screen shares: return to the conversing surface.
   [restore] threads any extra teardown the closing surface owns — like a theme
   cancel restoring its saved palette — applied before the surface flips. *)
let close_to_chat ?(restore = Fun.id) t =
  ({ (restore t) with surface = Conversing }, [])

(* The conversation reset shared by activating a session and by clearing to a
   fresh one: every field that returns to the conversing baseline, with the home
   motion frozen so the next stage animates from rest. Each caller layers its own
   divergent overrides — the destination session, the staged model, and the
   phase it opens on — on top of this. *)
let reset_conversation t =
  {
    t with
    main_feed = None;
    observation_lost = false;
    session_view = None;
    session_view_request = None;
    pending_decision_request = None;
    possibly_mutating = false;
    surface = Conversing;
    completion = No_completion;
    rewind = None;
    queue = [];
    changes = [];
    last_usage = None;
    glance = None;
    glance_request = None;
    dune_status = None;
    dune_request = None;
    running = [];
    running_request = None;
    children = [];
    strip_focus = None;
    strip_hover = None;
    drill = None;
    motion = Home.Motion.freeze t.motion;
  }

let activate_session session t =
  let cancel_shell =
    Option.map
      (fun request -> Cancel_local_shell request)
      (local_shell_request t)
  in
  let t = retire_chat_pending t in
  ( {
      (reset_conversation t) with
      active_session = Some session;
      staged_model = None;
      flash = None;
      phase = Chat (empty_chat t.current_snapshot);
      help = false;
    },
    Option.to_list cancel_shell @ [ Close_child_pane ] )

let init ~now ~(startup : Startup.t) ~capabilities ~reduced_motion
    ~show_reasoning ~overlay ~notify_policy ~palette ~theme_name ~themes
    ~theme_auto ~image_max_count =
  validate_now "init" now;
  let theme_auto =
    Option.map
      (fun (auto_dark, auto_light) ->
        { auto_dark; auto_light; auto_armed = true })
      theme_auto
  in
  let t =
    initial_model ~now ~startup ~capabilities ~reduced_motion ~show_reasoning
      ~overlay ~notify_policy ~palette ~theme_name ~themes ~theme_auto
      ~image_max_count
  in
  let t =
    match Startup.input startup with
    | Startup.Empty -> t
    | Startup.Draft text | Startup.Submit text -> set_draft text t
  in
  let t, home = issue_home_sessions t in
  let t, readiness = issue_account_readiness t in
  let history_request, t = fresh_request t in
  let user_commands_request, t = fresh_request t in
  let t =
    {
      t with
      history_request = Some history_request;
      user_commands_request = Some user_commands_request;
    }
  in
  (* Under auto the seed palette is the dark member (a brand fallback that holds
     if the terminal never answers); asking the terminal for its scheme lets the
     first reply swap to the light member when appropriate. *)
  let color_scheme_query =
    match theme_auto with Some _ -> [ Query_color_scheme ] | None -> []
  in
  let base_commands =
    color_scheme_query
    @ [
        home;
        readiness;
        Load_prompt_history history_request;
        Load_user_commands user_commands_request;
      ]
  in
  let model, commands =
    match Startup.session startup with
    | Some session ->
        let request, t = fresh_request t in
        let t = begin_session_follow ~request Resume t in
        (t, Resume_session { request; session } :: base_commands)
    | None -> (
        match Startup.input startup with
        | Startup.Empty | Startup.Draft _ -> (t, base_commands)
        | Startup.Submit prompt ->
            let request, t = fresh_request t in
            let t =
              add_pending request Start
                {
                  (clear_composer t) with
                  phase =
                    Chat (empty_chat ~tail_reset:request t.current_snapshot);
                  motion = Home.Motion.freeze t.motion;
                }
            in
            ( t,
              Start_session
                {
                  request;
                  prompt;
                  media = [];
                  mode = t.draft_mode;
                  history = None;
                  model = None;
                }
              :: base_commands ))
  in
  (* [mentat review] opens the review surface before the first frame, over the
     home model the launch built. *)
  if Startup.launch_review startup then
    let model, review_commands = open_review model in
    (model, commands @ review_commands)
  else (model, commands)

let append_notice notice chat =
  {
    chat with
    chat_document =
      Transcript.append chat.chat_document (Transcript.notice notice);
  }

let append_failure ?(next_step = "retry when ready") message chat =
  append_notice (Notice.Failure { message; next_step; count = 1 }) chat

let child_settlement_notice edge outcome =
  let task =
    Session.Delegation.task edge
    |> content_text |> Prims.normalize_inline |> String.trim
  in
  let subject =
    if String.equal task "" then "Agent" else "Agent \"" ^ task ^ "\""
  in
  let phrase =
    match outcome with
    | Session.Turn.Outcome.Completed -> "finished"
    | Session.Turn.Outcome.Step_limit -> "finished at the step limit"
    | Session.Turn.Outcome.Interrupted { reason; cancelled } -> (
        let verb =
          if cancelled then "was interrupted" else "ended interrupted"
        in
        match reason with None -> verb | Some reason -> verb ^ ": " ^ reason)
    | Session.Turn.Outcome.Failed { message } -> "failed: " ^ message
  in
  Notice.Event (Prims.normalize_inline ("● " ^ subject ^ " " ^ phrase))

let update_chat fn t =
  match t.phase with
  | Prelude -> t
  | Chat chat -> { t with phase = Chat (fn chat) }

let request_transcript_tail request =
  update_chat (fun chat -> { chat with page = None; tail_reset = Some request })

let remove_first predicate values =
  let rec loop rev_prefix = function
    | [] -> List.rev rev_prefix
    | value :: rest when predicate value -> List.rev_append rev_prefix rest
    | value :: rest -> loop (value :: rev_prefix) rest
  in
  loop [] values

let remove_pending_kind predicate t =
  {
    t with
    pending =
      remove_first
        (fun (pending : pending) -> predicate pending.pending_kind)
        t.pending;
  }

let command_error error t =
  update_chat
    (append_failure (error_text error))
    { t with flash = Some (error_text error) }

let capability_error diagnostic t =
  let message = diagnostic_text diagnostic in
  update_chat (append_failure message) { t with flash = Some message }

let change_equal left right = Change.Id.equal (Change.id left) (Change.id right)

let add_changes incoming changes =
  List.fold_left
    (fun changes change ->
      if List.exists (change_equal change) changes then changes
      else changes @ [ change ])
    changes incoming

let evidence_changes = function
  | Protocol.Fact.Tool_returned { mutation = Some evidence; _ }
  | Protocol.Fact.Tool_ambiguous { mutation = Some evidence; _ } ->
      evidence.Protocol.Fact.changes
  | Protocol.Fact.Turn_started _ | Protocol.Fact.Turn_assistant _
  | Protocol.Fact.Turn_assistant_interrupted _
  | Protocol.Fact.Turn_provider_failed _ | Protocol.Fact.Turn_message _
  | Protocol.Fact.Turn_settled _ | Protocol.Fact.Tool_started _
  | Protocol.Fact.Tool_prepared _
  | Protocol.Fact.Tool_returned { mutation = None; _ }
  | Protocol.Fact.Tool_ambiguous { mutation = None; _ }
  | Protocol.Fact.Decision_requested _ | Protocol.Fact.Decision_resolved _
  | Protocol.Fact.Journal_task_board _ | Protocol.Fact.Journal_delegation _
  | Protocol.Fact.Journal_queue _ | Protocol.Fact.Compaction _
  | Protocol.Fact.Workspace_notice _ | Protocol.Fact.Undo _ ->
      []

let queue_update update queue =
  match update with
  | Session.Queue.Update.Enqueued entry ->
      if
        List.exists
          (fun existing ->
            Session.Queue.Id.equal
              (Session.Queue.Entry.id existing)
              (Session.Queue.Entry.id entry))
          queue
      then queue
      else queue @ [ entry ]
  | Session.Queue.Update.Replaced entries -> entries
  | Session.Queue.Update.Cleared -> []

let consume_queued turn queue =
  match Session.Turn.origin turn with
  | Session.Turn.Origin.Queued admitted ->
      List.filter
        (fun entry ->
          not (Session.Queue.Id.equal admitted (Session.Queue.Entry.id entry)))
        queue
  | Session.Turn.Origin.User | Session.Turn.Origin.Triggered _
  | Session.Turn.Origin.Plan_build | Session.Turn.Origin.Compaction
  | Session.Turn.Origin.Step_limit_wind_down ->
      queue

let find_child child children =
  List.find_opt
    (fun entry -> Session.Id.equal child (Session.Delegation.child entry.edge))
    children

let update_child child fn children =
  List.map
    (fun entry ->
      if Session.Id.equal child (Session.Delegation.child entry.edge) then
        fn entry
      else entry)
    children

(* Insert a newly enumerated child into the DFS-ordered child list. A direct
   child (no parent) appends after every existing subtree. A nested child is
   spliced in immediately after its parent's subtree — the contiguous run of
   entries deeper than the parent — so siblings keep arrival order and the list
   stays a pre-order traversal that both the strip and index-based navigation
   read directly. *)
let insert_child ~parent entry children =
  match parent with
  | None -> children @ [ entry ]
  | Some parent_id -> (
      match find_child parent_id children with
      | None -> children @ [ entry ]
      | Some parent_entry ->
          let parent_depth = parent_entry.child_depth in
          let rec splice = function
            | [] -> [ entry ]
            | candidate :: rest ->
                if
                  Session.Id.equal parent_id
                    (Session.Delegation.child candidate.edge)
                then candidate :: after_subtree rest
                else candidate :: splice rest
          and after_subtree = function
            | candidate :: rest when candidate.child_depth > parent_depth ->
                candidate :: after_subtree rest
            | rest -> entry :: rest
          in
          splice children)

let issue_child ?parent edge t =
  let child = Session.Delegation.child edge in
  match find_child child t.children with
  | Some _ -> (t, [])
  | None ->
      let request, t = fresh_request t in
      let child_depth =
        match parent with
        | None -> 0
        | Some parent_id -> (
            match find_child parent_id t.children with
            | Some parent_entry -> parent_entry.child_depth + 1
            | None -> 0)
      in
      let entry =
        {
          edge;
          child_depth;
          child_pending = Some request;
          child_generation = None;
          child_projection = empty_child t.current_snapshot;
          child_closed = false;
          child_error = None;
        }
      in
      ( { t with children = insert_child ~parent entry t.children },
        [ Observe_child { request; child } ] )

let fold_turn_fact ~now ~show_reasoning fact chat =
  match Turn.fact ~now ~show_reasoning fact chat.chat_turn with
  | Ok (turn, blocks) ->
      let document =
        List.fold_left Transcript.append chat.chat_document blocks
      in
      let task_board =
        match fact with
        | Protocol.Fact.Journal_task_board board ->
            if Session.Task.Board.items board = [] then None else Some board
        | _ -> chat.task_board
      in
      { chat with chat_turn = turn; chat_document = document; task_board }
  | Error error -> append_failure (Turn.Error.message error) chat

let fold_child_fact ~now ~show_reasoning fact projection =
  match Turn.fact ~now ~show_reasoning fact projection.child_turn with
  | Ok (turn, blocks) ->
      let document =
        List.fold_left Transcript.append projection.child_document blocks
      in
      let outcome =
        match fact with
        | Protocol.Fact.Turn_settled { outcome; _ } -> Some outcome
        | _ -> projection.child_outcome
      in
      let child_board =
        match fact with
        | Protocol.Fact.Journal_task_board board ->
            if Session.Task.Board.items board = [] then None else Some board
        | _ -> projection.child_board
      in
      {
        child_document = document;
        child_turn = turn;
        child_outcome = outcome;
        child_board;
      }
  | Error error ->
      let document =
        Transcript.append projection.child_document
          (Transcript.notice
             (Notice.Failure
                {
                  message = Turn.Error.message error;
                  next_step = "child feed remains available";
                  count = 1;
                }))
      in
      { projection with child_document = document }

let exact_decision_id requested = Session.Decision.Requested.id requested

(* A user turn's origin, keyed by turn id, captured at its start. This mirrors
   [user_input_blocks]' predicate so the picker offers exactly the turns that
   render as user speech: only [User], [Queued], and [Triggered] origins with
   visible text. *)
let text_has_visible_grapheme text =
  String.exists (function ' ' | '\t' | '\n' | '\r' -> false | _ -> true) text

let turn_origin_of ~now ~prefix ~index turn =
  match Session.Turn.origin turn with
  | Session.Turn.Origin.User | Session.Turn.Origin.Queued _
  | Session.Turn.Origin.Triggered _ -> (
      match Session.Turn.Input.text (Session.Turn.input turn) with
      | Some text when text_has_visible_grapheme text ->
          Some
            {
              origin_turn = Session.Turn.id turn;
              origin_text = text;
              origin_prefix = prefix;
              origin_index = index;
              origin_at = now;
            }
      | Some _ | None -> None)
  | Session.Turn.Origin.Plan_build | Session.Turn.Origin.Compaction
  | Session.Turn.Origin.Step_limit_wind_down ->
      None

(* Every turn of any origin advances [turn_count]; a user turn additionally
   records its origin at that turn's all-origin index. *)
let record_turn_origin ~now ~prefix turn t =
  update_chat
    (fun chat ->
      let index = chat.turn_count in
      let chat = { chat with turn_count = index + 1 } in
      match turn_origin_of ~now ~prefix ~index turn with
      | None -> chat
      | Some origin -> { chat with turn_origins = origin :: chat.turn_origins })
    t

(* The reducer's notification decision. It fires the policy gate — enabled,
   the event selected in [notify_on], and the focus gate ([Unfocused] fires only
   when the terminal is not focused; a terminal that never reported focus stays
   unfocused, so it fires rather than silently dropping) — then resolves the
   configured channel to the concrete channels the runtime emits. [Command] is
   resolved only when the executable advertised the hook. The runtime holds no
   policy: it only encodes and writes. *)
let notify_channels t =
  match t.notify_policy.notify_channel with
  | Mentat_config.Notify.Channel.Off -> []
  | Mentat_config.Notify.Channel.Bell -> [ `Bell ]
  | Mentat_config.Notify.Channel.Osc9 -> [ `Osc9 ]
  | Mentat_config.Notify.Channel.Osc777 -> [ `Osc777 ]
  | Mentat_config.Notify.Channel.Auto -> [ `Bell; `Osc9 ]
  | Mentat_config.Notify.Channel.Command ->
      if t.effect_capabilities.notify_command then [ `Command ] else []

let notify_body = function
  | Mentat_config.Notify.Event.Turn_done -> "Turn finished"
  | Mentat_config.Notify.Event.Decision -> "Waiting for your response"

(* The notification title names the workspace the run belongs to, so a desktop
   alert says which Mentat fired it — the same identity the terminal title
   carries. *)
let notify_title t =
  "mentat — "
  ^ Filename.basename (Lpath.Abs.to_string (Snapshot.cwd t.current_snapshot))

let notify_for ~event t =
  let policy = t.notify_policy in
  let selected =
    List.exists (Mentat_config.Notify.Event.equal event) policy.notify_on
  in
  let focus_gate =
    match policy.notify_focus with
    | Mentat_config.Notify.When.Always -> true
    | Mentat_config.Notify.When.Unfocused -> not t.terminal_focused
  in
  if (not policy.notify_enabled) || (not selected) || not focus_gate then []
  else
    match notify_channels t with
    | [] -> []
    | channels ->
        [
          Notify { channels; title = notify_title t; body = notify_body event };
        ]

let fold_fact ~now fact t =
  validate_now "fact" now;
  let t = { t with now } in
  let chat =
    match t.phase with
    | Prelude -> empty_chat t.current_snapshot
    | Chat chat -> chat
  in
  let prefix_len = Transcript.length chat.chat_document in
  let chat = fold_turn_fact ~now ~show_reasoning:t.show_reasoning fact chat in
  let t = { t with phase = Chat chat; motion = Home.Motion.freeze t.motion } in
  let t = { t with changes = add_changes (evidence_changes fact) t.changes } in
  (* A whole-response usage supersedes the last as the occupancy reading; a
     generation-free response (a bare tool call) is not a context checkpoint. *)
  let t =
    match fact with
    | Protocol.Fact.Turn_assistant response -> (
        match Mentat_llm.Response.usage response with
        | Some usage when Mentat_llm.Usage.output_total usage > 0 ->
            { t with last_usage = Some usage }
        | Some _ | None -> t)
    | _ -> t
  in
  match fact with
  | Protocol.Fact.Turn_started turn ->
      let contract = Session.Turn.contract turn in
      let t =
        remove_pending_kind
          (function Start | Submission -> true | _ -> false)
          t
      in
      let t = record_turn_origin ~now ~prefix:prefix_len turn t in
      ( {
          t with
          current_snapshot = model_snapshot t turn t.current_snapshot;
          draft_mode = Session.Contract.mode contract;
          current_review = Session.Contract.review contract;
          flash = None;
          queue = consume_queued turn t.queue;
        },
        [] )
  | Protocol.Fact.Decision_requested requested ->
      ( { t with surface = Panel (Dialog (Dialog.make requested)) },
        notify_for ~event:Mentat_config.Notify.Event.Decision t )
  | Protocol.Fact.Decision_resolved resolved ->
      let id = Session.Decision.Resolved.id resolved in
      let surface =
        match t.surface with
        | Panel (Dialog dialog)
          when Session.Decision.Id.equal id
                 (exact_decision_id (Dialog.requested dialog)) ->
            Conversing
        | surface -> surface
      in
      let t =
        remove_pending_kind
          (function
            | Answer pending -> Session.Decision.Id.equal pending id
            | _ -> false)
          t
      in
      ({ t with surface }, [])
  | Protocol.Fact.Journal_task_board _ -> (t, [])
  | Protocol.Fact.Journal_queue update ->
      ({ t with queue = queue_update update t.queue }, [])
  | Protocol.Fact.Journal_delegation edge -> issue_child edge t
  | Protocol.Fact.Turn_settled { outcome = Session.Turn.Outcome.Failed _; _ }
    -> (
      let t = { t with queue = [] } in
      let notify = notify_for ~event:Mentat_config.Notify.Event.Turn_done t in
      match t.active_session with
      | None -> (t, notify)
      | Some session ->
          let t, command = issue_session_view session t in
          let t, glance = issue_workspace_status t in
          let t, running = issue_running_processes session t in
          (t, (command :: glance) @ [ running ] @ notify))
  | Protocol.Fact.Turn_settled _ -> (
      let notify = notify_for ~event:Mentat_config.Notify.Event.Turn_done t in
      match t.active_session with
      | None -> (t, notify)
      | Some session ->
          let t, command = issue_session_view session t in
          let t, glance = issue_workspace_status t in
          let t, running = issue_running_processes session t in
          (t, (command :: glance) @ [ running ] @ notify))
  | Protocol.Fact.Undo { update; _ } -> (
      (* The durable boundary drives the transcript seam and the model-view
         exclusion; the app only manages the composer. An [Armed] fact reloads
         the anchor turn's text into the composer (remembering the replaced draft
         once, for cancel); a [Released] fact restores it. Reconstructed on
         resume from the same fact. Media re-seed is not yet wired — the text
         round-trip is the honest paste/mention-expanded form. *)
      match Session.Undo.Update.anchor update with
      | Some anchor -> (
          match t.undo_armed with
          | Some a when Session.Turn.Id.equal a.undo_anchor anchor -> (t, [])
          | existing ->
              let restored =
                match existing with
                | Some a -> a.undo_restored
                | None -> Composer.history_entry (active_composer t)
              in
              let anchor_text =
                match t.phase with
                | Chat chat ->
                    List.find_map
                      (fun o ->
                        if Session.Turn.Id.equal o.origin_turn anchor then
                          Some o.origin_text
                        else None)
                      chat.turn_origins
                | Prelude -> None
              in
              let t =
                match anchor_text with
                | Some text ->
                    restore_draft (Draft.History_entry.of_text text) t
                | None -> t
              in
              ( {
                  t with
                  undo_armed =
                    Some { undo_anchor = anchor; undo_restored = restored };
                },
                [] ))
      | None -> (
          match t.undo_armed with
          | Some a ->
              (restore_draft a.undo_restored { t with undo_armed = None }, [])
          | None -> (t, [])))
  | Protocol.Fact.Turn_assistant _ | Protocol.Fact.Turn_assistant_interrupted _
  | Protocol.Fact.Turn_provider_failed _ | Protocol.Fact.Turn_message _
  | Protocol.Fact.Tool_started _ | Protocol.Fact.Tool_prepared _
  | Protocol.Fact.Tool_returned _ | Protocol.Fact.Tool_ambiguous _
  | Protocol.Fact.Compaction _ | Protocol.Fact.Workspace_notice _ ->
      (t, [])

let fold_progress ~now progress t =
  validate_now "progress" now;
  let t = { t with now } in
  match t.phase with
  | Prelude -> (t, [])
  | Chat chat ->
      let turn = Turn.progress ~now progress chat.chat_turn in
      ({ t with phase = Chat { chat with chat_turn = turn } }, [])

let turn_in_flight t =
  match t.phase with
  | Prelude -> false
  | Chat chat -> Turn.in_flight chat.chat_turn

(* A manual compaction has no turn projection to drive the working line — its
   turn is transparent on the feed — so its in-flight window is exactly the
   lifetime of the [Compact] pending. The start clock counts the status row. *)
let compaction_started t =
  List.find_map
    (fun pending ->
      match pending.pending_kind with
      | Compact { started } -> Some started
      | _ -> None)
    t.pending

let submission_pending t =
  List.exists
    (fun pending ->
      match pending.pending_kind with
      | Start | Submission | Resume | Fork _ | Queue_edit _ -> true
      | _ -> false)
    t.pending

let queue_edit_pending t =
  List.exists
    (fun pending ->
      match pending.pending_kind with Queue_edit _ -> true | _ -> false)
    t.pending

(* A command's human label for echoes and flashes: its slash spelling when it is
   slash-reachable, else its title (a key- or palette-only action). *)
let command_label command =
  match Command.slash command with
  | Some slash -> slash
  | None -> Command.title command

let echo_command command t =
  if not (Command.echoes command) then t
  else
    update_chat
      (append_notice
         (Notice.Echo { command = command_label command; result = None }))
      t

let provider_named name providers =
  List.find_map
    (fun declaration ->
      let provider = Mentat_provider.id declaration in
      if String.equal (Provider.id provider) name then Some provider else None)
    providers

let open_auth mode argument t =
  let provider =
    match argument with
    | None -> Ok None
    | Some name -> (
        match provider_named name t.provider_declarations with
        | Some provider -> Ok (Some provider)
        | None -> Error ("provider is not declared: " ^ name))
  in
  match provider with
  | Error message -> ({ t with flash = Some message }, [])
  | Ok provider ->
      let panel =
        Auth_panel.loading ~mode ~declarations:t.provider_declarations ?provider
          ()
      in
      let t, command =
        issue_account_readiness { t with surface = Panel (Auth panel) }
      in
      (t, [ command ])

let open_settings tab t =
  let screen =
    Settings_screen.loading ~tab ~snapshot:t.current_snapshot
      ~session:t.session_view
  in
  let t = { t with surface = Screen (Settings screen) } in
  let t, configuration = issue_configuration t in
  let t, readiness = issue_account_readiness t in
  let t, view_commands =
    match t.active_session with
    | None -> (t, [])
    | Some session ->
        let t, command = issue_session_view session t in
        (t, [ command ])
  in
  (t, configuration :: readiness :: view_commands)

let open_model ~return t =
  let panel = { state = Model_panel.loading t.current_snapshot; return } in
  let t, command =
    issue_model_readiness { t with surface = Panel (Model panel) }
  in
  (t, [ command ])

let open_theme t =
  let panel =
    {
      theme_picker = Theme_panel.make ~presets:t.themes ~current:t.theme_name;
      theme_saved = t.palette;
    }
  in
  ({ t with surface = Panel (Theme panel) }, [])

(* A runtime theme swap is a single-field update: [t.palette] is the only
   threaded source of color, so a new value recolors the whole TUI on the next
   frame with no cache to invalidate. *)
let set_palette palette t = { t with palette }

let clear_session t =
  let cancel_shell =
    Option.map
      (fun request -> Cancel_local_shell request)
      (local_shell_request t)
  in
  let chat =
    match t.active_session with
    | None -> empty_chat t.current_snapshot
    | Some session ->
        empty_chat t.current_snapshot
        |> append_notice
             (Notice.Event
                (Printf.sprintf
                   "conversation cleared · session %s remains saved"
                   (Session.Id.to_string session)))
  in
  ( {
      (reset_conversation t) with
      active_session = None;
      phase = Chat chat;
      pending = [];
      armed = None;
    },
    Option.to_list cancel_shell @ [ Close_child_pane; Detach_session ] )

let issue_lifecycle kind make_command session t =
  let request, t = fresh_request t in
  let t = add_pending request kind t in
  (t, [ make_command request session ])

let repairs_observation command =
  match Command.fate command with Command.Open_sessions -> true | _ -> false

let submitted_command_repairs_observation text t =
  match Composer.input_mode t.composer with
  | Composer.Input_mode.Plain -> (
      match Command.parse text with
      | Some (Command.Exact command | Command.With_argument (command, _)) ->
          repairs_observation command
      | Some (Command.Unexpected_argument _) | None -> false)
  | Composer.Input_mode.Shell | Composer.Input_mode.History_search -> false

let selected_command_repairs_observation t =
  match (Composer.input_mode t.composer, t.completion) with
  | Composer.Input_mode.Plain, Commands palette ->
      Option.exists repairs_observation (Palette.selected_command palette)
  | Composer.Input_mode.Plain, (No_completion | Mention _ | History_search _)
  | (Composer.Input_mode.Shell | Composer.Input_mode.History_search), _ ->
      false

(* Command scope across the main view and a drill. A drill is a focused view of
   one child session; slash commands split into two honest classes:

   - Global surface and toggle commands (login, logout, model, sessions,
     settings, review, thinking, mode, verbose, quit) belong to the whole
     application, not to any one conversation. They dispatch identically in a
     drill: the panel or screen opens over it and the drill persists underneath.

   - Conversation-lifecycle commands (clear, fork, compact, rename) act on
     a specific session through main-owned request accounting. In a drill they
     would silently target the hidden main session, so they are gated with an
     honest note directing the user back to main rather than acting on the wrong
     conversation. *)
let command_targets_conversation command =
  match Command.fate command with
  | Command.Clear_session | Command.Fork_session | Command.Rewind_session
  | Command.Undo_session | Command.Redo_session | Command.Compact_session
  | Command.Rename_session | Command.Init_project _ -> true
  | Command.Open_model | Command.Open_theme | Command.Open_sessions
  | Command.Open_settings _ | Command.Open_login | Command.Open_logout
  | Command.Switch_mode _ | Command.Toggle_thinking | Command.Toggle_verbose
  | Command.Open_review | Command.Dune_command | Command.Quit ->
      false
  (* The folded app-level gestures target the whole application, never the main
     session: Interrupt drives the Escape ladder that closes a drill, so
     classifying it as conversation-targeting would make a drill un-closable. The
     per-screen verbs never reach this predicate (they resolve into their
     screen's own update), but the match stays exhaustive so a new fate cannot
     default into the wrong side undetected. *)
  | Command.Interrupt | Command.Toggle_expanded | Command.Transcript_page _
  | Command.Focus_switch | Command.History_search | Command.Edit_in_editor
  | Command.Open_palette | Command.Copy_selection | Command.Sessions_fork
  | Command.Sessions_rename | Command.Sessions_archive
  | Command.Sessions_restore | Command.Sessions_delete | Command.Review_toggle
  | Command.Review_verdict | Command.Review_help | Command.Review_compose _
  | Command.Review_remove | Command.Review_next_hunk | Command.Review_prev_hunk
  | Command.Review_next_cr | Command.Review_prev_cr ->
      false

let open_rewind t =
  match (t.active_session, t.phase) with
  | None, _ -> ({ t with flash = Some "rewind: no active session" }, [])
  | Some _, Prelude -> ({ t with flash = Some "rewind: no messages yet" }, [])
  | Some _, Chat chat -> (
      match chat.turn_origins with
      | [] -> ({ t with flash = Some "rewind: no earlier messages" }, [])
      | origins ->
          let targets =
            List.map
              (fun origin ->
                Rewind_panel.Target.make ~turn:origin.origin_turn
                  ~text:origin.origin_text ~at:origin.origin_at)
              origins
          in
          ( {
              t with
              rewind = Some (Picking (Rewind_panel.make targets));
              completion = No_completion;
            },
            [] ))

(* Arming seeds the composer from the chosen turn's plain text and remembers the
   draft it replaced, so a cancel restores it verbatim. The dropped-turn count
   spans every turn of any origin from the anchor to the tail. *)
let arm_rewind ~turn t =
  match t.phase with
  | Prelude -> ({ t with rewind = None }, [])
  | Chat chat -> (
      match
        List.find_opt
          (fun origin -> Session.Turn.Id.equal origin.origin_turn turn)
          chat.turn_origins
      with
      | None -> ({ t with rewind = None }, [])
      | Some origin ->
          let restored = Composer.history_entry (active_composer t) in
          let t =
            restore_draft (Draft.History_entry.of_text origin.origin_text) t
          in
          let armed =
            {
              rewind_anchor = turn;
              rewind_prefix = origin.origin_prefix;
              rewind_dropped = chat.turn_count - origin.origin_index;
              rewind_restored = restored;
            }
          in
          ( { t with rewind = Some (Armed armed); completion = No_completion },
            [] ))

let cancel_rewind armed t =
  (restore_draft armed.rewind_restored { t with rewind = None }, [])

let update_rewind_panel message picker t =
  let picker, event = Rewind_panel.update message picker in
  match event with
  | Rewind_panel.Stay -> ({ t with rewind = Some (Picking picker) }, [])
  | Rewind_panel.Close -> ({ t with rewind = None }, [])
  | Rewind_panel.Arm turn -> arm_rewind ~turn t

(* Forward reference to the total registry dispatcher. Its gesture arms need
   effect functions defined far below (the Escape ladder, transcript paging, the
   editor handoff), so the reference is set once at the end of the reducer
   definitions. The slash dispatcher below delegates its non-slash fates through
   it; every call runs the same code, and the indirection only defers name
   resolution past this single module's top-down definition order. *)
let dispatch_registry_hook :
    (?argument:string -> Command.t -> t -> t * command list) ref =
  ref (fun ?argument:_ _ t -> (t, []))

let dispatch_registry ?argument command t =
  !dispatch_registry_hook ?argument command t

let rec dispatch_command ?argument command t =
  if Option.is_some t.drill && command_targets_conversation command then
    ( {
        t with
        flash =
          Some
            (command_label command
           ^ " targets the main session — esc back first");
      },
      [] )
  else if
    Command.phase command = Command.Idle_only
    && turn_in_flight t
    && not (t.observation_lost && repairs_observation command)
  then
    ( {
        t with
        flash =
          Some (command_label command ^ " is available after the turn finishes");
      },
      [] )
  else
    let t = echo_command command t in
    match Command.fate command with
    | Command.Quit -> ({ t with armed = None }, [ Quit ])
    | Command.Open_sessions ->
        let request, t = fresh_request t in
        ( {
            t with
            surface = Panel (Session_switch Sessions_panel.loading);
            quick_sessions_request = Some request;
          },
          [ Load_quick_sessions request ] )
    | Command.Open_model -> open_model ~return:To_chat t
    | Command.Open_theme -> open_theme t
    | Command.Open_login -> open_auth Auth_panel.Mode.Login argument t
    | Command.Open_logout -> open_auth Auth_panel.Mode.Logout argument t
    | Command.Open_settings tab -> open_settings tab t
    | Command.Open_review -> open_review t
    | Command.Switch_mode mode -> ({ t with draft_mode = mode }, [])
    | Command.Toggle_thinking ->
        ({ t with show_reasoning = not t.show_reasoning }, [])
    | Command.Toggle_verbose -> (
        match t.phase with
        | Prelude -> ({ t with flash = Some "no reasoning to expand yet" }, [])
        | Chat chat ->
            ( { t with phase = Chat { chat with expanded = not chat.expanded } },
              [] ))
    | Command.Clear_session -> clear_session t
    | Command.Fork_session -> (
        match t.active_session with
        | None -> ({ t with flash = Some "fork: no active session" }, [])
        | Some session ->
            let request, t = fresh_request t in
            ( reserve_session_follow ~request (Fork { parent = session }) t,
              [ Fork_session { request; session } ] ))
    | Command.Rewind_session -> open_rewind t
    | Command.Dune_command -> (
        match argument with
        | Some "restart" ->
            let t, verb = issue_dune_control `Restart t in
            ({ t with flash = Some "dune: restarting the watch" }, [ verb ])
        | Some "stop" ->
            let t, verb = issue_dune_control `Stop t in
            ({ t with flash = Some "dune: watch stopped" }, [ verb ])
        | Some _ | None ->
            ({ t with flash = Some "usage: /dune restart|stop" }, []))
    | Command.Undo_session -> (
        match t.active_session with
        | None -> ({ t with flash = Some "undo: no active session" }, [])
        | Some session ->
            let request, t = fresh_request t in
            (t, [ Undo_step { request; session; op = `Undo } ]))
    | Command.Redo_session -> (
        match (t.active_session, t.undo_armed) with
        | None, _ -> ({ t with flash = Some "redo: no active session" }, [])
        | Some _, None -> ({ t with flash = Some "nothing to redo" }, [])
        | Some session, Some _ ->
            let request, t = fresh_request t in
            (t, [ Undo_step { request; session; op = `Redo } ]))
    | Command.Compact_session -> (
        match t.active_session with
        | None -> ({ t with flash = Some "no session to compact" }, [])
        | Some session ->
            issue_lifecycle
              (Compact { started = t.now })
              (fun request session -> Compact_session { request; session })
              session t)
    | Command.Rename_session -> (
        match (t.active_session, argument) with
        | None, _ -> ({ t with flash = Some "no session to rename" }, [])
        | Some _, None -> (set_draft (command_label command ^ " ") t, [])
        | Some session, Some title ->
            issue_lifecycle Rename
              (fun request session ->
                Rename_session { request; session; title })
              session t)
    | Command.Init_project prompt ->
        (* /init is sugar over the ordinary prompt path: its fate carries the
           built-in prompt, which submits as a Build-mode turn so the agent
           writes AGENTS.md through the normal turn and mutation machinery. *)
        submit_prompt
          ~entry:(Draft.History_entry.of_text prompt)
          ~mode:Session.Contract.Mode.Build prompt t
    (* Non-slash fates never arrive through the slash path: the registry resolver
       and the command palette route the folded gestures and per-screen verbs by
       scope. The delegation keeps this match total so a new fate cannot silently
       default here. *)
    | Command.Interrupt | Command.Toggle_expanded | Command.Transcript_page _
    | Command.Focus_switch | Command.History_search | Command.Edit_in_editor
    | Command.Open_palette | Command.Copy_selection | Command.Sessions_fork
    | Command.Sessions_rename | Command.Sessions_archive
    | Command.Sessions_restore | Command.Sessions_delete | Command.Review_toggle
    | Command.Review_verdict | Command.Review_help | Command.Review_compose _
    | Command.Review_remove | Command.Review_next_hunk
    | Command.Review_prev_hunk | Command.Review_next_cr | Command.Review_prev_cr
      ->
        dispatch_registry ?argument command t

and submit_prompt ~entry ?mode ?(media = []) prompt t =
  let mode = Option.value mode ~default:t.draft_mode in
  if t.observation_lost then
    ( {
        t with
        flash =
          Some "the session feed is detached; resume a session before sending";
      },
      [] )
  else if submission_pending t then
    ({ t with flash = Some "waiting for the session feed to attach" }, [])
  else if Option.is_some t.undo_armed then
    (* Committing an armed undo truncates the crossed turns out of the journal,
       which the append-only feed cannot yet propagate; until commit-on-submit is
       wired, sending is blocked so an armed boundary is never left in a broken
       state. /redo to restore or esc to cancel first. *)
    ( {
        t with
        flash =
          Some
            "undo is armed — /redo to restore or esc to cancel before sending";
      },
      [] )
  else
    let request, t = fresh_request t in
    let persistence session = [ Append_prompt_history { session; entry } ] in
    if turn_in_flight t then
      match t.active_session with
      | None ->
          ({ t with flash = Some "the active turn has no attached session" }, [])
      | Some session ->
          ( request_transcript_tail request (add_pending request Submission t),
            Queue_next { request; session; prompt; media }
            :: persistence (Some session) )
    else
      match t.active_session with
      | Some session ->
          ( request_transcript_tail request (add_pending request Submission t),
            Prompt { request; session; prompt; media; mode }
            :: persistence (Some session) )
      | None ->
          let model = t.staged_model in
          let t =
            add_pending request Start
              {
                t with
                staged_model = None;
                phase = Chat (empty_chat ~tail_reset:request t.current_snapshot);
                motion = Home.Motion.freeze t.motion;
              }
          in
          ( t,
            [
              Start_session
                {
                  request;
                  prompt;
                  media;
                  mode;
                  history = Some entry;
                  model;
                };
            ] )

(* Committing an armed rewind resubmits the edited message into a fresh branch:
   the runtime rewinds [source] at the anchor, follows the child from the
   beginning, and submits [text] as its first turn. The reservation mirrors a
   fork so [session_followed] records the rewind seam. *)
let commit_rewind ~entry ?(media = []) text armed t =
  match t.active_session with
  | None ->
      ({ t with rewind = None; flash = Some "rewind: no active session" }, [])
  | Some source ->
      let anchor = Session.Anchor.before_turn armed.rewind_anchor in
      let request, t = fresh_request t in
      let mode = t.draft_mode in
      let t =
        reserve_session_follow ~request (Rewind { source; draft = entry }) t
      in
      let t = clear_composer { t with rewind = None } in
      ( t,
        [
          Rewind_session
            {
              request;
              source;
              anchor;
              prompt = text;
              media;
              mode;
              history = Some entry;
            };
        ] )

let submit_shell ~entry command t =
  if not t.effect_capabilities.local_shell then
    submit_prompt ~entry ("!" ^ command) t
  else if Option.is_some (local_shell_request t) then
    ({ t with flash = Some "a local shell command is already running" }, [])
  else
    let request, t = fresh_request t in
    (* Local shell output is presentation-only, but it still needs a transcript
       owner. Home is [Prelude], where [update_chat] deliberately has no effect;
       enter an empty local Chat before starting the callback so its correlated
       success or failure cannot be silently dropped. This creates no session. *)
    let t =
      match t.phase with
      | Prelude ->
          {
            t with
            phase = Chat (empty_chat t.current_snapshot);
            motion = Home.Motion.freeze t.motion;
          }
      | Chat _ -> t
    in
    let t = add_pending request Local_shell t in
    ( t,
      [
        Run_local_shell { request; command };
        Append_prompt_history { session = t.active_session; entry };
      ] )

(* The external-editor escape (Ctrl+X Ctrl+E by default). The seed is the draft
   fully materialized to plain text: paste payloads inlined and file-ref atoms
   rendered as their literal [@path] text, exactly the expansion [submit]
   produces. The returned buffer is installed as a plain draft, with no
   atom rebinding. At most one editor invocation is outstanding, mirroring the
   local-shell rule. *)
let request_editor t =
  if not t.effect_capabilities.external_editor then
    ({ t with flash = Some "external editor is not available" }, [])
  else if Option.is_some (editor_request t) then
    ({ t with flash = Some "the editor is already open" }, [])
  else
    let text =
      Draft.text
        (Draft.expand_paste_placeholders (Composer.draft (active_composer t)))
    in
    let request, t = fresh_request t in
    let t = add_pending request Editor t in
    (t, [ Edit_in_editor { request; text } ])

let starts_with_slash_token text =
  let length = String.length text in
  length > 0
  && Char.equal text.[0] '/'
  &&
  let rec no_separator index =
    index >= length
    ||
    match text.[index] with
    | ' ' | '\t' | '\r' | '\n' -> false
    | _ -> no_separator (index + 1)
  in
  no_separator 1

let slash_query text =
  if String.length text <= 1 then ""
  else String.sub text 1 (String.length text - 1)

(* The merged palette rows for [query]: builtin catalog rows from
   [Command.filter] followed by the custom commands whose name or description
   contains the query, matched with the same case- and horizontal-whitespace-
   insensitive rule the builtin filter uses. The app owns this merge so the
   palette stays a pure function over the supplied rows. *)
let string_contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec at index =
      index + nl <= hl
      && (String.equal (String.sub haystack index nl) needle || at (index + 1))
    in
    at 0

let custom_command_rows t query =
  let needle = String.lowercase_ascii (String.trim query) in
  List.filter_map
    (fun (command : Protocol.User_command.t) ->
      let name =
        String.lowercase_ascii
          (Protocol.User_command.Name.to_string
             command.Protocol.User_command.name)
      in
      let description =
        match command.Protocol.User_command.description with
        | Some text -> String.lowercase_ascii text
        | None -> ""
      in
      if string_contains ~needle name || string_contains ~needle description
      then Some (Palette.Custom command)
      else None)
    t.user_commands

let palette_rows t query =
  let builtins =
    List.map (fun command -> Palette.Builtin command) (Command.filter ~query)
  in
  builtins @ custom_command_rows t query

(* The registry scope of the currently focused surface, for command-palette
   seeding. A panel has no palette scope of its own. *)
let current_command_scope t =
  match t.surface with
  | Conversing -> Some Command.Chat
  | Screen (Sessions _) -> Some (Command.Screen Command.Sessions)
  | Screen (Review _) -> Some (Command.Screen Command.Review)
  | Screen (Settings _) -> Some (Command.Screen Command.Settings)
  | Panel _ -> None

(* Command-palette rows: every Global row plus the current surface's own rows,
   substring-matched on [query] over title and category, so each surface's verbs
   are discoverable in place. Custom commands are Chat-scoped, so they seed only
   where Chat rows do. *)
let command_palette_rows t query =
  let scope_here = current_command_scope t in
  let seeded command =
    let scope = Command.scope command in
    Command.scope_equal scope Command.Global
    ||
    match scope_here with
    | Some here -> Command.scope_equal scope here
    | None -> false
  in
  let builtins =
    Command.all |> List.filter seeded
    |> List.filter (Command.matches_palette ~query)
    |> List.map (fun command -> Palette.Builtin command)
  in
  let customs =
    match scope_here with
    | Some Command.Chat -> custom_command_rows t query
    | Some (Command.Global | Command.Screen _) | None -> []
  in
  builtins @ customs

let mention_query token =
  if String.length token <= 1 then ""
  else String.sub token 1 (String.length token - 1)

let issue_mention_loads mention t =
  if not t.effect_capabilities.file_enumeration then
    ({ t with completion = No_completion }, [])
  else
    let mention, needed = Mention.request_load mention in
    let t = { t with completion = Mention mention } in
    if not needed then (t, [])
    else
      let request, t = fresh_request t in
      ( { t with enumeration_request = Some request },
        [ Enumerate_files request ] )

let sync_completion t =
  if command_palette_open t then
    (* The command palette filters on the raw composer text, not a slash token,
       and stays a command palette across edits. *)
    let query = Composer.draft_text (active_composer t) in
    let palette =
      match t.completion with
      | Commands palette -> palette
      | No_completion | Mention _ | History_search _ -> Palette.make
    in
    ( {
        t with
        completion =
          Commands
            (Palette.with_rows ~query (command_palette_rows t query) palette);
      },
      [] )
  else
    match Composer.input_mode (active_composer t) with
    | Composer.Input_mode.History_search -> (
        match t.completion with
        | History_search state ->
            let query = Composer.draft_text (active_composer t) in
            ( {
                t with
                completion =
                  History_search
                    {
                      state with
                      search = History.Search.with_query query state.search;
                    };
              },
              [] )
        | No_completion | Commands _ | Mention _ -> (t, []))
    | Composer.Input_mode.Shell -> ({ t with completion = No_completion }, [])
    | Composer.Input_mode.Plain -> (
        let text = Composer.draft_text (active_composer t) in
        if starts_with_slash_token text then
          let palette =
            match t.completion with
            | Commands palette -> palette
            | No_completion | Mention _ | History_search _ -> Palette.make
          in
          ( {
              t with
              command_palette = false;
              completion =
                Commands
                  (Palette.with_rows ~query:(slash_query text)
                     (palette_rows t (slash_query text))
                     palette);
            },
            [] )
        else
          match
            ( t.effect_capabilities.file_enumeration,
              Composer.active_file_ref_token (active_composer t) )
          with
          | true, Some token ->
              let mention =
                match t.completion with
                | Mention mention -> mention
                | No_completion | Commands _ | History_search _ ->
                    Mention.make ()
              in
              issue_mention_loads
                (Mention.with_query (mention_query token) mention)
                t
          | false, _ | true, None -> ({ t with completion = No_completion }, [])
        )

(* Attached images. An [@]-mention of an image file, or a paste, routes the
   image to the executable through {!Attach_image}; the executable stores it and
   returns a media block, which {!attached} inserts as an atomic [[Image #N]]
   element. The pure shell never reads a file or the clipboard. *)

let image_extensions = [ ".png"; ".jpg"; ".jpeg"; ".gif"; ".webp" ]

let is_image_path path =
  let name = String.lowercase_ascii (Lpath.Rel.to_string path) in
  List.exists (fun suffix -> String.ends_with ~suffix name) image_extensions

let draft_image_count t =
  Composer.draft (active_composer t)
  |> Draft.ranges
  |> List.fold_left
       (fun count (range : Draft.range) ->
         match range.Draft.element with
         | Draft.Image _ -> count + 1
         | Draft.File_ref _ | Draft.Paste_placeholder _ -> count)
       0

let issue_attach ?(prewarn = true) source t =
  if draft_image_count t >= t.image_max_count then
    (* A path mention warns loudly; a speculative clipboard probe on an empty
       paste stays silent, since the user did not ask to attach anything. *)
    if prewarn then
      ( {
          t with
          flash =
            Some (Printf.sprintf "image limit reached (%d)" t.image_max_count);
        },
        [] )
    else (t, [])
  else
    let request, t = fresh_request t in
    ( { t with attach_requests = (request, source) :: t.attach_requests },
      [ Attach_image { request; source } ] )

let attached_result request result t =
  match
    List.find_opt
      (fun (token, _) -> equal_request token request)
      t.attach_requests
  with
  | None -> (t, [])
  | Some (_, source) -> (
      let t =
        {
          t with
          attach_requests =
            List.filter
              (fun (token, _) -> not (equal_request token request))
              t.attach_requests;
        }
      in
      match result with
      | Ok media ->
          let composer, _ =
            Composer.update
              (Composer.Insert_image (Draft.Image_ref.make media))
              (active_composer t)
          in
          (set_active_composer composer t, [])
      | Error Protocol.Attach.Error.Not_an_image when source = Attach_clipboard
        ->
          (* A paste whose clipboard held no image is the common case, not an
             error the user should see. *)
          (t, [])
      | Error error ->
          ( {
              t with
              flash =
                Some
                  (Format.asprintf "attach failed: %a" Protocol.Attach.Error.pp
                     error);
            },
            [] ))

let choose_mention item t =
  match item with
  | Mention.File path
    when t.effect_capabilities.image_attach && is_image_path path ->
      (* An image mention attaches its bytes instead of inserting an [@]-token.
         Clear the half-typed token now; [attached] inserts the [[Image #N]]. *)
      let composer, _ =
        Composer.update Composer.Clear_file_ref_token (active_composer t)
      in
      let t =
        set_active_composer composer { t with completion = No_completion }
      in
      issue_attach (Attach_path path) t
  | Mention.File path | Mention.Directory path ->
      let path = Lpath.Rel.to_string path in
      let composer, _ =
        Composer.update (Composer.Complete_file_ref path) (active_composer t)
      in
      (set_active_composer composer { t with completion = No_completion }, [])

(* Custom slash-command dispatch. A submitted slash line that
   [Command.parse] did not classify is a known custom command (expanded
   through the client and submitted) or an ordinary literal prompt. A builtin
   token never lands here with an argument: parse classifies it as
   [With_argument] or as the refused [Unexpected_argument]. The builtin token
   SET is checked before the custom snapshot, so a custom command named like a
   builtin verb is never reached. *)
let trim_horizontal_ends text =
  let is_horizontal = function ' ' | '\t' -> true | _ -> false in
  let n = String.length text in
  let first = ref 0 and last = ref n in
  while !first < !last && is_horizontal text.[!first] do
    incr first
  done;
  while !last > !first && is_horizontal text.[!last - 1] do
    decr last
  done;
  String.sub text !first (!last - !first)

let split_command_line text =
  if String.length text = 0 || text.[0] <> '/' then None
  else
    let body = String.sub text 1 (String.length text - 1) in
    let is_whitespace = function
      | ' ' | '\t' | '\n' | '\r' -> true
      | _ -> false
    in
    let n = String.length body in
    let stop = ref 0 in
    while !stop < n && not (is_whitespace body.[!stop]) do
      incr stop
    done;
    let name = String.sub body 0 !stop in
    if String.equal name "" then None
    else Some (name, trim_horizontal_ends (String.sub body !stop (n - !stop)))

let is_builtin_slash slash =
  List.exists
    (fun command ->
      match Command.slash command with
      | Some spelling -> String.equal spelling slash
      | None -> false)
    Command.all

(* The canonical name of the known custom command a slash line invokes, with its
   trimmed arguments, or [None] when the token is a builtin spelling or names no
   active custom command. *)
let custom_command_of text t =
  match split_command_line text with
  | None -> None
  | Some (typed_name, arguments) ->
      let lower = String.lowercase_ascii typed_name in
      if is_builtin_slash ("/" ^ lower) then None
      else
        List.find_map
          (fun (command : Protocol.User_command.t) ->
            let name =
              Protocol.User_command.Name.to_string
                command.Protocol.User_command.name
            in
            if String.equal (String.lowercase_ascii name) lower then
              Some (name, arguments)
            else None)
          t.user_commands

let issue_expand_command ~entry ~name ~arguments t =
  let request, t = fresh_request t in
  (t, [ Expand_command { request; name; arguments; entry } ])

let content_to_text content =
  content
  |> List.filter_map (function
    | Mentat_llm.Content.Text text -> Some text
    | Mentat_llm.Content.Media _ -> None)
  |> String.concat ""

let apply_palette_activation activation t =
  (* The command palette can activate a key- or palette-only row (a folded
     gesture or a screen verb), so its [Run] dispatches through the total
     registry dispatcher; the slash palette only ever holds slash rows. *)
  let run command =
    if command_palette_open t then dispatch_registry command
    else dispatch_command command
  in
  let t = { t with completion = No_completion; command_palette = false } in
  match activation with
  | Palette.Insert text -> (set_draft text t, [])
  | Palette.Run command -> run command (clear_composer t)
  | Palette.Expand name ->
      let t = clear_composer t in
      issue_expand_command
        ~entry:(Draft.History_entry.of_text ("/" ^ name))
        ~name ~arguments:"" t

let apply_history_activation entry t =
  let composer, _ =
    Composer.update Composer.End_history_search (active_composer t)
  in
  let composer, _ = Composer.update (Composer.Restore_history entry) composer in
  (set_active_composer composer { t with completion = No_completion }, [])

let activate_completion t =
  match t.completion with
  | No_completion -> None
  | Commands palette -> (
      match Palette.activate palette with
      | None -> None
      | Some activation -> Some (apply_palette_activation activation t))
  | Mention mention -> (
      match Mention.enter mention with
      | None -> Some ({ t with completion = No_completion }, [])
      | Some item -> Some (choose_mention item t))
  | History_search { search; _ } -> (
      match History.Search.selected_entry search with
      | None ->
          let composer, _ =
            Composer.update Composer.End_history_search (active_composer t)
          in
          Some
            ( set_active_composer composer { t with completion = No_completion },
              [] )
      | Some entry -> Some (apply_history_activation entry t))

let update_palette message t =
  match t.completion with
  | Commands palette -> (
      let palette, event = Palette.update message palette in
      let t = { t with completion = Commands palette } in
      match event with
      | Palette.Stay -> (t, [])
      | Palette.Activated activation -> apply_palette_activation activation t)
  | No_completion | Mention _ | History_search _ -> (t, [])

let update_mention message t =
  match t.completion with
  | Mention mention -> (
      let mention, event = Mention.update message mention in
      let t = { t with completion = Mention mention } in
      match event with
      | Mention.Stay -> (t, [])
      | Mention.Activated item -> choose_mention item t)
  | No_completion | Commands _ | History_search _ -> (t, [])

let update_history_search message t =
  match t.completion with
  | History_search state -> (
      let search, event = History.Search.update message state.search in
      let t = { t with completion = History_search { state with search } } in
      match event with
      | History.Search.Stay -> (t, [])
      | History.Search.Activated entry -> apply_history_activation entry t)
  | No_completion | Commands _ | Mention _ -> (t, [])

let tab_completion t =
  match t.completion with
  | Commands _ when command_palette_open t -> (
      (* Tab-complete is meaningless over slash-less command-palette rows; Tab
         activates the selection instead. *)
      match activate_completion t with
      | Some result -> result
      | None -> (t, []))
  | Commands palette -> (
      match Palette.complete palette with
      | Some text -> (set_draft text t, [])
      | None -> (
          match activate_completion t with
          | Some result -> result
          | None -> (t, [])))
  | Mention mention -> (
      match Mention.tab mention with
      | Mention.No_selection -> (t, [])
      | Mention.Chosen item -> choose_mention item t
      | Mention.Browse dir ->
          (* Drilling rewrites the token to [@dir/] — the token itself is the
             browse location — and the ordinary sync derives the listing from
             the new query. *)
          let composer, _ =
            Composer.update
              (Composer.Set_file_ref_token (Lpath.Rel.to_string dir ^ "/"))
              (active_composer t)
          in
          sync_completion (set_active_composer composer t))
  | History_search _ | No_completion -> (t, [])

(* Open the command palette over the conversing surface, seeded from the registry
   and filtered by the current draft (empty on a blank composer shows every
   seeded row). The palette is composer-driven, so on a panel or screen its
   Global chord is inert for now; the screen verbs it would surface stay
   remappable and resolve through the keymap regardless. *)
let open_command_palette t =
  match t.surface with
  | Conversing ->
      let query = Composer.draft_text (active_composer t) in
      ( {
          t with
          command_palette = true;
          completion =
            Commands
              (Palette.with_rows ~query
                 (command_palette_rows t query)
                 Palette.make);
        },
        [] )
  | Panel _ | Screen _ -> (t, [])

let move_completion direction t =
  let completion =
    match t.completion with
    | Commands palette -> Commands (Palette.move direction palette)
    | Mention mention ->
        Mention
          (match direction with
          | `Up -> Mention.select_previous mention
          | `Down -> Mention.select_next mention)
    | History_search ({ search; _ } as state) ->
        History_search
          { state with search = History.Search.move direction search }
    | No_completion -> No_completion
  in
  ({ t with completion }, [])

(* Prompt history is a single cross-session store; reverse search ranks the
   session currently in view first. In a drill that is the drilled child, so its
   own prompts lead; on the main view it is the active session. *)
let history_current_session t =
  match t.drill with
  | Some drill -> Some (drill_child drill)
  | None -> t.active_session

let begin_history_search t =
  let saved = Composer.history_entry (active_composer t) in
  let composer, _ =
    Composer.update Composer.Begin_history_search (active_composer t)
  in
  let t = clear_composer (set_active_composer composer t) in
  let search =
    History.Search.make
      ?current:(history_current_session t)
      ~entries:t.history ()
  in
  ({ t with completion = History_search { search; saved } }, [])

(* The drill composer shares the cross-session prompt history so recall and
   reverse search work exactly as on the main view. A fresh drill composer is
   seeded with that history and never enables shell input: executable-local shell
   is a main-surface capability that must not leak into a child conversation. *)
let fresh_drill_composer t =
  Composer.init ~shell_enabled:false ()
  |> Composer.with_history (List.map History.Entry.draft t.history)

(* A drilled child is a real session: a submitted prompt routes to the child's
   own session id, which the engine attaches and drives exactly like the main
   session. A prompt lands as a new turn on an idle child and as a queued input
   while the child's turn is in flight, mirroring the main composer. The reply
   arrives on the drill feed the observation already tails, so no optimistic
   transcript entry is minted here; the prompt is remembered in the shared
   history under the child's id so its own prompts lead the child's recall. *)
let submit_drill_prompt ~entry ?(media = []) text drill t =
  let child = drill_child drill in
  let request, t = fresh_request t in
  let command =
    if Turn.in_flight drill.drill_projection.child_turn then
      Queue_next { request; session = child; prompt = text; media }
    else
      Prompt
        {
          request;
          session = child;
          prompt = text;
          media;
          mode = Session.Contract.Mode.Build;
        }
  in
  let drill =
    {
      drill with
      drill_composer = fresh_drill_composer t;
      drill_prompt = Some request;
    }
  in
  ( { t with drill = Some drill },
    [ command; Append_prompt_history { session = Some child; entry } ] )

let composer_event event t =
  match event with
  | Composer.Submitted { text; media; entry } -> (
      (* While a rewind is armed the seeded composer commits the branch rather
         than dispatching a command or submitting an ordinary turn. [media] rides
         only the ordinary prompt paths; a submit that parses as a slash or custom
         command ignores it, since a command does not carry image content. *)
      match t.rewind with
      | Some (Armed armed) -> commit_rewind ~entry ~media text armed t
      | Some (Picking _) | None -> (
          (* A command carries no image content, so a media-bearing submit that
             parses as a command drops its attachments. Note the drop rather than
             let the bytes vanish silently, keeping any error the command itself
             raised. *)
          let note_dropped_media (result, commands) =
            match (media, result.flash) with
            | [], _ | _ :: _, Some _ -> (result, commands)
            | _ :: _, None ->
                ( {
                    result with
                    flash =
                      Some
                        "attached images were not sent: a command carries no \
                         image content";
                  },
                  commands )
          in
          match Command.parse text with
          | Some (Command.Exact command) ->
              note_dropped_media (dispatch_command command t)
          | Some (Command.With_argument (command, argument)) ->
              note_dropped_media (dispatch_command ~argument command t)
          | Some (Command.Unexpected_argument (command, _)) ->
              (* Refused in place: dispatching is impossible and submitting as
                 prose would silently start a paid model turn. The draft goes
                 back to the composer for editing. *)
              let composer, _ =
                Composer.update (Composer.Restore_history entry)
                  (active_composer t)
              in
              let flash =
                match Command.slash command with
                | Some slash -> Printf.sprintf "%s takes no argument" slash
                | None -> "this command takes no argument"
              in
              (set_active_composer composer { t with flash = Some flash }, [])
          | None -> (
              match custom_command_of text t with
              | Some (name, arguments) ->
                  note_dropped_media
                    (issue_expand_command ~entry ~name ~arguments t)
              | None -> (
                  match t.drill with
                  | Some drill -> submit_drill_prompt ~entry ~media text drill t
                  | None -> submit_prompt ~entry ~media text t))))
  | Composer.Shell_submitted { command; entry } -> submit_shell ~entry command t
  | Composer.Blank_submitted -> (
      (* A blank submit resumes the most recent session from home; a drill has no
         such gesture — a child is never resumed by an empty prompt. *)
      match (t.drill, t.phase, Home.Recents.most_recent t.recents) with
      | None, Prelude, Some session ->
          let request, t = fresh_request t in
          ( begin_session_follow ~request Resume t,
            [ Resume_session { request; session } ] )
      | _, Prelude, None | _, Chat _, _ | Some _, _, _ -> (t, []))
  | Composer.Draft_discarded entry ->
      (* A discarded nonblank draft is remembered in prompt history only — the
         next launch always starts with an empty composer. A drill's draft
         enters the shared history under the child's id. *)
      let session =
        match t.drill with
        | Some drill -> Some (drill_child drill)
        | None -> t.active_session
      in
      (t, [ Append_prompt_history { session; entry } ])
  | Composer.Help_requested -> ({ t with help = not t.help }, [])

let fold_composer message t =
  let composer, events = Composer.update message (active_composer t) in
  let t = set_active_composer composer t in
  let t =
    clear_active_strip_focus { t with motion = Home.Motion.freeze t.motion }
  in
  let t, commands =
    List.fold_left
      (fun (t, commands) event ->
        let t, more = composer_event event t in
        (t, commands @ more))
      (t, []) events
  in
  let t, completion_commands = sync_completion t in
  (t, commands @ completion_commands)

let recover_newest_queued t =
  match (t.active_session, List.rev t.queue) with
  | Some session, newest :: reversed_older -> (
      match Session.Queue.Entry.input newest with
      | [ Mentat_llm.Content.Text prompt ] ->
          let older = List.rev reversed_older in
          let inputs = List.map Session.Queue.Entry.input older in
          let rollback = Composer.history_entry t.composer in
          let t = set_draft prompt t in
          let optimistic = Composer.history_entry t.composer in
          let request, t = fresh_request t in
          let t = add_pending request (Queue_edit { optimistic; rollback }) t in
          let command =
            match inputs with
            | [] -> Clear_queued { request; session }
            | _ -> Replace_queued { request; session; inputs }
          in
          (t, [ command ])
      | _ ->
          ( {
              t with
              flash =
                Some
                  "the newest queued entry contains structured content and \
                   cannot be edited as text";
            },
            [] ))
  | None, _ :: _ ->
      ({ t with flash = Some "the queued draft has no attached session" }, [])
  | _, [] -> fold_composer Composer.History_previous t

(* One composer message path serves both the main view and a drill. The
   completion, prompt-history walk, and submit handling are shared; only two
   branches are main-only and are guarded by the absence of a drill: the detached
   main feed's command-repair gesture, and recall of the main session's newest
   queued input. Neither concerns a drilled child, whose own feed and queue are
   independent. *)
let update_composer message t =
  let on_main = Option.is_none t.drill in
  match message with
  | Composer.Submit text when on_main && t.observation_lost ->
      if submitted_command_repairs_observation text t then
        fold_composer message { t with completion = No_completion }
      else if selected_command_repairs_observation t then
        match activate_completion t with
        | Some result -> result
        | None -> (t, [])
      else (t, [])
  | Composer.Submit _ when completion_open t -> (
      match activate_completion t with
      | Some result -> result
      | None -> fold_composer message { t with completion = No_completion })
  | Composer.List_key `Tab when completion_open t -> tab_completion t
  | Composer.List_key `Up when completion_open t -> move_completion `Up t
  | Composer.List_key `Down when completion_open t -> move_completion `Down t
  | Composer.List_key (`Up | `Down)
    when match t.rewind with Some (Armed _) -> true | _ -> false ->
      (* While a rewind is armed the composer holds the message under edit;
         Up and Down never leave it to walk prompt history. *)
      (t, [])
  | Composer.List_key `Up
    when on_main && turn_in_flight t
         && Composer.is_blank t.composer
         && not t.observation_lost ->
      if queue_edit_pending t then
        ({ t with flash = Some "queue edit in progress" }, [])
      else recover_newest_queued t
  | Composer.List_key `Up -> fold_composer Composer.History_previous t
  | Composer.List_key `Down -> fold_composer Composer.History_next t
  | Composer.List_key `Tab -> (t, [])
  | Composer.Paste text
    when t.effect_capabilities.image_attach && String.trim text = "" ->
      (* An image paste often arrives as an empty bracketed paste; probe the OS
         clipboard out-of-band for an image while the (empty) text paste folds
         normally. A probe that finds nothing is silent. *)
      let t, commands = fold_composer message t in
      let t, attach = issue_attach ~prewarn:false Attach_clipboard t in
      (t, commands @ attach)
  | _ -> fold_composer message t

let resume_session session t =
  let request, t = fresh_request t in
  ( begin_session_follow ~request Resume t,
    [ Resume_session { request; session } ] )

let update_sessions_panel message panel t =
  let panel, event = Sessions_panel.update message panel in
  let t = { t with surface = Panel (Session_switch panel) } in
  match event with
  | Sessions_panel.Stay -> (t, [])
  | Sessions_panel.Close -> close_to_chat t
  | Sessions_panel.Resume session -> resume_session session t
  | Sessions_panel.Promote { filter; select } ->
      let request, t = fresh_request t in
      let screen = Sessions_screen.promoted ~filter ~select in
      ( {
          t with
          surface = Screen (Sessions screen);
          screen_sessions_request = Some request;
        },
        [ Load_screen_sessions request ] )

let screen_lifecycle kind make_command session screen t =
  let request, t = fresh_request t in
  ( add_pending request kind { t with surface = Screen (Sessions screen) },
    [ make_command request session ] )

let update_sessions_screen message screen t =
  let screen, event = Sessions_screen.update message screen in
  let stay = { t with surface = Screen (Sessions screen) } in
  match event with
  | Sessions_screen.Stay -> (stay, [])
  | Sessions_screen.Close -> close_to_chat t
  | Sessions_screen.Resume session -> resume_session session stay
  | Sessions_screen.Fork session ->
      let request, t = fresh_request t in
      ( reserve_session_follow ~request
          (Fork { parent = session })
          { t with surface = Screen (Sessions screen) },
        [ Fork_session { request; session } ] )
  | Sessions_screen.Rename { id = session; title } ->
      screen_lifecycle Rename
        (fun request session -> Rename_session { request; session; title })
        session screen t
  | Sessions_screen.Archive session ->
      screen_lifecycle Archive
        (fun request session -> Archive_session { request; session })
        session screen t
  | Sessions_screen.Restore session ->
      screen_lifecycle Restore
        (fun request session -> Restore_session { request; session })
        session screen t
  | Sessions_screen.Delete session ->
      screen_lifecycle Delete
        (fun request session -> Delete_session { request; session })
        session screen t

let update_model_panel message model t =
  let state, event = Model_panel.update message model.state in
  let model = { model with state } in
  let keep = { t with surface = Panel (Model model) } in
  match event with
  | Model_panel.Stay -> (keep, [])
  | Model_panel.Reload ->
      let t, command = issue_model_readiness ~refresh:true keep in
      (t, [ command ])
  | Model_panel.Close -> (
      match model.return with
      | To_chat -> close_to_chat t
      | To_settings screen -> ({ t with surface = Screen (Settings screen) }, [])
      )
  | Model_panel.Set_model { selector; reasoning_effort } -> (
      let refuse reason =
        let state = Model_panel.refuse_selection reason state in
        { t with surface = Panel (Model { model with state }) }
      in
      match t.active_session with
      | None ->
          (* Sessions are minted lazily by the first prompt, so there is no
             session to bind yet. The selection stages for the upcoming
             [Start_session], which applies it before the first submit, and the
             model line adopts it now — it is the model the next turn will
             use. *)
          let surface =
            match model.return with
            | To_chat -> Conversing
            | To_settings screen -> Screen (Settings screen)
          in
          let model_line = Mentat_provider.Selector.to_string selector in
          let effort =
            Option.map Mentat_llm.Request.Options.Reasoning_effort.to_string
              reasoning_effort
          in
          let context_window = model_context_window t selector in
          ( {
              t with
              surface;
              staged_model = Some (selector, reasoning_effort);
              current_snapshot =
                Snapshot.with_model ~model:model_line ~effort ?context_window
                  t.current_snapshot;
            },
            [] )
      | Some _ when model_selection_pending t ->
          (refuse "model selection is still being applied", [])
      | Some session ->
          let surface =
            match model.return with
            | To_chat -> Conversing
            | To_settings screen -> Screen (Settings screen)
          in
          let request, keep = fresh_request { keep with surface } in
          let model_line = Mentat_provider.Selector.to_string selector in
          let effort =
            Option.map Mentat_llm.Request.Options.Reasoning_effort.to_string
              reasoning_effort
          in
          ( add_pending request
              (Model_selection { session; model = model_line; effort })
              keep,
            [ Set_model { request; session; selector; reasoning_effort } ] ))

(* A hand pick disarms auto's colour-scheme following for the session. *)
let disarm_auto t =
  {
    t with
    theme_auto =
      Option.map (fun a -> { a with auto_armed = false }) t.theme_auto;
  }

(* The /theme picker previews live by pushing a new palette into [t.palette] on
   every cursor move, restores the palette saved at open on cancel, and on
   confirm keeps the previewed palette and persists the name to the user layer.
   The provenance warning is surfaced by {!Persist_ui_theme}'s result. *)
let theme_panel_event panel event t =
  let keep = { t with surface = Panel (Theme panel) } in
  match event with
  | Theme_panel.Stay -> (keep, [])
  | Theme_panel.Preview palette -> (set_palette palette (disarm_auto keep), [])
  | Theme_panel.Close ->
      close_to_chat ~restore:(fun t -> { t with palette = panel.theme_saved }) t
  | Theme_panel.Commit { name } ->
      let palette =
        match
          List.find_opt
            (fun (preset : Theme.Preset.t) ->
              String.equal preset.Theme.Preset.name name)
            t.themes
        with
        | Some preset -> preset.Theme.Preset.palette
        | None -> t.palette
      in
      let request, t = fresh_request (disarm_auto t) in
      ( {
          t with
          surface = Conversing;
          palette;
          theme_name = name;
          flash = Some ("theme · " ^ name);
        },
        [ Persist_ui_theme { request; name } ] )

let update_theme_panel message panel t =
  let picker, event = Theme_panel.update message panel.theme_picker in
  theme_panel_event { panel with theme_picker = picker } event t

let update_settings_screen message screen t =
  let screen, event = Settings_screen.update message screen in
  let keep = { t with surface = Screen (Settings screen) } in
  match event with
  | Settings_screen.Stay -> (keep, [])
  | Settings_screen.Close -> close_to_chat t
  | Settings_screen.Open_model_panel ->
      open_model ~return:(To_settings screen) keep
  | Settings_screen.Set_permission_review { request; review } -> (
      match t.active_session with
      | None ->
          ({ keep with flash = Some "permission review needs a session" }, [])
      | Some session ->
          (keep, [ Set_permission_review { request; session; review } ]))

let apply_dialog_outcome dialog outcome t =
  (* A dialog transition retires its previous validation; [Flash] below may
     install the next one explicitly. *)
  let keep = { t with surface = Panel (Dialog dialog); flash = None } in
  match outcome with
  | Dialog.Stay -> (keep, [])
  | Dialog.Flash message -> ({ keep with flash = Some message }, [])
  | Dialog.Resolve answer -> (
      let requested = Dialog.requested dialog in
      let decision = exact_decision_id requested in
      (* A dialog raised for a drilled child answers against THAT child (the
         drill is session-like); every other dialog answers the active session. *)
      let target =
        match t.drill with
        | Some drill
          when Option.exists
                 (fun req ->
                   Session.Decision.Id.equal decision
                     (Session.Decision.Requested.id req))
                 (Turn.pending_decision drill.drill_projection.child_turn) ->
            Some (drill_child drill)
        | None | Some _ -> t.active_session
      in
      match target with
      | None ->
          ({ keep with flash = Some "decision has no attached session" }, [])
      | Some session ->
          let request, keep = fresh_request keep in
          ( add_pending request (Answer decision) keep,
            [ Answer_decision { request; session; decision; answer } ] ))

let update_dialog_with transition dialog t =
  let decision = exact_decision_id (Dialog.requested dialog) in
  if answer_pending decision t then (t, [])
  else
    let dialog, outcome = transition dialog in
    apply_dialog_outcome dialog outcome t

let update_dialog_key key = update_dialog_with (Dialog.key key)
let update_dialog_message message = update_dialog_with (Dialog.update message)

let apply_auth_event event panel t =
  let keep panel = { t with surface = Panel (Auth panel) } in
  match event with
  | Auth_panel.Stay -> (keep panel, [])
  | Auth_panel.Close -> close_to_chat t
  | Auth_panel.Reload_readiness ->
      let t, command = issue_account_readiness (keep panel) in
      (t, [ command ])
  | Auth_panel.Flash message -> ({ (keep panel) with flash = Some message }, [])
  | Auth_panel.Copy text -> (keep panel, [ Copy_text text ])
  | Auth_panel.Open_url { attempt; url } ->
      if t.effect_capabilities.browser then
        (keep panel, [ Open_url { attempt; url } ])
      else
        let panel =
          Auth_panel.url_open_failed ~attempt
            ~message:"browser opening is unavailable" panel
        in
        ({ (keep panel) with flash = Some "browser opening is unavailable" }, [])
  | Auth_panel.Cancel_login attempt -> (keep panel, [ Auth_cancel attempt ])
  | Auth_panel.Save_api_key { provider; key } ->
      let attempt, t = fresh_attempt (keep panel) in
      let panel = Auth_panel.started ~attempt panel in
      ( { t with surface = Panel (Auth panel) },
        [ Auth_save_api_key { attempt; provider; key } ] )
  | Auth_panel.Begin_login { provider; method_ } ->
      let attempt, t = fresh_attempt (keep panel) in
      let panel = Auth_panel.started ~attempt panel in
      ( { t with surface = Panel (Auth panel) },
        [ Auth_begin_login { attempt; provider; method_ } ] )
  | Auth_panel.Logout { provider } ->
      let attempt, t = fresh_attempt (keep panel) in
      let panel = Auth_panel.started ~attempt panel in
      ( { t with surface = Panel (Auth panel) },
        [ Auth_logout { attempt; provider } ] )

let update_auth_panel message panel t =
  let panel, event = Auth_panel.update message panel in
  apply_auth_event event panel t

let fold_child_outcome ~now ~show_reasoning outcome projection =
  match outcome with
  | Ok (Mentat_client.Feed.Item (Protocol.Update.Committed { fact; _ })) ->
      (fold_child_fact ~now ~show_reasoning fact projection, false, None)
  | Ok (Mentat_client.Feed.Item (Protocol.Update.Progress progress)) ->
      ( {
          projection with
          child_turn = Turn.progress ~now progress projection.child_turn;
        },
        false,
        None )
  | Ok Mentat_client.Feed.Closed -> (projection, true, None)
  | Error error -> (projection, true, Some error)

let child_observation_started_result ~request ~observation ~child ~generation t
    =
  match observation with
  | Child_feeds.Live ->
      let children =
        update_child child
          (fun entry ->
            match entry.child_pending with
            | Some pending when same_request pending request ->
                {
                  entry with
                  child_pending = None;
                  child_generation = Some generation;
                  child_closed = false;
                  child_error = None;
                }
            | None | Some _ -> entry)
          t.children
      in
      ({ t with children }, [])
  | Child_feeds.Drill -> (
      match t.drill with
      | Some drill
        when Session.Id.equal child (drill_child drill)
             && Option.exists (same_request request) drill.drill_request ->
          ( {
              t with
              drill =
                Some
                  {
                    drill with
                    drill_request = None;
                    drill_generation = Some generation;
                    drill_error = None;
                  };
            },
            [] )
      | None | Some _ -> (t, []))

(* A drilled child is session-like: its permission review raises the SAME
   answerable dialog the main feed raises for the active session, and
   [apply_dialog_outcome] answers it against the drilled child. Raise it only
   over a clear conversing surface so it never clobbers another open panel; the
   drill state persists, so resolving or escaping the dialog returns to the drill
   glance. Drop the dialog when the shown decision resolves, retiring its pending
   answer exactly as the main [Decision_resolved] arm does. [was_pending] is the
   child's decision before the fold, so a resolve on this tick is detected
   precisely. *)
let reconcile_drill_decision ~was_pending t =
  match t.drill with
  | None -> (t, [])
  | Some drill -> (
      let now_pending =
        Turn.pending_decision drill.drill_projection.child_turn
      in
      match (now_pending, t.surface) with
      | Some requested, Conversing ->
          ( { t with surface = Panel (Dialog (Dialog.make requested)) },
            notify_for ~event:Mentat_config.Notify.Event.Decision t )
      | None, Panel (Dialog dialog)
        when Option.exists
               (fun req ->
                 Session.Decision.Id.equal
                   (exact_decision_id (Dialog.requested dialog))
                   (Session.Decision.Requested.id req))
               was_pending ->
          let id = exact_decision_id (Dialog.requested dialog) in
          let t =
            remove_pending_kind
              (function
                | Answer pending -> Session.Decision.Id.equal pending id
                | _ -> false)
              t
          in
          ({ t with surface = Conversing }, [])
      | _ -> (t, []))

let child_feed_result ~observation ~generation ~child outcome t =
  let now = t.now in
  match observation with
  | Child_feeds.Live ->
      let previous = find_child child t.children in
      let admitted =
        match previous with
        | Some entry ->
            Option.exists
              (fun current -> Child_feeds.Generation.equal current generation)
              entry.child_generation
        | None -> false
      in
      let children =
        update_child child
          (fun entry ->
            match entry.child_generation with
            | Some current when Child_feeds.Generation.equal current generation
              ->
                let projection, closed, error =
                  fold_child_outcome ~now ~show_reasoning:t.show_reasoning
                    outcome entry.child_projection
                in
                {
                  entry with
                  child_projection = projection;
                  child_closed = closed;
                  child_error = error;
                }
            | None | Some _ -> entry)
          t.children
      in
      let t = { t with children } in
      let t =
        match (previous, find_child child children) with
        | Some previous, Some current -> (
            match
              ( previous.child_projection.child_outcome,
                current.child_projection.child_outcome )
            with
            | None, Some outcome ->
                update_chat
                  (append_notice (child_settlement_notice current.edge outcome))
                  t
            | None, None | Some _, None | Some _, Some _ -> t)
        | None, _ | Some _, None -> t
      in
      let t =
        match (admitted, outcome) with
        | true, Error error -> command_error error t
        | false, _ | true, Ok _ -> t
      in
      (* A delegated child that itself delegates surfaces its grandchild through
         its own live feed as a [Journal_delegation] fact. Enumerate it here so a
         subagent's subagent joins the switcher and is observed in turn, exactly
         as a direct child is from the active session's feed; passing this child
         as the parent nests the grandchild one level under it in the tree. *)
      let t, commands =
        match (admitted, outcome) with
        | ( true,
            Ok
              (Mentat_client.Feed.Item
                 (Protocol.Update.Committed
                    { fact = Protocol.Fact.Journal_delegation edge; _ })) ) ->
            issue_child ~parent:child edge t
        | _ -> (t, [])
      in
      (t, commands)
  | Child_feeds.Drill -> (
      match t.drill with
      | Some drill
        when Session.Id.equal child (drill_child drill)
             && Option.exists
                  (fun current ->
                    Child_feeds.Generation.equal current generation)
                  drill.drill_generation ->
          let was_pending =
            Turn.pending_decision drill.drill_projection.child_turn
          in
          let projection, _, error =
            fold_child_outcome ~now ~show_reasoning:t.show_reasoning outcome
              drill.drill_projection
          in
          let t =
            {
              t with
              drill =
                Some
                  {
                    drill with
                    drill_projection = projection;
                    drill_error = error;
                  };
            }
          in
          reconcile_drill_decision ~was_pending t
      | None | Some _ -> (t, []))

let thread_count t = List.length t.children + 1

let move_thread_focus direction t =
  let count = thread_count t in
  let selected =
    match (direction, t.strip_focus) with
    | `Down, None -> Some 0
    | `Up, None -> Some (count - 1)
    | `Down, Some index -> Some ((index + 1) mod count)
    | `Up, Some index -> Some ((index - 1 + count) mod count)
  in
  ({ t with strip_focus = selected }, [])

(* [Tab] toggles keyboard focus between the composer and the switcher. Entering
   rests on [main] so the first arrow steps to the newest delegation; leaving
   returns the arrows to prompt-history recall. *)
let toggle_strip_focus t =
  match t.strip_focus with
  | None -> ({ t with strip_focus = Some 0 }, [])
  | Some _ -> ({ t with strip_focus = None; strip_hover = None }, [])

let select_thread index t =
  if index < 0 || index >= thread_count t then t
  else { t with strip_focus = Some index }

let hover_thread index t =
  let strip_hover =
    match index with
    | Some index when index >= 0 && index < thread_count t -> Some index
    | None | Some _ -> None
  in
  { t with strip_hover }

(* A lost child observation is terminal: the live feed does not re-attach on its
   own. Activating such a row re-follows it from the beginning in place, so a
   transient transport drop recovers to the running child and a persistent one
   settles back to the same honest error. The row keeps focus through the retry;
   drilling into an errorless empty transcript would only hide the state. *)
let retry_child_observation entry t =
  let child = Session.Delegation.child entry.edge in
  let request, t = fresh_request t in
  let children =
    update_child child
      (fun entry ->
        {
          entry with
          child_pending = Some request;
          child_generation = None;
          child_projection = empty_child t.current_snapshot;
          child_closed = false;
          child_error = None;
        })
      t.children
  in
  ({ t with children }, [ Observe_child { request; child } ])

let close_drill_commands drill =
  match drill.drill_generation with
  | None -> []
  | Some generation ->
      [ Close_child_drill { child = drill_child drill; generation } ]

let drill_targets_child child t =
  match t.drill with
  | Some drill -> Session.Id.equal (drill_child drill) child
  | None -> false

(* Opening a drill from within another drill switches conversations in place:
   the outgoing feed is closed before the incoming one is followed so no
   read-only observation is leaked and the two feeds never both drive the single
   drill projection. A fresh drill always opens on an unfocused glance. *)
let drill_focused_thread entry t =
  let child = Session.Delegation.child entry.edge in
  let closing =
    match t.drill with
    | Some drill when not (Session.Id.equal (drill_child drill) child) ->
        close_drill_commands drill
    | None | Some _ -> []
  in
  let request, t = fresh_request t in
  let drill =
    {
      drill_edge = entry.edge;
      drill_request = Some request;
      drill_generation = None;
      drill_projection = empty_child t.current_snapshot;
      drill_error = None;
      drill_composer = fresh_drill_composer t;
      drill_prompt = None;
      drill_focus = None;
    }
  in
  ( { t with drill = Some drill; strip_focus = None; strip_hover = None },
    closing @ [ Drill_child { request; child } ] )

let close_thread_drill t =
  match t.drill with
  | None -> (t, [])
  | Some drill -> ({ t with drill = None }, close_drill_commands drill)

let open_focused_thread t =
  match t.strip_focus with
  | None | Some 0 -> (t, [])
  | Some index -> (
      match List.nth_opt t.children (index - 1) with
      | None -> ({ t with strip_focus = None; strip_hover = None }, [])
      | Some entry when Option.is_some entry.child_error ->
          retry_child_observation entry t
      | Some entry -> drill_focused_thread entry t)

(* The drilled child walks the switcher through its own [drill_focus], so
   navigation is visible and predictable without inheriting or disturbing the
   parent view's [strip_focus]. *)
let move_drill_focus direction drill t =
  let count = thread_count t in
  let selected =
    match (direction, drill.drill_focus) with
    | `Down, None -> Some 0
    | `Up, None -> Some (count - 1)
    | `Down, Some index -> Some ((index + 1) mod count)
    | `Up, Some index -> Some ((index - 1 + count) mod count)
  in
  ({ t with drill = Some { drill with drill_focus = selected } }, [])

let clear_drill_focus drill t =
  ({ t with drill = Some { drill with drill_focus = None } }, [])

(* The drilled child's own row in the switcher: index 0 is the parent, so a
   child sits at one past its position among the siblings. A child with no live
   sibling entry (it was not yet issued) falls back to the parent row. *)
let drill_child_index drill t =
  let child = drill_child drill in
  match
    List.find_index
      (fun entry ->
        Session.Id.equal (Session.Delegation.child entry.edge) child)
      t.children
  with
  | Some index -> index + 1
  | None -> 0

(* [Tab] hands focus to the drill's switcher and back, mirroring the main view so
   the two navigate identically: focused arrows walk, unfocused arrows stay on
   the composer's history. The glance opens on the child currently in view — not
   the parent row — so [Enter] holds the current child and an arrow reaches a
   sibling, rather than silently jumping home. *)
let toggle_drill_focus drill t =
  match drill.drill_focus with
  | None ->
      ( {
          t with
          drill =
            Some { drill with drill_focus = Some (drill_child_index drill t) };
        },
        [] )
  | Some _ -> ({ t with drill = Some { drill with drill_focus = None } }, [])

(* Activating the switcher from within a drill: the parent row is the way home,
   an errored sibling re-follows its live feed in place, the current child drops
   the focus, and any other sibling switches the drill in place. *)
let activate_drill_focus drill t =
  match drill.drill_focus with
  | None -> (t, [])
  | Some 0 -> close_thread_drill t
  | Some index -> (
      match List.nth_opt t.children (index - 1) with
      | None -> clear_drill_focus drill t
      | Some entry when Option.is_some entry.child_error ->
          retry_child_observation entry t
      | Some entry
        when drill_targets_child (Session.Delegation.child entry.edge) t ->
          clear_drill_focus drill t
      | Some entry -> drill_focused_thread entry t)

let update_threads_strip message t =
  match (t.drill, message) with
  | Some drill, Threads_strip.Select_index index ->
      if index < 0 || index >= thread_count t then (t, [])
      else ({ t with drill = Some { drill with drill_focus = Some index } }, [])
  | Some drill, Threads_strip.Activate_index index ->
      let drill = { drill with drill_focus = Some index } in
      activate_drill_focus drill { t with drill = Some drill }
  | Some _, Threads_strip.Hover_index _ -> (t, [])
  | None, Threads_strip.Select_index index -> (select_thread index t, [])
  | None, Threads_strip.Activate_index index ->
      open_focused_thread (select_thread index t)
  | None, Threads_strip.Hover_index index -> (hover_thread index t, [])

(* The switcher navigation of whichever surface is on screen. The drill walks its
   own [drill_focus]; the main view walks [strip_focus]. One set of key bindings
   in [update] drives both through these. *)
let active_strip_focus t =
  match t.drill with Some drill -> drill.drill_focus | None -> t.strip_focus

let move_active_focus direction t =
  match t.drill with
  | Some drill -> move_drill_focus direction drill t
  | None -> move_thread_focus direction t

let toggle_active_focus t =
  match t.drill with
  | Some drill -> toggle_drill_focus drill t
  | None -> toggle_strip_focus t

let activate_active_focus t =
  match t.drill with
  | Some drill -> activate_drill_focus drill t
  | None -> open_focused_thread t

let now_time t = Session.Time.of_unix_seconds_float t.now

let map_settings_return fn = function
  | To_chat -> To_chat
  | To_settings screen -> To_settings (fn screen)

let install_session_view session view t =
  if not (session_view_matches session view) then
    { t with flash = Some "session detail returned a different session" }
  else
    let surface =
      match t.surface with
      | Screen (Settings screen) ->
          Screen (Settings (Settings_screen.set_session (Some view) screen))
      | Panel (Model model) ->
          let return =
            map_settings_return
              (Settings_screen.set_session (Some view))
              model.return
          in
          Panel (Model { model with return })
      | surface -> surface
    in
    { t with session_view = Some view; surface }

(* A listing warning renders on a one-line status row, so only each
   diagnostic's head belongs on the stage; a store decode trace in the context
   would splat codec internals across the screen. The runtime logs the full
   diagnostics when it delivers the listing. *)
let listing_diagnostics diagnostics =
  diagnostics
  |> List.map Mentat_diagnostic.message
  |> String.concat Theme.separator

let load_home_result request result t =
  guard_request t.recents_request request t @@ fun t ->
  let recents =
    match result with
    | Ok (summaries, []) -> Home.Recents.loaded summaries
    | Ok (summaries, diagnostics) ->
        Home.Recents.loaded summaries
        |> Home.Recents.failed (listing_diagnostics diagnostics)
    | Error error -> Home.Recents.failed (error_text error) t.recents
  in
  ({ t with recents; recents_request = None }, [])

let load_quick_result request result t =
  match (t.quick_sessions_request, t.surface) with
  | Some current, Panel (Session_switch panel) when same_request current request
    ->
      let panel =
        match result with
        | Ok (summaries, []) -> Sessions_panel.loaded summaries panel
        | Ok (summaries, diagnostics) ->
            Sessions_panel.loaded summaries panel
            |> Sessions_panel.failed (listing_diagnostics diagnostics)
        | Error error -> Sessions_panel.failed (error_text error) panel
      in
      ( {
          t with
          quick_sessions_request = None;
          surface = Panel (Session_switch panel);
        },
        [] )
  | (None | Some _), _ -> (t, [])

let load_screen_result request result t =
  match (t.screen_sessions_request, t.surface) with
  | Some current, Screen (Sessions screen) when same_request current request ->
      let screen =
        match result with
        | Ok (summaries, []) -> Sessions_screen.loaded summaries screen
        | Ok (summaries, diagnostics) ->
            Sessions_screen.loaded summaries screen
            |> Sessions_screen.failed (listing_diagnostics diagnostics)
        | Error error -> Sessions_screen.failed (error_text error) screen
      in
      ( {
          t with
          screen_sessions_request = None;
          surface = Screen (Sessions screen);
        },
        [] )
  | (None | Some _), _ -> (t, [])

let load_session_view_result ~request ~session result t =
  guard_request_session t.session_view_request request ~session t @@ fun t ->
  let t = { t with session_view_request = None } in
  match result with
  | Ok view -> (install_session_view session view t, [])
  | Error error -> (command_error error t, [])

let load_pending_decision_result ~request ~session result t =
  guard_request_session t.pending_decision_request request ~session t
  @@ fun t ->
  let t = { t with pending_decision_request = None } in
  match result with
  | Ok None -> (t, [])
  | Ok (Some requested) ->
      ({ t with surface = Panel (Dialog (Dialog.make requested)) }, [])
  | Error error -> (command_error error t, [])

let apply_account_readiness_to_surface result surface =
  match surface with
  | Panel (Model model) ->
      let update_settings screen =
        match result with
        | Ok readiness -> Settings_screen.readiness_loaded readiness screen
        | Error error ->
            Settings_screen.readiness_failed (error_text error) screen
      in
      let return = map_settings_return update_settings model.return in
      (Panel (Model { model with return }), None)
  | Screen (Settings screen) ->
      let screen =
        match result with
        | Ok readiness -> Settings_screen.readiness_loaded readiness screen
        | Error error ->
            Settings_screen.readiness_failed (error_text error) screen
      in
      (Screen (Settings screen), None)
  | Panel (Auth panel) ->
      let panel, event = Auth_panel.readiness_loaded result panel in
      (Panel (Auth panel), Some (panel, event))
  | Conversing
  | Panel (Session_switch _ | Theme _ | Dialog _)
  | Screen (Sessions _ | Review _) ->
      (surface, None)

let apply_model_readiness_to_surface result surface =
  match surface with
  | Panel (Model model) ->
      let state =
        match result with
        | Ok readiness -> Model_panel.loaded readiness model.state
        | Error error -> Model_panel.failed (error_text error) model.state
      in
      Panel (Model { model with state })
  | Conversing
  | Panel (Session_switch _ | Theme _ | Dialog _ | Auth _)
  | Screen (Sessions _ | Settings _ | Review _) ->
      surface

let all_accounts_missing = function
  | [] -> false
  | readiness ->
      List.for_all
        (function
          | Discovery.Known account -> (
              match Account.phase account with
              | Account_phase.Missing -> true
              | Account_phase.Unchecked | Account_phase.Ready
              | Account_phase.Degraded | Account_phase.Blocked ->
                  false)
          | Discovery.Resolution_failed _ -> false)
        readiness

let load_account_readiness_result request result t =
  guard_request t.account_readiness_request request t @@ fun t ->
  let all_accounts_missing =
    match result with
    | Ok value -> all_accounts_missing value
    | Error _ -> t.all_accounts_missing
  in
  let surface, auth = apply_account_readiness_to_surface result t.surface in
  let t =
    { t with all_accounts_missing; account_readiness_request = None; surface }
  in
  match auth with
  | None -> (t, [])
  | Some (panel, event) -> apply_auth_event event panel t

let load_model_readiness_result request result t =
  guard_request t.model_readiness_request request t @@ fun t ->
  let surface = apply_model_readiness_to_surface result t.surface in
  ({ t with model_readiness_request = None; surface }, [])

let load_configuration_result request result t =
  guard_request t.configuration_request request t @@ fun t ->
  let update screen =
    match result with
    | Ok value -> Settings_screen.configuration_loaded value screen
    | Error error ->
        Settings_screen.configuration_failed (error_text error) screen
  in
  let surface =
    match t.surface with
    | Screen (Settings screen) -> Screen (Settings (update screen))
    | Panel (Model model) ->
        let return = map_settings_return update model.return in
        Panel (Model { model with return })
    | surface -> surface
  in
  ({ t with configuration_request = None; surface }, [])

(* Fold a workspace-glance poll only while its request is the current one. A
   fresh observation replaces the held one; a failure keeps the previous glance
   (retry-in-place, never a flash of blank), and a stale result is dropped. *)
let load_workspace_glance_result request result t =
  guard_request t.glance_request request t @@ fun t ->
  let t = { t with glance_request = None } in
  match result with
  | Ok value -> ({ t with glance = Some value }, [])
  | Error _ -> (t, [])

(* The status tick's fold: the same replace-on-success law over the dune half
   alone. *)
let load_workspace_dune_result request result t =
  guard_request t.dune_request request t @@ fun t ->
  let t = { t with dune_request = None } in
  match result with
  | Ok status -> ({ t with dune_status = Some status }, [])
  | Error _ -> (t, [])

(* Fold a running-processes poll only while its request is current and its
   session still matches — a stale poll from a since-switched session is dropped.
   A fresh observation replaces the held list; a failure keeps the previous one,
   the poll being ambient like the workspace glance (it never surfaces an
   error). *)
let load_running_processes_result ~request ~session result t =
  guard_request_session t.running_request request ~session t @@ fun t ->
  let t = { t with running_request = None } in
  match result with
  | Ok views -> ({ t with running = views }, [])
  | Error _ -> (t, [])

let refresh_session_screen t =
  match t.surface with
  | Screen (Sessions _) ->
      let request, t = fresh_request t in
      ( { t with screen_sessions_request = Some request },
        [ Load_screen_sessions request ] )
  | Conversing | Panel _ | Screen (Settings _ | Review _) -> (t, [])

(* A drill composer submission owns its own [drill_prompt] request, distinct
   from the observation's [drill_request]. Its admission is silent — the child
   turn's facts arrive on the drill feed — and only its failure surfaces. *)
let drill_prompt_pending request t =
  match t.drill with
  | Some drill -> Option.exists (same_request request) drill.drill_prompt
  | None -> false

let clear_drill_prompt t =
  match t.drill with
  | Some drill -> { t with drill = Some { drill with drill_prompt = None } }
  | None -> t

let command_succeeded_result request t =
  if drill_prompt_pending request t then (clear_drill_prompt t, [])
  else
    match
      List.find_opt
        (fun pending -> same_request pending.pending_token request)
        t.pending
    with
    | Some { pending_kind = Model_selection { session; model; effort }; _ } ->
        let _, t = take_pending request t in
        let active =
          Option.exists
            (fun current -> Session.Id.equal current session)
            t.active_session
        in
        if active then
          (* The engine accepted the selector for [session]'s next turn. Record it
           as the model line so the footer, home banner, and picker immediately
           reflect the model the next turn will use — the visible acknowledgement
           replaces the transient flash, and the new model's catalog window keeps
           the context fill honest instead of going dark until [Turn_started]
           refines it. A completion for a session that is no longer active must
           not rewrite presentation. *)
          let context_window =
            match Mentat_provider.Selector.of_string model with
            | Ok selector -> model_context_window t selector
            | Error _ -> None
          in
          ( {
              t with
              current_snapshot =
                Snapshot.with_model ~model ~effort ?context_window
                  t.current_snapshot;
              flash = None;
            },
            [] )
        else (t, [])
    | Some { pending_kind = Queue_edit _; _ } ->
        let _, t = take_pending request t in
        (t, [])
    | Some { pending_kind = Submission; _ } ->
        let _, t = take_pending request t in
        ({ t with flash = None }, [])
    | Some
        {
          pending_kind =
            Start | Resume | Fork _ | Rewind _ | Answer _ | Local_shell | Editor;
          _;
        } ->
        (t, [])
    | Some { pending_kind = Compact _; _ } -> (t, [])
    | Some { pending_kind = Rename | Archive | Restore | Delete; _ } ->
        let _, t = take_pending request t in
        refresh_session_screen t
    | None -> (t, [])

let child_request_pending request t =
  List.exists
    (fun entry -> Option.exists (same_request request) entry.child_pending)
    t.children
  ||
  match t.drill with
  | Some drill -> Option.exists (same_request request) drill.drill_request
  | None -> false

let clear_child_request request error t =
  let children =
    List.map
      (fun entry ->
        match entry.child_pending with
        | Some current when same_request current request ->
            {
              entry with
              child_pending = None;
              child_closed = true;
              child_error = Some error;
            }
        | None | Some _ -> entry)
      t.children
  in
  let drill =
    match t.drill with
    | Some drill when Option.exists (same_request request) drill.drill_request
      ->
        Some { drill with drill_request = None; drill_error = Some error }
    | drill -> drill
  in
  { t with children; drill }

let session_mutation_failed error t =
  match t.surface with
  | Screen (Sessions screen) ->
      {
        t with
        surface =
          Screen
            (Sessions
               (Sessions_screen.mutation_failed (error_text error) screen));
        flash = None;
      }
  | Conversing | Panel _ | Screen (Settings _ | Review _) ->
      command_error error t

let command_failed_result request error t =
  if drill_prompt_pending request t then
    (clear_drill_prompt { t with flash = Some (error_text error) }, [])
  else
    let child_pending = child_request_pending request t in
    let pending, t = take_pending request t in
    match pending with
    | None when not child_pending -> (t, [])
    | Some { pending_kind = Model_selection { session; _ }; _ } ->
        if
          Option.exists
            (fun current -> Session.Id.equal current session)
            t.active_session
        then (command_error error t, [])
        else (t, [])
    | Some { pending_kind = Start | Submission; _ } ->
        let t = clear_child_request request error t |> command_error error in
        ( remove_pending_kind
            (function Start | Submission -> true | _ -> false)
            t,
          [] )
    | Some { pending_kind = Answer decision; _ } ->
        let t = clear_child_request request error t in
        let active =
          match t.surface with
          | Panel (Dialog dialog) ->
              Session.Decision.Id.equal decision
                (exact_decision_id (Dialog.requested dialog))
          | Conversing
          | Panel (Session_switch _ | Model _ | Theme _ | Auth _)
          | Screen _ ->
              false
        in
        ((if active then command_error error t else t), [])
    | Some { pending_kind = Local_shell | Editor; _ } ->
        let t = clear_child_request request error t |> command_error error in
        (t, [])
    | Some { pending_kind = Queue_edit { optimistic; rollback }; _ } ->
        let t =
          if
            Draft.History_entry.equal optimistic
              (Composer.history_entry t.composer)
          then restore_draft rollback t
          else t
        in
        (command_error error t, [])
    | Some { pending_kind = Rename | Archive | Restore | Delete; _ } ->
        let t = clear_child_request request error t in
        (session_mutation_failed error t, [])
    | Some { pending_kind = Rewind { draft; _ }; _ } ->
        (* A rewind or its follow failed before the child was admitted: the feed
           is untouched and nothing was discarded, so restore the edited message
           to the composer rather than leaving it only in prompt history. *)
        let t = clear_child_request request error t |> command_error error in
        (restore_draft draft t, [])
    | Some { pending_kind = Resume | Fork _ | Compact _; _ } ->
        let t = clear_child_request request error t |> command_error error in
        (t, [])
    | None ->
        let t = clear_child_request request error t |> command_error error in
        (t, [])

let session_followed_result ~request ~session ~possibly_mutating t =
  match
    List.find_opt
      (fun pending -> same_request pending.pending_token request)
      t.pending
  with
  | Some { pending_kind = Resume; _ } ->
      let _, t = take_pending request t in
      let t, retire = activate_session session t in
      let t =
        { t with main_feed = Some (session, request); possibly_mutating }
      in
      let t, view = issue_session_view session t in
      let t, decision = issue_pending_decision session t in
      let t, glance = issue_workspace_status t in
      let t, running = issue_running_processes session t in
      (t, retire @ [ view; decision ] @ glance @ [ running ])
  | Some { pending_kind = Fork { parent }; _ } ->
      let _, t = take_pending request t in
      let t, retire = activate_session session t in
      let t =
        { t with main_feed = Some (session, request); possibly_mutating }
        |> update_chat
             (append_notice
                (Notice.Seam
                   (Printf.sprintf "forked %s · from %s"
                      (Session.Id.to_string session)
                      (Session.Id.to_string parent))))
      in
      let t, view = issue_session_view session t in
      let t, decision = issue_pending_decision session t in
      let t, glance = issue_workspace_status t in
      let t, running = issue_running_processes session t in
      (t, retire @ [ view; decision ] @ glance @ [ running ])
  | Some { pending_kind = Rewind { source; _ }; _ } ->
      let _, t = take_pending request t in
      let t, retire = activate_session session t in
      let t =
        { t with main_feed = Some (session, request); possibly_mutating }
        |> update_chat
             (append_notice
                (Notice.Seam
                   (Printf.sprintf "rewound %s · from %s · files not reverted"
                      (Session.Id.to_string session)
                      (Session.Id.to_string source))))
      in
      let t, view = issue_session_view session t in
      let t, decision = issue_pending_decision session t in
      let t, glance = issue_workspace_status t in
      let t, running = issue_running_processes session t in
      (t, retire @ [ view; decision ] @ glance @ [ running ])
  | Some { pending_kind = Start; _ } when Option.is_none t.active_session ->
      let t =
        {
          t with
          active_session = Some session;
          main_feed = Some (session, request);
          observation_lost = false;
          flash = None;
          possibly_mutating;
        }
      in
      let t, view = issue_session_view session t in
      let t, decision = issue_pending_decision session t in
      let t, glance = issue_workspace_status t in
      let t, running = issue_running_processes session t in
      (t, [ view; decision ] @ glance @ [ running ])
  | Some _ | None -> (t, [])

let owns_main_feed ~session ~request t =
  match t.main_feed with
  | Some (current_session, current_request) ->
      Session.Id.equal session current_session
      && equal_request request current_request
  | None -> false

let compaction_result request result t =
  match
    List.find_opt
      (fun pending -> same_request pending.pending_token request)
      t.pending
  with
  | Some { pending_kind = Compact _; _ } -> (
      let _, t = take_pending request t in
      match result with
      | Error error -> (command_error error t, [])
      | Ok Mentat_client.Installed -> (t, [])
      | Ok Mentat_client.Skipped ->
          ( update_chat
              (append_notice
                 (Notice.Event "compaction skipped · context already compact"))
              t,
            [] ))
  | Some _ | None -> (t, [])

let settings_mutation_result request result t =
  let surface =
    match t.surface with
    | Screen (Settings screen) ->
        Screen
          (Settings (Settings_screen.mutation_finished request result screen))
    | surface -> surface
  in
  ({ t with surface }, [])

let history_loaded_result request (loaded : History.loaded) t =
  guard_request t.history_request request t @@ fun t ->
  let drafts = List.map History.Entry.draft loaded.History.entries in
  let composer = Composer.with_history drafts t.composer in
  let flash =
    match loaded.History.rejected with
    | [] -> t.flash
    | rejection :: _ ->
        Some
          (Printf.sprintf "history line %d ignored: %s" rejection.History.line
             (History.Error.message rejection.History.error))
  in
  ( {
      t with
      history = loaded.History.entries;
      history_request = None;
      composer;
      flash;
    },
    [] )

let user_commands_loaded_result request result t =
  guard_request t.user_commands_request request t @@ fun t ->
  let t = { t with user_commands_request = None } in
  match result with
  | Ok commands -> ({ t with user_commands = commands }, [])
  (* A failed load is benign: keep the previous snapshot rather than
     surfacing an error for a completion catalog. *)
  | Error _ -> (t, [])

(* The expansion of a custom command drives an ordinary user turn: the invocation
   [entry] records [/name args] in history while the expanded text is submitted
   through the same path a typed prompt takes, in the main composer or the active
   drill. An empty or blank expansion, or a client error, is a non-fatal flash
   and no turn is sent — the same empty-prompt guard a typed blank prompt hits. *)
let command_expanded_result ~entry result t =
  let blank () =
    ({ t with flash = Some "the command expanded to an empty prompt" }, [])
  in
  match result with
  | Ok [] -> blank ()
  | Ok content -> (
      let text = content_to_text content in
      if String.equal (String.trim text) "" then blank ()
      else
        match t.drill with
        | Some drill -> submit_drill_prompt ~entry text drill t
        | None -> submit_prompt ~entry text t)
  | Error error ->
      ( {
          t with
          flash =
            Some (Mentat_diagnostic.to_string (Protocol.Error.diagnostic error));
        },
        [] )

let files_loaded_result ~request result t =
  if not (Option.exists (same_request request) t.enumeration_request) then
    (t, [])
  else
    let t = { t with enumeration_request = None } in
    match t.completion with
    | Mention mention ->
        let mention = Mention.loaded result mention in
        ({ t with completion = Mention mention }, [])
    | No_completion | Commands _ | History_search _ -> (t, [])

let local_shell_result request result t =
  match
    List.find_opt
      (function
        | { pending_token; pending_kind = Local_shell } ->
            same_request pending_token request
        | _ -> false)
      t.pending
  with
  | Some _ -> (
      let _, t = take_pending request t in
      match result with
      | Ok block ->
          ( update_chat
              (fun chat ->
                {
                  chat with
                  chat_document =
                    Transcript.append chat.chat_document (Transcript.tool block);
                })
              { t with flash = None },
            [] )
      | Error diagnostic -> (capability_error diagnostic t, []))
  | None -> (t, [])

(* Fold the editor round-trip. On success the returned buffer replaces the draft
   as a plain draft (cursor at end); on failure the draft is left untouched and
   the structured error surfaces as a transient notice. *)
let editor_result request result t =
  match
    List.find_opt
      (function
        | { pending_token; pending_kind = Editor } ->
            same_request pending_token request
        | _ -> false)
      t.pending
  with
  | Some _ -> (
      let _, t = take_pending request t in
      match result with
      | Ok text -> (set_draft text { t with flash = None }, [])
      | Error diagnostic -> (capability_error diagnostic t, []))
  | None -> (t, [])

let auth_attempt_is_active attempt panel =
  Option.exists (( = ) attempt) (Auth_panel.active_attempt panel)

(* Settle a login whose flow persisted [account]. Account readiness always
   refreshes. When [account] is usable and no usable account existed before it —
   the fresh-install state where every declared account was missing — this
   credential is the first that can run a turn, yet the launch model may still
   name a provider that is not signed in, so we hand off to the model picker to
   answer "now what?". With a usable account already present the running model
   works and a picker on every login would be noise, so we stay put. A saved but
   blocked credential leaves the account unusable and also stays put. The rule is
   uniform across the API-key, browser, and device-code settle paths. *)
let settle_saved_login account t =
  let first_usable = Account.connected account && t.all_accounts_missing in
  let t, readiness = issue_account_readiness t in
  if first_usable then
    let t, model = open_model ~return:To_chat t in
    (t, readiness :: model)
  else (t, [ readiness ])

let auth_login_step_result attempt step t =
  match t.surface with
  | Panel (Auth panel) ->
      let active = auth_attempt_is_active attempt panel in
      let panel, event = Auth_panel.login_step ~attempt step panel in
      let accepted =
        active && Option.is_none (Auth_panel.active_attempt panel)
      in
      let t, commands = apply_auth_event event panel t in
      if accepted then
        match step with
        | Mentat_client.Login.Saved account ->
            let t, settle = settle_saved_login account t in
            (t, commands @ settle)
        | Mentat_client.Login.Progress _ | Mentat_client.Login.Cancelled ->
            (t, commands)
      else (t, commands)
  | Conversing
  | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
  | Screen _ ->
      (t, [])

let auth_login_failed_result attempt error t =
  match t.surface with
  | Panel (Auth panel) ->
      let panel = Auth_panel.login_failed ~attempt error panel in
      ({ t with surface = Panel (Auth panel) }, [])
  | Conversing
  | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
  | Screen _ ->
      (t, [])

let auth_save_api_key_result attempt result t =
  match t.surface with
  | Panel (Auth panel) -> (
      let active = auth_attempt_is_active attempt panel in
      let panel = Auth_panel.save_api_key_finished ~attempt result panel in
      let accepted =
        active && Option.is_none (Auth_panel.active_attempt panel)
      in
      let t = { t with surface = Panel (Auth panel) } in
      match (accepted, result) with
      | true, Ok account -> settle_saved_login account t
      | false, _ | true, Error _ -> (t, []))
  | Conversing
  | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
  | Screen _ ->
      (t, [])

let auth_logout_result attempt result t =
  match t.surface with
  | Panel (Auth panel) -> (
      let active = auth_attempt_is_active attempt panel in
      let panel = Auth_panel.logout_finished ~attempt result panel in
      let accepted =
        active && Option.is_none (Auth_panel.active_attempt panel)
      in
      let t = { t with surface = Panel (Auth panel) } in
      match (accepted, result) with
      | true, Ok _ ->
          let t, readiness = issue_account_readiness t in
          (t, [ readiness ])
      | false, _ | true, Error _ -> (t, []))
  | Conversing
  | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
  | Screen _ ->
      (t, [])

let auth_url_result attempt result t =
  match t.surface with
  | Panel (Auth panel) ->
      let panel =
        match result with
        | Ok () -> Auth_panel.url_opened ~attempt panel
        | Error message -> Auth_panel.url_open_failed ~attempt ~message panel
      in
      ({ t with surface = Panel (Auth panel) }, [])
  | Conversing
  | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
  | Screen _ ->
      (t, [])

(* Ctrl+D opens the review surface focused on the latest change's file, so the
   diff is read in one place. The composer only offers the chord while changes
   exist, so [[]] is defensive. *)
let open_latest_change t =
  match List.rev t.changes with
  | change :: _ ->
      let focus = Change.path change |> Mentat_workspace.Path.rel in
      open_review ~focus t
  | [] -> ({ t with flash = Some "no mutation changes yet" }, [])

let page_transcript direction chat =
  {
    chat with
    next_page = chat.next_page + 1;
    page = Some (chat.next_page, direction);
  }

let acknowledge_transcript_page serial chat =
  match chat.page with
  | Some (current, _) when current = serial -> { chat with page = None }
  | None | Some _ -> chat

let acknowledge_transcript_tail_reset request chat =
  match chat.tail_reset with
  | Some current when same_request current request ->
      { chat with tail_reset = None }
  | None | Some _ -> chat

let discard_draft t =
  let composer, events = Composer.update Composer.Clear_to_history t.composer in
  List.fold_left
    (fun (t, commands) event ->
      let t, more = composer_event event t in
      (t, commands @ more))
    ( {
        t with
        composer;
        completion = No_completion;
        armed = None;
        rewind = None;
      },
      [] )
    events

let quit_or_discard t =
  if not (Composer.is_blank t.composer) then discard_draft t
  else
    match t.armed with
    | Some Quit_armed -> ({ t with armed = None }, [ Quit ])
    | Some Clear_armed | Some Interrupt_armed | None ->
        ({ t with armed = Some Quit_armed }, [])

let escape t =
  match t.undo_armed with
  (* R0: while an undo is armed, Escape cancels it — a driver round-trip that
     un-reverts the files and releases the boundary. Unlike the rewind rung this
     performs IO; the composer draft is restored when the [Released] fact lands,
     and the round-trip can flash a failure. *)
  | Some _ -> (
      match t.active_session with
      | Some session ->
          let request, t = fresh_request t in
          (t, [ Undo_step { request; session; op = `Cancel } ])
      | None -> ({ t with undo_armed = None }, []))
  | None -> (
      match t.rewind with
      (* R1: while a rewind is armed, a single Escape is the new top rung of the
         ladder — it cancels the arming, restores the replaced draft, and consumes
         the key rather than falling through to the non-blank draft-discard rung.
         The picker consumes Escape on the modal key path, so it never reaches
         here. *)
      | Some (Armed armed) -> cancel_rewind armed t
      | None | Some (Picking _) -> (
          match t.drill with
          | Some drill when Option.is_some drill.drill_focus ->
              ({ t with drill = Some { drill with drill_focus = None } }, [])
          | Some _ -> close_thread_drill t
          | None when Option.is_some t.strip_focus ->
              ({ t with strip_focus = None; strip_hover = None }, [])
          | None -> (
              match t.completion with
              | History_search { saved; _ } ->
                  let composer, _ =
                    Composer.update Composer.End_history_search t.composer
                  in
                  let composer, _ =
                    Composer.update (Composer.Restore_history saved) composer
                  in
                  ({ t with composer; completion = No_completion }, [])
              | Commands _ | Mention _ ->
                  ({ t with completion = No_completion }, [])
              | No_completion -> (
                  if t.help then ({ t with help = false }, [])
                  else if
                    Composer.input_mode t.composer = Composer.Input_mode.Shell
                    && Composer.is_blank t.composer
                  then
                    let composer, _ =
                      Composer.update Composer.Exit_shell t.composer
                    in
                    ({ t with composer; armed = None }, [])
                  else if not (Composer.is_blank t.composer) then
                    match t.armed with
                    | Some Clear_armed -> discard_draft t
                    | Some Quit_armed | Some Interrupt_armed | None ->
                        ({ t with armed = Some Clear_armed }, [])
                  else
                    match (local_shell_request t, t.phase) with
                    | Some request, _ -> (
                        match t.armed with
                        | Some Interrupt_armed ->
                            ( { t with armed = None },
                              [ Cancel_local_shell request ] )
                        | Some Quit_armed | Some Clear_armed | None ->
                            ({ t with armed = Some Interrupt_armed }, []))
                    | None, Chat chat when Turn.in_flight chat.chat_turn -> (
                        match t.armed with
                        | Some Interrupt_armed ->
                            ( {
                                t with
                                phase =
                                  Chat
                                    {
                                      chat with
                                      chat_turn =
                                        Turn.interrupting chat.chat_turn;
                                    };
                                armed = None;
                              },
                              match t.active_session with
                              | None -> []
                              | Some session -> [ Interrupt { session } ] )
                        | Some Quit_armed | Some Clear_armed | None ->
                            ({ t with armed = Some Interrupt_armed }, []))
                    | None, (Prelude | Chat _) -> (t, [])))))

let ctrl_c t =
  match t.surface with
  | Panel (Auth panel) -> (
      match Auth_panel.cancel_active panel with
      | Some (panel, event) -> apply_auth_event event panel t
      | None -> quit_or_discard t)
  | Conversing
  | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
  | Screen _ ->
      quit_or_discard t

let shift_tab t =
  let mode =
    match t.draft_mode with
    | Session.Contract.Mode.Build -> Session.Contract.Mode.Plan
    | Session.Contract.Mode.Plan | Session.Contract.Mode.Review ->
        Session.Contract.Mode.Build
  in
  ({ t with draft_mode = mode }, [])

let frame_tick dt t =
  if (not (Float.is_finite dt)) || dt < 0. then
    invalid_arg "App.update: frame delta must be finite and nonnegative";
  let interval = 0.08 in
  let accum = t.frame_accum +. dt in
  let rec advance motion accum =
    if accum < interval then (motion, accum)
    else advance (Home.Motion.tick motion) (accum -. interval)
  in
  let motion, frame_accum = advance t.motion accum in
  ({ t with motion; frame_accum }, [])

(* Route a resolved sessions or review verb into its focused screen's own update,
   the same seam a classified key uses. The registry owns the chord -> action
   mapping; the screen owns the action -> effect interpretation. *)
let dispatch_sessions_verb verb t =
  match t.surface with
  | Screen (Sessions screen) ->
      update_sessions_screen (Sessions_screen.verb verb) screen t
  | Conversing | Panel _ | Screen (Settings _ | Review _) -> (t, [])

let dispatch_review_verb verb t =
  match t.surface with
  | Screen (Review screen) ->
      update_review_screen (Review_screen.verb verb) screen t
  | Conversing | Panel _ | Screen (Sessions _ | Settings _) -> (t, [])

(* The total registry dispatcher: the folded gestures reach their effect
   functions here, the per-screen verbs route into their screen, and the slash
   fates fall to the slash dispatcher. It backs the forward reference the slash
   dispatcher and the command palette call. *)
let dispatch_registry_impl ?argument command t =
  match Command.fate command with
  | Command.Interrupt -> escape t
  | Command.Toggle_expanded -> (
      match t.phase with
      | Prelude -> (t, [])
      | Chat chat ->
          ( { t with phase = Chat { chat with expanded = not chat.expanded } },
            [] ))
  | Command.Transcript_page direction ->
      (update_chat (page_transcript direction) t, [])
  | Command.History_search -> begin_history_search t
  | Command.Focus_switch -> shift_tab t
  | Command.Edit_in_editor -> request_editor t
  | Command.Open_palette -> open_command_palette t
  | Command.Copy_selection -> (t, [ Copy_selection ])
  | Command.Sessions_fork -> dispatch_sessions_verb `Fork t
  | Command.Sessions_rename -> dispatch_sessions_verb `Rename t
  | Command.Sessions_archive -> dispatch_sessions_verb `Archive t
  | Command.Sessions_restore -> dispatch_sessions_verb `Restore t
  | Command.Sessions_delete -> dispatch_sessions_verb `Delete t
  | Command.Review_toggle -> dispatch_review_verb `Toggle t
  | Command.Review_verdict -> dispatch_review_verb `Verdict t
  | Command.Review_help -> dispatch_review_verb `Help t
  | Command.Review_compose which -> dispatch_review_verb (`Compose which) t
  | Command.Review_remove -> dispatch_review_verb `Remove t
  | Command.Review_next_hunk -> dispatch_review_verb `Next_hunk t
  | Command.Review_prev_hunk -> dispatch_review_verb `Prev_hunk t
  | Command.Review_next_cr -> dispatch_review_verb `Next_cr t
  | Command.Review_prev_cr -> dispatch_review_verb `Prev_cr t
  | Command.Clear_session | Command.Fork_session | Command.Rewind_session
  | Command.Undo_session | Command.Redo_session | Command.Compact_session
  | Command.Rename_session | Command.Open_model
  | Command.Open_theme | Command.Open_sessions | Command.Open_settings _
  | Command.Open_login | Command.Open_logout | Command.Switch_mode _
  | Command.Toggle_thinking | Command.Toggle_verbose | Command.Open_review
  | Command.Dune_command | Command.Init_project _ | Command.Quit ->
      dispatch_command ?argument command t

let () = dispatch_registry_hook := dispatch_registry_impl

let update msg t =
  (* Any resolved key gesture other than arming clears the two-press chord latch;
     timers and feed events leave it untouched so a slow chord still completes. *)
  let t =
    match msg with
    | Arm_chord _ -> t
    | Ctrl_c | Escape | Toggle_expanded | Begin_history_search | Shift_tab
    | Transcript_paged _ | Edit_in_editor_requested | Disarm_chord
    | Run_command _ | Open_command_palette ->
        { t with pending_chord = None }
    | _ -> t
  in
  match msg with
  (* The agent switcher and the composer share one set of key bindings across the
     main view and a drill. Whichever surface is on screen exposes its own strip
     focus through [active_strip_focus]: [Tab] hands keyboard focus to the
     switcher and back, focused arrows walk it, [Enter] activates the selection,
     and while the composer owns the arrows they stay on prompt-history recall.
     No parent selection bleeds into a drill; the drill keeps its own focus. *)
  | Composer_msg (Composer.Submit _)
    when Option.is_some (active_strip_focus t) && not (completion_open t) ->
      activate_active_focus t
  | Composer_msg (Composer.List_key ((`Up | `Down) as direction))
    when Option.is_some (active_strip_focus t)
         && Composer.is_blank (active_composer t)
         && not (completion_open t) ->
      move_active_focus direction t
  | Composer_msg (Composer.List_key `Tab)
    when (not (completion_open t))
         && Composer.is_blank (active_composer t)
         && t.children <> [] ->
      toggle_active_focus t
  | Composer_msg message -> update_composer message t
  | Palette_msg message -> update_palette message t
  | Mention_msg message -> update_mention message t
  | History_search_msg message -> update_history_search message t
  | Threads_strip_msg message -> update_threads_strip message t
  | Frame_tick dt -> frame_tick dt t
  | Clock_tick -> ({ t with now = t.now +. 1. }, [])
  | Resized { cols; rows } -> ({ t with cols; rows }, [])
  | Turn_tick ->
      (update_chat (fun chat -> { chat with spinner = chat.spinner + 1 }) t, [])
  | Flash_expired -> ({ t with flash = None }, [])
  | Armed_expired -> ({ t with armed = None }, [])
  | Ctrl_c -> ctrl_c t
  | Escape -> escape t
  | Toggle_expanded -> (
      match t.phase with
      | Prelude -> (t, [])
      | Chat chat ->
          ( { t with phase = Chat { chat with expanded = not chat.expanded } },
            [] ))
  | Begin_history_search -> begin_history_search t
  | Shift_tab -> shift_tab t
  | Arm_chord command -> ({ t with pending_chord = Some command }, [])
  | Disarm_chord -> (t, [])
  | Run_command command -> dispatch_registry command t
  | Open_command_palette -> open_command_palette t
  | Edit_in_editor_requested -> request_editor t
  | Terminal_focus focused -> ({ t with terminal_focused = focused }, [])
  | Color_scheme scheme -> (
      (* Follow the terminal's reported scheme only while auto is armed; a hand
         pick has already disarmed it, so a late or unsolicited reply is dropped
         rather than overriding the deliberate palette. *)
      match t.theme_auto with
      | Some { auto_armed = true; auto_dark; auto_light; _ } ->
          let palette =
            match scheme with `Dark -> auto_dark | `Light -> auto_light
          in
          (set_palette palette t, [])
      | Some _ | None -> (t, []))
  | Transcript_paged direction -> (update_chat (page_transcript direction) t, [])
  | Transcript_page_applied serial ->
      (update_chat (acknowledge_transcript_page serial) t, [])
  | Transcript_tail_reset_applied request ->
      (update_chat (acknowledge_transcript_tail_reset request) t, [])
  | Fact { session; request; now; fact } ->
      if owns_main_feed ~session ~request t then fold_fact ~now fact t
      else (t, [])
  | Progress { session; request; now; progress } ->
      if owns_main_feed ~session ~request t then fold_progress ~now progress t
      else (t, [])
  | Feed_failed { session; request; message; login_needed } ->
      if not (owns_main_feed ~session ~request t) then (t, [])
      else
        let t =
          update_chat
            (append_failure ~next_step:"check the connection, then retry"
               message)
            {
              (remove_pending_kind
                 (function
                   | Start | Submission | Queue_edit _ -> true | _ -> false)
                 t)
              with
              main_feed = None;
              flash = Some message;
              observation_lost = true;
            }
        in
        if login_needed then open_auth Auth_panel.Mode.Login None t else (t, [])
  | Operation_failed { message; login_needed } ->
      let t =
        update_chat
          (append_failure ~next_step:"check the connection, then retry" message)
          {
            (remove_pending_kind (function Submission -> true | _ -> false) t) with
            flash = Some message;
          }
      in
      if login_needed then open_auth Auth_panel.Mode.Login None t else (t, [])
  | Session_followed { request; session; possibly_mutating } ->
      session_followed_result ~request ~session ~possibly_mutating t
  | Command_succeeded request -> command_succeeded_result request t
  | Command_failed (request, error) -> command_failed_result request error t
  | Compaction_finished (request, result) -> compaction_result request result t
  | Settings_mutation_finished (request, result) ->
      settings_mutation_result request result t
  | Capability_failed (request, diagnostic) ->
      if pending_request request t then
        let _, t = take_pending request t in
        (capability_error diagnostic t, [])
      else (t, [])
  | Attached (request, result) -> attached_result request result t
  | Home_sessions_loaded (request, result) -> load_home_result request result t
  | Quick_sessions_loaded (request, result) ->
      load_quick_result request result t
  | Screen_sessions_loaded (request, result) ->
      load_screen_result request result t
  | Session_view_loaded { request; session; result } ->
      load_session_view_result ~request ~session result t
  | Pending_decision_loaded { request; session; result } ->
      load_pending_decision_result ~request ~session result t
  | Configuration_loaded (request, result) ->
      load_configuration_result request result t
  | Workspace_glance_loaded (request, result) ->
      load_workspace_glance_result request result t
  | Workspace_dune_loaded (request, result) ->
      load_workspace_dune_result request result t
  | Workspace_dune_tick ->
      if Option.is_some t.dune_request then (t, [])
      else
        let t, command = issue_workspace_dune t in
        (t, [ command ])
  | Running_processes_loaded { request; session; result } ->
      load_running_processes_result ~request ~session result t
  | Account_readiness_loaded (request, result) ->
      load_account_readiness_result request result t
  | Model_readiness_loaded (request, result) ->
      load_model_readiness_result request result t
  | Review_state_loaded (request, result) ->
      fold_review_completion ~request
        (Review_screen.state_loaded (Result.map_error review_error result))
        t
  | Review_diff_loaded { request; path; result } ->
      fold_review_completion ~request
        (Review_screen.diff_loaded path (Result.map_error review_error result))
        t
  | Review_crs_loaded (request, result) ->
      fold_review_completion ~request
        (Review_screen.crs_loaded (Result.map_error review_error result))
        t
  | Review_command_finished (request, result) ->
      fold_review_completion ~request
        (Review_screen.command_done (Result.map_error review_error result))
        t
  | Review_compose_finished (request, result) ->
      fold_review_completion ~request
        (Review_screen.compose_done (Result.map_error review_error result))
        t
  | Review_screen_msg message -> (
      match t.surface with
      | Screen (Review screen) -> update_review_screen message screen t
      | Conversing | Panel _ | Screen (Sessions _ | Settings _) ->
          (t, []))
  | Sessions_panel_msg message -> (
      match t.surface with
      | Panel (Session_switch panel) -> update_sessions_panel message panel t
      | Conversing | Panel (Model _ | Theme _ | Dialog _ | Auth _) | Screen _ ->
          (t, []))
  | Rewind_panel_msg message -> (
      match t.rewind with
      | Some (Picking picker) -> update_rewind_panel message picker t
      | Some (Armed _) | None -> (t, []))
  | Sessions_screen_msg message -> (
      match t.surface with
      | Screen (Sessions screen) -> update_sessions_screen message screen t
      | Conversing | Panel _ | Screen (Settings _ | Review _) -> (t, [])
      )
  | Settings_screen_msg message -> (
      match t.surface with
      | Screen (Settings screen) -> update_settings_screen message screen t
      | Conversing | Panel _ | Screen (Sessions _ | Review _) -> (t, [])
      )
  | Settings_paste text -> (
      match t.surface with
      | Screen (Settings screen) ->
          ( {
              t with
              surface = Screen (Settings (Settings_screen.paste text screen));
            },
            [] )
      | Conversing | Panel _ | Screen (Sessions _ | Review _) -> (t, [])
      )
  | Model_panel_msg message -> (
      match t.surface with
      | Panel (Model model) -> update_model_panel message model t
      | Conversing
      | Panel (Session_switch _ | Theme _ | Dialog _ | Auth _)
      | Screen _ ->
          (t, []))
  | Model_paste text -> (
      match t.surface with
      | Panel (Model model) ->
          let model =
            { model with state = Model_panel.paste text model.state }
          in
          ({ t with surface = Panel (Model model) }, [])
      | Conversing
      | Panel (Session_switch _ | Theme _ | Dialog _ | Auth _)
      | Screen _ ->
          (t, []))
  | Theme_panel_msg message -> (
      match t.surface with
      | Panel (Theme panel) -> update_theme_panel message panel t
      | Conversing
      | Panel (Session_switch _ | Model _ | Dialog _ | Auth _)
      | Screen _ ->
          (t, []))
  | Theme_paste text -> (
      match t.surface with
      | Panel (Theme panel) ->
          let picker, event = Theme_panel.paste text panel.theme_picker in
          theme_panel_event { panel with theme_picker = picker } event t
      | Conversing
      | Panel (Session_switch _ | Model _ | Dialog _ | Auth _)
      | Screen _ ->
          (t, []))
  | Ui_theme_persisted (_, result) -> (
      match result with
      | Error error ->
          ( { t with flash = Some ("theme save failed · " ^ error_text error) },
            [] )
      | Ok None -> (t, [])
      | Ok (Some (layer, value)) ->
          ( {
              t with
              flash =
                Some
                  (Printf.sprintf
                     "saved to user config, but %s pins tui.theme = %s" layer
                     value);
            },
            [] ))
  | Dialog_msg message -> (
      match t.surface with
      | Panel (Dialog dialog) -> update_dialog_message message dialog t
      | Conversing
      | Panel (Session_switch _ | Model _ | Theme _ | Auth _)
      | Screen _ ->
          (t, []))
  | Dialog_key key -> (
      match t.surface with
      | Panel (Dialog dialog) -> update_dialog_key key dialog t
      | Conversing
      | Panel (Session_switch _ | Model _ | Theme _ | Auth _)
      | Screen _ ->
          (t, []))
  | Auth_panel_msg message -> (
      match t.surface with
      | Panel (Auth panel) -> update_auth_panel message panel t
      | Conversing
      | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
      | Screen _ ->
          (t, []))
  | Auth_paste text -> (
      match t.surface with
      | Panel (Auth panel) ->
          ({ t with surface = Panel (Auth (Auth_panel.paste text panel)) }, [])
      | Conversing
      | Panel (Session_switch _ | Model _ | Theme _ | Dialog _)
      | Screen _ ->
          (t, []))
  | Auth_login_step (attempt, step) -> auth_login_step_result attempt step t
  | Auth_login_failed (attempt, error) ->
      auth_login_failed_result attempt error t
  | Auth_save_api_key_finished (attempt, result) ->
      auth_save_api_key_result attempt result t
  | Auth_logout_finished (attempt, result) ->
      auth_logout_result attempt result t
  | Auth_url_opened attempt -> auth_url_result attempt (Ok ()) t
  | Auth_url_open_failed (attempt, message) ->
      auth_url_result attempt (Error message) t
  | Prompt_history_loaded (request, loaded) ->
      history_loaded_result request loaded t
  | User_commands_loaded (request, result) ->
      user_commands_loaded_result request result t
  | Command_expanded { request = _; entry; result } ->
      command_expanded_result ~entry result t
  | Files_loaded { request; result } -> files_loaded_result ~request result t
  | Local_shell_finished (request, result) ->
      local_shell_result request result t
  | Editor_finished (request, result) -> editor_result request result t
  | Child_observation_started { request; observation; child; generation } ->
      child_observation_started_result ~request ~observation ~child ~generation
        t
  | Child_feed { observation; generation; child; outcome } ->
      child_feed_result ~observation ~generation ~child outcome t
  | Open_latest_change -> open_latest_change t

let account_absent t = t.all_accounts_missing

let app_notice t =
  match t.armed with
  | Some Quit_armed -> Some "press ctrl+c again to quit"
  | Some Clear_armed -> Some "press esc again to discard the draft"
  | Some Interrupt_armed -> Some "press esc again to interrupt"
  | None -> t.flash

let notice_row t =
  match app_notice t with
  | None -> None
  | Some message ->
      Some
        (box ~key:"app.notice" ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
           ~size:{ width = pct 100; height = auto }
           [
             text
               ~style:(Theme.Palette.warning_style t.palette)
               ~wrap:`None message;
           ])

(* Current context occupancy: the latest whole-response usage summed across every
   lane, as a share of the active model's context window. This is the live
   context fill, not the session's cumulative spend. The window is provider-owned
   and may be unknown, in which case the percent is withheld rather than guessed.
   It feeds both the compact footer glance and the pane's context section, so the
   two never disagree. *)
let workspace_context t =
  match t.last_usage with
  | None -> None
  | Some usage ->
      let used = Mentat_llm.Usage.sum_lanes usage in
      if used <= 0 then None
      else
        let percent =
          match Snapshot.context_window t.current_snapshot with
          | Some window when window > 0 ->
              Some
                (int_of_float
                   (Float.round (100. *. float used /. float window)))
          | Some _ | None -> None
        in
        Some (used, percent)

let footer t =
  match notice_row t with
  | Some notice -> notice
  | None ->
      Footer.view ~palette:t.palette ~permission_review:t.current_review
        ~input_mode:(Composer.input_mode t.composer)
        ~account_absent:(account_absent t) ?context:(workspace_context t)
        t.current_snapshot

let composer_element ?(top_margin = 1) t =
  let inspect_latest_change =
    match t.changes with [] -> None | _ :: _ -> Some Open_latest_change
  in
  Composer.render ~list_open:(completion_open t) ~mode:t.draft_mode
    ~turn_running:(turn_in_flight t) ~top_margin ?inspect_latest_change
    ~palette:t.palette
    ~on_msg:(fun message -> Composer_msg message)
    t.composer

let completion_rows t =
  match t.completion with
  | No_completion -> []
  | Commands palette ->
      let command_mode = command_palette_open t in
      let keybind = function
        | Palette.Builtin command -> Command.keybind t.overlay command
        | Palette.Custom _ -> None
      in
      [
        Palette.view ~palette:t.palette ~command_mode ~keybind palette
        |> Mosaic.map (fun message -> Palette_msg message);
      ]
  | Mention mention ->
      [
        Mention.view ~palette:t.palette mention
        |> Mosaic.map (fun message -> Mention_msg message);
      ]
  | History_search { search; _ } ->
      [
        History.Search.view ~palette:t.palette search
        |> Mosaic.map (fun message -> History_search_msg message);
      ]

let composer_region t =
  box ~key:"composer.region" ~flex_direction:Flex_direction.Column
    ~flex_shrink:0.
    ~size:{ width = pct 100; height = auto }
    (completion_rows t
    @ [
        composer_element
          ~top_margin:(if completion_open t || t.changes <> [] then 0 else 1)
          t;
      ])

let help_rows t = if t.help then [ Help.view ~palette:t.palette () ] else []

let queue_text queue =
  List.map (fun entry -> content_text (Session.Queue.Entry.input entry)) queue

let outcome_label outcome = Format.asprintf "%a" Session.Turn.Outcome.pp outcome

(* A drilled child's identity is its role (or the generic [subagent]) optionally
   followed by its short description. The role alone names the strip kind and the
   composer chip; the description rides the strip label and heap banner, where
   the full prompt would be too long. *)
let subagent_role_name edge =
  match Session.Delegation.role edge with
  | Some role -> Session.Delegation.Role.to_string role
  | None -> "subagent"

let subagent_identity edge =
  let name = subagent_role_name edge in
  match Session.Delegation.description edge with
  | Some description -> name ^ " — " ^ description
  | None -> name

let child_row ~palette entry =
  let glyph, style, facts =
    match
      ( entry.child_error,
        entry.child_projection.child_outcome,
        Turn.in_flight entry.child_projection.child_turn )
    with
    | Some _, _, _ ->
        ("!", Theme.Palette.error_style palette, [ "feed unavailable" ])
    | None, Some (Session.Turn.Outcome.Completed as outcome), _
    | None, Some (Session.Turn.Outcome.Step_limit as outcome), _ ->
        ("✓", Theme.Palette.success_style palette, [ outcome_label outcome ])
    | None, Some (Session.Turn.Outcome.Interrupted _ as outcome), _ ->
        ("■", Theme.Palette.warning_style palette, [ outcome_label outcome ])
    | None, Some (Session.Turn.Outcome.Failed _ as outcome), _ ->
        ("!", Theme.Palette.error_style palette, [ outcome_label outcome ])
    | None, None, _
      when Option.is_some
             (Turn.pending_decision entry.child_projection.child_turn) ->
        (Theme.waiting, Theme.Palette.warning_style palette, [ "blocked" ])
    | None, None, true ->
        ("◉", Theme.Palette.accent_style palette, [ "working" ])
    | None, None, false when entry.child_closed ->
        ("○", Theme.Palette.muted_style palette, [ "closed" ])
    | None, None, false ->
        ("○", Theme.Palette.muted_style palette, [ "delegated" ])
  in
  let label =
    match Session.Delegation.description entry.edge with
    | Some description -> description
    | None -> content_text (Session.Delegation.task entry.edge)
  in
  Threads_strip.Thread
    {
      glyph;
      style;
      kind = subagent_role_name entry.edge;
      task = label;
      facts;
      depth = entry.child_depth;
    }

let thread_rows t =
  Threads_strip.Main :: List.map (child_row ~palette:t.palette) t.children

let focused_child t =
  match t.strip_focus with
  | Some index when index > 0 -> List.nth_opt t.children (index - 1)
  | None | Some _ -> None

let thread_strip ~placement t =
  let can_open = Option.exists (fun index -> index > 0) t.strip_focus in
  (* Activation re-follows a lost feed in place rather than opening it, so the
     focused error row advertises the retry it actually performs; a focused
     blocked child advertises the review its drill raises. *)
  let activate_hint =
    match focused_child t with
    | Some entry when Option.is_some entry.child_error -> Some "enter to retry"
    | Some entry
      when Option.is_some
             (Turn.pending_decision entry.child_projection.child_turn) ->
        Some "enter to answer"
    | Some _ | None -> None
  in
  Threads_strip.view ~palette:t.palette ~placement ~can_open ?activate_hint
    ~hovered:t.strip_hover ~rows:(thread_rows t) ~selected:t.strip_focus ()
  |> List.map (Mosaic.map (fun message -> Threads_strip_msg message))

let agent_facts t =
  let running, blocked =
    List.fold_left
      (fun (running, blocked) entry ->
        match (entry.child_error, entry.child_projection.child_outcome) with
        | None, None ->
            if
              Option.is_some
                (Turn.pending_decision entry.child_projection.child_turn)
            then (running, blocked + 1)
            else if Turn.in_flight entry.child_projection.child_turn then
              (running + 1, blocked)
            else (running, blocked)
        | Some _, _ | _, Some _ -> (running, blocked))
      (0, 0) t.children
  in
  (if running = 0 then [] else [ Printf.sprintf "%d running" running ])
  @ if blocked = 0 then [] else [ Printf.sprintf "%d blocked" blocked ]

let task_facts board =
  let done_count, running_count =
    List.fold_left
      (fun (done_count, running_count) (item : Session.Task.Item.t) ->
        match item.Session.Task.Item.status with
        | Session.Task.Status.In_progress -> (done_count, running_count + 1)
        | Session.Task.Status.Completed | Session.Task.Status.Cancelled ->
            (done_count + 1, running_count)
        | Session.Task.Status.Pending -> (done_count, running_count))
      (0, 0)
      (Session.Task.Board.items board)
  in
  [
    Printf.sprintf "%d done" done_count;
    Printf.sprintf "%d running" running_count;
  ]

let board_section ~palette board =
  Pane_sections.section ~label:"tasks" ~facts:(task_facts board)
    (Todo_board.view ~count_header:false ~palette board)

let threads_section t =
  Pane_sections.section ~label:"agents" ~facts:(agent_facts t)
    (thread_strip ~placement:Threads_strip.Agents_pane t)

let workspace_changed t =
  match t.changes with
  | [] -> None
  | _ :: _ -> Some (Change.of_changes t.changes)

(* Cumulative session spend: the whole session's metered usage priced by the
   active model's catalog rate. It is distinct from the occupancy the [context]
   rows show, and it is withheld — never a fabricated zero — when the catalog
   carries no rate for the model. A view still describing a previous conversation
   contributes nothing. *)
let workspace_spent t =
  match (t.active_session, t.session_view) with
  | Some session, Some view when session_view_matches session view ->
      let usage = (Session.Session_view.metrics view).Session.Metrics.usage in
      let model =
        match
          Mentat_provider.Selector.of_string (Snapshot.model t.current_snapshot)
        with
        | Ok selector -> model_catalog t selector
        | Error _ -> None
      in
      Option.bind model (fun model -> Mentat_provider.Model.cost model usage)
  | _, None | None, _ | Some _, Some _ -> None

(* The two independent poll signals. The worktree diff is absent until the
   first glance returns; the tooling status defaults to [Off Disabled] (no
   row) until the first dune query returns, honoring the fail-honest law. *)
let workspace_worktree t =
  match t.glance with Some worktree -> worktree | None -> None

let workspace_tooling t =
  match t.dune_status with
  | Some status -> status
  | None -> Mentat_workspace.Health.Off Mentat_workspace.Health.Off.Disabled

(* The watch is worth following on a tick whenever one is live or coming up:
   a settled row must still follow an editor save between turns (the rebuild
   happens without any engine boundary), and a transitional one must resolve.
   Only an absent watch is not polled — the glance moments cover attachment. *)
let workspace_dune_followed t =
  match workspace_tooling t with
  | Mentat_workspace.Health.Probing | Mentat_workspace.Health.Starting
  | Mentat_workspace.Health.Restarting _ | Mentat_workspace.Health.Live _ ->
      true
  | Mentat_workspace.Health.Off _ -> false

let workspace_section t =
  Pane_sections.section ~label:"workspace"
    (Workspace_glance.trust ~palette:t.palette
       ~trusted:(Snapshot.trusted t.current_snapshot)
    @ Workspace_glance.worktree ~palette:t.palette
        ~worktree:(workspace_worktree t)
    @ Workspace_glance.changed ~palette:t.palette ~changed:(workspace_changed t)
    @ Workspace_glance.tooling ~palette:t.palette ~tooling:(workspace_tooling t)
    )

let context_section t =
  Pane_sections.section ~label:"context"
    (Workspace_glance.context ~palette:t.palette ~context:(workspace_context t)
       ~spent:(workspace_spent t))

let running_section t =
  Pane_sections.section ~label:"running"
    (Workspace_glance.running ~palette:t.palette ~running:t.running)

let pane_rows chat t =
  (* Established pane priority: workspace, context, and running processes
     (ambient), agents, then tasks. Each section renders only when it has live
     content, so an idle workspace or a childless run leaves no orphan heading. *)
  let sections =
    [ workspace_section t; context_section t; running_section t ]
    @ (if t.children = [] then [] else [ threads_section t ])
    @
    match chat.task_board with
    | None -> []
    | Some board -> [ board_section ~palette:t.palette board ]
  in
  Pane_sections.view ~palette:t.palette sections

let transcript_scrollport ?header ?(extra = []) ~key ~now ~show_reasoning
    ~palette ?compaction_started chat =
  let document =
    Transcript.view ~expanded:chat.expanded ~palette chat.chat_document
  in
  let tail =
    Turn.tail ~palette ~now ~show_reasoning ~expanded:chat.expanded
      chat.chat_turn
  in
  let working =
    Turn.working_line ~palette ~now ~spinner:chat.spinner chat.chat_turn
  in
  let compacting =
    Option.map
      (fun started ->
        Turn.compacting_line ~palette ~now ~spinner:chat.spinner ~started)
      compaction_started
  in
  let live =
    List.filter_map Fun.id [ tail; working; compacting ]
    |> List.map (fun element ->
        box ~flex_shrink:0. ~margin:(margin_lrtb 0 0 1 0)
          ~size:{ width = pct 100; height = auto }
          [ element ])
  in
  Scrollport.view ~key
    ?scroll_by:
      (Option.map
         (fun (serial, direction) ->
           {
             Mosaic.Scroll_box.key = key ^ "-page-" ^ string_of_int serial;
             x = None;
             y = Some (match direction with `Up -> -1. | `Down -> 1.);
             unit = `Viewport;
           })
         chat.page)
    ?on_scroll_by_applied:
      (Option.map
         (fun (serial, _) ~key:_ -> Some (Transcript_page_applied serial))
         chat.page)
    ?reset_sticky:
      (Option.map
         (fun request -> key ^ "-tail-" ^ Int64.to_string request)
         chat.tail_reset)
    ?on_reset_sticky_applied:
      (Option.map
         (fun request ~key:_ -> Some (Transcript_tail_reset_applied request))
         chat.tail_reset)
    ((Option.to_list header @ [ document ] @ extra) @ live)

let status_row ~palette ?(style = Theme.Palette.muted_style palette) label =
  box ~flex_shrink:0. ~padding:(padding_lrtb 2 1 0 0)
    ~size:{ width = pct 100; height = auto }
    [ text ~style ~wrap:`None (Prims.normalize_inline label) ]

(* The change tally leads the status cluster directly under the composer at both
   widths, so it reads as the composer's own footnote and stays next to the
   [ctrl+d] chord it advertises. The additions and deletions carry the workspace
   glance's green and red so the same figures are the same colour wherever they
   surface. *)
let mutation_status t =
  match List.rev t.changes with
  | [] -> []
  | _ :: _ ->
      let count = List.length t.changes in
      let totals = Change.of_changes t.changes in
      let additions = totals.Textdiff.additions in
      let deletions = totals.Textdiff.deletions in
      [
        (* The tally leads into the composer beneath it: one separating row
           above, snug against the composer's zeroed top margin below. *)
        box ~flex_shrink:0. ~padding:(padding_lrtb 2 1 1 0)
          ~size:{ width = pct 100; height = auto }
          [
            box ~flex_direction:Flex_direction.Row ~align_items:Align.Flex_start
              ~flex_shrink:0.
              ~size:{ width = pct 100; height = auto }
              [
                Prims.seg
                  (Theme.Palette.muted_style t.palette)
                  (Printf.sprintf "Δ %d change%s" count
                     (if count = 1 then "" else "s"));
                Prims.seg (Theme.Palette.muted_style t.palette) Theme.separator;
                Prims.seg
                  (Theme.Palette.success_style t.palette)
                  (Printf.sprintf "+%d" additions);
                Prims.seg Ansi.Style.default " ";
                Prims.seg
                  (Theme.Palette.error_style t.palette)
                  (Printf.sprintf "−%d" deletions);
                Prims.seg (Theme.Palette.muted_style t.palette) Theme.separator;
                Prims.seg
                  (Theme.Palette.muted_style t.palette)
                  "ctrl+d opens latest";
              ];
          ];
      ]

let ambiguity_status t =
  if t.possibly_mutating then
    [
      status_row ~palette:t.palette
        ~style:(Theme.Palette.warning_style t.palette)
        "! recovered session may still have a workspace mutation in flight";
    ]
  else []

(* The narrow activity carried inside the transcript region: only the todo board
   (a side-pane tenant on wide, hence narrow-only here). The agent switcher does
   not ride the region; it stacks beneath the composer exactly as the main view
   does (see [below_composer_threads] in [drill_view]), so the two surfaces place
   it identically. *)
let narrow_activity chat t =
  let board =
    match chat.task_board with
    | None -> []
    | Some board -> Todo_board.view ~palette:t.palette board
  in
  match board with
  | [] -> []
  | rows -> Todo_board.strip_rule ~palette:t.palette :: rows

(* The single conversation body shared by the main chat and a drilled child: a
   sticky transcript scrollport beside the responsive activity pane. Callers vary
   only the Mosaic key, the optional opening [header], and the [chat] projection
   they hand in; the tenant order (workspace, agents, tasks) and the breakpoint
   are identical, so a subagent view is the same code as the parent. *)
let conversation_region ?header ?compaction_started ~key ~now ~show_reasoning
    chat t =
  let left =
    transcript_scrollport ?header ~key ~now ~show_reasoning ~palette:t.palette
      ?compaction_started chat
  in
  Pane.frame ~palette:t.palette ~left ~wide_activity:(pane_rows chat t)
    ~narrow_activity:(narrow_activity chat t) ()

let narrow_only element =
  Mosaic.viewport_switch ~at_least_width:110 ~wide:Mosaic.empty ~narrow:element

(* The main view keeps the agent switcher out of the transcript region and
   stacks it beneath the composer instead (see [chat_view]), so on a narrow
   terminal the region carries the transcript and its tail: the todo board (a
   side-pane tenant on wide, hence narrow-only here), then the ambiguity,
   strip, and change-tally rows. The tail rides inside the region so
   the side pane's rule spans it and the region's bottom edge meets the
   composer. *)
let chat_region ?extra chat t =
  let left =
    transcript_scrollport ?extra ~key:"main.transcript" ~now:t.now
      ~show_reasoning:t.show_reasoning ~palette:t.palette
      ?compaction_started:(compaction_started t) chat
  in
  let board =
    let rows =
      match chat.task_board with
      | None -> []
      | Some board -> Todo_board.view ~palette:t.palette board
    in
    match rows with
    | [] -> []
    | rows ->
        [
          narrow_only
            (box ~key:"chat.tail.board" ~flex_direction:Flex_direction.Column
               ~flex_shrink:0.
               ~size:{ width = pct 100; height = auto }
               (Todo_board.strip_rule ~palette:t.palette :: rows));
        ]
  in
  let tail =
    board @ ambiguity_status t
    @ Strip.view ~palette:t.palette ~verbose:chat.expanded
        ~queued:(queue_text t.queue)
    @ mutation_status t
  in
  Pane.frame ~tail ~palette:t.palette ~left ~wide_activity:(pane_rows chat t)
    ~narrow_activity:[] ()

(* Only the agent switcher lives beneath the composer on a narrow terminal;
   the todo board rides the transcript column's tail above it. A wide terminal
   carries both tenants in the side pane, so each renders only under the
   narrow branch. The switcher's scroll table settles only against a definite
   height, so its box is sized to its own visible rows (the same 4/10 cap it
   applies internally), plus the glance's "↓ N more" overflow line when the cap
   hides threads. A blank row follows it to keep the strip clear of the footer;
   it sheds first when height is scarce. *)
let below_composer_threads ?(key = "chat.below-composer.threads") t =
  if t.children = [] then []
  else
    let cap = if Option.is_some t.strip_focus then 10 else 4 in
    let total = List.length t.children + 1 in
    let overflow = Option.is_none t.strip_focus && total > cap in
    let visible = min total cap + if overflow then 1 else 0 in
    [
      narrow_only
        (box ~key ~flex_direction:Flex_direction.Column ~flex_shrink:0.
           ~size:{ width = pct 100; height = px visible }
           (thread_strip ~placement:Threads_strip.Below_transcript t));
      narrow_only
        (box ~key:(key ^ ".gap") ~flex_shrink:1.
           ~min_size:{ width = px 0; height = px 0 }
           ~size:{ width = pct 100; height = px 1 }
           []);
    ]

let chat_view chat t =
  [ chat_region chat t; composer_region t ]
  @ below_composer_threads t @ help_rows t
  @ [ footer t ]

(* The rewind picker replaces the composer and footer below the transcript, in
   the same shape as any [Panel] surface. *)
let rewind_picker_view chat picker t =
  [
    chat_region chat t;
    Rewind_panel.view ~palette:t.palette ~now:t.now
      ~frame:(Theme.Palette.rule t.palette)
      picker
    |> Mosaic.map (fun message -> Rewind_panel_msg message);
  ]

(* The armed-rewind preview: the kept prefix of the transcript, a boundary
   naming the discarded tail, then that tail rendered below it, then the honest
   files notice, the seeded composer, and the commit hint. *)
let rewind_armed_view chat armed t =
  let kept, dropped = Transcript.split armed.rewind_prefix chat.chat_document in
  let plural = if armed.rewind_dropped = 1 then "" else "s" in
  let divider =
    box ~key:"rewind.divider" ~flex_shrink:0. ~padding:(padding_lrtb 2 2 1 0)
      ~size:{ width = pct 100; height = auto }
      [
        text
          ~style:(Theme.Palette.warning_style t.palette)
          ~wrap:`None
          (Printf.sprintf
             "rewinding here · %d message%s below will be discarded"
             armed.rewind_dropped plural);
      ]
  in
  let discarded =
    box ~key:"rewind.discarded" ~flex_shrink:0.
      ~size:{ width = pct 100; height = auto }
      [ Transcript.view ~expanded:chat.expanded ~palette:t.palette dropped ]
  in
  let files_notice =
    status_row ~palette:t.palette
      "files on disk are not reverted · rewind changes the conversation only"
  in
  let hint =
    status_row ~palette:t.palette
      (Printf.sprintf "↵ resubmit (discards %d) · esc cancel"
         armed.rewind_dropped)
  in
  [
    chat_region ~extra:[ divider; discarded ]
      { chat with chat_document = kept }
      t;
    files_notice;
    composer_region t;
    hint;
  ]
  @ help_rows t
  @ [ footer t ]

(* The standing welcome notice: the one sanctioned
   exception to the no-greetings voice rule — these are mentat's first users
   and the brand thanks them. Two lines: a lead and a muted caveat. A host
   announcement feed replaces this content without reshaping the view; armed
   prompts and flashes never do, they belong to the footer. *)
let welcome_notice =
  [
    "welcome — and thanks for trying mentat this early.";
    "it's experimental: sessions and config may change without migration.";
  ]

let home_view t =
  let composer = Some (composer_region t) in
  [
    Home.stage ~palette:t.palette ~snapshot:t.current_snapshot
      ~recents:t.recents ~now:(now_time t) ~account_absent:(account_absent t)
      ~permission_review:t.current_review ~notice:welcome_notice
      ~motion:t.motion ~composer;
    footer t;
  ]

let drill_header ~palette edge =
  box ~key:"child.header" ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 1 0)
    ~size:{ width = pct 100; height = auto }
    [
      text
        ~style:(Theme.Palette.accent_style palette)
        ~wrap:`None
        ("▂▄▆▄▂ @" ^ subagent_identity edge);
      text
        ~style:(Theme.Palette.muted_style palette)
        ~wrap:`None "started by main";
    ]

let drill_composer_element t drill =
  Composer.render ~list_open:(completion_open t)
    ~mode:Session.Contract.Mode.Build
    ~agent:(subagent_role_name drill.drill_edge)
    ~turn_running:(Turn.in_flight drill.drill_projection.child_turn)
    ~top_margin:(if completion_open t then 0 else 1)
    ~palette:t.palette
    ~on_msg:(fun message -> Composer_msg message)
    drill.drill_composer

(* The drill's composer region mirrors [composer_region]: the completion overlay
   and the controlled editor sit in one box, so the drill's input scopes its keys
   exactly as the main view does and the agent switcher stacks beneath as a
   sibling rather than competing with the editor for the [Tab] traversal. *)
let drill_composer_region t drill =
  box ~key:"child.composer.region" ~flex_direction:Flex_direction.Column
    ~flex_shrink:0.
    ~size:{ width = pct 100; height = auto }
    (completion_rows t @ [ drill_composer_element t drill ])

(* A drilled child is a chat running hot, so it projects into the very same
   [chat] the parent renders: its transcript, its live turn, and its own durable
   task board. Only the identity banner and the switcher's home key differ. *)
let chat_of_drill drill : chat =
  {
    chat_document = drill.drill_projection.child_document;
    chat_turn = drill.drill_projection.child_turn;
    task_board = drill.drill_projection.child_board;
    turn_origins = [];
    turn_count = 0;
    expanded = false;
    spinner = 0;
    next_page = 0;
    page = None;
    tail_reset = None;
  }

let drill_view drill t =
  let chat = chat_of_drill drill in
  (* The identity banner is the transcript's opening content, so it scrolls with
     the conversation and the activity pane stays flush with the top instead of
     being pushed down by a fixed chrome row. The pane carries the same live
     switcher as the main view, driven by the drill's own [drill_focus] so a
     sibling subagent is one navigation away and no stale parent selection
     bleeds in. *)
  let pane_context =
    { t with strip_focus = drill.drill_focus; strip_hover = None }
  in
  let region =
    conversation_region
      ~header:(drill_header ~palette:t.palette drill.drill_edge)
      ~key:"child.transcript" ~now:t.now ~show_reasoning:t.show_reasoning chat
      pane_context
  in
  let failure =
    match drill.drill_error with
    | None -> []
    | Some error ->
        [
          status_row ~palette:t.palette
            ~style:(Theme.Palette.error_style t.palette)
            (error_text error);
        ]
  in
  let footer =
    (* Transient notices (flash, armed prompts, the command-scope gate) take the
       footer row here exactly as they do on the main view, so a gated command in
       a drill is visible rather than a silent no-op. *)
    match notice_row t with
    | Some notice -> notice
    | None ->
        Footer.view ~palette:t.palette ~permission_review:t.current_review
          ~input_mode:(Composer.input_mode drill.drill_composer)
          ~account_absent:(account_absent t) ~home_badge:"esc back to main"
          t.current_snapshot
  in
  [ region ] @ failure
  @ [ drill_composer_region t drill ]
  @ below_composer_threads ~key:"child.below-composer.threads" pane_context
  @ [ footer ]

let panel_element t = function
  | Session_switch panel ->
      Sessions_panel.view ~palette:t.palette ~now:(now_time t)
        ~frame:(Theme.Palette.rule t.palette)
        panel
      |> Mosaic.map (fun message -> Sessions_panel_msg message)
  | Model model ->
      Model_panel.view ~palette:t.palette
        ~frame:(Theme.Palette.rule t.palette)
        ~rows:t.rows model.state
      |> Mosaic.map (fun message -> Model_panel_msg message)
  | Theme panel ->
      Theme_panel.view ~palette:t.palette
        ~frame:(Theme.Palette.rule t.palette)
        panel.theme_picker
      |> Mosaic.map (fun message -> Theme_panel_msg message)
  | Dialog dialog ->
      Dialog.view ~palette:t.palette dialog
      |> Mosaic.map (fun message -> Dialog_msg message)
  | Auth panel ->
      Auth_panel.view ~palette:t.palette
        ~frame:(Theme.Palette.rule t.palette)
        panel
      |> Mosaic.map (fun message -> Auth_panel_msg message)

let panel_view panel t =
  let panel = panel_element t panel in
  match t.phase with
  | Prelude ->
      [
        Home.stage ~palette:t.palette ~snapshot:t.current_snapshot
          ~recents:t.recents ~now:(now_time t)
          ~account_absent:(account_absent t) ~permission_review:t.current_review
          ~notice:welcome_notice ~motion:t.motion ~composer:None;
        panel;
      ]
  | Chat chat -> [ chat_region chat t; panel ]

let screen_view screen t =
  match screen with
  | Sessions screen ->
      Sessions_screen.view ~palette:t.palette
        ~home:(Snapshot.home t.current_snapshot)
        ~now:(now_time t)
        ~frame:(Theme.Palette.rule t.palette)
        screen
      |> Mosaic.map (fun message -> Sessions_screen_msg message)
  | Settings screen ->
      Settings_screen.view ~palette:t.palette
        ~frame:(Theme.Palette.rule t.palette)
        screen
      |> Mosaic.map (fun message -> Settings_screen_msg message)
  | Review screen ->
      Review_screen.view ~palette:t.palette ~width:t.cols ~height:t.rows
        ~inject:(fun message -> Review_screen_msg message)
        screen

let view t =
  let children =
    match t.surface with
    | Panel panel -> panel_view panel t
    | Screen screen -> [ screen_view screen t ]
    | Conversing -> (
        match (t.phase, t.drill) with
        | Prelude, _ -> home_view t
        | Chat _, Some drill -> drill_view drill t
        | Chat chat, None -> (
            match t.rewind with
            | Some (Picking picker) -> rewind_picker_view chat picker t
            | Some (Armed armed) -> rewind_armed_view chat armed t
            | None -> chat_view chat t))
  in
  box ~key:"shell" ~flex_direction:Flex_direction.Column ~flex_grow:1.
    ~flex_shrink:1.
    ~min_size:{ width = px 0; height = px 0 }
    ~overflow:{ x = Overflow.Hidden; y = Overflow.Hidden }
    ~size:{ width = pct 100; height = pct 100 }
    children

let terminal_title t =
  let leaf =
    Filename.basename (Lpath.Abs.to_string (Snapshot.cwd t.current_snapshot))
  in
  (* The title leads with the product name so a host multiplexer names the tab
     "mentat", then carries the workspace leaf as disambiguating context — never
     the bare leaf, which would read as the coincidental folder name. *)
  let label = "mentat — " ^ leaf in
  match t.phase with
  | Chat chat when Turn.in_flight chat.chat_turn ->
      (* Alternate the heartbeat once per second, keyed to whole seconds rather
         than the frame counter so the window title stays calm while the spinner
         animates at [spinner_frame_interval]. *)
      (if int_of_float t.now mod 2 = 0 then "⠂ " else "⠐ ") ^ label
  | Prelude | Chat _ -> "✳ " ^ label

let ctrl character data =
  data.Matrix.Input.Key.modifier.Matrix.Input.Modifier.ctrl
  &&
  match data.Matrix.Input.Key.key with
  | Matrix.Input.Key.Char uchar -> Uchar.equal uchar (Uchar.of_char character)
  | _ -> false

(* The sessions/review screen verb a resolved registry fate carries, if any. A
   resolve scoped to a screen only ever returns that screen's rows, so the other
   arms are unreachable; the exhaustive match keeps a new fate from defaulting to
   the wrong screen undetected. *)
let sessions_verb_of_fate = function
  | Command.Sessions_fork -> Some `Fork
  | Command.Sessions_rename -> Some `Rename
  | Command.Sessions_archive -> Some `Archive
  | Command.Sessions_restore -> Some `Restore
  | Command.Sessions_delete -> Some `Delete
  | Command.Clear_session | Command.Fork_session | Command.Rewind_session
  | Command.Undo_session | Command.Redo_session | Command.Compact_session
  | Command.Rename_session | Command.Open_model
  | Command.Open_theme | Command.Open_sessions | Command.Open_settings _
  | Command.Open_login | Command.Open_logout | Command.Switch_mode _
  | Command.Toggle_thinking | Command.Toggle_verbose | Command.Open_review
  | Command.Dune_command | Command.Init_project _ | Command.Quit
  | Command.Interrupt | Command.Toggle_expanded | Command.Transcript_page _
  | Command.Focus_switch
  | Command.History_search | Command.Edit_in_editor | Command.Open_palette
  | Command.Copy_selection | Command.Review_toggle | Command.Review_verdict
  | Command.Review_help | Command.Review_compose _ | Command.Review_remove
  | Command.Review_next_hunk | Command.Review_prev_hunk | Command.Review_next_cr
  | Command.Review_prev_cr ->
      None

let review_verb_of_fate = function
  | Command.Review_toggle -> Some `Toggle
  | Command.Review_verdict -> Some `Verdict
  | Command.Review_help -> Some `Help
  | Command.Review_compose which -> Some (`Compose which)
  | Command.Review_remove -> Some `Remove
  | Command.Review_next_hunk -> Some `Next_hunk
  | Command.Review_prev_hunk -> Some `Prev_hunk
  | Command.Review_next_cr -> Some `Next_cr
  | Command.Review_prev_cr -> Some `Prev_cr
  | Command.Clear_session | Command.Fork_session | Command.Rewind_session
  | Command.Undo_session | Command.Redo_session | Command.Compact_session
  | Command.Rename_session | Command.Open_model
  | Command.Open_theme | Command.Open_sessions | Command.Open_settings _
  | Command.Open_login | Command.Open_logout | Command.Switch_mode _
  | Command.Toggle_thinking | Command.Toggle_verbose | Command.Open_review
  | Command.Dune_command | Command.Init_project _ | Command.Quit
  | Command.Interrupt | Command.Toggle_expanded | Command.Transcript_page _
  | Command.Focus_switch
  | Command.History_search | Command.Edit_in_editor | Command.Open_palette
  | Command.Copy_selection | Command.Sessions_fork | Command.Sessions_rename
  | Command.Sessions_archive | Command.Sessions_restore
  | Command.Sessions_delete ->
      None

(* [Sub.on_key_all] deliberately receives events consumed by a focused widget.
   Respect that ownership before classifying shell bindings: tables, scroll
   boxes, and editors must settle their local key without a modal or transcript
   fallback applying the same gesture a second time.

   The registry resolves a keypress in one pinned order (Command's keymap
   projection): reserved floor ([Ctrl+C]) -> scoped pending completion -> global
   resolve -> surface routing -> conversing resolve. Every later stage only sees
   keys the earlier ones declined. *)
let key_message t event =
  let data = Mosaic.Event.Key.data event in
  let key = data.Matrix.Input.Key.key in
  let emit message =
    Mosaic.Event.Key.prevent_default event;
    Some message
  in
  let disarm_or_pass () =
    if Option.is_some t.pending_chord then Some Disarm_chord else None
  in
  let phase = if turn_in_flight t then Command.Anytime else Command.Idle_only in
  (* Map a resolved registry command to its message, honoring the completion-open
     guards that keep history search, focus, and the editor inert while a
     completion owns the surface — exactly as the fixed bindings did. A key-bound
     slash command dispatches through the total registry dispatcher; a resolved
     screen verb never reaches here (it resolves on its own surface). *)
  let message_of_command command =
    match Command.fate command with
    | Command.Toggle_expanded -> emit Toggle_expanded
    | Command.Interrupt -> emit Escape
    | Command.Transcript_page `Up -> emit (Transcript_paged `Up)
    | Command.Transcript_page `Down -> emit (Transcript_paged `Down)
    | Command.Edit_in_editor ->
        if completion_open t then disarm_or_pass ()
        else emit Edit_in_editor_requested
    | Command.History_search ->
        if completion_open t then disarm_or_pass ()
        else emit Begin_history_search
    | Command.Focus_switch ->
        if completion_open t then disarm_or_pass () else emit Shift_tab
    | Command.Open_palette -> emit Open_command_palette
    | Command.Clear_session | Command.Fork_session | Command.Rewind_session
    | Command.Undo_session | Command.Redo_session | Command.Compact_session
    | Command.Rename_session | Command.Open_model
    | Command.Open_theme | Command.Open_sessions | Command.Open_settings _
    | Command.Open_login | Command.Open_logout | Command.Switch_mode _
    | Command.Toggle_thinking | Command.Toggle_verbose | Command.Open_review
    | Command.Dune_command | Command.Copy_selection | Command.Init_project _
    | Command.Quit ->
        emit (Run_command command)
    | Command.Sessions_fork | Command.Sessions_rename | Command.Sessions_archive
    | Command.Sessions_restore | Command.Sessions_delete | Command.Review_toggle
    | Command.Review_verdict | Command.Review_help | Command.Review_compose _
    | Command.Review_remove | Command.Review_next_hunk
    | Command.Review_prev_hunk | Command.Review_next_cr | Command.Review_prev_cr
      ->
        None
  in
  let resolve_scope surface =
    match
      Command.resolve t.overlay ~surface ~phase ~pending:t.pending_chord data
    with
    | `Pending command ->
        Mosaic.Event.Key.prevent_default event;
        Some (Arm_chord command)
    | `None -> None
    | `Action command -> message_of_command command
  in
  (* An armed two-press chord captures its completion key even over a focused
     widget, but only on the surface it armed on: the pending latch clears on any
     surface change, and a chord armed elsewhere can never complete here. *)
  let completes_chord =
    match (t.pending_chord, current_command_scope t) with
    | Some command, Some surface -> (
        match
          Command.resolve t.overlay ~surface ~phase ~pending:(Some command) data
        with
        | `Action completed when Command.equal completed command ->
            Some completed
        | `None | `Pending _ | `Action _ -> None)
    | (Some _ | None), _ -> None
  in
  match completes_chord with
  | Some command -> message_of_command command
  | None -> (
      if Mosaic.Event.Key.default_prevented event then disarm_or_pass ()
      else if ctrl 'c' data then emit Ctrl_c
      else
        (* Global resolve: the palette chord opens before per-surface routing. *)
        match resolve_scope Command.Global with
        | Some _ as message -> message
        | None -> (
            match t.surface with
            | Panel (Session_switch _) ->
                Mosaic.Event.Key.prevent_default event;
                Option.map
                  (fun message -> Sessions_panel_msg message)
                  (Sessions_panel.key data)
            | Panel (Model _) ->
                Mosaic.Event.Key.prevent_default event;
                Option.map
                  (fun message -> Model_panel_msg message)
                  (Model_panel.key data)
            | Panel (Theme _) ->
                Mosaic.Event.Key.prevent_default event;
                Option.map
                  (fun message -> Theme_panel_msg message)
                  (Theme_panel.key data)
            | Panel (Dialog dialog) ->
                if Dialog.editing dialog then
                  match key with
                  | Matrix.Input.Key.Escape -> emit (Dialog_key data)
                  | _ -> None
                else emit (Dialog_key data)
            | Panel (Auth _) ->
                Mosaic.Event.Key.prevent_default event;
                Option.map
                  (fun message -> Auth_panel_msg message)
                  (Auth_panel.key data)
            | Screen (Sessions screen) ->
                Mosaic.Event.Key.prevent_default event;
                let classifier () =
                  Option.map
                    (fun message -> Sessions_screen_msg message)
                    (Sessions_screen.key data)
                in
                (* Screen verbs resolve through the registry while browsing; the
                   filter, rename, and confirmation states keep every key as the
                   screen's own vocabulary. *)
                if Sessions_screen.browsing screen then
                  match
                    Command.resolve t.overlay
                      ~surface:(Command.Screen Command.Sessions) ~phase
                      ~pending:t.pending_chord data
                  with
                  | `Pending command -> Some (Arm_chord command)
                  | `Action command -> (
                      match sessions_verb_of_fate (Command.fate command) with
                      | Some verb ->
                          Some (Sessions_screen_msg (Sessions_screen.verb verb))
                      | None -> classifier ())
                  | `None -> classifier ()
                else classifier ()
            | Screen (Settings _) ->
                Mosaic.Event.Key.prevent_default event;
                Option.map
                  (fun message -> Settings_screen_msg message)
                  (Settings_screen.key data)
            | Screen (Review screen) -> (
                Mosaic.Event.Key.prevent_default event;
                let classifier () =
                  Option.map
                    (fun message -> Review_screen_msg message)
                    (Review_screen.key screen data)
                in
                (* While the compose textarea owns input the verbs are inert; its
                   printables and cancel stay the screen's own vocabulary. *)
                if Review_screen.composing screen then classifier ()
                else
                  match
                    Command.resolve t.overlay
                      ~surface:(Command.Screen Command.Review) ~phase
                      ~pending:t.pending_chord data
                  with
                  | `Pending command -> Some (Arm_chord command)
                  | `Action command -> (
                      match review_verb_of_fate (Command.fate command) with
                      | Some verb ->
                          Some (Review_screen_msg (Review_screen.verb verb))
                      | None -> classifier ())
                  | `None -> classifier ())
            | Conversing
              when match t.rewind with Some (Picking _) -> true | _ -> false ->
                (* The rewind picker is a modal overlay over the Conversing
                   surface: it owns every classified key like a [Panel] does. *)
                Mosaic.Event.Key.prevent_default event;
                Option.map
                  (fun message -> Rewind_panel_msg message)
                  (Rewind_panel.key data)
            | Conversing -> (
                (* Conversing resolve: the Chat-scoped gestures and the palette
                   alias fire here; anything unclaimed is composer text. *)
                match resolve_scope Command.Chat with
                | Some _ as message -> message
                | None -> disarm_or_pass ())))

let paste_subscription t =
  let handler wrap event =
    Mosaic.Event.Paste.prevent_default event;
    Some (wrap (Mosaic.Event.Paste.text event))
  in
  match t.surface with
  | Panel (Auth panel) when Auth_panel.accepts_paste panel ->
      Mosaic.Sub.on_paste_all (handler (fun text -> Auth_paste text))
  | Panel (Model _) ->
      Mosaic.Sub.on_paste_all (handler (fun text -> Model_paste text))
  | Panel (Theme _) ->
      Mosaic.Sub.on_paste_all (handler (fun text -> Theme_paste text))
  | Screen (Settings _) ->
      Mosaic.Sub.on_paste_all (handler (fun text -> Settings_paste text))
  | Conversing
  | Panel (Session_switch _ | Dialog _ | Auth _)
  | Screen (Sessions _ | Review _) ->
      Mosaic.Sub.none

(* [Turn_tick] advances [spinner] one frame every [spinner_frame_interval]
   seconds while a turn runs. [Theme.spinner_frames] holds ten glyphs, so a full
   braille rotation completes in one second. The interval is distinct from the
   other timers below so it drives its own wakeup cadence. *)
let spinner_frame_interval = 0.1

let subscriptions t =
  let home_motion =
    match (t.phase, t.surface) with
    | Prelude, Conversing when Home.Motion.animating t.motion -> true
    | Prelude, (Panel _ | Screen _) | Chat _, _ | Prelude, Conversing -> false
  in
  Mosaic.Sub.batch
    [
      Mosaic.Sub.on_key_all (key_message t);
      Mosaic.Sub.on_focus (Terminal_focus true);
      Mosaic.Sub.on_blur (Terminal_focus false);
      Mosaic.Sub.on_resize (fun ~width ~height ->
          Resized { cols = width; rows = height });
      (* Follow the terminal's live light/dark scheme only under auto: the reply
         to the startup query and any unsolicited DEC 2031 notification arrive
         here; the update drops them once a hand pick disarms auto. *)
      (if Option.is_some t.theme_auto then
         Mosaic.Sub.on_color_scheme (fun scheme -> Some (Color_scheme scheme))
       else Mosaic.Sub.none);
      (if home_motion then Mosaic.Sub.on_tick (fun ~dt -> Frame_tick dt)
       else Mosaic.Sub.none);
      Mosaic.Sub.every 1. (fun () -> Clock_tick);
      (if workspace_dune_followed t then
         Mosaic.Sub.every 2. (fun () -> Workspace_dune_tick)
       else Mosaic.Sub.none);
      (if turn_in_flight t || Option.is_some (compaction_started t) then
         Mosaic.Sub.every spinner_frame_interval (fun () -> Turn_tick)
       else Mosaic.Sub.none);
      (if Option.is_some t.flash then
         Mosaic.Sub.every 3. (fun () -> Flash_expired)
       else Mosaic.Sub.none);
      (if Option.is_some t.armed then
         Mosaic.Sub.every 2. (fun () -> Armed_expired)
       else Mosaic.Sub.none);
      paste_subscription t;
    ]
