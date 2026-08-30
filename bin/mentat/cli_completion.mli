(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [completion] command: print a self-contained shell completion script for
    bash, zsh, or pwsh. The scripts drive the binary's own cmdliner completion
    protocol, so they carry no command tree and never drift. *)

val cmd : int Cmdliner.Cmd.t
