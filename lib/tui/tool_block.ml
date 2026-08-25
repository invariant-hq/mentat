(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

type verb =
  | Read
  | List
  | Search
  | Glob
  | Edit
  | Patch
  | Create
  | Shell
  | Shell_output
  | Shell_kill
  | Fetch
  | Web_search
  | Task
  | Todo
  | Diagnostics
  | Ocaml_search
  | Ocaml_edit
  | Ocaml_replace
  | Ocaml_rename
  | Ocaml_eval
  | Ocaml_docs
  | Ocaml_type
  | Ocaml_definition
  | Ocaml_references
  | Skill
  | Plan
  | Message
  | Follow_up
  | Cancel
  | Wait
  | Question
  | Other of string

type dot = Running | Awaiting | Succeeded | Failed | Warned | Ambiguous
type edge = First | Last
type detail = Preview of { lines : string list; edge : edge; max_rows : int }

type t = {
  verb : verb;
  argument : string;
  dot : dot;
  summary : string;
  facts : string list;
  detail : detail option;
}

type text_shape = Inline | Block

let is_control code = code < 0x20 || (code >= 0x7f && code <= 0x9f)

(* Normalize untrusted presentation text before it reaches Mosaic. Invalid UTF-8
   and terminal controls become visible replacement characters. Line boundaries
   remain meaningful in result prose but become one space in one-row fields. *)
let normalize shape text =
  let buffer = Buffer.create (String.length text) in
  let newline () =
    Buffer.add_char buffer (match shape with Inline -> ' ' | Block -> '\n')
  in
  let rec loop offset =
    if offset < String.length text then
      let decoded = String.get_utf_8_uchar text offset in
      let length = Uchar.utf_decode_length decoded in
      if not (Uchar.utf_decode_is_valid decoded) then (
        Buffer.add_utf_8_uchar buffer Uchar.rep;
        loop (offset + length))
      else
        let uchar = Uchar.utf_decode_uchar decoded in
        let code = Uchar.to_int uchar in
        if code = 0x0d then (
          newline ();
          let next = offset + length in
          let next =
            if next < String.length text && Char.equal text.[next] '\n' then
              next + 1
            else next
          in
          loop next)
        else if code = 0x0a || code = 0x2028 || code = 0x2029 then (
          newline ();
          loop (offset + length))
        else if code = 0x09 then (
          Buffer.add_string buffer "  ";
          loop (offset + length))
        else if is_control code then (
          Buffer.add_utf_8_uchar buffer Uchar.rep;
          loop (offset + length))
        else (
          Buffer.add_utf_8_uchar buffer uchar;
          loop (offset + length))
  in
  loop 0;
  Buffer.contents buffer

let is_unicode_space code =
  code = 0x20 || code = 0x85 || code = 0xa0 || code = 0x1680
  || (code >= 0x2000 && code <= 0x200a)
  || code = 0x2028 || code = 0x2029 || code = 0x202f || code = 0x205f
  || code = 0x3000

let has_visible_text text =
  let grapheme_is_space grapheme =
    let rec loop offset =
      if offset >= String.length grapheme then true
      else
        let decoded = String.get_utf_8_uchar grapheme offset in
        let code = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
        is_unicode_space code && loop (offset + Uchar.utf_decode_length decoded)
    in
    loop 0
  in
  try
    Matrix.Text.iter_grapheme_info ~width_method:`Unicode ~tab_width:2
      (fun ~offset ~len ~width ->
        let grapheme = String.sub text offset len in
        if width > 0 && not (grapheme_is_space grapheme) then raise Exit)
      text;
    false
  with Exit -> true

let label = function
  | Read -> "Read"
  | List -> "List"
  | Search -> "Search"
  | Glob -> "Glob"
  | Edit -> "Edit"
  | Patch -> "Patch"
  | Create -> "Create"
  | Shell -> "Shell"
  | Shell_output -> "Shell Output"
  | Shell_kill -> "Shell Kill"
  | Fetch -> "Fetch"
  | Web_search -> "Web Search"
  | Task -> "Task"
  | Todo -> "Todo"
  | Diagnostics -> "Diagnostics"
  | Ocaml_search -> "OCaml Search"
  | Ocaml_edit -> "OCaml Edit"
  | Ocaml_replace -> "OCaml Replace"
  | Ocaml_rename -> "OCaml Rename"
  | Ocaml_eval -> "OCaml Eval"
  | Ocaml_docs -> "OCaml Docs"
  | Ocaml_type -> "OCaml Type"
  | Ocaml_definition -> "OCaml Definition"
  | Ocaml_references -> "OCaml References"
  | Skill -> "Skill"
  | Plan -> "Plan"
  | Message -> "Message"
  | Follow_up -> "Follow-up"
  | Cancel -> "Cancel"
  | Wait -> "Wait"
  | Question -> "Question"
  | Other name ->
      let name = String.trim (normalize Inline name) in
      if has_visible_text name then String.capitalize_ascii name else "Tool"

let fallback_summary = function
  | Running -> "running"
  | Awaiting -> "waiting for approval"
  | Succeeded -> "done"
  | Failed -> "failed"
  | Warned -> "warning"
  | Ambiguous -> "outcome unknown"

let display_summary ~fallback summary =
  let summary = normalize Block summary in
  if has_visible_text summary then summary else fallback

let preview ~take ~max_rows lines =
  if max_rows < 0 then
    invalid_arg "Tool_block.preview: max_rows must be non-negative";
  let edge = match take with `First -> First | `Last -> Last in
  let lines = List.map (normalize Inline) lines in
  Preview { lines; edge; max_rows }

let make verb ~argument ~dot ~summary ?(facts = []) ?detail () =
  let facts =
    facts |> List.map (normalize Inline) |> List.filter has_visible_text
  in
  {
    verb;
    argument = normalize Inline argument;
    dot;
    summary = display_summary ~fallback:(fallback_summary dot) summary;
    facts;
    detail;
  }

let dot_style ~palette = function
  | Running -> Theme.Palette.running_style palette
  | Awaiting -> Theme.Palette.muted_style palette
  | Succeeded -> Ansi.Style.make ~fg:(Theme.Palette.success palette) ()
  | Failed -> Theme.Palette.error_style palette
  | Warned | Ambiguous -> Theme.Palette.warning_style palette

let zero_size = { width = px 0; height = px 0 }
let fill_width = { width = pct 100; height = auto }
let hidden_overflow = { x = Overflow.Hidden; y = Overflow.Hidden }
let horizontal_gap = { width = px 1; height = px 0 }

let header ~palette verb ~argument ~dot =
  let argument = normalize Inline argument in
  let title =
    let argument =
      if has_visible_text argument then
        [
          text ~style:Ansi.Style.default ~wrap:`None ~truncate:true
            ~flex_shrink:100. ~min_size:zero_size
            ("(" ^ argument ^ ")");
        ]
      else []
    in
    box ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow
      ~flex_grow:1. ~flex_shrink:1. ~min_size:zero_size ~size:fill_width
      (text ~style:Theme.bold ~wrap:`None ~truncate:true ~flex_shrink:1.
         ~min_size:zero_size (label verb)
      :: argument)
  in
  box ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow
    ~gap:horizontal_gap ~flex_shrink:0. ~min_size:zero_size
    ~size:{ width = pct 100; height = px 1 }
    [
      text ~style:(dot_style ~palette dot) ~wrap:`None ~flex_shrink:0.
        Theme.tool;
      title;
    ]

