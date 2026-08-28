(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable session document metadata.

    Metadata is saved with a {!Mentat_session.t} document, but it does not
    replay into {!State.t}. It records session-level facts needed to save, load,
    list, and fork sessions without making them model-visible semantic events.

    Updating metadata does not append session events and does not change the
    reconstructed transcript. Hosts are responsible for touching [updated_at]
    when their persistence workflow wants a metadata update to move the saved
    modification time. *)

module Status : sig
  (** Durable session lifecycle status. *)

  type t =
    | Active  (** The session can accept new semantic events. *)
    | Archived
        (** The session is hidden from ordinary active lists and cannot accept
            new semantic events until restored. *)
    | Deleted
        (** The session is tombstoned. Deleted sessions cannot be restored,
            archived, appended to, or forked. *)

  val is_active : t -> bool
  (** [is_active t] is [true] iff [t] is {!Active}. *)

  val is_archived : t -> bool
  (** [is_archived t] is [true] iff [t] is {!Archived}. *)

  val is_deleted : t -> bool
  (** [is_deleted t] is [true] iff [t] is {!Deleted}. *)

  val to_string : t -> string
  (** [to_string t] is the lifecycle label [active], [archived], or [deleted] —
      the one vocabulary every surface renders, so a listing and a lifecycle
      column never disagree. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same status. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a status for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps statuses to JSON values and rejects unknown status tags. *)
end

module Forked_from : sig
  (** Durable fork lineage.

      [copied_events] is the number of parent semantic events copied into the
      child document, excluding any branch reset suffix the child appends. It is
      a prefix length, not a store cursor. *)

  type t = private { parent : Id.t; copied_events : int }

  val make : parent:Id.t -> copied_events:int -> t
  (** [make ~parent ~copied_events] is fork lineage.

      Raises [Invalid_argument] if [copied_events] is negative. *)

  val parent : t -> Id.t
  (** [parent t] is [t]'s parent session id. *)

  val copied_events : t -> int
  (** [copied_events t] is [t]'s copied parent event count. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same lineage. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats fork lineage for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps fork lineage to JSON values. Decoding validates the same
      non-negative [copied_events] invariant as {!make}. *)
end

module Delegated_from : sig
  (** Durable delegation lineage.

      The parent journal owns the immutable {!Delegation.t}; this backlink lets
      an independently attached child locate and verify that edge before it is
      allowed to execute under v1's exact delegated tool catalog. It carries no
      workspace capability or sandbox claim. *)

  type t = private { parent : Id.t; delegation : Delegation.Id.t }

  val make : parent:Id.t -> delegation:Delegation.Id.t -> t
  (** [make ~parent ~delegation] is the parent journal and delegation edge that
      created a child session. *)

  val parent : t -> Id.t
  (** [parent t] is the session whose journal owns [delegation t]. *)

  val delegation : t -> Delegation.Id.t
  (** [delegation t] is the immutable edge that created the child. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] name the same parent and edge. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats delegation lineage for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps delegation lineage to JSON values. *)
end

