(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The engine's workspace value over [mentat.workspace_io].

    The sealed identity and [Claim_scope] attribution window bind directly to
    the resolved capability, so real edit and observation attribution flows to
    the engine.

    - {b checkpoint} takes a real boundary capture through the
      {!Mentat_store.Capture} backend: it walks the workspace beneath the opened
      roots (skipping build artifacts and the capture store's own data home),
      stores each covered file's bytes as a content-addressed write-once blob,
      and mints an [Available] capture whose opaque
      {!Mentat_mutation.Checkpoint.Snapshot.t} reference resolves through the
      same backend. A genuine capture failure — the capture store cannot be
      written — is recorded durably as a [Degraded] fact rather than faked;
      execution continues and "revert unavailable" is honest.
    - {b drain_notices} is the optional [notices] producer, or [[]] when none is
      wired — dune build-health (see {!Workspace_notices}) and the filesystem
      watch lane (see {!Workspace_watch}) are the two producers, composed by the
      executable. Each drained notice becomes a durable [Workspace_notice] fact,
      so a workspace with no producer wired records none.

    The whole claim-window yield crosses the port unchanged: the closer returned
    by [open_scope] yields {!Mentat_edit.Apply_evidence.t}, so a
    commit-phase-failed apply's attribution (its confirmed prefix and uncertain
    target) reaches the engine like a successful apply's, with no field dropped.
*)

val observe :
  Mentat_workspace_io.t -> Mentat_workspace.Path.t -> Mentat_edit.Observed.t
(** [observe capability target] observes [target] through [capability]'s
    native-write boundary, swallowing an observe error to
    {!Mentat_edit.Observed.Other}. The swallow is the revert flows' caller
    policy — an unobservable target is a non-text change, not a hard failure —
    so it is a bin-side convenience rather than a capability behaviour. *)

val observe_opt :
  Mentat_workspace_io.t ->
  Mentat_workspace.Path.t ->
  Mentat_edit.Observed.t option
(** [observe_opt capability target] is {!observe} but keeps an observe error
    ([None]) distinct from a real observation ([Some]), for the preview path
    that offers revert only when every target is observable. *)

val make :
  store:Mentat_store.Capture.Store.t ->
  ?self_prefix:Lpath.Rel.t ->
  ?notices:(unit -> Mentat_workspace.Notice.t list) ->
  ?watch:Workspace_watch.t ->
  Mentat_workspace_io.t ->
  Mentat_agent.Ports.workspace
(** [make ~store ?self_prefix ?notices ?watch capability] is the workspace
    capability over [capability], taking boundary captures into [store].
    [self_prefix], when the capture store's data home lies inside the workspace,
    is that home's workspace-relative path, pruned from every capture so the
    capture system never captures its own bytes. [notices] is the notice source
    (default: none); the engine drains it to prepare a turn, as each tool claim
    settles, and as delegated children deliver. [watch] (default: none) brackets
    every claim's attribution window with the watch lane's poll boundaries: the
    window's watched changes flow to {!Mentat_workspace_io.Claim_scope.observe}
    as observational attribution, and only changes outside every window reach
    the lane's external-change notices. *)
