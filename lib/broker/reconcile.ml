(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type fence =
  [ `Free | `Held_self | `Held of int option | `Custodial | `Io of string ]

type head = [ `Unfinished | `Terminal | `Absent ]

type action =
  | Observe
  | Preempt of int
  | Respawn
  | Dispose
  | Stand_down
  | Reprobe
  | Fail of string

let decide ~fence ~reachable ~head =
  match fence () with
  | `Io message -> Fail ("the run fence could not be probed: " ^ message)
  | `Held_self -> Stand_down
  | `Custodial -> Reprobe
  | `Held holder -> (
      if reachable () then Observe
      else
        match holder with
        | Some pid -> Preempt pid
        | None ->
            Fail
              "the run fence is held by a process the broker may not preempt")
  | `Free -> (
      match head () with
      | `Unfinished -> Respawn
      | `Terminal | `Absent -> Dispose)

type boot =
  [ `Adopt
  | `Adopt_and_watch
  | `Watch
  | `Adopt_and_dispose
  | `Dispose
  | `Skip of string ]

let boot_action ~fence ~head ~parent =
  match (fence, head, parent) with
  | `Io, _, _ -> `Skip "the run fence could not be probed"
  | _, _, `Absent -> (
      match fence with
      | `Free -> `Dispose
      | `Held | `Io -> `Skip "an orphan with no parent integrates nowhere")
  | `Held, _, `Waiting -> `Adopt_and_watch
  | `Held, _, `Idle -> `Watch
  | `Free, `Unfinished, _ -> `Adopt
  | `Free, (`Terminal | `Absent), `Waiting -> `Adopt_and_dispose
  | `Free, (`Terminal | `Absent), `Idle -> `Dispose
