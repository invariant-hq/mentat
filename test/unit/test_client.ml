(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_client], the effectful frontend connection.
   The client is driven entirely by an in-test fake {!Driver.t}: a
   record of scripted closures that record their inputs and return canned
   results, so every law is pinned without an engine, store, or transport — the
   dependency exclusion is a compile-time fact of the dune stanza, not a
   runtime check.

   The suite pins: submit passthrough and admission; the three-case
   [follow_session] against a scripted session-half; the feed wrapper's
   delivery order (committed before progress), drop-oldest progress ring,
   never-drop committed, seam-error surfacing, and [Closed];
   [Login.t] boxing (steps pulled in order, idempotent cancel, cancel mid-flow);
   the [query] router's typed dispatch over the landed protocol constructors;
   protocol [Error.t] crossing unchanged; operation-labelled containment of
   raised driver exceptions with cancellation preserved; and client-minted ids
   on create/fork/rewind.

   A public {!Mentat_protocol.Position.make} value is only a locally shaped
   candidate; it supplies neither feed membership nor the paired committed
   fact. The fixture therefore projects a one-turn session — exactly as the
   protocol suite does — to harvest a genuine [(position, fact)] pair. Eio tests
   run under one [Eio_main.run] with a real-clock deadlock guard. *)

open Windtrap
module Client = Mentat_client
module Driver = Client.Driver
module Feed = Client.Feed
module Login = Client.Login
module Protocol = Mentat_protocol
module Update = Protocol.Update
module Progress = Protocol.Progress
module Error = Protocol.Error
module Session = Mentat_session
module Mutation = Mentat_mutation
module Llm = Mentat_llm
module Permission = Mentat_permission
module Sandbox = Mentat_sandbox
module Provider = Mentat_provider
module Review = Mentat_review
module Login_progress = Provider.Auth.Login.Progress

(* Generic helpers. *)

let error_t = Testable.make ~pp:Error.pp ~equal:Error.equal

let ok = function
  | Ok value -> value
  | Error e -> failf "unexpected error: %a" Error.pp e

let sid s = Session.Id.of_string s
let tid s = Session.Turn.Id.of_string s
let missing_account provider = Provider.Account.missing ~provider

let known_missing provider =
  Provider.Account.Discovery.Known (missing_account provider)

let logout_result ?(revoke = false) provider : Provider.Account.Logout.t =
  Provider.Account.Logout.
    {
      current = known_missing provider;
      revocation =
        (if revoke then Some Provider.Account.Logout.Not_stored else None);
    }

(* Run a body needing a switch under one Eio domain, guarded so a feed fiber
   that never wakes fails loudly instead of hanging the suite. *)
let with_eio f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  match
    Eio.Time.with_timeout clock 15.0 (fun () ->
        f sw;
        Ok ())
  with
  | Ok () -> ()
  | Error `Timeout ->
      fail
        "deadlock guard: the test body exceeded 15s (a feed fiber never woke)"

(* A genuine committed update, harvested from a one-turn projection. *)

let projected =
  let provider = Llm.Provider.make "openai" in
  let model =
    Llm.Model.make ~provider ~api:(Llm.Model.Api.make "responses") ~id:"gpt-5"
  in
  let contract =
    Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
      ~declarations:[] ~policy:Permission.Policy.default
      ~review:Permission.Review_behavior.Enforce
      ~sandbox:(Sandbox.identity Sandbox.direct)
      ()
  in
  let turn =
    Session.Turn.make ~id:(tid "turn-1") ~origin:Session.Turn.Origin.User
      ~input:(Session.Turn.Input.user_text "hello")
      ~max_steps:8 ~contract ()
  in
  let metadata =
    Session.Metadata.make
      ~cwd:(Lpath.Abs.of_string_exn "/workspace")
      ~created_at:(Session.Time.of_unix_ms 1L)
      ~updated_at:(Session.Time.of_unix_ms 2L)
      ()
  in
  let session =
    match
      Session.make ~id:(sid "session-1") ~metadata
        ~events:[ Session.Event.turn_started turn ]
    with
    | Ok s -> s
    | Error e -> failf "session build: %a" Session.Error.pp e
  in
  let mutation =
    match Mutation.State.of_events [] with
    | Ok m -> m
    | Error _ -> fail "mutation build"
  in
  Protocol.Projection.all ~session ~mutation

let committed_update =
  match projected with
  | (position, fact) :: _ -> Update.Committed { position; fact }
  | [] -> fail "projection produced no facts"

let a_position =
  match projected with
  | (position, _) :: _ -> position
  | [] -> fail "no position"

let is_committed = function
  | Update.Committed _ -> true
  | Update.Progress _ -> false

let progress ~turn text =
  Update.Progress
    (Progress.Model { turn; update = Progress.Model.Assistant_delta { text } })

let progress_text = function
  | Update.Progress
      (Progress.Model { update = Progress.Model.Assistant_delta { text }; _ })
    ->
      text
  | _ -> fail "expected an assistant-delta progress pulse"

(* The scripted fake driver. *)

(* Every field of the default sub-records fails loudly; a test overrides only
   the fields it exercises with [{ default with field = ... }]. *)

let default_session : Driver.Session.t =
  {
    Driver.Session.submit = (fun _ -> fail "submit: not scripted");
    follow = (fun _ ~from:_ -> fail "follow: not scripted");
    answer_unattended =
      (fun ~session:_ ~decision:_ -> fail "answer_unattended: not scripted");
    possibly_mutating =
      (fun ~session:_ -> fail "possibly_mutating: not scripted");
    faulted = (fun ~session:_ -> fail "faulted: not scripted");
    fork = (fun ~session:_ ~into:_ -> fail "fork: not scripted");
    rewind = (fun ~session:_ ~into:_ ~anchor:_ -> fail "rewind: not scripted");
    compact = (fun ~session:_ ~turn:_ -> fail "compact: not scripted");
    pending_decision = (fun _ -> fail "pending_decision: not scripted");
    change_diff = (fun ~session:_ ~change:_ -> fail "change_diff: not scripted");
    tail = (fun ?n:_ _ -> fail "tail: not scripted");
    page = (fun ?n:_ _ ~before:_ -> fail "page: not scripted");
    running_processes = (fun _ -> fail "running_processes: not scripted");
    revert = (fun ~session:_ ~scope:_ -> fail "revert: not scripted");
    undo = (fun ~session:_ ~op:_ -> fail "undo: not scripted");
    export = (fun ~session:_ -> fail "export: not scripted");
  }

let default_accounts : Driver.Accounts.t =
  {
    Driver.Accounts.login =
      (fun ~provider:_ ~method_:_ -> fail "login: not scripted");
    save_api_key = (fun ~provider:_ ~key:_ -> fail "save_api_key: not scripted");
    logout =
      (fun ?(revoke = false) provider ->
        failf "logout: not scripted for %s (revoke %b)"
          (Llm.Provider.id provider) revoke);
    account_readiness = (fun () -> fail "account_readiness: not scripted");
    model_readiness = (fun ?refresh:_ () -> fail "model_readiness: not scripted");
  }

let default_settings : Driver.Settings.t =
  {
    Driver.Settings.set_model =
      (fun ~session ?reasoning_effort selector ->
        failf "set_model: not scripted for %s (%s, effort %s)"
          (Session.Id.to_string session)
          (Provider.Selector.to_string selector)
          (Option.fold ~none:"default"
             ~some:Llm.Request.Options.Reasoning_effort.to_string
             reasoning_effort));
    set_permission_review =
      (fun ~session:_ _ -> fail "set_permission_review: not scripted");
    configuration = (fun () -> fail "configuration: not scripted");
    set_default_model =
      (fun ?reasoning_effort:_ _ -> fail "set_default_model: not scripted");
    set_ui_theme = (fun ~theme:_ -> fail "set_ui_theme: not scripted");
  }

let default_lifecycle : Driver.Lifecycle.t =
  {
    Driver.Lifecycle.create =
      (fun ~id:_ ~title:_ -> fail "create: not scripted");
    rename = (fun ~session:_ ~title:_ -> fail "rename: not scripted");
    archive = (fun ~session:_ -> fail "archive: not scripted");
    restore = (fun ~session:_ -> fail "restore: not scripted");
    delete = (fun ~session:_ -> fail "delete: not scripted");
    set_goal = (fun ~session:_ ~goal:_ -> fail "set_goal: not scripted");
    sessions = (fun ~listing:_ -> fail "sessions: not scripted");
    session = (fun _ -> fail "session: not scripted");
  }

let default_review : Driver.Review.t =
  {
    Driver.Review.apply = (fun _ -> fail "review apply: not scripted");
    state = (fun ~scope:_ -> fail "review state: not scripted");
    diff = (fun ~path:_ -> fail "review diff: not scripted");
    crs = (fun () -> fail "review crs: not scripted");
    compose = (fun _ -> fail "review compose: not scripted");
  }

let default_workspace : Driver.Workspace.t =
  {
    Driver.Workspace.glance = (fun () -> fail "workspace glance: not scripted");
    dune = (fun () -> fail "workspace dune: not scripted");
    dune_control =
      (fun ~op:_ -> fail "workspace dune_control: not scripted");
  }

let default_user_commands () = fail "user_commands: not scripted"

let default_expand_command ~name:_ ~arguments:_ =
  fail "expand_command: not scripted"

let default_attach ~session:_ _source = fail "attach: not scripted"

let client_of ?(session = default_session) ?(accounts = default_accounts)
    ?(settings = default_settings) ?(lifecycle = default_lifecycle)
    ?(review = default_review) ?(workspace = default_workspace)
    ?(user_commands = default_user_commands)
    ?(expand_command = default_expand_command) ?(attach = default_attach) () =
  Client.make ~user_commands ~expand_command ~attach
    { Driver.session; accounts; settings; lifecycle; review; workspace }

(* A seam whose [next] pops scripted [Update.t]/error results synchronously
   (wrapping updates in [Feed.Item] as the engine seam does) and, once exhausted,
   parks until [close] — after which a parked [next] wakes with [Ok Closed],
   exactly as the engine feed's seam does. *)
let scripted_seam results : Feed.seam =
  let q = Queue.create () in
  List.iter (fun r -> Queue.push r q) results;
  let cond = Eio.Condition.create () in
  let closed = ref false in
  let next () =
    Eio.Condition.loop_no_mutex cond (fun () ->
        match Queue.take_opt q with
        | Some (Ok update) -> Some (Ok (Feed.Item update))
        | Some (Error _ as e) -> Some e
        | None -> if !closed then Some (Ok Feed.Closed) else None)
  in
  let close () =
    closed := true;
    Eio.Condition.broadcast cond
  in
  { Feed.next; close }

let read_next feed =
  match Feed.next feed with
  | Ok (Feed.Item update) -> `Item update
  | Ok Feed.Closed -> `Closed
  | Error e -> `Error e

