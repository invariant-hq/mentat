(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure workspace root admission and path binding.

    A workspace has one primary writable root, zero or more read-only auxiliary
    roots, and a construction-fixed {!cwd} used to resolve relative input.
    {!Path.t} is the durable root-key-relative identity shared by every layer;
    the workspace is the only owner of the mapping from that identity to a
    current logical absolute directory.

    The usual flow is to construct location-bound roots with {!Root.of_dir} or
    bind host-owned identities with {!Root.make}, admit them with {!make} or
    {!single}, resolve external input with {!resolve_string}, and pass the
    resulting {!Path.t} together with the workspace to a host layer. At a
    filesystem boundary, use {!to_abs}; never treat decoding a path as proof
    that its root is currently admitted.

    This module performs no I/O. The host owns root discovery, filesystem
    canonicalization, stable root-key selection, physical containment checks,
    and enforcement of writable versus read-only admission.

    {b Co-tenant pure projections.} {!Notice} and {!Health} live here though
    neither is about path binding: dependency direction forces them into this
    pure library — the lowest one every layer above the workspace shares — so
    the engine and protocol can name and serialize them without linking a
    resource or build-tool effect library. Their placement is deliberate, not a
    path concern. *)

(** {1:components Components} *)

module Root = Root
(** Stable root identities bound to current logical directories. *)

module Path = Path
(** Durable root-key-relative workspace paths. *)

module Error = Error
(** Workspace construction errors. *)

module Resolve_error = Resolve_error
(** Raw, absolute, and root-key path-resolution errors. *)

