(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The cooperative stop seam the serve loops share.

    One flag, three obligations: a first SIGTERM/SIGINT requests a graceful
    stop the serve body polls for; a second signal — arriving while a wedged
    teardown holds the first request — forces an immediate [exit 130], so a
    repeat signal is never swallowed and the OS then releases every fence the
    process held; and the previous handlers are restored when the guarded body
    returns. A watchdog requests the same stop through {!request}. *)

type t
(** The type for one serve loop's stop flag. *)

val create : unit -> t
(** [create ()] is a fresh flag with no stop requested. *)

val requested : t -> bool
(** [requested t] is whether a stop has been requested. *)

val request : t -> unit
(** [request t] requests a cooperative stop — the idle watchdogs' verb. The
    installed signal handler escalates instead of calling this. *)

val with_signals : t -> (unit -> 'a) -> 'a
(** [with_signals t f] runs [f] with SIGTERM and SIGINT installed onto [t]:
    the first signal requests the stop, and a second — while the request
    stands — forces [Stdlib.exit 130]. The previous handlers are restored when
    [f] returns or raises. *)

val wait : clock:_ Eio.Time.clock -> t -> unit
(** [wait ~clock t] polls [t] on a short cadence until a stop is requested —
    the Eio-safe signal path: the handler only flips an atomic, and this fiber
    observes it. Race it against the serve branches so a signal ends the
    serve. *)
