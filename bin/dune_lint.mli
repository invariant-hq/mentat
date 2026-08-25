(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The lint runner.

    One value per workspace instance runs the configured lint command
    ([dune.lint_command], by default [litany check]) as a bounded confined
    one-shot each time the build lane settles Clean on a fresh build
    witness — the principled trigger, since a linter reading build
    artifacts has nothing to read until the build is green, and
    lint-after-green self-debounces to one run per settle. Dune is not in
    the lint path at all: no alias, no lock, no forwarding — the linter
    reads what the green build just wrote. Its output is parsed with
    {!Mentat_ocaml_dune_rpc.Lint_output} and published into the shared
    observer's settled reading as the lint lane
    ({!Mentat_ocaml_dune_rpc.Instance.set_lint}) — one source of truth for
    the row's count and the drain's notices.

    The lane's availability gate mirrors the watch's ladder, in both
    worlds a project keeps its linter in: the dune lane must be live (the
    trigger is its readings), the command non-empty, and the command
    reachable — directly when its program resolves on the sealed child
    PATH (the opam world), through a [dune exec] prefix otherwise (the
    dune-pkg world, where the binary lives in the lock universe and may
    need building). Whether the reached command exists is the first run's
    answer: a structurally absent direct program, or dune's own
    Program-not-found answer, takes the lane off for the session — off
    means lint-absent, never lint-clean, and never a fossil of the last
    word. A linter installed mid-session takes effect next session.
    Construction is pure; {!engage} forks the polling fiber. *)

type t
(** The type for lint runners. *)

val make :
  rpc:Mentat_ocaml_dune_rpc.Instance.t ->
  capability:Mentat_workspace_io.t ->
  mono:_ Eio.Time.Mono.t ->
  sw:Eio.Switch.t ->
  workspace:Mentat_workspace.t ->
  command:string list ->
  t
(** [make ~rpc ~capability ~mono ~sw ~workspace ~command] is a lint runner
    executing [command] from the workspace root through the sealed
    [capability], watching [rpc]'s settled readings for its trigger and
    publishing its findings back into [rpc]. [workspace] resolves reported
    paths workspace-relative. Construction performs no IO and spawns
    nothing. A run that exits — cleanly, or non-zero with findings parsed —
    publishes its word ([Some []] is lint-clean); any other termination
    keeps the lane's last one: a non-zero exit without findings, a timeout,
    an output overrun, and a signal death alike are incomplete reports, and
    an incomplete report never speaks — a signal-killed linter's partial
    output would fabricate resolutions. Hostile or unparseable output is
    the same incomplete case, never the fiber's death.

    Raises [Invalid_argument] if [command] is empty — an empty command means
    no runner is constructed at all. *)

val engage : t -> unit
(** [engage t] forks the runner's fiber under the engagement switch.
    Idempotent: later calls do nothing. The fiber polls the observer's
    snapshot; each Clean settle whose build witness advanced past the last
    run starts one bounded run, one at a time — a settle during a run
    re-arms it. *)
