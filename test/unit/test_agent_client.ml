(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit pins for the frontend's per-session router ([Agent_client]) — the
   session→endpoint resolution and the dormant-start decision. The
   composition is staged for real over a hermetic temp home; a hand-served
   stub endpoint stands in for a live agent, and the one process-shaped
   effect — the broker's spawn — is refused loudly through MENTAT_BIN, so
   an arm that decides to start an agent is visible without any process
   being forked. *)

open Windtrap
module Server = Mentat_server
module Session = Mentat_session
module Driver = Mentat_client.Driver

let sid = Session.Id.of_string
let unavailable message = Error (Mentat_protocol.Error.unavailable message)
let reached_text = "reached the stub endpoint"

(* The stand-in for a live agent's confined driver: any session field the
   router dials answers the marker, so a dial is distinguishable from a
   dormant answer and from a start refusal. [possibly_mutating] answers
   [true] — the opposite of the dormant answer. *)
let stub_driver () : Driver.t =
  let reached () = unavailable reached_text in
  {
    Driver.session =
      {
        Driver.Session.submit = (fun _ -> reached ());
        follow = (fun _ ~from:_ -> reached ());
        answer_unattended = (fun ~session:_ ~decision:_ -> reached ());
        possibly_mutating = (fun ~session:_ -> true);
        faulted = (fun ~session:_ -> None);
        fork = (fun ~session:_ ~into:_ -> reached ());
        rewind = (fun ~session:_ ~into:_ ~anchor:_ -> reached ());
        compact = (fun ~session:_ ~turn:_ -> reached ());
        pending_decision = (fun _ -> reached ());
        running_processes = (fun _ -> reached ());
        change_diff = (fun ~session:_ ~change:_ -> reached ());
        tail = (fun ?n:_ _ -> reached ());
        page = (fun ?n:_ _ ~before:_ -> reached ());
        revert = (fun ~session:_ ~scope:_ -> reached ());
        undo = (fun ~session:_ ~op:_ -> reached ());
        export = (fun ~session:_ -> reached ());
      };
    accounts =
      {
        Driver.Accounts.login = (fun ~provider:_ ~method_:_ -> reached ());
        save_api_key = (fun ~provider:_ ~key:_ -> reached ());
        logout = (fun ?revoke:_ _ -> reached ());
        account_readiness = (fun () -> reached ());
        model_readiness = (fun ?refresh:_ () -> reached ());
      };
    settings =
      {
        Driver.Settings.set_model =
          (fun ~session:_ ?reasoning_effort:_ _ -> reached ());
        set_permission_review = (fun ~session:_ _ -> reached ());
        configuration = (fun () -> reached ());
        set_default_model = (fun ?reasoning_effort:_ _ -> reached ());
        set_ui_theme = (fun ~theme:_ -> reached ());
      };
    lifecycle =
      {
        Driver.Lifecycle.create = (fun ~id:_ ~title:_ -> reached ());
        rename = (fun ~session:_ ~title:_ -> reached ());
        archive = (fun ~session:_ -> reached ());
        restore = (fun ~session:_ -> reached ());
        delete = (fun ~session:_ -> reached ());
        sessions = (fun ~listing:_ -> reached ());
        session = (fun _ -> reached ());
      };
    review =
      {
        Driver.Review.apply = (fun _ -> reached ());
        state = (fun ~scope:_ -> reached ());
        diff = (fun ~path:_ -> reached ());
        crs = (fun () -> reached ());
        compose = (fun _ -> reached ());
      };
    workspace =
      {
        Driver.Workspace.glance = (fun () -> reached ());
        dune = (fun () -> reached ());
        dune_control = (fun ~op:_ -> reached ());
      };
  }

let status_message = function
  | Exit_status.Runtime_error m
  | Exit_status.Usage_error m
  | Exit_status.Blocked m
  | Exit_status.Internal m ->
      m
  | Exit_status.Success -> "ok"
  | Exit_status.Failed -> "failed"
  | Exit_status.Interrupted -> "interrupted"

