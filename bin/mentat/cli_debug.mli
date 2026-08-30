(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [debug] diagnostic group: [context], [prompt], [session], and [model] —
    pure offline views of what a run assembles, none linking the engine. *)

val cmd : int Cmdliner.Cmd.t

val session_bundle :
  Mentat_boot.Composition.t ->
  Mentat_store.Session.Document.t ->
  Jsont.json * string list * string list
(** [session_bundle t document] is what [debug session --json] prints for
    [document], paired with the paths of the log files and crash reports whose
    records name that session. {!Cli_report} bundles the projection and copies
    those files; the two commands must agree on what correlates, so the
    projection has one implementation. *)
