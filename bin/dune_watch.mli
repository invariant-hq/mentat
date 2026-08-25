(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The build-watch supervisor.

    One value per workspace instance owns the lifecycle of the workspace's
    [dune build --watch]: probe before spawning (an already-answering server
    means a foreign watch to observe, never to fight for the lock), spawn the
    watch as a confined supervised session with a private runtime directory,
    pin the watch's endpoint into the shared attach observer so its readings
    never depend on the user's global registry, mirror its registry entry
    into that registry so editor tooling discovers it, restart it when it
    exits, and give up when successive spawns die before coming up. The
    settled readings themselves are the observer's business — the supervisor
    only makes sure there is a watch for it to observe, and says honestly
    which state that effort is in. The rules it says them with are the pure
    {!Mentat_ocaml_dune_rpc.Watch}; this module is their effectful shell.

    Construction is pure. {!engage} forks the supervising fiber; it is called
    at the first turn's preparation, never at boot, so opening a frontend on
    a cold workspace starts no build. Stopping is {!stop} — explicit during
    instance shutdown, and registered on the engagement switch as the
    backstop: the session is signalled (SIGTERM to its group, a daemon-scale
    grace, SIGKILL) so dune's own exit handlers unlink its socket and private
    registry entry where the signal reaches them, and the supervisor unlinks
    both host-side where it does not — the sealed route's Linux backend
    detaches the child from the signalled group. *)

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
  rpc:Mentat_ocaml_dune_rpc.Instance.t ->
  capability:Mentat_workspace_io.t ->
  mono:_ Eio.Time.Mono.t ->
  sw:Eio.Switch.t ->
  root:Lpath.Abs.t ->
  run_id:string ->
  mode:Mode.t ->
  program:string list option ->
  targets:string list ->
  t
(** [make ~rpc ~capability ~mono ~sw ~root ~run_id ~mode ~program ~targets]
    is a supervisor for the workspace rooted at [root].

    [rpc] is the workspace's shared attach observer: the supervisor pins a
    spawned watch's endpoint into it, probes through it, and writes the
    registry mirror through it. [capability] is the sealed workspace the
    watch is spawned through — the watch runs confined under the same policy
    as every other command. [sw] is the engagement switch: {!engage} forks
    under it, and its release is the teardown backstop. [program] is the
    watch's argv prefix, or [None] when no dune resolves on the command PATH
    (the supervisor then never spawns and reports it); the launch itself
    resolves the program on the sealed route, as every launch does. [targets]
    are the watch's build targets, each passed verbatim after
    [build --root . --watch]. [run_id] names the private runtime directory
    [<root>/.mentat/run/<run_id>] the watch's registry entry is confined to.

    Construction performs no IO and spawns nothing. *)

val engage : t -> unit
(** [engage t] forks the supervising fiber under the engagement switch and
    registers {!stop} as the switch's teardown backstop. Idempotent: later
    calls do nothing. In {!Mode.Observe} nothing is forked and nothing is
    claimed; attaching remains the observer's continuous work and the
    observer's view is what {!health} reports. *)

val report_stall : t -> unit
(** [report_stall t] tells the supervisor a forwarded build stalled: a dune
    command's tool call timed out while the watch held the lock. The live
    loop answers with one bounded verification — dune's [flush_file_watcher],
    which a slow build completes and a wedged event loop cannot — and only a
    failed verification restarts the watch, as [Restarting Hung]. Reports
    between lives, before the watch is up, or without a supervised watch at
    all are dropped; the call never blocks and is safe from any fiber. *)

val drain_notices : t -> Mentat_workspace.Notice.t list
(** [drain_notices t] returns and clears the supervisor's pending notices —
    a hang restart, a blocked file watcher — in the order they arose. The
    drain-time notice producer appends them ahead of the build-change
    notices it derives. *)

val health : t -> Mentat_workspace.Health.t
(** [health t] is the watch status a frontend renders, without IO:
    {!Mentat_ocaml_dune_rpc.Watch.compose} of the machine's word with the
    observer's view. An attached watch always wins and carries its own
    owner — ours exactly when the connection opened through the supervisor's
    pin — and otherwise the machine speaks: probing, starting, a restart with
    its cause, no dune on the PATH, or given up. Before {!engage}, and in
    {!Mode.Observe}, it is the observer's view alone. *)

val stop : t -> unit
(** [stop t] ends supervision: the machine stops (a pending restart never
    respawns), a live session is signalled (SIGTERM to its group, a
    daemon-scale grace, SIGKILL), the observer is unpinned, and the registry
    mirror, the private runtime directory, and — when nothing answers the
    socket — the endpoint debris a signal-starved child left behind are all
    removed host-side. Idempotent, and safe before {!engage}. Call it during
    instance shutdown, before the engagement switch releases, so the watch
    dies on SIGTERM rather than on the switch's kill of still-running
    children. *)
