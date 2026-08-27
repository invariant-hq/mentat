(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Mentat_broker.send], the mail primitive, over a real store
   in a fresh temp root: the fence-first append twin, its recorded-enqueue
   dedup, the custodial-hold patience, the loud refusals. The wire arm — a
   fence held by a live per-session server — needs a real serve-session
   process and lives in the blackbox subagent suite. The supervision half's
   pure tables are [test_reconcile]'s. *)

open Windtrap
module Broker = Mentat_broker
module Store = Mentat_store
module Session = Mentat_session
module Llm = Mentat_llm

let sid = Session.Id.of_string
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)

let ok_open msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Error.pp error

let ok_store msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Session.Error.pp error

(* One broker over one fresh store root; the socket base and log dir are
   scratch, and the spawn resolver refuses — nothing here materializes. A
   test that binds a socket under the base supplies its own short
   [?socket_base]: the scratch root is too deep for the [sun_path] budget. *)
let with_broker ?socket_base name fn =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  let base = Unix.realpath (temp_dir ~prefix:("mb-" ^ name) ()) in
  Eio.Switch.run @@ fun sw ->
  let store =
    ok_open "open store" (Store.open_ ~sw (Eio.Path.( / ) fs base))
  in
  let socket_base =
    match socket_base with
    | Some dir -> dir
    | None -> Filename.concat base "sock"
  in
  let broker =
    Broker.create ~sw ~stdenv:env ~store
      ~resolve_bin:(fun () -> Error "the unit tier spawns nothing")
      ~socket_base
      ~log_dir:(Filename.concat base "log")
      ~now:(fun () -> time 2_000)
  in
  let finally () = Broker.stop broker in
  Fun.protect ~finally (fun () -> fn ~sw ~clock ~store ~broker ~socket_base)

let create_root store ~id =
  ignore
    (ok_store "create root"
       (Store.Session.create store
          (Session.create ~id:(sid id)
             ~cwd:(Lpath.Abs.of_string_exn "/tmp")
             ~created_at:(time 1_000) ())))

let create_child store ~id ~parent =
  let delegated_from =
    Session.Metadata.Delegated_from.make ~parent:(sid parent)
      ~delegation:(Session.Delegation.Id.of_string "d-1")
  in
  ignore
    (ok_store "create child"
       (Store.Session.create store
          (Session.create ~id:(sid id) ~delegated_from
             ~cwd:(Lpath.Abs.of_string_exn "/tmp")
             ~created_at:(time 1_000) ())))

let pending store ~id =
  let document = ok_store "load" (Store.Session.load store (sid id)) in
  Session.State.pending_queue
    (Session.state (Store.Session.Document.session document))

let event_count store ~id =
  let document = ok_store "load" (Store.Session.load store (sid id)) in
  List.length (Session.events (Store.Session.Document.session document))

let qid = Session.Queue.Id.of_string
let text body = [ Llm.Content.text body ]