let read_item feed =
  match read_next feed with
  | `Item update -> update
  | `Closed -> fail "expected an item, got Closed"
  | `Error e -> failf "expected an item, got error: %a" Error.pp e

(* A genuine catch-up position rejection: the mli names [Invalid_position] as the
   error a [from] naming no committed fact surfaces. [Not_in_feed] carries a real
   position; the client never mints or inspects one, so a forged position is
   modelled by the driver returning this structural rejection. *)
let invalid_position =
  Error.Invalid_position (Protocol.Position.Invalid.Not_in_feed a_position)

let foreign_position =
  Error.Invalid_position
    (Protocol.Position.Invalid.Foreign_session
       { expected = sid "expected"; actual = sid "actual" })

(* One fixed error the passthrough sweeps assert crosses every flow unmapped. *)
let swept = Error.Session_not_found (sid "swept")

let expect_unavailable ~operation ~calls = function
  | Ok _ -> failf "%s: expected a contained driver exception" operation
  | Error (Error.Unavailable diagnostic) ->
      equal int ~msg:(operation ^ " invoked once") 1 !calls;
      equal string
        ~msg:(operation ^ " exposes no exception text")
        (operation ^ " failed unexpectedly")
        (Mentat_diagnostic.to_string diagnostic)
  | Error error ->
      failf "%s: expected Unavailable, got %a" operation Error.pp error

let raise_driver calls =
  incr calls;
  failwith "driver boom"

(* A login step-pull that blocks its caller until [cancel] wakes it with a
   terminal step — the shape a real interactive flow has (a parked [next] the
   flow's own cancel resolves). [scripted_login] never blocks, so it cannot pin
   the cancel-racing-a-parked-pull race. *)
let blocking_login ~terminal cancels : Login.steps =
  let cond = Eio.Condition.create () in
  let cancelled = ref false in
  let next () =
    Eio.Condition.loop_no_mutex cond (fun () ->
        if !cancelled then Some (Ok terminal) else None)
  in
  let cancel () =
    incr cancels;
    cancelled := true;
    Eio.Condition.broadcast cond
  in
  { Login.next; cancel }

(* Submission and admission. *)

let submission_group =
  group "submission"
    [
      test "submit forwards the command and returns durable admission"
        (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.submit =
                (fun command ->
                  seen := Some command;
                  Ok ());
            }
          in
          let client = client_of ~session () in
          let command = Protocol.Command.clear_queued ~session:(sid "s") in
          ok (Client.submit client command);
          match !seen with
          | Some command ->
              is_true ~msg:"the exact command reached the driver"
                (Session.Id.equal (sid "s") (Protocol.Command.session command))
          | None -> fail "the driver's submit was never called");
      test "submit surfaces a refusal verbatim (no queue promise)" (fun () ->
          let busy = Error.Busy { session = sid "s"; owner = Some "peer" } in
          let session =
            {
              default_session with
              Driver.Session.submit = (fun _ -> Error busy);
            }
          in
          let client = client_of ~session () in
          match
            Client.submit client
              (Protocol.Command.clear_queued ~session:(sid "s"))
          with
          | Ok () -> fail "expected the refusal to cross"
          | Error e -> equal error_t ~msg:"refusal crosses unmapped" busy e);
      test "answer_unattended routes to the unattended responder" (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.answer_unattended =
                (fun ~session ~decision ->
                  seen := Some (session, decision);
                  Ok ());
            }
          in
          let client = client_of ~session () in
          ok
            (Client.answer_unattended client ~session:(sid "s")
               ~decision:(Session.Decision.Id.of_string "d1"));
          match !seen with
          | Some (session, decision) ->
              is_true ~msg:"session and decision forwarded"
                (Session.Id.equal (sid "s") session
                && Session.Decision.Id.equal
                     (Session.Decision.Id.of_string "d1")
                     decision)
          | None -> fail "answer_unattended never reached the driver");
      test "possibly_mutating is a plain bool passthrough" (fun () ->
          let session =
            {
              default_session with
              Driver.Session.possibly_mutating = (fun ~session:_ -> true);
            }
          in
          let client = client_of ~session () in
          is_true ~msg:"true crosses as a plain bool"
            (Client.possibly_mutating client ~session:(sid "s")));
    ]

(* Feeds: the three-case follow and the wrapper contract. *)

let follow_group =
  group "feeds: follow_session"
    [
      test "each from case reaches the driver and the feed catches up"
        (fun () ->
          List.iter
            (fun from ->
              with_eio (fun sw ->
                  let seen = ref None in
                  let session =
                    {
                      default_session with
                      Driver.Session.follow =
                        (fun id ~from ->
                          seen := Some (id, from);
                          Ok (scripted_seam [ Ok committed_update ]));
                    }
                  in
                  let client = client_of ~session () in
                  let feed =
                    ok (Client.follow_session ~sw client (sid "s") ~from)
                  in
                  is_true ~msg:"the committed fact catches up"
                    (is_committed (read_item feed));
                  (match !seen with
                  | Some (id, seen_from) ->
                      is_true ~msg:"session id forwarded"
                        (Session.Id.equal (sid "s") id);
                      is_true ~msg:"from forwarded unchanged" (seen_from = from)
                  | None -> fail "the driver's follow was never called");
                  Feed.close feed))
            [ `Beginning; `Now; `After a_position ]);
      test "follow surfaces a driver refusal without a feed" (fun () ->
          with_eio (fun sw ->
              let session =
                {
                  default_session with
                  Driver.Session.follow =
                    (fun _ ~from:_ -> Error (Error.Session_not_found (sid "s")));
                }
              in
              let client = client_of ~session () in
              match Client.follow_session ~sw client (sid "s") ~from:`Now with
              | Ok _ -> fail "expected the refusal to cross"
              | Error e ->
                  equal error_t ~msg:"refusal crosses unmapped"
                    (Error.Session_not_found (sid "s"))
                    e));
      test
        "an empty catch-up keeps the feed live and parked; close then wakes it"
        (fun () ->
          (* `Beginning on a zero-fact session and `After at the exact head both
             hand back a seam with no catch-up: the feed must stay live (a
             parked next, never a spurious Closed) until close wakes it. *)
          List.iter
            (fun from ->
              with_eio (fun sw ->
                  let session =
                    {
                      default_session with
                      Driver.Session.follow =
                        (fun _ ~from:_ -> Ok (scripted_seam []));
                    }
                  in
                  let client = client_of ~session () in
                  let feed =
                    ok (Client.follow_session ~sw client (sid "s") ~from)
                  in
                  let observed = ref `Parked in
                  Eio.Fiber.fork ~sw (fun () ->
                      observed :=
                        match read_next feed with
                        | `Closed -> `Closed
                        | `Item _ -> `Item
                        | `Error _ -> `Error);
                  (* Let the reader and drain fibers reach their park points. *)
                  Eio.Fiber.yield ();
                  Eio.Fiber.yield ();
                  is_true
                    ~msg:"the empty catch-up leaves next parked, not Closed"
                    (!observed = `Parked);
                  Feed.close feed;
                  Eio.Fiber.yield ();
                  is_true ~msg:"close wakes the parked next with Closed"
                    (!observed = `Closed)))
            [ `Beginning; `After a_position ]);
      test "follow `Now then an immediate close yields Closed with no items"
        (fun () ->
          with_eio (fun sw ->
              let session =
                {
                  default_session with
                  Driver.Session.follow =
                    (fun _ ~from:_ -> Ok (scripted_seam []));
                }
              in
              let client = client_of ~session () in
              let feed =
                ok (Client.follow_session ~sw client (sid "s") ~from:`Now)
              in
              Feed.close feed;
              match read_next feed with
              | `Closed -> ()
              | `Item _ -> fail "expected Closed, a `Now attach had no backlog"
              | `Error _ -> fail "expected Closed, got an error"));
      test "a foreign/forged position crosses as a structural Invalid_position"
        (fun () ->
          with_eio (fun sw ->
              (* The client wrapper normally threads [from] unchanged and
                 surfaces the engine's membership rejection verbatim; public
                 candidate construction does not move that authority here. *)
              let session =
                {
                  default_session with
                  Driver.Session.follow =
                    (fun _ ~from:_ -> Error foreign_position);
                }
              in
              let client = client_of ~session () in
              match
                Client.follow_session ~sw client (sid "s")
                  ~from:(`After a_position)
              with
              | Ok _ -> fail "expected the structural rejection to cross"
              | Error e ->
                  equal error_t ~msg:"Invalid_position crosses unmapped"
                    foreign_position e));
    ]

