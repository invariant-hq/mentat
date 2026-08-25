(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The unified command registry.

    One table of named actions ({!all}) projected three ways: slash completion
    ({!filter} / {!parse}), a command palette ({!matches_palette} / {!keybind}),
    and the keymap ({!Overlay} / {!resolve}). Each row carries a stable {!id},
    an optional slash spelling, palette text, a {!category}, a surface {!scope}
    and in-flight {!phase}, its shipped default key {!bindings}, a
    transcript-echo flag, and a typed {!fate} the shell dispatches on. The
    former app-level keymap gestures and the per-screen verbs are ordinary rows,
    so a new action needs one row and no new dispatch path.

    The registry holds only data and projection: it reads no application state
    and performs no effects. Widget-internal editing and navigation keys stay a
    fixed shared vocabulary that {!reserved_vocabulary} enumerates per scope; a
    registry binding can never collide with it, by construction. *)

(** {1:types Types} *)

(** Palette grouping. A small stable set of buckets, not free-form. *)
type category = Session | Conversation | Navigation | Model | View | App

(** A full-screen surface with its own verbs. *)
type screen = Review | Sessions | Settings

(** The three settings pages: the destination tab an {!Open_settings} fate
    carries. *)
type settings_tab = Config | Status | Usage

(** The surface a row is offered on and whose keys it resolves against. *)
type scope =
  | Global
      (** Offered in every palette; resolves before per-surface routing. *)
  | Chat  (** The conversing surface: paging, mode, the Escape ladder. *)
  | Screen of screen  (** One screen's verbs (Review, Sessions, …). *)

(** The in-flight admission gate. *)
type phase =
  | Idle_only
      (** Dispatch requires an idle session; a consumer leaves state unchanged
          during an in-flight turn and reports availability afterwards. *)
  | Anytime
      (** Dispatch may occur while a turn is in flight; it never mutates the
          running turn's sealed contract. *)

type availability = { scope : scope; phase : phase }
(** A row's surface scope crossed with its in-flight gate. *)

type binding = { chord : Chord.t; on : scope }
(** A default binding and the scope its chord resolves on. [on] equals the row's
    own scope except for a row that wants a chord on a narrower surface than it
    is offered (the palette's Chat alias). Every binding's chord lies outside
    its scope's {!reserved_vocabulary}. *)

(** The typed effect the shell dispatches on. Every row has exactly one fate. *)
type fate =
  | Clear_session
      (** Create a fresh empty session while retaining the previous one. *)
  | Fork_session  (** Fork the active session and continue in the child. *)
  | Rewind_session  (** Open the rewind picker. *)
  | Undo_session  (** Step the durable undo boundary back one user turn. *)
  | Redo_session  (** Step the undo boundary forward one user turn. *)
  | Compact_session  (** Compact the active conversation. *)
  | Rename_session  (** Rename the active session. *)
  | Open_model  (** Open model selection. *)
  | Open_theme  (** Open theme selection. *)
  | Open_sessions  (** Open session history. *)
  | Open_settings of settings_tab
      (** Open settings on the destination screen's exact tab. *)
  | Open_login  (** Open provider login. *)
  | Open_logout  (** Open provider logout. *)
  | Switch_mode of Mentat_session.Contract.Mode.t
      (** Select the product mode carried by the next submitted prompt. *)
  | Toggle_thinking  (** Toggle rendering of thinking summaries. *)
  | Toggle_verbose  (** Toggle expanded reasoning detail. *)
  | Open_review  (** Open the review surface. *)
  | Dune_command
      (** Drive the supervised build watch: [/dune restart] forgives a
          terminal state and cycles a fresh watch, [/dune stop] ends
          supervision for the session. *)
  | Init_project of string
      (** Submit the carried AGENTS.md initialization prompt as a Build turn. *)
  | Quit  (** Request process exit through the shell's guarded quit flow. *)
  | Interrupt
      (** The Escape gesture: cancel a picker, close a panel, interrupt a turn,
          then arm quit. Reserved on Escape; drives the whole ladder. *)
  | Toggle_expanded  (** Toggle expanded reasoning detail. *)
  | Transcript_page of [ `Up | `Down ]  (** Scroll the transcript one page. *)
  | Focus_switch  (** Move focus to the thread switcher. *)
  | History_search  (** Begin incremental prompt-history search. *)
  | Edit_in_editor  (** Open the composer draft in the external editor. *)
  | Open_palette  (** Open the command palette. *)
  | Copy_selection  (** Copy the terminal's current text selection. *)
  | Sessions_fork  (** Sessions screen: fork the selected session. *)
  | Sessions_rename  (** Sessions screen: rename the selected session. *)
  | Sessions_archive  (** Sessions screen: archive the selected session. *)
  | Sessions_restore  (** Sessions screen: restore the selected session. *)
  | Sessions_delete  (** Sessions screen: delete the selected session. *)
  | Review_toggle  (** Review screen: toggle the reviewed mark. *)
  | Review_verdict  (** Review screen: toggle the verdict. *)
  | Review_help  (** Review screen: toggle the key help. *)
  | Review_compose of [ `Add | `Edit | `Resolve ]
      (** Review screen: start a comment add, edit, or resolve. *)
  | Review_remove  (** Review screen: remove the focused comment. *)
  | Review_next_hunk  (** Review screen: jump to the next hunk. *)
  | Review_prev_hunk  (** Review screen: jump to the previous hunk. *)
  | Review_next_cr  (** Review screen: jump to the next comment. *)
  | Review_prev_cr  (** Review screen: jump to the previous comment. *)

type t
(** A registry row. Values are obtained only from {!all}, {!filter}, {!parse},
    and {!resolve}; ids and slash spellings are unique. *)

(** A successfully parsed command line. *)
type parsed =
  | Exact of t
      (** A recognized command without an argument, including a bare command
          that can optionally take one. *)
  | With_argument of t * string
      (** A recognized argument-taking command and its non-empty argument, with
          surrounding horizontal whitespace removed and case preserved. *)
  | Unexpected_argument of t * string
      (** A recognized argless command given a non-empty argument. Never
          dispatched: the host refuses in place, because submitting the line as
          prose instead would silently start a paid model turn. *)

(** {1:catalog Catalog} *)

val all : t list
(** [all] is every registry row in palette display order. Ids are unique; slash
    spellings, where present, are canonical lowercase ASCII and unique. *)

val filter : query:string -> t list
(** [filter ~query] is the subsequence of {!all} whose slash spelling or title
    contains [query]. Rows without a slash are skipped. Matching ignores leading
    and trailing ASCII horizontal whitespace and letter case. An empty query
    yields every slash-reachable row. *)

val matches_palette : query:string -> t -> bool
(** [matches_palette ~query t] is [true] iff [query] is a substring of [t]'s
    title or {!category_label}, the same substring matcher slash completion
    uses. *)

val parse : string -> parsed option
(** [parse s] classifies the single command line [s]. Leading and trailing
    spaces and tabs are ignored and the command token matches with ASCII
    case-insensitivity. A bare known slash command produces [Exact]; a non-empty
    argument produces [With_argument] when {!argument_hint} is present and
    [Unexpected_argument] otherwise. Slash-less rows, unknown commands, empty
    input, and input with a newline or carriage return return [None]. *)

(** {1:queries Queries} *)

val id : t -> string
(** [id t] is [t]'s stable name, used by keybindings.json and the palette. *)

val slash : t -> string option
(** [slash t] is [Some spelling] when [t] is slash-reachable, else [None]. *)

val title : t -> string
val description : t -> string
val category : t -> category
val category_label : category -> string

val argument_hint : t -> string option
(** [argument_hint t] is [Some hint] when [t] accepts one trailing argument. *)

val scope : t -> scope
val phase : t -> phase

val echoes : t -> bool
(** [echoes t] is [true] iff ordinary dispatch records a command echo. *)

val fate : t -> fate

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same registry row. *)

val scope_equal : scope -> scope -> bool

(** {1:keymap Keymap projection}

    A keypress resolves in one pinned order, each stage seeing only keys the
    earlier stages declined: {b reserved floor} ([Ctrl+C]) →
    {b scoped pending completion} → {b global resolve} ([scope = Global]) →
    {b surface routing} (a screen's [Screen s] rows, then its fixed vocabulary)
    → {b conversing resolve} ([scope = Chat]). Because no binding may claim a
    chord that is reserved vocabulary on its resolving surface, the order
    disambiguates scopes and never a collision. *)

val reserved_vocabulary : scope -> Chord.t -> bool
(** [reserved_vocabulary scope chord] is [true] iff [chord] is fixed widget
    editing or navigation on [scope] and therefore may never carry a registry
    binding. Global reserves [Ctrl+C]; Chat reserves every plain printable and
    the textarea's readline chords; each screen reserves its classifier
    navigation. The set is a superset of what each classifier consumes. *)

(** {2:diagnostics Diagnostics} *)

module Diagnostic : sig
  type t
  (** One rejected keybinding entry. The offending entry keeps its default. *)

  val message : t -> string
  (** [message d] is a single-line human-readable explanation. *)

  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

(** {2:overlay Overlay} *)

module Overlay : sig
  type t
  (** A validated map from action {!id} to a non-empty list of alternative
      chords, overlaying the shipped defaults. Rejected entries are absent, so a
      row keeps its default and resolution stays total and conflict-free. *)

  val empty : t
  (** [empty] overlays nothing; every row keeps its default binding. *)

  val of_json : Jsont.json -> t * Diagnostic.t list
  (** [of_json j] parses [j], a JSON object mapping an action {!id} to a chord
      string or an array of chord strings. Each of these becomes a
      {!Diagnostic.t} and keeps the default for that entry: an unknown id, an
      unparseable chord, a chord equal to the reserved [Ctrl+C] floor, the
      reserved [interrupt] action, a chord that is {!reserved_vocabulary} on the
      row's scope, and a chord already bound to another same-scope row. A
      non-object [j] yields {!empty} and one diagnostic. When two entries claim
      one chord, the later loses. *)
end

(** {1:palette Palette projection} *)

val keybind : Overlay.t -> t -> string option
(** [keybind overlay t] is the chord string shown for [t] in the palette: the
    overlay override when present, else the first default binding, else [None].
*)

(** {2:resolution Resolution} *)

type resolution = [ `None | `Pending of t | `Action of t ]
(** [`None] matches no binding; [`Pending c] matched the first press of [c]'s
    two-press chord (latch it and feed the next key with [~pending]);
    [`Action c] completed [c]'s chord. *)

val resolve :
  Overlay.t ->
  surface:scope ->
  phase:phase ->
  pending:t option ->
  Matrix.Input.Key.event ->
  resolution
(** [resolve overlay ~surface ~phase ~pending event] classifies one decoded key
    against the rows whose binding resolves on [surface] ([Global] included only
    when [surface = Global]); each row's effective chords are its overlay
    override or its defaults on [surface]. [phase] is the current in-flight
    state ([Idle_only] when idle): an [Idle_only] row resolves only when idle.
    When [pending] is [Some c], [event] is matched against the remaining press
    of [c]'s chord on [surface]; on a mismatch the latch is abandoned and
    [event] is reclassified as a fresh first press. *)
