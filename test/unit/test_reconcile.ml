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
      | Reconcile.Reprobe -> Format.pp_print_string ppf "Reprobe"
      | Reconcile.Fail message -> Format.fprintf ppf "Fail %S" message)
    ~equal:(fun a b ->
      match (a, b) with
      | Reconcile.Observe, Reconcile.Observe
      | Reconcile.Respawn, Reconcile.Respawn
      | Reconcile.Dispose, Reconcile.Dispose
      | Reconcile.Stand_down, Reconcile.Stand_down
      | Reconcile.Reprobe, Reconcile.Reprobe ->
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
  equal action
    ~msg:"a custodial hold is re-probed — never preempted, never failed"
    Reconcile.Reprobe (decide `Custodial);
  equal action ~msg:"a free fence with outstanding work respawns"
    Reconcile.Respawn
    (decide ~head:(fun () -> `Unfinished) `Free);
  equal action ~msg:"a free fence over a settled head disposes"
    Reconcile.Dispose
    (decide ~head:(fun () -> `Terminal) `Free);
  equal action ~msg:"a free fence over no session disposes" Reconcile.Dispose
    (decide ~head:(fun () -> `Absent) `Free)

let root_action =
  Testable.make
    ~pp:(fun ppf -> function
      | Reconcile.Adopt -> Format.pp_print_string ppf "Adopt"
      | Reconcile.Preempt_stale pid -> Format.fprintf ppf "Preempt_stale %d" pid
      | Reconcile.Spawn -> Format.pp_print_string ppf "Spawn"
      | Reconcile.Settle -> Format.pp_print_string ppf "Settle"
      | Reconcile.Reprobe_hold -> Format.pp_print_string ppf "Reprobe_hold"
      | Reconcile.Hold -> Format.pp_print_string ppf "Hold"
      | Reconcile.Refuse message -> Format.fprintf ppf "Refuse %S" message)
    ~equal:(fun a b ->
      match (a, b) with
      | Reconcile.Adopt, Reconcile.Adopt
      | Reconcile.Spawn, Reconcile.Spawn
      | Reconcile.Settle, Reconcile.Settle
      | Reconcile.Reprobe_hold, Reconcile.Reprobe_hold
      | Reconcile.Hold, Reconcile.Hold ->
          true
      | Reconcile.Preempt_stale a, Reconcile.Preempt_stale b -> Int.equal a b
      | Reconcile.Refuse _, Reconcile.Refuse _ -> true
      | _ -> false)

let supervise ?(reachable = never_reachable) ?(head = never_head) fence =
  Reconcile.supervise_action ~fence:(fun () -> fence) ~reachable ~head

(* The root-supervision table, arm by arm. It shares the delegated table's
   probe discipline — reachability only under a held fence, the head only
   under a free one — and differs where the two verbs must rule differently:
   an unpreemptable holder is a bounded hold, never an immediate failure, and
   a free fence over a missing session refuses rather than settles. No fence
   answer maps to a signal against anything but a stale same-host child
   server. *)
let supervise_table () =
  equal root_action ~msg:"an unprobeable fence refuses loudly"
    (Reconcile.Refuse "")
    (supervise (`Io "boom"));
  equal root_action ~msg:"a self-held fence is a hold, never a signal"
    Reconcile.Hold (supervise `Held_self);
  equal root_action ~msg:"a reachable holder is adopted" Reconcile.Adopt
    (supervise ~reachable:(fun () -> true) (`Held (Some 42)));
  equal root_action ~msg:"a reachable holder needs no identity" Reconcile.Adopt
    (supervise ~reachable:(fun () -> true) (`Held None));
  equal root_action ~msg:"an unreachable same-host child server is preempted"
    (Reconcile.Preempt_stale 42)
    (supervise ~reachable:(fun () -> false) (`Held (Some 42)));
  equal root_action
    ~msg:"an unreachable unidentifiable holder is a bounded hold, no signal"
    Reconcile.Hold
    (supervise ~reachable:(fun () -> false) (`Held None));
  equal root_action
    ~msg:"a custodial hold is re-probed — never preempted, never failed"
    Reconcile.Reprobe_hold (supervise `Custodial);
  equal root_action ~msg:"a free fence with outstanding work spawns"
    Reconcile.Spawn
    (supervise ~head:(fun () -> `Unfinished) `Free);
  equal root_action ~msg:"a free fence over concluded work settles"
    Reconcile.Settle
    (supervise ~head:(fun () -> `Terminal) `Free);
  equal root_action ~msg:"a free fence over no session refuses"
    (Reconcile.Refuse "")
    (supervise ~head:(fun () -> `Absent) `Free)

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
      test "the root-supervision table" supervise_table;
      test "the node-boot table" boot_table;
    ]
