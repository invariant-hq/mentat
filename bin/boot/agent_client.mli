(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The client a frontend drives sessions with: spawn and dial.

    Every session is driven by its own agent — a [mentat serve] process on
    the session's derived socket. The client assembled here answers the
    engine-free cones in this process ({!Composition.daemon_cones}: accounts,
    the sessionless settings, lifecycle, review, workspace) and routes every
    session-scoped call — the whole session cone, plus [set_model] and
    [set_permission_review] — over the wire to the target session's agent,
    attach-or-start: an agent already serving the session is dialed; none is
    started through {!Composition.broker} ({!Mentat_broker.serve}) and then
    dialed. The result is wrapped by {!Composition.attach_client}, so command
    expansion and image attach stay local.

    The caller's connections are the lease: a held feed keeps the agent
    alive, and an agent nobody dials idles out on its own linger. No engine
    is ever assembled in this process. *)

val serving : Composition.t -> Mentat_session.Id.t -> bool
(** [serving t session] is whether [session]'s derived endpoint accepts a
    connection right now — a raw probe, no handshake, nothing started. The
    seam for a caller that must refuse a spawn-scoped option when the agent
    already runs (its boot environment is fixed). *)

val client :
  ?environment_overrides:(string * string) list ->
  Composition.t ->
  (Mentat_client.t, Exit_status.t) result
(** [client ?environment_overrides t] is the frontend client described above.
    [environment_overrides] extends [t]'s process-environment snapshot for
    the agents this client starts — same-named variables replaced — the seam
    a run's boot-config flags ride into a spawned agent ([MENTAT_MODEL],
    [MENTAT_SANDBOX_MODE], …); an agent already serving keeps the
    environment its own spawner rendered. [Error] exactly as
    {!Composition.daemon_cones}'s prefix (an unsealable workspace). *)

val client_with_tui_capabilities :
  Composition.t ->
  ( Mentat_client.t * Mentat_workspace_io.t * Mentat_tool.t,
    Exit_status.t )
  result
(** [client_with_tui_capabilities t] is {!client} paired with
    {!Composition.tui_capabilities} — the read-only workspace capability for
    file completion and the local-user shell definition, both local; the
    engines are the sessions' own agents. *)
