(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Mentat_broker]'s send and root supervision, over a real
   store in a fresh temp root. The send half: the fence-first append twin,
   its recorded-enqueue dedup, the custodial-hold patience, the loud
   refusals. The supervision half: the real interpretation loop — spawn,
   reap, respawn budget, deadline, the bounded hold — driven through the
   spawn resolver seam (a trivial system binary stands in for the
   activation, and the test settles the journal where the activation would),
   plus the un-owning watch. The wire arm and a real served activation live
   in the blackbox subagent suite; the pure decision tables are
   [test_reconcile]'s. *)

open Windtrap
module Broker = Mentat_broker
module Store = Mentat_store
module Session = Mentat_session
module Llm = Mentat_llm

(* POSIX record locks are per process, so a fence probe can only see a
   foreign holder from a second process. This private executable mode gives
   the boot-race tests a genuine one: it locks the given run.lock, writes its
   own owner line under the serving label — the fence exactly as a
   frontend-served winner leaves it — and holds until its stdin closes. *)
let fence_holder_mode = "--broker-fence-holder"

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) fence_holder_mode
  then begin
    let fd =
      Unix.openfile Sys.argv.(2)
        [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
        0o600
    in
    Unix.lockf fd Unix.F_LOCK 0;
    (match
       Jsont_bytesrw.encode_string Mentat_store.Run_lock.Owner.jsont
         (Mentat_store.Run_lock.Owner.make ~label:Mentat_broker.serve_owner_label
            ())
     with
    | Error message ->
        prerr_endline message;
        exit 2
    | Ok text ->
        let line = text ^ "\n" in
        Unix.ftruncate fd 0;
        let (_ : int) =
          Unix.write_substring fd line 0 (String.length line)
        in
        ());
    print_endline "ready";
    (match input_char stdin with _ -> () | exception End_of_file -> ());
    Unix.lockf fd Unix.F_ULOCK 0;
    Unix.close fd;
    exit 0
  end

let sid = Session.Id.of_string
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)

let rec waitpid_nointr pid =
  match Unix.waitpid [] pid with
  | waited, status -> (waited, status)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid

type fence_holder = { holder_pid : int; holder_stdin : out_channel }

(* Start the holder and return once it owns the lock; releasing closes its
   stdin and reaps it. Liveness is read with [WNOHANG] — a signalled child
   is a zombie until reaped, so a bare [kill 0] could not tell the two
   apart. *)
let start_fence_holder ~lock_path =
  let child_stdin, parent_stdin = Unix.pipe ~cloexec:true () in
  let parent_stdout, child_stdout = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; fence_holder_mode; lock_path |]
      child_stdin child_stdout Unix.stderr
  in
  Unix.close child_stdin;
  Unix.close child_stdout;
  let input = Unix.in_channel_of_descr parent_stdout in
  let holder_stdin = Unix.out_channel_of_descr parent_stdin in
  (match input_line input with
  | "ready" -> ()
  | line -> failf "unexpected fence-holder greeting: %s" line
  | exception End_of_file -> fail "the fence holder exited before readiness");
  close_in_noerr input;
  { holder_pid = pid; holder_stdin }

let holder_running holder =
  match Unix.waitpid [ Unix.WNOHANG ] holder.holder_pid with
  | 0, _ -> true
  | _, _ -> false
  | exception Unix.Unix_error _ -> false

let release_fence_holder holder =
  close_out_noerr holder.holder_stdin;
  match waitpid_nointr holder.holder_pid with
  | _ -> ()
  | exception Unix.Unix_error _ -> ()

let run_lock_path ~base ~id =
  List.fold_left Filename.concat base [ "sessions"; id; "run.lock" ]

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let ok_open msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Error.pp error

let ok_store msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Session.Error.pp error

(* One broker over one fresh store root; the socket base and log dir are
   scratch, and the default spawn resolver refuses — a supervision test
   passes its own [?resolve_bin]. A test that binds a socket under the base
   supplies its own short [?socket_base]: the scratch root is too deep for
   the [sun_path] budget. *)
