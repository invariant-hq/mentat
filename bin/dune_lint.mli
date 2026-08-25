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

    The lane's availability gate mirrors the watch's: the dune lane must be
    live (the trigger is its readings), the command non-empty, and the
    command's program resolvable on the sealed child PATH — probed at
    construction like the watch's dune, so the linter found is the
    project's own, version-matched to the compiler that wrote the
    artifacts. Absent means no runner and a lane that reads lint-absent,
    never lint-clean; a linter installed mid-session takes effect next
    session. Construction is pure; {!engage} forks the polling fiber. *)

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
    nothing. A run that exits zero or carries findings publishes them
    ([Some []] is lint-clean); a run that fails without findings is a
    crashed linter and the lane keeps its last word.

    Raises [Invalid_argument] if [command] is empty — an empty command means
    no runner is constructed at all. *)

val engage : t -> unit
(** [engage t] forks the runner's fiber under the engagement switch.
    Idempotent: later calls do nothing. The fiber polls the observer's
    snapshot; each Clean settle whose build witness advanced past the last
    run starts one bounded run, one at a time — a settle during a run
    re-arms it. *)