let feed_group =
  group "feeds: the wrapper contract"
    [
      test
        "the wrapper forwards seam outcomes in order (committed then progress)"
        (fun () ->
          (* Committed-before-progress and bounded drop-oldest progress are the
             producer's obligations; the thin wrapper forwards
             whatever the seam yields, in order, with no buffer of its own. The
             ring/drop-oldest semantics are pinned engine-side (test_agent_next). *)
          with_eio (fun sw ->
              let turn = tid "turn-1" in
              let seam =
                scripted_seam
                  [
                    Ok committed_update;
                    Ok (progress ~turn "p0");
                    Ok (progress ~turn "p1");
                  ]
              in
              let feed = Feed.subscribe ~sw seam in
              is_true ~msg:"the committed fact crosses first"
                (is_committed (read_item feed));
              equal string ~msg:"then progress p0" "p0"
                (progress_text (read_item feed));
              equal string ~msg:"then progress p1" "p1"
                (progress_text (read_item feed));
              Feed.close feed));
      test "a returned seam error crosses unmapped; close then ends the feed"
        (fun () ->
          with_eio (fun sw ->
              let err = Error.Session_not_found (sid "s") in
              let feed = Feed.subscribe ~sw (scripted_seam [ Error err ]) in
              (match read_next feed with
              | `Error e ->
                  equal error_t ~msg:"the returned seam error crosses" err e
              | `Item _ -> fail "expected the seam error"
              | `Closed -> fail "expected the seam error, got Closed");
              (* A returned error is not terminal (the seam owns terminality, e.g.
                 the engine feed repeats a catch-up rejection); close ends it. *)
              Feed.close feed;
              match read_next feed with
              | `Closed -> ()
              | `Item _ -> fail "expected Closed after close"
              | `Error _ -> fail "the error should surface only once"));
      test "close wakes the feed with Closed and is idempotent" (fun () ->
          with_eio (fun sw ->
              let feed = Feed.subscribe ~sw (scripted_seam []) in
              Feed.close feed;
              Feed.close feed;
              match read_next feed with
              | `Closed -> ()
              | `Item _ -> fail "expected Closed"
              | `Error _ -> fail "expected Closed, got an error"));
      test "committed facts cross before a returned seam error, in order"
        (fun () ->
          with_eio (fun sw ->
              (* The wrapper forwards in seam order: committed facts come out
                 before a returned error, exactly as the producer yields them
                 (the never-skip catch-up is the producer's). *)
              let feed =
                Feed.subscribe ~sw
                  (scripted_seam
                     [
                       Ok committed_update;
                       Ok committed_update;
                       Error invalid_position;
                     ])
              in
              is_true ~msg:"first committed fact crosses before the error"
                (is_committed (read_item feed));
              is_true ~msg:"second committed fact crosses before the error"
                (is_committed (read_item feed));
              (match read_next feed with
              | `Error e ->
                  equal error_t ~msg:"only then the seam error" invalid_position
                    e
              | `Item _ ->
                  fail "expected the seam error after the committed facts"
              | `Closed -> fail "expected the seam error, got Closed");
              Feed.close feed;
              match read_next feed with
              | `Closed -> ()
              | _ -> fail "expected Closed after close"));
      test "close from two fibers is safe and single-shot" (fun () ->
          with_eio (fun sw ->
              (* Two concurrent closers must not double-close the seam: the
                 [not closed] guard makes close single-shot. *)
              let feed = Feed.subscribe ~sw (scripted_seam []) in
              Eio.Fiber.both
                (fun () -> Feed.close feed)
                (fun () -> Feed.close feed);
              match read_next feed with
              | `Closed -> ()
              | `Item _ -> fail "expected Closed"
              | `Error _ -> fail "expected Closed, got an error"));
      test "releasing the subscribing switch closes the feed (on_release path)"
        (fun () ->
          with_eio (fun _outer ->
              (* A feed bound to an inner switch is closed when that switch is
                 cancelled: [Switch.on_release] fires [close]. The feed handle
                 outlives the switch. *)
              let feed = ref None in
              (try
                 Eio.Switch.run (fun inner ->
                     feed := Some (Feed.subscribe ~sw:inner (scripted_seam []));
                     raise Exit)
               with Exit -> ());
              match read_next (Option.get !feed) with
              | `Closed -> ()
              | `Item _ -> fail "expected Closed after the switch released"
              | `Error _ -> fail "expected Closed, got an error"));
      test
        "a raising seam next is contained: terminal Unavailable then Closed, \
         siblings survive" (fun () ->
          with_eio (fun sw ->
              (* [Feed.next] runs the untrusted seam's [next] on the caller's own
                 fiber. A seam that raises (vs returns Error) is contained into a
                 terminal Unavailable on the feed's own channel, then Closed — a
                 broken seam fails only its own feed, never a sibling. *)
              let broken =
                let emitted = ref false in
                let next () =
                  if !emitted then failwith "seam boom"
                  else (
                    emitted := true;
                    Ok (Feed.Item committed_update))
                in
                Feed.subscribe ~sw { Feed.next; close = (fun () -> ()) }
              in
              let sibling =
                Feed.subscribe ~sw (scripted_seam [ Ok committed_update ])
              in
              is_true ~msg:"the committed fact crosses before the fault"
                (is_committed (read_item broken));
              (match read_next broken with
              | `Error (Error.Unavailable _) -> ()
              | `Error e ->
                  failf "expected a contained Unavailable, got %a" Error.pp e
              | `Item _ -> fail "expected the contained seam fault"
              | `Closed -> fail "expected the contained seam fault, got Closed");
              (match read_next broken with
              | `Closed -> ()
              | `Item _ -> fail "expected Closed after the contained fault"
              | `Error _ -> fail "the contained fault must surface only once");
              is_true ~msg:"the sibling feed survived"
                (is_committed (read_item sibling));
              Feed.close sibling));
      test "a raising seam.close during switch release does not break teardown"
        (fun () ->
          with_eio (fun outer ->
              (* [Switch.on_release] runs [close] during teardown; a raise from
                 the untrusted [seam.close] must be contained so the switch tears
                 down cleanly (only Exit escapes) and a sibling under the outer
                 switch survives. *)
              let sibling =
                Feed.subscribe ~sw:outer (scripted_seam [ Ok committed_update ])
              in
              let raising_close =
                let never = Eio.Condition.create () in
                {
                  Feed.next =
                    (fun () ->
                      Eio.Condition.loop_no_mutex never (fun () -> None));
                  close = (fun () -> failwith "seam close boom");
                }
              in
              (try
                 Eio.Switch.run (fun inner ->
                     ignore (Feed.subscribe ~sw:inner raising_close);
                     raise Exit)
               with Exit -> ());
              is_true ~msg:"the sibling survived the release-time seam fault"
                (is_committed (read_item sibling));
              Feed.close sibling));
    ]

(* Login: boxing the raw step-pull. *)

let scripted_login steps ~pulls ~cancels : Login.steps =
  let q = Queue.create () in
  List.iter (fun s -> Queue.push s q) steps;
  let next () =
    incr pulls;
    match Queue.take_opt q with
    | Some step -> step
    | None -> fail "login producer pulled past its scripted terminal"
  in
  let cancel () = incr cancels in
  { Login.next; cancel }

