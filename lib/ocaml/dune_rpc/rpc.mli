(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Dune RPC workspace observation.

    {!Instance} is the shareable workspace object that polls the Dune
    registry, attaches to the matching endpoint, and folds the watch's own
    diagnostic events into the settled readings every consumer snapshots. The
    fold itself is the pure {!Store}. *)

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
    mono:_ Eio.Time.Mono.t ->
    workspace:Mentat_workspace.t ->
    ?env:(string -> string option) ->
    unit ->
    t
  (** [create ~fs ~net ~mono ~workspace ()] is a workspace-level Dune RPC
      instance.

      [fs] is used to poll Dune's registry, [net] to connect to the selected
      endpoint, and [mono] to stamp stream events — the clock is part of the
      instance's identity, since a snapshot cannot answer the quiet rule
      without it. [env] defaults to {!Sys.getenv_opt} and is used for XDG
      registry discovery. Construction performs no IO and never suspends: a
      first caller's lazy initialisation stays race-free by construction.

      The value owns registry polling and the latest diagnostic state for
      [workspace]. It never starts Dune; it only observes an already-running
      RPC instance. *)

  (** The attach-side view of the observed watch. *)
  module Status : sig
    type t =
      | Absent
          (** No matching endpoint is registered for the workspace, or nothing
              answered. Build diagnostics are unavailable, which is not an
              error. *)
      | Connecting
          (** An endpoint is registered and a connection is being established.
          *)
      | Attached of { pid : int; ours : bool }
          (** A live connection holds the watch's diagnostic and progress
              subscriptions; [pid] is the watch's advertised process id, and
              [ours] whether the connection opened through a supervisor's
              {!pin} — the supervised watch — rather than through registry
              discovery. *)
    (** The type for attach statuses. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same status with the
        same pid. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics. *)
  end

  (** What the attach loop knows right now, taken without IO. *)
  module Snapshot : sig
    type t = {
      status : Status.t;
      building : bool;
          (** A build is in progress, or no build has settled since the
              connection opened. Meaningful only when attached. *)
      reading : Mentat_ocaml.Build_change.Reading.t option;
          (** The settled reading, when one exists: the connection is attached,
              the last progress sample is a settle, and the diagnostic stream
              has been quiet long enough to be at rest. [None] otherwise —
              mid-build, mid-churn, or detached — and lost visibility is the
              change law's business, never invented here. *)
    }
    (** The type for snapshots. *)

    val health : t -> Mentat_workspace.Health.t
    (** [health t] is the wire status a frontend glances at: nothing attached
        is {!Mentat_workspace.Health.Off} [No_server], a connection in flight
        is {!Mentat_workspace.Health.Probing}, and an attached watch is
        {!Mentat_workspace.Health.Live} — owned by us when the connection
        opened through a supervisor's {!pin} and foreign otherwise; mid-build
        or unsettled as [Building], at rest as [Settled] with the reading's
        verdict and lint count. The caller owes the tooling gate: a disabled
        or untrusted workspace never reaches this projection. *)
  end

  val attach : t -> unit
  (** [attach t] runs the attach loop and never returns: poll the
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

  (** {1:supervision The supervisor's seams}

      A build-watch supervisor knows its own watch's socket and host pid, so
      the observer must never rediscover that watch through the user's global
      registry — a broken or unwritable registry would silently cost the
      agent its own build visibility. These seams let the supervisor state
      what it knows; everything below stays observation. *)

  val socket_path : t -> string
  (** [socket_path t] is where dune's RPC server binds for the workspace, by
      dune's own convention: [_build/.rpc/dune] under the primary root. *)

  val pin : t -> pid:int -> lint:bool -> unit
  (** [pin t ~pid ~lint] directs the attach loop at the workspace's own
      socket ({!socket_path}) instead of the registry: the supervisor spawned
      a watch with host process id [pid] there. [lint] states whether the
      requested targets make the lint lane live — a pinned watch's targets
      are known, so the lint marker alone no longer decides a finding's lane.
      An attachment that opens through the pin reports the watch as ours. The
      pin holds until {!unpin}; while the socket does not answer yet the loop
      keeps reconnecting to it, which is a spawned watch starting up. *)

  val unpin : t -> unit
  (** [unpin t] returns the attach loop to registry discovery — the
      supervised watch is gone. An attachment already open keeps the identity
      it was opened with until it disconnects. *)

  val probe : t -> bool
  (** [probe t] is [true] iff a Dune RPC server accepted a connection at
      {!socket_path} and completed the initialize handshake, bounded to one
      second. A missing socket, a refused connection, a failed handshake, and
      a timeout are all [false]: the caller treats an unanswering socket as
      no server. The probe holds no subscription and closes its connection
      before returning. *)

  val mirror : t -> pid:int -> (Mirror.t, string) result
  (** [mirror t ~pid] writes the user-registry mirror entry for the
      supervised watch with host process id [pid] serving {!socket_path} —
      see {!Mirror.write}. The instance contributes only the ambient
      environment the registry directory derives from; the caller owns the
      entry and its removal. *)

  val flush : t -> [ `Answered | `Timed_out | `No_server ]
  (** [flush t] verifies the watch's event loop: a fresh connection to
      {!socket_path} sends dune's [flush_file_watcher] — the public request
      that waits for the file watcher's sync round-trip and the debounce
      quiet period, exercising the event loop without waiting on the build —
      bounded to ten seconds ([MENTAT_DUNE_WATCH_FLUSH_S] scales it for
      hermetic tests). Any answer is [`Answered]: a slow build still
      answers, an error response is a response, and a server without the
      method answered the version negotiation — the answer, not its content,
      is the evidence, so only a wedged loop cannot produce one.
      [`No_server] is a connection that never opened (nothing to verify; the
      exit paths own a dead child). [`Timed_out] is the hang verdict. *)

  val activity : t -> int
  (** [activity t] is a monotone count of stream events folded so far, for
      liveness comparison around a {!flush}: a count that moved during the
      verification window means the loop delivered events — alive — whatever
      the flush itself did. *)
end
