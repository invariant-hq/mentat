(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Semantic argument validation at the boundary.

    The single vocabulary for turning a raw command-line string into a validated
    value. Each validator is the {e only} way a value of its semantic type
    enters a responder, and it runs as the responder's first act — so a library
    smart constructor that would raise [Invalid_argument] on the raw input
    ([Mentat_session.Id.of_string] on an empty id) is never reached with a
    raising value (the raise is unreachable by construction).

    A validation failure is an {!Exit_status.Usage_error} (exit 2) with a
    structured message — never a library [Invalid_argument] (a 125 crash) nor a
    cmdliner 124. Only {e lexical} parsing (int-vs-string, flag presence) stays
    in cmdliner and fails 124. The same logical input yields the same exit code
    and message everywhere. *)

val session_id : string -> (Mentat_session.Id.t, Exit_status.t) result
(** [session_id raw] validates [raw] as a session id: non-empty, only letters,
    digits, ['.'], ['_'], ['-'], and at most 128 characters. Returns the
    constructed id; {!Mentat_session.Id.of_string} is called only here, on
    validated input. *)

val title : string -> (string, Exit_status.t) result
(** [title raw] validates a session title: non-empty after trimming
    (whitespace-only rejected), no embedded newline. Returns [raw] unchanged so
    stored titles keep their exact bytes. *)

val title_opt : string option -> (string option, Exit_status.t) result
(** [title_opt raw] is {!title} lifted over [option]: [None] passes, [Some raw]
    validates. *)

val limit : int -> (int, Exit_status.t) result
(** [limit n] rejects a negative row limit as usage; [0] means unlimited. *)

val model_selector : string -> (string, Exit_status.t) result
(** [model_selector raw] validates the [provider/model] {e format} only
    (non-empty, one ['/'], both sides non-empty) and returns [raw]. Catalog
    existence is a runtime check the responder makes, carrying flag-provenance.
    The clean format message here sidesteps the doubled "model model selector"
    the config field renderer produces. *)

val workflow_mode :
  string -> (Mentat_session.Contract.Mode.t, Exit_status.t) result
(** [workflow_mode raw] parses the [run]/[tui] [--mode] value as one of [build],
    [plan], or [review] into a {!Mentat_session.Contract.Mode.t}, or a
    {!Exit_status.Usage_error} naming the accepted set. Mode has no config
    field: it is a per-turn value threaded onto the prompt command, so it is
    validated here rather than through the config-field renderer. *)

val review_behavior :
  string -> (Mentat_permission.Review_behavior.t, Exit_status.t) result
(** [review_behavior raw] parses the [run] [--permission] value as [default]
    (enforce reviews) or [bypass] (allow reviews, never deny) into a
    {!Mentat_permission.Review_behavior.t}, or a {!Exit_status.Usage_error}
    naming the accepted set. It is a session-scoped run posture (set through the
    client before the turn), not a config field. *)

val triggered :
  string -> (Mentat_protocol.Command.triggered, Exit_status.t) result
(** [triggered raw] parses the [run start] [--triggered] value as
    [<charter>@<digest>:<key>]: a charter name of letters, digits, ['.'],
    ['_'], or ['-']; the charter policy digest — exactly 16 lowercase
    hexadecimal characters, the length {!Mentat_charter.Charter.policy_digest}
    renders (the two must move together); and a non-empty trigger key. The
    key may itself contain ['@'] or [':'] — the first ['@'] and the first
    [':'] after it delimit the parts. Anything else is a
    {!Exit_status.Usage_error} naming the grammar. *)

val charter_name : string -> (string, Exit_status.t) result
(** [charter_name raw] validates [raw] as an installed charter's name:
    non-empty, only letters, digits, ['.'], ['_'], ['-'], and not opening
    with a dot — so a name is always a plain directory component, never a
    path. Returns [raw]. *)

val config_key : string -> (Mentat_config.Field.any, Exit_status.t) result
(** [config_key raw] parses [raw] as a supported config key, returning the field
    (so the responder does not re-parse), or a {!Exit_status.Usage_error}
    carrying the key's diagnostic and did-you-mean hints (which lifts exit 1 to
    2). *)

val provider :
  known:Mentat_llm.Provider.t list ->
  string ->
  (Mentat_llm.Provider.t, Exit_status.t) result
(** [provider ~known raw] validates [raw] against the [known] provider set (the
    account snapshot carries one per declared provider); an unknown provider is
    a {!Exit_status.Usage_error} naming the set — never an empty table with exit
    1. *)