let login_group =
  group "login"
    [
      test "login forwards canonical progress and memoizes Saved" (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let pulls = ref 0 in
              let browser_url = Uri.of_string "https://issuer/authorize" in
              let redirect_uri = Uri.of_string "http://127.0.0.1/callback" in
              let account = missing_account (Llm.Provider.make "openai") in
              let steps =
                scripted_login
                  [
                    Ok (Login.Progress (Login_progress.Browser_url browser_url));
                    Ok
                      (Login.Progress
                         (Login_progress.Listening { redirect_uri }));
                    Ok (Login.Saved account);
                  ]
                  ~pulls ~cancels
              in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ -> Ok steps);
                }
              in
              let client = client_of ~accounts () in
              let login =
                ok
                  (Client.login ~sw client
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              (match Login.next login with
              | Ok (Login.Progress (Login_progress.Browser_url served)) ->
                  is_true ~msg:"the exact Uri.t crosses without stringification"
                    (served == browser_url)
              | _ -> fail "expected Browser_url progress first");
              (match Login.next login with
              | Ok
                  (Login.Progress
                     (Login_progress.Listening { redirect_uri = served })) ->
                  is_true ~msg:"the exact redirect Uri.t crosses"
                    (served == redirect_uri)
              | _ -> fail "expected Listening progress second");
              (match Login.next login with
              | Ok (Login.Saved served) ->
                  is_true ~msg:"the exact Account.t crosses" (served == account)
              | _ -> fail "expected Saved third");
              (match Login.next login with
              | Ok (Login.Saved served) ->
                  is_true ~msg:"Saved is memoized exactly" (served == account)
              | _ -> fail "expected memoized Saved");
              equal int ~msg:"the producer was not pulled after Saved" 3 !pulls;
              equal int ~msg:"no cancel while pulling" 0 !cancels));
      test "Progress is not terminal and may repeat" (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let pulls = ref 0 in
              let redirect_uri = Uri.of_string "http://127.0.0.1/callback" in
              let steps =
                scripted_login
                  [
                    Ok
                      (Login.Progress
                         (Login_progress.Listening { redirect_uri }));
                    Ok
                      (Login.Progress
                         (Login_progress.Listening { redirect_uri }));
                    Ok Login.Cancelled;
                  ]
                  ~pulls ~cancels
              in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ -> Ok steps);
                }
              in
              let login =
                ok
                  (Client.login ~sw (client_of ~accounts ())
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              ignore (ok (Login.next login));
              ignore (ok (Login.next login));
              equal int ~msg:"both progress values pull the producer" 2 !pulls));
      test "the first producer error is terminal and memoized" (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let pulls = ref 0 in
              let steps = scripted_login [ Error swept ] ~pulls ~cancels in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ -> Ok steps);
                }
              in
              let login =
                ok
                  (Client.login ~sw (client_of ~accounts ())
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              List.iter
                (fun result ->
                  match result with
                  | Error error ->
                      equal error_t ~msg:"memoized producer error" swept error
                  | Ok _ -> fail "expected the producer error")
                [ Login.next login; Login.next login ];
              equal int ~msg:"the producer was pulled once" 1 !pulls));
      test "Cancelled is terminal and memoized" (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let pulls = ref 0 in
              let steps =
                scripted_login [ Ok Login.Cancelled ] ~pulls ~cancels
              in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ -> Ok steps);
                }
              in
              let login =
                ok
                  (Client.login ~sw (client_of ~accounts ())
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              List.iter
                (fun result ->
                  match result with
                  | Ok Login.Cancelled -> ()
                  | Ok _ -> fail "expected Cancelled"
                  | Error error -> failf "unexpected error: %a" Error.pp error)
                [ Login.next login; Login.next login ];
              equal int ~msg:"the producer was pulled once" 1 !pulls));
      test "cancel is idempotent and fires the underlying cancel once"
        (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let pulls = ref 0 in
              let redirect_uri = Uri.of_string "http://127.0.0.1/callback" in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ ->
                      Ok
                        (scripted_login
                           [
                             Ok
                               (Login.Progress
                                  (Login_progress.Listening { redirect_uri }));
                           ]
                           ~pulls ~cancels));
                }
              in
              let client = client_of ~accounts () in
              let login =
                ok
                  (Client.login ~sw client
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              Login.cancel login;
              Login.cancel login;
              Login.cancel login;
              equal int ~msg:"underlying cancel ran exactly once" 1 !cancels));
      test "cancel mid-flow, after a step, still fires the cancel once"
        (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let pulls = ref 0 in
              let url = Uri.of_string "https://issuer/device" in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ ->
                      Ok
                        (scripted_login
                           [
                             Ok
                               (Login.Progress
                                  (Login_progress.Device_challenge
                                     {
                                       url;
                                       user_code = "WXYZ";
                                       expires_in = 300;
                                     }));
                           ]
                           ~pulls ~cancels));
                }
              in
              let client = client_of ~accounts () in
              let login =
                ok
                  (Client.login ~sw client
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "device"))
              in
              (match Login.next login with
              | Ok
                  (Login.Progress
                     (Login_progress.Device_challenge
                        { url = served; user_code; expires_in })) ->
                  is_true ~msg:"the exact device Uri.t crosses" (served == url);
                  equal string ~msg:"device code delivered" "WXYZ" user_code;
                  equal int ~msg:"challenge lifetime crosses" 300 expires_in
              | _ -> fail "expected Device_challenge");
              Login.cancel login;
              equal int ~msg:"cancel fired once mid-flow" 1 !cancels));
      test "cancel racing a parked next wakes it with the documented terminal"
        (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ ->
                      Ok (blocking_login ~terminal:Login.Cancelled cancels));
                }
              in
              let client = client_of ~accounts () in
              let login =
                ok
                  (Client.login ~sw client
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              (* One fiber parks on next; another cancels. The cancel wakes the
                 parked pull with the flow's terminal step. *)
              let step = ref None in
              Eio.Fiber.both
                (fun () -> step := Some (Login.next login))
                (fun () ->
                  Eio.Fiber.yield ();
                  Login.cancel login);
              (match !step with
              | Some (Ok Login.Cancelled) -> ()
              | _ -> fail "expected the parked next to wake with Cancelled");
              equal int ~msg:"the underlying cancel ran exactly once" 1 !cancels));
      test "a step pulled after cancel still returns the flow's terminal"
        (fun () ->
          with_eio (fun sw ->
              let cancels = ref 0 in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ ->
                      Ok (blocking_login ~terminal:Login.Cancelled cancels));
                }
              in
              let client = client_of ~accounts () in
              let login =
                ok
                  (Client.login ~sw client
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "device"))
              in
              Login.cancel login;
              match Login.next login with
              | Ok Login.Cancelled -> ()
              | _ -> fail "expected Cancelled after cancel"));
      test "a raising login producer is terminally contained and pulled once"
        (fun () ->
          with_eio (fun sw ->
              let pulls = ref 0 in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ ->
                      Ok
                        {
                          Login.next = (fun () -> raise_driver pulls);
                          cancel = (fun () -> ());
                        });
                }
              in
              let login =
                ok
                  (Client.login ~sw (client_of ~accounts ())
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              expect_unavailable ~operation:"login.next" ~calls:pulls
                (Login.next login);
              expect_unavailable ~operation:"login.next" ~calls:pulls
                (Login.next login)));
      test "login pull cancellation re-raises and does not become terminal"
        (fun () ->
          with_eio (fun sw ->
              let pulls = ref 0 in
              let cause = Failure "login cancelled" in
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ ->
                      Ok
                        {
                          Login.next =
                            (fun () ->
                              incr pulls;
                              if !pulls = 1 then
                                raise (Eio.Cancel.Cancelled cause)
                              else Ok Login.Cancelled);
                          cancel = (fun () -> ());
                        });
                }
              in
              let login =
                ok
                  (Client.login ~sw (client_of ~accounts ())
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              (match Login.next login with
              | _ -> fail "login cancellation returned normally"
              | exception Eio.Cancel.Cancelled served ->
                  is_true ~msg:"the cancellation cause crosses unchanged"
                    (served == cause));
              (match Login.next login with
              | Ok Login.Cancelled -> ()
              | _ -> fail "the producer did not remain pullable");
              (match Login.next login with
              | Ok Login.Cancelled -> ()
              | _ -> fail "the terminal step was not cached");
              equal int ~msg:"cancellation was not cached as a terminal error" 2
                !pulls));
      test
        "a raising steps.cancel during switch release does not break teardown"
        (fun () ->
          with_eio (fun _outer ->
              (* [attach] registers [on_release -> cancel]; a raise from the
                 untrusted [steps.cancel] during teardown must be contained so
                 the switch tears down cleanly and only Exit escapes. *)
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ ->
                      Ok
                        {
                          Login.next =
                            (fun () ->
                              Ok
                                (Login.Progress
                                   (Login_progress.Listening
                                      {
                                        redirect_uri =
                                          Uri.of_string
                                            "http://127.0.0.1/callback";
                                      })));
                          cancel = (fun () -> failwith "steps cancel boom");
                        });
                }
              in
              let client = client_of ~accounts () in
              let completed = ref false in
              (try
                 Eio.Switch.run (fun inner ->
                     ignore
                       (ok
                          (Client.login ~sw:inner client
                             ~provider:(Llm.Provider.make "openai")
                             ~method_:(Provider.Auth.Login.Id.make "browser")));
                     raise Exit)
               with Exit -> completed := true);
              is_true ~msg:"teardown completed; only Exit escaped" !completed));
    ]

(* Accounts: the non-interactive completions forward their arguments. *)

let accounts_group =
  group "accounts: non-interactive completions"
    [
      test "save_api_key and logout forward exact inputs and typed outcomes"
        (fun () ->
          let calls = ref [] in
          let record tag = calls := tag :: !calls in
          let name provider = Llm.Provider.id provider in
          let p = Llm.Provider.make "openai" in
          let saved = missing_account p in
          let logged_out = logout_result p in
          let revoked = logout_result ~revoke:true p in
          let accounts =
            {
              default_accounts with
              Driver.Accounts.save_api_key =
                (fun ~provider ~key ->
                  record (Printf.sprintf "save:%s:%s" (name provider) key);
                  Ok saved);
              logout =
                (fun ?(revoke = false) provider ->
                  record (Printf.sprintf "logout:%s:%b" (name provider) revoke);
                  if revoke then Ok revoked else Ok logged_out);
            }
          in
          let client = client_of ~accounts () in
          is_true ~msg:"the exact saved Account.t crosses"
            (ok (Client.save_api_key client ~provider:p ~key:"sk-123") == saved);
          is_true ~msg:"logout defaults revoke to false"
            (ok (Client.logout client p) == logged_out);
          is_true ~msg:"explicit revocation returns its exact settlement"
            (ok (Client.logout client ~revoke:true p) == revoked);
          equal (list string)
            ~msg:"each completion forwarded its exact request in order"
            [
              "save:openai:sk-123"; "logout:openai:false"; "logout:openai:true";
            ]
            (List.rev !calls));
      test "an empty API key is rejected before the accounts driver" (fun () ->
          let called = ref false in
          let provider = Llm.Provider.make "openai" in
          let account = missing_account provider in
          let accounts =
            {
              default_accounts with
              Driver.Accounts.save_api_key =
                (fun ~provider:served ~key ->
                  called := true;
                  is_true ~msg:"the exact provider would reach the driver"
                    (Llm.Provider.equal provider served);
                  equal string ~msg:"the exact key would reach the driver" ""
                    key;
                  Ok account);
            }
          in
          let client = client_of ~accounts () in
          (match Client.save_api_key client ~provider ~key:"" with
          | Error Error.Invalid_api_key -> ()
          | Error e -> failf "unexpected error: %a" Error.pp e
          | Ok _ -> fail "expected Invalid_api_key");
          is_false ~msg:"the driver was not invoked" !called);
    ]

(* Reads. *)

