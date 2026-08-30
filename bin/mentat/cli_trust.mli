(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [trust]/[untrust] workspace-trust commands. *)

val trust_cmd : int Cmdliner.Cmd.t
val untrust_cmd : int Cmdliner.Cmd.t
