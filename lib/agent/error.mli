(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Structured engine errors.

    Composed from owner errors — the step's error cases fold in here; human
    messages are renderings, never the branching interface. *)

module Delegation : sig
  (** Failures while verifying durable delegated-session lineage. *)

  type t =
    | Parent_not_found of Mentat_session.Id.t
        (** The child backlink names no saved parent session. *)
    | Edge_not_found of {
        parent : Mentat_session.Id.t;
        delegation : Mentat_session.Delegation.Id.t;
      }  (** The named parent has no matching delegation edge. *)
    | Child_mismatch of {
        delegation : Mentat_session.Delegation.Id.t;
        expected : Mentat_session.Id.t;
        found : Mentat_session.Id.t;
      }  (** The edge exists but names a different child session. *)
    | Cycle of Mentat_session.Id.t
        (** Following a parent backlink revisited this session. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats {!message} output. *)
end

(** The type for engine errors. *)
type t =
  | Busy of { owner : string option }
      (** The fence is held by another driver — the store fence's held signal,
          mapped. [owner] is the store's rendered owner line when the holder's
          owner line was readable, [None] otherwise; the exclusion is
          authoritative either way. *)
  | Not_found
      (** No document exists for the addressed session — the store's not-found,
          minus the id the call site already holds. The runtime bridge restores
          the id when it maps this onto the protocol's [Session_not_found]. *)
  | Store of Mentat_diagnostic.t
      (** A store operation failed: a CAS conflict under the held fence (a
          fence violation or an engine bug — the driver faults, never a silent
          retry), corrupt persisted data, or a filesystem or lock failure. The
          diagnostic is the store's own, passed through whole. *)
  | Request of Mentat_llm.Request.Error.t
      (** The model transcript could not become a model request. *)
  | Session of Mentat_session.Error.t
      (** A checked append was refused — a step or driver bug, loud. *)
  | Decision of Mentat_session.Decision.Resolve_error.t
      (** A decision answer failed validation — including the
          unattended-may-only-deny restriction. *)
  | Configuration of Mentat_diagnostic.t
      (** The per-session configuration callback failed. *)
  | Delegation of Delegation.t
      (** A delegated child failed durable parent-edge verification. *)
  | Internal of Mentat_diagnostic.t
      (** A driver-protocol violation surfaced loudly — a step feed-back applied
          against a state it cannot serve, or a callback exception's retained
          diagnostic. *)
  | Shutting_down  (** The agent no longer admits work. *)

val of_step : Mentat_agent_step.Error.t -> t
(** [of_step e] folds a step error into the engine vocabulary: session,
    decision, and request arms map to their owners; the step's protocol cases
    become {!Internal}. *)

val message : t -> string
(** [message e] is a human-readable diagnostic for [e]. *)

val diagnostic : t -> Mentat_diagnostic.t
(** [diagnostic e] is the renderable diagnostic for [e]. The {!Store} arm
    passes its carried diagnostic through whole, keeping the store's located
    subject and hints intact. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats {!message} output. *)
