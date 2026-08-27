(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

let zero_size = { width = px 0; height = px 0 }
let fill_width = { width = pct 100; height = px 1 }
let hidden_overflow = { x = Overflow.Hidden; y = Overflow.Hidden }

let is_white_space uchar =
  match Uchar.to_int uchar with
  | 0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x20 | 0x85 | 0xA0 | 0x1680 | 0x2028
  | 0x2029 | 0x202F | 0x205F | 0x3000 ->
      true
  | code -> code >= 0x2000 && code <= 0x200A

let visibly_nonblank value =
  let rec loop offset =
    if offset >= String.length value then false
    else
      let decoded = String.get_utf_8_uchar value offset in
      if is_white_space (Uchar.utf_decode_uchar decoded) then
        loop (offset + Uchar.utf_decode_length decoded)
      else true
  in
  loop 0

let usable_option = function
  | None -> None
  | Some value ->
      let value = Prims.normalize_inline value in
      if visibly_nonblank value then Some value else None

let flexible_text ~priority style value =
  text ~style ~wrap:`None ~truncate:true ~flex_shrink:priority
    ~min_size:zero_size value

let shrinking_row ~priority ?min_size children =
  box ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow
    ~flex_shrink:priority ?min_size children

(* Safety identity never relies on the truncating text surface: the mark is an
   intrinsic child, while only its explanation yields to sibling facts. *)
let marked ?(prefix = "") ~priority style mark label =
  shrinking_row ~priority
    [ seg style (prefix ^ mark); flexible_text ~priority:1. style label ]

let permission_warning ~palette = function
  | Mentat_permission.Review_behavior.Enforce -> None
  | Mentat_permission.Review_behavior.Bypass ->
      Some
        (marked ~priority:0.
           (Theme.Palette.error_style palette)
           "!" " never ask · /settings")

let account_warning ~palette ~prefix =
  marked ~prefix ~priority:1.
    (Theme.Palette.error_style palette)
    "!" " not logged in · /login"

let prefixed_fact ~priority style value =
  flexible_text ~priority style (Theme.separator ^ value)

(* The compact context glance mirrors the pane's context section: the abbreviated
   occupancy and, when the model window is known, its fill percent — both
   precomputed by the caller so the two surfaces never disagree. It is the least
   load-bearing left fact, so its priority sheds it before the workspace path and
   the model line under width pressure. *)
let context_fact ~palette = function
  | Some (used, percent) when used > 0 ->
      let compact = Prims.compact_count used in
      let label =
        match percent with
        | Some pct -> Printf.sprintf "%s (%d%%)" compact pct
        | None -> compact
      in
      Some
        (prefixed_fact ~priority:200. (Theme.Palette.muted_style palette) label)
  | Some _ | None -> None

(* The launch sandbox posture is ambient status, not an identity fact: the
   permissive [workspace-write] default stays silent, a restrictive or delegated
   posture reads as a quiet fact, and only [danger-full-access] — no filesystem
   or network confinement — earns the loud safety mark. Its wording stays
   distinct from the permission-review warning so the two safety axes never read
   as one duplicated fact. *)
let sandbox_fact ~palette snapshot =
  match Snapshot.sandbox snapshot with
  | None -> None
  | Some label -> (
      match Mentat_config.Mode.of_string label with
      | None | Some Mentat_config.Mode.Workspace_write -> None
      | Some Mentat_config.Mode.Read_only ->
          Some
            (prefixed_fact ~priority:50.
               (Theme.Palette.muted_style palette)
               "read-only")
      | Some Mentat_config.Mode.External_sandbox ->
          Some
            (prefixed_fact ~priority:50.
               (Theme.Palette.muted_style palette)
               "external sandbox")
      | Some Mentat_config.Mode.Danger_full_access ->
          Some
            (marked ~prefix:Theme.separator ~priority:1.
               (Theme.Palette.error_style palette)
               "!" " full access"))

(* Untrusted is the loud kind of quiet: it degrades the whole session —
   project config unread, project tooling off — and its only other traces
   are absences (no dune row, fewer tools). One warned fact names it. *)
let trust_fact ~palette snapshot =
  if Snapshot.trusted snapshot then None
  else
    Some
      (marked ~prefix:Theme.separator ~priority:2.
         (Theme.Palette.warning_style palette)
         "!" " untrusted")

let normalized_model snapshot = Snapshot.model_line snapshot

let home_path ~palette ~prefix relative =
  let path =
    if Lpath.Rel.is_root relative then "~"
    else "~/" ^ (Lpath.Rel.to_string relative |> Prims.normalize_inline)
  in
  flexible_text ~priority:100.
    (Theme.Palette.muted_style palette)
    (prefix ^ path)

let absolute_path ~palette ~prefix path =
  flexible_text ~priority:100.
    (Theme.Palette.muted_style palette)
    (prefix ^ (Lpath.Abs.to_string path |> Prims.normalize_inline))

let workspace_path ~palette ~prefix (snapshot : Snapshot.t) =
  match Snapshot.home snapshot with
  | Some home -> (
      match Lpath.Abs.relativize ~root:home (Snapshot.cwd snapshot) with
      | Some relative -> home_path ~palette ~prefix relative
      | None -> absolute_path ~palette ~prefix (Snapshot.cwd snapshot))
  | None -> absolute_path ~palette ~prefix (Snapshot.cwd snapshot)

(* Grows to push the right affordance to the edge, yet never collapses fully:
   one reserved column keeps that affordance from abutting the left facts when
   the row overflows and the flexible gap would otherwise vanish. *)
let spacer =
  box ~flex_grow:1. ~flex_shrink:100.
    ~min_size:{ width = px 1; height = px 0 }
    ~size:{ width = auto; height = px 1 }
    []

let mode_row ~palette ~prefix ~hint ~badge =
  box ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow ~flex_grow:1.
    ~flex_shrink:1. ~min_size:zero_size
    [
      flexible_text ~priority:100.
        (Theme.Palette.faint_style palette)
        (prefix ^ hint);
      spacer;
      badge;
    ]

let shortcut ~palette =
  flexible_text ~priority:100.
    (Theme.Palette.faint_style palette)
    "? for shortcuts"

let plain_row ~palette ~prefix ~account_absent ~home_badge ~context snapshot =
  let home_content =
    match usable_option home_badge with
    | None -> shortcut ~palette
    | Some badge ->
        flexible_text ~priority:100. (Theme.Palette.accent_style palette) badge
  in
  let account =
    if account_absent then [ account_warning ~palette ~prefix ] else []
  in
  let cwd_prefix = if account_absent then Theme.separator else prefix in
  let cwd = workspace_path ~palette ~prefix:cwd_prefix snapshot in
  let model =
    prefixed_fact ~priority:25.
      (Theme.Palette.muted_style palette)
      (normalized_model snapshot)
  in
  let sandbox = Option.to_list (sandbox_fact ~palette snapshot) in
  let trust = Option.to_list (trust_fact ~palette snapshot) in
  let context = Option.to_list context in
  box ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow ~flex_grow:1.
    ~flex_shrink:1. ~min_size:zero_size
    (account @ [ cwd; model ] @ sandbox @ trust @ context
    @ [ spacer; home_content ])

let view ~palette ~permission_review ~input_mode ~account_absent ?home_badge
    ?context (snapshot : Snapshot.t) =
  let context = context_fact ~palette context in
  let warning = permission_warning ~palette permission_review in
  let prefix = match warning with None -> "" | Some _ -> Theme.separator in
  let content =
    match input_mode with
    | Composer.Input_mode.Plain ->
        plain_row ~palette ~prefix ~account_absent ~home_badge ~context snapshot
    | Composer.Input_mode.Shell ->
        mode_row ~palette ~prefix ~hint:"esc exit shell · ↵ run"
          ~badge:
            (seg
               (Theme.Palette.warning_style palette)
               (Theme.shell_marker ^ " shell"))
    | Composer.Input_mode.History_search ->
        mode_row ~palette ~prefix ~hint:"↵ insert · esc cancel · type to search"
          ~badge:
            (seg
               (Ansi.Style.make ~fg:(Theme.Palette.history palette) ())
               (Theme.history_marker ^ " history"))
  in
  let children = Option.to_list warning @ [ content ] in
  box ~key:"footer" ~flex_direction:Flex_direction.Row ~overflow:hidden_overflow
    ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0) ~size:fill_width children
