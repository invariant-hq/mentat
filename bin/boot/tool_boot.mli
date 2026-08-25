(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Private boot-time resolution for executable tool prefixes.

    [Tool_boot] resolves configured Merlin prefixes before the engine catalog is
    constructed, using the sealed workspace capability only for project
    observation and a caller-supplied immutable toolchain search space for
    executable lookup. It never starts a process or changes the workspace.

    This module is executable-private. Tool libraries receive only the resolved
    argv and remain unable to inspect the environment or discover executables.
*)

type t
(** A lookup resolver over one workspace capability and captured toolchain
    search space. *)

(** Structured failures from resolving an explicit Dune dev-tool prefix. *)
type error =
  | Invalid_tool of string
      (** A [dune tools exec] tool is not a single workspace path component. *)
  | Workspace_path of Mentat_workspace.Resolve_error.t
      (** A project-relative dev-tool path could not be represented in the
          resolved workspace. *)
  | File_observation of Mentat_workspace_io.File_error.t
      (** The sealed capability refused or failed a dev-tool observation. *)
  | Address of Mentat_workspace.Resolve_error.t
      (** A discovered workspace path could not be projected to its immutable
          absolute executable address. *)
  | Binary_not_found of string
      (** The named binary was not present in Dune's existing dev-tool layout.
      *)

val make : Mentat_workspace_io.t -> toolchain:Mentat_ocaml_toolchain.t -> t
(** [make workspace_io ~toolchain] is the lookup resolver over exactly those
    captured values. It performs no observation; {!resolve_merlin} does. *)

val resolve_program : t -> string -> string list
(** [resolve_program t program] is [[absolute]] when [program] resolves through
    [t]'s captured toolchain and [[program]] otherwise. The unresolved spelling
    is intentional: the consuming tool then reports its normal structured
    unavailable result without disabling unrelated catalog entries. *)

val resolve_merlin : t -> configured:string list -> (string list, error) result
(** [resolve_merlin t ~configured] is a lookup-only Merlin argv prefix.

    Resolution preserves the configured prefix except in these exact cases:

    - a bare single token is pinned when the toolchain resolves it; when it does
      not, an already-built same-named Dune dev tool is preferred, otherwise the
      token remains unchanged;
    - exactly [dune tools exec TOOL --], where [dune]'s basename is ["dune"],
      resolves to an already-built regular file named [TOOL] or returns
      {!Binary_not_found}. Directories and other non-regular entries are not
      executable candidates.

    Absolute or relative executables, multi-token wrappers, and near-matching
    Dune command lines remain unchanged. [Error] means no observation-only
    replacement was found; callers must not pass the original Dune prefix to
    per-call tools because doing so could build outside a claimed turn.

    Raises [Invalid_argument] if [configured] is empty. *)

val error_message : error -> string
(** [error_message error] is a human-readable lookup diagnostic. It is not a
    matching surface; branch on [error]. *)
