(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_routine
module Routine_fire = Mentat_boot.Routine_fire
module Routine_store = Mentat_boot.Routine_store

(* Drivers over the pure tables ([Mentat_routine.Record], the receipt
   folds). Probes and interpretation live here; every refusal and failure
   is narrated through the environment's line sink and none is raised — a
   broken routine or an unreachable remote must not stop the node, and the
   next beat retries for free. *)

let say env fmt = Printf.ksprintf env.Routine_fire.say fmt

(* The pending-run watch. Each open record — a spawned disposition with no
   reaped line — is observed through one [Mentat_broker.watch]: the fence
   and the journal head on the broker's poll, holding nothing, signalling
   nothing. The terminal observation, whichever arm, funnels into the one
   honest settle ([Routine_fire.settle_recovered]), whose own re-checks
   under the fire lock keep it exactly-once and refuse to settle over a
   holder — a run observed settled while its activation still lingers
   holding the fence is left to the next pass, which re-watches. The
   watched set dedups across passes: the beat is the backstop that starts
   a watch for any pending run none is observing — after a daemon restart,
   or after a settle that had to leave the record. *)
let watched : (string, unit) Hashtbl.t = Hashtbl.create 8

(* The spawn grace. A just-committed run's activation stages a whole
   composition before it binds the fence, and a watch cannot tell "crashed
   before settling" from "not yet booted": a free fence over an unfinished
   head reads holder-died either way, and a false settle spends the claim,
   fires a false alert, and suppresses the eventual publication. A pending
   run younger than this grace is left to the next pass — the broker's own
   boot patience is 30 s, so a minute keeps even a slow cold boot out of
   the false arm. MENTAT_ROUTINE_SPAWN_GRACE (test-only, seconds) shortens
   it so a blackbox stage that manufactures a seconds-old orphan is not
   paced by the default. *)
let default_spawn_grace_s = 60.0

let spawn_grace_s env =
  match
    Option.bind
      (List.assoc_opt "MENTAT_ROUTINE_SPAWN_GRACE"
         env.Routine_fire.environment)
      float_of_string_opt
  with
  | Some s when s >= 0. -> s
  | Some _ | None -> default_spawn_grace_s

let settle env (loaded : Routine_store.Loaded.t) (pending : Receipt.Pending.t)
    =
  let { Receipt.Pending.identity; digest; session; spawned_at } = pending in
  let age =
    Eio.Time.now (Eio.Stdenv.clock env.Routine_fire.stdenv) -. spawned_at
  in
  if age >= spawn_grace_s env && not (Hashtbl.mem watched session) then begin
    Hashtbl.replace watched session ();
    Mentat_broker.watch env.Routine_fire.broker
      ~session:(Mentat_session.Id.of_string session)
      ~on_terminal:(fun observation ->
        (match observation with
        | `Settled | `Holder_died -> ()
        | `Gone -> say env "run %s: its session document is gone" session);
        (match
           Routine_fire.settle_recovered env loaded ~identity ~digest ~session
         with
        | Ok () -> ()
        | Error e -> say env "recover %s: %s" session e);
        Hashtbl.remove watched session)
  end

(* The owed-alert re-derivation. A reap and its alert are two appends with
   an external hook between them, so no transaction can make them one; a
   crash in the window leaves a failed run the owner never hears about.
   This fold re-derives the alert each reaped disposition owes — the same
   judgment the reaping paths apply inline: a settled clean exit owes none
   (a settled run's close belongs to the sweep's publisher row), a forced
   stop alerts nothing (the stop is the owner's own act), and the normal
   stop path's interrupted head alerts nothing either — and re-fires it
   through the idempotent alert, whose receipt-log dedup makes every
   repeated derivation a no-op. *)
let owed_alert (r : Receipt.t) =
  match r.Receipt.kind with
  | Receipt.Kind.Disposition
      (Receipt.Disposition.Reaped { session; exit; head; cause; _ }) ->
      if
        (exit = 0 && Receipt.Head.equal head Receipt.Head.Settled)
        || Receipt.Cause.equal cause Receipt.Cause.Interrupted
        || Receipt.Head.equal head Receipt.Head.Interrupted
           && not (Receipt.Cause.equal cause Receipt.Cause.Recovered)
      then None
      else
        Some
          ( session,
            if exit = 3 || Receipt.Head.equal head Receipt.Head.Parked then
              Receipt.Transition.Parked
            else Receipt.Transition.Failed )
  | Receipt.Kind.Disposition _ | Receipt.Kind.Delivery _ | Receipt.Kind.Egress _
  | Receipt.Kind.Alert _ ->
      None

let repair_alerts env (loaded : Routine_store.Loaded.t) receipts =
  List.iter
    (fun (r : Receipt.t) ->
      match owed_alert r with
      | None -> ()
      | Some (session, transition) ->
          if
            not
              (Receipt.alerted ~digest:r.Receipt.digest
                 ~identity:r.Receipt.identity ~transition receipts)
          then (
            match
              Routine_fire.alert_identity env loaded ~digest:r.Receipt.digest
                ~identity:r.Receipt.identity ~transition
                ~session:(Some session)
            with
            | Ok () -> ()
            | Error e -> say env "alert %s: %s" r.Receipt.identity e))
    receipts

(* The delivery re-drive. A 202 promises the sender its event is owned, and
   the sender never redelivers — so a delivery receipt with no disposition
   is a promise a dead process left unkept, and this row keeps it: the
   event is rebuilt from the receipt's own members and driven through the
   ordinary dispose, whose claim and dup machinery make a re-drive
   idempotent. A record the pipeline cannot re-enter — a pre-upgrade line
   without the members, a corrupt rebuild, a policy edit that retired the
   delivery's digest — is closed with a skipped line instead: an
   un-closeable record would narrate forever, and the head, if still open,
   re-enters through the sweep under the policy in force. *)
let close_delivery env ~name (r : Receipt.t) reason =
  let receipt =
    {
      Receipt.at = Unix.gettimeofday ();
      identity = r.Receipt.identity;
      digest = r.Receipt.digest;
      kind = Receipt.Kind.Disposition (Receipt.Disposition.Skipped reason);
    }
  in
  match Routine_store.append_receipt env.Routine_fire.dirs ~name receipt with
  | Ok () -> say env "skipped %s: %s" r.Receipt.identity reason
  | Error e -> say env "%s" (Routine_store.Error.message e)

let unreconstructable = "unreconstructable delivery record"

let redrive_deliveries env ~repo (loaded : Routine_store.Loaded.t) receipts =
  let name = loaded.Routine_store.Loaded.name in
  let digest = loaded.Routine_store.Loaded.digest in
  List.fold_left
    (fun acc (r : Receipt.t) ->
      match acc with
      | Routine_fire.Interrupted -> acc
      | Routine_fire.Disposed -> (
          match r.Receipt.kind with
          | Receipt.Kind.Delivery None ->
              close_delivery env ~name r unreconstructable;
              acc
          | Receipt.Kind.Delivery (Some d) ->
              if not (String.equal r.Receipt.digest digest) then (
                close_delivery env ~name r "superseded by a policy edit";
                acc)
              else (
                match
                  Event.Pull_request.of_delivery ~identity:r.Receipt.identity
                    ~action:d.Receipt.Delivery.action
                    ~base_ref:d.Receipt.Delivery.base_ref
                    ~draft:d.Receipt.Delivery.draft
                    ~author_association:d.Receipt.Delivery.author_association
                with
                | None ->
                    close_delivery env ~name r unreconstructable;
                    acc
                | Some event -> (
                    match env.Routine_fire.stop () with
                    | `Stop | `Force -> Routine_fire.Interrupted
                    | `None -> (
                        say env "re-driving %s: admitted, never decided"
                          r.Receipt.identity;
                        match
                          Routine_fire.dispose env ~repo loaded ~event
                            ~check_head:true
                        with
                        | Ok outcome -> outcome
                        | Error e ->
                            say env "%s" e;
                            acc)))
          | Receipt.Kind.Disposition _ | Receipt.Kind.Egress _
          | Receipt.Kind.Alert _ ->
              acc))
    Routine_fire.Disposed
    (Receipt.open_deliveries receipts)