let with_broker ?socket_base ?resolve_bin name fn =
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
  let resolve_bin =
    match resolve_bin with
    | Some resolve -> resolve
    | None -> fun () -> Error "the unit tier spawns nothing"
  in
  let broker =
    Broker.create ~sw ~stdenv:env ~store ~resolve_bin ~socket_base
      ~log_dir:(Filename.concat base "log")
      ~now:(fun () -> time 2_000)
  in
  let finally () = Broker.stop broker in
  Fun.protect ~finally (fun () ->
      fn ~sw ~base ~clock ~store ~broker ~socket_base)

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
  with_broker "dormant" @@ fun ~sw:_ ~base:_ ~clock:_ ~store ~broker ~socket_base:_ ->
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
  with_broker "dedup" @@ fun ~sw:_ ~base:_ ~clock:_ ~store ~broker ~socket_base:_ ->
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
  with_broker "custodial" @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
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
  with_broker "held" @@ fun ~sw:_ ~base:_ ~clock:_ ~store ~broker ~socket_base:_ ->
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
  | `Undelivered reason -> (
      is_true ~msg:"the refusal names the holder"
        (String.starts_with ~prefix:"the target's fence is held by pid" reason);
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
  @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base ->
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
  with_broker "order" @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
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
  with_broker "refusals" @@ fun ~sw:_ ~base:_ ~clock:_ ~store ~broker ~socket_base:_ ->
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

(* The backlog cap runs at admission under the target's fence: the cap-th
   unconsumed entry from one sender lands, the next is a loud undelivered
   answer that commits nothing, and the owner's mail stays uncapped through
   the same full mailbox. *)
let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    i + lsub <= ls && (String.equal (String.sub s i lsub) sub || go (i + 1))
  in
  go 0

let a_full_mailbox_is_a_loud_send_failure () =
  with_broker "backlog" @@ fun ~sw:_ ~base:_ ~clock:_ ~store ~broker ~socket_base:_ ->
  create_root store ~id:"parent";
  create_child store ~id:"child" ~parent:"parent";
  let origin = Session.Origin.agent (sid "parent") in
  for i = 1 to Session.mail_backlog_cap do
    match
      Broker.send broker ~origin ~target:(sid "child")
        ~id:(qid (Printf.sprintf "q-%d" i))
        ~input:(text "ping") ()
    with
    | `Delivered -> ()
    | `Undelivered reason -> failf "send %d undelivered: %s" i reason
  done;
  let events = event_count store ~id:"child" in
  (match
     Broker.send broker ~origin ~target:(sid "child") ~id:(qid "q-over")
       ~input:(text "one too many") ()
   with
  | `Delivered -> fail "a full mailbox must refuse the sender"
  | `Undelivered reason ->
      is_true ~msg:"the refusal names the full mailbox"
        (contains_sub ~sub:"mailbox is full" reason));
  equal int ~msg:"the refusal committed nothing" events
    (event_count store ~id:"child");
  match
    Broker.send broker ~target:(sid "child") ~id:(qid "q-owner")
      ~input:(text "owner mail") ()
  with
  | `Delivered -> ()
  | `Undelivered reason -> failf "the owner must never be capped: %s" reason

(* Supervision fixtures. A concluded head is a real settled turn — started,
   one provider round, finished — appended and committed under the session's
   fence, exactly as a driver would leave it. *)

let contract =
  let provider = Llm.Provider.make "openai" in
  let api = Llm.Model.Api.make "responses" in
  let model = Llm.Model.make ~provider ~api ~id:"gpt-5" in
  lazy
    (Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
       ~declarations:[] ~policy:Mentat_permission.Policy.default
       ~review:Mentat_permission.Review_behavior.Enforce
       ~sandbox:(Mentat_sandbox.identity Mentat_sandbox.direct) ())

let settle_with_fence store ~fence ~id =
  let document = ok_store "load" (Store.Session.load store (sid id)) in
  let session = Store.Session.Document.session document in
  let turn =
    Session.Turn.make
      ~id:(Session.Turn.Id.of_string "turn-1")
      ~origin:Session.Turn.Origin.User
      ~input:(Session.Turn.Input.user_text "Go.")
      ~max_steps:8 ~contract:(Lazy.force contract) ()
  in
  let claim =
    Session.Provider_request.Started.make ~turn:(Session.Turn.id turn)
      ~request_digest:(Mentat_digest.string "req-1")
  in
  let response =
    Llm.Response.make
      ~model:(Llm.Model.make ~provider:(Llm.Provider.make "openai")
                ~api:(Llm.Model.Api.make "responses") ~id:"gpt-5")
      (Llm.Message.Assistant.text "Done.")
  in
  let events =
    [
      Session.Event.turn_started turn;
      Session.Event.provider_requested claim;
      Session.Event.provider_settled
        (Session.Provider_request.Settled.responded
           ~id:(Session.Provider_request.Started.id claim)
           response);
      Session.Event.turn_finished ~turn:(Session.Turn.id turn)
        Session.Turn.Outcome.completed;
    ]
  in
  let appended =
    match Session.append_all events session with
    | Ok session -> session
    | Error e -> failf "append settled turn: %s" (Session.Error.message e)
  in
  ignore
    (ok_store "commit settled turn"
       (Store.Session.commit store ~fence document
          (Session.touch (time 3_000) appended)))

let settle_session ~sw store ~id =
  let guard =
    match
      Store.Run_lock.try_acquire ~sw store ~session:(sid id)
        ~owner:(Store.Run_lock.Owner.make ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  settle_with_fence store ~fence:guard ~id;
  Store.Run_lock.release guard

(* The supervision outcome, awaited with a timeout so a broken arm fails the
   test instead of hanging it. *)
let outcome_sinks () =
  let outcome, resolver = Eio.Promise.create () in
  let on_settled () = ignore (Eio.Promise.try_resolve resolver `Settled) in
  let on_failure failure =
    ignore (Eio.Promise.try_resolve resolver (`Failed failure))
  in
  (outcome, on_settled, on_failure)

let await_outcome clock outcome =
  match
    Eio.Time.with_timeout clock 10.0 @@ fun () ->
    Ok (Eio.Promise.await outcome)
  with
  | Ok answer -> answer
  | Error `Timeout -> fail "the supervision never answered its sink"

(* A SIGTERM counter around the never-signal assertions: if a supervision
   arm ever signalled this process — the fence holder in these tests — the
   count would show it (and without the handler the default disposition
   would kill the runner outright). *)
let with_sigterm_counter fn =
  let terms = ref 0 in
  let previous =
    Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ -> incr terms))
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.signal Sys.sigterm previous))
    (fun () -> fn terms)

