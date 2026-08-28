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

type root_action =
  | Adopt
  | Preempt_stale of int
  | Spawn
  | Settle
  | Reprobe_hold
  | Hold
  | Refuse of string

let supervise_action ~fence ~reachable ~head =
  match fence () with
  | `Io message -> Refuse ("the run fence could not be probed: " ^ message)
  | `Custodial -> Reprobe_hold
  | `Held_self -> Hold
  | `Held holder -> (
      if reachable () then Adopt
      else match holder with Some pid -> Preempt_stale pid | None -> Hold)
  | `Free -> (
      match head () with
      | `Unfinished -> Spawn
      | `Terminal -> Settle
      | `Absent -> Refuse "the session does not exist")
