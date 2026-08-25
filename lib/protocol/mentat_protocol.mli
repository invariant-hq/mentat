(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The pure protocol core — one typed vocabulary and the one projector.

    [mentat.protocol] is the versioned value vocabulary every frontend consumes,
    and the only one: {!Position.t} (a session-scoped feed position),
    {!Command.t} (session intents whose completion is a committed fact),
    {!Fact.t} (the presentation-sufficient projection of one durable session
    change, joined with mutation evidence), {!Progress.t} (droppable ephemera),
    and {!Error.t}, each with its jsont codec — plus {!Projection.all} and
    {!Projection.after}, the one fold from durable state to position-tagged
    facts.

    Two laws govern the library:
    - {b The firewall is provable by types.} No exposed type has a
      function-typed field; the package contains no effects and no [eio]. Every
      wire value round-trips through its [jsont], every fact payload is a value
      another library already persists through its own codec, and this library
      composes those codecs and re-encodes nothing. Tool output text, compact
      semantic JSON, and truncation state all cross the same codec.
    - {b Projection is deterministic.} Same durable inputs, same durable fact
      projections: {!Projection.all}/{!Projection.after} are a pure fold over
      the journal. Live emission and replay therefore have identical encoded
      [Committed] values.

    {b Strict decode.} Every decoder rejects unknown tags, unknown members, and
    an unexpected envelope version [v] with a structured error naming what it
    saw — never a silent skip. No vocabulary reserves a constructor: under
    strict decode an unknown tag hard-fails, so a reservation would buy nothing,
    and a new capability ships instead as a new tag gated by a negotiated
    version.

    {b What the library does not own.} Delivery — feeds, submission, typed
    request/completion flows — is [mentat.client]'s, a separate effectful
    library over the engine's feed-serving seam; operations that are not session
    intents (accounts, settings, session lifecycle, manual compaction, review)
    travel those client flows and have no vocabulary here. Offline configuration
    edits ([config set], [unset], [init]) are a sessionless executable surface,
    not a session command or decision, so they have no vocabulary here either.
    Rendering is the frontends'. The headless CLI's dotted tag map
    ([tool.finished], [permission.*], [journal.queue.*]) is a derived rendering
    at the headless envelope over {!Fact.jsont}'s stable per-arm tags, never
    this codec's own. Nothing here reaches an engine, store, or transport. *)

(** {1:positions Positions} *)

module Position = Position
(** Feed positions. Construction exposes the v1 token shape for protocol
    implementations and diagnostics; it does not establish that a token belongs
    to a feed. {!Projection.after} performs that one authoritative membership
    validation and returns a structured {!Position.Invalid.t}. *)

(** {1:vocabulary Commands, facts, progress} *)

module Command = Command
(** Session intents — the six-verb command sum. *)

module Attach = Attach
(** The image-attach request/completion vocabulary. *)

module Fact = Fact
(** Committed facts — the presentation-sufficient projection. *)

module Progress = Progress
(** Ephemeral progress. *)

(** {1:updates Feed updates} *)

module Update = Update
(** Feed updates: committed facts at resume positions or droppable progress. *)

(** {1:commands User commands} *)

module User_command = User_command
(** The completion summary of a user-invoked custom command. *)

(** {1:errors Errors} *)

module Error = Error
(** Protocol errors. *)

(** {1:projection Projection} *)

module Projection = Projection
(** The one engine/replay projector. *)

(** {1:transcript Bounded transcript reads} *)

module Transcript = Transcript
(** The tail view and backward pages — bounded sub-ranges of the one projection
    for a frontend's first paint and scroll-up, provably consistent with the
    replayed feed. *)

module Process = Process
(** A session's live background-process views, for the side pane and the
    between-turns reminder — derived on demand, never persisted. *)
