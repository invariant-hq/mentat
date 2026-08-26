(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_charter

type fence = [ `Free | `Held | `Io of string ]
type run = [ `Settle | `Leave | `Overdue | `Skip of string ]

let run_action ~fence ~overdue =
  match fence () with
  | `Io message -> `Skip message
  | `Held -> if overdue () then `Overdue else `Leave
  | `Free -> `Settle

type sweep = [ `Drive | `Republish of string | `Done ]

let sweep_action ~claimed ~spawned ~egress ~settled =
  if not claimed || not (spawned ()) then `Drive
  else if egress () then `Done
  else
    match settled () with
    | Some session -> `Republish session
    | None -> `Done

module Pending = struct
  type t = {
    identity : string;
    digest : string;
    session : string;
    spawned_at : float;
  }
end

let pending_runs receipts =
  let reaped = Hashtbl.create 8 in
  List.iter
    (fun (r : Receipt.t) ->
      match r.Receipt.kind with
      | Receipt.Kind.Disposition (Receipt.Disposition.Reaped _) ->
          Hashtbl.replace reaped (r.Receipt.digest, r.Receipt.identity) ()
      | _ -> ())
    receipts;
  List.filter_map
    (fun (r : Receipt.t) ->
      match r.Receipt.kind with
      | Receipt.Kind.Disposition (Receipt.Disposition.Spawned { session })
        when not (Hashtbl.mem reaped (r.Receipt.digest, r.Receipt.identity)) ->
          Some
            {
              Pending.identity = r.Receipt.identity;
              digest = r.Receipt.digest;
              session;
              spawned_at = r.Receipt.at;
            }
      | _ -> None)
    receipts

(* Drivers. Probes and interpretation live here; every refusal and failure
   is narrated through the environment's line sink and none is raised — a
   broken charter or an unreachable remote must not stop the node, and the
   next beat retries for free. *)

let say env fmt = Printf.ksprintf env.Charter_fire.say fmt

(* One charter's pass narrates under the charter's name — the fold's own
   refusals and every line the fire pipeline speaks through the same
   environment — exactly as the node's delivery path prefixes: one resident
   process speaks for many charters, so the prefix is the line's
   provenance. *)
let charter_env env name =
  {
    env with
    Charter_fire.say =
      (fun line ->
        env.Charter_fire.say (Printf.sprintf "charter %s: %s" name line));
  }

let probe_fence env session : fence =
  match
    Mentat_store.Run_lock.holder env.Charter_fire.store
      ~session:(Mentat_session.Id.of_string session)
  with
  | `Free -> `Free
  | `Held _ -> `Held
  | `Io io -> `Io (Format.asprintf "%a" Mentat_store.Io.pp io)

let settle env (loaded : Charter_store.Loaded.t) (pending : Pending.t) =
  let { Pending.identity; digest; session; spawned_at } = pending in
  let fence () = probe_fence env session in
  let overdue () =
    let budget = loaded.Charter_store.Loaded.charter.Charter.budget in
    Unix.gettimeofday () -. spawned_at > budget.Charter.Budget.wall_clock
  in
  match run_action ~fence ~overdue with
  | `Leave -> ()
  | `Overdue ->
      say env
        "run %s outlives its wall clock; its fence holder is left to finish"
        session
  | `Skip message -> say env "run %s fence unprobeable: %s" session message
  | `Settle -> (
      match
        Charter_fire.settle_recovered env loaded ~identity ~digest ~session
      with
      | Ok () -> ()
      | Error e -> say env "recover %s: %s" session e)

let reconcile env ~repo_for (loaded : Charter_store.Loaded.t) =
  let name = loaded.Charter_store.Loaded.name in
  let env = charter_env env name in
  (match Charter_store.read_receipts env.Charter_fire.dirs ~name with
  | Error e -> say env "%s" (Charter_store.Error.message e)
  | Ok receipts -> List.iter (settle env loaded) (pending_runs receipts));
  if loaded.Charter_store.Loaded.charter.Charter.enabled then
    match repo_for loaded with
    | Error e -> say env "%s" e
    | Ok repo -> (
        match Charter_fire.fire_sweep env ~repo loaded with
        | Ok _ -> ()
        | Error e -> say env "sweep: %s" e)

let pass env ~repo_for =
  match Charter_store.roster env.Charter_fire.dirs with
  | Error e -> say env "charters: %s" (Charter_store.Error.message e)
  | Ok entries ->
      List.iter
        (fun (name, entry) ->
          match entry with
          | Error e ->
              say env "charter %s: %s" name (Charter_store.Error.message e)
          | Ok loaded -> reconcile env ~repo_for loaded)
        entries

(* The reconcile beat. Ten minutes: long enough that a beat's open-PR
   listings stay a rounding error against API budgets even across many
   charters, short enough that a run orphaned by a crash — or a delivery
   the resident lost before disposing it — converges well inside a
   reviewer's patience. The beat is a backstop behind webhook deliveries
   and a reap's own re-entry, never the primary delivery path. *)
let reconcile_interval_s = 600.0

let loop env ~repo_for =
  let clock = Eio.Stdenv.clock env.Charter_fire.stdenv in
  let rec beat () =
    match env.Charter_fire.stop () with
    | `Stop | `Force -> ()
    | `None ->
        pass env ~repo_for;
        Eio.Time.sleep clock reconcile_interval_s;
        beat ()
  in
  beat ()
