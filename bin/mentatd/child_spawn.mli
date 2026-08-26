(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The brokered child materializer's spawn half: launch one detached
    [mentat serve-session] process for a recorded delegation.

    Identity only crosses the spawn — the session id and workspace root on
    argv, the instance's environment snapshot as the child environment; the
    task and role stay authoritative in the durable delegation edge the child
    re-reads. The child is detached ([setsid] under the internal [--spawned]
    flag), its stdio appended to a per-session log under the daemon home, and
    its pid returned for the broker's reaper — it is never bound to an Eio
    switch, because a child must outlive its spawner. *)

val spawn :
  User_dirs.t ->
  environment:(string * string) list ->
  session:Mentat_session.Id.t ->
  cwd:Lpath.Abs.t ->
  (int, string) result
(** [spawn dirs ~environment ~session ~cwd] launches [mentat serve-session]
    for the delegated child [session] recorded under the workspace root [cwd],
    with [environment] as its whole environment, and returns the child pid.
    [Error message] when no [mentat] binary resolves — beside this executable,
    or named by [MENTAT_BIN] — so a spawn that could never converge is refused
    before it launches anything. Spawning carries no idempotence of its own;
    the serve-session boot supplies it (a child that already ran is re-attached
    and mints nothing), so a redundant spawn converges to a clean exit. *)
