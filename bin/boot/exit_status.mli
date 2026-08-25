(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The single exit-code contract.

    Every command term evaluates to a {!t}; {!term} turns it into the process
    exit code cmdliner returns from [Cmd.eval']. The codes: [Success] → 0,
    [Failed] → 1 (message already emitted), [Runtime_error] → 1, [Usage_error] →
    2, [Blocked] → 3, [Interrupted] → 130 (a user SIGINT — distinct from
    [Blocked] because the cause differs: 3 is the agent waiting for you, 130 is
    you stopping it), [Internal] → 125. Cmdliner adds 124 (lexical parse
    failure). A structured error is rendered once, here, as [mentat: <message>]
    on stderr, so no command prints its own error line, and no user- or
    environment-supplied input ever reaches 125 with a backtrace on stderr (the
    backtrace goes to a crash file; the user sees
    [mentat: internal error: <message>]). *)

type t =
  | Success  (** Exit 0. *)
  | Failed
      (** Exit 1; the failure was already emitted upstream (e.g. in a JSONL
          stream). *)
  | Runtime_error of string  (** Exit 1; [mentat: <message>] on stderr. *)
  | Usage_error of string  (** Exit 2; [mentat: <message>] on stderr. *)
  | Blocked of string  (** Exit 3; the session is parked on a user decision. *)
  | Interrupted  (** Exit 130; a user-initiated SIGINT stopped the turn. *)
  | Internal of string
      (** Exit 125; an internal invariant violation.
          [mentat: internal error: <message>] on stderr — never a backtrace
          (that goes to a crash file, written by {!Main}). *)

val code : t -> int
(** [code t] is [t]'s process exit code, without emitting anything. *)

val emit : t -> unit
(** [emit t] writes [t]'s [mentat: <message>] line to stderr, if any. *)

val to_process_code : t -> int
(** [to_process_code t] is {!emit} then {!code} — what a command term reduces
    to. *)

val term : t Cmdliner.Term.t -> int Cmdliner.Term.t
(** [term u] adapts a command term to the process exit code. *)

val exits : Cmdliner.Cmd.Exit.info list
(** The exit-code documentation declared on every command. *)

(** {1:mapping Structured error mapping} *)

val of_diagnostic : Mentat_diagnostic.t -> t
(** [of_diagnostic d] is a {!Runtime_error} rendering [d] (message plus its
    hints). *)

val runtime : string -> t
(** [runtime message] is a plain {!Runtime_error}. *)

val usage : string -> t
(** [usage message] is a {!Usage_error}. *)

val of_result : (t, t) result -> t
(** [of_result r] merges the responder monad's two arms — an [Ok] status (the
    command ran) or an [Error] status (a boundary validator rejected input
    before any library smart constructor) — both already {!t}. This is the
    [|> Exit_status.of_result] tail of the responder skeleton. *)

val of_exn : exn -> t
(** [of_exn exn] classifies an exception escaping to the top-level guard:
    [Unix_error]/[Sys_error]/[Eio.Io] are an environment/IO condition and map to
    {!Runtime_error} (exit 1, never 125); anything else is an internal invariant
    and maps to {!Internal} (exit 125). No raw exception repr the exe mints
    reaches the user through the first three. *)

val of_protocol_error :
  ?daemon_live:(unit -> bool) -> Mentat_protocol.Error.t -> t
(** [of_protocol_error e] maps a client operation error onto the contract:
    caller/protocol misuse ([Invalid_position], [Turn_id_reused],
    [No_active_turn], [Active_turn_exists], [Decision_not_pending],
    [Already_resolved]) is a {!Usage_error}; everything else ([Busy],
    [Session_not_found], [Archived], [Deleted], [Unavailable]) is a
    {!Runtime_error}. Rendering is always [Error.diagnostic].

    [daemon_live] (default: always [false]) is consulted only for a [Busy]: when
    it returns [true] — a per-user daemon is running and holds the fence — the
    message gains a "re-run with --attach" hint (4e). It is a thunk so the
    liveness probe (a discovery-file + claim check) runs only on the [Busy]
    path, never on the common case; with no daemon the message is
    byte-identical, so offline goldens do not move. *)