let a_send_to_a_dormant_session_lands_durably () =
  with_broker "dormant" @@ fun ~sw:_ ~clock:_ ~store ~broker ~socket_base:_ ->
  create_root store ~id:"parent";
  create_child store ~id:"child" ~parent:"parent";
  let origin = Session.Origin.agent (sid "parent") in
  (match
     Broker.send broker ~origin ~target:(sid "child") ~id:(qid "q-mail")
       ~input:(text "extra context") ()
   with
  | `Delivered -> ()
  | `Undelivered reason -> failf "undelivered: %s" reason);
  (match pending store ~id:"child" with
  | [ entry ] ->
      is_true ~msg:"the entry carries the derived id"
        (Session.Queue.Id.equal (Session.Queue.Entry.id entry) (qid "q-mail"));
      (match Session.Queue.Entry.origin entry with
      | Some (Session.Origin.Agent sender) ->
          is_true ~msg:"the origin names the sender"
            (Session.Id.equal sender (sid "parent"))
      | Some (Session.Origin.Trigger _) | None ->
          fail "the entry must carry the sender's origin")
  | entries -> failf "expected one pending entry, got %d" (List.length entries));
  (* Durable means committed and released: the fence is free again. *)
  match Store.Run_lock.holder store ~session:(sid "child") with
  | `Free -> ()
  | `Held _ | `Io _ -> fail "the send must release the fence"

let a_repeated_send_is_idempotent () =
  with_broker "dedup" @@ fun ~sw:_ ~clock:_ ~store ~broker ~socket_base:_ ->
  create_root store ~id:"parent";
  create_child store ~id:"child" ~parent:"parent";
  let origin = Session.Origin.agent (sid "parent") in
  let send () =
    Broker.send broker ~origin ~target:(sid "child") ~id:(qid "q-mail")
      ~input:(text "extra context") ()
  in
  (match send () with
  | `Delivered -> ()
  | `Undelivered reason -> failf "first send: %s" reason);
  let events = event_count store ~id:"child" in
  (match send () with
  | `Delivered -> ()
  | `Undelivered reason -> failf "repeat send: %s" reason);
  equal int ~msg:"the repeat commits no second fact" events
    (event_count store ~id:"child")

let a_custodial_hold_is_outwaited () =
  with_broker "custodial" @@ fun ~sw:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"parent";
  create_child store ~id:"child" ~parent:"parent";
  (* A concurrent custodial hold (another send mid-append): the loop re-probes
     and delivers once the hold releases — never a failure. *)
  Eio.Switch.run @@ fun hold_sw ->
  let guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "child")
        ~owner:(Store.Run_lock.Owner.make ~label:Broker.send_owner_label ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  Eio.Fiber.both
    (fun () ->
      (* Release after a beat, from a sibling fiber. *)
      Eio.Time.sleep clock 0.2;
      Store.Run_lock.release guard)
    (fun () ->
      match
        Broker.send broker
          ~origin:(Session.Origin.agent (sid "parent"))
          ~target:(sid "child") ~id:(qid "q-mail")
          ~input:(text "patient mail") ()
      with
      | `Delivered -> ()
      | `Undelivered reason -> failf "undelivered: %s" reason);
  match pending store ~id:"child" with
  | [ _ ] -> ()
  | entries -> failf "expected one pending entry, got %d" (List.length entries)

let an_unlabeled_holder_bounds_the_send () =
  with_broker "held" @@ fun ~sw:_ ~clock:_ ~store ~broker ~socket_base:_ ->
  create_root store ~id:"parent";
  create_child store ~id:"child" ~parent:"parent";
  Eio.Switch.run @@ fun hold_sw ->
  let _guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "child")
        ~owner:(Store.Run_lock.Owner.make ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  match
    Broker.send broker
      ~origin:(Session.Origin.agent (sid "parent"))
      ~budget_s:0.2 ~target:(sid "child") ~id:(qid "q-mail")
      ~input:(text "never lands") ()
  with
  | `Delivered -> fail "an unlabeled holder must not be dialed or preempted"
  | `Undelivered _ -> (
      match pending store ~id:"child" with
      | [] -> ()
      | _ -> fail "nothing may land while a foreign driver holds the fence")

(* The budget bounds the send in wall time. A serving-label holder whose
   socket accepts the OS connect but never answers the handshake burns real
   seconds per dial, so a budget that only counted the loop's sleeps would
   let one send run budget/backoff passes of the grace. The loop must end
   within roughly the budget, each dial capped at what remains of it. *)
let the_budget_bounds_wall_time_against_a_wedged_server () =
  let socket_base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "mbw-%d" (Unix.getpid ()))
  in
  with_broker ~socket_base "wedged"
  @@ fun ~sw:_ ~clock ~store ~broker ~socket_base ->
  create_root store ~id:"parent";
  create_child store ~id:"child" ~parent:"parent";
  Eio.Switch.run @@ fun hold_sw ->
  let _guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "child")
        ~owner:(Store.Run_lock.Owner.make ~label:Broker.serve_owner_label ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  let dir = Broker.socket_dir ~base:socket_base ~session:"child" in
  let rec ensure_dir path =
    if not (Sys.file_exists path) then begin
      ensure_dir (Filename.dirname path);
      Unix.mkdir path 0o700
    end
  in
  ensure_dir dir;
  let socket_path =
    Mentat_server.Bind.socket_path ~dir:(Lpath.Abs.of_string_exn dir)
  in
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let finally () = try Unix.close listener with Unix.Unix_error _ -> () in
  Fun.protect ~finally @@ fun () ->
  Unix.bind listener (Unix.ADDR_UNIX socket_path);
  Unix.listen listener 1;
  let started = Eio.Time.now clock in
  (match
     Broker.send broker
       ~origin:(Session.Origin.agent (sid "parent"))
       ~budget_s:0.5 ~target:(sid "child") ~id:(qid "q-mail")
       ~input:(text "never lands") ()
   with
  | `Delivered -> fail "a wedged server must not answer delivered"
  | `Undelivered _ -> ());
  let elapsed = Eio.Time.now clock -. started in
  is_true
    ~msg:"the loop ended within the wall-time budget, not passes of the grace"
    (elapsed < 3.0)

(* Sends to one target land in arrival order: the second sender queues on the
   target's ordering lock while the first is still contending for the fence,
   so the entries commit in acquisition order — the FIFO is the send's own
   contract, never a caller discipline. *)
let racing_sends_commit_in_acquisition_order () =
  with_broker "order" @@ fun ~sw:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"parent";
  create_child store ~id:"child" ~parent:"parent";
  Eio.Switch.run @@ fun hold_sw ->
  let guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "child")
        ~owner:(Store.Run_lock.Owner.make ~label:Broker.send_owner_label ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  let send id body =
    match
      Broker.send broker
        ~origin:(Session.Origin.agent (sid "parent"))
        ~target:(sid "child") ~id:(qid id) ~input:(text body) ()
    with
    | `Delivered -> ()
    | `Undelivered reason -> failf "%s undelivered: %s" id reason
  in
  Eio.Fiber.all
    [
      (fun () ->
        (* Hold the fence long enough that the first sender is provably
           parked in its loop — holding the ordering lock — when the second
           arrives. *)
        Eio.Time.sleep clock 0.2;
        Store.Run_lock.release guard);
      (fun () -> send "q-first" "first");
      (fun () -> send "q-second" "second");
    ];
  match pending store ~id:"child" with
  | [ a; b ] ->
      is_true ~msg:"the first sender's entry landed first"
        (Session.Queue.Id.equal (Session.Queue.Entry.id a) (qid "q-first"));
      is_true ~msg:"the second sender's entry landed second"
        (Session.Queue.Id.equal (Session.Queue.Entry.id b) (qid "q-second"))
  | entries ->
      failf "expected two pending entries, got %d" (List.length entries)

let loud_refusals () =
  with_broker "refusals" @@ fun ~sw:_ ~clock:_ ~store ~broker ~socket_base:_ ->
  create_root store ~id:"parent";
  create_root store ~id:"stranger";
  create_child store ~id:"child" ~parent:"parent";
  (* A sender the target's journal cannot prove is refused, not committed. *)
  (match
     Broker.send broker
       ~origin:(Session.Origin.agent (sid "stranger"))
       ~target:(sid "child") ~id:(qid "q-mail") ~input:(text "psst") ()
   with
  | `Delivered -> fail "an unprovable sender must be refused"
  | `Undelivered _ -> ());
  (* Media is refused before anything is touched. *)
  (match
     Broker.send broker
       ~origin:(Session.Origin.agent (sid "parent"))
       ~target:(sid "child") ~id:(qid "q-media")
       ~input:[ Llm.Content.media ~media_type:"image/png" (`Base64 "aGk=") ]
       ()
   with
  | `Delivered -> fail "inline media must not cross the send"
  | `Undelivered _ -> ());
  (* A target the store does not hold is a loud error. *)
  (match
     Broker.send broker ~target:(sid "missing") ~id:(qid "q-mail")
       ~input:(text "hello") ()
   with
  | `Delivered -> fail "a missing target must not answer delivered"
  | `Undelivered _ -> ());
  equal int ~msg:"no refusal committed anything" 0 (event_count store ~id:"child")

let () =
  run "mentat.broker"
    [
      group "the send"
        [
          test "a send to a dormant session lands durably"
            a_send_to_a_dormant_session_lands_durably;
          test "a repeated send is idempotent" a_repeated_send_is_idempotent;
          test "a custodial hold is outwaited" a_custodial_hold_is_outwaited;
          test "an unlabeled holder bounds the send"
            an_unlabeled_holder_bounds_the_send;
          test "the budget bounds wall time against a wedged server"
            the_budget_bounds_wall_time_against_a_wedged_server;
          test "racing sends commit in acquisition order"
            racing_sends_commit_in_acquisition_order;
          test "loud refusals" loud_refusals;
        ];
    ]
