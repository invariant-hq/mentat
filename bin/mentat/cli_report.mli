(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [report] command: one NDJSON bundle carrying what a maintainer needs to
    diagnose a problem.

    It composes projections the diagnostic commands already own rather than
    re-deriving them, so a report and the command a user could have run by hand
    cannot disagree. Records are accumulated whole and written atomically under
    [0600]; a terminal manifest carries a count and a digest over the exact
    bytes of every preceding line, so a truncated bundle is detectable.

    By default the bundle carries the session's {e state}, not its conversation.
    [--with-session-export] adds the conversation as one nested export bundle,
    base64 so the export's own manifest still covers its own bytes and a reader
    can verify it independently. Either way the bundle is written only after a
    confirmation that enumerates what it will contain — a prompt that overstates
    teaches users to stop reading it. It never reads the credential store or the
    composer's cross-project prompt history, and it uploads nothing. *)

val cmd : version:string -> int Cmdliner.Cmd.t
