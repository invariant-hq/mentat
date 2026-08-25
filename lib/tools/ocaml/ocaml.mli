(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OCaml source and project-intelligence tools.

    Each public module constructs one immutable model-facing definition. The
    composition root selects explicit subsets for Build and read-only catalogs;
    this family deliberately has no aggregate constructor or configuration
    policy. Shared Merlin protocol plumbing is private to the executor library.
*)

module Search_expressions = Search_expressions
(** Structural expression search over workspace implementations. *)

module Ocaml_ast_edit = Ocaml_ast_edit
(** One compiler-validated structural edit in a source file. *)

module Replace_expressions = Replace_expressions
(** Multi-file structural expression replacement. *)

module Rename = Rename
(** Staged project-wide identifier rename. *)

module Type_at = Type_at
(** Merlin-backed type and documentation lookup at a source position. *)

module Eval = Eval
(** Fresh Dune-context OCaml expression evaluation. *)

module Find_definitions = Find_definitions
(** Merlin-backed definition lookup. *)

module Find_references = Find_references
(** Merlin-backed semantic reference lookup. *)

module Docs = Docs
(** Bounded OCaml API documentation lookup. *)
