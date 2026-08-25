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

val classify :
  lint:bool ->
  severity:Severity.t ->
  ?path:string ->
  ?location:string ->
  head:string ->
  unit ->
  t
(** [classify ~lint ~severity ?path ?location ~head ()] is {!v} with the lane
    decided by the lint marker: the finding is [Lint] iff [lint] is [true] and
    [head] ends with [" [<rule>]"] where [<rule>] matches [[a-z][a-z0-9-]*] —
    the convention a lint tool running inside the build uses to mark its
    findings, since the build tool's wire drops the rule identity. Everything
    else is [Build].

    Raises [Invalid_argument] as {!v} does. *)

(** {1:queries Queries} *)

val lane : t -> Lane.t
(** [lane t] is the finding's lane. *)

val severity : t -> Severity.t
(** [severity t] is the finding's severity. *)

val path : t -> string option
(** [path t] is the workspace-relative file, when the finding has one. *)

val location : t -> string option
(** [location t] is the rendered position, when the finding has one. *)

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

(** {1:comparison Comparison and formatting} *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have equal {!val:key}s. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)
