(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Charter_reconcile], the node's charter reconcile
   drivers — the honest settle, the owed-alert repair, the delivery
   re-drive, and the one-pass gate — exercised over a temporary charter
   estate with injected repository closures. The pure tables the drivers
   interpret live in [Mentat_charter] and are tested with that library; the
   module here lives in [bin/mentatd] and is not library-linkable, so its
   source is copied into this test executable by the [copy_files] rule in
   [dune]. *)

open Windtrap
open Mentat_charter

let head_sha = String.make 40 'a'

let event ?(action = "opened") ?(number = 7) () =
  {
    Event.Pull_request.action;
    number;
    head_sha;
    base_ref = "main";
    draft = false;
    author_association = "OWNER";
    repo = "acme/widgets";
  }

(* Receipt builders. *)

let receipt ?(at = 1000.) ~identity ~digest kind =
  { Receipt.at; identity; digest; kind }

let spawned ?at ~identity ~digest session =
  receipt ?at ~identity ~digest
    (Receipt.Kind.Disposition (Receipt.Disposition.Spawned { session }))

let reaped ?at ?(exit = 0) ?(head = Receipt.Head.Settled)
    ?(cause = Receipt.Cause.Exited) ~identity ~digest session =
  receipt ?at ~identity ~digest
    (Receipt.Kind.Disposition
       (Receipt.Disposition.Reaped
          {
            session;
            exit;
            head;
            usage = Jsont.Json.object' [];
            usd = None;
            cause;
          }))

let delivery ?at ~identity ~digest fields =
  receipt ?at ~identity ~digest (Receipt.Kind.Delivery fields)

let admitted_fields (ev : Event.Pull_request.t) =
  Some
    {
      Receipt.Delivery.action = ev.Event.Pull_request.action;
      base_ref = ev.Event.Pull_request.base_ref;
      draft = ev.Event.Pull_request.draft;
      author_association = ev.Event.Pull_request.author_association;
    }

