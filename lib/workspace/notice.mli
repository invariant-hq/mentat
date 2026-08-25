(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace runtime observations.

    A notice is a workspace runtime observation: filesystem watcher batches,
    dune diagnostic and build-health changes, code-review comments. Producers
    construct notices and own their own deduplication — the port has no queue —
    while {!val:key} is the coalescing identity the surfaces display on; the
    engine drains them transactionally wherever a turn resumes from waiting on
    the outside world — preparing the turn, settling a tool claim, taking
    delegated children's answers — so what the world says while a turn runs
    reaches that turn rather than the next one.

    A drained notice is a {e durable, turn-scoped} datum, not an ephemeral
    prelude item. At the drain boundary the engine converts its model-visible
    content to the session-owned {!Mentat_session.Notice.t} — the durable core
    the journal controls, without this type's producer-side coalescing [key] —
    and records it against the turn that saw it (the session's
    [Workspace_notice] event), injecting the active turn's own into that turn's
    continuation requests: replay reconstructs exactly the observation a turn
    saw, and a later turn carries its own and no other's. Within a turn a
    producer may speak more than once, and every one of a turn's observations is
    stated in the order it arrived — a producer is free to report a state or a
    delta, and nothing here can tell which, so none is dropped in favour of a
    later one. A notice is an external observation, not a projection of the
    transcript, so storing it does not violate the
    derived-facts-are-never-stored law, which binds only genuinely-derived
    facts. Engine-authored prelude items — subagent parent messages — are
    {e not} notices: the engine constructs none of these and carries them as
    the step's own prelude input.

    Notices are pure data and live in this pure library because both notice
    consumers are pure: the engine names the type through the [WORKSPACE] port
    without linking any resource library, and the protocol's progress lane
    serializes it with {!jsont}. The codec serves that ephemeral wire lane; the
    durable journal owns its own {!Mentat_session.Notice.t} the drain converts
    to.

    Every accessor is plain text, so consumers can render a notice without this
    library owning any rendering policy. *)

(** Notice severities. *)
module Severity : sig
  type t = Info | Warning | Error  (** The type for notice severities. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same severity. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf severity] formats [severity] for diagnostics. *)
end

type t
(** A model-visible workspace runtime observation.

    Invariant: [source], [title], and [key] are non-empty, and [body] is
    non-empty when present. *)

(** {1:constructors Constructors} *)

val make :
  source:string ->
  severity:Severity.t ->
  title:string ->
  ?body:string ->
  key:string ->
  unit ->
  t
(** [make ~source ~severity ~title ?body ~key ()] is a notice from the producer
    named [source] with a one-line [title] and optional multi-line [body]
    (default: none). [key] is the producer-owned coalescing identity: while
    queued, a newer notice with the same key replaces the older one. The key is
    state identity for the queue, never model-visible text.

    Raises [Invalid_argument] if [source], [title], or [key] is empty, or if
    [body] is present and empty. *)

(** {1:queries Queries} *)

val source : t -> string
(** [source t] names the producer (for example ["dune"] or ["fswatch"]). *)

val severity : t -> Severity.t
(** [severity t] is the notice's severity. *)

val title : t -> string
(** [title t] is the one-line summary. *)

val body : t -> string option
(** [body t] is the optional detail text. *)

val key : t -> string
(** [key t] is the queue-coalescing identity (see {!make}). *)

(** {1:comparison Comparison and formatting} *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] agree on every field, [key] included.
*)

val pp : Format.formatter -> t -> unit
(** [pp ppf notice] formats [notice] for diagnostics. *)

(** {1:codec Codec} *)

val jsont : t Jsont.t
(** [jsont] encodes the strict JSON object with string members ["source"],
    ["severity"] (["info"], ["warning"], or ["error"]), ["title"], ["key"], and
    the optional string member ["body"] (omitted when absent). Decoding rejects
    missing required members, unknown members, unknown severities, and any value
    violating {!make}'s non-empty invariants. The codec serves the ephemeral
    progress wire lane; the durable journal records the converted, session-owned
    {!Mentat_session.Notice.t} through its own codec. *)