module Triggered_from : sig
  (** Durable trigger provenance.

      A session created by a trigger host on a standing grant records the
      trigger's identity here: [source] names the trigger as the scheduling
      host defines it, [digest] seals the policy content it fired under, and
      [key] names the event it fired on — the same three members an
      {!Origin.Trigger} queue entry carries, which is what lets mail
      admission ({!Mentat_session.admits_mail}) prove "this session's own
      trigger" from the session's recorded facts alone. Provenance is
      attribution, never authority. *)

  type t = private { source : string; digest : string; key : string }

  val make : source:string -> digest:string -> key:string -> t
  (** [make ~source ~digest ~key] is trigger provenance with every member
      checked non-empty.

      Raises [Invalid_argument] if any member is empty. *)

  val source : t -> string
  (** [source t] is the trigger's name. *)

  val digest : t -> string
  (** [digest t] is the policy digest the trigger fired under. *)

  val key : t -> string
  (** [key t] is the event the trigger fired on. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same provenance. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats provenance for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps provenance to JSON values. Decoding validates the same
      non-empty invariants as {!make}. *)
end

module Run_policy : sig
  (** The recorded run contract a session was created under.

      A session created for a standing, unattended run records the run knobs
      its creator granted, so every process that later serves it — the first
      activation and any successor — applies the same contract without
      re-consulting the grant that has since moved on. Two consumers split
      the members: queue admission reads [mode] and [output_schema] to seal
      each admitted turn (never the plain Build defaults), and the serving
      boot lowers the rest onto its configuration overlay before the engine
      is built. The lowered members hold the run surface's own textual
      spellings — [sandbox] a sandbox-mode token, [model] a provider/model
      selector, [reasoning] a reasoning effort, [unattended] an unattended
      permission policy — validated by the configuration layer that applies
      them, so an unknown spelling refuses the boot loudly rather than
      running under defaults the grant never named. *)

  type t = private {
    mode : Contract.Mode.t option;
        (** The product mode admitted turns seal; absent means Build. *)
    output_schema : Jsont.json option;
        (** The structured-output schema admitted turns run under. *)
    max_steps : int option;  (** The per-turn step bound; positive. *)
    sandbox : string option;  (** The sandbox-mode spelling to apply. *)
    require_sandbox : bool;
        (** Whether the run must refuse to start without an enforceable or
            external sandbox. *)
    model : string option;  (** A provider/model selector override. *)
    reasoning : string option;  (** A reasoning-effort spelling. *)
    unattended : string option;
        (** An unattended permission-policy spelling. *)
    project_instructions : bool option;
        (** Force project instruction files on or off; absent uses the
            default. *)
  }

  val make :
    ?mode:Contract.Mode.t ->
    ?output_schema:Jsont.json ->
    ?max_steps:int ->
    ?sandbox:string ->
    ?require_sandbox:bool ->
    ?model:string ->
    ?reasoning:string ->
    ?unattended:string ->
    ?project_instructions:bool ->
    unit ->
    t
  (** [make ()] is a recorded run policy; every member is optional and
      [require_sandbox] defaults to [false].

      Raises [Invalid_argument] if [max_steps] is not positive or a textual
      member is empty. *)

  val mode : t -> Contract.Mode.t option
  (** [mode t] is the recorded product mode. *)

  val output_schema : t -> Jsont.json option
  (** [output_schema t] is the recorded structured-output schema. *)

  val max_steps : t -> int option
  (** [max_steps t] is the recorded per-turn step bound. *)

  val sandbox : t -> string option
  (** [sandbox t] is the recorded sandbox-mode spelling. *)

  val require_sandbox : t -> bool
  (** [require_sandbox t] is whether the run requires an enforceable or
      external sandbox. *)

  val model : t -> string option
  (** [model t] is the recorded model selector. *)

  val reasoning : t -> string option
  (** [reasoning t] is the recorded reasoning-effort spelling. *)

  val unattended : t -> string option
  (** [unattended t] is the recorded unattended permission-policy spelling. *)

  val project_instructions : t -> bool option
  (** [project_instructions t] is the recorded project-instructions toggle. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] record the same policy. Schemas
      compare over their JSON values, so a decoded policy equals an
      otherwise-identical constructed one. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a policy for diagnostics. The schema is elided. *)

  val jsont : t Jsont.t
  (** [jsont] maps policies to JSON values. Decoding validates the same
      invariants as {!make}. *)
end

type t = private {
  title : string option;  (** Optional non-empty user-facing title. *)
  status : Status.t;  (** Saved lifecycle status. *)
  forked_from : Forked_from.t option;
      (** Fork lineage, if this document was created from another session. *)
  delegated_from : Delegated_from.t option;
      (** Delegation lineage, if this document is a subagent session. *)
  triggered_from : Triggered_from.t option;
      (** Trigger provenance, if a trigger host created this session. *)
  run_policy : Run_policy.t option;
      (** The recorded run contract, if the session was created under one. *)
  root : Mentat_workspace.Root.t;
      (** The workspace the session was created under. {!Mentat_workspace.Root}
          is the one owner of a session's workspace identity; the absolute
          directory survives only as {!Mentat_workspace.Root.dir}, a display and
          search projection, never an identity comparison.

          v1 mints the root with {!Mentat_workspace.Root.of_dir}, an injective
          encoding of the creation directory, and persists that directory as the
          on-disk ["cwd"] member. A future host daemon swaps the minting for
          host-owned keys plus a relocation registry without touching this field
          or its consumers. *)
  created_at : Time.t;  (** Saved creation time. *)
  updated_at : Time.t;  (** Saved last update time. *)
}
(** The type for durable session metadata.

    [updated_at] is always greater than or equal to [created_at]. Fork,
    delegation, and trigger lineage are mutually exclusive: a session has at
    most one creation origin. *)