(* The estate. *)

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
    triggers =
      [
        Charter.Trigger.Github_webhook
          {
            Charter.Trigger.Webhook.events = [ "pull_request.opened" ];
            gate =
              { Charter.Gate.base = None; drafts = false; associations = None };
          };
        Charter.Trigger.Cli;
      ];
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
  let broker =
    Mentat_broker.create ~sw ~stdenv ~store
      ~resolve_bin:(fun () -> Error "unit tests spawn nothing")
      ~socket_base:(temp_dir ("mentat-reconcile-sock-" ^ name))
      ~log_dir:(temp_dir ("mentat-reconcile-log-" ^ name))
      ~now:(fun () -> Mentat_session.Time.of_unix_ms 0L)
  in
  let env =
    {
      Charter_fire.dirs;
      store;
      catalog = Mentat_provider.Catalog.make [];
      stdenv;
      environment = [];
      mentat_bin = "/nonexistent/mentat";
      broker;
      stop = (fun () -> `None);
      say = (fun line -> said := line :: !said);
    }
  in
  (* The pending-run settle rides a broker watch, so its receipts land on a
     watch fiber shortly after a pass returns; [await] bounds the wait. *)
  let await ~msg pred =
    let clock = Eio.Stdenv.clock stdenv in
    let rec go n =
      if pred () then ()
      else if n = 0 then failf "%s: not observed in time" msg
      else begin
        Eio.Time.sleep clock 0.05;
        go (n - 1)
      end
    in
    go 100
  in
  let result = fn ~env ~dirs ~said ~await in
  Mentat_broker.stop broker;
  result

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

let append dirs ~name receipt =
  match Charter_store.append_receipt dirs ~name receipt with
  | Ok () -> ()
  | Error e -> failf "append: %s" (Charter_store.Error.message e)

let read_back dirs ~name =
  match Charter_store.read_receipts dirs ~name with
  | Ok receipts -> receipts
  | Error e -> failf "read receipts: %s" (Charter_store.Error.message e)

let claim dirs ~name ~digest identity =
  match Charter_store.claim_identity dirs ~name ~digest identity with
  | Ok `Claimed -> ()
  | Ok `Dup -> failf "claim: already held"
  | Error e -> failf "claim: %s" (Charter_store.Error.message e)

let fake_repo ?current_head ?(open_prs = fun () -> Ok []) () =
  let current_head =
    match current_head with
    | Some current_head -> current_head
    | None -> fun ~number:_ -> fail "current_head must not be read"
  in
  {
    Charter_fire.Repo.git_url = "/nonexistent/remote.git";
    github =
      {
        Charter_fire.Github.current_head;
        open_prs;
        posted = (fun ~number:_ -> fail "posted must not be read");
      };
  }

let count pred receipts = List.length (List.filter pred receipts)

let is_alert (r : Receipt.t) =
  match r.Receipt.kind with
  | Receipt.Kind.Alert { window = `Identity; _ } -> true
  | _ -> false

let is_egress (r : Receipt.t) =
  match r.Receipt.kind with Receipt.Kind.Egress _ -> true | _ -> false

let is_skipped reason (r : Receipt.t) =
  match r.Receipt.kind with
  | Receipt.Kind.Disposition (Receipt.Disposition.Skipped carried) ->
      String.equal carried reason
  | _ -> false

(* A spawned receipt with no reaped line, no session journal, and a free
   fence is the record a killed resident leaves behind — one pass settles it
   honestly (recovered, head missing, exit 255), alerts once, and a second
   pass finds nothing owed. *)
let orphan_settles () =
  with_estate "orphan" @@ fun ~env ~dirs ~said ~await ->
  let name = "pr-review" in
  let identity = "github:acme/widgets#1@abc1234:opened" in
  let loaded = loaded_of dirs ~name ~enabled:false in
  append dirs ~name (spawned ~at:1. ~identity ~digest:"d1" "run-orphan");
  let repo_for _ = fail "a disabled charter must not build a repo" in
  Charter_reconcile.reconcile env ~repo_for loaded;
  await ~msg:"the watched orphan settles" (fun () ->
      List.length (read_back dirs ~name) >= 3);
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
  equal bool ~msg:"the settle is narrated under the charter's name" true
    (List.exists
       (String.starts_with ~prefix:"charter pr-review: recovered")
       !said);
  Charter_reconcile.reconcile env ~repo_for loaded;
  equal int ~msg:"a second pass finds nothing owed" 3
    (List.length (read_back dirs ~name))

let sweep_failure_is_narrated () =
  with_estate "sweep" @@ fun ~env ~dirs ~said ~await ->
  let name = "pr-review" in
  let identity = "github:acme/widgets#2@def5678:opened" in
  let loaded = loaded_of dirs ~name ~enabled:true in
  append dirs ~name (spawned ~at:1. ~identity ~digest:"d1" "run-open");
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Error "no read token")
    loaded;
  let recovered () =
    List.exists
      (fun (r : Receipt.t) ->
        match r.Receipt.kind with
        | Receipt.Kind.Disposition (Receipt.Disposition.Reaped { cause; _ }) ->
            Receipt.Cause.equal cause Receipt.Cause.Recovered
        | _ -> false)
      (read_back dirs ~name)
  in
  await ~msg:"the watched pending run settles" recovered;
  equal bool ~msg:"the pending run settles despite the repo failure" true
    (recovered ());
  equal bool ~msg:"the repo failure is narrated, never raised" true
    (List.exists
       (fun line ->
         String.length line > 0
         &&
         match String.index_opt line ':' with
         | Some _ -> String.ends_with ~suffix:"no read token" line
         | None -> false)
       !said)

