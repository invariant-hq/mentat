(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OCaml language facts shared by OCaml-specific tools.

    This library is the small, backend-neutral vocabulary that Dune, Merlin,
    odoc, and tool-facing adapters convert into. It is pure and owns no compiler
    service, RPC connection, filesystem authority, cache, or host lifecycle; it
    links no effect library.

    The Dune-specific surfaces are separate libraries above it:
    [Mentat_ocaml_dune_describe] normalises [dune describe] output into
    {!Project.t}, and [Mentat_ocaml_dune_rpc] observes a running Dune RPC
    server. Neither is needed to name a value from this vocabulary. *)

(** {1 Source coordinates} *)

module Position = Position
(** Source positions. *)

module Range = Range
(** Source ranges over {!Position.t} endpoints. *)

module Location = Location
(** Workspace-anchored source ranges. *)

module Module_name = Module_name
(** OCaml module names. *)

module Finding = Finding
(** Build and lint diagnostic identities — the content keys the build-change
    law compares. *)

module Build_change = Build_change
(** The build-change law: the pure diff between consecutive settled diagnostic
    readings, per lane, rendered as {!Mentat_workspace.Notice.t}. *)

(** {1 Diagnostics} *)

module Diagnostic = Diagnostic
(** Diagnostics reported by OCaml tools and the build system. *)

(** {1 Project descriptions} *)

module Project = Project
(** Normalized project descriptions for agent-facing tools. *)
