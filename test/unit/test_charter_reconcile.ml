(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Charter_reconcile], the node's charter reconcile fold —
   the pure decision tables and receipt folds a resident pass judges a
   charter's durable record by, driven here over thunk probes and
   hand-built receipts with no store, fence, or child behind them. The
   module lives in [bin/mentatd] and is not library-linkable, so its source
   is copied into this test executable by the [copy_files] rule in
   [dune]. *)

open Windtrap
open Mentat_charter

let run_decision =
  Testable.make
    ~pp:(fun ppf -> function
      | `Settle -> Format.pp_print_string ppf "Settle"
      | `Leave -> Format.pp_print_string ppf "Leave"
      | `Overdue -> Format.pp_print_string ppf "Overdue"
      | `Skip reason -> Format.fprintf ppf "Skip %S" reason)
    ~equal:(fun (a : Charter_reconcile.run) (b : Charter_reconcile.run) ->
      match (a, b) with
      | `Settle, `Settle | `Leave, `Leave | `Overdue, `Overdue -> true
      | `Skip _, `Skip _ -> true
      | _ -> false)

let never_overdue () : bool = fail "overdue must not be read on this arm"

let run_action ?(overdue = never_overdue) fence =
  Charter_reconcile.run_action ~fence:(fun () -> fence) ~overdue

(* The pending-run table, arm by arm — including which probes each arm may
   spend: the clock is read only under a held fence. The free-fence row is
   the one that makes the pipeline's driver cancellable at any instant: a
   run orphaned between spawn and reap is settled by the next pass. *)
let run_table () =
  equal run_decision ~msg:"a free fence settles the orphaned record honestly"
    `Settle (run_action `Free);
  equal run_decision ~msg:"an unprobeable fence is never settled over"
    (`Skip "") (run_action (`Io "boom"));
  equal run_decision ~msg:"a live holder within budget is left alone" `Leave
    (run_action ~overdue:(fun () -> false) `Held);
  equal run_decision ~msg:"a live holder past budget is narrated, not killed"
    `Overdue
    (run_action ~overdue:(fun () -> true) `Held)

