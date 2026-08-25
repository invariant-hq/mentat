(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Diagnostics logging and crash reports, configured from the environment.

    Libraries only declare {!Logs} sources and log; level, reporter policy, and
    session attribution live here.

    {1 Level and destination}

    [MENTAT_LOG] selects the level ([quiet], [error], [warning], [info], or
    [debug]) and [MENTAT_LOG_FILE] the destination (an absolute path, appended).
    Both are read once at process start. Diagnostics never reach stdout, which
    carries results.

    Headless commands are opt-in: nothing is logged unless [MENTAT_LOG] is set,
    and the default sink is stderr. The interactive terminal instead always logs
    at [info] (or the [MENTAT_LOG] override; [quiet] disables it) to a per-run
    file under the state home, since stderr would corrupt the screen. [info] is
    the floor at which a run log is self-describing: the session-boundary line
    below is emitted there, so a lower default would record faults with no way
    to attribute them.

    Every record is one physical line, since each reader — [grep], the session
    correlation in [debug session] — is line-oriented. The reporter's formatter
    is given no margin and opens no box: {!Format} breaks a line both at a
    margin and at a box opened past [max_indent], and the shared-sink prefix
    alone exceeds the default of either.

    {1 What a log may contain}

    A log records what the process did, never what the user asked or what a
    provider answered. Positional arguments carry prompt text, so {!started}
    records only the resolved subcommand token, and no Mentat source logs a
    message body, a tool argument, or a credential.

    [MENTAT_LOG] therefore governs Mentat's own sources alone. Linked libraries
    declare their own and are held at [warning] whatever the setting: cohttp
    writes whole HTTP requests and responses at [debug] — bodies and the
    [Authorization] header included — so honouring [MENTAT_LOG] for it would
    write the conversation and the user's API key into exactly the file people
    are asked to attach to a bug report. At [warning] a transport or TLS fault
    still surfaces and no payload does. The ceiling is applied as the global
    level, so a source that registers later is quiet rather than loud.

    {1 Session attribution}

    A mutable breadcrumb names the frontend's active session so lines and crash
    reports are attributable. It reflects {e the frontend's} active session
    only: were engine or child-session logging ever added, those lines must
    carry their own session identity rather than rely on this breadcrumb, which
    the frontend alone owns.

    Both frontends keep it current. Headless runs set it around the turn they
    drive; the interactive terminal sets it once before launch for a resumed
    target and thereafter through {!Mentat_tui.Runtime.Local.attribute_session},
    which reports every attachment the runtime establishes — including a session
    opened fresh inside the terminal, which never crosses the launch boundary.

    Per-run files (the TUI divert) are identified by their filename, so their
    lines carry only a short [[s=<first-8-of-id>]] tag while the breadcrumb is
    set. Shared sinks (stderr, an explicit [MENTAT_LOG_FILE]) interleave across
    processes, so their lines additionally carry [[run=<run-id>]]. *)

type event =
  | Opened
  | Resumed
  | Switched
  | Detached
      (** How the active session changed, for the info-level boundary line. *)

val install :
  getenv:(string -> string option) ->
  verbosity:int ->
  (unit, Exit_status.t) result
(** [install ~getenv ~verbosity] sets the global {!Logs} level and installs the
    shared-sink reporter over [MENTAT_LOG_FILE] or, when it is unset, stderr.
    Called by {!Main} before [Cmd.eval'].

    [verbosity] is the count of [-v]/[--verbose] occurrences {!Main} took from
    argv: [0] leaves [MENTAT_LOG] in charge, [1] is [info], and more is [debug].
    A flag beats the environment, since someone typing it is asking about the
    run in front of them rather than about their shell profile. Either way the
    choice is remembered, so {!divert_for_tui} does not override it.

    An invalid [MENTAT_LOG] value, a relative [MENTAT_LOG_FILE], and a log file
    that cannot be opened are all {!Exit_status.Runtime_error} (exit 1): the
    values arrive from the environment, and only flag-carried input classifies
    as a usage error (exit 2). None of them ever reaches a [125] backtrace. *)

val started : version:string -> argv:string array -> unit
(** [started ~version ~argv] records one process-start line at info level naming
    the resolved subcommand token from [argv]. Only that token is logged, never
    a positional argument, which can carry prompt text. *)

val set_session : ?event:event -> string option -> unit
(** [set_session ?event id] updates the active-session breadcrumb. When the
    value changes it emits one info-level boundary line naming the full id —
    [session <id> opened|resumed|switched|detached] — so a reader at info level
    can map a short tag back to the full id even though per-line tags are
    truncated. [event] labels the transition; omitted, it is inferred from the
    previous breadcrumb ([None]→[Some] opened, [Some]→[Some] switched,
    [Some]→[None] detached). *)

val divert_for_tui : getenv:(string -> string option) -> unit
(** [divert_for_tui ~getenv] prepares logging for the interactive terminal
    before it takes over the screen. When [MENTAT_LOG] is unset it raises the
    level to [info] (the TUI default); an explicit [MENTAT_LOG] level, including
    [quiet], wins. With no explicit [MENTAT_LOG_FILE] and a non-quiet level it
    redirects logging to [<state_home>/logs/<run>.log], writes a [latest.json]
    pointer atomically, and keeps the newest twenty run logs; an explicit
    [MENTAT_LOG_FILE] is respected in place. If the divert file cannot be
    created, logging is silenced so no byte reaches the terminal. Best-effort:
    it never fails the launch — a broken state home surfaces through base
    staging instead. *)

val retain_logs : keep:int -> dir:string -> current:string -> unit
(** [retain_logs ~keep ~dir ~current] deletes all but the newest [keep] [.log]
    files in [dir], counting [current] among them and never removing it. The
    retention the run logs and crash reports apply to themselves, exposed so the
    daemon can bound its own log the same way. Best-effort: an unreadable
    directory or an undeletable file leaves the trail intact rather than failing
    a caller who was only tidying. *)

val write_crash_report :
  version:string ->
  backtrace:string ->
  getenv:(string -> string option) ->
  string option
(** [write_crash_report ~version ~backtrace ~getenv] writes [backtrace] to
    [<state_home>/crashes/<run>.log] — the same run stamp as the log file, so a
    crash correlates with its run by name.

    The report is meant to travel alone, since the log it correlates with may
    have rotated away or never have been kept: above the backtrace sit
    [mentat_version], [run_id], [pid], [session] (the breadcrumb, or [-]),
    [command] (the subcommand token {!started} resolved — never a positional,
    which can carry prompt text), [term], [ocaml], and [log] (this run's sink,
    or [-]), then this run's last records copied from that sink. A shared sink
    interleaves processes, so only lines carrying this run's [run=] tag are
    copied.

    The file is [0600] and the newest twenty crash reports are kept. Returns the
    path written, or [None] if the state home cannot be resolved or the file
    cannot be written. *)

val write_boot_failure_report :
  message:string ->
  diagnostic:string option ->
  getenv:(string -> string option) ->
  string option
(** [write_boot_failure_report ~message ~diagnostic ~getenv] writes a
    {!write_crash_report} for a crash-grade boot-staging failure: [message] is
    the staging error's one-liner, [diagnostic] the captured raise context when
    one exists (for the store, {!Mentat_store.last_exn_diagnostic}). The version
    is the one retained by {!started}. Returns the report path, or [None] when
    the report cannot be written. *)