(* One hermetic home per test, staged through the real [with_base] so the
   router runs over exactly the composition a frontend holds. MENTAT_BIN
   names a non-program: any start decision fails with that exact refusal
   instead of forking. *)
let with_client name fn =
  let base = temp_dir ~prefix:("ac-" ^ name) () in
  let dir leaf = Filename.concat base leaf in
  Unix.putenv "HOME" base;
  Unix.putenv "XDG_DATA_HOME" (dir "data");
  Unix.putenv "XDG_CONFIG_HOME" (dir "config");
  Unix.putenv "XDG_STATE_HOME" (dir "state");
  Unix.putenv "XDG_CACHE_HOME" (dir "cache");
  Unix.putenv "MENTAT_BIN" "/nonexistent/mentat";
  let work = dir "work" in
  Unix.mkdir work 0o755;
  match
    Composition.with_base ~cwd:(Some work) ~overrides:[] (fun t ->
        match Agent_client.client t with
        | Error status ->
            failf "%s: the client did not assemble: %s" name
              (status_message status)
        | Ok client ->
            fn ~t ~client;
            Exit_status.Success)
  with
  | Exit_status.Success -> ()
  | status -> failf "%s: staging failed: %s" name (status_message status)

let leaf_dir t session =
  User_dirs.child_socket_dir (Composition.dirs t)
    ~session:(Session.Id.to_string session)

(* Hand-serve [stub_driver] at [session]'s derived endpoint — where the
   broker's spawn would bind — under [sw]. The handshake echoes whatever
   workspace the dialer requests, as a live agent echoes its own root. *)