(* Every supervise here starts fresh over an ungoverned session, so the
   answer is pinned [`Supervising] at the call site. *)
let supervising = function
  | `Supervising -> ()
  | `Already_governed -> fail "no standing entry governs the session"
  | `Stopped -> fail "the broker is not stopped"

let failed_reason failure = failf "failed: %s" (Broker.failure_message failure)

let a_finished_session_settles_immediately () =
  let resolved = ref 0 in
  with_broker "settle-now"
    ~resolve_bin:(fun () ->
      incr resolved;
      Error "nothing to spawn")
  @@ fun ~sw ~base:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  settle_session ~sw store ~id:"run";
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run") ~environment:[] ~on_settled
       ~on_failure ());
  (match await_outcome clock outcome with
  | `Settled -> ()
  | `Failed failure -> failed_reason failure);
  equal int ~msg:"a concluded session spawns nothing" 0 !resolved

let a_spawned_run_settles_at_its_terminal_head () =
  let resolved = ref 0 in
  let resolver = ref (fun () -> Error "unset") in
  with_broker "spawn-settle" ~resolve_bin:(fun () -> !resolver ())
  @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  (* The resolver runs at the spawn — after the decision read the unfinished
     head — so settling the journal here is exactly the activation doing the
     work; the trivial binary then exits and the reaper's funnel reads the
     settled head. *)
  (resolver :=
     fun () ->
       incr resolved;
       Eio.Switch.run (fun sw -> settle_session ~sw store ~id:"run");
       Ok "/usr/bin/true");
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run") ~environment:[] ~on_settled
       ~on_failure ());
  (match await_outcome clock outcome with
  | `Settled -> ()
  | `Failed failure -> failed_reason failure);
  equal int ~msg:"one spawn served the whole run" 1 !resolved

