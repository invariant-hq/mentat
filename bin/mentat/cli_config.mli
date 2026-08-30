(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [config] command group: path, show, get, set, unset, init, validate. *)

val cmd : int Cmdliner.Cmd.t

val print_warnings :
  ?about:Mentat_config.Field.any -> Mentat_boot.Composition.t -> unit
(** [print_warnings t] writes [t]'s configuration resolution warnings to stderr,
    one [mentat: warning:] line each: config input that did not take effect,
    such as a workspace key outside the shared allowlist or a config file
    dropped by trust. Human-path only; [config show], [config get], and
    {!Cli_run}'s run-start notices call it so an inert key is never silent.

    [about] restricts the report to warnings that bear on one key — its own,
    plus the file-level warnings that bear on every key. *)

val resolved_json : Mentat_boot.Composition.t -> Jsont.json
(** [resolved_json t] is the effective configuration with each value's
    provenance, as [config show --json --origins] renders it. Credentials are
    withheld because the library's view projects them that way — an API key
    reads [[REDACTED]], a base URL keeps its endpoint and loses its userinfo —
    so {!Cli_report} can bundle this without a redaction pass of its own. *)