(* The crash window between a reap and its alert: a reaped disposition in
   the failure class with no identity-scoped alert is repaired on the next
   pass, once — the receipt-log dedup makes the repair idempotent — while
   settled clean exits and the stop path's interrupted heads stay silent. *)
let lost_alert_is_repaired () =
  with_estate "repair" @@ fun ~env ~dirs ~said:_ ~await:_ ->
  let name = "pr-review" in
  let failed = "github:acme/widgets#3@abc9999:head" in
  let stopped = "github:acme/widgets#4@abcaaaa:head" in
  let clean = "github:acme/widgets#5@abcbbbb:head" in
  let loaded = loaded_of dirs ~name ~enabled:false in
  append dirs ~name
    (reaped ~exit:255 ~head:Receipt.Head.Missing ~identity:failed ~digest:"d1"
       "s-f");
  append dirs ~name
    (reaped ~exit:130 ~head:Receipt.Head.Interrupted ~identity:stopped
       ~digest:"d1" "s-s");
  append dirs ~name (reaped ~identity:clean ~digest:"d1" "s-c");
  let repo_for _ = fail "a disabled charter must not build a repo" in
  Charter_reconcile.reconcile env ~repo_for loaded;
  let receipts = read_back dirs ~name in
  equal int ~msg:"exactly the failed reap is repaired with an alert" 1
    (count is_alert receipts);
  equal bool ~msg:"the repaired alert names the failed identity" true
    (Receipt.alerted ~digest:"d1" ~identity:failed
       ~transition:Receipt.Transition.Failed receipts);
  Charter_reconcile.reconcile env ~repo_for loaded;
  equal int ~msg:"the repair is idempotent across passes" 1
    (count is_alert (read_back dirs ~name))

(* The delivery re-drive: an admitted delivery with no disposition is
   rebuilt from its receipt and driven through the ordinary dispose — here
   to a superseded close off the injected current-head read — while records
   the pipeline cannot re-enter close as skipped. *)
let open_delivery_redrives () =
  with_estate "redrive" @@ fun ~env ~dirs ~said:_ ~await:_ ->
  let name = "pr-review" in
  let ev = event () in
  let identity = Event.Identity.to_string (Event.Identity.of_pull_request ev) in
  let loaded = loaded_of dirs ~name ~enabled:true in
  append dirs ~name (delivery ~identity ~digest:"d1" (admitted_fields ev));
  let moved_on = String.make 40 'b' in
  let repo =
    fake_repo ~current_head:(fun ~number:_ -> Ok moved_on) ()
  in
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Ok repo) loaded;
  let receipts = read_back dirs ~name in
  equal int ~msg:"the re-driven delivery reaches its disposition" 1
    (count
       (fun (r : Receipt.t) ->
         match r.Receipt.kind with
         | Receipt.Kind.Disposition Receipt.Disposition.Superseded -> true
         | _ -> false)
       receipts);
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Ok repo) loaded;
  equal int ~msg:"a disposed delivery is not re-driven again"
    (List.length receipts)
    (List.length (read_back dirs ~name))

let unreconstructable_deliveries_close () =
  with_estate "close" @@ fun ~env ~dirs ~said:_ ~await:_ ->
  let name = "pr-review" in
  let ev = event () in
  let identity = Event.Identity.to_string (Event.Identity.of_pull_request ev) in
  let loaded = loaded_of dirs ~name ~enabled:true in
  (* A pre-upgrade line without the members, and a policy edit's retired
     digest. *)
  append dirs ~name (delivery ~identity ~digest:"d1" None);
  append dirs ~name
    (delivery ~identity:"github:acme/widgets#9@abc1111:head"
       ~digest:"feedfacefeedface"
       (admitted_fields (event ~number:9 ())));
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Ok (fake_repo ()))
    loaded;
  let receipts = read_back dirs ~name in
  equal int ~msg:"the memberless line closes as unreconstructable" 1
    (count (is_skipped "unreconstructable delivery record") receipts);
  equal int ~msg:"the retired digest closes as superseded by the edit" 1
    (count (is_skipped "superseded by a policy edit") receipts);
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Ok (fake_repo ()))
    loaded;
  equal int ~msg:"closed records stay closed" (List.length receipts)
    (List.length (read_back dirs ~name))

