(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The build-watch supervisor.

    One value per workspace instance owns the lifecycle of the workspace's
    [dune build --watch]: probe before spawning (an already-answering server
    means a foreign watch to observe, never to fight for the lock), spawn the
    watch as a confined supervised session with a private runtime directory,
    mirror its registry entry into the user's real registry so editor tooling
    discovers it, restart it when it exits, and give up when successive
    spawns die before coming up. The settled readings themselves are the
    shared attach observer's business — the supervisor only makes sure there
    is a watch for it to observe, and says honestly which state that effort
    is in.

    Construction is pure. {!engage} forks the supervising fiber; it is called
    at the first turn's preparation, never at boot, so opening a frontend on
    a cold workspace starts no build. Stopping is the engagement switch's
    release: the session is signalled (SIGTERM to its group, grace, SIGKILL)
    so dune's own exit handlers unlink its socket and private registry entry,
    and the mirror is removed host-side either way. *)

type t
(** The type for build-watch supervisors. *)

(** Supervisor modes, the operative half of the [dune.watch] knob ([off]
    constructs no supervisor at all). *)
module Mode : sig
  type t =
    | Auto  (** Probe, attach to a foreign watch, or spawn and supervise. *)
    | Observe  (** Attach to a foreign watch only; never spawn. *)
end

val make :
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  mono:_ Eio.Time.Mono.t ->
  capability:Mentat_workspace_io.t ->
  root:Lpath.Abs.t ->
  run_id:string ->
  mode:Mode.t ->
  program:string list option ->
  targets:string list ->
  env:(string -> string option) ->
  observed:(unit -> Mentat_workspace.Health.t) ->
  unit ->
  t
(** [make ~net ~clock ~mono ~capability ~root ~run_id ~mode ~program ~targets
     ~env ~observed ()] is a supervisor for the workspace rooted at [root].

    [capability] is the sealed workspace the watch is spawned through — the
    watch runs confined under the same policy as every other command.
    [program] is the resolved dune argv prefix, or [None] when no dune
    resolves on the command PATH (the supervisor then never spawns and
    reports it). [targets] are the watch's build targets, each passed
    verbatim after [build --root . --watch]. [run_id] names the private
    runtime directory [<root>/.mentat/run/<run_id>] the watch's registry
    entry is confined to. [env] is the ambient environment the host-side
    registry mirror derives the user's real registry directory from.
    [observed] projects the shared attach observer's current status; the
    supervisor composes it with its own machine — an attached watch whose
    advertised pid is the supervised child is reported as ours.

    Construction performs no IO and spawns nothing. *)

val engage : t -> sw:Eio.Switch.t -> unit
(** [engage t ~sw] forks the supervising fiber under [sw] and registers the
    teardown that signals a live session and removes the registry mirror when
    [sw] releases. Idempotent: later calls do nothing. In {!Mode.Observe} the
    fiber only records that nothing is spawned; attaching remains the
    observer's continuous work. *)

val health : t -> Mentat_workspace.Health.t
(** [health t] is the watch status a frontend renders, without IO: the
    supervisor's machine composed with the observer's view. An attached watch
    always wins — reported as ours exactly when the supervisor's own child is
    the one attached — and otherwise the machine speaks: probing, starting, a
    restart with its cause, no dune on the PATH, nothing to observe, or given
    up. Before {!engage} it is the observer's view alone. *)

val owns_lock : t -> bool
(** [owns_lock t] is [true] while a supervised session holds dune's build
    lock — from spawn until the child's exit is observed. Lock-taking
    one-shot tools consult it to refuse honestly instead of failing with
    dune's own lock advice. *)
