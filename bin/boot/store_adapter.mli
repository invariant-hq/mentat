(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The engine's STORE port over [mentat.store].

    The engine links no store backend; this adapter is the executable's binding
    of {!Mentat_agent.Ports.STORE} to an opened {!Mentat_store.t} root. Session
    and mutation ops are near 1:1; {!Mentat_agent.Ports.STORE.commit} is the one
    composition the port assigns the adapter — fold the engine's event suffix
    through the session's checked append ({!Mentat_session.append_all}), stamp
    [updated_at] from the injected clock, then CAS. Every lower error maps
    losslessly onto {!Mentat_agent.Ports.Store_error.t}. *)

val make :
  sw:Eio.Switch.t ->
  root:Mentat_store.t ->
  owner:Mentat_store.Run_lock.Owner.t ->
  now:(unit -> Mentat_session.Time.t) ->
  merge:bool ->
  capability:Mentat_workspace_io.t ->
  checkpoint:
    (boundary:Mentat_mutation.Checkpoint.boundary ->
    Mentat_mutation.Checkpoint.t) ->
  new_id:(unit -> Mentat_mutation.Revert.Id.t) ->
  (module Mentat_agent.Ports.STORE)
(** [make ~sw ~root ~owner ~now ~merge ~capability ~checkpoint ~new_id] is the
    STORE port bound to [root]. [merge] is the [revert.merge] config value the
    online revert cone threads to the lifecycle. Fences acquired through
    {!Mentat_agent.Ports.STORE.try_acquire} register on [sw] and carry [owner];
    [now] stamps [updated_at] at each commit. [capability] is the
    workspace-write capability the online revert cone applies and observes
    through, [checkpoint] its [Before_revert] boundary capture, and [new_id] the
    revert-id minter — the three effects {!Mentat_agent.Ports.STORE.revert}
    composes that the store itself does not own. *)