let respawn_exhaustion_fires_the_failure_sink () =
  let resolved = ref 0 in
  with_broker "exhaust"
    ~resolve_bin:(fun () ->
      incr resolved;
      Ok "/usr/bin/true")
  @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run") ~environment:[] ~respawns:1
       ~on_settled ~on_failure ());
  (match await_outcome clock outcome with
  | `Settled -> fail "a run that never settles must not answer settled"
  | `Failed (Broker.Deadline _) -> fail "no deadline was given"
  | `Failed (Broker.Gave_up reason) ->
      is_true ~msg:"the failure names the unsettled deaths"
        (contains_sub ~sub:"died before settling, 2 times over" reason));
  equal int ~msg:"the budget bounds the spawns" 2 !resolved

let the_deadline_fires_the_ladder_then_the_failure_sink () =
  (* A stand-in activation that ignores its argv and lingers: the deadline's
     ladder must end it. *)
  let dir = Unix.realpath (temp_dir ~prefix:"mb-linger" ()) in
  let script = Filename.concat dir "linger.sh" in
  Out_channel.with_open_bin script (fun oc ->
      Out_channel.output_string oc "#!/bin/sh\nexec sleep 30\n");
  Unix.chmod script 0o700;
  with_broker "deadline" ~resolve_bin:(fun () -> Ok script)
  @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run")
       ~environment:[ ("PATH", "/usr/bin:/bin") ]
       ~deadline_s:0.4 ~respawns:0 ~on_settled ~on_failure ());
  let rec spawned_pid elapsed =
    match Broker.children broker with
    | [ (session, `Spawned pid) ] ->
        is_true ~msg:"the table names the supervised session"
          (Session.Id.equal session (sid "run"));
        pid
    | _ when elapsed > 5.0 -> fail "the spawn never appeared in the table"
    | _ ->
        Eio.Time.sleep clock 0.02;
        spawned_pid (elapsed +. 0.02)
  in
  let pid = spawned_pid 0. in
  (match await_outcome clock outcome with
  | `Settled -> fail "an overdue run must not answer settled"
  | `Failed (Broker.Gave_up reason) ->
      failf "the failure must carry the typed deadline arm, not: %s" reason
  | `Failed (Broker.Deadline deadline) ->
      equal Testable.float_exact ~msg:"the failure carries the clock" 0.4
        deadline);
  match Unix.kill pid 0 with
  | () -> failf "pid %d survived the deadline ladder" pid
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let an_unlabeled_holder_is_observed_never_signalled () =
  with_sigterm_counter @@ fun terms ->
  with_broker "hold-settle" @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  Eio.Switch.run @@ fun hold_sw ->
  let guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "run")
        ~owner:(Store.Run_lock.Owner.make ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  (* Concluded under the hold: the bounded observation reads the terminal
     head and settles without ever touching the holder. *)
  settle_with_fence store ~fence:guard ~id:"run";
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run") ~environment:[] ~on_settled
       ~on_failure ());
  (match await_outcome clock outcome with
  | `Settled -> ()
  | `Failed failure -> failed_reason failure);
  equal int ~msg:"the holder was never signalled" 0 !terms;
  Store.Run_lock.release guard

let a_double_supervise_is_idempotent () =
  with_broker "idempotent" @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  Eio.Switch.run @@ fun hold_sw ->
  let guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "run")
        ~owner:(Store.Run_lock.Owner.make ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run") ~environment:[] ~on_settled
       ~on_failure ());
  (* The second call is a no-op that says so: the standing supervision owns
     the outcome and the second sinks never fire. *)
  let second = ref false in
  (match
     Broker.supervise broker ~session:(sid "run") ~environment:[]
       ~on_settled:(fun () -> second := true)
       ~on_failure:(fun _ -> second := true)
       ()
   with
  | `Already_governed -> ()
  | `Supervising -> fail "the standing entry must be answered as governing"
  | `Stopped -> fail "the broker is not stopped");
  (match Broker.children broker with
  | [ (session, `Observed) ] ->
      is_true ~msg:"one entry governs the session"
        (Session.Id.equal session (sid "run"))
  | rows -> failf "expected one observed row, got %d" (List.length rows));
  settle_with_fence store ~fence:guard ~id:"run";
  (match await_outcome clock outcome with
  | `Settled -> ()
  | `Failed failure -> failed_reason failure);
  Eio.Time.sleep clock 0.1;
  is_false ~msg:"the second supervision's sinks never fire" !second;
  Store.Run_lock.release guard

(* A supervise whose spawned child dies in a lost boot race adopts the winner
   instead of severing it: the exit funnel probes the fence before any
   removal or respawn, and a held serving fence installs an uncharged
   successor that waits — the winner's endpoint is never unlinked, the
   respawn budget is never charged, no signal is ever sent, and no failure
   is reported while the work is running. Once the winner releases, the
   ordinary spawn drives the session to settlement. *)
let a_lost_boot_race_adopts_the_winner_instead_of_severing () =
  let resolved = ref 0 in
  let resolver = ref (fun () -> Error "unset") in
  let winner = ref None in
  with_broker "adopt" ~resolve_bin:(fun () -> !resolver ())
  @@ fun ~sw:_ ~base ~clock ~store ~broker ~socket_base ->
  create_root store ~id:"run";
  let dir = Broker.socket_dir ~base:socket_base ~session:"run" in
  let socket_path =
    Mentat_server.Bind.socket_path ~dir:(Lpath.Abs.of_string_exn dir)
  in
  (resolver :=
     fun () ->
       incr resolved;
       if !resolved = 1 then begin
         (* The winner takes the fence and binds while our child boots: by
            the time the loser's exit reaches the funnel, the session is
            another process's. A plain file stands in for the endpoint —
            the severing this pins is an unlink by path. *)
         winner := Some (start_fence_holder ~lock_path:(run_lock_path ~base ~id:"run"));
         ensure_dir dir;
         Out_channel.with_open_bin socket_path (fun _ -> ())
       end
       else Eio.Switch.run (fun sw -> settle_session ~sw store ~id:"run");
       Ok "/usr/bin/true")
  ;
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run") ~environment:[] ~respawns:1
       ~on_settled ~on_failure ());
  (* Wait out the loser's spawn, then give the funnel several reaper beats:
     under the fix nothing advances while the winner holds — the old code
     would have respawned to exhaustion and failed the supervision by now. *)
  let rec await_spawn elapsed =
    if !resolved >= 1 then ()
    else if elapsed > 5.0 then fail "the loser never spawned"
    else begin
      Eio.Time.sleep clock 0.05;
      await_spawn (elapsed +. 0.05)
    end
  in
  await_spawn 0.;
  let winner = Option.get !winner in
  Fun.protect ~finally:(fun () -> release_fence_holder winner) @@ fun () ->
  Eio.Time.sleep clock 0.8;
  is_true ~msg:"the winner's endpoint survives the loser's exit"
    (Sys.file_exists socket_path);
  is_true ~msg:"the winner was never signalled" (holder_running winner);
  equal int ~msg:"a held fence charges no respawn" 1 !resolved;
  (match Broker.children broker with
  | [ (_, `Observed) ] -> ()
  | rows ->
      failf "the successor must still govern the session, got %d rows"
        (List.length rows));
  is_false ~msg:"no failure is reported while the work is running"
    (Eio.Promise.is_resolved outcome);
  release_fence_holder winner;
  (match await_outcome clock outcome with
  | `Settled -> ()
  | `Failed failure -> failed_reason failure);
  equal int ~msg:"the successor spawned only after the winner released" 2
    !resolved

