(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Dune RPC workspace observation.

    {!Instance} is the shareable workspace object that polls the Dune
    registry, attaches to the matching endpoint, and folds the watch's own
    diagnostic events into the settled readings every consumer snapshots. *)

module Diagnostic : sig
  (** Dune diagnostic identifiers. *)

  module Id : sig
    (** Stable identifier for a Dune diagnostic event. *)

    type t
    (** The type for non-empty diagnostic identifiers. Diagnostics are keyed
        by this id inside the attach loop's store; consumers read findings and
        never the id, so it stays opaque. *)
  end

  type id = Id.t
  (** The type for diagnostic identifiers. *)
end

module Instance : sig
  (** Workspace-level Dune RPC state shared by every observer.

      One instance should be created per Mentat workspace: its {!attach} loop
      holds the watch's diagnostic and progress subscriptions, and every
      consumer — the drain-time notice producer, a status glance — reads the
      same {!snapshot}. The instance discovers already-running Dune RPC
      servers through the registry; it never starts Dune. *)

  type t
  (** The type for a workspace-level Dune RPC instance. *)

  val create :
    fs:_ Eio.Path.t ->
    net:_ Eio.Net.t ->
    workspace:Mentat_workspace.t ->
    ?env:(string -> string option) ->
    unit ->
    t
  (** [create ~fs ~net ~workspace ()] is a workspace-level Dune RPC instance.

      [fs] is used to poll Dune's registry. [net] is used to connect to the
      selected endpoint. [env] defaults to {!Sys.getenv_opt} and is used for XDG
      registry discovery.

      The value owns registry polling and the latest diagnostic state for
      [workspace]. It never starts Dune; it only observes an already-running RPC
      instance. *)

  (** The attach-side view of the observed watch. *)
  module Watch : sig
    type status =
      | Absent
          (** No matching endpoint is registered for the workspace, or nothing
              answered. Build diagnostics are unavailable, which is not an
              error. *)
      | Connecting of { pid : int }
          (** An endpoint is registered and a connection is being established.
          *)
      | Attached of { pid : int }
          (** A live connection holds the watch's diagnostic and progress
              subscriptions. *)
    (** The type for attach statuses. [pid] is the watch's advertised process
        id. *)

    val equal : status -> status -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same status with the
        same pid. *)

    val pp : Format.formatter -> status -> unit
    (** [pp ppf status] formats [status] for diagnostics. *)
  end

  (** What the attach loop knows right now, taken without IO. *)
  module Snapshot : sig
    type t = {
      status : Watch.status;
      building : bool;
          (** A build is in progress, or no build has settled since the
              connection opened. Meaningful only when attached. *)
      reading : Mentat_workspace.Build_change.Reading.t option;
          (** The settled reading, when one exists: the connection is attached,
              the last progress sample is a settle, and the diagnostic stream
              has been quiet long enough to be at rest. [None] otherwise —
              mid-build, mid-churn, or detached — and lost visibility is the
              change law's business, never invented here. *)
    }
    (** The type for snapshots. *)
  end

  val attach : t -> mono:_ Eio.Time.Mono.t -> unit
  (** [attach t ~mono] runs the attach loop and never returns: poll the
      registry for a matching endpoint, connect, hold the watch's [diagnostic]
      and [progress] subscriptions — folding dune's own add/remove events into
      the finding store — and on any disconnect fall back to polling. Run it
      in its own fiber; cancelling that fiber (its switch releasing) detaches
      and ends the loop.

      The [diagnostic] stream doubles as a build witness: dune mints fresh
      diagnostic ids per build, so any build that touches an error produces
      events even when its content is identical. A reading's emptiness is
      confirmed — and a recovery therefore statable — only when a settle was
      witnessed after the last removal, or after two seconds of total quiet,
      because dune's progress source is sampled and a sub-sample rebuild can
      settle without an event.

      This loop never spawns dune and never writes; it only observes an
      already-running RPC instance. *)

  val snapshot : t -> Snapshot.t
  (** [snapshot t] is the attach loop's current knowledge, without IO: safe on
      any fiber, in particular the engine's drain path. Before {!attach} runs
      it is [{ status = Absent; building = false; reading = None }]. *)
end
