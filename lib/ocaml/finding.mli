(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Build and lint diagnostic identities.

    A finding is one diagnostic of a settled build reading, reduced to the
    identity the change law compares: its lane, severity, path, and first
    message line. Position is display data, never identity — an error that
    moves with an edit above it is the same finding, while a different message
    at the same position is a new one.

    Findings are pure data. The producer that reads a build tool's diagnostics
    constructs them; {!Build_change.step} compares their {!val:key}s. *)

(** Finding lanes. *)
module Lane : sig
  type t = Build | Lint
  (** The type for lanes. [Build] is the compiler's verdict; [Lint] carries a
      linter's findings, which never make the build verdict. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same lane. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf lane] formats [lane] for diagnostics. *)
end

(** Finding severities. *)
module Severity : sig
  type t = Error | Warning
  (** The type for severities. A build tool's informational output never
      becomes a finding. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same severity. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf severity] formats [severity] for diagnostics. *)
end

type t
(** The type for findings.

    Invariant: [head] is non-empty and single-line. *)

val v :
  lane:Lane.t ->
  severity:Severity.t ->
  ?path:string ->
  ?location:string ->
  head:string ->
  unit ->
  t
(** [v ~lane ~severity ?path ?location ~head ()] is a finding with an explicit
    lane. [path] is the workspace-relative file the finding is anchored to,
    when it has one; [location] is its rendered position
    (["path:line:col-line:col"]), display data only. [head] is the first line
    of the diagnostic message.

    Raises [Invalid_argument] if [head] is empty or contains a newline. *)

(** {1:queries Queries} *)

val lane : t -> Lane.t
(** [lane t] is the finding's lane. *)

val severity : t -> Severity.t
(** [severity t] is the finding's severity. *)

val path : t -> string option
(** [path t] is the workspace-relative file, when the finding has one. *)

val head : t -> string
(** [head t] is the first line of the diagnostic message. *)

val key : t -> string
(** [key t] is the finding's comparison identity: lane, severity, path, and
    head — never the position. Two findings with equal keys are the same
    finding to the change law. *)

val body_line : t -> string
(** [body_line t] is the one-line rendering a notice body carries:
    ["<location>: <head>"], or [head] alone when the finding has no location.
*)

(** {1:derivation Derivation}

    Both lanes — the watch stream's diagnostics and the lint runner's parsed
    reports — derive their display data here, so the two renderings cannot
    drift apart. *)

val head_of_message : string -> string
(** [head_of_message message] is the head a converter derives from a raw
    diagnostic message: the first line of the trimmed text, itself trimmed,
    or ["(no message)"] when nothing remains. *)

val rendered_location : Location.t -> string * string
(** [rendered_location location] is the [(path, location)] display pair a
    finding carries: {!Mentat_workspace.Path.display} of the location's path,
    and the location rendered by {!Location.pp}. *)
