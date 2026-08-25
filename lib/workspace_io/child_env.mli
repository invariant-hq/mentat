(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The one private child environment.

    Constructed exactly once, at resolution, and served byte-for-byte to every
    launch on every route: ambient secrets and agent sockets never appear
    because inheritance is allow-listed, and nothing is rewritten. The
    allow-list carries every variable the resolver derives a root from — [HOME],
    the temp-dir family, and the three base directories beneath it — so the
    child computes the same directories the policy grants, and the whole dune
    and OCaml configuration families ([DUNE_*], [OCAML*], [CAML*]), so a build
    inside is configured exactly like the user's build outside: dune folds its
    configuration into every rule digest, and two differently configured builds
    sharing one build directory re-execute each other's work on every
    alternation. Construction is total: ambient values that cannot be
    represented (a NUL byte, a malformed path segment) are dropped, never fatal.

    [PWD] is deliberately absent here and written by the launch instead: it
    names the directory a single command starts in, which the resolution does
    not know, and the external backends assign it themselves once they enter the
    sandbox. *)

type t = {
  bindings : string array;
      (** ["NAME=value"] bindings sorted by name, the exact array every spawn
          receives. *)
  path_dirs : string list;
      (** The normalized [PATH] directories, in search order — the same
          directories the child's [PATH] names, used by the launch boundary to
          resolve an implicit program. *)
}

module Policy : sig
  (** The configurable half of the construction — [sandbox.env_inherit],
      [sandbox.env_exclude], [sandbox.env_include_only] — governing the
      inherited sets beyond the structural core. The core is not governable:
      [PATH], the fixed bindings, the locale family, and every variable the
      resolver derives a grant from — [HOME], the temp-dir and XDG bases,
      [OPAMROOT], [GIT_CONFIG_GLOBAL], [DUNE_CACHE_ROOT], and the OCaml
      toolchain path variables. Excluding one would leave the policy granting
      directories the child no longer computes, the disagreement this library
      exists to prevent. A floor of secret-shaped patterns and agent handles is
      applied before the policy and nothing subtracts from it. *)

  type t = {
    inherit_all : bool;
        (** Inherit every remaining ambient name, floor and policy permitting —
            the widest posture, as an explicit choice. *)
    exclude : string list;
        (** Case-insensitive ['*'] globs removed from the governable sets, on
            top of the floor. *)
    include_only : string list;
        (** When non-empty, only governable names matching one of these globs
            are inherited — the hard mode. *)
  }

  val default : t
  (** The allow-list posture: no [inherit_all], nothing excluded beyond the
      floor, no restriction. *)
end

val make :
  path:string ->
  lookup:(string -> string option) ->
  names:string list ->
  policy:Policy.t ->
  t
(** [make ~path ~lookup ~names ~policy] builds the environment.

    [path] is the resolver-derived [PATH] value; its segments are normalized
    (absolute, deduplicated, malformed segments dropped). No value is rewritten:
    [HOME] and the temp-dir family are inherited like every other allow-listed
    name, so the resolver derives its roots from the same values the child reads
    and no directory can be named to a tool without the grant that makes it
    usable. [lookup] reads the ambient environment for the allow-listed names:
    [HOME], the temp-dir family, locale variables verbatim, the curated
    build-tool set verbatim — the C toolchain ([CC] and the flag families),
    pkg-config's search path, the proxy variables in both spellings, TLS trust,
    and git identity — and the OCaml toolchain variables with their path values
    normalized. [names] are the ambient variable names, from which the dune and
    OCaml configuration families are inherited verbatim by prefix — every
    [DUNE_*], [OCAML*] and [CAML*] name except the handles dune assigns to the
    actions it spawns ([DUNE_ACTION_TRACE_DIR], [DUNE_SOURCEROOT],
    [DUNE_DIR_LOCATIONS]), which describe a running dune instance rather than
    configure one. Fixed pager, color, and terminal bindings complete the set.
*)