module Notice = Notice
(** Model-visible workspace runtime observations. Pure data, drained at turn
    preparation and recorded as a durable, turn-scoped session fact the engine
    both renders and re-injects into that turn's model request. *)

module Health = Health
(** The workspace build-watch status a frontend glances at, wire-safe and
    fail-honest as a type: the status is always renderable, a build verdict
    exists only inside a settled phase. *)

type t
(** An admitted workspace. Exactly one root is primary and writable; every
    auxiliary root is read-only. Across all admitted roots, durable keys and
    logical directories have a bijective relationship. Root order is primary
    first and then auxiliaries in admission order; this order participates in
    equality. The current directory names an admitted root key and cannot be
    changed after construction. *)

(** {1:constructors Constructors} *)

val single : ?cwd:Lpath.Rel.t -> Root.t -> t
(** [single ?cwd root] admits [root] as the primary with no auxiliaries. [cwd]
    is relative to [root] and defaults to {!Lpath.Rel.root}. This constructor
    cannot fail because the root is admitted by construction and [cwd] is
    already normalized typed syntax. *)

val make :
  ?cwd:Path.t ->
  primary:Root.t ->
  read_only:Root.t list ->
  unit ->
  (t, Error.t) result
(** [make ~primary ~read_only ()] admits [primary] as writable and each
    auxiliary as read-only. Exact duplicate roots are dropped, preserving the
    first admission. A root key cannot name two logical directories and a
    logical directory cannot be admitted under two keys.

    [cwd] defaults to the primary root. A supplied [cwd] must name an admitted
    root key; its current absolute binding always comes from the admitted root,
    never from the path value.

    Errors with {!Error.Conflicting_root} for a key/directory conflict and
    {!Error.Root_not_in_workspace} when [cwd] names an unknown root key. A
    mandatory [primary] makes an empty workspace unrepresentable. *)

(** {1:admission Root admission} *)

val roots : t -> Root.t list
(** [roots workspace] is every admitted root, primary first and then auxiliaries
    in admission order. *)

val primary : t -> Root.t
(** [primary workspace] is its single writable root and stable default for
    workspace-level operations. *)

val read_only_roots : t -> Root.t list
(** [read_only_roots workspace] is its unique auxiliary roots in admission
    order. *)

val is_writable : t -> Root.t -> bool
(** [is_writable workspace root] is [true] iff [root] is the admitted primary.
    It is [false] for an auxiliary or unadmitted binding. *)

val is_writable_path : t -> Path.t -> bool
(** [is_writable_path workspace path] is [true] iff [path] names the primary
    root key. It is [false] for auxiliary and unknown root keys. This is
    workspace admission data, not filesystem or permission authority. *)

val root_by_key : t -> Root.Key.t -> Root.t option
(** [root_by_key workspace key] is the unique current binding for [key], or
    [None] when [key] is not admitted. *)

val contains_path : t -> Path.t -> bool
(** [contains_path workspace path] is [true] iff [path]'s root key is admitted.
    It checks logical admission only, not filesystem existence, permissions, or
    physical containment after following symlinks. *)

(** {1:bases Resolution bases} *)

val cwd : t -> Path.t
(** [cwd workspace] is its construction-fixed base for relative raw input. It is
    explicit workspace data, not the ambient process working directory. *)

val root_path : t -> Path.t
(** [root_path workspace] addresses the primary root, independent of {!cwd}. *)

val path_at_cwd_root : t -> Lpath.Rel.t -> Path.t
(** [path_at_cwd_root workspace rel] addresses [rel] within the root identity
    containing {!cwd}. It does not append [rel] below the current directory. Use
    it for already-parsed root-relative input. *)

(** {1:resolving Resolving and binding paths} *)

val import_abs : t -> Lpath.Abs.t -> (Path.t, Resolve_error.t) result
(** [import_abs workspace abs] imports [abs] under the most-specific admitted
    root that lexically contains it. For example, when both [/workspace] and
    [/workspace/vendor] are admitted, an address below the latter uses the
    [/workspace/vendor] root key.

    Errors with {!Resolve_error.Outside_workspace} when no admitted root
    contains [abs]. Success proves lexical containment only; existence, target
    kind, permission, and post-symlink containment belong to the host layer. *)

val resolve_string : t -> string -> (Path.t, Resolve_error.t) result
(** [resolve_string workspace input] parses raw absolute or relative input. An
    absolute input must lie in an admitted root. A relative input resolves
    against {!cwd} and is then imported with the same most-specific-root rule as
    {!import_abs}.

    Errors with {!Resolve_error.Invalid_input} when [input] is malformed and
    {!Resolve_error.Outside_workspace} when the resolved address is well-formed
    but outside every admitted root. Use this function at raw product or
    user-input boundaries; prefer typed {!Path.append} or {!import_abs} when
    input is already parsed. *)

val to_abs : t -> Path.t -> (Lpath.Abs.t, Resolve_error.t) result
(** [to_abs workspace path] binds [path] through the current directory of its
    admitted root. The result may change when the same root key is mounted at a
    different directory, while [path] itself remains equal and persistable.

    Errors with {!Resolve_error.Unknown_root} when [workspace] does not admit
    [Path.root_key path]. This logical projection performs no filesystem access
    and does not prove existence or post-symlink containment. *)

(** {1:comparison Comparison and formatting} *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have equal primary roots, equal
    auxiliary roots in the same order, and equal current directories. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf workspace] formats [workspace] for diagnostics. *)

(** {1:protected Protected metadata} *)

val protected_meta_names : string list
(** [protected_meta_names] is [[".git"; ".mentat"]], the top-level metadata
    names that native edits and confined commands must not rewrite. *)

val run_dir_name : string
(** [run_dir_name] is ["run"]: the [.mentat] subdirectory holding
    per-process runtime state (the build watch supervisor's private
    registry). The sandbox's session-run grant and the supervisor's
    directory maintenance both take the name here, so the grant and the
    directory cannot drift apart. *)

val protected_meta_component : Path.t -> string option
(** [protected_meta_component path] is [Some name] iff the first component of
    [Path.rel path] is a {!protected_meta_names} entry. It is [Some ".git"] for
    [.git/config], including when the target does not exist, but [None] for
    [src/.git], [.gitignore], and the root path.

    The check is pure and lexical. It does not check root admission or
    filesystem state. *)

val observation_prune_names : string list
(** [observation_prune_names] is [[".git"; ".mentat"; "_build"; "_opam"]], the
    top-level directory names whose subtrees the workspace observers — the
    filesystem watcher and the review git loader — prune, since their churn is
    machinery, not workspace content. It is a superset of
    {!protected_meta_names}: write protection guards a narrower set, so the two
    lists are kept independent rather than one derived from the other. *)
