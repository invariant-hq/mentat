(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

type choice = Untrusted | Trusted
type 'a outcome = Continue of 'a | Exit_prompt

(* [root] is the workspace as the rest of the TUI shows it — home-relative when
   the repository lives under the user's home — so the trust gate names one
   workspace the same way the banner, footer and status screens do. The
   absolute root stays with the caller, which owns trust identity and
   persistence; nothing here depends on this spelling. *)
type model = { root : string; selected : int; notice : string option }
type msg = Move of int | Activate of int | Leave

let accent = Ansi.Color.of_rgb 214 96 60
let muted = Ansi.Color.grayscale ~level:14
let error = Ansi.Color.of_rgb 255 95 95
let title_style = Ansi.Style.make ~fg:accent ~bold:true ()
let selection_style = Ansi.Style.make ~fg:accent ~bold:true ()
let muted_style = Ansi.Style.make ~fg:muted ()
let error_style = Ansi.Style.make ~fg:error ~bold:true ()

let selected_label = function
  | 0 -> "Selection: 1 — continue restricted"
  | 1 -> "Selection: 2 — trust and activate this repository"
  | _ -> "Selection: 3 — exit without saving a decision"

let choice_view ~selected ~index ~label ~description =
  let active = Int.equal selected index in
  let marker = if active then "❯" else " " in
  let style = if active then selection_style else Ansi.Style.default in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    [
      box ~flex_direction:Flex_direction.Row
        ~size:{ width = pct 100; height = auto }
        [
          text ~wrap:`None ~flex_shrink:0. ~style
            (Printf.sprintf "%s %d. " marker (index + 1));
          text ~wrap:`Word ~flex_grow:1. ~style label;
        ];
      box ~padding:(padding_lrtb 3 0 0 0)
        [ text ~style:muted_style ~wrap:`Word description ];
    ]

let key_message selected event =
  let data = Event.Key.data event in
  let modifier = data.Matrix.Input.Key.modifier in
  let no_command_modifier =
    (not modifier.Matrix.Input.Modifier.ctrl)
    && (not modifier.Matrix.Input.Modifier.alt)
    && (not modifier.Matrix.Input.Modifier.super)
    && (not modifier.Matrix.Input.Modifier.hyper)
    && not modifier.Matrix.Input.Modifier.meta
  in
  let control scalar code letter =
    Uchar.to_int scalar = code
    || modifier.Matrix.Input.Modifier.ctrl
       && Uchar.equal scalar (Uchar.of_char letter)
  in
  let handled message =
    Event.Key.prevent_default event;
    Some message
  in
  match data.Matrix.Input.Key.event_type with
  | Matrix.Input.Key.Release -> None
  | Matrix.Input.Key.Press | Matrix.Input.Key.Repeat -> (
      match data.Matrix.Input.Key.key with
      | Matrix.Input.Key.Up when no_command_modifier -> handled (Move (-1))
      | Matrix.Input.Key.Down when no_command_modifier -> handled (Move 1)
      | Matrix.Input.Key.Enter | Matrix.Input.Key.Line_feed
      | Matrix.Input.Key.KP_enter ->
          handled (Activate selected)
      | Matrix.Input.Key.Escape -> handled Leave
      | Matrix.Input.Key.Char scalar when control scalar 0x03 'c' ->
          handled Leave
      | Matrix.Input.Key.Char scalar when control scalar 0x04 'd' ->
          handled Leave
      | Matrix.Input.Key.Char scalar when no_command_modifier -> (
          match Uchar.to_int scalar with
          | 0x31 -> handled (Activate 0)
          | 0x32 -> handled (Activate 1)
          | 0x33 -> handled (Activate 2)
          | _ -> None)
      | _ -> None)

let view model =
  let notice =
    match model.notice with
    | None -> []
    | Some message ->
        [
          box ~padding:(padding_lrtb 0 0 1 0)
            [ text ~style:error_style ~wrap:`Word message ];
        ]
  in
  let content =
    [
      text ~wrap:`Word ("Repository root: " ^ model.root);
      text ~style:selection_style ~wrap:`Word (selected_label model.selected);
    ]
    @ notice
    @ [
        text "";
        text ~wrap:`Word
          "This repository can control config, instructions, skills, Dune \
           rules, local tools, evaluator, and Build-mode project processes. \
           Activation does not approve operations or widen the selected \
           sandbox.";
        text "";
        choice_view ~selected:model.selected ~index:0
          ~label:"Continue restricted — remember this choice"
          ~description:
            "Native reads, searches, and sandboxed edits remain available. \
             Repository-controlled code will not run. Files edited now may \
             execute if you activate the repository later.";
        choice_view ~selected:model.selected ~index:1
          ~label:"Trust and activate this repository — remember this choice"
          ~description:
            "Repository inputs and Build processes activate after reload.";
        choice_view ~selected:model.selected ~index:2 ~label:"Exit"
          ~description:"Save nothing and start no project process.";
      ]
  in
  box ~id:"workspace-trust-prompt" ~focusable:true ~autofocus:true
    ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = pct 100 }
    [
      box ~flex_shrink:0. ~padding:(padding_lrtb 1 1 1 0)
        [ text ~style:title_style "Mentat repository activation" ];
      scroll_box ~key:"workspace-trust-content" ~scroll_x:false ~scroll_y:true
        ~show_scrollbars:false ~focusable:false ~flex_grow:1. ~flex_shrink:1.
        ~min_size:{ width = auto; height = px 0 }
        [
          box ~flex_direction:Flex_direction.Column
            ~padding:(padding_lrtb 1 1 1 1)
            ~size:{ width = pct 100; height = auto }
            content;
        ];
      box ~flex_shrink:0. ~padding:(padding_lrtb 1 1 0 1)
        [
          text ~style:muted_style ~wrap:`Word
            "Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.";
        ];
    ]

let run ?notice ?home ~stdenv ~root ~decide () =
  let outcome = ref None in
  let init () =
    ( {
        root = Mentat_tui.Path_display.home_relative ~home root;
        selected = 0;
        notice;
      },
      Cmd.none )
  in
  let update message model =
    match message with
    | Move delta ->
        ({ model with selected = (model.selected + delta + 3) mod 3 }, Cmd.none)
    | Leave ->
        outcome := Some Exit_prompt;
        ({ model with selected = 2 }, Cmd.quit)
    | Activate 2 ->
        outcome := Some Exit_prompt;
        ({ model with selected = 2 }, Cmd.quit)
    | Activate selected -> (
        let choice = if Int.equal selected 0 then Untrusted else Trusted in
        match decide choice with
        | Ok value ->
            outcome := Some (Continue value);
            ({ model with selected }, Cmd.quit)
        | Error failure ->
            ({ model with selected; notice = Some failure }, Cmd.none))
  in
  Eio.Switch.run ~name:"mentat-workspace-trust-prompt" @@ fun sw ->
  let matrix =
    Matrix_eio.create ~mode:`Alt ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~stdin:stdenv#stdin ~stdout:stdenv#stdout ~target_fps:(Some 30.)
      ~mouse_enabled:false ~cursor_visible:false ~exit_on_ctrl_c:false
      ~start_idle:true ()
  in
  Mosaic.run ~matrix
    {
      init;
      update;
      view;
      subscriptions =
        (fun model -> Mosaic.Sub.on_key_all (key_message model.selected));
    };
  Option.value !outcome ~default:Exit_prompt
