(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared cmdliner vocabulary for every command: help sections, leaf argument
    converters, the exit-code declaration, and the temporary manual-compaction
    deferral. *)

open Cmdliner

val s_run : string
val s_session : string
val s_config : string
val s_diagnostic : string

val exits : Cmd.Exit.info list
(** The exit-code documentation, declared on every command. *)

val cwd : string option Term.t
(** [--cwd]/[-C DIR]: run as if in [DIR]. *)

val json : bool Term.t
(** [--json]: emit machine-readable JSON. *)

val session_arg : string option Term.t
(** The optional positional [SESSION] id or unique prefix. *)

val last : bool Term.t
(** [--last]: target the newest resumable session in the workspace. *)