val make :
  ?title:string ->
  ?status:Status.t ->
  ?forked_from:Forked_from.t ->
  ?delegated_from:Delegated_from.t ->
  ?triggered_from:Triggered_from.t ->
  ?run_policy:Run_policy.t ->
  cwd:Lpath.Abs.t ->
  created_at:Time.t ->
  updated_at:Time.t ->
  unit ->
  t
(** [make ?title ?status ?forked_from ?delegated_from ?triggered_from
     ?run_policy ~cwd ~created_at ~updated_at ()] is metadata whose workspace
    identity is {!Mentat_workspace.Root.of_dir} [cwd] — the v1 injective
    minting of a directory into a durable root.

    [status] defaults to {!Status.Active}. [title], when present, must be a
    non-empty display title; no trimming or normalization is performed.

    Raises [Invalid_argument] if [title] is empty, [updated_at] is before
    [created_at], or more than one of [forked_from], [delegated_from], and
    [triggered_from] is supplied. *)

val title : t -> string option
(** [title t] is [t]'s optional user-facing title. *)

val status : t -> Status.t
(** [status t] is [t]'s saved lifecycle status. *)

val fork : t -> Forked_from.t option
(** [fork t] is [t]'s fork lineage, if it was forked from another session.
    Lineage is fixed at construction ([make ?forked_from]) and never updated. *)

val delegated_from : t -> Delegated_from.t option
(** [delegated_from t] is [t]'s delegation lineage, if it is a subagent session.
    Lineage is fixed at construction ([make ?delegated_from]) and never updated.
*)

val triggered_from : t -> Triggered_from.t option
(** [triggered_from t] is [t]'s trigger provenance, if a trigger host created
    it. Fixed at construction and never updated. *)

val run_policy : t -> Run_policy.t option
(** [run_policy t] is [t]'s recorded run contract, if it was created under
    one. Fixed at construction and never updated. *)

val root : t -> Mentat_workspace.Root.t
(** [root t] is the workspace [t] was created under — the owner of [t]'s
    workspace identity. Scope and membership decisions compare
    {!Mentat_workspace.Root.key}, never the directory. *)

val cwd : t -> Lpath.Abs.t
(** [cwd t] is the absolute directory [t] was created under, i.e.
    {!Mentat_workspace.Root.dir} [(root t)]. A display and search projection of
    {!root}, not an identity — do not compare it to decide workspace membership.
*)

val created_at : t -> Time.t
(** [created_at t] is [t]'s saved creation time. *)

val updated_at : t -> Time.t
(** [updated_at t] is [t]'s saved last update time. *)

val with_title : string option -> t -> t
(** [with_title title t] is [t] with title [title].

    Raises [Invalid_argument] if [title] is [Some ""]. *)

val with_status : Status.t -> t -> t
(** [with_status status t] is [t] with status [status]. *)

val touch : Time.t -> t -> t
(** [touch time t] is [t] with [updated_at] set to [time].

    Raises [Invalid_argument] if [time] is before [created_at t]. *)

val is_active : t -> bool
(** [is_active t] is [true] iff [status t] is {!Status.Active}. *)

val is_archived : t -> bool
(** [is_archived t] is [true] iff [status t] is {!Status.Archived}. *)

val is_deleted : t -> bool
(** [is_deleted t] is [true] iff [status t] is {!Status.Deleted}. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same metadata. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats metadata for diagnostics. The output is not stable storage
    syntax. *)

val absolute_path_jsont : Lpath.Abs.t Jsont.t
(** [absolute_path_jsont] maps an absolute path to and from its POSIX-string
    wire form — the shape metadata persists [cwd] as, shared with the session
    summary projection. Decoding rejects a malformed path. *)

val jsont : t Jsont.t
(** [jsont] maps metadata to JSON values. Decoding validates title and timestamp
    ordering invariants. *)