let serve_stub t ~sw session =
  let stdenv = Composition.stdenv t in
  let dir = leaf_dir t session in
  Session_endpoint.ensure_socket_parents dir;
  let listener =
    Server.listen ~sw
      ~net:(Eio.Stdenv.net stdenv)
      (Server.Bind.unix ~dir:(Lpath.Abs.of_string_exn dir))
  in
  let driver_for ~workspace ~environment:_ =
    Ok { Server.workspace; driver = stub_driver (); on_close = (fun () -> ()) }
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try Server.serve ~sw ~clock:(Eio.Stdenv.clock stdenv) ~driver_for listener
       with Eio.Cancel.Cancelled _ -> ());
      `Stop_daemon)

let reached ~msg = function
  | Ok _ -> failf "%s: the stub endpoint answers the marker" msg
  | Error (Mentat_protocol.Error.Unavailable text) ->
      equal Testable.string ~msg reached_text (Mentat_diagnostic.message text)
  | Error other ->
      failf "%s: expected the stub marker, got %a" msg Mentat_protocol.Error.pp
        other

let a_serving_endpoint_is_dialed () =
  with_client "dial" @@ fun ~t ~client ->
  let session = sid "ac-dial" in
  is_false ~msg:"a fresh session's endpoint answers no probe"
    (Agent_client.serving t session);
  Eio.Switch.run @@ fun sw ->
  serve_stub t ~sw session;
  is_true ~msg:"the bound endpoint answers the probe"
    (Agent_client.serving t session);
  (* The attach-or-start route dials — a start attempt would answer the
     MENTAT_BIN refusal instead of the stub's marker. *)
  reached ~msg:"tail reaches the endpoint" (Mentat_client.tail client session);
  is_true ~msg:"a live read dials rather than answering dormantly"
    (Mentat_client.possibly_mutating client ~session)

let the_dormant_reads_start_nothing () =
  with_client "dormant" @@ fun ~t ~client ->
  let session = sid "ac-dormant" in
  is_false ~msg:"a dormant session possibly mutates nothing"
    (Mentat_client.possibly_mutating client ~session);
  (match Mentat_client.running_processes client session with
  | Ok [] -> ()
  | Ok _ -> fail "a dormant session runs no processes"
  | Error e -> failf "the dormant answer is Ok []: %a" Mentat_protocol.Error.pp e);
  (match Mentat_client.faulted client ~session with
  | None -> ()
  | Some _ -> fail "a dormant session reports no fault");
  is_false ~msg:"no agent was started for a dormant read"
    (Sys.file_exists (leaf_dir t session))

let the_first_session_call_decides_the_start () =
  with_client "start" @@ fun ~t ~client ->
  let session = sid "ac-start" in
  (match Mentat_client.create client ~id:session () with
  | Ok () -> ()
  | Error e -> failf "create is engine-free: %a" Mentat_protocol.Error.pp e);
  is_false ~msg:"create starts no agent" (Agent_client.serving t session);
  is_false ~msg:"create binds no endpoint"
    (Sys.file_exists (leaf_dir t session));
  match Mentat_client.tail client session with
  | Ok _ -> fail "no agent serves; the start must have been attempted"
  | Error (Mentat_protocol.Error.Unavailable text) ->
      equal Testable.string
        ~msg:"the first session-scoped call starts, and the spawn's refusal \
              is the caller's answer"
        "session ac-start: MENTAT_BIN names /nonexistent/mentat, which is \
         not a program"
        (Mentat_diagnostic.message text)
  | Error other ->
      failf "expected the spawn refusal, got %a" Mentat_protocol.Error.pp other

let the_cached_driver_survives_generations () =
  with_client "generations" @@ fun ~t ~client ->
  let session = sid "ac-gen" in
  (Eio.Switch.run @@ fun sw ->
   serve_stub t ~sw session;
   reached ~msg:"the first generation answers"
     (Mentat_client.tail client session));
  (* The first generation's listener is gone with its switch; a successor
     binds the same derived endpoint, and the same client's cached wire
     driver — each call dials fresh — reaches it with no rebuild. *)
  Eio.Switch.run @@ fun sw ->
  serve_stub t ~sw session;
  reached ~msg:"the successor generation answers through the same client"
    (Mentat_client.tail client session)

(* Only the serve boot may enter a serving label: an offline attach's owner
   line must stay unlabeled, or interactive holds would read as dialable
   servers — and become preemptable past the boot wait. *)
let an_offline_attach_is_unlabeled () =
  with_client "unlabeled" @@ fun ~t ~client ->
  let session = sid "ac-plain" in
  (match Mentat_client.create client ~id:session () with
  | Ok () -> ()
  | Error error -> failf "create: %a" Mentat_protocol.Error.pp error);
  (match Composition.adopt_session t session with
  | Ok () -> ()
  | Error error -> failf "adopt: %a" Mentat_protocol.Error.pp error);
  let lock =
    List.fold_left Filename.concat
      (Unix.getenv "XDG_DATA_HOME")
      [ "mentat"; "sessions"; Session.Id.to_string session; "run.lock" ]
  in
  let line = In_channel.with_open_bin lock In_channel.input_all in
  let contains_label =
    let needle = "label" in
    let n = String.length needle and l = String.length line in
    let rec go i = i + n <= l && (String.sub line i n = needle || go (i + 1)) in
    go 0
  in
  is_false ~msg:"an offline attach's owner line carries no label"
    contains_label

let () =
  run "mentat.agent-client"
    [
      group "the per-session router"
        [
          test "a serving endpoint is probed and dialed, nothing started"
            a_serving_endpoint_is_dialed;
          test "an offline attach's owner line is unlabeled"
            an_offline_attach_is_unlabeled;
          test "the dormant trivial reads answer without starting an agent"
            the_dormant_reads_start_nothing;
          test "the first session-scoped call decides the start"
            the_first_session_call_decides_the_start;
          test "one cached driver survives agent generations"
            the_cached_driver_survives_generations;
        ];
    ]
