(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session auto-titling: name a fresh session from its first prompt. *)

val run :
  Mentat_boot.Composition.t ->
  client:Mentat_client.t ->
  session:Mentat_session.Id.t ->
  prompt:string ->
  unit
(** [run t ~client ~session ~prompt] gives [session] a short human-readable
    title derived from its first user [prompt], generated on the resolved
    {!Mentat_boot.Composition.small_model} and persisted with
    {!Mentat_client.rename}.

    It is a best-effort side-call the executable makes exactly once for a fresh,
    still-untitled session, before the first prompt is submitted (submission
    attaches the turn's driver, which holds the session guard the rename needs).
    Since it therefore gates the first turn, generation is time-bounded: a call
    slower than a few seconds is abandoned with no title. It is likewise a no-op
    when [MENTAT_AUTO_TITLE] is set to a falsey value ([0], [false], [no],
    [off]), when no small model resolves, when the provider call fails, or when
    the model returns nothing usable — the session simply keeps its untitled
    fallback. Every failure is swallowed rather than surfaced, beyond an info
    log. *)
