(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The build-watch supervisor's pure law.

    A supervisor publishes one {!word} — what its machine currently claims —
    and the status a frontend renders is {!compose} of that word with the
    shared observer's view. The death budget that bounds a crash loop is
    {!after_death}. Both are total functions so the supervisor's effectful
    shell owns nothing but spawning, sleeping, and IO — the rules themselves
    are table-testable without a process. *)

type word =
  | Defer
      (** The observer speaks: nothing is spawned and nothing is claimed —
          observe mode, and the idle machine before its first probe. *)
  | Announce of Mentat_workspace.Health.t
      (** The machine's own claim, already in wire form: probing, a spawned
          child not yet attached ([Starting]), a restart with its cause, no
          dune on the PATH, or given up. *)

val compose :
  word -> observed:Mentat_workspace.Health.t -> Mentat_workspace.Health.t
(** [compose word ~observed] is the status a frontend renders. An attached
    connection is ground truth wherever the machine believes itself to be, so
    an observed {!Mentat_workspace.Health.Live} always wins — the observer
    carries the owner, ours for a pinned supervised watch and foreign
    otherwise. Everything else is the word: the observer's view under
    [Defer], the machine's claim under [Announce]. *)

val after_death : reached:bool -> deaths:int -> [ `Give_up | `Retry of int ]
(** [after_death ~reached ~deaths] applies the give-up rule to one ended
    life. [deaths] counts the consecutive lives that died before reaching
    [Live]; a life that reached [Live] ([reached]) resets the count, so its
    death always retries and buys the respawn two fresh strikes. Two
    consecutive lives dying before [Live] give up; otherwise the result
    carries the count the next death is judged against. *)
