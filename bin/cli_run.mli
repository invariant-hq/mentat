(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [run] command group: start (default), resume, reply, and review.
    Headless turns use the client without token streaming and print final text
    once at turn end. Reply targets one exact pending decision and continues
    its turn; plan approval continues through the admitted Build turn. Review
    runs a headless review turn over an explicit git diff target ([--base],
    [--uncommitted], or [--commit]) and prints the validated findings JSON; an
    empty target diff exits 0 with a "nothing to review" line, starting no
    run. *)

val cmd : int Cmdliner.Cmd.t
