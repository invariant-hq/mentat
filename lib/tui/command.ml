(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type category = Session | Conversation | Navigation | Model | View | App
type screen = Review | Sessions | Settings | Goal
type settings_tab = Config | Status | Usage
type scope = Global | Chat | Screen of screen
type phase = Idle_only | Anytime
type availability = { scope : scope; phase : phase }
type binding = { chord : Chord.t; on : scope }

type fate =
  (* Slash-reachable commands. *)
  | Clear_session
  | Fork_session
  | Rewind_session
  | Undo_session
  | Redo_session
  | Compact_session
  | Open_goal
  | Rename_session
  | Open_model
  | Open_theme
  | Open_sessions
  | Open_settings of settings_tab
  | Open_login
  | Open_logout
  | Switch_mode of Mentat_session.Contract.Mode.t
  | Toggle_thinking
  | Toggle_verbose
  | Open_review
  | Dune_command
  | Init_project of string
  | Quit
  (* App-level key gestures, folded from the former keymap. *)
  | Interrupt
  | Toggle_expanded
  | Transcript_page of [ `Up | `Down ]
  | Focus_switch
  | History_search
  | Edit_in_editor
  | Open_palette
  | Copy_selection
  (* Sessions-screen verbs, resolved into the screen's own update. *)
  | Sessions_fork
  | Sessions_rename
  | Sessions_archive
  | Sessions_restore
  | Sessions_delete
  (* Review-screen verbs, resolved into the screen's own update. *)
  | Review_toggle
  | Review_verdict
  | Review_help
  | Review_compose of [ `Add | `Edit | `Resolve ]
  | Review_remove
  | Review_next_hunk
  | Review_prev_hunk
  | Review_next_cr
  | Review_prev_cr

type t = {
  id : string;
  slash : string option;
  title : string;
  description : string;
  category : category;
  argument_hint : string option;
  availability : availability;
  default_keys : binding list;
  echoes : bool;
  fate : fate;
}

type parsed =
  | Exact of t
  | With_argument of t * string
  | Unexpected_argument of t * string

let trim_horizontal s =
  let is_horizontal = function ' ' | '\t' -> true | _ -> false in
  let length = String.length s in
  let rec first i =
    if i < length && is_horizontal s.[i] then first (i + 1) else i
  in
  let rec last i = if i >= 0 && is_horizontal s.[i] then last (i - 1) else i in
  let first = first 0 in
  if first = length then ""
  else
    let last = last (length - 1) in
    String.sub s first (last - first + 1)

let contains_line_break s = String.contains s '\n' || String.contains s '\r'

let contains_ascii_control s =
  let rec loop i =
    if i = String.length s then false
    else
      let code = Char.code s.[i] in
      code < 0x20 || code = 0x7f || loop (i + 1)
  in
  loop 0

let is_command_char = function
  | 'a' .. 'z' | '0' .. '9' | '-' -> true
  | _ -> false

let valid_slash slash =
  let length = String.length slash in
  length > 1
  && Char.equal slash.[0] '/'
  &&
  let rec loop i = i = length || (is_command_char slash.[i] && loop (i + 1)) in
  loop 1

let is_id_char = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '_' -> true
  | _ -> false

let valid_id id =
  (not (String.equal id ""))
  &&
  let rec loop i =
    i = String.length id || (is_id_char id.[i] && loop (i + 1))
  in
  loop 0

let valid_label label =
  (not (String.equal label ""))
  && String.equal (trim_horizontal label) label
  && not (contains_ascii_control label)

let chord_exn s =
  match Chord.of_string s with
  | Ok chord -> chord
  | Error message -> invalid_arg ("Command: built-in chord " ^ message)

(* The built-in /init prompt. It is a frontend string constant, not a reach into
   a prompts library the TUI does not link: /init is sugar over the ordinary
   prompt path and carries this text in its fate. The first line is a stable
   summary; the agent does the exploration and the write with its own tools. *)
let init_prompt =
  "Explore this repository and write or update its AGENTS.md so a new \
   contributor can get productive fast. Cover how to build, test, and run the \
   project, the layout and where the key code lives, and the conventions and \
   architectural rules to follow. Keep it concise, around 20-30 lines. If \
   AGENTS.md already exists, improve it in place rather than replacing it, and \
   fold in any conventions from other agent- or editor-instruction files. \
   Document only what you can verify from the repository; do not invent \
   anything."

let entry ~id ?slash ?argument_hint ~title ~description ~category ~scope ~phase
    ?(keys = []) ~echoes ~fate () =
  if not (valid_id id) then
    invalid_arg ("Command: invalid id " ^ String.escaped id);
  Option.iter
    (fun slash ->
      if not (valid_slash slash) then
        invalid_arg ("Command: invalid slash spelling " ^ String.escaped slash))
    slash;
  if not (valid_label title) then
    invalid_arg ("Command: invalid title for " ^ id);
  if not (valid_label description) then
    invalid_arg ("Command: invalid description for " ^ id);
  Option.iter
    (fun hint ->
      if not (valid_label hint) then
        invalid_arg ("Command: invalid argument hint for " ^ id))
    argument_hint;
  {
    id;
    slash;
    title;
    description;
    category;
    argument_hint;
    availability = { scope; phase };
    default_keys = keys;
    echoes;
    fate;
  }

let key ?on chord scope =
  let on = Option.value on ~default:scope in
  { chord = chord_exn chord; on }

(* This table is the only command-definition site: every projection — slash
   completion, the command palette, and the keymap — reads it. Required fields
   make each entry's dispatch fate, gate, palette grouping, scope, and default
   binding total. Rows without a slash are key- or palette-only; rows with an
   empty [default_keys] are unbound until an overlay binds them. The former
   keymap gestures and the per-screen verbs are ordinary rows here, so a new
   action needs one row and no new dispatch path. *)
let all =
  [
    (* Conversation-lifecycle slash commands (Chat scope). *)
    entry ~id:"clear" ~slash:"/clear" ~title:"Clear"
      ~description:
        "Start a new session with empty context; previous session stays on disk"
      ~category:Session ~scope:Chat ~phase:Idle_only ~echoes:false
      ~fate:Clear_session ();
    entry ~id:"fork" ~slash:"/fork" ~title:"Fork"
      ~description:"Fork current session" ~category:Session ~scope:Chat
      ~phase:Idle_only ~echoes:false ~fate:Fork_session ();
    entry ~id:"rewind" ~slash:"/rewind" ~title:"Rewind"
      ~description:"Jump back to an earlier message and resubmit"
      ~category:Session ~scope:Chat ~phase:Idle_only ~echoes:false
      ~fate:Rewind_session ();
    entry ~id:"undo" ~slash:"/undo" ~title:"Undo"
      ~description:"Undo the last turn: revert its files and reload its message"
      ~category:Session ~scope:Chat ~phase:Idle_only ~echoes:false
      ~fate:Undo_session ();
    entry ~id:"redo" ~slash:"/redo" ~title:"Redo"
      ~description:"Redo an undone turn, restoring its files and messages"
      ~category:Session ~scope:Chat ~phase:Idle_only ~echoes:false
      ~fate:Redo_session ();
    entry ~id:"compact" ~slash:"/compact" ~title:"Compact"
      ~description:"Free up context by summarizing the conversation so far"
      ~category:Session ~scope:Chat ~phase:Idle_only ~echoes:false
      ~fate:Compact_session ();
    entry ~id:"goal" ~slash:"/goal" ~title:"Goal"
      ~description:"Declare a goal, or inspect and control the current one"
      ~argument_hint:"[objective]" ~category:Conversation ~scope:Chat
      ~phase:Anytime ~echoes:false ~fate:Open_goal ();
    entry ~id:"init" ~slash:"/init" ~title:"Init"
      ~description:"Generate or update AGENTS.md with project conventions"
      ~category:Conversation ~scope:Chat ~phase:Idle_only ~echoes:false
      ~fate:(Init_project init_prompt) ();
    entry ~id:"rename" ~slash:"/rename" ~title:"Rename"
      ~description:"Rename the active session" ~argument_hint:"<title>"
      ~category:Session ~scope:Chat ~phase:Idle_only ~echoes:false
      ~fate:Rename_session ();
    entry ~id:"dune" ~slash:"/dune" ~title:"Dune watch"
      ~description:"Restart or stop the supervised build watch"
      ~argument_hint:"restart|stop" ~category:Session ~scope:Chat
      ~phase:Anytime ~echoes:false ~fate:Dune_command ();
    (* App-level slash commands (Global scope: offered in every palette). *)
    entry ~id:"review" ~slash:"/review" ~title:"Review"
      ~description:"Review the worktree diff against the base" ~category:View
      ~scope:Global ~phase:Anytime ~echoes:false ~fate:Open_review ();
    entry ~id:"model" ~slash:"/model" ~title:"Model"
      ~description:"Select model and effort" ~category:Model ~scope:Global
      ~phase:Anytime ~echoes:false ~fate:Open_model ();
    entry ~id:"theme" ~slash:"/theme" ~title:"Theme"
      ~description:"Choose a color theme" ~category:View ~scope:Chat
      ~phase:Anytime ~echoes:false ~fate:Open_theme ();
    entry ~id:"thinking" ~slash:"/thinking" ~title:"Thinking"
      ~description:"Toggle thinking summaries" ~category:View ~scope:Global
      ~phase:Anytime ~echoes:true ~fate:Toggle_thinking ();
    entry ~id:"verbose" ~slash:"/verbose" ~title:"Verbose"
      ~description:"Expand or collapse reasoning detail (ctrl+o)" ~category:View
      ~scope:Global ~phase:Anytime ~echoes:true ~fate:Toggle_verbose ();
    entry ~id:"plan" ~slash:"/plan" ~title:"Plan"
      ~description:"Use plan mode for the next prompt" ~category:Conversation
      ~scope:Global ~phase:Anytime ~echoes:true
      ~fate:(Switch_mode Mentat_session.Contract.Mode.Plan) ();
    entry ~id:"build" ~slash:"/build" ~title:"Build"
      ~description:"Use build mode for the next prompt" ~category:Conversation
      ~scope:Global ~phase:Anytime ~echoes:true
      ~fate:(Switch_mode Mentat_session.Contract.Mode.Build) ();
    entry ~id:"sessions" ~slash:"/sessions" ~title:"Sessions"
      ~description:"Show recent sessions" ~category:Session ~scope:Global
      ~phase:Idle_only ~echoes:false ~fate:Open_sessions ();
    entry ~id:"settings" ~slash:"/settings" ~title:"Settings"
      ~description:"Open settings" ~category:App ~scope:Global ~phase:Anytime
      ~echoes:false ~fate:(Open_settings Config) ();
    entry ~id:"status" ~slash:"/status" ~title:"Status"
      ~description:"Show session and workspace status" ~category:App
      ~scope:Global ~phase:Anytime ~echoes:false ~fate:(Open_settings Status) ();
    entry ~id:"config" ~slash:"/config" ~title:"Config"
      ~description:"Show effective TUI configuration" ~category:App
      ~scope:Global ~phase:Anytime ~echoes:false ~fate:(Open_settings Config) ();
    entry ~id:"usage" ~slash:"/usage" ~title:"Usage"
      ~description:"Show active session token usage" ~category:App ~scope:Global
      ~phase:Anytime ~echoes:false ~fate:(Open_settings Usage) ();
    entry ~id:"login" ~slash:"/login" ~title:"Login"
      ~description:"Log in to a provider" ~argument_hint:"[provider]"
      ~category:App ~scope:Global ~phase:Anytime ~echoes:false ~fate:Open_login
      ();
    entry ~id:"logout" ~slash:"/logout" ~title:"Logout"
      ~description:"Log out of a provider" ~argument_hint:"[provider]"
      ~category:App ~scope:Global ~phase:Anytime ~echoes:false ~fate:Open_logout
      ();
    entry ~id:"quit" ~slash:"/quit" ~title:"Quit" ~description:"Exit Mentat"
      ~category:App ~scope:Global ~phase:Anytime ~echoes:false ~fate:Quit ();
    (* The command palette itself: Ctrl+G on every surface, Ctrl+P on the idle
       composer. Its Global scope resolves before per-surface routing. *)
    entry ~id:"command.palette" ~title:"Command palette"
      ~description:"Search and run any command" ~category:App ~scope:Global
      ~phase:Anytime
      ~keys:[ key "ctrl+g" Global; key ~on:Chat "ctrl+p" Global ]
      ~echoes:false ~fate:Open_palette ();
    (* Copy the terminal's current text selection. Global and key-less: reached
       from the palette on every surface, a no-op when nothing is selected. *)
    entry ~id:"copy.selection" ~title:"Copy selection"
      ~description:"Copy the current text selection to the clipboard"
      ~category:App ~scope:Global ~phase:Anytime ~echoes:false
      ~fate:Copy_selection ();
    (* App-level key gestures (Chat scope), folded from the former keymap. *)
    entry ~id:"interrupt" ~title:"Interrupt"
      ~description:"Cancel a picker, close a panel, interrupt a turn, arm quit"
      ~category:App ~scope:Chat ~phase:Anytime
      ~keys:[ key "escape" Chat ]
      ~echoes:false ~fate:Interrupt ();
    entry ~id:"history_search" ~title:"History search"
      ~description:"Begin incremental prompt-history search"
      ~category:Navigation ~scope:Chat ~phase:Anytime
      ~keys:[ key "ctrl+r" Chat ]
      ~echoes:false ~fate:History_search ();
    entry ~id:"toggle_expanded" ~title:"Toggle expanded"
      ~description:"Toggle expanded reasoning detail" ~category:View ~scope:Chat
      ~phase:Anytime
      ~keys:[ key "ctrl+o" Chat ]
      ~echoes:false ~fate:Toggle_expanded ();
    entry ~id:"transcript_page_up" ~title:"Page up"
      ~description:"Scroll the transcript up one page" ~category:Navigation
      ~scope:Chat ~phase:Anytime
      ~keys:[ key "pageup" Chat ]
      ~echoes:false ~fate:(Transcript_page `Up) ();
    entry ~id:"transcript_page_down" ~title:"Page down"
      ~description:"Scroll the transcript down one page" ~category:Navigation
      ~scope:Chat ~phase:Anytime
      ~keys:[ key "pagedown" Chat ]
      ~echoes:false ~fate:(Transcript_page `Down) ();
    entry ~id:"focus_switch" ~title:"Switch focus"
      ~description:"Move focus to the thread switcher" ~category:Navigation
      ~scope:Chat ~phase:Anytime
      ~keys:[ key "shift+tab" Chat ]
      ~echoes:false ~fate:Focus_switch ();
    entry ~id:"edit_in_editor" ~title:"Edit in editor"
      ~description:"Open the composer draft in the external editor"
      ~category:Conversation ~scope:Chat ~phase:Anytime
      ~keys:[ key "ctrl+x ctrl+e" Chat ]
      ~echoes:false ~fate:Edit_in_editor ();
    (* Sessions-screen verbs (Screen Sessions scope). *)
    entry ~id:"session.fork" ~title:"Fork session"
      ~description:"Fork the selected session" ~category:Session
      ~scope:(Screen Sessions) ~phase:Anytime
      ~keys:[ key "f" (Screen Sessions) ]
      ~echoes:false ~fate:Sessions_fork ();
    entry ~id:"session.rename" ~title:"Rename session"
      ~description:"Rename the selected session" ~category:Session
      ~scope:(Screen Sessions) ~phase:Anytime
      ~keys:[ key "r" (Screen Sessions) ]
      ~echoes:false ~fate:Sessions_rename ();
    entry ~id:"session.archive" ~title:"Archive session"
      ~description:"Archive the selected session" ~category:Session
      ~scope:(Screen Sessions) ~phase:Anytime
      ~keys:[ key "a" (Screen Sessions) ]
      ~echoes:false ~fate:Sessions_archive ();
    entry ~id:"session.restore" ~title:"Restore session"
      ~description:"Restore the selected session" ~category:Session
      ~scope:(Screen Sessions) ~phase:Anytime
      ~keys:[ key "u" (Screen Sessions) ]
      ~echoes:false ~fate:Sessions_restore ();
    entry ~id:"session.delete" ~title:"Delete session"
      ~description:"Permanently delete the selected session" ~category:Session
      ~scope:(Screen Sessions) ~phase:Anytime
      ~keys:[ key "d" (Screen Sessions) ]
      ~echoes:false ~fate:Sessions_delete ();
    (* Review-screen verbs (Screen Review scope). *)
    entry ~id:"review.toggle" ~title:"Toggle reviewed"
      ~description:"Toggle the reviewed mark on the focused unit" ~category:View
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "space" (Screen Review) ]
      ~echoes:false ~fate:Review_toggle ();
    entry ~id:"review.verdict" ~title:"Toggle verdict"
      ~description:"Toggle the overall review verdict" ~category:View
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "a" (Screen Review) ]
      ~echoes:false ~fate:Review_verdict ();
    entry ~id:"review.help" ~title:"Review help"
      ~description:"Toggle the review key help" ~category:View
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "?" (Screen Review) ]
      ~echoes:false ~fate:Review_help ();
    entry ~id:"review.compose_add" ~title:"Add comment"
      ~description:"Start a comment on the focused line" ~category:View
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "c" (Screen Review) ]
      ~echoes:false ~fate:(Review_compose `Add) ();
    entry ~id:"review.compose_edit" ~title:"Edit comment"
      ~description:"Edit the focused comment" ~category:View
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "e" (Screen Review) ]
      ~echoes:false ~fate:(Review_compose `Edit) ();
    entry ~id:"review.compose_resolve" ~title:"Resolve comment"
      ~description:"Resolve the focused comment" ~category:View
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "x" (Screen Review) ]
      ~echoes:false ~fate:(Review_compose `Resolve) ();
    entry ~id:"review.remove" ~title:"Remove comment"
      ~description:"Remove the focused comment" ~category:View
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "d" (Screen Review) ]
      ~echoes:false ~fate:Review_remove ();
    entry ~id:"review.next_hunk" ~title:"Next hunk"
      ~description:"Jump to the next hunk" ~category:Navigation
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "]" (Screen Review) ]
      ~echoes:false ~fate:Review_next_hunk ();
    entry ~id:"review.prev_hunk" ~title:"Previous hunk"
      ~description:"Jump to the previous hunk" ~category:Navigation
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "[" (Screen Review) ]
      ~echoes:false ~fate:Review_prev_hunk ();
    entry ~id:"review.next_cr" ~title:"Next comment"
      ~description:"Jump to the next comment" ~category:Navigation
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "n" (Screen Review) ]
      ~echoes:false ~fate:Review_next_cr ();
    entry ~id:"review.prev_cr" ~title:"Previous comment"
      ~description:"Jump to the previous comment" ~category:Navigation
      ~scope:(Screen Review) ~phase:Anytime
      ~keys:[ key "p" (Screen Review) ]
      ~echoes:false ~fate:Review_prev_cr ();
  ]