let result ~palette ~summary ~facts =
  let summary = display_summary ~fallback:"done" summary in
  let facts =
    facts |> List.map (normalize Inline) |> List.filter has_visible_text
  in
  let body =
    summary
    ^ String.concat "" (List.map (fun fact -> Theme.separator ^ fact) facts)
  in
  box ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow
    ~gap:{ width = px 2; height = px 0 }
    ~padding:(padding_lrtb 2 0 0 0) ~min_size:zero_size ~size:fill_width
    [
      text
        ~style:(Theme.Palette.muted_style palette)
        ~wrap:`None ~flex_shrink:0. Theme.gutter;
      text
        ~style:(Theme.Palette.muted_style palette)
        ~wrap:`Word ~flex_grow:1. ~flex_shrink:1. ~min_size:zero_size body;
    ]

let detail_row ~palette line =
  text
    ~style:(Theme.Palette.muted_style palette)
    ~wrap:`None ~truncate:true ~flex_shrink:1. ~min_size:zero_size line

let overflow_marker ~palette hidden =
  text
    ~style:(Theme.Palette.faint_style palette)
    ~wrap:`None ~flex_shrink:0.
    (Printf.sprintf "… +%d %s" hidden (if hidden = 1 then "line" else "lines"))

(* A settled result is static scrollback: the whole transcript scrolls in the
   terminal, so bounded output is clamped to at most [max_rows] plain rows with
   a faint overflow marker rather than an inner scroll region. [First] keeps the
   head and marks the hidden tail below; [Last] keeps the tail and marks the
   hidden head above, so the marker always sits on the elided edge. *)
let detail_view ~palette (Preview { lines; edge; max_rows }) =
  let total = List.length lines in
  (* A single hidden line costs the same row as the marker that would elide it,
     so show the line itself rather than "… +1 line". *)
  let hidden = if total - max_rows <= 1 then 0 else total - max_rows in
  let shown =
    if hidden = 0 then lines
    else
      match edge with
      | First -> List.filteri (fun index _ -> index < max_rows) lines
      | Last -> List.filteri (fun index _ -> index >= total - max_rows) lines
  in
  let rows = List.map (detail_row ~palette) shown in
  let body =
    if hidden = 0 then rows
    else
      match edge with
      | First -> rows @ [ overflow_marker ~palette hidden ]
      | Last -> overflow_marker ~palette hidden :: rows
  in
  box ~flex_direction:Flex_direction.Column ~overflow:hidden_overflow
    ~padding:(padding_lrtb 6 0 0 0) ~flex_shrink:0. ~min_size:zero_size
    ~size:fill_width body

let view ~palette t =
  let detail =
    match t.detail with
    | None -> []
    | Some detail -> [ detail_view ~palette detail ]
  in
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0. ~size:fill_width
    (header ~palette t.verb ~argument:t.argument ~dot:t.dot
    :: result ~palette ~summary:t.summary ~facts:t.facts
    :: detail)
