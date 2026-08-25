(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Tui_harness
module Client = Mentat_client
module Driver = Client.Driver
module Feed = Client.Feed
module Protocol = Mentat_protocol
module Runtime = Mentat_tui.Runtime
module Session = Mentat_session
module Tool = Mentat_tool
module Tool_output = Mentat_tools_output

let unavailable text =
  Error (Protocol.Error.Unavailable (Mentat_diagnostic.of_text text))

let session_id = Session.Id.of_string "runtime-resume-position"

let default_session : Driver.Session.t =
  {
    Driver.Session.submit = (fun _ -> unavailable "submit is unused");
    follow = (fun _ ~from:_ -> unavailable "follow is unused");
    answer_unattended =
      (fun ~session:_ ~decision:_ -> unavailable "answer is unused");
    possibly_mutating = (fun ~session:_ -> false);
    faulted = (fun ~session:_ -> None);
    fork = (fun ~session:_ ~into:_ -> unavailable "fork is unused");
    rewind =
      (fun ~session:_ ~into:_ ~anchor:_ -> unavailable "rewind is unused");
    compact = (fun ~session:_ ~turn:_ -> unavailable "compact is unused");
    pending_decision = (fun _ -> Ok None);
    running_processes = (fun _ -> unavailable "running processes is unused");
    change_diff =
      (fun ~session:_ ~change:_ -> unavailable "change diff is unused");
    tail = (fun ?n:_ _ -> unavailable "tail is unused");
    page = (fun ?n:_ _ ~before:_ -> unavailable "page is unused");
    revert = (fun ~session:_ ~scope:_ -> unavailable "revert is unused");
    undo = (fun ~session:_ ~op:_ -> unavailable "undo is unused");
    export = (fun ~session:_ -> unavailable "export is unused");
  }

let accounts : Driver.Accounts.t =
  {
    Driver.Accounts.login =
      (fun ~provider:_ ~method_:_ -> unavailable "login is unused");
    save_api_key = (fun ~provider:_ ~key:_ -> unavailable "api key is unused");
    logout = (fun ?revoke:_ _ -> unavailable "logout is unused");
    account_readiness = (fun () -> Ok []);
    model_readiness = (fun ?refresh:_ () -> unavailable "model readiness is unused");
  }

let settings : Driver.Settings.t =
  {
    Driver.Settings.set_model =
      (fun ~session:_ ?reasoning_effort:_ _ -> unavailable "model is unused");
    set_default_model =
      (fun ?reasoning_effort:_ _ -> unavailable "default model is unused");
    set_permission_review = (fun ~session:_ _ -> unavailable "review is unused");
    set_ui_theme = (fun ~theme:_ -> unavailable "theme is unused");
    configuration = (fun () -> unavailable "configuration is unused");
  }

let review : Driver.Review.t =
  {
    Driver.Review.apply = (fun _ -> unavailable "review apply is unused");
    state = (fun ~scope:_ -> unavailable "review state is unused");
    diff = (fun ~path:_ -> unavailable "review diff is unused");
    crs = (fun () -> unavailable "review crs is unused");
    compose = (fun _ -> unavailable "review compose is unused");
  }

let workspace : Driver.Workspace.t =
  {
    Driver.Workspace.glance =
      (fun () -> unavailable "workspace glance is unused");
    dune = (fun () -> unavailable "workspace dune is unused");
    dune_control = (fun ~op:_ -> unavailable "workspace dune_control is unused");
  }

let lifecycle document : Driver.Lifecycle.t =
  {
    Driver.Lifecycle.create =
      (fun ~id:_ ~title:_ -> unavailable "create is unused");
    rename = (fun ~session:_ ~title:_ -> unavailable "rename is unused");
    archive = (fun ~session:_ -> unavailable "archive is unused");
    restore = (fun ~session:_ -> unavailable "restore is unused");
    delete = (fun ~session:_ -> unavailable "delete is unused");
    sessions =
      (fun ~listing:_ -> Ok ([ Session.Summary.of_session document ], []));
    session =
      (fun requested ->
        if Session.Id.equal requested session_id then
          Ok (Session.Session_view.of_session document)
        else unavailable "foreign session");
  }

let blocking_seam () : Feed.seam =
  let closed = ref false in
  let condition = Eio.Condition.create () in
  let next () =
    Eio.Condition.loop_no_mutex condition (fun () ->
        if !closed then Some (Ok Feed.Closed) else None)
  in
  let close () =
    closed := true;
    Eio.Condition.broadcast condition
  in
  { Feed.next; close }

let seam ?(on_step = fun _ -> ()) ?(on_drained = fun () -> ()) steps : Feed.seam
    =
  let steps = ref steps in
  let drained = ref false in
  let blocked = blocking_seam () in
  let next () =
    match !steps with
    | step :: rest ->
        steps := rest;
        on_step step;
        step
    | [] ->
        if not !drained then begin
          drained := true;
          on_drained ()
        end;
        blocked.Feed.next ()
  in
  { Feed.next; close = blocked.Feed.close }

let provider = Mentat_llm.Provider.make "openai"
let api = Mentat_llm.Model.Api.make "responses"
let model = Mentat_llm.Model.make ~provider ~api ~id:"gpt-5.5"

let contract =
  Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
    ~declarations:[] ~policy:Mentat_permission.Policy.default
    ~review:Mentat_permission.Review_behavior.Enforce
    ~sandbox:(Mentat_sandbox.identity Mentat_sandbox.direct)
    ()

let turn id prompt =
  let id = Session.Turn.Id.of_string id in
  ( id,
    Session.Turn.make ~id ~origin:Session.Turn.Origin.User
      ~input:(Session.Turn.Input.user_text prompt)
      ~max_steps:100 ~contract () )

let response text =
  Mentat_llm.Response.make ~model (Mentat_llm.Message.Assistant.text text)

let committed position fact =
  Ok (Feed.Item (Protocol.Update.Committed { position; fact }))

let invalid position =
  Error
    (Protocol.Error.Invalid_position
       (Protocol.Position.Invalid.Not_in_feed position))

let staged ~first ~second =
  let stage = ref `First in
  fun ~mark_ready requested ~from ->
    if not (Session.Id.equal requested session_id) then
      unavailable "foreign follow"
    else
      match !stage with
      | `First -> (
          stage := `Second;
          match from with
          | `Beginning -> Ok (first ())
          | `Now | `After _ ->
              mark_ready ();
              unavailable "initial resume did not begin at journal start")
      | `Second ->
          stage := `Exhausted;
          second ~mark_ready from
      | `Exhausted ->
          mark_ready ();
          unavailable "wrong third retry: reconnect allowance was exhausted"

let attached ~mark_ready requested ~from =
  if not (Session.Id.equal requested session_id) then
    unavailable "foreign follow"
  else
    match from with
    | `Beginning -> Ok (seam ~on_drained:mark_ready [])
    | `Now | `After _ ->
        mark_ready ();
        unavailable "initial resume did not begin at journal start"

type terminal = {
  project : Project.t;
  backend : Matrix_test.t;
  clock : float Eio.Time.clock_ty Eio.Std.r;
  idle : Eio.Condition.t;
  parked_condition : Eio.Condition.t;
  mutable signaled : bool;
  mutable parked : bool;
  mutable idles : int;
  mutable stopping : bool;
  mutable finished : bool;
  mutable probe : Mosaic.Probe.t option;
}

let wake t =
  t.signaled <- true;
  Eio.Condition.broadcast t.idle

let wait_parked t =
  while not t.parked do
    if t.finished then failwith "runtime exited before its visual checkpoint";
    Eio.Condition.await_no_mutex t.parked_condition
  done

let round_trip t =
  let target = t.idles + 1 in
  wake t;
  while t.idles < target do
    if t.finished then failwith "runtime exited before its visual checkpoint";
    Eio.Condition.await_no_mutex t.parked_condition
  done

let keys t bytes =
  Matrix_test.feed t.backend bytes;
  wake t

let press_escape t =
  Matrix_test.feed t.backend Key.escape;
  wake t;
  round_trip t;
  Matrix_test.set_now t.backend (Matrix_test.now t.backend +. 0.06);
  wake t;
  round_trip t

let rec settle t spent =
  if spent > 20_000 then failwith "runtime visual frame did not settle";
  wait_parked t;
  let pending = Mosaic.Probe.pending (Option.get t.probe) in
  if
    List.mem "messages" pending
    || Matrix.redraw_requested (Matrix_test.app t.backend)
  then begin
    round_trip t;
    settle t (spent + 1)
  end
  else if List.mem "render" pending then begin
    Matrix.request_redraw (Matrix_test.app t.backend);
    round_trip t;
    settle t (spent + 1)
  end
  else if pending <> [] then begin
    Eio.Time.sleep t.clock 0.001;
    settle t (spent + 1)
  end
  else
    let before = t.idles in
    Eio.Time.sleep t.clock 0.001;
    if (not t.parked) || t.idles <> before then settle t (spent + 1)

let rec await_frame t visible remaining =
  if remaining = 0 then failwith "runtime produced no reviewable frame";
  settle t 0;
  let screen = Matrix_test.screen t.backend in
  if List.exists (Screen.contains screen) visible then screen
  else begin
    round_trip t;
    await_frame t visible (remaining - 1)
  end

let print_frame t visible =
  Screen.print ~project:t.project (await_frame t visible 20_000);
  flush stdout

let run ?run_local_shell ?(drive = fun _ -> ())
    ?(startup_session = Some session_id) ?make_client ~name ~visible make_follow
    =
  Project.with_temp name @@ fun project ->
  Project.with_process_env (Project.bindings project) @@ fun () ->
  Eio_main.run @@ fun stdenv ->
  let cwd = Lpath.Abs.of_string_exn (Project.root project) in
  let document =
    Session.create ~id:session_id ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  let snapshot =
    Mentat_tui.Snapshot.make ~version:"test" ~model:"openai/gpt-5.5"
      ~effort:None ~cwd ~home:(Some cwd) ~context_window:None ~sandbox:None
  in
  let startup =
    Mentat_tui.Startup.make ~snapshot ~mode:Session.Contract.Mode.Build
      ~session:startup_session ~input:Mentat_tui.Startup.Empty ~providers:[]
      ~permission_review:Mentat_permission.Review_behavior.Enforce ()
  in
  let local =
    Runtime.Local.make
      ~load_prompt_history:(fun () -> "")
      ~append_prompt_history:(fun _ -> ())
      ?run_local_shell ()
  in
  let ready = ref false in
  let ready_condition = Eio.Condition.create () in
  let mark_ready () =
    ready := true;
    Eio.Condition.broadcast ready_condition
  in
  let follow = make_follow ~mark_ready in
  let client =
    match make_client with
    | Some make -> make ~cwd ~mark_ready
    | None ->
        Client.make
          ~user_commands:(fun () -> Ok [])
          ~expand_command:(fun ~name:_ ~arguments:_ -> Ok [])
          ~attach:(fun ~session:_ _ ->
            Error
              (Protocol.Attach.Error.Unavailable
                 (Mentat_diagnostic.of_text "attach is unused")))
          {
            Driver.session = { default_session with Driver.Session.follow };
            accounts;
            settings;
            lifecycle = lifecycle document;
            review;
            workspace;
          }
  in
  let cell = ref None in
  let on_idle _ ~timeout:_ =
    let t = Option.get !cell in
    if Option.is_none startup_session && not !ready then mark_ready ();
    t.idles <- t.idles + 1;
    t.parked <- true;
    Eio.Condition.broadcast t.parked_condition;
    while (not t.signaled) && not t.stopping do
      Eio.Condition.await_no_mutex t.idle
    done;
    t.signaled <- false;
    t.parked <- false
  in
  let on_wake () = Option.iter wake !cell in
  let backend =
    Matrix_test.create ~target_fps:10. ~now:1. ~on_idle ~on_wake ~width:80
      ~height:24 ()
  in
  let t =
    {
      project;
      backend;
      clock = Eio.Stdenv.clock stdenv;
      idle = Eio.Condition.create ();
      parked_condition = Eio.Condition.create ();
      signaled = false;
      parked = false;
      idles = 0;
      stopping = false;
      finished = false;
      probe = None;
    }
  in
  cell := Some t;
  Eio.Fiber.both
    (fun () ->
      Fun.protect
        ~finally:(fun () ->
          t.finished <- true;
          Eio.Condition.broadcast t.parked_condition)
        (fun () ->
          match
            Runtime.run ~stdenv ~client ~startup ~local ~reduced_motion:true
              ~show_reasoning:false ~overlay:Mentat_tui.Command.Overlay.empty
              ~notify_policy:
                {
                  Mentat_tui.App.notify_enabled = false;
                  notify_channel = Mentat_config.Notify.Channel.Auto;
                  notify_focus = Mentat_config.Notify.When.Unfocused;
                  notify_on = [];
                }
              ~palette:Mentat_tui.Theme.Palette.default
              ~theme_name:"mentat-dark" ~themes:Mentat_tui.Theme.Preset.all
              ~theme_auto:None ~image_max_count:20 ~mouse:true
              ~matrix:(Matrix_test.app backend)
              ~probe:(fun probe -> t.probe <- Some probe)
              ()
          with
          | Ok _ -> ()
          | Error error -> fail (Runtime.error_message error)))
    (fun () ->
      Fun.protect ~finally:(fun () ->
          t.stopping <- true;
          Matrix_test.stop backend;
          wake t)
      @@ fun () ->
      Eio.Condition.loop_no_mutex ready_condition (fun () ->
          if !ready then Some () else None);
      drive t;
      print_frame t visible)

let process_output ~text ~termination ~duration_ms =
  let process = Tool_output.Process.make ~termination ~duration_ms in
  Tool_output.Codec.encode Tool_output.Process.jsont ~text process

let process_result ~text ~termination ~duration_ms =
  let output = process_output ~text ~termination ~duration_ms in
  Tool.Result.completed ~output ()

let pushable_seam () =
  let pending = ref [] in
  let closed = ref false in
  let condition = Eio.Condition.create () in
  let next () =
    Eio.Condition.loop_no_mutex condition (fun () ->
        match !pending with
        | step :: remaining ->
            pending := remaining;
            Some step
        | [] when !closed -> Some (Ok Feed.Closed)
        | [] -> None)
  in
  let close () =
    closed := true;
    Eio.Condition.broadcast condition
  in
  let push steps =
    if !closed then invalid_arg "runtime visual feed is already closed";
    pending := !pending @ steps;
    Eio.Condition.broadcast condition
  in
  ({ Feed.next; close }, push)

let fresh_start_client ~cwd ~mark_ready =
  let stage = ref `Reject_create in
  let created = ref None in
  let push = ref None in
  let submit command =
    match command with
    | Protocol.Command.Prompt
        { session; turn; input; options; mode; max_steps; goal = _; _ } -> (
        match (input, options, mode, max_steps) with
        | ( [ Mentat_llm.Content.Text prompt ],
            None,
            Some Session.Contract.Mode.Build,
            None ) -> (
            match !stage with
            | `Reject_submit ->
                stage := `Accept;
                unavailable "runtime submit rejected the followed candidate"
            | `Accept -> (
                match !push with
                | None ->
                    unavailable "runtime accepted without an attached feed"
                | Some push ->
                    let accepted =
                      Session.Turn.make ~id:turn
                        ~origin:Session.Turn.Origin.User
                        ~input:(Session.Turn.Input.user_text prompt)
                        ~max_steps:100 ~contract ()
                    in
                    let p0 = Protocol.Position.make ~session ~seq:0 in
                    let p1 = Protocol.Position.make ~session ~seq:1 in
                    let p2 = Protocol.Position.make ~session ~seq:2 in
                    push
                      [
                        committed p0 (Protocol.Fact.Turn_started accepted);
                        committed p1
                          (Protocol.Fact.Turn_assistant
                             (response
                                "The next prompt succeeded after every \
                                 admission boundary released."));
                        committed p2
                          (Protocol.Fact.Turn_settled
                             { turn; outcome = Session.Turn.Outcome.completed });
                      ];
                    Ok ())
            | `Reject_create | `Reject_follow ->
                unavailable "runtime submitted before follow admission")
        | _ -> unavailable "runtime received an unexpected prompt command")
    | command ->
        unavailable
          (Format.asprintf "runtime received unexpected %a" Protocol.Command.pp
             command)
  in
  let follow requested ~from =
    let is_created =
      Option.exists (fun session -> Session.Id.equal session requested) !created
    in
    match (!stage, from, is_created) with
    | `Reject_follow, `Now, true ->
        stage := `Reject_submit;
        unavailable "runtime follow rejected the created candidate"
    | `Reject_submit, `Now, true ->
        let feed, enqueue = pushable_seam () in
        push := Some enqueue;
        mark_ready ();
        Ok feed
    | (`Reject_create | `Accept), _, _
    | (`Reject_follow | `Reject_submit), (`Beginning | `After _), _
    | (`Reject_follow | `Reject_submit), `Now, false ->
        unavailable "runtime followed an unexpected session candidate"
  in
  let seed =
    Session.create ~id:session_id ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  let lifecycle =
    {
      (lifecycle seed) with
      Driver.Lifecycle.create =
        (fun ~id ~title ->
          match title with
          | Some title when String.equal (String.trim title) "" ->
              unavailable "runtime create received an empty title"
          | Some _ | None -> (
              match !stage with
              | `Reject_create ->
                  stage := `Reject_follow;
                  unavailable "runtime create rejected the first candidate"
              | `Reject_follow | `Reject_submit ->
                  created := Some id;
                  Ok ()
              | `Accept ->
                  unavailable "runtime created a session after admission"));
      session =
        (fun requested ->
          let document =
            Session.create ~id:requested ~cwd
              ~created_at:(Session.Time.of_unix_ms 2L)
              ()
          in
          Ok (Session.Session_view.of_session document));
    }
  in
  Client.make
    ~user_commands:(fun () -> Ok [])
    ~expand_command:(fun ~name:_ ~arguments:_ -> Ok [])
    ~attach:(fun ~session:_ _ ->
      Error
        (Protocol.Attach.Error.Unavailable
           (Mentat_diagnostic.of_text "attach is unused")))
    {
      Driver.session = { default_session with Driver.Session.submit; follow };
      accounts;
      settings;
      lifecycle;
      review;
      workspace;
    }

(* Every recovery origin maps to a different visible branch. The complete
   terminal frame, rather than a hidden call list or counter, is the contract. *)
let%expect_test "committed Invalid_position resumes After without replay" =
  let p0 = Protocol.Position.make ~session:session_id ~seq:0 in
  let p1 = Protocol.Position.make ~session:session_id ~seq:1 in
  let p2 = Protocol.Position.make ~session:session_id ~seq:2 in
  let turn_id, accepted =
    turn "runtime-invalid-position"
      "Recover this transcript after the feed rejects its cursor."
  in
  let recovered =
    response
      "Recovered after the committed cursor; no accepted input was replayed."
  in
  run ~name:"runtime-invalid-position"
    ~visible:
      [
        "Recovered after the committed cursor";
        "wrong cursor retry";
        "wrong beginning retry";
        "invalid-position recovery tailed now";
      ]
    (staged
       ~first:(fun () ->
         seam [ committed p0 (Protocol.Fact.Turn_started accepted); invalid p0 ])
       ~second:(fun ~mark_ready -> function
         | `After resumed when Protocol.Position.equal resumed p0 ->
             Ok
               (seam ~on_drained:mark_ready
                  [
                    committed p1 (Protocol.Fact.Turn_assistant recovered);
                    committed p2
                      (Protocol.Fact.Turn_settled
                         {
                           turn = turn_id;
                           outcome = Session.Turn.Outcome.completed;
                         });
                  ])
         | `After _ ->
             mark_ready ();
             unavailable "wrong cursor retry for Invalid_position"
         | `Beginning ->
             mark_ready ();
             unavailable
               "wrong beginning retry: populated Invalid_position must not \
                rewind"
         | `Now ->
             mark_ready ();
             unavailable "invalid-position recovery tailed now"));
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ❯ Recover this transcript after the feed rejects its cursor.
06 |
07 | ⏺ Recovered after the committed cursor; no accepted input was replayed.
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ~ · openai/gpt-5.5                                           ? for shortcuts|}]

let%expect_test "committed Closed retries After and rejection is visible" =
  let position = Protocol.Position.make ~session:session_id ~seq:0 in
  let _, accepted =
    turn "runtime-closed-after"
      "Keep the committed cursor when this feed closes."
  in
  run ~name:"runtime-closed-after"
    ~visible:[ "closed retry rejected after cursor"; "wrong beginning retry" ]
    (staged
       ~first:(fun () ->
         seam
           [
             committed position (Protocol.Fact.Turn_started accepted);
             Ok Feed.Closed;
           ])
       ~second:(fun ~mark_ready from ->
         mark_ready ();
         match from with
         | `After resumed when Protocol.Position.equal resumed position ->
             unavailable "closed retry rejected after cursor; resume explicitly"
         | `After _ -> unavailable "wrong cursor retry for Closed"
         | `Beginning ->
             unavailable "wrong beginning retry for committed Closed"
         | `Now -> unavailable "closed feed tailed now"));
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ❯ Keep the committed cursor when this feed closes.
06 |
07 | ✗ closed retry rejected after cursor; resume explicitly
08 |   check the connection, then retry
09 |
10 | ⠋ Working… (0s · esc to interrupt)
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   closed retry rejected after cursor; resume explicitly|}]

let%expect_test "empty Invalid_position reconnects visibly once from Beginning"
    =
  let p0 = Protocol.Position.make ~session:session_id ~seq:0 in
  let p1 = Protocol.Position.make ~session:session_id ~seq:1 in
  let p2 = Protocol.Position.make ~session:session_id ~seq:2 in
  let turn_id, accepted =
    turn "runtime-empty-invalid-position"
      "Recover an empty invalid cursor from the journal beginning."
  in
  let recovered =
    response
      "The empty invalid cursor restarted from the beginning exactly once."
  in
  run ~name:"runtime-empty-invalid-position"
    ~visible:
      [
        "empty invalid cursor restarted";
        "wrong after retry";
        "empty Invalid_position tailed now";
      ]
    (staged
       ~first:(fun () -> seam [ invalid p0 ])
       ~second:(fun ~mark_ready -> function
         | `Beginning ->
             Ok
               (seam ~on_drained:mark_ready
                  [
                    committed p0 (Protocol.Fact.Turn_started accepted);
                    committed p1 (Protocol.Fact.Turn_assistant recovered);
                    committed p2
                      (Protocol.Fact.Turn_settled
                         {
                           turn = turn_id;
                           outcome = Session.Turn.Outcome.completed;
                         });
                  ])
         | `After _ ->
             mark_ready ();
             unavailable
               "wrong after retry: empty Invalid_position requires Beginning"
         | `Now ->
             mark_ready ();
             unavailable "empty Invalid_position tailed now"));
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ❯ Recover an empty invalid cursor from the journal beginning.
06 |
07 | ⏺ The empty invalid cursor restarted from the beginning exactly once.
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ~ · openai/gpt-5.5                                           ? for shortcuts|}]