let disabled_deliveries_close () =
  with_estate "disabled" @@ fun ~env ~dirs ~said:_ ~await:_ ->
  let name = "pr-review" in
  let ev = event () in
  let identity = Event.Identity.to_string (Event.Identity.of_pull_request ev) in
  let loaded = loaded_of dirs ~name ~enabled:false in
  append dirs ~name (delivery ~identity ~digest:"d1" (admitted_fields ev));
  Charter_reconcile.reconcile env
    ~repo_for:(fun _ -> fail "a disabled charter must not build a repo")
    loaded;
  equal int ~msg:"a disabled charter's open delivery closes as skipped" 1
    (count (is_skipped "disabled") (read_back dirs ~name))

(* The settled-no-findings close: a settled run whose log carries no
   findings document must not re-enter the publisher forever — the sweep's
   republish row alerts (the recovered path never had) and stamps a
   none-needed egress, and the next pass finds the record complete. *)
let settled_without_findings_closes () =
  with_estate "no-findings" @@ fun ~env ~dirs ~said:_ ~await:_ ->
  let name = "pr-review" in
  let ev = event () in
  let id = Event.Identity.of_pull_request ev in
  let identity = Event.Identity.to_string id in
  let loaded = loaded_of dirs ~name ~enabled:true in
  claim dirs ~name ~digest:"d1" id;
  append dirs ~name (spawned ~identity ~digest:"d1" "run-settled");
  append dirs ~name
    (reaped ~cause:Receipt.Cause.Recovered ~identity ~digest:"d1"
       "run-settled");
  let repo =
    fake_repo
      ~open_prs:(fun () ->
        Ok
          [
            {
              Charter_fire.Github.number = 7;
              head_sha;
              base_ref = "main";
              draft = false;
              author_association = "OWNER";
            };
          ])
      ()
  in
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Ok repo) loaded;
  let receipts = read_back dirs ~name in
  equal int ~msg:"the recovered settle's lost alert fires" 1
    (count is_alert receipts);
  equal int ~msg:"a none-needed egress closes the record" 1
    (count is_egress receipts);
  Charter_reconcile.reconcile env ~repo_for:(fun _ -> Ok repo) loaded;
  equal int ~msg:"the closed record re-enters nothing" (List.length receipts)
    (List.length (read_back dirs ~name))

(* The one-pass gate: the after-reap re-entry tries the gate and yields to
   a pass in flight instead of parking its caller; a freed gate admits the
   next re-entry. *)
let reentry_yields_to_a_pass () =
  with_estate "gate" @@ fun ~env ~dirs ~said:_ ~await:_ ->
  let loaded = loaded_of dirs ~name:"pr-review" ~enabled:true in
  let order = ref [] in
  let note tag = order := tag :: !order in
  let release, resolve = Eio.Promise.create () in
  Eio.Fiber.all
    [
      (fun () ->
        Charter_reconcile.reconcile env
          ~repo_for:(fun _ ->
            note "first enters";
            Eio.Promise.await release;
            note "first leaves";
            Error "no read token")
          loaded);
      (fun () ->
        Charter_reconcile.reconcile env
          ~repo_for:(fun _ ->
            note "second enters";
            Error "no read token")
          loaded;
        note "second returned");
      (fun () -> Eio.Promise.resolve resolve ());
    ];
  equal
    (Testable.list Testable.string)
    ~msg:"a held gate is yielded to, never waited on"
    [ "first enters"; "second returned"; "first leaves" ]
    (List.rev !order);
  Charter_reconcile.reconcile env
    ~repo_for:(fun _ ->
      note "third enters";
      Error "no read token")
    loaded;
  equal bool ~msg:"a freed gate admits the next re-entry" true
    (List.mem "third enters" !order)

let () =
  run "mentat.charter_reconcile"
    [
      test "an orphaned run settles honestly" orphan_settles;
      test "a repo failure narrates and never raises" sweep_failure_is_narrated;
      test "a lost failure alert is repaired once" lost_alert_is_repaired;
      test "an open delivery re-drives through dispose" open_delivery_redrives;
      test "unreconstructable deliveries close as skipped"
        unreconstructable_deliveries_close;
      test "a disabled charter closes its open deliveries"
        disabled_deliveries_close;
      test "a settled run without findings closes"
        settled_without_findings_closes;
      test "the re-entry yields to a pass in flight" reentry_yields_to_a_pass;
    ]
