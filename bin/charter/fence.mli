(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Budget fences — pure folds over a charter's receipts.

    Admission is metered against the receipt log alone: derived spend over
    the trailing 24 hours and spawned runs over the trailing hour. Every
    query takes the clock as an argument and folds a receipt list, so
    running one twice is running it once; nothing here reads a file or the
    time.

    Windows trail [now] in plain seconds — a receipt is inside a window of
    [w] seconds when [now -. at < w], so a receipt exactly [w] old has just
    left. Second arithmetic knows no calendar: there are no midnight
    buckets and no daylight-saving edges to reason about.

    Every fold counts only receipts stamped with the [digest] under
    evaluation: editing the charter's policy re-stamps subsequent receipts
    and thereby resets every window, which is how an owner re-admits a
    fenced charter deliberately. *)

type verdict =
  | Pass  (** Admission may proceed to the spawn. *)
  | Fenced of Receipt.Meter.t  (** Refused; the tripped meter. *)

val admit :
  digest:string ->
  usd_per_day:float option ->
  runs_per_hour:int option ->
  now:float ->
  Receipt.t list ->
  verdict
(** [admit ~digest ~usd_per_day ~runs_per_hour ~now receipts] is the
    admission verdict under the given limits. Spend is checked first: when
    [usd_per_day] is a limit and the window's spend has reached it, the
    verdict is [Fenced Usd_per_day]. Then rate: when [runs_per_hour] is a
    limit and the trailing hour already holds that many spawns, the verdict
    is [Fenced Runs_per_hour]. A [None] limit meters nothing. *)

val spend_in_window : digest:string -> now:float -> Receipt.t list -> float
(** [spend_in_window ~digest ~now receipts] is the summed cost of reaped
    dispositions inside the trailing 24-hour window. An unpriced reap
    ([usd = None]) contributes nothing — which is why a charter whose model
    has no rate degrades to the run-count fence. *)

val spawns_in_window : digest:string -> now:float -> Receipt.t list -> int
(** [spawns_in_window ~digest ~now receipts] is the count of spawned
    dispositions inside the trailing one-hour window. *)

val should_alert :
  digest:string -> now:float -> meter:Receipt.Meter.t -> Receipt.t list -> bool
(** [should_alert ~digest ~now ~meter receipts] is [true] iff no alert
    receipt for a fence trip of [meter] — an alert whose transition is
    [Fenced] and whose window names [meter] — lies inside [meter]'s
    trailing window. The first trip in a window alerts; every later trip
    in the same window is receipted silently. *)
