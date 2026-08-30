(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [auth] command group: status, login, save, logout, and remove.

    Login progress stays typed until this presentation edge. [logout --revoke]
    reports the canonical remote/local settlement; refresh is runtime policy and
    is not a command. *)

val cmd : int Cmdliner.Cmd.t
(** [cmd] is the [auth] command group. *)
