(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** A policy lowered by one backend: the internal enforcement profile.

    Internal to the library — no consumer outside it holds a profile. [Seal]
    builds a profile from the policy it seals, so the enforcing prefix a command
    runs under and the digest its {!Evidence} reports are generated together and
    cannot describe different policies. Generation is pure and deterministic:
    equal policies produce byte-equal profiles and equal digests. *)

type t
(** A lowered profile: the enforcing argv prefix, whether a working-directory
    argument is inserted at wrap time, and the digest of the generated profile
    text. *)

val prepare : Backend.t -> Policy.t -> t
(** [prepare backend policy] lowers [policy] with [backend]'s pure generator
    ({!Seatbelt.sbpl} or {!Bubblewrap.arguments}), assembling the enforcing
    prefix behind {!Backend.executable} and digesting the canonical profile text
    with [Mentat_digest.derive ~domain:"mentat.sandbox.profile.v1"]. Total. *)

val digest : t -> Mentat_digest.t
(** [digest t] is the derived digest of the generated profile text. {!Evidence}
    reports it, and {!Identity} seals it for resume comparison; it changes on
    any confinement change and on a generator change that alters the profile
    text. *)

val wrap : t -> cwd:Lpath.Abs.t -> string list -> string list
(** [wrap t ~cwd argv] is the enforcing argv around [argv]: [t]'s prefix,
    optionally a [--chdir cwd --] segment (Bubblewrap), then [argv]'s tokens
    verbatim. A prefix cannot rewrite, reorder, or drop the command it wraps.
    Pure prefix application; [argv] is [Seal]-validated non-empty. *)