let reads_group =
  group "reads"
    [
      test "pending_decision forwards to the session responder" (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.pending_decision =
                (fun id ->
                  seen := Some id;
                  Ok None);
            }
          in
          let client = client_of ~session () in
          (match Client.pending_decision client (sid "s") with
          | Ok None -> ()
          | Ok (Some _) -> fail "expected the scripted None"
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some id ->
              is_true ~msg:"session id reached the responder"
                (Session.Id.equal (sid "s") id)
          | None -> fail "the session responder was never called");
      test "account_readiness forwards the exact discovery list" (fun () ->
          let called = ref false in
          let discovery = known_missing (Llm.Provider.make "openai") in
          let readiness = [ discovery ] in
          let accounts =
            {
              default_accounts with
              Driver.Accounts.account_readiness =
                (fun () ->
                  called := true;
                  Ok readiness);
            }
          in
          let client = client_of ~accounts () in
          (match Client.account_readiness client with
          | Ok [ served ] ->
              is_true ~msg:"the exact discovery is forwarded"
                (served == discovery)
          | Ok _ -> fail "unexpected readiness list"
          | Error e -> failf "unexpected error: %a" Error.pp e);
          is_true ~msg:"the accounts responder was called" !called);
      test "model_readiness forwards the exact owner value" (fun () ->
          let called = ref false in
          let readiness =
            Provider.Model_readiness.of_catalog (Provider.Catalog.make [])
              ~discoveries:[]
          in
          let accounts =
            {
              default_accounts with
              Driver.Accounts.model_readiness =
                (fun ?refresh:_ () ->
                  called := true;
                  Ok readiness);
            }
          in
          let client = client_of ~accounts () in
          (match Client.model_readiness client with
          | Ok served ->
              is_true ~msg:"the exact model readiness is forwarded"
                (served == readiness)
          | Error e -> failf "unexpected error: %a" Error.pp e);
          is_true ~msg:"the accounts responder was called" !called);
      test "change_diff forwards session and change" (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.change_diff =
                (fun ~session ~change ->
                  seen := Some (session, change);
                  Ok []);
            }
          in
          let client = client_of ~session () in
          let change = Mutation.Change.Id.of_string "chg-1" in
          (match Client.change_diff client ~session:(sid "s") ~change with
          | Ok [] -> ()
          | Ok _ -> fail "expected the scripted empty hunk list"
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some (session, change') ->
              is_true ~msg:"session and change forwarded"
                (Session.Id.equal (sid "s") session
                && Mutation.Change.Id.equal change change')
          | None -> fail "the session responder was never called");
      test "tail forwards the session and the requested page size" (fun () ->
          let seen = ref None in
          let value =
            {
              Protocol.Transcript.Tail.head = None;
              pending = None;
              page = { Protocol.Transcript.Page.facts = []; before = None };
            }
          in
          let session =
            {
              default_session with
              Driver.Session.tail =
                (fun ?n id ->
                  seen := Some (n, id);
                  Ok value);
            }
          in
          let client = client_of ~session () in
          (match Client.tail client ~n:7 (sid "s") with
          | Ok served ->
              is_true ~msg:"the exact tail is forwarded" (served == value)
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some (Some 7, id) ->
              is_true ~msg:"session id reached the responder"
                (Session.Id.equal (sid "s") id)
          | Some _ -> fail "the page size was not forwarded"
          | None -> fail "the session responder was never called");
      test "page forwards the session, size, and backward position" (fun () ->
          let seen = ref None in
          let value = { Protocol.Transcript.Page.facts = []; before = None } in
          let sent_before =
            Some (Protocol.Position.make ~session:(sid "s") ~seq:3)
          in
          let session =
            {
              default_session with
              Driver.Session.page =
                (fun ?n id ~before ->
                  seen := Some (n, id, before);
                  Ok value);
            }
          in
          let client = client_of ~session () in
          (match Client.page client ~n:9 (sid "s") ~before:sent_before with
          | Ok served ->
              is_true ~msg:"the exact page is forwarded" (served == value)
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some (Some 9, id, Some pos) ->
              is_true ~msg:"session, size, and position reached the responder"
                (Session.Id.equal (sid "s") id
                && Int.equal 3 (Protocol.Position.seq pos))
          | Some _ -> fail "the page arguments were not forwarded"
          | None -> fail "the session responder was never called");
      test "configuration forwards the exact settings view" (fun () ->
          let module Config = Mentat_config in
          let view =
            match
              Config.resolve
                ~env:(fun _ -> None)
                ~user:
                  (Lpath.Abs.of_string_exn "/home/u/config.json", Config.empty)
                ~extra:None
                ~workspace_config:
                  (Config.Disabled
                     {
                       status = "untrusted";
                       project = None;
                       project_local = None;
                     })
                ~overrides:[]
            with
            | Ok resolved -> Config.Resolved.view resolved
            | Error error -> failf "resolve: %s" (Config.Error.message error)
          in
          let called = ref false in
          let settings =
            {
              default_settings with
              Driver.Settings.configuration =
                (fun () ->
                  called := true;
                  Ok view);
            }
          in
          let client = client_of ~settings () in
          (match Client.configuration client with
          | Ok served ->
              is_true ~msg:"the exact view is forwarded" (served == view)
          | Error e -> failf "unexpected error: %a" Error.pp e);
          is_true ~msg:"the settings responder was called" !called);
      test "sessions preserves listing intent and partial diagnostics"
        (fun () ->
          let seen = ref None in
          let diagnostic =
            Mentat_diagnostic.make ~context:"sessions/bad" "bad"
          in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.sessions =
                (fun ~listing ->
                  seen := Some listing;
                  Ok ([], [ diagnostic ]));
            }
          in
          let listing : Session.Listing.t =
            {
              Session.Listing.scope = `All;
              lifecycles = [ Session.Metadata.Status.Active ];
              search = Some "needle";
              limit = Some 2;
            }
          in
          let client = client_of ~lifecycle () in
          (match Client.sessions client listing with
          | Ok ([], [ served ]) ->
              is_true ~msg:"diagnostic crossed whole"
                (Mentat_diagnostic.equal diagnostic served)
          | Ok _ -> fail "unexpected sessions result"
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some served ->
              is_true ~msg:"search survived dispatch"
                (Option.equal String.equal listing.Session.Listing.search
                   served.Session.Listing.search);
              equal (option int) ~msg:"limit survived dispatch"
                listing.Session.Listing.limit served.Session.Listing.limit
          | None -> fail "the lifecycle responder was never called");
      test "session forwards the id to the lifecycle responder" (fun () ->
          let seen = ref None in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.session =
                (fun id ->
                  seen := Some id;
                  Error swept);
            }
          in
          let client = client_of ~lifecycle () in
          (match Client.session client (sid "s") with
          | Error e -> equal error_t ~msg:"error crosses" swept e
          | Ok _ -> fail "expected the scripted error");
          match !seen with
          | Some id ->
              is_true ~msg:"session id reached the responder"
                (Session.Id.equal (sid "s") id)
          | None -> fail "the lifecycle responder was never called");
      test "review_state forwards the focus scope" (fun () ->
          let seen = ref None in
          let view =
            {
              Review.View.title = None;
              base = "HEAD";
              tip = "WORKTREE";
              verdict = Review.Verdict.Pending;
              verdict_freshness = `Pending;
              cursor = Review.Cursor.feature;
              focus = Review.Scope.Feature;
              focus_reviewed = false;
              files = [];
              units = 0;
              reviewed_units = 0;
              open_crs = 0;
              progress = 1.0;
              is_complete = true;
            }
          in
          let review =
            {
              default_review with
              Driver.Review.state =
                (fun ~scope ->
                  seen := Some scope;
                  Ok view);
            }
          in
          let client = client_of ~review () in
          (match Client.review_state client ~scope:Review.Scope.Feature with
          | Ok served ->
              is_true ~msg:"the exact view is forwarded" (served == view)
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some scope ->
              is_true ~msg:"focus scope reached the responder"
                (Review.Scope.equal Review.Scope.Feature scope)
          | None -> fail "the review responder was never called");
      test "reads surface their responder errors unmapped" (fun () ->
          (* These representative reads distinguish the session and account
             responder cones; each error crosses verbatim at its own response
             type. *)
          let check : type a. string -> (a, Error.t) result -> unit =
           fun label result ->
            match result with
            | Ok _ -> failf "%s: expected the responder error to cross" label
            | Error e -> equal error_t ~msg:label swept e
          in
          check "pending_decision"
            (Client.pending_decision
               (client_of
                  ~session:
                    {
                      default_session with
                      Driver.Session.pending_decision = (fun _ -> Error swept);
                    }
                  ())
               (sid "s"));
          check "account_readiness"
            (Client.account_readiness
               (client_of
                  ~accounts:
                    {
                      default_accounts with
                      Driver.Accounts.account_readiness =
                        (fun () -> Error swept);
                    }
                  ()));
          check "model_readiness"
            (Client.model_readiness
               (client_of
                  ~accounts:
                    {
                      default_accounts with
                      Driver.Accounts.model_readiness = (fun ?refresh:_ () -> Error swept);
                    }
                  ()));
          check "change_diff"
            (Client.change_diff
               (client_of
                  ~session:
                    {
                      default_session with
                      Driver.Session.change_diff =
                        (fun ~session:_ ~change:_ -> Error swept);
                    }
                  ())
               ~session:(sid "s")
               ~change:(Mutation.Change.Id.of_string "c"));
          check "tail"
            (Client.tail
               (client_of
                  ~session:
                    {
                      default_session with
                      Driver.Session.tail = (fun ?n:_ _ -> Error swept);
                    }
                  ())
               (sid "s"));
          check "page"
            (Client.page
               (client_of
                  ~session:
                    {
                      default_session with
                      Driver.Session.page =
                        (fun ?n:_ _ ~before:_ -> Error swept);
                    }
                  ())
               (sid "s") ~before:None));
      test "every read contains a raising responder exactly once" (fun () ->
          let listing : Session.Listing.t =
            {
              Session.Listing.scope = `Cwd;
              lifecycles = [];
              search = None;
              limit = None;
            }
          in
          let check operation run =
            let calls = ref 0 in
            expect_unavailable ~operation ~calls (run calls)
          in
          check "pending_decision" (fun calls ->
              Client.pending_decision
                (client_of
                   ~session:
                     {
                       default_session with
                       Driver.Session.pending_decision =
                         (fun _ -> raise_driver calls);
                     }
                   ())
                (sid "s"));
          check "account_readiness" (fun calls ->
              Client.account_readiness
                (client_of
                   ~accounts:
                     {
                       default_accounts with
                       Driver.Accounts.account_readiness =
                         (fun () -> raise_driver calls);
                     }
                   ()));
          check "model_readiness" (fun calls ->
              Client.model_readiness
                (client_of
                   ~accounts:
                     {
                       default_accounts with
                       Driver.Accounts.model_readiness =
                         (fun ?refresh:_ () -> raise_driver calls);
                     }
                   ()));
          check "change_diff" (fun calls ->
              Client.change_diff
                (client_of
                   ~session:
                     {
                       default_session with
                       Driver.Session.change_diff =
                         (fun ~session:_ ~change:_ -> raise_driver calls);
                     }
                   ())
                ~session:(sid "s")
                ~change:(Mutation.Change.Id.of_string "c"));
          check "tail" (fun calls ->
              Client.tail
                (client_of
                   ~session:
                     {
                       default_session with
                       Driver.Session.tail = (fun ?n:_ _ -> raise_driver calls);
                     }
                   ())
                (sid "s"));
          check "page" (fun calls ->
              Client.page
                (client_of
                   ~session:
                     {
                       default_session with
                       Driver.Session.page =
                         (fun ?n:_ _ ~before:_ -> raise_driver calls);
                     }
                   ())
                (sid "s") ~before:None);
          check "configuration" (fun calls ->
              Client.configuration
                (client_of
                   ~settings:
                     {
                       default_settings with
                       Driver.Settings.configuration =
                         (fun () -> raise_driver calls);
                     }
                   ()));
          check "sessions" (fun calls ->
              Client.sessions
                (client_of
                   ~lifecycle:
                     {
                       default_lifecycle with
                       Driver.Lifecycle.sessions =
                         (fun ~listing:_ -> raise_driver calls);
                     }
                   ())
                listing);
          check "session" (fun calls ->
              Client.session
                (client_of
                   ~lifecycle:
                     {
                       default_lifecycle with
                       Driver.Lifecycle.session = (fun _ -> raise_driver calls);
                     }
                   ())
                (sid "s"));
          check "review_state" (fun calls ->
              Client.review_state
                (client_of
                   ~review:
                     {
                       default_review with
                       Driver.Review.state =
                         (fun ~scope:_ -> raise_driver calls);
                     }
                   ())
                ~scope:Review.Scope.Feature);
          check "review_diff" (fun calls ->
              Client.review_diff
                (client_of
                   ~review:
                     {
                       default_review with
                       Driver.Review.diff = (fun ~path:_ -> raise_driver calls);
                     }
                   ())
                ~path:(Lpath.Rel.of_string_exn "lib/a.ml"));
          check "review_crs" (fun calls ->
              Client.review_crs
                (client_of
                   ~review:
                     {
                       default_review with
                       Driver.Review.crs = (fun () -> raise_driver calls);
                     }
                   ()));
          check "workspace_glance" (fun calls ->
              Client.workspace_glance
                (client_of
                   ~workspace:
                     {
                       Driver.Workspace.glance = (fun () -> raise_driver calls);
                       dune = (fun () -> raise_driver calls);
                       dune_control = (fun ~op:_ -> raise_driver calls);
                     }
                   ())));
    ]

(* The review flow. *)

let review_group =
  group "review flow"
    [
      test "review forwards the command to the apply responder" (fun () ->
          let seen = ref None in
          let review =
            {
              default_review with
              Driver.Review.apply =
                (fun command ->
                  seen := Some command;
                  Ok ());
            }
          in
          let client = client_of ~review () in
          let command = Review.Command.Mark_reviewed Review.Scope.Feature in
          (match Client.review client command with
          | Ok () -> ()
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some served ->
              is_true ~msg:"the exact command is forwarded"
                (Review.Command.equal command served)
          | None -> fail "the review responder was never called");
      test "review surfaces the responder error unmapped" (fun () ->
          let review =
            { default_review with Driver.Review.apply = (fun _ -> Error swept) }
          in
          match Client.review (client_of ~review ()) Review.Command.Approve with
          | Ok () -> fail "expected the responder error to cross"
          | Error e -> equal error_t ~msg:"review" swept e);
      test "review_compose forwards the edit to the compose responder"
        (fun () ->
          let seen = ref None in
          let review =
            {
              default_review with
              Driver.Review.compose =
                (fun edit ->
                  seen := Some edit;
                  Ok ());
            }
          in
          let cr =
            match Review.Cr.make ~body:"fix this" () with
            | Ok cr -> cr
            | Error error -> failf "cr make: %a" Review.Cr.Error.pp error
          in
          let edit =
            Review.Cr.Edit.Add
              { path = Lpath.Rel.of_string_exn "lib/a.ml"; line = 1; cr }
          in
          (match Client.review_compose (client_of ~review ()) edit with
          | Ok () -> ()
          | Error e -> failf "unexpected error: %a" Error.pp e);
          match !seen with
          | Some served ->
              is_true ~msg:"the exact edit is forwarded"
                (Review.Cr.Edit.equal edit served)
          | None -> fail "the compose responder was never called");
      test "review contains a raising responder as Unavailable" (fun () ->
          let calls = ref 0 in
          expect_unavailable ~operation:"review" ~calls
            (Client.review
               (client_of
                  ~review:
                    {
                      default_review with
                      Driver.Review.apply = (fun _ -> raise_driver calls);
                    }
                  ())
               Review.Command.Approve));
    ]

(* Settings and lifecycle: passthrough and client-minted ids. *)

let settings_group =
  group "settings"
    [
      test "session-scoped setters forward the exact session and value"
        (fun () ->
          let calls = ref [] in
          let record tag = calls := tag :: !calls in
          let settings =
            {
              Driver.Settings.set_model =
                (fun ~session ?reasoning_effort selector ->
                  record
                    (Printf.sprintf "set_model:%s:%s:%s"
                       (Session.Id.to_string session)
                       (Provider.Selector.to_string selector)
                       (Option.fold ~none:"default"
                          ~some:Llm.Request.Options.Reasoning_effort.to_string
                          reasoning_effort));
                  Ok ());
              set_permission_review =
                (fun ~session review ->
                  let review =
                    match review with
                    | Permission.Review_behavior.Enforce -> "enforce"
                    | Permission.Review_behavior.Bypass -> "bypass"
                  in
                  record
                    ("set_permission_review:"
                    ^ Session.Id.to_string session
                    ^ ":" ^ review);
                  Ok ());
              configuration = default_settings.Driver.Settings.configuration;
              set_default_model =
                default_settings.Driver.Settings.set_default_model;
              set_ui_theme = default_settings.Driver.Settings.set_ui_theme;
            }
          in
          let client = client_of ~settings () in
          let s = sid "s" in
          ok
            (Client.set_model client ~session:s
               ~reasoning_effort:Llm.Request.Options.Reasoning_effort.High
               (Provider.Selector.make
                  ~provider:(Llm.Provider.make "openai")
                  ~id:"gpt-5"));
          ok
            (Client.set_model client ~session:s
               (Provider.Selector.make
                  ~provider:(Llm.Provider.make "anthropic")
                  ~id:"claude-sonnet-4-5"));
          ok
            (Client.set_permission_review client ~session:s
               Permission.Review_behavior.Bypass);
          equal (list string)
            ~msg:"each setter forwarded its exact session and value"
            [
              "set_model:s:openai/gpt-5:high";
              "set_model:s:anthropic/claude-sonnet-4-5:default";
              "set_permission_review:s:bypass";
            ]
            (List.rev !calls));
    ]

let lifecycle_group =
  group "lifecycle: client-minted ids and error passthrough"
    [
      test "create forwards the client-minted id and title" (fun () ->
          let seen = ref None in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.create =
                (fun ~id ~title ->
                  seen := Some (id, title);
                  Ok ());
            }
          in
          let client = client_of ~lifecycle () in
          ok (Client.create client ~id:(sid "new") ~title:"Draft" ());
          match !seen with
          | Some (id, title) ->
              is_true ~msg:"the client's id and title reached the driver"
                (Session.Id.equal (sid "new") id && title = Some "Draft")
          | None -> fail "create never reached the driver");
      test "empty lifecycle titles are rejected before the driver" (fun () ->
          let create_calls = ref 0 in
          let rename_calls = ref 0 in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.create =
                (fun ~id:_ ~title:_ ->
                  incr create_calls;
                  Ok ());
              rename =
                (fun ~session:_ ~title:_ ->
                  incr rename_calls;
                  Ok ());
            }
          in
          let client = client_of ~lifecycle () in
          (match Client.create client ~id:(sid "new") ~title:"" () with
          | Error Error.Invalid_title -> ()
          | Error e -> failf "unexpected create error: %a" Error.pp e
          | Ok () -> fail "expected Invalid_title from create");
          (match Client.rename client ~session:(sid "new") ~title:"" with
          | Error Error.Invalid_title -> ()
          | Error e -> failf "unexpected rename error: %a" Error.pp e
          | Ok () -> fail "expected Invalid_title from rename");
          equal int ~msg:"create did not reach the driver" 0 !create_calls;
          equal int ~msg:"rename did not reach the driver" 0 !rename_calls);
      test "fork carries both client-minted ids" (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.fork =
                (fun ~session ~into ->
                  seen := Some (session, into);
                  Ok ());
            }
          in
          let client = client_of ~session () in
          ok (Client.fork client ~session:(sid "src") ~into:(sid "child") ());
          match !seen with
          | Some (source, into) ->
              is_true ~msg:"source and client-minted child forwarded"
                (Session.Id.equal (sid "src") source
                && Session.Id.equal (sid "child") into)
          | None -> fail "fork never reached the driver");
      test "rewind carries both ids and the anchor" (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.rewind =
                (fun ~session ~into ~anchor ->
                  seen := Some (session, into, anchor);
                  Ok ());
            }
          in
          let client = client_of ~session () in
          let anchor = Session.Anchor.before_turn (tid "turn-1") in
          ok
            (Client.rewind client ~session:(sid "src") ~into:(sid "child")
               ~anchor);
          match !seen with
          | Some (source, into, anchor') ->
              is_true ~msg:"ids and anchor forwarded"
                (Session.Id.equal (sid "src") source
                && Session.Id.equal (sid "child") into
                && Session.Anchor.equal anchor anchor')
          | None -> fail "rewind never reached the driver");
      test "delete surfaces a driver error unmapped" (fun () ->
          let err = Error.Archived (sid "s") in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.delete = (fun ~session:_ -> Error err);
            }
          in
          let client = client_of ~lifecycle () in
          match Client.delete client ~session:(sid "s") with
          | Ok () -> fail "expected the error to cross"
          | Error e -> equal error_t ~msg:"error crosses unmapped" err e);
      test "compact returns the driver's typed outcome" (fun () ->
          let session =
            {
              default_session with
              Driver.Session.compact =
                (fun ~session:_ ~turn:_ -> Ok Client.Skipped);
            }
          in
          let client = client_of ~session () in
          match Client.compact client ~session:(sid "s") ~turn:(tid "c") with
          | Ok Client.Skipped -> ()
          | Ok _ -> fail "expected Skipped"
          | Error e -> failf "unexpected error: %a" Error.pp e);
      test "compact forwards the caller's turn id unchanged" (fun () ->
          (* The client mints no id: it faithfully forwards the caller's. *)
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.compact =
                (fun ~session:_ ~turn ->
                  seen := Some turn;
                  Ok Client.Installed);
            }
          in
          let client = client_of ~session () in
          (match
             Client.compact client ~session:(sid "s") ~turn:(tid "c-42")
           with
          | Ok Client.Installed -> ()
          | _ -> fail "expected Installed");
          match !seen with
          | Some turn ->
              equal string ~msg:"the driver saw the caller's turn id" "c-42"
                (Session.Turn.Id.to_string turn)
          | None -> fail "the driver was never called");
      test "rapid create/fork/rewind forward distinct client-minted ids"
        (fun () ->
          (* The client mints no ids: it faithfully forwards the caller's, so
             distinct ids arrive distinct and unchanged, in call order. *)
          let minted = ref [] in
          let record id = minted := Session.Id.to_string id :: !minted in
          let session =
            {
              default_session with
              Driver.Session.fork =
                (fun ~session:_ ~into ->
                  record into;
                  Ok ());
              rewind =
                (fun ~session:_ ~into ~anchor:_ ->
                  record into;
                  Ok ());
            }
          in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.create =
                (fun ~id ~title:_ ->
                  record id;
                  Ok ());
            }
          in
          let client = client_of ~session ~lifecycle () in
          ok (Client.create client ~id:(sid "s1") ());
          ok (Client.fork client ~session:(sid "s1") ~into:(sid "s2") ());
          ok
            (Client.rewind client ~session:(sid "s1") ~into:(sid "s3")
               ~anchor:(Session.Anchor.before_turn (tid "t")));
          ok (Client.create client ~id:(sid "s4") ());
          equal (list string)
            ~msg:"each op forwarded its own distinct id, in order"
            [ "s1"; "s2"; "s3"; "s4" ] (List.rev !minted));
      test "archive then restore both reach the store (archive is reversible)"
        (fun () ->
          (* archive/restore round-trip; delete is documented terminal (no
             inverse op exists on the surface to test at runtime). *)
          let calls = ref [] in
          let lifecycle =
            {
              default_lifecycle with
              Driver.Lifecycle.archive =
                (fun ~session ->
                  calls := ("archive:" ^ Session.Id.to_string session) :: !calls;
                  Ok ());
              restore =
                (fun ~session ->
                  calls := ("restore:" ^ Session.Id.to_string session) :: !calls;
                  Ok ());
            }
          in
          let client = client_of ~lifecycle () in
          ok (Client.archive client ~session:(sid "s"));
          ok (Client.restore client ~session:(sid "s"));
          equal (list string) ~msg:"archive is reversible via restore"
            [ "archive:s"; "restore:s" ]
            (List.rev !calls));
    ]

(* Error passthrough: every unit-returning flow surfaces the driver's error
   unmapped (error unification — one Error.t escapes). *)

let error_passthrough_group =
  group "error passthrough"
    [
      test "every unit-returning flow crosses a driver error unmapped"
        (fun () ->
          let check label = function
            | Ok () ->
                failf "%s: expected the driver error to cross, got Ok" label
            | Error e -> equal error_t ~msg:label swept e
          in
          let s = sid "s" in
          let provider = Llm.Provider.make "openai" in
          let ops : (string * (unit -> (unit, Error.t) result)) list =
            [
              ( "answer_unattended",
                fun () ->
                  Client.answer_unattended
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.answer_unattended =
                             (fun ~session:_ ~decision:_ -> Error swept);
                         }
                       ())
                    ~session:s
                    ~decision:(Session.Decision.Id.of_string "d") );
              ( "fork",
                fun () ->
                  Client.fork
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.fork =
                             (fun ~session:_ ~into:_ -> Error swept);
                         }
                       ())
                    ~session:s ~into:(sid "c") () );
              ( "rewind",
                fun () ->
                  Client.rewind
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.rewind =
                             (fun ~session:_ ~into:_ ~anchor:_ -> Error swept);
                         }
                       ())
                    ~session:s ~into:(sid "c")
                    ~anchor:(Session.Anchor.before_turn (tid "t")) );
              ( "compact",
                fun () ->
                  Result.map
                    (fun _ -> ())
                    (Client.compact
                       (client_of
                          ~session:
                            {
                              default_session with
                              Driver.Session.compact =
                                (fun ~session:_ ~turn:_ -> Error swept);
                            }
                          ())
                       ~session:s ~turn:(tid "c")) );
              ( "save_api_key",
                fun () ->
                  Result.map
                    (fun _ -> ())
                    (Client.save_api_key
                       (client_of
                          ~accounts:
                            {
                              default_accounts with
                              Driver.Accounts.save_api_key =
                                (fun ~provider:_ ~key:_ -> Error swept);
                            }
                          ())
                       ~provider ~key:"k") );
              ( "logout",
                fun () ->
                  Result.map
                    (fun _ -> ())
                    (Client.logout
                       (client_of
                          ~accounts:
                            {
                              default_accounts with
                              Driver.Accounts.logout =
                                (fun ?revoke provider ->
                                  ignore revoke;
                                  ignore provider;
                                  Error swept);
                            }
                          ())
                       provider) );
              ( "set_model",
                fun () ->
                  Client.set_model
                    (client_of
                       ~settings:
                         {
                           default_settings with
                           Driver.Settings.set_model =
                             (fun ~session ?reasoning_effort selector ->
                               if
                                 Session.Id.equal session s
                                 && Option.is_none reasoning_effort
                                 && Provider.Selector.equal selector
                                      (Provider.Selector.make ~provider
                                         ~id:"gpt-5")
                               then Error swept
                               else fail "unexpected set_model arguments");
                         }
                       ())
                    ~session:s
                    (Provider.Selector.make ~provider ~id:"gpt-5") );
              ( "set_permission_review",
                fun () ->
                  Client.set_permission_review
                    (client_of
                       ~settings:
                         {
                           default_settings with
                           Driver.Settings.set_permission_review =
                             (fun ~session:_ _ -> Error swept);
                         }
                       ())
                    ~session:s Permission.Review_behavior.Bypass );
              ( "create",
                fun () ->
                  Client.create
                    (client_of
                       ~lifecycle:
                         {
                           default_lifecycle with
                           Driver.Lifecycle.create =
                             (fun ~id:_ ~title:_ -> Error swept);
                         }
                       ())
                    ~id:(sid "n") () );
              ( "rename",
                fun () ->
                  Client.rename
                    (client_of
                       ~lifecycle:
                         {
                           default_lifecycle with
                           Driver.Lifecycle.rename =
                             (fun ~session:_ ~title:_ -> Error swept);
                         }
                       ())
                    ~session:s ~title:"t" );
              ( "archive",
                fun () ->
                  Client.archive
                    (client_of
                       ~lifecycle:
                         {
                           default_lifecycle with
                           Driver.Lifecycle.archive =
                             (fun ~session:_ -> Error swept);
                         }
                       ())
                    ~session:s );
              ( "restore",
                fun () ->
                  Client.restore
                    (client_of
                       ~lifecycle:
                         {
                           default_lifecycle with
                           Driver.Lifecycle.restore =
                             (fun ~session:_ -> Error swept);
                         }
                       ())
                    ~session:s );
            ]
          in
          List.iter (fun (label, run) -> check label (run ())) ops);
      test "login surfaces a driver refusal without a login handle" (fun () ->
          with_eio (fun sw ->
              let accounts =
                {
                  default_accounts with
                  Driver.Accounts.login =
                    (fun ~provider:_ ~method_:_ -> Error swept);
                }
              in
              let client = client_of ~accounts () in
              match
                Client.login ~sw client
                  ~provider:(Llm.Provider.make "openai")
                  ~method_:(Provider.Auth.Login.Id.make "browser")
              with
              | Ok _ -> fail "expected the refusal to cross"
              | Error e -> equal error_t ~msg:"login refusal crosses" swept e));
    ]

let exception_containment_group =
  group "driver exception containment"
    [
      test "session and account operations contain a raising driver once"
        (fun () ->
          with_eio (fun sw ->
              let check operation run =
                let calls = ref 0 in
                expect_unavailable ~operation ~calls (run calls)
              in
              check "submit" (fun calls ->
                  Client.submit
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.submit = (fun _ -> raise_driver calls);
                         }
                       ())
                    (Protocol.Command.clear_queued ~session:(sid "s")));
              check "follow_session" (fun calls ->
                  Result.map
                    (fun _ -> ())
                    (Client.follow_session ~sw
                       (client_of
                          ~session:
                            {
                              default_session with
                              Driver.Session.follow =
                                (fun _ ~from:_ -> raise_driver calls);
                            }
                          ())
                       (sid "s") ~from:`Now));
              check "answer_unattended" (fun calls ->
                  Client.answer_unattended
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.answer_unattended =
                             (fun ~session:_ ~decision:_ -> raise_driver calls);
                         }
                       ())
                    ~session:(sid "s")
                    ~decision:(Session.Decision.Id.of_string "d"));
              check "fork" (fun calls ->
                  Client.fork
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.fork =
                             (fun ~session:_ ~into:_ -> raise_driver calls);
                         }
                       ())
                    ~session:(sid "s") ~into:(sid "child") ());
              check "rewind" (fun calls ->
                  Client.rewind
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.rewind =
                             (fun ~session:_ ~into:_ ~anchor:_ ->
                               raise_driver calls);
                         }
                       ())
                    ~session:(sid "s") ~into:(sid "child")
                    ~anchor:(Session.Anchor.before_turn (tid "t")));
              check "compact" (fun calls ->
                  Client.compact
                    (client_of
                       ~session:
                         {
                           default_session with
                           Driver.Session.compact =
                             (fun ~session:_ ~turn:_ -> raise_driver calls);
                         }
                       ())
                    ~session:(sid "s") ~turn:(tid "c"));
              check "login" (fun calls ->
                  Client.login ~sw
                    (client_of
                       ~accounts:
                         {
                           default_accounts with
                           Driver.Accounts.login =
                             (fun ~provider:_ ~method_:_ -> raise_driver calls);
                         }
                       ())
                    ~provider:(Llm.Provider.make "openai")
                    ~method_:(Provider.Auth.Login.Id.make "browser"));
              check "save_api_key" (fun calls ->
                  Client.save_api_key
                    (client_of
                       ~accounts:
                         {
                           default_accounts with
                           Driver.Accounts.save_api_key =
                             (fun ~provider:_ ~key:_ -> raise_driver calls);
                         }
                       ())
                    ~provider:(Llm.Provider.make "openai")
                    ~key:"key");
              check "logout" (fun calls ->
                  Client.logout
                    (client_of
                       ~accounts:
                         {
                           default_accounts with
                           Driver.Accounts.logout =
                             (fun ?revoke provider ->
                               ignore revoke;
                               ignore provider;
                               raise_driver calls);
                         }
                       ())
                    (Llm.Provider.make "openai"))));
      test "settings and lifecycle operations contain a raising driver once"
        (fun () ->
          let check operation run =
            let calls = ref 0 in
            expect_unavailable ~operation ~calls (run calls)
          in
          check "set_model" (fun calls ->
              Client.set_model
                (client_of
                   ~settings:
                     {
                       default_settings with
                       Driver.Settings.set_model =
                         (fun ~session:_ ?reasoning_effort:_ _ ->
                           raise_driver calls);
                     }
                   ())
                ~session:(sid "s")
                (Provider.Selector.make
                   ~provider:(Llm.Provider.make "openai")
                   ~id:"gpt-5"));
          check "set_permission_review" (fun calls ->
              Client.set_permission_review
                (client_of
                   ~settings:
                     {
                       default_settings with
                       Driver.Settings.set_permission_review =
                         (fun ~session:_ _ -> raise_driver calls);
                     }
                   ())
                ~session:(sid "s") Permission.Review_behavior.Bypass);
          check "create" (fun calls ->
              Client.create
                (client_of
                   ~lifecycle:
                     {
                       default_lifecycle with
                       Driver.Lifecycle.create =
                         (fun ~id:_ ~title:_ -> raise_driver calls);
                     }
                   ())
                ~id:(sid "new") ());
          check "rename" (fun calls ->
              Client.rename
                (client_of
                   ~lifecycle:
                     {
                       default_lifecycle with
                       Driver.Lifecycle.rename =
                         (fun ~session:_ ~title:_ -> raise_driver calls);
                     }
                   ())
                ~session:(sid "s") ~title:"title");
          check "archive" (fun calls ->
              Client.archive
                (client_of
                   ~lifecycle:
                     {
                       default_lifecycle with
                       Driver.Lifecycle.archive =
                         (fun ~session:_ -> raise_driver calls);
                     }
                   ())
                ~session:(sid "s"));
          check "restore" (fun calls ->
              Client.restore
                (client_of
                   ~lifecycle:
                     {
                       default_lifecycle with
                       Driver.Lifecycle.restore =
                         (fun ~session:_ -> raise_driver calls);
                     }
                   ())
                ~session:(sid "s"));
          check "delete" (fun calls ->
              Client.delete
                (client_of
                   ~lifecycle:
                     {
                       default_lifecycle with
                       Driver.Lifecycle.delete =
                         (fun ~session:_ -> raise_driver calls);
                     }
                   ())
                ~session:(sid "s")));
      test "a returned driver error keeps its identity and is invoked once"
        (fun () ->
          let calls = ref 0 in
          let returned =
            Error.Unavailable (Mentat_diagnostic.make "returned unchanged")
          in
          let session =
            {
              default_session with
              Driver.Session.submit =
                (fun _ ->
                  incr calls;
                  Error returned);
            }
          in
          (match
             Client.submit (client_of ~session ())
               (Protocol.Command.clear_queued ~session:(sid "s"))
           with
          | Error served ->
              is_true ~msg:"the exact returned error crosses"
                (served == returned)
          | Ok () -> fail "the returned driver error was lost");
          equal int ~msg:"the driver was invoked once" 1 !calls);
      test "driver cancellation is re-raised unchanged after one invocation"
        (fun () ->
          let calls = ref 0 in
          let cause = Failure "submit cancelled" in
          let session =
            {
              default_session with
              Driver.Session.submit =
                (fun _ ->
                  incr calls;
                  raise (Eio.Cancel.Cancelled cause));
            }
          in
          (match
             Client.submit (client_of ~session ())
               (Protocol.Command.clear_queued ~session:(sid "s"))
           with
          | _ -> fail "driver cancellation returned normally"
          | exception Eio.Cancel.Cancelled served ->
              is_true ~msg:"the cancellation cause crosses unchanged"
                (served == cause));
          equal int ~msg:"the cancelled driver was invoked once" 1 !calls);
    ]

