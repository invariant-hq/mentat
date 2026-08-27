(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

let zero_size = { width = px 0; height = px 0 }
let fill_width = { width = pct 100; height = auto }
let horizontal_gap = { width = px 2; height = px 0 }
let vertical_gap = { width = px 0; height = px 1 }
let hidden_overflow = { x = Overflow.Hidden; y = Overflow.Hidden }

let validate_rows = function
  | [ _; _ ] as rows -> rows
  | _ -> invalid_arg "Banner.home: rows must contain exactly two lockup rows"

let inline ~style value =
  text ~style ~wrap:`None ~truncate:true ~flex_shrink:1. ~min_size:zero_size
    value

(* The two rows differ in width (letters + grain vs letters + heap), so they
   are centered as one block: per-row centering would land their left edges one
   column apart and pull the aloft grain off the mound's centre. *)
let home_lockup ~palette rows =
  box ~flex_direction:Flex_direction.Row ~justify_content:Justify.Center
    ~overflow:hidden_overflow ~flex_shrink:1. ~min_size:zero_size
    ~size:fill_width
    [
      box ~flex_direction:Flex_direction.Column ~flex_shrink:1.
        ~min_size:zero_size
        ~size:{ width = auto; height = auto }
        (List.map
           (fun row -> inline ~style:(Theme.Palette.accent_style palette) row)
           rows);
    ]

let home ~palette (snapshot : Snapshot.t) ~rows =
  let rows = validate_rows rows in
  let facts =
    box ~flex_direction:Flex_direction.Row ~justify_content:Justify.Center
      ~overflow:hidden_overflow ~flex_shrink:1. ~min_size:zero_size
      ~size:{ width = pct 100; height = px 1 }
      ([
         inline
           ~style:(Theme.Palette.muted_style palette)
           (Snapshot.version snapshot);
         text
           ~style:(Theme.Palette.muted_style palette)
           ~wrap:`None ~flex_shrink:0. Theme.separator;
         inline ~style:Ansi.Style.default (Snapshot.model_line snapshot);
       ]
      @
      if Snapshot.trusted snapshot then []
      else
        [
          text
            ~style:(Theme.Palette.muted_style palette)
            ~wrap:`None ~flex_shrink:0. Theme.separator;
          inline ~style:(Theme.Palette.warning_style palette) "untrusted";
        ])
  in
  box ~flex_direction:Flex_direction.Column ~align_items:Align.Center
    ~overflow:hidden_overflow ~flex_shrink:1. ~min_size:zero_size
    ~gap:vertical_gap ~size:fill_width
    [ home_lockup ~palette rows; facts ]

let record_lockup ~palette () =
  box ~flex_direction:Flex_direction.Column ~flex_shrink:1. ~min_size:zero_size
    ~size:{ width = auto; height = auto }
    (List.map
       (fun row -> inline ~style:(Theme.Palette.accent_style palette) row)
       Theme.lockup)

(* The facts column declares a small fixed flex basis and then grows: wrap
   decisions read the basis, not the content, so a long cwd can never push the
   column under the lockup on a wide row. The basis is the stacking threshold —
   rows narrower than lockup + gap + basis wrap the facts below, lockup
   intact; anything wider keeps one line and lets the inline text truncate. *)
let facts_basis = { width = px 20; height = auto }

let record_facts ~palette (snapshot : Snapshot.t) =
  box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
    ~min_size:zero_size ~size:facts_basis
    ([
       inline
         ~style:(Theme.Palette.muted_style palette)
         (Snapshot.version snapshot ^ Theme.separator
         ^ Snapshot.model_line snapshot);
       inline
         ~style:(Theme.Palette.muted_style palette)
         (Path_display.home_relative ~home:(Snapshot.home snapshot)
            (Snapshot.cwd snapshot));
     ]
    @
    if Snapshot.trusted snapshot then []
    else
      [ inline ~style:(Theme.Palette.warning_style palette) "untrusted" ])

let record ~palette (snapshot : Snapshot.t) =
  (* One flex line while the row affords lockup + the facts basis; narrower
     rows wrap the facts under the intact lockup declared by [facts_basis]. *)
  let head =
    box ~flex_direction:Flex_direction.Row ~flex_wrap:Flex_wrap.Wrap
      ~align_items:Align.Flex_start ~gap:horizontal_gap ~flex_shrink:1.
      ~min_size:zero_size ~size:fill_width
      [ record_lockup ~palette (); record_facts ~palette snapshot ]
  in
  box ~flex_direction:Flex_direction.Column ~padding:(padding 1)
    ~overflow:hidden_overflow ~flex_shrink:1. ~min_size:zero_size
    ~size:fill_width [ head ]