(* Accessors. *)

let id t = t.id
let slash t = t.slash
let title t = t.title
let description t = t.description
let category t = t.category
let argument_hint t = t.argument_hint
let scope t = t.availability.scope
let phase t = t.availability.phase
let echoes t = t.echoes
let fate t = t.fate
let equal a b = String.equal a.id b.id

let scope_equal a b =
  match (a, b) with
  | Global, Global | Chat, Chat -> true
  | Screen a, Screen b -> (
      match (a, b) with
      | Review, Review | Sessions, Sessions | Settings, Settings | Goal, Goal ->
          true
      | (Review | Sessions | Settings | Goal), _ -> false)
  | (Global | Chat | Screen _), _ -> false

let category_label = function
  | Session -> "session"
  | Conversation -> "conversation"
  | Navigation -> "navigation"
  | Model -> "model"
  | View -> "view"
  | App -> "app"

(* Structural sanity: the display order below carries no duplicate ids or
   slashes, so overlay lookups and slash parsing stay unambiguous. *)
let () =
  let rec loop ids slashes = function
    | [] -> ()
    | command :: rest ->
        if List.exists (String.equal command.id) ids then
          invalid_arg ("Command: duplicate id " ^ command.id);
        Option.iter
          (fun slash ->
            if List.exists (String.equal slash) slashes then
              invalid_arg ("Command: duplicate slash spelling " ^ slash))
          command.slash;
        loop (command.id :: ids) (Option.to_list command.slash @ slashes) rest
  in
  loop [] [] all

