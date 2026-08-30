(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [sandbox] command group.

    Pure render over the sealed workspace capability: [status] reports the
    effective posture (mode, read scope, network, enforcement evidence, readable
    roots) and [explain] the concrete sealed identity and confinement policy.
    Both resolve the workspace through
    {!Mentat_boot.Composition.resolve_workspace} — no engine, no credentials,
    no session, no mutation — so they run on any
    platform: an unsealable posture is a clean runtime error (exit 1), never a
    crash. *)

open! Cmdliner

val cmd : int Cmd.t
(** The [sandbox] group: [status] and [explain]. *)

val print_run_posture : Mentat_boot.Composition.t -> unit
(** [print_run_posture t] writes the run-start sandbox posture block to stderr
    (F7): the configured mode, read scope, and network, mirroring the mode
    default that the client passes to
    {!Mentat_boot.Composition.resolve_workspace}.
    Human-path only; the executable owns this render and [cli_run] calls it
    before a headless turn. *)
