(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session targeting shared by the [session] and [run] commands. Every
    non-empty target is loaded exactly first; only an exact [Not_found] falls
    back to mixed healthy/corrupt prefix resolution. *)

type error
(** A private executable control-flow error. It preserves store corruption and
    exact not-found facts until {!status}; no candidate/index concept crosses
    the frontend boundary. *)

val status : error -> Mentat_boot.Exit_status.t
(** [status error] classifies invalid/ambiguous input as usage and store or
    availability failures as runtime errors. *)

val resolve :
  Mentat_boot.Composition.t ->
  session:string option ->
  last:bool ->
  (Mentat_store.Session.Document.t, error) result
(** [resolve t ~session ~last] applies the [SESSION] xor [--last] rule: exactly
    one of a positional id/prefix and the newest resumable session in the
    workspace. A positional target is exact-load-first. Prefix resolution counts
    both healthy documents and corrupt facts carrying ids; exactly one corrupt
    candidate reports that corruption, while mixed or multiple candidates are
    ambiguous. Unrelated corruption never blocks resolution. *)