(* Slash matching. *)

let is_substring ~affix s =
  let affix_length = String.length affix and string_length = String.length s in
  if affix_length = 0 then true
  else if affix_length > string_length then false
  else
    let rec loop i =
      if i + affix_length > string_length then false
      else if String.equal (String.sub s i affix_length) affix then true
      else loop (i + 1)
    in
    loop 0

let matches_slash ~query t =
  match t.slash with
  | None -> false
  | Some slash ->
      is_substring ~affix:query (String.lowercase_ascii slash)
      || is_substring ~affix:query (String.lowercase_ascii t.title)

let filter ~query =
  let query = String.lowercase_ascii (trim_horizontal query) in
  List.filter (matches_slash ~query) all

let matches_palette ~query t =
  let query = String.lowercase_ascii (trim_horizontal query) in
  is_substring ~affix:query (String.lowercase_ascii t.title)
  || is_substring ~affix:query (category_label t.category)

let split_line line =
  let length = String.length line in
  let rec separator i =
    if i = length then None
    else match line.[i] with ' ' | '\t' -> Some i | _ -> separator (i + 1)
  in
  match separator 0 with
  | None -> (line, None)
  | Some i ->
      let token = String.sub line 0 i in
      let argument = trim_horizontal (String.sub line i (length - i)) in
      (token, if String.equal argument "" then None else Some argument)

