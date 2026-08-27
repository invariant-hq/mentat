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

    The lane's gate is the watch's ladder plus a non-empty command;
    reachability is re-resolved at {e every} due settle, never once for
    the session: the composition's resolver answers the sealed child PATH
    (the opam world) or the built binary in the project's lock universe
    (the dune-pkg world), and a settle it cannot answer is skipped —
    lint-absent, never lint-clean, never a fossil. A linter that appears
    mid-session (a lock universe freshly built, a PATH install) runs at
    the next settle; one that vanishes skips until it returns. The lane
    has no death: only [dune.lint_command = []] means no runner.
    Construction is pure; {!engage} forks the polling fiber. *)

type t
(** The type for lint runners. *)

val make :
  rpc:Mentat_ocaml_dune_rpc.Instance.t ->
  capability:Mentat_workspace_io.t ->
  mono:_ Eio.Time.Mono.t ->
  sw:Eio.Switch.t ->
  workspace:Mentat_workspace.t ->
  resolve:(unit -> string list option) ->
  t
(** [make ~rpc ~capability ~mono ~sw ~workspace ~resolve] is a lint runner
    executing the command [resolve] answers, from the workspace root
    through the sealed [capability], watching [rpc]'s settled readings for
    its trigger and publishing its findings back into [rpc]. [resolve] is
    consulted at every due settle; [None] skips that settle. [workspace]
    resolves reported paths workspace-relative. Construction performs no
    IO and spawns nothing. A run that exits — cleanly, or non-zero with
    findings parsed — publishes its word ([Some []] is lint-clean); any
    other termination keeps the lane's last one: a non-zero exit without
    findings, a timeout, an output overrun, a launch failure, and a signal
    death alike are incomplete reports, and an incomplete report never
    speaks — a signal-killed linter's partial output would fabricate
    resolutions. Hostile or unparseable output is the same incomplete
    case, never the fiber's death. *)

val engage : t -> unit
(** [engage t] forks the runner's fiber under the engagement switch.
    Idempotent: later calls do nothing. The fiber polls the observer's
    snapshot; each Clean settle whose build witness advanced past the last
    run starts one bounded run, one at a time — a settle during a run
    re-arms it. *)
