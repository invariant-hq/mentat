(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The workspace build-watch status and verdict — the ambient glance's dune
    signal.

    A wire-safe projection of one workspace's dune watch, owned in this pure
    library so every layer above the workspace can name it without linking a
    build-tool effect library: the protocol embeds {!jsont} on its query
    response lane, and a frontend renders it directly.

    {b The fail-honest law, as a type.} A build verdict exists only inside
    {!Phase.Settled}: every other state carries no verdict, so a frontend
    cannot invent one while a build runs, a connection is being established,
    or nothing is attached. The status itself is a fact about the watch — a
    frontend may always render it. A value is a point-in-time observation a
    frontend holds as a last observation and re-reads on demand; it is never
    persisted derived state. *)

(** Build verdicts of a settled reading. *)
module Verdict : sig
  type t = Clean | Failing of { errors : int; warnings : int }
  (** The type for verdicts. [Failing] counts the build lane's diagnostics by
      severity; a failed build that printed only warnings is
      [Failing { errors = 0; warnings = n }], never [Clean] — the build tool's
      own verdict is failure. Invariant: [Failing] has [errors + warnings >=
      1]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same verdict with the same
      counts. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** Watch owners. *)
module Owner : sig
  type t = Ours | Theirs of int
  (** The type for owners: the watch this instance spawned and supervises, or
      an already-running one attached to by its advertised pid. A foreign
      watch is observed, never signalled. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same owner with the same
      pid. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** Phases of a live, attached watch. *)
module Phase : sig
  type t =
    | Building
        (** A build is in progress, or none has settled since attaching. No
            verdict. *)
    | Settled of { build : Verdict.t; lint : int option }
        (** The last build settled: the build verdict, and the lint lane's
            finding count — [None] when the lane is off or the watch's lint
            targets are unknown, which is absence, never cleanliness. *)
  (** The type for phases. Every phase has a producer: a foreign watch that
      stops answering has none yet, so no phase names it — detection would
      mint the state alongside itself. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same phase with the same
      verdict and lint count. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** Why no watch is running. *)
module Off : sig
  type t =
    | Disabled  (** Workspace tooling is disabled or the workspace untrusted. *)
    | No_dune  (** No dune executable resolves. *)
    | No_server
        (** Nothing is attached and this instance does not spawn: no endpoint
            is registered, or nothing answered. Not an error. *)
    | Blocked of string
        (** The watch cannot run here; the payload names why (for example a
            sandbox denying its file watcher). *)
    | Gave_up  (** Successive spawned watches died before coming up. *)
  (** The type for off reasons. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same reason with the same
      payload. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** Why an owned watch is being respawned. *)
module Restart : sig
  type t = Exited of string | Hung
  (** The type for restart causes: the watch's last life ended on its own —
      the payload describes how, an exit status tailed with the watch's dying
      words when any were captured, or a failure to spawn at all — or it
      stopped answering liveness probes and was killed. The distinction is
      rendered differently and counted separately. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same cause with the same
      payload. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

type t =
  | Off of Off.t  (** No watch and no attachment. *)
  | Probing  (** Discovery or connection establishment is in flight. *)
  | Starting  (** A spawned watch has not yet accepted a connection. *)
  | Live of { owner : Owner.t; phase : Phase.t }  (** Attached. *)
  | Restarting of Restart.t  (** An owned watch is being respawned. *)
(** The type for watch statuses. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same status, every payload
    included. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] is the JSON codec for a status — the one wire form the protocol's
    query response embeds. It round-trips every case, payloads included. *)
