(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The shared notification hook — one owner-configured command, one JSON
    event on its standard input.

    Every notifying surface fires the same way: the configured argv is
    spawned as-is and the event is written to the child's stdin as a single
    minified JSON line. A structured event deserves a structured channel, and
    stdin cannot collide with the command's own argument parsing — so the
    event's shape is entirely the caller's vocabulary, and this module never
    grows a flag convention. The event vocabularies themselves stay with
    their owners and never merge: a watching user's turn moments and an
    unattended run's dispositions are different facts. *)

val fire :
  proc_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  argv:string list ->
  event:Jsont.json ->
  unit
(** [fire ~proc_mgr ~clock ~argv ~event] runs the hook [argv] with [event],
    encoded minified plus a newline, on its standard input. Best-effort by
    contract: output is discarded (a hook must never reach the caller's
    terminal), a hook still running after five seconds is killed, and no
    failure — spawn, write, exit status, timeout — ever raises or is
    reported; a notification is a courtesy, never an outcome. An empty
    [argv] fires nothing.

    Control characters in the event's strings — member names and values —
    are stripped before encoding (tab and newline survive), so a decoded
    value cannot smuggle a terminal escape into whatever surface the hook
    writes. *)