(* A serving fence with no endpoint is a booting agent between its
   fence-taking attach and its bind, not a wedged holder: supervision waits
   out the boot patience instead of signalling, and the ordinary spawn
   resumes once the holder releases. *)
let a_booting_holder_is_not_laddered_within_the_bound () =
  let resolver = ref (fun () -> Error "unset") in
  with_broker "boot-patience" ~resolve_bin:(fun () -> !resolver ())
  @@ fun ~sw:_ ~base ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  let holder = start_fence_holder ~lock_path:(run_lock_path ~base ~id:"run") in
  Fun.protect ~finally:(fun () -> release_fence_holder holder) @@ fun () ->
  (resolver :=
     fun () ->
       Eio.Switch.run (fun sw -> settle_session ~sw store ~id:"run");
       Ok "/usr/bin/true");
  let outcome, on_settled, on_failure = outcome_sinks () in
  supervising
    (Broker.supervise broker ~session:(sid "run") ~environment:[] ~on_settled
       ~on_failure ());
  (* Long past the old immediate preempt, well inside the boot wait. *)
  Eio.Time.sleep clock 1.2;
  is_true ~msg:"the booting holder is alive and unsignalled"
    (holder_running holder);
  is_false ~msg:"the supervision is patient, not failed"
    (Eio.Promise.is_resolved outcome);
  release_fence_holder holder;
  match await_outcome clock outcome with
  | `Settled -> ()
  | `Failed failure -> failed_reason failure

