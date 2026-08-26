(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [serve-session] child server: one process serving exactly one delegated
    session — its own — over the daemon's wire, on a per-session unix socket
    derived from the session id. Internal: launched by the broker; not for
    direct use. The boot re-reads the task from the durable delegation edge,
    submits the child's deterministic first turn idempotently, serves feed and
    commands while the work runs, and exits cleanly once the session settles
    idle with an empty queue and no unsettled delegations of its own. *)

val cmd : int Cmdliner.Cmd.t