(* The suite's law-coverage map. The library owns the no-engine-reach and
   admission-honesty laws and the thin feed wrapper's own contract;
   committed-before-progress, bounded drop-oldest progress, and
   never-drop-committed are the PRODUCER's obligations, pinned engine-side
   (test_agent_next) — the client wrapper adds no buffer of its own, so it only
   forwards and contains faults.

   - No engine reach: a compile-time fact of the library's own dune stanza —
     mentat_client links protocol + value vocabularies + eio only. The forward
     exclusion is guarded against regression by the client_law8 dune rule
     (test/unit/dune), which fails the build if the client stanza ever lists a
     forbidden effect library (engine/store/session store/provider
     runtime/workspace IO); the transitive closure is review-verified. This suite
     cannot violate that law and does not re-check it at runtime.
   - Admission and completion honest: "submit forwards …/returns durable
     admission", "submit surfaces a refusal verbatim", and the whole "error
     passthrough" group — every flow returns the driver's Result unchanged, never
     a queue promise; the single-Error.t escape is the "each query arm …" and
     "every unit-returning flow …" sweeps. The exception-containment group pins
     the other driver behavior: one invocation, generic operation-labelled
     Unavailable, no exception prose, and cancellation re-raised unchanged.
   - Feed wrapper contract: "the wrapper forwards seam outcomes in order" and
     "committed facts cross before a returned seam error" pin faithful, buffer-free
     forwarding (the ordering it forwards is the producer's, laws 2/3/10, tested
     engine-side); "a raising seam next is contained" pins fault isolation (law
     10's feed isolation at the wrapper); "a returned seam error crosses unmapped"
     pins error passthrough with seam-owned terminality.
   O11 (one fiber per feed, close wakes a parked next): "close wakes a parked next
   …", "an empty catch-up keeps the feed live …", "close from two fibers …",
   "releasing the subscribing switch …". O10 (client-minted ids): create/fork/
   rewind forwarding tests. O13 (login pull + idempotent cancel): the login
   group. *)

(* User-command queries: the two responders are required injection points into
   [Client.make]. A backend that declines commands supplies responders returning
   a typed error; the client forwards whatever they return. *)

let commands_name s = Result.get_ok (Protocol.User_command.Name.of_string s)

let commands_group =
  let sample =
    {
      Protocol.User_command.name = commands_name "review";
      description = Some "Review a PR";
      argument_hint = None;
      scope = Protocol.User_command.Project;
    }
  in
  group "user commands"
    [
      test "user_commands forwards the responder's list" (fun () ->
          let client = client_of ~user_commands:(fun () -> Ok [ sample ]) () in
          match Client.user_commands client with
          | Ok [ c ] ->
              equal string "review"
                (Protocol.User_command.Name.to_string
                   c.Protocol.User_command.name)
          | Ok _ -> fail "expected exactly one command"
          | Error _ -> fail "unexpected error");
      test "user_commands forwards a declining responder's error" (fun () ->
          let client =
            client_of
              ~user_commands:(fun () ->
                Error
                  (Error.Unavailable (Mentat_diagnostic.make "no commands here")))
              ()
          in
          match Client.user_commands client with
          | Error (Error.Unavailable _) -> ()
          | Error _ -> fail "expected Unavailable"
          | Ok _ -> fail "expected an error");
      test "expand_command forwards the expanded content" (fun () ->
          let client =
            client_of
              ~expand_command:(fun ~name:_ ~arguments:_ ->
                Ok [ Llm.Content.text "Hello" ])
              ()
          in
          match Client.expand_command client ~name:"review" ~arguments:"1" with
          | Ok [ Llm.Content.Text s ] -> equal string "Hello" s
          | _ -> fail "expected one text block");
      test "expand_command surfaces Unknown_command" (fun () ->
          let client =
            client_of
              ~expand_command:(fun ~name:_ ~arguments:_ ->
                Error (Error.Unknown_command (commands_name "review")))
              ()
          in
          match Client.expand_command client ~name:"review" ~arguments:"1" with
          | Error (Error.Unknown_command n) ->
              equal string "review" (Protocol.User_command.Name.to_string n)
          | _ -> fail "expected Unknown_command");
      test "expand_command forwards a declining responder's error" (fun () ->
          let client =
            client_of
              ~expand_command:(fun ~name:_ ~arguments:_ ->
                Error
                  (Error.Unavailable (Mentat_diagnostic.make "no commands here")))
              ()
          in
          match Client.expand_command client ~name:"x" ~arguments:"" with
          | Error (Error.Unavailable _) -> ()
          | _ -> fail "expected Unavailable");
    ]

(* The W3 online-cone waist fields: each facade op reaches its driver field with
   the exact arguments and returns the driver's value unchanged. *)
let waist_group =
  let provider = Llm.Provider.make "openai" in
  group "waist: revert / export / set_default_model"
    [
      test "revert forwards the scope and returns the driver's outcome"
        (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.revert =
                (fun ~session ~scope ->
                  seen := Some (session, scope);
                  Ok Mutation.Revert.Outcome.Nothing_to_revert);
            }
          in
          let client = client_of ~session () in
          (match
             Client.revert client ~session:(sid "s")
               ~scope:Mutation.Revert.Scope.Latest
           with
          | Ok Mutation.Revert.Outcome.Nothing_to_revert -> ()
          | Ok _ -> fail "the outcome did not cross unchanged"
          | Error e -> failf "revert refused: %a" Error.pp e);
          match !seen with
          | Some (session, Mutation.Revert.Scope.Latest) ->
              is_true ~msg:"the exact session and scope reached the driver"
                (Session.Id.equal (sid "s") session)
          | _ -> fail "revert did not reach the driver with the scope");
      test "export forwards the session and returns the driver's bundle"
        (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.export =
                (fun ~session ->
                  seen := Some session;
                  Ok "{\"bundle\":true}");
            }
          in
          let client = client_of ~session () in
          equal string ~msg:"the bundle crosses unchanged" "{\"bundle\":true}"
            (ok (Client.export client ~session:(sid "s")));
          is_true ~msg:"the exact session reached the driver"
            (match !seen with
            | Some s -> Session.Id.equal (sid "s") s
            | None -> false));
      test "set_default_model forwards the sessionless selection to settings"
        (fun () ->
          let seen = ref None in
          let settings =
            {
              default_settings with
              Driver.Settings.set_default_model =
                (fun ?reasoning_effort selector ->
                  seen := Some (reasoning_effort, selector);
                  Ok ());
            }
          in
          let client = client_of ~settings () in
          ok
            (Client.set_default_model client
               (Provider.Selector.make ~provider ~id:"gpt-5"));
          match !seen with
          | Some (None, selector) ->
              is_true ~msg:"the exact selector reached settings, no effort"
                (Provider.Selector.equal selector
                   (Provider.Selector.make ~provider ~id:"gpt-5"))
          | _ -> fail "set_default_model did not reach the driver");
    ]

let () =
  run "mentat.client"
    [
      commands_group;
      submission_group;
      follow_group;
      feed_group;
      login_group;
      accounts_group;
      reads_group;
      review_group;
      settings_group;
      waist_group;
      lifecycle_group;
      error_passthrough_group;
      exception_containment_group;
    ]