(* The serve verb's arms. Unlike supervision it spawns for a settled session
   too — a resume needs a socket regardless of the head — so a boot death
   over a settled journal both proves the spawn and pins the refusal naming
   the child's log. *)
let the_serve_verb_spawns_even_settled_and_names_the_boot_log () =
  let dir = Unix.realpath (temp_dir ~prefix:"mb-serve-die" ()) in
  let script = Filename.concat dir "die.sh" in
  Out_channel.with_open_bin script (fun oc ->
      Out_channel.output_string oc "#!/bin/sh\nexit 1\n");
  Unix.chmod script 0o700;
  with_broker "serve-die" ~resolve_bin:(fun () -> Ok script)
  @@ fun ~sw ~base:_ ~clock:_ ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  settle_session ~sw store ~id:"run";
  match
    Broker.serve broker ~session:(sid "run")
      ~environment:[ ("PATH", "/usr/bin:/bin") ]
      ()
  with
  | `Serving -> fail "a dying boot must not answer serving"
  | `Refused reason ->
      let marker = "exited during boot; see " in
      is_true ~msg:"the refusal names the boot death"
        (contains_sub ~sub:marker reason);
      let rec path_after i =
        if i + String.length marker > String.length reason then
          fail "the refusal names no log path"
        else if String.equal (String.sub reason i (String.length marker)) marker
        then
          String.sub reason
            (i + String.length marker)
            (String.length reason - i - String.length marker)
        else path_after (i + 1)
      in
      is_true ~msg:"the named log file exists"
        (Sys.file_exists (path_after 0))

let the_serve_verb_dials_a_bound_listener_without_spawning () =
  let socket_base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "mbs-%d" (Unix.getpid ()))
  in
  let resolved = ref 0 in
  with_broker ~socket_base "serve-bound"
    ~resolve_bin:(fun () ->
      incr resolved;
      Error "poison")
  @@ fun ~sw:_ ~base:_ ~clock:_ ~store ~broker ~socket_base ->
  create_root store ~id:"run";
  let dir = Broker.socket_dir ~base:socket_base ~session:"run" in
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
  (match Broker.serve broker ~session:(sid "run") ~environment:[] () with
  | `Serving -> ()
  | `Refused reason -> failf "an answering endpoint refused: %s" reason);
  equal int ~msg:"an answering endpoint spawns nothing" 0 !resolved

