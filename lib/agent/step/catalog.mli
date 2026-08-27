(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The one dispatch surface.

    A catalog is one exact validated vocabulary: executable tools plus the
    explicitly supplied product-native and collaboration verbs. Its validation
    and dispatch are pure and live in this unit; [Agent.Catalog] is their public
    face. Duplicate and reserved-name rejection is the construction invariant.

    Engine verbs are dispatch vocabulary, never executable tools: a verb call is
    evaluated by the step as a pure function of decoded input and session state.
    The verb spellings are stable: [spawn], [wait], [send], and [follow_up]
    for the collaboration verbs, [todo_write], [ask_user], and [propose_plan]
    for the product-native verbs. Recorded calls under the retired
    [send_message] spelling stay readable — the step's receipt scan decodes
    them forever — but the name is no longer declared or dispatched. *)

(** {1:verbs Engine verbs} *)

module Verb : sig
  (** The type for the engine's built-in dispatch verbs. *)
  type t =
    | Todo_write  (** Replace the whole task board. *)
    | Ask_user  (** Park a reviewer question decision. *)
    | Propose_plan  (** Park a plan-proposal decision. *)
    | Spawn  (** Reserve and record a child delegation. *)
    | Wait  (** Park on named children until they settle. *)
    | Send  (** Durable mail into a kin session's queue — a spawned child
                ([to: "child:<id>"]) or this session's parent
                ([to: "parent"]). *)
    | Follow_up  (** One new turn on an idle child. *)

  val name : t -> string
  (** [name v] is [v]'s stable model-visible tool name. *)

  val declaration : t -> Mentat_llm.Tool.t
  (** [declaration v] is [v]'s model-visible declaration. The input schema is
      paired with the step's verb input decoding, which is strict against the
      advertised schema: an unknown object member — a nested [todo_write] item
      included — fails, and a field dropped from the contract fails loudly
      rather than passing as ignored compatibility payload. *)
end

(** {1:errors Errors} *)

module Error : sig
  (** Catalog construction errors. *)
  type t =
    | Duplicate_name of string
        (** Two executable tools declared the same name. *)
    | Reserved_name of string
        (** An executable tool used an engine verb's name. *)
    | Duplicate_verb of Verb.t
        (** A catalog construction named the same engine verb more than once. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. *)
end

(** {1:catalogs Catalogs} *)

val output_tool_name : string
(** [output_tool_name] is the reserved name of the synthetic structured-output
    tool ([structured_output]). It is not a dispatch verb — it is sealed on the
    turn contract and dispatched by the step's own terminal branch — but it is
    reserved here so no executable tool can claim it, keeping the request's
    [declarations @ [output_tool]] free of a duplicate name. *)

type t
(** The type for one exact validated dispatch vocabulary. Invariant: executable
    tool names and engine verbs are each unique, and no executable name collides
    with any engine verb or the reserved {!output_tool_name}. *)

val make : verbs:Verb.t list -> Mentat_tool.t list -> (t, Error.t) result
(** [make ~verbs tools] is the exact catalog containing [tools] and [verbs], in
    their supplied order. It returns a structured {!Error.t} on a duplicate or
    reserved executable name or a duplicate verb. There is deliberately no
    implicit engine-verb set. *)

val declarations : t -> Mentat_llm.Tool.t list
(** [declarations t] is the model-visible declaration snapshot a new turn's
    contract seals: the executable declarations, then the verb declarations. *)

val resolve :
  t -> string -> [ `Executable of Mentat_tool.t | `Verb of Verb.t ] option
(** [resolve t name] is the dispatch target for the model tool name [name], or
    [None] when the catalog knows no such name. *)
