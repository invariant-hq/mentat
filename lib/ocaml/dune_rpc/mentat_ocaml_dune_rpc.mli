(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Dune RPC observation for OCaml project tooling.

    This library observes an already-running Dune RPC server: it polls the
    registry, attaches to the endpoint matching a workspace, and folds the
    watch's own diagnostic events into settled readings. It never starts
    Dune.

    It is a separate library from {!Mentat_ocaml} for one reason: it contains
    the Dune RPC protocol stack ([dune-rpc], [csexp], [xdg]) and the [eio]
    effects that drive it. Normalising [dune describe] output into a project
    description needs none of that and lives in {!Mentat_ocaml.Describe}. *)

module Store = Store
(** The pure fold of a watch's diagnostic and progress streams — exposed so
    its timing rules are table-testable without a connection. *)

module Instance = Rpc.Instance
(** Workspace-level Dune RPC state shared by every observer. *)

module Probe = Rpc.Probe
(** One-shot liveness probe against a watch's known socket. *)

module Mirror = Mirror
(** The host-side registry mirror for a supervised build watch. *)
