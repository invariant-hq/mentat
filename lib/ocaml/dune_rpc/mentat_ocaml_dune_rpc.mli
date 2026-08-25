(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Dune RPC observation for OCaml project tooling.

    This library observes a running Dune RPC server: it discovers the
    endpoint matching a workspace — a supervisor's pinned socket, or the
    registry for a foreign watch — attaches, and folds the watch's own
    diagnostic events into settled readings. Its one write is {!Mirror}: the
    host-side registry entry a supervised watch cannot write for itself. It
    never starts Dune — starting and supervising are the caller's, through
    the sealed spawn route.

    It is a separate library from {!Mentat_ocaml} for one reason: it contains
    the Dune RPC protocol stack ([dune-rpc], [csexp], [xdg]) and the [eio]
    effects that drive it — and {!Lint_output}'s [ocamlc-loc], which rides
    the same lock entry as [dune-rpc], is kept here so that undeclared
    dependency has exactly one home. *)

module Store = Store
(** The pure fold of a watch's diagnostic and progress streams — exposed so
    its timing rules are table-testable without a connection. *)

module Watch = Watch
(** The build-watch supervisor's pure law — exposed so its composition and
    give-up rules are table-testable without a process. *)

module Instance = Rpc.Instance
(** Workspace-level Dune RPC state shared by every observer. *)

module Mirror = Mirror
(** The host-side registry mirror for a supervised build watch. *)

module Lint_output = Lint_output
(** The lint runner's output, parsed into lint-lane findings. *)
