(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

let zero_size = { width = px 0; height = px 0 }
let fill_width = { width = pct 100; height = auto }
let plural n = if n = 1 then "" else "s"

(* Each status line carries the pane's two-column content inset, so the rows hang
   under their section header exactly like the task board's items. *)
let row segs =
  box ~flex_direction:Flex_direction.Row ~align_items:Align.Flex_start
    ~flex_shrink:0. ~min_size:zero_size ~size:fill_width
    (Prims.seg Ansi.Style.default "  " :: segs)

let sep ~palette = Prims.seg (Theme.Palette.muted_style palette) Theme.separator

(* The worktree diff (git, against the review base) and the session diff (this
   run's tool mutations) share a shape, so a labelled prefix is what tells them
   apart in the same section. *)
let diff_row ~palette ~label (stats : Textdiff.stats) =
  row
    [
      Prims.seg (Theme.Palette.muted_style palette) label;
      sep ~palette;
      Prims.seg
        (Theme.Palette.muted_style palette)
        (Printf.sprintf "%d file%s" stats.Textdiff.files
           (plural stats.Textdiff.files));
      sep ~palette;
      Prims.seg
        (Theme.Palette.success_style palette)
        (Printf.sprintf "+%d" stats.Textdiff.additions);
      Prims.seg Ansi.Style.default " ";
      Prims.seg
        (Theme.Palette.error_style palette)
        (Printf.sprintf "−%d" stats.Textdiff.deletions);
    ]

let diff_rows ~palette ~label = function
  | Some (stats : Textdiff.stats) when stats.Textdiff.files > 0 ->
      [ diff_row ~palette ~label stats ]
  | Some _ | None -> []

let worktree ~palette ~worktree = diff_rows ~palette ~label:"worktree" worktree
let changed ~palette ~changed = diff_rows ~palette ~label:"session" changed

(* The session-goal objective. In the pane its section header names it, so the
   bare row is the objective alone; the narrow strip has no headers, so
   [labelled] prefixes the muted [goal] tag that tells the row apart from the
   task rows beneath it. *)
let goal ~palette ~labelled ~objective =
  match objective with
  | None -> []
  | Some objective ->
      let content =
        text ~style:Ansi.Style.default ~wrap:`Word ~flex_grow:1. ~flex_shrink:1.
          ~min_size:zero_size objective
      in
      if labelled then
        [
          row
            [
              Prims.seg (Theme.Palette.muted_style palette) "goal";
              sep ~palette;
              content;
            ];
        ]
      else [ row [ content ] ]

(* Fail-honest: a verdict exists only inside a settled phase; the status
   itself is a fact about the watch and renders in every state but the two
   where nothing was attempted — tooling disabled, and no watch to attach to.
   Status words render muted; restarts warn; a foreign
   watch carries the [theirs] prefix so an owned one is tellable from it. *)
let dune_row ~palette segs =
  [ row (Prims.seg (Theme.Palette.muted_style palette) "dune" :: segs) ]

let muted_segs ~palette words =
  List.concat_map
    (fun word ->
      [ sep ~palette; Prims.seg (Theme.Palette.muted_style palette) word ])
    words

let warning_segs ~palette words =
  List.concat_map
    (fun word ->
      [ sep ~palette; Prims.seg (Theme.Palette.warning_style palette) word ])
    words

let verdict_segs ~palette (verdict : Mentat_workspace.Health.Verdict.t) =
  match verdict with
  | Mentat_workspace.Health.Verdict.Clean ->
      [ Prims.seg (Theme.Palette.success_style palette) "clean" ]
  | Mentat_workspace.Health.Verdict.Failing { errors = 0; warnings } ->
      [
        Prims.seg
          (Theme.Palette.warning_style palette)
          (Printf.sprintf "%d warning%s" warnings (plural warnings));
      ]
  | Mentat_workspace.Health.Verdict.Failing { errors; warnings = _ } ->
      [
        Prims.seg
          (Theme.Palette.error_style palette)
          (Printf.sprintf "%d error%s" errors (plural errors));
      ]

(* The lint lane's own row, under the dune row. [None] is absence — lane
   off or targets unknown — and renders nothing: absence is never
   cleanliness. The label is the lane's ([lint], as the notices and doctor
   spell it): the wire carries no linter name, and the lane is
   deliberately linter-agnostic. *)
let lint_row ~palette lint =
  match lint with
  | None -> []
  | Some n ->
      [
        row
          [
            Prims.seg (Theme.Palette.muted_style palette) "lint";
            sep ~palette;
            (if n = 0 then
               Prims.seg (Theme.Palette.success_style palette) "clean"
             else
               Prims.seg
                 (Theme.Palette.warning_style palette)
                 (Printf.sprintf "%d finding%s" n (plural n)));
          ];
      ]

let owner_segs ~palette (owner : Mentat_workspace.Health.Owner.t) =
  match owner with
  | Mentat_workspace.Health.Owner.Ours -> []
  | Mentat_workspace.Health.Owner.Theirs _ -> muted_segs ~palette [ "theirs" ]

let tooling ~palette ~tooling =
  match (tooling : Mentat_workspace.Health.t) with
  | Mentat_workspace.Health.Off Mentat_workspace.Health.Off.Disabled -> []
  | Mentat_workspace.Health.Off Mentat_workspace.Health.Off.No_server ->
      dune_row ~palette (muted_segs ~palette [ "off"; "no watch" ])
  | Mentat_workspace.Health.Off Mentat_workspace.Health.Off.No_dune ->
      dune_row ~palette (muted_segs ~palette [ "off"; "not on PATH" ])
  | Mentat_workspace.Health.Off (Mentat_workspace.Health.Off.Blocked _) ->
      dune_row ~palette (muted_segs ~palette [ "off"; "sandboxed watcher" ])
  | Mentat_workspace.Health.Off Mentat_workspace.Health.Off.Gave_up ->
      dune_row ~palette (muted_segs ~palette [ "off"; "gave up" ])
  | Mentat_workspace.Health.Probing | Mentat_workspace.Health.Starting ->
      dune_row ~palette (muted_segs ~palette [ "starting" ])
  | Mentat_workspace.Health.Restarting Mentat_workspace.Health.Restart.Hung ->
      dune_row ~palette (warning_segs ~palette [ "hung"; "restarting" ])
  | Mentat_workspace.Health.Restarting
      (Mentat_workspace.Health.Restart.Exited detail) ->
      dune_row ~palette
        (warning_segs ~palette [ Printf.sprintf "restarting (%s)" detail ])
  | Mentat_workspace.Health.Live { owner; phase } -> (
      let prefix = owner_segs ~palette owner in
      match phase with
      | Mentat_workspace.Health.Phase.Building ->
          dune_row ~palette (prefix @ muted_segs ~palette [ "building" ])
      | Mentat_workspace.Health.Phase.Settled { build; lint } ->
          dune_row ~palette
            (prefix @ (sep ~palette :: verdict_segs ~palette build))
          @ lint_row ~palette lint)

let muted_row ~palette value =
  row [ Prims.seg (Theme.Palette.muted_style palette) value ]

(* Untrusted degrades the whole session — project config unread, project
   tooling off — and its other traces are absences (no dune row among
   them). The section states it instead of letting each absence speak. *)
let trust ~palette ~trusted =
  if trusted then []
  else [ row [ Prims.seg (Theme.Palette.warning_style palette) "untrusted" ] ]

(* Dollars to cents, always two places: an existing rate can spell a real but
   sub-cent spend as "$0.00", which is honest — the row is omitted only when the
   catalog carries no rate at all (see {!context}'s [spent = None]). *)
let spent_row ~palette dollars =
  muted_row ~palette (Printf.sprintf "$%.2f spent" dollars)

let context ~palette ~context ~spent =
  match context with
  | Some (used, percent) when used > 0 ->
      let tokens =
        muted_row ~palette
          (Printf.sprintf "%s tokens" (Prims.group_digits used))
      in
      let percent_rows =
        match percent with
        | Some pct -> [ muted_row ~palette (Printf.sprintf "%d%% used" pct) ]
        | None -> []
      in
      let spent_rows =
        match spent with
        | Some dollars -> [ spent_row ~palette dollars ]
        | None -> []
      in
      (tokens :: percent_rows) @ spent_rows
  | _ -> []

(* A background process's liveness keyword. A nonzero exit or a killing signal is
   the only status that earns colour; a clean exit, a still-running child, and a
   we-terminated child stay muted (the row leaves the list on the next poll). *)
let status_label (status : Mentat_protocol.Process.Status.t) =
  match status with
  | Mentat_protocol.Process.Status.Running -> "running"
  | Mentat_protocol.Process.Status.Exited code ->
      Printf.sprintf "exited %d" code
  | Mentat_protocol.Process.Status.Signaled signal ->
      Printf.sprintf "signaled %d" signal
  | Mentat_protocol.Process.Status.Terminated -> "terminated"

let status_style ~palette (status : Mentat_protocol.Process.Status.t) =
  match status with
  | Mentat_protocol.Process.Status.Exited 0
  | Mentat_protocol.Process.Status.Running
  | Mentat_protocol.Process.Status.Terminated ->
      Theme.Palette.muted_style palette
  | Mentat_protocol.Process.Status.Exited _
  | Mentat_protocol.Process.Status.Signaled _ ->
      Theme.Palette.error_style palette

(* A compact age, largest whole unit only: seconds under a minute, then minutes,
   then hours. Non-negative by the view's invariant. *)
let age_label ms =
  let s = ms / 1000 in
  if s < 60 then Printf.sprintf "%ds" s
  else if s < 3600 then Printf.sprintf "%dm" (s / 60)
  else Printf.sprintf "%dh" (s / 3600)

(* The command is the one variable-width field, so it alone shrinks and truncates
   (Mosaic owns the elision); the handle, status, and age hold at their intrinsic
   width beside it. *)
let running_row ~palette view =
  box ~flex_direction:Flex_direction.Row ~align_items:Align.Flex_start
    ~flex_shrink:0. ~min_size:zero_size ~size:fill_width
    [
      Prims.seg Ansi.Style.default "  ";
      Prims.seg
        (Theme.Palette.muted_style palette)
        (Mentat_protocol.Process.View.handle view);
      sep ~palette;
      text
        ~style:(Theme.Palette.muted_style palette)
        ~wrap:`None ~truncate:true ~flex_shrink:1. ~min_size:zero_size
        (Prims.normalize_inline (Mentat_protocol.Process.View.command view));
      sep ~palette;
      Prims.seg
        (status_style ~palette (Mentat_protocol.Process.View.status view))
        (status_label (Mentat_protocol.Process.View.status view));
      sep ~palette;
      Prims.seg
        (Theme.Palette.muted_style palette)
        (age_label (Mentat_protocol.Process.View.age_ms view));
    ]

let running ~palette ~running = List.map (running_row ~palette) running