let sweep_decision =
  Testable.make
    ~pp:(fun ppf -> function
      | `Drive -> Format.pp_print_string ppf "Drive"
      | `Republish session -> Format.fprintf ppf "Republish %s" session
      | `Done -> Format.pp_print_string ppf "Done")
    ~equal:(fun (a : Charter_reconcile.sweep) (b : Charter_reconcile.sweep) ->
      match (a, b) with
      | `Drive, `Drive | `Done, `Done -> true
      | `Republish a, `Republish b -> String.equal a b
      | _ -> false)

let never_spawned () : bool = fail "spawned must not be read on this arm"
let never_egress () : bool = fail "egress must not be read on this arm"

let never_settled () : string option =
  fail "settled must not be read on this arm"

let sweep_action ?(spawned = never_spawned) ?(egress = never_egress)
    ?(settled = never_settled) claimed =
  Charter_reconcile.sweep_action ~claimed ~spawned ~egress ~settled

(* The sweep table over its full domain, with probe frugality pinned: the
   spawned line is read only under a held claim, egress only under a
   committed spawn, and the publishable session only when no egress line
   exists. *)
let sweep_table () =
  equal sweep_decision ~msg:"an unclaimed identity is driven whole" `Drive
    (sweep_action false);
  equal sweep_decision
    ~msg:"a claim with no spawned line is adopted and driven" `Drive
    (sweep_action ~spawned:(fun () -> false) true);
  equal sweep_decision ~msg:"an egress line completes the record" `Done
    (sweep_action ~spawned:(fun () -> true) ~egress:(fun () -> true) true);
  equal sweep_decision
    ~msg:"a publishable settle with no egress re-enters the publisher"
    (`Republish "s1")
    (sweep_action
       ~spawned:(fun () -> true)
       ~egress:(fun () -> false)
       ~settled:(fun () -> Some "s1")
       true);
  equal sweep_decision
    ~msg:"a committed record with nothing publishable is left alone" `Done
    (sweep_action
       ~spawned:(fun () -> true)
       ~egress:(fun () -> false)
       ~settled:(fun () -> None)
       true)

(* Receipt builders for the pending fold. *)

let receipt ?(at = 1000.) ~identity ~digest kind =
  { Receipt.at; identity; digest; kind }

let spawned ?at ~identity ~digest session =
  receipt ?at ~identity ~digest
    (Receipt.Kind.Disposition (Receipt.Disposition.Spawned { session }))

let reaped ?at ~identity ~digest session =
  receipt ?at ~identity ~digest
    (Receipt.Kind.Disposition
       (Receipt.Disposition.Reaped
          {
            session;
            exit = 0;
            head = Receipt.Head.Settled;
            usage = Jsont.Json.object' [];
            usd = None;
            cause = Receipt.Cause.Exited;
          }))

let pending =
  Testable.make
    ~pp:(fun ppf (p : Charter_reconcile.Pending.t) ->
      Format.fprintf ppf "%s@%s:%s at %g" p.Charter_reconcile.Pending.identity
        p.Charter_reconcile.Pending.digest p.Charter_reconcile.Pending.session
        p.Charter_reconcile.Pending.spawned_at)
    ~equal:(fun (a : Charter_reconcile.Pending.t) b ->
      String.equal a.Charter_reconcile.Pending.identity
        b.Charter_reconcile.Pending.identity
      && String.equal a.Charter_reconcile.Pending.digest
           b.Charter_reconcile.Pending.digest
      && String.equal a.Charter_reconcile.Pending.session
           b.Charter_reconcile.Pending.session
      && Float.equal a.Charter_reconcile.Pending.spawned_at
           b.Charter_reconcile.Pending.spawned_at)

let open_run ~identity ~digest ~session ~spawned_at =
  { Charter_reconcile.Pending.identity; digest; session; spawned_at }

let pending_fold () =
  let runs = Testable.list pending in
  equal runs ~msg:"an empty log holds nothing open" []
    (Charter_reconcile.pending_runs []);
  equal runs ~msg:"a delivery alone opens nothing" []
    (Charter_reconcile.pending_runs
       [ receipt ~identity:"i" ~digest:"d" Receipt.Kind.Delivery ]);
  equal runs ~msg:"other dispositions neither open nor close" []
    (Charter_reconcile.pending_runs
       [
         receipt ~identity:"i" ~digest:"d"
           (Receipt.Kind.Disposition (Receipt.Disposition.Skipped "draft"));
         receipt ~identity:"i" ~digest:"d"
           (Receipt.Kind.Disposition Receipt.Disposition.Dup);
       ]);
  equal runs ~msg:"a spawned line with no reap is open"
    [ open_run ~identity:"i" ~digest:"d" ~session:"s" ~spawned_at:7. ]
    (Charter_reconcile.pending_runs
       [ spawned ~at:7. ~identity:"i" ~digest:"d" "s" ]);
  equal runs ~msg:"a reaped line closes its spawn" []
    (Charter_reconcile.pending_runs
       [
         spawned ~identity:"i" ~digest:"d" "s";
         reaped ~identity:"i" ~digest:"d" "s";
       ]);
  equal runs ~msg:"pairing is by digest and identity, never by session" []
    (Charter_reconcile.pending_runs
       [
         spawned ~identity:"i" ~digest:"d" "s";
         reaped ~identity:"i" ~digest:"d" "other";
       ]);
  equal runs ~msg:"a reap under another digest closes nothing"
    [ open_run ~identity:"i" ~digest:"d1" ~session:"s" ~spawned_at:7. ]
    (Charter_reconcile.pending_runs
       [
         spawned ~at:7. ~identity:"i" ~digest:"d1" "s";
         reaped ~identity:"i" ~digest:"d2" "s";
       ]);
  equal runs ~msg:"a reap under another identity closes nothing"
    [ open_run ~identity:"a" ~digest:"d" ~session:"s" ~spawned_at:7. ]
    (Charter_reconcile.pending_runs
       [
         spawned ~at:7. ~identity:"a" ~digest:"d" "s";
         reaped ~identity:"b" ~digest:"d" "s";
       ]);
  equal runs ~msg:"open runs keep log order"
    [
      open_run ~identity:"a" ~digest:"d" ~session:"s1" ~spawned_at:1.;
      open_run ~identity:"b" ~digest:"d" ~session:"s2" ~spawned_at:2.;
    ]
    (Charter_reconcile.pending_runs
       [
         spawned ~at:1. ~identity:"a" ~digest:"d" "s1";
         receipt ~identity:"c" ~digest:"d" Receipt.Kind.Delivery;
         spawned ~at:2. ~identity:"b" ~digest:"d" "s2";
       ])

(* The driver, end to end over a temporary estate: a spawned receipt with no
   reaped line, no session journal, and a free fence is the record a killed
   resident leaves behind — one pass settles it honestly (recovered, head
   missing, exit 255), alerts once, and a second pass finds nothing owed. *)

let temp_dir prefix =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%06x" prefix (Unix.getpid ()) (Random.int 0xFFFFFF))
  in
  Unix.mkdir dir 0o700;
  dir

let test_charter ~name ~enabled =
  {
    Charter.name;
    enabled;
    repo = "acme/widgets";
    triggers = [ Charter.Trigger.Cli ];
    permission_unattended = None;
    run =
      {
        Charter.Run.model = None;
        reasoning = None;
        max_steps = 1;
        prompt = "prompt.md";
        output_schema = "schema.json";
        project_instructions = None;
      };
    budget =
      {
        Charter.Budget.wall_clock = 60.;
        usd_per_day = None;
        runs_per_hour = None;
      };
    notify = None;
    suppress_clean_run = false;
  }

let with_estate name fn =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let home = temp_dir ("mentat-reconcile-" ^ name) in
  let dirs =
    match
      User_dirs.resolve ~getenv:(function
        | "HOME" -> Some home
        | _ -> None)
    with
    | Ok dirs -> dirs
    | Error e -> failf "resolve dirs: %s" e
  in
  let store_base = temp_dir ("mentat-reconcile-store-" ^ name) in
  let store =
    match
      Mentat_store.open_ ~sw
        (Eio.Path.( / ) (Eio.Stdenv.fs stdenv) store_base)
    with
    | Ok store -> store
    | Error e -> failf "open store: %s" (Mentat_store.Error.message e)
  in
  let said = ref [] in
  let env =
    {
      Charter_fire.dirs;
      store;
      catalog = Mentat_provider.Catalog.make [];
      stdenv;
      environment = [];
      mentat_bin = "/nonexistent/mentat";
      stop = (fun () -> `None);
      say = (fun line -> said := line :: !said);
    }
  in
  fn ~env ~dirs ~said

let loaded_of dirs ~name ~enabled =
  {
    Charter_store.Loaded.name;
    dir = User_dirs.charter_dir dirs name;
    charter = test_charter ~name ~enabled;
    digest = "d1";
    prompt = "";
    output_schema = "";
    ingress_id = None;
  }

let append_spawned dirs ~name ~identity ~session =
  match
    Charter_store.append_receipt dirs ~name
      (spawned ~at:1. ~identity ~digest:"d1" session)
  with
  | Ok () -> ()
  | Error e -> failf "append: %s" (Charter_store.Error.message e)

let read_back dirs ~name =
  match Charter_store.read_receipts dirs ~name with
  | Ok receipts -> receipts
  | Error e -> failf "read receipts: %s" (Charter_store.Error.message e)

let orphan_settles () =
  with_estate "orphan" @@ fun ~env ~dirs ~said ->
  let name = "pr-review" in
  let identity = "github:acme/widgets#1@abc1234:opened" in
  let loaded = loaded_of dirs ~name ~enabled:false in
  append_spawned dirs ~name ~identity ~session:"run-orphan";
  let repo_for _ = fail "a disabled charter must not build a repo" in
  Charter_reconcile.reconcile env ~repo_for loaded;
  (match read_back dirs ~name with
  | [ _spawned; recovered; alert ] ->
      (match recovered.Receipt.kind with
      | Receipt.Kind.Disposition
          (Receipt.Disposition.Reaped { session; exit; head; usd; cause; _ })
        ->
          equal string ~msg:"the settle names the orphaned session"
            "run-orphan" session;
          equal int ~msg:"no observable status stamps exit 255" 255 exit;
          equal string ~msg:"a child with no journal reads head missing"
            "missing"
            (Receipt.Head.to_string head);
          equal string ~msg:"the cause is recovered" "recovered"
            (Receipt.Cause.to_string cause);
          equal (Testable.option float_exact)
            ~msg:"an empty catalog prices nothing" None usd;
          equal string ~msg:"the settle is stamped with the run's digest"
            "d1" recovered.Receipt.digest
      | _ -> fail "the second receipt must be the recovered reap");
      (match alert.Receipt.kind with
      | Receipt.Kind.Alert { transition; window = `Identity } ->
          equal string ~msg:"an unpublishable recovery alerts failed" "failed"
            (Receipt.Transition.to_string transition)
      | _ -> fail "the third receipt must be the identity-scoped alert")
  | receipts ->
      failf "expected spawned+reaped+alert, got %d receipts"
        (List.length receipts));
  equal bool ~msg:"the settle is narrated" true
    (List.exists
       (fun line -> String.length line >= 9 && String.sub line 0 9 = "recovered")
       !said);
  Charter_reconcile.reconcile env ~repo_for loaded;
  equal int ~msg:"a second pass finds nothing owed" 3
    (List.length (read_back dirs ~name))

let sweep_failure_is_narrated () =
  with_estate "sweep" @@ fun ~env ~dirs ~said ->
  let name = "pr-review" in
  let identity = "github:acme/widgets#2@def5678:opened" in
  let loaded = loaded_of dirs ~name ~enabled:true in
  append_spawned dirs ~name ~identity ~session:"run-open";
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Error "no read token")
    loaded;
  equal bool
    ~msg:"the pending run settles before the repo is even built" true
    (List.exists
       (fun (r : Receipt.t) ->
         match r.Receipt.kind with
         | Receipt.Kind.Disposition (Receipt.Disposition.Reaped { cause; _ })
           ->
             Receipt.Cause.equal cause Receipt.Cause.Recovered
         | _ -> false)
       (read_back dirs ~name));
  equal bool ~msg:"the repo failure is narrated, never raised" true
    (List.exists
       (fun line ->
         String.length line > 0
         &&
         match String.index_opt line ':' with
         | Some _ -> String.ends_with ~suffix:"no read token" line
         | None -> false)
       !said)

let () =
  run "mentat.charter_reconcile"
    [
      test "the pending-run table" run_table;
      test "the sweep table" sweep_table;
      test "the pending fold" pending_fold;
      test "an orphaned run settles honestly" orphan_settles;
      test "a repo failure narrates and never raises" sweep_failure_is_narrated;
    ]
