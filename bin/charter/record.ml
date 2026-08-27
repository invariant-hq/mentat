(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type fence = [ `Free | `Held | `Io of string ]
type run = [ `Settle | `Leave | `Overdue | `Skip of string ]

let run_action ~fence ~overdue =
  match fence () with
  | `Io message -> `Skip message
  | `Held -> if overdue () then `Overdue else `Leave
  | `Free -> `Settle

type sweep = [ `Drive | `Republish of string | `Done ]

let sweep_action ~claimed ~spawned ~egress ~settled =
  if not claimed || not (spawned ()) then `Drive
  else if egress () then `Done
  else
    match settled () with
    | Some session -> `Republish session
    | None -> `Done
