(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Mentat_broker.Reconcile], the child broker's pure
   reconciliation tables — every process-level decision the broker makes,
   driven here over thunk probes with no process, socket, or store behind
   them. *)

open Windtrap
open Mentat_broker

let action =
  Testable.make
    ~pp:(fun ppf -> function
      | Reconcile.Observe -> Format.pp_print_string ppf "Observe"
      | Reconcile.Preempt pid -> Format.fprintf ppf "Preempt %d" pid
      | Reconcile.Respawn -> Format.pp_print_string ppf "Respawn"
      | Reconcile.Dispose -> Format.pp_print_string ppf "Dispose"
      | Reconcile.Stand_down -> Format.pp_print_string ppf "Stand_down"
      | Reconcile.Fail message -> Format.fprintf ppf "Fail %S" message)
    ~equal:(fun a b ->
      match (a, b) with
      | Reconcile.Observe, Reconcile.Observe
      | Reconcile.Respawn, Reconcile.Respawn
      | Reconcile.Dispose, Reconcile.Dispose
      | Reconcile.Stand_down, Reconcile.Stand_down ->
          true
      | Reconcile.Preempt a, Reconcile.Preempt b -> Int.equal a b
      | Reconcile.Fail _, Reconcile.Fail _ -> true
      | _ -> false)

let boot =
  Testable.make
    ~pp:(fun ppf -> function
      | `Adopt -> Format.pp_print_string ppf "Adopt"
      | `Adopt_and_watch -> Format.pp_print_string ppf "Adopt_and_watch"
      | `Watch -> Format.pp_print_string ppf "Watch"
      | `Adopt_and_dispose -> Format.pp_print_string ppf "Adopt_and_dispose"
      | `Dispose -> Format.pp_print_string ppf "Dispose"
      | `Skip reason -> Format.fprintf ppf "Skip %S" reason)
    ~equal:(fun (a : Reconcile.boot) (b : Reconcile.boot) ->
      match (a, b) with
      | `Adopt, `Adopt
      | `Adopt_and_watch, `Adopt_and_watch
      | `Watch, `Watch
      | `Adopt_and_dispose, `Adopt_and_dispose
      | `Dispose, `Dispose
      | `Skip _, `Skip _ ->
          true
      | _ -> false)

let never_reachable () : bool = fail "reachable must not be probed on this arm"
let never_head () : Reconcile.head = fail "head must not be probed on this arm"

let decide ?(reachable = never_reachable) ?(head = never_head) fence =
  Reconcile.decide ~fence:(fun () -> fence) ~reachable ~head

(* The whole materialization table, arm by arm — including which probes each
   arm is allowed to spend: reachability only under a foreign-held fence, the
   journal head only under a free one. *)
let materialize_table () =
  equal action ~msg:"an unprobeable fence fails loudly" (Reconcile.Fail "")
    (decide (`Io "boom"));
  equal action ~msg:"a self-held fence stands the broker down"
    Reconcile.Stand_down (decide `Held_self);
  equal action ~msg:"a reachable holder is observed, never respawned"
    Reconcile.Observe
    (decide ~reachable:(fun () -> true) (`Held (Some 42)));
  equal action ~msg:"a reachable holder needs no identity" Reconcile.Observe
    (decide ~reachable:(fun () -> true) (`Held None));
  equal action ~msg:"an unreachable same-host holder is preempted"
    (Reconcile.Preempt 42)
    (decide ~reachable:(fun () -> false) (`Held (Some 42)));
  equal action ~msg:"an unreachable unidentifiable holder fails loudly"
    (Reconcile.Fail "")
    (decide ~reachable:(fun () -> false) (`Held None));
  equal action ~msg:"a free fence with outstanding work respawns"
    Reconcile.Respawn
    (decide ~head:(fun () -> `Unfinished) `Free);
  equal action ~msg:"a free fence over a settled head disposes"
    Reconcile.Dispose
    (decide ~head:(fun () -> `Terminal) `Free);
  equal action ~msg:"a free fence over no session disposes" Reconcile.Dispose
    (decide ~head:(fun () -> `Absent) `Free)

(* The node-boot table over its full domain. *)
let boot_table () =
  let all_heads = [ `Unfinished; `Terminal; `Absent ] in
  let all_parents = [ `Waiting; `Idle; `Absent ] in
  List.iter
    (fun head ->
      List.iter
        (fun parent ->
          equal boot ~msg:"an unprobeable fence skips the candidate"
            (`Skip "")
            (Reconcile.boot_action ~fence:`Io ~head ~parent))
        all_parents)
    all_heads;
  List.iter
    (fun head ->
      equal boot ~msg:"a parentless orphan under a free fence is disposed"
        `Dispose
        (Reconcile.boot_action ~fence:`Free ~head ~parent:`Absent);
      equal boot
        ~msg:"a live parentless orphan is left alone, never re-driven"
        (`Skip "")
        (Reconcile.boot_action ~fence:`Held ~head ~parent:`Absent))
    all_heads;
  List.iter
    (fun head ->
      equal boot ~msg:"a live child with a waiting parent adopts and watches"
        `Adopt_and_watch
        (Reconcile.boot_action ~fence:`Held ~head ~parent:`Waiting);
      equal boot
        ~msg:"a live child nobody waits for is watched, its parent unpinned"
        `Watch
        (Reconcile.boot_action ~fence:`Held ~head ~parent:`Idle))
    all_heads;
  List.iter
    (fun parent ->
      equal boot ~msg:"outstanding work under a free fence adopts to re-drive"
        `Adopt
        (Reconcile.boot_action ~fence:`Free ~head:`Unfinished ~parent))
    [ `Waiting; `Idle ];
  List.iter
    (fun head ->
      equal boot
        ~msg:"a settled child with a waiting parent adopts, then disposes"
        `Adopt_and_dispose
        (Reconcile.boot_action ~fence:`Free ~head ~parent:`Waiting);
      equal boot ~msg:"a settled child nobody waits for is residue" `Dispose
        (Reconcile.boot_action ~fence:`Free ~head ~parent:`Idle))
    [ `Terminal; `Absent ]

let () =
  run "mentat.reconcile"
    [
      test "the materialization table" materialize_table;
      test "the node-boot table" boot_table;
    ]