(* The one-pass gate. Passes must not run concurrently: the honest settle
   is serialized under the routine's fire lock, but two interleaved sweeps
   would double every GitHub listing and race the publisher re-entry into
   its upsert. One node runs per process, so the gate is module state — the
   boot settle and the periodic beat queue here, while the after-reap
   re-entry tries the gate and yields to a pass in flight rather than
   parking the pump behind it. Held across effects, never poisoned: the
   drivers never raise, and a cancellation mid-pass releases it on the way
   out. *)
let gate = Eio.Mutex.create ()

let with_gate f =
  Eio.Mutex.lock gate;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock gate) f

let reconcile_routine env ~repo_for (loaded : Routine_store.Loaded.t) =
  let name = loaded.Routine_store.Loaded.name in
  let env = Routine_fire.named_env env ~name in
  match Routine_store.read_receipts env.Routine_fire.dirs ~name with
  | Error e ->
      say env "%s" (Routine_store.Error.message e);
      `Continue
  | Ok receipts -> (
      List.iter (settle env loaded) (Receipt.pending_runs receipts);
      repair_alerts env loaded receipts;
      if loaded.Routine_store.Loaded.routine.Routine.enabled then (
        match repo_for loaded with
        | Error e ->
            say env "%s" e;
            `Continue
        | Ok repo -> (
            match redrive_deliveries env ~repo loaded receipts with
            | Routine_fire.Interrupted -> `Interrupted
            | Routine_fire.Disposed -> (
                match Routine_fire.fire_sweep env ~repo loaded with
                | Ok Routine_fire.Interrupted -> `Interrupted
                | Ok Routine_fire.Disposed -> `Continue
                | Error e ->
                    say env "sweep: %s" e;
                    `Continue)))
      else (
        (* A disabled routine sweeps nothing and publishes nothing, but its
           record is still owed: each open delivery gets the same skipped
           line intake writes when a disabled routine's event arrives. *)
        List.iter
          (fun (r : Receipt.t) ->
            match r.Receipt.kind with
            | Receipt.Kind.Delivery _ -> close_delivery env ~name r "disabled"
            | Receipt.Kind.Disposition _ | Receipt.Kind.Egress _
            | Receipt.Kind.Alert _ ->
                ())
          (Receipt.open_deliveries receipts);
        `Continue))

let reconcile env ~repo_for loaded =
  if Eio.Mutex.try_lock gate then
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock gate)
      (fun () ->
        match reconcile_routine env ~repo_for loaded with
        | `Continue | `Interrupted -> ())

let pass env ~repo_for =
  with_gate @@ fun () ->
  match Routine_store.roster env.Routine_fire.dirs with
  | Error e -> say env "routines: %s" (Routine_store.Error.message e)
  | Ok entries ->
      let rec drive = function
        | [] -> ()
        | (name, entry) :: rest -> (
            match env.Routine_fire.stop () with
            | `Stop | `Force -> ()
            | `None -> (
                match entry with
                | Error e ->
                    say env "routine %s: %s" name
                      (Routine_store.Error.message e);
                    drive rest
                | Ok loaded -> (
                    match reconcile_routine env ~repo_for loaded with
                    | `Interrupted -> ()
                    | `Continue -> drive rest)))
      in
      drive entries

let pass_settle env =
  with_gate @@ fun () ->
  match Routine_store.roster env.Routine_fire.dirs with
  | Error e -> say env "routines: %s" (Routine_store.Error.message e)
  | Ok entries ->
      List.iter
        (fun (name, entry) ->
          match entry with
          | Error e ->
              say env "routine %s: %s" name (Routine_store.Error.message e)
          | Ok loaded -> (
              let env = Routine_fire.named_env env ~name in
              match
                Routine_store.read_receipts env.Routine_fire.dirs ~name
              with
              | Error e -> say env "%s" (Routine_store.Error.message e)
              | Ok receipts ->
                  List.iter (settle env loaded) (Receipt.pending_runs receipts)))
        entries

(* The reconcile beat. Ten minutes: long enough that a beat's open-PR
   listings stay a rounding error against API budgets even across many
   routines, short enough that a run orphaned by a crash — or a delivery
   the resident lost before disposing it — converges well inside a
   reviewer's patience. The beat is a backstop behind webhook deliveries
   and a reap's own re-entry, never the primary delivery path. *)
let reconcile_interval_s = 600.0

let loop env ~repo_for =
  let clock = Eio.Stdenv.clock env.Routine_fire.stdenv in
  let rec beat () =
    match env.Routine_fire.stop () with
    | `Stop | `Force -> ()
    | `None ->
        pass env ~repo_for;
        Eio.Time.sleep clock reconcile_interval_s;
        beat ()
  in
  beat ()
