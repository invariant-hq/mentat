(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Command = Mentat_tui.Command
module Chord = Mentat_tui.Chord
module Key = Matrix.Input.Key
module Modifier = Matrix.Input.Modifier

(* The command registry is a pure data transform with rich diagnostics — the
   sanctioned windtrap exception to the TUI's blackbox norm. This suite pins the
   chord parser, the scoped default resolutions, the two-press latch and its
   surface scoping, the reserved vocabulary, and the overlay diagnostics. *)

(* Event constructors for [resolve]. *)
let ctrl c = Key.of_char ~modifier:{ Modifier.none with Modifier.ctrl = true } c
let plain c = Key.of_char c
let named k = Key.make k
let shift k = Key.make ~modifier:{ Modifier.none with Modifier.shift = true } k
let by_id id = List.find (fun command -> Command.id command = id) Command.all

let resolution_to_string : Command.resolution -> string = function
  | `None -> "none"
  | `Pending command -> "pending:" ^ Command.id command
  | `Action command -> "action:" ^ Command.id command

let resolve ?(overlay = Command.Overlay.empty) ?(pending = None) ~surface event
    =
  Command.resolve overlay ~surface ~phase:Command.Idle_only ~pending event

(* A JSON object mapping action ids to chord strings. *)
let jo pairs =
  Jsont.Json.object'
    (List.map
       (fun (name, chord) ->
         Jsont.Json.mem (Jsont.Json.name name) (Jsont.Json.string chord))
       pairs)

let messages diagnostics = List.map Command.Diagnostic.message diagnostics

let chord_roundtrip =
  group "chord parsing"
    [
      test "canonical chords round-trip" (fun () ->
          List.iter
            (fun spelling ->
              match Chord.of_string spelling with
              | Ok chord ->
                  equal string ~msg:spelling spelling (Chord.to_string chord)
              | Error message -> failf "%s: %s" spelling message)
            [
              "escape";
              "ctrl+r";
              "ctrl+o";
              "shift+tab";
              "pageup";
              "pagedown";
              "ctrl+x ctrl+e";
            ]);
      test "the empty chord is rejected" (fun () ->
          match Chord.of_string "   " with
          | Error _ -> ()
          | Ok _ -> fail "expected an error for the empty chord");
      test "an unknown key is rejected" (fun () ->
          match Chord.of_string "ctrl+nope" with
          | Error message -> is_true (String.length message > 0)
          | Ok _ -> fail "expected an unknown-key error");
      test "an unknown modifier is rejected" (fun () ->
          match Chord.of_string "hyper+x" with
          | Error _ -> ()
          | Ok _ -> fail "expected an unknown-modifier error");
      test "more than two presses is rejected" (fun () ->
          match Chord.of_string "ctrl+a ctrl+b ctrl+c" with
          | Error _ -> ()
          | Ok _ -> fail "expected a too-long-chord error");
    ]

let default_resolution =
  let case name surface event expected =
    test name (fun () ->
        equal string ~msg:name expected
          (resolution_to_string (resolve ~surface event)))
  in
  group "default resolution"
    [
      case "ctrl+r begins history search" Command.Chat (ctrl 'r')
        "action:history_search";
      case "ctrl+o toggles expanded" Command.Chat (ctrl 'o')
        "action:toggle_expanded";
      case "escape interrupts" Command.Chat (named Key.Escape)
        "action:interrupt";
      case "shift+tab switches focus" Command.Chat (shift Key.Tab)
        "action:focus_switch";
      case "pageup pages the transcript up" Command.Chat (named Key.Page_up)
        "action:transcript_page_up";
      case "pagedown pages the transcript down" Command.Chat
        (named Key.Page_down) "action:transcript_page_down";
      case "ctrl+x arms the editor chord" Command.Chat (ctrl 'x')
        "pending:edit_in_editor";
      case "a bare letter is composer text on Chat" Command.Chat (plain 'a')
        "none";
      case "ctrl+g opens the palette on the global surface" Command.Global
        (ctrl 'g') "action:command.palette";
      case "ctrl+p is the chat palette alias" Command.Chat (ctrl 'p')
        "action:command.palette";
      case "the sessions screen forks on f" (Command.Screen Command.Sessions)
        (plain 'f') "action:session.fork";
      case "the sessions screen deletes on d" (Command.Screen Command.Sessions)
        (plain 'd') "action:session.delete";
      case "the review screen toggles verdict on a"
        (Command.Screen Command.Review) (plain 'a') "action:review.verdict";
      case "the review screen removes on d" (Command.Screen Command.Review)
        (plain 'd') "action:review.remove";
      test "ctrl+x ctrl+e completes the editor chord" (fun () ->
          equal string "action:edit_in_editor"
            (resolution_to_string
               (resolve ~surface:Command.Chat
                  ~pending:(Some (by_id "edit_in_editor"))
                  (ctrl 'e'))));
      test "an unrelated key abandons the latch and reclassifies" (fun () ->
          equal string ~msg:"ctrl+r after ctrl+x still searches history"
            "action:history_search"
            (resolution_to_string
               (resolve ~surface:Command.Chat
                  ~pending:(Some (by_id "edit_in_editor"))
                  (ctrl 'r'))));
      test "a pending chord cannot complete on another surface" (fun () ->
          (* The editor chord armed on Chat cannot complete on a screen: its
             binding does not resolve there, so the latch drops. *)
          equal string ~msg:"ctrl+e on the sessions screen is inert" "none"
            (resolution_to_string
               (resolve ~surface:(Command.Screen Command.Sessions)
                  ~pending:(Some (by_id "edit_in_editor"))
                  (ctrl 'e'))));
    ]

let reserved =
  group "reserved vocabulary"
    [
      test "Chat reserves printables and readline chords" (fun () ->
          let chord s = Result.get_ok (Chord.of_string s) in
          is_true (Command.reserved_vocabulary Command.Chat (chord "a"));
          is_true (Command.reserved_vocabulary Command.Chat (chord "ctrl+a"));
          is_false (Command.reserved_vocabulary Command.Chat (chord "ctrl+r")));
      test "screens keep their verb letters free" (fun () ->
          let chord s = Result.get_ok (Chord.of_string s) in
          is_false
            (Command.reserved_vocabulary (Command.Screen Command.Sessions)
               (chord "f"));
          is_true
            (Command.reserved_vocabulary (Command.Screen Command.Sessions)
               (chord "enter")));
      test "Global reserves only the Ctrl+C floor" (fun () ->
          let chord s = Result.get_ok (Chord.of_string s) in
          is_true (Command.reserved_vocabulary Command.Global (chord "ctrl+c"));
          is_false (Command.reserved_vocabulary Command.Global (chord "ctrl+g")));
    ]

let overlay =
  let resolves ~overlay ~surface event =
    resolution_to_string (resolve ~overlay ~surface event)
  in
  group "overlay of_json"
    [
      test "a valid remap overlays with no diagnostics" (fun () ->
          let overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("history_search", "ctrl+t") ])
          in
          equal (list string) ~msg:"no diagnostics" [] (messages diagnostics);
          equal string ~msg:"history search moved to ctrl+t"
            "action:history_search"
            (resolves ~overlay ~surface:Command.Chat (ctrl 't'));
          equal string ~msg:"the former default no longer resolves" "none"
            (resolves ~overlay ~surface:Command.Chat (ctrl 'r')));
      test "an unknown id is reported and skipped" (fun () ->
          let overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("nonsense", "ctrl+t") ])
          in
          equal (list string)
            [ {|unknown action "nonsense"|} ]
            (messages diagnostics);
          equal string ~msg:"map unchanged" "action:history_search"
            (resolves ~overlay ~surface:Command.Chat (ctrl 'r')));
      test "an unparseable chord keeps the default" (fun () ->
          let _overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("history_search", "ctrl+nope") ])
          in
          equal int ~msg:"one diagnostic" 1 (List.length diagnostics));
      test "a same-scope duplicate is a conflict, later entry loses" (fun () ->
          let overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("history_search", "ctrl+o") ])
          in
          equal (list string)
            [
              {|action "history_search": chord "ctrl+o" already bound to "toggle_expanded"|};
            ]
            (messages diagnostics);
          equal string ~msg:"history search kept its default"
            "action:history_search"
            (resolves ~overlay ~surface:Command.Chat (ctrl 'r')));
      test "a printable on Chat is rejected as reserved vocabulary" (fun () ->
          let _overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("history_search", "z") ])
          in
          equal (list string)
            [
              {|action "history_search": "z" is reserved widget vocabulary and cannot be remapped|};
            ]
            (messages diagnostics));
      test "cross-scope chord reuse is allowed" (fun () ->
          (* Binding a sessions verb to a chord a review verb also uses is safe:
             the two never share a surface. *)
          let overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("session.fork", "]") ])
          in
          equal (list string) ~msg:"no diagnostics" [] (messages diagnostics);
          equal string ~msg:"sessions fork resolves on the reused chord"
            "action:session.fork"
            (resolves ~overlay ~surface:(Command.Screen Command.Sessions)
               (plain ']'));
          equal string ~msg:"review still uses the same chord"
            "action:review.next_hunk"
            (resolves ~overlay:Command.Overlay.empty
               ~surface:(Command.Screen Command.Review) (plain ']')));
      test "the Ctrl+C floor cannot be rebound" (fun () ->
          let _overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("history_search", "ctrl+c") ])
          in
          equal (list string)
            [
              {|action "history_search": ctrl+c is reserved for quit and cannot be remapped|};
            ]
            (messages diagnostics));
      test "interrupt is reserved on escape" (fun () ->
          let _overlay, diagnostics =
            Command.Overlay.of_json (jo [ ("interrupt", "ctrl+t") ])
          in
          equal (list string)
            [
              {|action "interrupt": interrupt is reserved on escape and cannot be remapped|};
            ]
            (messages diagnostics));
      test "a non-object file falls back to defaults" (fun () ->
          let _overlay, diagnostics =
            Command.Overlay.of_json (Jsont.Json.string "oops")
          in
          equal (list string)
            [ "keybindings must be a JSON object mapping action ids to chords" ]
            (messages diagnostics));
    ]

(* Slash-line classification. The refusal arm is load-bearing: an argless
   builtin given an argument must be distinguishable from "not a command", or
   the composer submits the line as prose and silently starts a paid turn. *)
let parse_line =
  let classify text =
    match Command.parse text with
    | None -> "none"
    | Some (Command.Exact command) -> "exact:" ^ Command.id command
    | Some (Command.With_argument (command, argument)) ->
        Printf.sprintf "argument:%s:%s" (Command.id command) argument
    | Some (Command.Unexpected_argument (command, argument)) ->
        Printf.sprintf "unexpected:%s:%s" (Command.id command) argument
  in
  group "parse"
    [
      test "a bare builtin is exact" (fun () ->
          equal string "exact:model" (classify "/model"));
      test "an argless builtin with an argument is refused, not prose"
        (fun () ->
          equal string "unexpected:model:anthropic/claude-sonnet-5"
            (classify "/model anthropic/claude-sonnet-5"));
      test "an argument-taking builtin keeps its argument" (fun () ->
          equal string "argument:rename:Ship it" (classify "/rename Ship it"));
      test "an unknown command is not classified" (fun () ->
          equal string "none" (classify "/definitely-not-a-command x"));
    ]

let () =
  run "mentat.tui.command"
    [ chord_roundtrip; default_resolution; reserved; overlay; parse_line ]
