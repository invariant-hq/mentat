(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The typed routine document.

    A routine is an owner-written JSON file granting a standing, unattended
    run: what triggers it, what the run may do, what it may spend, where the
    outcome is published, and who is told when it needs a human.
    {!decode} is the strict reader for a version-1 document and
    {!policy_digest} derives the identity of the policy the file states.
    The module is pure — no I/O; the caller reads the bytes.

    {b The version-1 grant envelope is closed at decode.} A version-1
    routine can never consent or write: the run is always mode [review] in
    a read-only, enforced sandbox; an unattended permission ask may only be
    denied or may park the run; there is no goal, no write grant, and no
    tool axis — those members do not exist, and an unknown member anywhere
    in the document is a load error naming it. Widening any of this is a
    routine version bump, never a lenient read. *)

(** The unattended permission policy — the one grant knob a routine has. *)
module Unattended : sig
  type t =
    | Deny  (** Record a model-visible denial and continue. *)
    | Block  (** Park the run on the ask, holding it for a human. *)

  val to_string : t -> string
  (** [to_string t] is ["deny"] or ["block"] — the run surface's
      [--permission-unattended] values. *)
end

(** Webhook gate configuration — which deliveries are worth a run. *)
module Gate : sig
  type t = {
    base : string list option;
        (** Admitted base branches; [None] admits any base. *)
    drafts : bool;  (** Whether draft pull requests are admitted. *)
    associations : string list option;
        (** Admitted author associations, drawn from GitHub's vocabulary
            (["OWNER"], ["MEMBER"], ["COLLABORATOR"], ["CONTRIBUTOR"],
            ["FIRST_TIME_CONTRIBUTOR"], ["FIRST_TIMER"], ["MANNEQUIN"],
            ["NONE"]); [None] admits any author. *)
  }
  (** The type for gate configurations. An omitted [gate] member decodes to
      the permissive gate: any base, any author, drafts refused — a draft
      is not asking for review. *)
end

