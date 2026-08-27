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
  budget:Charter.Budget.t ->
  trigger:[ `Cli | `Webhook ] ->
  now:float ->
  Receipt.t list ->
  verdict
(** [admit ~digest ~budget ~trigger ~now receipts] is the admission verdict
    under [budget] for an event of the [trigger] kind — the {e delivery}'s
    trigger arm, never the invoking transport: an owner replaying or
    sweeping webhook-shaped deliveries admits them as [`Webhook], because
    their rate is set by whoever opens pull requests. Spend is checked
    first: when [budget.usd_per_day] is a limit and the window's spend has
    reached it, the verdict is [Fenced Usd_per_day]. Then rate: when the
    trailing hour already holds as many spawns as the rate limit, the
    verdict is [Fenced Runs_per_hour]. The rate limit is
    {!effective_runs_per_hour}; an absent limit meters nothing. *)

val effective_runs_per_hour :
  budget:Charter.Budget.t -> trigger:[ `Cli | `Webhook ] -> int option
(** [effective_runs_per_hour ~budget ~trigger] is the rate limit {!admit}
    applies: [budget.runs_per_hour] when set, else the delivery kind's
    default — 6 for [`Webhook], so a remote service can never be an
    unmetered spender by omission, and none for [`Cli]. Status surfaces
    render this same judgment, so what is displayed is what admission
    applies. *)

val spend_in_window : digest:string -> now:float -> Receipt.t list -> float
(** [spend_in_window ~digest ~now receipts] is the summed cost of reaped
    dispositions inside the trailing 24-hour window. An unpriced reap
    ([usd = None]) contributes nothing — which is why a charter whose model
    has no rate degrades to the run-count fence. *)

val spawns_in_window : digest:string -> now:float -> Receipt.t list -> int
(** [spawns_in_window ~digest ~now receipts] is the count of spawned
    dispositions inside the trailing one-hour window. *)

val spend_line :
  digest:string ->
  now:float ->
  budget:Charter.Budget.t ->
  Receipt.t list ->
  string
(** [spend_line ~digest ~now ~budget receipts] is the one-line spend
    projection every status surface prints — ["spend 24h: 1.25 usd of
    15.00"], or ["spend 24h: 1.25 usd (no limit)"] when spend is
    unmetered: {!spend_in_window} rendered against the budget. One
    projection, so the CLI roster and the dashboard can never disagree on
    the same meter. *)

val runs_line :
  digest:string ->
  now:float ->
  budget:Charter.Budget.t ->
  trigger:[ `Cli | `Webhook ] ->
  Receipt.t list ->
  string
(** [runs_line ~digest ~now ~budget ~trigger receipts] is the one-line
    rate projection — ["runs 1h: 2 of 6"], or ["runs 1h: 2 (no limit)"]
    when {!effective_runs_per_hour} answers [None]: {!spawns_in_window}
    rendered against the limit admission itself applies. *)

val should_alert :
  digest:string -> now:float -> meter:Receipt.Meter.t -> Receipt.t list -> bool
(** [should_alert ~digest ~now ~meter receipts] is [true] iff no alert
    receipt for a fence trip of [meter] — an alert whose transition is
    [Fenced] and whose window is [`Meter meter] — lies inside [meter]'s
    trailing window. The first trip in a window alerts; every later trip
    in the same window is receipted silently. *)
