(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [doctor] diagnostic command. Exits 1 only on a failing check. *)

val cmd : int Cmdliner.Cmd.t

val probe_checks_json : Mentat_boot.Composition.Probe.t -> Jsont.json
(** [probe_checks_json probe] is the check array [doctor --json] prints.
    {!Cli_report} bundles it, so a report carries the same readiness picture the
    user would have seen had they run [doctor] themselves. *)
