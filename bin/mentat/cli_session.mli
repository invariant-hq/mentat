(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [session] command group: create, list, search, show, rename, archive,
    restore, delete, purge, fork, rewind, diff, revert, export, and compact. *)

val cmd : int Cmdliner.Cmd.t
