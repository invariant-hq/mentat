(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Protocol errors.

    One flat, structured, fully-inhabitable type at this boundary. No
    constructor is reserved, none wraps a lower library's error chain; the one
    opaque escape is a {!Mentat_diagnostic.t} for failures a client can only
    report — and that diagnostic crosses the wire whole (message, context, and
    hints), never flattened to a string.

    Deliberately absent: no [Cursor_expired] (v1 retains the whole journal), no
    [Not_permitted] (a non-local principal is unrepresentable in v1), no
    [Unsupported] (nothing is reserved), no free-string invalid input. Commands
    validate their own payloads; raw lifecycle/account flow inputs use the two
    closed {!Invalid_title}/{!Invalid_api_key} errors below. There is no
    mirrored provider error (a known provider failure streams as a structured
    {!Fact.Turn_provider_failed} followed by the generic turn settlement), no
    store revision conflict (a client never holds a revision), and no
    [Feed_closed]: a closed feed is a local delivery outcome ({!Mentat_agent}'s
    feed seam owns it), never a versioned wire value. A structural
    [Admission_unknown] arm — for a backend that cannot prove durable admission
    — is not minted here; it lands with the agent durable-admission wave. *)

(** The type for protocol errors. *)
type t =
  | Busy of { session : Mentat_session.Id.t; owner : string option }
      (** Another process drives the session; [owner] is a display-only rendered
          line the producer supplied through the store's owner printer, or
          [None] when the holder's owner line was unreadable. Protocol takes no
          store dependency: the string arrives pre-rendered. *)
  | Session_not_found of Mentat_session.Id.t
  | Invalid_position of Position.Invalid.t
      (** A threaded position is not a legitimate resume token: it belongs to
          another session's feed, or it names no committed fact of its own. *)
  | No_active_turn of Mentat_session.Id.t
  | Active_turn_exists of Mentat_session.Turn.Id.t
  | Turn_id_reused of Mentat_session.Turn.Id.t
      (** The same client-minted turn id was resubmitted with a different
          payload. *)
  | Decision_not_pending of Mentat_session.Decision.Id.t
      (** The answered decision id is unknown, resolved-and-gone, or of another
          kind. *)
  | Already_resolved of Mentat_session.Decision.Id.t
      (** A later answer lost to the first valid one. *)
  | Invalid_title
      (** A public client lifecycle flow received an empty title. Rejected
          before its driver responder runs. *)
  | Invalid_api_key
      (** A public client credential flow received an empty API key. Rejected
          before its driver responder runs; the key is never carried or rendered
          by this error. *)
  | Archived of Mentat_session.Id.t
  | Deleted of Mentat_session.Id.t
  | Unknown_command of User_command.Name.t
      (** An expanded command name names no active custom command — the
          expansion-race outcome where a name in a frontend's catalog snapshot
          named a command file that changed before expansion. It names a missing
          entity, parallel to {!Session_not_found}; the frontend renders it
          inline. Ordinary unknown [/x] slash lines are never this error: a
          frontend intercepts only known command tokens and sends the rest
          literally. *)
  | File_unresolved of { path : string; reason : string }
      (** An [@path] file reference in an expanded command body could not be
          resolved: it escaped the workspace, named no file, was unreadable, or
          was requested in an untrusted workspace. [path] is the reference as
          written and [reason] a one-line diagnostic. Expansion is all-or-
          nothing, so no turn is sent; the frontend renders it inline, naming
          the failing path so the user fixes the command rather than firing a
          half-built prompt. *)
  | Unavailable of Mentat_diagnostic.t
      (** Store, IO, or internal failure a client can only report. *)

val unavailable : string -> t
(** [unavailable message] is an {!Unavailable} error whose diagnostic is
    [Mentat_diagnostic.of_text_or ~fallback message]: a total constructor over
    an arbitrary, possibly empty or multi-line [message] such as a formatted
    lower-error rendering or [Printexc.to_string] output. Unlike constructing
    [Unavailable (Mentat_diagnostic.of_text message)] directly, it never raises
    on empty or multi-line input, falling back to a fixed message and carrying
    the original text as context. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same error, composed from the
    payload owners' equalities arm by arm — including {!Mentat_diagnostic.equal}
    for {!Unavailable}. *)

val diagnostic : t -> Mentat_diagnostic.t
(** [diagnostic t] is the renderable diagnostic for [t], for uniform display at
    one host boundary. *)

val jsont : t Jsont.t
(** [jsont] maps errors to versioned JSON objects by a per-arm tag, rejecting
    unknown tags, unknown members, and an unexpected envelope version.

    The {!Unavailable} payload crosses the wire as its structured
    {!Mentat_diagnostic.jsont} object, so the round-trip preserves the message,
    context, and hints, not merely the rendering. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats {!diagnostic} output. *)
