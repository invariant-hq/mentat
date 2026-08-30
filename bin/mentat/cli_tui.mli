(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Interactive terminal entry points.

    This module is the executable side of the TUI boundary. It resolves launch
    arguments, builds the launch-fixed snapshot and executable-local
    persistence, file-enumeration, browser, and sandboxed-shell closures from
    {!Mentat_boot.Composition.t}, resolves motion policy from the captured
    process environment, obtains the client, and then hands only those values
    to {!Mentat_tui.Runtime}. Before that handoff it reads workspace trust,
    owns the persistence decision and launch gate, and delegates only the
    prompt presentation to {!Cli_trust_prompt}. *)

open Cmdliner

val keybindings_diagnostics : string -> string list
(** [keybindings_diagnostics path] parses the keybindings.json at [path] and
    returns a plain message for each entry the overlay parser rejects; an
    unreadable file or malformed JSON is itself one such message, and the empty
    list means the file parsed with every entry accepted. It shares the
    launch-time overlay parse, so a diagnostic caller outside a TUI session —
    [mentat doctor] — reports the same problems without itself linking a
    rendering library. *)

val default_term : version:string -> int Term.t
(** [default_term ~version] launches the TUI for the bare [mentat] invocation.
    It accepts the common working-directory option plus launch draft, prompt,
    and session-selection options. *)

val resume_cmd : version:string -> int Cmd.t
(** [resume_cmd ~version] is [mentat resume [SESSION]]; [--last] resolves the
    newest resumable session in the selected workspace. Without either target,
    the command opens Home. *)

val review_cmd : version:string -> int Cmd.t
(** [review_cmd ~version] is [mentat review [BASE]]: opens the interactive
    terminal directly on the review screen over the worktree diff against [BASE]
    (default HEAD). *)
