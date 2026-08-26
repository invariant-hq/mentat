(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The shared binary entry guard.

    Every mentat executable starts the same way: output channels
    initialized, backtraces recorded, [-v]/[-vv]/[--verbose] taken from argv
    before the diagnostics reporter installs (so startup records have a
    sink), the command evaluated with cmdliner's own exception handler
    disabled, and any escaping exception routed through the exit-status
    ladder — an internal invariant failure writing its backtrace to a crash
    report under the state home, never to the screen. One guard, one crash
    shape, for every binary that links it. *)

val run :
  version:string ->
  ?rewrite_argv:(string array -> string array) ->
  int Cmdliner.Cmd.t ->
  'a
(** [run ~version ?rewrite_argv cmd] evaluates [cmd] on [Sys.argv] and
    exits the process with the resulting code; it never returns. [version]
    stamps the startup log record and any crash report. [rewrite_argv]
    (default the identity) is applied to argv {e after} verbosity flags are
    taken and before cmdliner sees it — the seam for argv ergonomics like
    the [run PROMPT] splice. *)