let an_unlabeled_holder_refuses_the_serve_after_a_brief_patience () =
  with_broker "serve-held"
  @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  Eio.Switch.run @@ fun hold_sw ->
  let guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "run")
        ~owner:(Store.Run_lock.Owner.make ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  let started = Eio.Time.now clock in
  (match Broker.serve broker ~session:(sid "run") ~environment:[] () with
  | `Serving -> fail "an unreachable interactive holder must refuse"
  | `Refused reason ->
      is_true ~msg:"the refusal names the driving holder"
        (contains_sub ~sub:"the session is driven by" reason));
  is_true ~msg:"the brief patience elapsed before the refusal"
    (Eio.Time.now clock -. started >= 1.9);
  Store.Run_lock.release guard

(* A serving-labeled fence with no listener is a booting agent, not a wedged
   one: the serve waits — past the unlabeled arm's two-second refusal — and
   proceeds the moment the holder releases. *)
let a_booting_serving_fence_is_waited_on_not_refused () =
  with_broker "serve-wait"
  @@ fun ~sw:_ ~base ~clock ~store ~broker ~socket_base:_ ->
  create_root store ~id:"run";
  let holder = start_fence_holder ~lock_path:(run_lock_path ~base ~id:"run") in
  Fun.protect ~finally:(fun () -> release_fence_holder holder) @@ fun () ->
  let answer = ref None in
  Eio.Fiber.both
    (fun () ->
      answer := Some (Broker.serve broker ~session:(sid "run") ~environment:[] ()))
    (fun () ->
      Eio.Time.sleep clock 3.0;
      is_true ~msg:"the boot wait outlasts the unlabeled arm's refusal"
        (Option.is_none !answer);
      is_true ~msg:"the booting holder is alive and unsignalled"
        (holder_running holder);
      release_fence_holder holder);
  match !answer with
  | Some (`Refused reason) ->
      is_true ~msg:"the released fence let the serve reach its spawn"
        (contains_sub ~sub:"spawns nothing" reason)
  | Some `Serving -> fail "nothing binds an endpoint in this fixture"
  | None -> fail "the serve never answered"

let the_watch_reports_a_settlement () =
  with_sigterm_counter @@ fun terms ->
  with_broker "watch-settle" @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_
    ->
  create_root store ~id:"run";
  Eio.Switch.run @@ fun hold_sw ->
  let guard =
    match
      Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "run")
        ~owner:(Store.Run_lock.Owner.make ())
    with
    | Ok guard -> guard
    | Error _ -> fail "the fixture could not take the fence"
  in
  let observation, resolver = Eio.Promise.create () in
  Broker.watch broker ~session:(sid "run") ~on_terminal:(fun terminal ->
      ignore (Eio.Promise.try_resolve resolver terminal));
  settle_with_fence store ~fence:guard ~id:"run";
  (match
     Eio.Time.with_timeout clock 10.0 @@ fun () ->
     Ok (Eio.Promise.await observation)
   with
  | Ok `Settled -> ()
  | Ok `Holder_died -> fail "a settled head must report settled"
  | Ok `Gone -> fail "the session exists"
  | Error `Timeout -> fail "the watch never fired");
  equal int ~msg:"the watch never signals" 0 !terms;
  Store.Run_lock.release guard

let the_watch_reports_a_holder_death () =
  with_broker "watch-death" @@ fun ~sw:_ ~base:_ ~clock ~store ~broker ~socket_base:_
    ->
  create_root store ~id:"run";
  let observation, resolver = Eio.Promise.create () in
  Eio.Switch.run (fun hold_sw ->
      let _guard =
        match
          Store.Run_lock.try_acquire ~sw:hold_sw store ~session:(sid "run")
            ~owner:(Store.Run_lock.Owner.make ())
        with
        | Ok guard -> guard
        | Error _ -> fail "the fixture could not take the fence"
      in
      Broker.watch broker ~session:(sid "run") ~on_terminal:(fun terminal ->
          ignore (Eio.Promise.try_resolve resolver terminal));
      (* Hold across one probe beat, then let the switch release the fence
         with the work unfinished — the holder died. *)
      Eio.Time.sleep clock 0.2);
  (match
     Eio.Time.with_timeout clock 10.0 @@ fun () ->
     Ok (Eio.Promise.await observation)
   with
  | Ok `Holder_died -> ()
  | Ok `Settled -> fail "unfinished work must not report settled"
  | Ok `Gone -> fail "the session exists"
  | Error `Timeout -> fail "the watch never fired")

(* The boot residue sweep claims a leaf for every stored session — a live
   root agent (a routine run, a served root) binds its leaf in the same
   tree as a delegated child, and a boot must not sever it. A leaf no
   session answers to is residue and is removed. *)
let sweep_keeps_a_stored_sessions_leaf () =
  with_broker "sweep"
  @@ fun ~sw:_ ~base ~clock:_ ~store ~broker ~socket_base ->
  create_root store ~id:"run";
  let leaf id = Broker.socket_dir ~base:socket_base ~session:id in
  let rec ensure_dir path =
    if not (Sys.file_exists path) then begin
      ensure_dir (Filename.dirname path);
      Unix.mkdir path 0o700
    end
  in
  ensure_dir (leaf "run");
  ensure_dir (leaf "ghost");
  (* A session this binary cannot decode still exists: existence, not
     decodability, claims the leaf — the upgrade window where an older
     sweeper meets newer documents must not sever a live agent. *)
  let broken_dir =
    List.fold_left Filename.concat base [ "sessions"; "broken" ]
  in
  ensure_dir broken_dir;
  Out_channel.with_open_bin (Filename.concat broken_dir "session.json")
    (fun oc -> Out_channel.output_string oc "{not json");
  ensure_dir (leaf "broken");
  Broker.sweep_endpoints broker;
  is_true ~msg:"the live root's endpoint leaf survives the sweep"
    (Sys.file_exists (leaf "run"));
  is_true ~msg:"an undecodable session's leaf survives the sweep"
    (Sys.file_exists (leaf "broken"));
  is_false ~msg:"a leaf no session answers to is removed as residue"
    (Sys.file_exists (leaf "ghost"))

let the_watch_reports_a_missing_session () =
  with_broker "watch-gone" @@ fun ~sw:_ ~base:_ ~clock ~store:_ ~broker ~socket_base:_
    ->
  let observation, resolver = Eio.Promise.create () in
  Broker.watch broker ~session:(sid "never-created")
    ~on_terminal:(fun terminal ->
      ignore (Eio.Promise.try_resolve resolver terminal));
  match
    Eio.Time.with_timeout clock 10.0 @@ fun () ->
    Ok (Eio.Promise.await observation)
  with
  | Ok `Gone -> ()
  | Ok (`Settled | `Holder_died) -> fail "a missing session is gone"
  | Error `Timeout -> fail "the watch never fired"

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
          test "a full mailbox is a loud send failure"
            a_full_mailbox_is_a_loud_send_failure;
        ];
      group "supervision"
        [
          test "a finished session settles immediately"
            a_finished_session_settles_immediately;
          test "a spawned run settles at its terminal head"
            a_spawned_run_settles_at_its_terminal_head;
          test "respawn exhaustion fires the failure sink"
            respawn_exhaustion_fires_the_failure_sink;
          test "the deadline fires the ladder then the failure sink"
            the_deadline_fires_the_ladder_then_the_failure_sink;
          test "an unlabeled holder is observed, never signalled"
            an_unlabeled_holder_is_observed_never_signalled;
          test "a double supervise is idempotent"
            a_double_supervise_is_idempotent;
          test "a lost boot race adopts the winner instead of severing"
            a_lost_boot_race_adopts_the_winner_instead_of_severing;
          test "a booting holder is not laddered within the bound"
            a_booting_holder_is_not_laddered_within_the_bound;
        ];
      group "the serve verb"
        [
          test "it spawns even settled and names the boot log"
            the_serve_verb_spawns_even_settled_and_names_the_boot_log;
          test "it dials a bound listener without spawning"
            the_serve_verb_dials_a_bound_listener_without_spawning;
          test "an unlabeled holder refuses after a brief patience"
            an_unlabeled_holder_refuses_the_serve_after_a_brief_patience;
          test "a booting serving fence is waited on, not refused"
            a_booting_serving_fence_is_waited_on_not_refused;
        ];
      group "the watch"
        [
          test "the watch reports a settlement" the_watch_reports_a_settlement;
          test "the watch reports a holder death"
            the_watch_reports_a_holder_death;
          test "the watch reports a missing session"
            the_watch_reports_a_missing_session;
        ];
      group "the residue sweep"
        [
          test "a stored session's endpoint leaf survives the sweep"
            sweep_keeps_a_stored_sessions_leaf;
        ];
    ]