let parse s =
  if contains_line_break s then None
  else
    let line = trim_horizontal s in
    if String.equal line "" then None
    else
      let token, argument = split_line line in
      let token = String.lowercase_ascii token in
      match
        List.find_opt
          (fun command ->
            match command.slash with
            | Some slash -> String.equal token slash
            | None -> false)
          all
      with
      | None -> None
      | Some command -> (
          match argument with
          | None -> Some (Exact command)
          | Some argument -> (
              match command.argument_hint with
              | None -> Some (Unexpected_argument (command, argument))
              | Some _ -> Some (With_argument (command, argument))))

(* Reserved vocabulary. Each scope carries a fixed set of chords that belong to
   widget navigation or editing and can therefore never carry a registry
   binding. This hand-maintained table is derived from the [panel.ml]/[screen.ml]
   classifiers, the review screen's focus-aware nav, and the composer textarea's
   readline map; a test asserts it stays a superset of what each classifier
   actually consumes (open question 2 in the design). *)

let global_reserved = [ chord_exn "ctrl+c" ]

(* The composer textarea's readline editing map (edit_surface.ml). *)
let chat_readline =
  List.map chord_exn
    [
      "ctrl+a";
      "ctrl+b";
      "ctrl+d";
      "ctrl+e";
      "ctrl+f";
      "ctrl+k";
      "ctrl+u";
      "ctrl+w";
      "ctrl+z";
      "ctrl+left";
      "ctrl+right";
      "ctrl+shift+left";
      "ctrl+shift+right";
    ]

(* Sessions screen classifier nav plus the [/] filter trigger. *)
let sessions_reserved =
  List.map chord_exn
    [
      "enter";
      "escape";
      "tab";
      "up";
      "down";
      "left";
      "right";
      "backspace";
      "pageup";
      "pagedown";
      "ctrl+p";
      "ctrl+n";
      "ctrl+d";
      "/";
    ]

(* Review screen classifier nav plus its focus-contextual movement keys. The
   remaining letters (space a ? c e x d ] [ n p) are the registry verbs. *)
let review_reserved =
  List.map chord_exn
    [
      "up";
      "down";
      "left";
      "right";
      "j";
      "k";
      "g";
      "tab";
      "enter";
      "home";
      "end";
      "pageup";
      "pagedown";
      "ctrl+p";
      "ctrl+n";
      "ctrl+o";
      "escape";
    ]

(* Settings and goal screens carry no registry verbs; their classifier nav is
   the generic screen vocabulary. *)
let screen_nav =
  List.map chord_exn
    [
      "enter";
      "escape";
      "tab";
      "up";
      "down";
      "left";
      "right";
      "backspace";
      "pageup";
      "pagedown";
      "ctrl+p";
      "ctrl+n";
    ]

let in_set set chord =
  List.exists (fun reserved -> Chord.conflict reserved chord) set

(* A single plain printable press is composer text (Chat) and never a binding. *)
let is_plain_printable chord =
  match Chord.presses chord with
  | [ { Chord.ctrl = false; alt = false; super = false; key; _ } ] -> (
      match key with
      | Matrix.Input.Key.Char u ->
          let code = Uchar.to_int u in
          code >= 0x20 && code <> 0x7f
      | _ -> false)
  | _ -> false

let reserved_vocabulary scope chord =
  match scope with
  | Global -> in_set global_reserved chord
  | Chat -> is_plain_printable chord || in_set chat_readline chord
  | Screen Sessions -> in_set sessions_reserved chord
  | Screen Review -> in_set review_reserved chord
  | Screen (Settings | Goal) -> in_set screen_nav chord

(* Every default binding obeys the law the overlay validator enforces: no
   binding's chord is reserved vocabulary on the surface it resolves. *)
let () =
  List.iter
    (fun command ->
      List.iter
        (fun binding ->
          if reserved_vocabulary binding.on binding.chord then
            invalid_arg
              (Printf.sprintf
                 "Command: default binding for %s is reserved on %s" command.id
                 (category_label App)))
        command.default_keys)
    all

(* Diagnostics. *)

module Diagnostic = struct
  type t =
    | Unknown_action of string
    | Bad_chord of { action : string; reason : string }
    | Reserved of { action : string; reason : string }
    | Reserved_vocabulary of { action : string; chord : string }
    | Conflict of { action : string; chord : string; conflicts_with : string }
    | Not_object

  let message = function
    | Unknown_action name -> Printf.sprintf "unknown action %S" name
    | Bad_chord { action; reason } ->
        Printf.sprintf "action %S: %s" action reason
    | Reserved { action; reason } ->
        Printf.sprintf "action %S: %s" action reason
    | Reserved_vocabulary { action; chord } ->
        Printf.sprintf
          "action %S: %S is reserved widget vocabulary and cannot be remapped"
          action chord
    | Conflict { action; chord; conflicts_with } ->
        Printf.sprintf "action %S: chord %S already bound to %S" action chord
          conflicts_with
    | Not_object ->
        "keybindings must be a JSON object mapping action ids to chords"

  let equal a b = String.equal (message a) (message b)
  let pp ppf diagnostic = Format.pp_print_string ppf (message diagnostic)
end

(* [Ctrl+C] is the non-remappable quit floor, and [interrupt] drives the whole
   Escape ladder, so it too is reserved: binding either is ignored with a
   diagnostic. *)
let reserved_floor = chord_exn "ctrl+c"

(* Overlay: id -> validated chords. Rejected entries fall back to the row's
   default, so resolution stays total and conflict-free. *)

(* The scopes on which a row's binding resolves: its default bindings' scopes,
   or, for a key-less row an overlay is binding for the first time, its own
   declared scope. *)
let binding_scopes command =
  match command.default_keys with
  | [] -> [ command.availability.scope ]
  | keys -> List.map (fun binding -> binding.on) keys

module Overlay = struct
  type t = (string * Chord.t list) list

  let empty = []
  let chords_for t id = List.assoc_opt id t

  let find_action id =
    List.find_opt (fun command -> String.equal command.id id) all

  (* The chord already bound to another same-scope action, so an overlay entry
     never creates a duplicate or shadowing binding. Only bindings that resolve
     on the same surface can collide; a Review verb and a Chat chord may reuse a
     key. Order-dependent by construction: an entry loses to any binding already
     present, default or from an earlier overlay entry. *)
  let same_scope_conflict acc command chord =
    let scopes = binding_scopes command in
    List.find_map
      (fun other ->
        if String.equal other.id command.id then None
        else
          let shared =
            List.exists
              (fun scope -> List.exists (scope_equal scope) scopes)
              (binding_scopes other)
          in
          if not shared then None
          else
            let others =
              match chords_for acc other.id with
              | Some cs -> cs
              | None -> List.map (fun b -> b.chord) other.default_keys
            in
            if List.exists (Chord.conflict chord) others then Some other.id
            else None)
      all

  let of_json json =
    let add_chord (map, diagnostics) command chord =
      if Chord.conflict chord reserved_floor then
        ( map,
          diagnostics
          @ [
              Diagnostic.Reserved
                {
                  action = command.id;
                  reason =
                    Chord.to_string chord
                    ^ " is reserved for quit and cannot be remapped";
                };
            ] )
      else if String.equal command.id "interrupt" then
        ( map,
          diagnostics
          @ [
              Diagnostic.Reserved
                {
                  action = command.id;
                  reason =
                    "interrupt is reserved on escape and cannot be remapped";
                };
            ] )
      else if
        List.exists
          (fun scope -> reserved_vocabulary scope chord)
          (binding_scopes command)
      then
        ( map,
          diagnostics
          @ [
              Diagnostic.Reserved_vocabulary
                { action = command.id; chord = Chord.to_string chord };
            ] )
      else
        match same_scope_conflict map command chord with
        | Some conflicts_with ->
            ( map,
              diagnostics
              @ [
                  Diagnostic.Conflict
                    {
                      action = command.id;
                      chord = Chord.to_string chord;
                      conflicts_with;
                    };
                ] )
        | None ->
            let existing =
              match chords_for map command.id with Some cs -> cs | None -> []
            in
            ( (command.id, existing @ [ chord ])
              :: List.remove_assoc command.id map,
              diagnostics )
    in
    let chords_of_value value =
      match value with
      | Jsont.String (raw, _) -> `One raw
      | Jsont.Array (items, _) ->
          `Many
            (List.map
               (function
                 | Jsont.String (raw, _) -> Ok raw
                 | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Array _
                 | Jsont.Object _ ->
                     Error "chord must be a string")
               items)
      | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _ -> `Bad
    in
    let fold_raw acc command raw =
      match Chord.of_string raw with
      | Error reason ->
          let map, diagnostics = acc in
          ( map,
            diagnostics
            @ [ Diagnostic.Bad_chord { action = command.id; reason } ] )
      | Ok chord -> add_chord acc command chord
    in
    let fold_entry acc ((name, _), value) =
      let map, diagnostics = acc in
      match find_action name with
      | None -> (map, diagnostics @ [ Diagnostic.Unknown_action name ])
      | Some command -> (
          match chords_of_value value with
          | `One raw -> fold_raw acc command raw
          | `Bad ->
              ( map,
                diagnostics
                @ [
                    Diagnostic.Bad_chord
                      { action = command.id; reason = "chord must be a string" };
                  ] )
          | `Many items ->
              List.fold_left
                (fun acc item ->
                  match item with
                  | Ok raw -> fold_raw acc command raw
                  | Error reason ->
                      let map, diagnostics = acc in
                      ( map,
                        diagnostics
                        @ [
                            Diagnostic.Bad_chord { action = command.id; reason };
                          ] ))
                acc items)
    in
    match json with
    | Jsont.Object (members, _) -> List.fold_left fold_entry (empty, []) members
    | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
    | Jsont.Array _ ->
        (empty, [ Diagnostic.Not_object ])
end

(* The effective binding of a row: the overlay chords when present, else its
   default chords whose [on] scope resolves on [surface]. *)
let effective_chords overlay command surface =
  if not (List.exists (scope_equal surface) (binding_scopes command)) then []
  else
    match Overlay.chords_for overlay command.id with
    | Some chords -> chords
    | None ->
        List.filter_map
          (fun binding ->
            if scope_equal binding.on surface then Some binding.chord else None)
          command.default_keys

(* The keybind shown in the palette: the row's first effective chord on any of
   its own binding scopes, preferring the overlay override. *)
let keybind overlay command =
  match Overlay.chords_for overlay command.id with
  | Some (chord :: _) -> Some (Chord.to_string chord)
  | Some [] -> None
  | None -> (
      match command.default_keys with
      | binding :: _ -> Some (Chord.to_string binding.chord)
      | [] -> None)

type resolution = [ `None | `Pending of t | `Action of t ]

let eligible ~phase command =
  match (command.availability.phase, phase) with
  | Anytime, _ -> true
  | Idle_only, Idle_only -> true
  | Idle_only, Anytime -> false

let resolve overlay ~surface ~phase ~pending event =
  let fresh () =
    let first_matches command =
      if not (eligible ~phase command) then None
      else
        let chords = effective_chords overlay command surface in
        List.find_map
          (fun chord ->
            match Chord.presses chord with
            | first :: rest when Chord.press_matches first event ->
                Some (command, rest)
            | _ -> None)
          chords
    in
    match List.find_map first_matches all with
    | None -> `None
    | Some (command, []) -> `Action command
    | Some (command, _ :: _) -> `Pending command
  in
  match pending with
  | None -> fresh ()
  | Some command ->
      let chords = effective_chords overlay command surface in
      let completes =
        List.exists
          (fun chord ->
            match Chord.presses chord with
            | [ _; second ] -> Chord.press_matches second event
            | _ -> false)
          chords
      in
      if completes then `Action command else fresh ()
