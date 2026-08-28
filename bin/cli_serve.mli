(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [serve] activation: one process serving exactly one session —
    its own — over the daemon's wire, on a per-session unix socket derived
    from the session id. Internal: launched by the broker; not for direct
    use. The boot takes no mode flags — it derives its shape from the
    session document's recorded lineage. A delegated child is served from
    its durable edge: the task is re-read from the edge and the child's
    deterministic first turn submitted idempotently. A session with no
    lineage is a root, served plainly: the boot attaches its driver with no
    accompanying command, so mail already durable in the journal starts the
    first turn. Every shape serves feed and commands while the work runs and
    exits cleanly once the session settles idle with an empty queue and no
    unsettled delegations of its own. *)

val cmd : int Cmdliner.Cmd.t