let%expect_test "a closure after Invalid_position recovery is terminal" =
  let position = Protocol.Position.make ~session:session_id ~seq:0 in
  run ~name:"runtime-shared-reconnect-allowance"
    ~visible:[ "the session feed closed unexpectedly"; "wrong third retry" ]
    (staged
       ~first:(fun () -> seam [ invalid position ])
       ~second:(fun ~mark_ready -> function
         | `Beginning ->
             Ok (seam ~on_step:(fun _ -> mark_ready ()) [ Ok Feed.Closed ])
         | `After _ ->
             mark_ready ();
             unavailable
               "wrong after retry: empty Invalid_position requires Beginning"
         | `Now ->
             mark_ready ();
             unavailable "empty Invalid_position tailed now"));
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ the session feed closed unexpectedly
06 |   check the connection, then retry
07 |
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   the session feed closed unexpectedly|}]

let%expect_test "local shell callback renders the typed process result" =
  let result =
    process_result ~text:"local shell from tui"
      ~termination:(Tool_output.Process.Exited 0) ~duration_ms:12
  in
  run ~name:"runtime-invalid-position"
    ~visible:[ "local shell from tui"; "wrong local shell command" ]
    ~run_local_shell:(fun ~cancelled ~command ->
      if cancelled () then
        Error (Mentat_diagnostic.of_text "wrong premature cancellation")
      else if String.equal command "printf runtime callback" then Ok result
      else Error (Mentat_diagnostic.of_text "wrong local shell command"))
    ~drive:(fun t ->
      settle t 0;
      keys t ("!printf runtime callback" ^ Key.enter))
    attached;
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ⏺ Shell(printf runtime callback)
06 |   ⎿  Completed in 12 ms
07 |       local shell from tui
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ~ · openai/gpt-5.5                                           ? for shortcuts|}]

let%expect_test "local shell cancellation is cooperative and correlated" =
  let started = ref false in
  let started_condition = Eio.Condition.create () in
  run ~name:"runtime-invalid-position"
    ~visible:[ "local shell cancellation output"; "wrong local shell command" ]
    ~run_local_shell:(fun ~cancelled ~command ->
      if not (String.equal command "sleep until cancelled") then
        Error (Mentat_diagnostic.of_text "wrong local shell command")
      else begin
        started := true;
        Eio.Condition.broadcast started_condition;
        while not (cancelled ()) do
          Eio.Fiber.yield ()
        done;
        let output =
          process_output ~text:"local shell cancellation output"
            ~termination:Tool_output.Process.Stopped ~duration_ms:7
        in
        Ok
          (Tool.Result.interrupted ~output
             ~reason:"Stopped by cooperative cancellation." ~cancelled:true ())
      end)
    ~drive:(fun t ->
      settle t 0;
      keys t ("!sleep until cancelled" ^ Key.enter);
      Eio.Condition.loop_no_mutex started_condition (fun () ->
          if !started then Some () else None);
      press_escape t;
      press_escape t)
    attached;
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ⏺ Shell(sleep until cancelled)
06 |   ⎿  Stopped by cooperative cancellation.
07 |
08 |      Stopped in 7 ms · cancelled
09 |       local shell cancellation output
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ~ · openai/gpt-5.5                                           ? for shortcuts|}]

let%expect_test
    "fresh admission failures release the UI through create follow and submit" =
  let send t prompt =
    settle t 0;
    keys t (prompt ^ Key.enter)
  in
  run ~name:"runtime-fresh-admission" ~startup_session:None
    ~make_client:fresh_start_client
    ~visible:
      [ "The next prompt succeeded after every admission boundary released." ]
    ~drive:(fun t ->
      send t "Create a session for this task.";
      print_frame t [ "runtime create rejected the first candidate" ];
      [%expect
        {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ runtime create rejected the first candidate
06 |   retry when ready
07 |
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   runtime create rejected the first candidate|}];
      send t "Retry after create failure.";
      print_frame t [ "runtime follow rejected the created candidate" ];
      [%expect
        {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ runtime follow rejected the created candidate
06 |   retry when ready
07 |
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   runtime follow rejected the created candidate|}];
      send t "Retry after follow failure.";
      print_frame t [ "runtime submit rejected the followed candidate" ];
      [%expect
        {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ runtime submit rejected the followed candidate
06 |   retry when ready
07 |
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   runtime submit rejected the followed candidate|}];
      send t "Recover after submit failure.")
    attached;
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ runtime submit rejected the followed candidate
06 |   retry when ready
07 |
08 | ❯ Recover after submit failure.
09 |
10 | ⏺ The next prompt succeeded after every admission boundary released.
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ~ · openai/gpt-5.5                                           ? for shortcuts|}]

let%expect_test
    "local shell result and exception failures release busy state for reuse" =
  let result =
    process_result ~text:"local shell recovered after both failures"
      ~termination:(Tool_output.Process.Exited 0) ~duration_ms:9
  in
  run ~name:"runtime-shell-failures"
    ~visible:[ "local shell recovered after both failures" ]
    ~run_local_shell:(fun ~cancelled ~command ->
      if cancelled () then
        Error (Mentat_diagnostic.of_text "unexpected shell cancellation")
      else
        match command with
        | "structured shell failure" ->
            Error
              (Mentat_diagnostic.of_text
                 "structured local shell capability failure")
        | "raising shell failure" -> failwith "local shell boundary exploded"
        | "recover shell" -> Ok result
        | command ->
            Error
              (Mentat_diagnostic.of_text
                 ("unexpected local shell command: " ^ command)))
    ~drive:(fun t ->
      settle t 0;
      keys t ("!structured shell failure" ^ Key.enter);
      print_frame t [ "structured local shell capability failure" ];
      [%expect
        {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ structured local shell capability failure
06 |   retry when ready
07 |
08 |
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   structured local shell capability failure|}];
      keys t ("!raising shell failure" ^ Key.enter);
      print_frame t [ "local shell callback raised" ];
      [%expect
        {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ structured local shell capability failure
06 |   retry when ready
07 |
08 | ✗ local shell callback raised: Failure("local shell boundary exploded")
09 |   retry when ready
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   local shell callback raised: Failure("local shell boundary exploded")|}];
      keys t ("!recover shell" ^ Key.enter))
    attached;
  [%expect
    {|01 |
02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    test · openai/gpt-5.5
03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~
04 |
05 | ✗ structured local shell capability failure
06 |   retry when ready
07 |
08 | ✗ local shell callback raised: Failure("local shell boundary exploded")
09 |   retry when ready
10 |
11 | ⏺ Shell(recover shell)
12 |   ⎿  Completed in 9 ms
13 |       local shell recovered after both failures
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message mentat
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ~ · openai/gpt-5.5                                           ? for shortcuts|}]
