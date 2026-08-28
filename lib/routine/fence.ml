(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type verdict = Pass | Fenced of Receipt.Meter.t

let in_window ~now ~window (receipt : Receipt.t) =
  now -. receipt.Receipt.at < window

let relevant ~digest ~now ~window (receipt : Receipt.t) =
  String.equal receipt.Receipt.digest digest
  && in_window ~now ~window receipt

let spend_in_window ~digest ~now receipts =
  let window = Receipt.Meter.window Receipt.Meter.Usd_per_day in
  List.fold_left
    (fun total (receipt : Receipt.t) ->
      match receipt.Receipt.kind with
      | Receipt.Kind.Disposition (Receipt.Disposition.Reaped { usd = Some usd; _ })
        when relevant ~digest ~now ~window receipt ->
          total +. usd
      | _ -> total)
    0.0 receipts

let spawns_in_window ~digest ~now receipts =
  let window = Receipt.Meter.window Receipt.Meter.Runs_per_hour in
  List.fold_left
    (fun count (receipt : Receipt.t) ->
      match receipt.Receipt.kind with
      | Receipt.Kind.Disposition (Receipt.Disposition.Spawned _)
        when relevant ~digest ~now ~window receipt ->
          count + 1
      | _ -> count)
    0 receipts

(* The webhook default lives here, in admission itself, so an unfenced
   webhook routine can never exist by a caller forgetting to apply it: a
   delivery whose rate is set by whoever opens pull requests must never be
   an unmetered spender. A bare cli fire's rate is set by the owner's own
   scheduler, so it imposes no default. *)
let webhook_default_runs_per_hour = 6

let effective_runs_per_hour ~(budget : Routine.Budget.t) ~trigger =
  match budget.Routine.Budget.runs_per_hour with
  | Some limit -> Some limit
  | None -> (
      match trigger with
      | `Webhook -> Some webhook_default_runs_per_hour
      | `Cli -> None)

let spend_line ~digest ~now ~(budget : Routine.Budget.t) receipts =
  let spend = spend_in_window ~digest ~now receipts in
  match budget.Routine.Budget.usd_per_day with
  | Some limit -> Printf.sprintf "spend 24h: %.2f usd of %.2f" spend limit
  | None -> Printf.sprintf "spend 24h: %.2f usd (no limit)" spend

let runs_line ~digest ~now ~budget ~trigger receipts =
  let spawns = spawns_in_window ~digest ~now receipts in
  match effective_runs_per_hour ~budget ~trigger with
  | Some limit -> Printf.sprintf "runs 1h: %d of %d" spawns limit
  | None -> Printf.sprintf "runs 1h: %d (no limit)" spawns

let admit ~digest ~(budget : Routine.Budget.t) ~trigger ~now receipts =
  let spend_tripped =
    match budget.Routine.Budget.usd_per_day with
    | None -> false
    | Some limit ->
        Float.compare (spend_in_window ~digest ~now receipts) limit >= 0
  in
  if spend_tripped then Fenced Receipt.Meter.Usd_per_day
  else
    let rate_tripped =
      match effective_runs_per_hour ~budget ~trigger with
      | None -> false
      | Some limit -> spawns_in_window ~digest ~now receipts >= limit
    in
    if rate_tripped then Fenced Receipt.Meter.Runs_per_hour else Pass

let should_alert ~digest ~now ~meter receipts =
  let window = Receipt.Meter.window meter in
  not
    (List.exists
       (fun (receipt : Receipt.t) ->
         match receipt.Receipt.kind with
         | Receipt.Kind.Alert
             {
               transition = Receipt.Transition.Fenced;
               window = `Meter tripped;
             }
           when Receipt.Meter.equal tripped meter ->
             relevant ~digest ~now ~window receipt
         | _ -> false)
       receipts)
