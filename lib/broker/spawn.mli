(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The brokered child materializer's spawn half: launch one detached
    [mentat serve] process for a recorded delegation.

    Identity only crosses the spawn — the session id and workspace root on
    argv, the instance's environment snapshot as the child environment; the
    task and role stay authoritative in the durable delegation edge the child
    re-reads. The child is detached ([setsid] under the internal [--spawned]
    flag), its stdio appended to a per-session log under the configured log
    directory, and its pid returned for the broker's reaper — it is never
    bound to an Eio switch, because a child must outlive its spawner. *)

val spawn :
  resolve_bin:(unit -> (string, string) result) ->
  log_dir:string ->
  leaf:string ->
  environment:(string * string) list ->
  session:Mentat_session.Id.t ->
  interrupted:bool ->
  cwd:Lpath.Abs.t ->
  (int, string) result
(** [spawn ~resolve_bin ~log_dir ~leaf ~environment ~session ~interrupted
    ~cwd] launches [mentat serve] for the delegated child [session]
    recorded under the workspace root [cwd], with [environment] as its whole
    environment, and returns the child pid. [resolve_bin] is the caller's
    executable resolution, consulted here so a spawn that could never
    converge is refused — [Error message] — before it launches anything.
    [log_dir] is created [0700] if absent; the child's stdio appends to
    [child-<leaf>.log] inside it, where [leaf] is the same path-safe leaf the
    child's socket directory uses. [interrupted] carries a standing interrupt
    intent across the spawn (the internal [--interrupted] flag): the boot
    submits an interrupt right after its idempotent first-turn submit, so a
    cancelled child killed at the escalation's final rung ends in its own
    terminal interrupted fact instead of resuming the cancelled work.
    Spawning carries no idempotence of its own; the serve boot
    supplies it (a child that already ran is re-attached and mints nothing),
    so a redundant spawn converges to a clean exit. *)
