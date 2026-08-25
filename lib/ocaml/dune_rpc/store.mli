(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The pure fold of a watch's diagnostic and progress streams (internal).

    One immutable value holds everything the reading rule needs: the finding
    set keyed by the watch's own diagnostic identifiers, whether that set has
    been synchronised at least once since the connection opened, whether a
    build is in flight, when the diagnostic stream last spoke, and whether a
    settle was witnessed since the last removal. {!apply} folds one timestamped
    event; {!reading} answers the availability rule without IO, so every
    timing case — the quiet window, the settle witness, the fallback — is a
    table-driven test over synthetic timestamps.

    The rules, stated once:

    - a reading exists only when the set is synchronised, no build is in
      flight, and the diagnostic stream has been quiet for [quiet_s] — never
      before the first diagnostic answer of a connection, so a not-yet-synced
      emptiness can never read as clean;
    - an empty set is confirmed — and a recovery therefore statable — only
      when a settle was witnessed after the last removal, or after
      [fallback_s] of diagnostic quiet, because the watch's progress source is
      sampled and a sub-sample rebuild can settle without an event. *)

type t
(** The type for stream folds. *)

val initial : t
(** [initial] is the fold before any connection: unsynchronised, no reading.
*)

type event =
  | Connected
      (** The subscriptions (re)opened: the set is forgotten and
          unsynchronised until the stream's first answer. *)
  | Diagnostics of
      [ `Add of string * Mentat_ocaml.Finding.t | `Remove of string ] list
      (** One diagnostic stream answer, in event order. The key is the watch's
          own diagnostic identifier, rendered injectively. An answer — empty
          included — synchronises the set; a removal un-witnesses the settle.
      *)
  | Progress of [ `Settle | `Busy ]
      (** One progress stream answer, collapsed: a finished build ([`Settle])
          admits readings and witnesses the emptiness it produced; anything
          else is a build in flight. *)

val apply : at:Mtime.t -> event -> t -> t
(** [apply ~at event t] folds [event], stamped [at], into [t]. *)

val building : t -> bool
(** [building t] is [true] while no settle has been folded since the
    connection opened or a build is in flight. *)

val reading :
  ?lint:Mentat_ocaml.Finding.t list ->
  t ->
  now:Mtime.t ->
  quiet_s:float ->
  fallback_s:float ->
  Mentat_ocaml.Build_change.Reading.t option
(** [reading t ~now ~quiet_s ~fallback_s] is the settled reading, when the
    rules above admit one. [lint] is the lint runner's current findings,
    joined into the reading with the lane live — a settled build reading is
    the one vehicle every lane rides ([None], the default, means the lane is
    off, which is lint-absent, never lint-clean). The stream's own findings
    are always build-lane; the lanes cannot cross. *)
