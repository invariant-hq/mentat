(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Resolution-time root derivation.

    The effect half of sandbox resolution that turns the logical workspace and
    the ambient environment into policy inputs: canonicalized workspace roots,
    validated configured roots, platform/executable/toolchain/git-worktree read
    roots, the existence-filtered protected set, the derived child [PATH], and
    the origin-labeled display facts behind
    {!Mentat_workspace_io.describe_roots}.

    Every spelling is canonicalized exactly once, here; broad roots — [/], the
    account home, a workspace ancestor — are rejected at admission. The module's
    effects are resolution-time and bounded: filesystem observation ([stat],
    [realpath], reading git worktree metadata), and the creation of the
    directories Mentat itself owns, which must exist to be denied and are minted
    here under a guard that refuses a symlink, a non-directory, or another
    user's directory rather than adopting one. It opens no capability and
    launches nothing. *)

type derived = {
  workspace_roots : (Mentat_workspace.Root.t * Lpath.Abs.t) list;
      (** Each admitted logical root with its canonical directory, primary
          first, in admission order. These are the roots the resolver opens. *)
  writable : Lpath.Abs.t list;
      (** The primary root, the validated configured writable roots, and — when
          the primary root carries a [.mentat] directory — its materialized
          [.mentat/run] session-run directory, granted back to write beneath
          the read-only [.mentat] carveout so a supervised build watch spawned
          with its private runtime directory there can create and write its
          registry entry. *)
  platform_writable : Lpath.Abs.t list;
      (** Shared scratch space: [/tmp] on both platforms, and each of the
          temp-dir variables the child inherits that names an existing,
          non-broad directory — on macOS that is how the per-user Darwin temp
          bucket is admitted. Nothing here outlives a command by intent, which
          is what makes it the one writable set a no-mutation route still gets.
          These join the sandbox policy's writable roots and are never described
          or protected. *)
  toolchain_writable : Lpath.Abs.t list;
      (** Toolchain state a build must write, outside the workspace — dune's
          cache, which holds the revision-store lock a pinned-source build takes
          unconditionally, and on macOS the per-user Darwin {e cache} bucket
          Apple's developer-tool shims cache under. Separate from
          {!platform_writable} because it is persistent user state rather than
          scratch space: a route that promises no mutation is still granted
          somewhere to put a temporary file, and is not granted this. *)
  readable : Lpath.Abs.t list;
      (** The scoped read roots (workspace, configured, platform, executable,
          toolchain, git-worktree, git-config); [[]] when not scoped. *)
  protected : Lpath.Abs.t list;
      (** The existence-filtered protected paths: existing protected metadata
          under the primary root, the read-only workspace roots, the linked
          git-worktree directories, and the carveouts of each [Read_write]
          carried directory. Only existing entries appear, so a carveout naming
          a directory that does not exist yet protects nothing — the strict
          read-only bind a carveout lowers to cannot name a missing source. *)
  denied : Lpath.Abs.t list;
      (** Mentat's own user directories — the config, data and state homes —
          which no confined command may read or write on any route, in any mode.
          Materialized at resolution under the guard in {!run}, so the set is
          independent of machine state and a planted symlink cannot relocate the
          exclusion; entries whose parent Mentat does not own are dropped rather
          than created. Unlike {!protected}, these are not filtered against the
          writable roots: a denial is meaningful wherever it lies, and one that
          falls {e inside} a writable root is exactly the case worth keeping —
          see {!run} for the containment that is refused instead. *)
  path : string;
      (** The derived child [PATH] value. Scoped, it is rebuilt from the
          toolchain bin directory followed by the admitted executable roots,
          deduplicated; unscoped, it prepends the toolchain bin directory to the
          ambient [PATH]. *)
  describe : (string * Lpath.Abs.t) list;
      (** Origin-labeled read-root facts in display order, before the
          policy-membership filter the facade applies. *)
}

val run :
  scoped:bool ->
  lookup:(string -> string option) ->
  logical:Mentat_workspace.t ->
  configured_reads:string list ->
  configured_writes:string list ->
  mentat_dirs:Lpath.Abs.t list ->
  (derived, Resolve_error.t) result
(** [run ~scoped ~lookup ~logical ~configured_reads ~configured_writes
     ~mentat_dirs] derives every policy input for one resolution.

    [mentat_dirs] are Mentat's own user directories, which become {!denied}. A
    denied path that {e contains} a granted root — readable or writable — is
    refused ({!Resolve_error.Denied_overlaps_grant}): both backends let the
    deeper grant win inside the denial, so admitting it would carve a hole in
    the one set of directories that must stay closed — the session store's
    confinement identity is what a resume revalidates against. A denial nested
    {e inside} a granted root is admitted and enforced — that is a store kept
    inside the workspace, and masking just that subtree is the point. [scoped]
    is [true] iff the route is confined with project-scoped reads; unscoped
    derivation still canonicalizes the workspace roots and validates the
    configured writable roots. [lookup] reads the ambient environment. *)

val canonical : Lpath.Abs.t -> Lpath.Abs.t
(** [canonical path] is [path] resolved through [realpath] where it exists (so
    the described path equals the enforced path, for example [/tmp] to
    [/private/tmp] on macOS); a path that cannot be resolved keeps its lexical
    spelling. *)

val is_linux : unit -> bool
(** [is_linux ()] is [true] iff the host is Linux. *)

val is_executable_file : string -> bool
(** [is_executable_file path] is [true] iff [path] (symlinks followed) is a
    regular file this process may execute ([X_OK]). A directory or a
    non-executable file is [false], so neither can shadow a real executable in a
    [PATH] search or pass an availability probe. *)