(** Trigger arms — the ways a routine fires. *)
module Trigger : sig
  (** The webhook arm's configuration. *)
  module Webhook : sig
    type t = {
      events : string list;
          (** The admitted deliveries, each named
              [pull_request.<action>] where [<action>] is one of GitHub's
              documented pull_request webhook actions; non-empty, no
              duplicates. The action vocabulary is closed at decode, so a
              typo is a load error, never a routine that silently never
              fires. *)
      gate : Gate.t;  (** Which admitted deliveries are worth a run. *)
    }
    (** The type for webhook trigger arms. *)
  end

  type t =
    | Github_webhook of Webhook.t
        (** Fire on a GitHub [pull_request] delivery. *)
    | Cli  (** Fire when the owner invokes the routine by hand. *)
end

(** The run contract — every field maps onto one audited run-surface
    flag, so a routine can grant nothing an owner could not grant at a
    keyboard. *)
module Run : sig
  type t = {
    model : string option;  (** Model override; [None] uses the default. *)
    reasoning : string option;
        (** Reasoning effort, one of ["none"], ["minimal"], ["low"],
            ["medium"], ["high"], ["xhigh"], or ["max"]; [None] uses the
            default. *)
    max_steps : int;  (** The step bound; at least 1. Defaults to 60. *)
    prompt : string;
        (** The prompt file, as a relative path inside the routine
            directory. *)
    output_schema : string;
        (** The output-schema file, as a relative path inside the routine
            directory. *)
    project_instructions : bool option;
        (** Force project instruction files on ([Some true]) or off
            ([Some false]); [None] uses the default. *)
  }
  (** The type for run contracts. The mode is not a field: a version-1
      routine always runs mode [review], in a read-only sandbox the run
      must refuse to start without, and pins no skills. *)
end

(** Budgets — the run's leash and the routine's meters. *)
module Budget : sig
  type t = {
    wall_clock : float;
        (** The per-run wall-clock bound in seconds; positive. Written as
            a duration token — digits then a unit, [s], [m], or [h], as in
            ["15m"]. *)
    usd_per_day : float option;
        (** Derived spend admitted over the trailing 24 hours; [None]
            leaves spend unmetered. *)
    runs_per_hour : int option;
        (** Spawns admitted over the trailing hour; [None] falls back to
            the delivery kind's default, applied inside admission
            ({!Fence.admit}): 6 for a webhook-shaped delivery — replayed
            and swept deliveries included, since their rate is set by
            whoever opens pull requests — and none for a bare cli fire,
            whose rate is the owner's own scheduler. *)
  }
  (** The type for budgets. *)
end

(** The notification contract. *)
module Notify : sig
  type t = {
    on : Receipt.Transition.t list;
        (** The alert transitions that fire the hook; non-empty, no
            duplicates. The vocabulary is exactly the receipt log's alert
            transitions — a routine cannot name a moment the record cannot
            carry. *)
    command : string list;
        (** The hook argv; non-empty, its first element non-empty. *)
  }
  (** The type for notification contracts. *)
end

type t = {
  name : string;
      (** The routine's name: non-empty, drawn from letters, digits,
          ['.'], ['_'], and ['-'] — a plain token, never a path. It
          persists as the [source] member of the trigger-origin mail a
          fire delivers ({!Mentat_session.Origin.Trigger}) and in
          receipts on disk. *)
  enabled : bool;  (** Whether the routine admits events; defaults true. *)
  repo : string;  (** The [owner/name] repository the routine watches. *)
  triggers : Trigger.t list;
      (** The [trigger] member's arms: non-empty, at most one arm of each
          kind. *)
  permission_unattended : Unattended.t option;
      (** The unattended permission policy; [None] uses the run surface's
          default. *)
  run : Run.t;  (** The run contract. *)
  budget : Budget.t;  (** The budgets. *)
  notify : Notify.t option;  (** The notification contract, if any. *)
  suppress_clean_run : bool;
      (** [true] when the document sets [suppress.clean_run] to
          ["silent"]: a run that finds nothing publishes no fresh comment
          (an existing summary still converges). *)
}
(** The type for routines. *)

val webhook_arm : t -> Trigger.Webhook.t option
(** [webhook_arm t] is [t]'s webhook trigger arm, when one exists — the
    arm webhook deliveries, replays, and sweeps run under. At most one
    exists: {!decode} refuses duplicate trigger kinds. *)

val delivery_trigger : t -> [ `Cli | `Webhook ]
(** [delivery_trigger t] is admission's judgment of the delivery kind
    [t]'s events carry: [`Webhook] when a webhook arm exists — a
    webhook-armed routine's deliveries are webhook-shaped whatever
    transport replays them, and their rate is set by whoever opens pull
    requests — and [`Cli] otherwise. Status surfaces derive their rate
    limit through this same judgment ({!Fence.effective_runs_per_hour}),
    so what is displayed is what admission applies. *)

(** Decode errors. *)
module Error : sig
  type t
  (** The type for strict-decode errors: which member of the document is
      unacceptable, and why. *)

  val message : t -> string
  (** [message e] is [e]'s one-line diagnostic, naming the offending
      member by path. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}. *)
end

val decode : string -> (t, Error.t) result
(** [decode bytes] is the routine [bytes] denotes. The read is strict and
    the envelope closed: malformed JSON, a version other than 1, an
    unknown or duplicate member at any level, a missing required member, a
    wrongly-typed member, a name outside the token grammar, an empty or
    duplicate-bearing list, a [sandbox] other than ["read-only"], a
    [permission_unattended] other than ["deny"] or ["block"], a mode other
    than ["review"], a non-empty [skills] list, a [suppress.clean_run]
    other than ["silent"], a prompt or schema path that is absolute,
    traverses [..], names [routine.json] or [ingress.id], or lives under
    [secrets/], an event naming a pull_request action outside GitHub's
    documented vocabulary, or a trigger kind this build does not run is an
    [Error] naming the offending member.

    The trigger kinds [schedule], [agent_message], and [self_schedule] are
    recognized vocabulary: each parses but is refused as unimplemented,
    distinctly from an unknown kind, so a document from a future build
    fails with its real diagnosis. [retention.keep_failed_worktrees] is
    refused the same way — no reaper exists to honor it, and an accepted
    no-op grant would be worse than the refusal. *)

val policy_digest :
  routine_json:string -> prompt:string -> output_schema:string -> string
(** [policy_digest ~routine_json ~prompt ~output_schema] is the identity
    of the policy those bytes state: the first 16 lowercase hexadecimal
    characters of the SHA-256 of the [mentat.routine.policy.v1] domain and
    the three files' bytes, in that order, each length-framed. The framing
    is injective over arbitrary bytes, so no edit to one file can alias
    another. The digest covers exactly the three policy files — never
    secrets, never the ingress id — so editing any of the three re-stamps
    receipts and resets fence windows, and rotating a secret moves
    nothing. The 16-character spelling is a wire format: digests persist
    in receipts and as the [digest] member of the trigger-origin mail a
    fire delivers ({!Mentat_session.Origin.Trigger}). *)
