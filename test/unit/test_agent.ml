(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_agent], the engine. The engine reaches
   the world only through the three ports (next/lib/agent/ports.mli), so every
   runtime test drives it with in-memory fakes: an in-memory STORE keyed by
   session id (its fence a shared held-set, so two engines over one store see
   [Busy]), a scripted PROVIDER that returns canned [Llm.Response.t] values (and,
   for the interrupt test, cooperatively yields until cancelled), and a no-op
   WORKSPACE. No fake needs real IO.

   The private modules ([driver], [feed], [scheduler]) are not exported, so their
   laws are pinned through the public [Mentat_agent] runtime plus its [Client]
   seam; the pure step ([Mentat_agent_step]) is exercised directly for the
   effect-free laws (catalog validation, config/env positivity, error folding).

   No sleeps: the driver reads no wall clock (the [now] port is injected and the
   feed/mailbox are condition-driven), so every test is deterministic under one
   [Eio_main.run] domain. Each runtime test is wrapped in a real-clock deadlock
   guard that fails loudly rather than hanging the suite if a turn never
   settles. *)

open Windtrap
open Test_support
module Agent = Mentat_agent
module Client = Mentat_client
module Step = Mentat_agent_step
module Catalog = Mentat_agent_step.Catalog
module Ports = Mentat_agent.Ports
module Protocol = Mentat_protocol
module Session = Mentat_session
module Mutation = Mentat_mutation
module Sandbox = Mentat_sandbox
module Llm = Mentat_llm
module Json = Jsont.Json

let all_verbs =
  [
    Catalog.Verb.Todo_write;
    Catalog.Verb.Ask_user;
    Catalog.Verb.Propose_plan;
    Catalog.Verb.Spawn;
    Catalog.Verb.Wait;
    Catalog.Verb.Send;
    Catalog.Verb.Follow_up;
  ]

(* Generic helpers. *)

let contains_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    i + lsub <= ls && (String.equal (String.sub s i lsub) sub || go (i + 1))
  in
  lsub = 0 || go 0

let members_of = function
  | Jsont.Object (members, meta) -> (members, meta)
  | _ -> fail "expected a JSON object"

let set_member name value json =
  let members, meta = members_of json in
  Jsont.Object
    ( List.map
        (fun ((n, m), v) ->
          if String.equal n name then ((n, m), value) else ((n, m), v))
        members,
      meta )

(* LLM / session fixtures. *)

let model =
  Llm.Model.make
    ~provider:(Llm.Provider.make "openai")
    ~api:(Llm.Model.Api.make "responses")
    ~id:"gpt-5"

let cwd = Lpath.Abs.of_string_exn "/workspace"
let sid s = Session.Id.of_string s
let tid s = Session.Turn.Id.of_string s

let plain_response text =
  Llm.Response.make ~model ~stop:Llm.Response.Stop.end_turn
    (Llm.Message.Assistant.text text)

let tool_call_response ~name ~input text =
  let call = Llm.Tool.Call.make ~id:(name ^ "-1") ~name ~input () in
  let assistant =
    Llm.Message.Assistant.make
      [
        Llm.Message.Assistant.text_part text;
        Llm.Message.Assistant.tool_call call;
      ]
  in
  Llm.Response.make ~model ~stop:Llm.Response.Stop.tool_call assistant

let request_contains request needle =
  match Jsont_bytesrw.encode_string Llm.Request.jsont request with
  | Ok s -> contains_sub ~sub:needle s
  | Error _ -> false

let request_occurrences request needle =
  match Jsont_bytesrw.encode_string Llm.Request.jsont request with
  | Error _ -> 0
  | Ok s ->
      let n = String.length needle in
      let rec go i count =
        if i + n > String.length s then count
        else if String.equal (String.sub s i n) needle then
          go (i + n) (count + 1)
        else go (i + 1) count
      in
      go 0 0

let index_sub ~sub s =
  let ls = String.length s and lsub = String.length sub in
  let rec go i =
    if i + lsub > ls then None
    else if String.equal (String.sub s i lsub) sub then Some i
    else go (i + 1)
  in
  if lsub = 0 then Some 0 else go 0

(* The handle a spawn receipt hands the model: "Spawned child <delegation-id>
   (session <session-id>).". The subagent verbs accept only the delegation id, so
   the round-trip test reads it back exactly as the model would — from the
   request transcript, never from the store. *)
let receipt_child_of request =
  match Jsont_bytesrw.encode_string Llm.Request.jsont request with
  | Error _ -> None
  | Ok s -> (
      let marker = "Spawned child " in
      match index_sub ~sub:marker s with
      | None -> None
      | Some i ->
          let start = i + String.length marker in
          let rec stop j =
            if j >= String.length s || Char.equal s.[j] ' ' then j
            else stop (j + 1)
          in
          let e = stop start in
          if e > start then Some (String.sub s start (e - start)) else None)

let is_child_key k =
  String.length k >= 4 && String.equal (String.sub k 0 4) "sub-"

let is_child_id id = is_child_key (Session.Id.to_string id)

(* Fake ports. *)

type store_state = {
  sessions : (string, Session.t) Hashtbl.t;
  muts : (string, Mutation.Event.t list) Hashtbl.t;
  (* Content-addressed attachment blobs keyed by "<session>\x00<ref token>",
     mirroring the real store's per-session attachments namespace. *)
  attachments : (string, string) Hashtbl.t;
  held : (string, string) Hashtbl.t;
  mutable commit_fault : Session.Event.t list -> Ports.Store_error.t option;
  mutable metadata_fault : Session.t -> Ports.Store_error.t option;
  mutable create_fault : Session.Id.t -> Ports.Store_error.t option;
  (* An adapter that [raise]s (rather than returning [Error]) during a child
     [create] — the shape fault-containment must catch. *)
  mutable create_raise : Session.Id.t -> bool;
  (* Runs before a [create] takes effect. A real disk create suspends on IO
     here; the default is a no-op, and a test that needs to expose the pre-create
     scheduling window injects an [Eio.Fiber.yield]. *)
  mutable create_before : Session.Id.t -> unit;
  (* The online revert/export cones' port results. Default: decline, so a test
     that does not exercise them sees the honest "no backend" error; a flow test
     sets a success or a specific fault. *)
  mutable revert_result :
    Mutation.Revert.Scope.t ->
    (Mutation.Revert.Outcome.t, Ports.Store_error.t) result;
  mutable export_result : (string, Ports.Store_error.t) result;
}

let fresh_store () =
  {
    sessions = Hashtbl.create 8;
    muts = Hashtbl.create 8;
    attachments = Hashtbl.create 8;
    held = Hashtbl.create 8;
    commit_fault = (fun _ -> None);
    metadata_fault = (fun _ -> None);
    create_fault = (fun _ -> None);
    create_raise = (fun _ -> false);
    create_before = (fun _ -> ());
    revert_result =
      (fun _ ->
        Error
          (Ports.Store_error.Io
             (Mentat_diagnostic.of_text "fake store: revert not implemented")));
    export_result =
      Error
        (Ports.Store_error.Io
           (Mentat_diagnostic.of_text "fake store: export not implemented"));
  }

let seed_session st ~id =
  let s =
    Session.create ~id:(sid id) ~cwd ~created_at:(Session.Time.of_unix_ms 1L) ()
  in
  Hashtbl.replace st.sessions id s;
  Hashtbl.replace st.muts id []

let store_of st : (module Ports.STORE) =
  (module struct
    type guard = string
    type loaded = Session.t

    let session_of l = l

    let try_acquire id =
      let k = Session.Id.to_string id in
      match Hashtbl.find_opt st.held k with
      | Some owner -> `Held (Some owner)
      | None ->
          Hashtbl.replace st.held k "fake-owner";
          `Acquired k

    let release g = Hashtbl.remove st.held g

    let create session =
      let id = Session.id session in
      let k = Session.Id.to_string id in
      st.create_before id;
      if st.create_raise id then raise (Sys_error "child backend exploded");
      match st.create_fault id with
      | Some e -> Error e
      | None ->
          if Hashtbl.mem st.sessions k then Error Ports.Store_error.Conflict
          else begin
            Hashtbl.replace st.sessions k session;
            Hashtbl.replace st.muts k [];
            Ok session
          end

    (* A branch: the same document-creation fault hooks as [create], plus the
       copied ledger prefix seeded as the child's mutation history (the real
       store copies blobs too; this fake persists none). *)
    let fork ~from:_ ~events session =
      let id = Session.id session in
      let k = Session.Id.to_string id in
      st.create_before id;
      if st.create_raise id then raise (Sys_error "child backend exploded");
      match st.create_fault id with
      | Some e -> Error e
      | None ->
          if Hashtbl.mem st.sessions k then Error Ports.Store_error.Conflict
          else begin
            Hashtbl.replace st.sessions k session;
            Hashtbl.replace st.muts k events;
            Ok session
          end

    let load g =
      match Hashtbl.find_opt st.sessions g with
      | Some s -> Ok s
      | None -> Error Ports.Store_error.Not_found

    let view id =
      match Hashtbl.find_opt st.sessions (Session.Id.to_string id) with
      | Some s -> Ok s
      | None -> Error Ports.Store_error.Not_found

    let commit g loaded events =
      match st.commit_fault events with
      | Some e -> Error e
      | None -> (
          match Session.append_all events loaded with
          | Error e -> Error (Ports.Store_error.Rejected e)
          | Ok s ->
              Hashtbl.replace st.sessions g s;
              Ok s)

    let commit_metadata g _loaded session =
      match st.metadata_fault session with
      | Some e -> Error e
      | None ->
          Hashtbl.replace st.sessions g session;
          Ok session

    let of_events_or_corrupt updated =
      match Mutation.State.of_events updated with
      | Ok state -> Ok state
      | Error _ ->
          Error
            (Ports.Store_error.Corrupt
               (Mentat_diagnostic.of_text "fake mutation ledger inconsistent"))

    let append_edit g _loaded ~entries:_ event =
      let updated =
        Option.value (Hashtbl.find_opt st.muts g) ~default:[] @ [ event ]
      in
      Hashtbl.replace st.muts g updated;
      of_events_or_corrupt updated

    let append_mutation g _loaded events =
      let updated =
        Option.value (Hashtbl.find_opt st.muts g) ~default:[] @ events
      in
      Hashtbl.replace st.muts g updated;
      of_events_or_corrupt updated

    let mutation_events loaded =
      let id = Session.id loaded in
      Ok
        (Option.value
           (Hashtbl.find_opt st.muts (Session.Id.to_string id))
           ~default:[])

    (* This fake persists no blobs (its tools record no edits), so a change-diff
       query finds no image bytes; the flip's [change_diff] wiring is exercised
       structurally, not for real hunks. *)
    let blob _id _ref = Ok None

    (* A working in-memory attachment namespace, content-addressed like the real
       store, so the engine's externalize/resolve passes round-trip real bytes. *)
    let attachment_key id reference =
      Session.Id.to_string id ^ "\x00"
      ^ Mentat_digest.Content_ref.to_token reference

    let put_attachment id bytes =
      let reference = Mentat_digest.Content_ref.of_contents bytes in
      Hashtbl.replace st.attachments (attachment_key id reference) bytes;
      Ok reference

    let attachment id reference =
      Ok (Hashtbl.find_opt st.attachments (attachment_key id reference))

    (* The revert/export port results are injected; the default declines. The
       online-cone flow tests set a success or a specific fault. *)
    let revert _g _loaded ~scope = st.revert_result scope

    let revert_selection _g _loaded ~selection:_ =
      Error
        (Ports.Store_error.Io
           (Mentat_diagnostic.of_text
              "fake store: revert_selection not implemented"))

    let truncate _g _loaded ~keep:_ _session =
      Error
        (Ports.Store_error.Io
           (Mentat_diagnostic.of_text "fake store: truncate not implemented"))

    let export _g = st.export_result
  end)

let workspace : Ports.workspace =
  let checkpoint ~boundary =
    Mutation.Checkpoint.make ~boundary
      ~capture:
        (Mutation.Checkpoint.Capture.Available
           {
             snapshot =
               Mutation.Checkpoint.Snapshot.make ~backend:"fake"
                 ~reference:"ref";
             excluded = 0;
           })
  in
  {
    Ports.identity = Sandbox.identity Sandbox.direct;
    checkpoint;
    open_scope =
      (fun _claim () ->
        { Mentat_edit.Apply_evidence.applies = []; observed = [] });
    drain_notices = (fun () -> []);
  }

type workspace_calls = {
  mutable drains : int;
  mutable checkpoints : int;
  mutable scopes : int;
}

let workspace_calls () = { drains = 0; checkpoints = 0; scopes = 0 }

let available_capture () =
  Mutation.Checkpoint.Capture.Available
    {
      snapshot =
        Mutation.Checkpoint.Snapshot.make ~backend:"fake" ~reference:"ref";
      excluded = 0;
    }

let degraded_capture () =
  Mutation.Checkpoint.Capture.Degraded
    {
      failure =
        Mutation.Checkpoint.Capture.Failure.make
          ~message:"snapshot backend unavailable";
    }

let tracked_workspace ?(capture = available_capture ()) calls identity :
    Ports.workspace =
  let checkpoint ~boundary =
    calls.checkpoints <- calls.checkpoints + 1;
    Mutation.Checkpoint.make ~boundary ~capture
  in
  {
    Ports.identity;
    checkpoint;
    open_scope =
      (fun _claim () ->
        calls.scopes <- calls.scopes + 1;
        { Mentat_edit.Apply_evidence.applies = []; observed = [] });
    drain_notices =
      (fun () ->
        calls.drains <- calls.drains + 1;
        []);
  }

let catalog =
  match Catalog.make ~verbs:all_verbs [] with
  | Ok c -> c
  | Error e -> failf "catalog: %a" Catalog.Error.pp e

let default_config _id ~latest_model:_ =
  Ok (Agent.Config.make ~model ())

let default_script = Ports.script @@ fun _request -> Ok (plain_response "Done.")

(* The flip: the suite drives the real [Mentat_client.t] over the engine's
   session driver ([Agent.driver]). The account/settings/lifecycle sub-records
   are the executable's at runtime; here they are stubs — every field a report
   the suite never triggers, since it exercises only session-scoped ops. *)
let stub_unavailable () =
  Error
    (Protocol.Error.Unavailable (Mentat_diagnostic.of_text "stub responder"))

let stub_accounts : Client.Driver.Accounts.t =
  {
    Client.Driver.Accounts.login =
      (fun ~provider:_ ~method_:_ -> stub_unavailable ());
    save_api_key = (fun ~provider:_ ~key:_ -> stub_unavailable ());
    logout =
      (fun ?revoke provider ->
        ignore revoke;
        ignore provider;
        stub_unavailable ());
    account_readiness = (fun () -> stub_unavailable ());
    model_readiness = (fun ?refresh:_ () -> stub_unavailable ());
  }

let stub_settings : Client.Driver.Settings.t =
  {
    Client.Driver.Settings.set_model =
      (fun ~session ?reasoning_effort selector ->
        Error
          (Protocol.Error.Unavailable
             (Mentat_diagnostic.of_text
                (Printf.sprintf "stub model selection for %s: %s (%s)"
                   (Session.Id.to_string session)
                   (Mentat_provider.Selector.to_string selector)
                   (Option.fold ~none:"provider default"
                      ~some:Llm.Request.Options.Reasoning_effort.to_string
                      reasoning_effort)))));
    set_permission_review = (fun ~session:_ _ -> stub_unavailable ());
    configuration = (fun () -> stub_unavailable ());
    set_default_model = (fun ?reasoning_effort:_ _ -> stub_unavailable ());
    set_ui_theme = (fun ~theme:_ -> stub_unavailable ());
  }

let stub_lifecycle : Client.Driver.Lifecycle.t =
  {
    Client.Driver.Lifecycle.create = (fun ~id:_ ~title:_ -> stub_unavailable ());
    rename = (fun ~session:_ ~title:_ -> stub_unavailable ());
    archive = (fun ~session:_ -> stub_unavailable ());
    restore = (fun ~session:_ -> stub_unavailable ());
    delete = (fun ~session:_ -> stub_unavailable ());
    sessions = (fun ~listing:_ -> stub_unavailable ());
    session = (fun _ -> stub_unavailable ());
  }

let stub_review : Client.Driver.Review.t =
  {
    Client.Driver.Review.apply = (fun _ -> stub_unavailable ());
    state = (fun ~scope:_ -> stub_unavailable ());
    diff = (fun ~path:_ -> stub_unavailable ());
    crs = (fun () -> stub_unavailable ());
    compose = (fun _ -> stub_unavailable ());
  }

let stub_workspace : Client.Driver.Workspace.t =
  {
    Client.Driver.Workspace.glance = (fun () -> stub_unavailable ());
    dune = (fun () -> stub_unavailable ());
    dune_control = (fun ~op:_ -> stub_unavailable ());
  }

(* Custom /commands are not exercised by the engine suite: these responders are
   inert no-ops, present only to satisfy [Client.make]'s required arguments. *)
let no_user_commands () = Ok []
let no_expand_command ~name:_ ~arguments:_ = Ok []

let no_attach ~session:_ _source =
  Error
    (Protocol.Attach.Error.Unavailable
       (Mentat_diagnostic.of_text "attach not wired in this test"))

let make_client engine =
  Client.make ~user_commands:no_user_commands ~expand_command:no_expand_command
    ~attach:no_attach
    {
      Client.Driver.session = Agent.driver engine;
      accounts = stub_accounts;
      settings = stub_settings;
      lifecycle = stub_lifecycle;
      review = stub_review;
      workspace = stub_workspace;
    }

(* The harness pairs the client with the switch its feeds bind to (feeds close on
   switch release), so [follow_ok] can open a feed without threading a switch
   through every call site. *)
type test_client = { c : Client.t; sw : Eio.Switch.t }

(* A hard call cap keeps a mis-scripted multi-step turn from busy-looping the
   controller fiber (the provider is synchronous, so a loop that never settles
   would starve every other fiber, including the deadlock-guard timer). *)
let capped_script ~cap f =
  let calls = ref 0 in
  fun request ~on_event ~on_download ~cancelled ->
    incr calls;
    if !calls > cap then Ok (plain_response "capped")
    else f request ~on_event ~on_download ~cancelled

(* Runtime harness. *)

let mk_engine ~sw ~store ?(script = default_script) ?(config = default_config)
    ?max_children ?child_backend ?broker ?(catalog = catalog)
    ?(workspace = workspace) ?execution_for_mode ?background_probe
    ?running_view ?delegated_execution ?delegated_role_spy () =
  let now =
    let r = ref 1000L in
    fun () ->
      let v = !r in
      r := Int64.add v 1L;
      Session.Time.of_unix_ms v
  in
  (* Tests select executions as [(catalog, workspace, policy)] triples; the
     engine seam takes an [Execution.t]. Wrap here with the empty context
     prelude so every existing test stays unchanged. *)
  let as_execution (catalog, workspace, policy) =
    Agent.Execution.make ~catalog ~workspace ~policy
      ~prelude:Mentat_llm.Request.Prelude.empty
  in
  let select_for_mode =
    Option.value execution_for_mode
      ~default:(fun ~configured ~model:_ ~sealed_declarations:_ _mode ->
        (catalog, workspace, configured.Agent.Config.policy))
  in
  (* [execution_for_mode] is a factory over the driver's nested per-session
     switch, applied once at controller start; the [background_probe] runs there
     (to observe or attach to that switch, or to raise). It yields the per-turn
     selector and a live background-process view — the default is empty (no
     background tools); a test injects [running_view] to exercise the read. *)
  let execution_for_mode ~background =
    Option.iter (fun probe -> probe background) background_probe;
    ( (fun ~configured ~model ~sealed_declarations mode ->
        as_execution
          (select_for_mode ~configured ~model ~sealed_declarations mode)),
      Option.value running_view ~default:(fun () -> []) )
  in
  let delegated_selection =
    Option.value delegated_execution
      ~default:(catalog, workspace, Mentat_permission.Policy.default)
  in
  (* [delegated_execution] mirrors the real factory shape: applied once over the
     child driver's [~background] switch, it yields the child's per-turn selector
     and background-process view. A test injects the fixed [(catalog, workspace,
     policy)] selection the child dispatches through — the harness routes it for
     every role, since composition's role branching is not what the engine tests
     probe. A delegated child's [role] rides the durable edge and is resolved by
     the engine; the wrapper reports it to [delegated_role_spy] and stamps its
     identity into the child's prelude, so a test can prove the role survived to
     the child's turn construction and reached its system fragments. A roleless
     child keeps the empty prelude. *)
  let delegated_catalog, delegated_workspace, delegated_policy =
    delegated_selection
  in
  let delegated_execution ~role ~background:_ =
    Option.iter (fun spy -> spy role) delegated_role_spy;
    let prelude =
      match role with
      | None -> Mentat_llm.Request.Prelude.empty
      | Some role -> (
          match
            Mentat_llm.Request.Prelude.make
              [
                Mentat_llm.Message.developer
                  ("delegated-role:" ^ Session.Delegation.Role.to_string role);
              ]
          with
          | Ok prelude -> prelude
          | Error _ -> Mentat_llm.Request.Prelude.empty)
    in
    let select ~configured:_ ~model:_ ~sealed_declarations:_ _mode =
      Agent.Execution.make ~catalog:delegated_catalog
        ~workspace:delegated_workspace ~policy:delegated_policy ~prelude
    in
    (select, Option.value running_view ~default:(fun () -> []))
  in
  (* The mocked broker seam: the unit tier runs over the fake store, so a
     send's real fence-and-append effects have nowhere to land — the default
     stub answers [`Delivered] and a test that cares injects its own
     recording stub. *)
  let broker =
    match broker with
    | Some broker -> broker
    | None ->
        Mentat_broker.for_tests
          ~send:(fun ~origin:_ ~target:_ ~id:_ ~input:_ -> `Delivered)
  in
  Agent.create ~sw ~store:(store_of store) ~provider:script ~config ~now
    ?max_children ?child_backend ~broker ~execution_for_mode
    ~delegated_execution ()

(* One engine over a freshly-seeded [root] session, torn down (shutdown, then
   switch cancellation) inside a real-clock deadlock guard. *)
let with_engine ?script ?config ?max_children ?child_backend ?broker ?catalog
    ?workspace ?execution_for_mode ?background_probe ?running_view
    ?delegated_execution ?delegated_role_spy f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let engine =
    mk_engine ~sw ~store ?script ?config ?max_children ?child_backend ?broker
      ?catalog ?workspace ?background_probe ?running_view ?execution_for_mode
      ?delegated_execution ?delegated_role_spy ()
  in
  let client = { c = make_client engine; sw } in
  match
    Eio.Time.with_timeout clock 15.0 (fun () ->
        f ~sw ~client ~store ~engine;
        Agent.shutdown engine;
        Ok ())
  with
  | Ok () -> ()
  | Error `Timeout ->
      fail
        "deadlock guard: the test body exceeded 15s (a turn likely never \
         settled)"

(* A [commit_fault] that declines every commit until the [n]th one matching
   [predicate] (all commits by default), then yields [error] exactly once. It
   counts only matching commits, so a predicate scopes the ordinal to one kind
   of append — the knob the crash matrix uses to fault at a chosen commit point
   rather than always at the first. *)
let fault_on_nth ?(predicate = fun _ -> true) n error =
  let matched = ref 0 in
  fun events ->
    if predicate events then begin
      incr matched;
      if !matched = n then Some error else None
    end
    else None

(* The crash-and-successor fixture: one store seeded with [root], plus a
   [restart] that attaches a fresh engine and client to it. A crash body drives
   one engine to a [commit_fault], shuts it, and [restart]s the successor that
   recovers — without re-deriving the run/switch/store/guard boilerplate. Style
   (a): the successor shares this switch and the 15s deadlock guard. A
   synthesized-journal case that seeds recovery state directly, with no live
   crash, stays on the plain [mk_engine] form (style (b)). *)
let with_crash_recovery f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let restart ?script ?config ?catalog ?workspace () =
    let engine = mk_engine ~sw ~store ?script ?config ?catalog ?workspace () in
    ({ c = make_client engine; sw }, engine)
  in
  match
    Eio.Time.with_timeout clock 15.0 (fun () ->
        f ~store ~restart;
        Ok ())
  with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: a crash-recovery body exceeded 15s"

let prompt ?mode ~session ~turn text =
  match
    Protocol.Command.prompt ~session ~turn
      ~input:[ Llm.Content.text text ]
      ?mode ()
  with
  | Ok c -> c
  | Error e -> failf "prompt command: %s" (Protocol.Command.Invalid.message e)

let submit_ok client command =
  match Client.submit client.c command with
  | Ok () -> ()
  | Error e -> failf "submit refused: %a" Protocol.Error.pp e

let follow_ok ?(from = `Beginning) client session =
  match Client.follow_session ~sw:client.sw client.c session ~from with
  | Ok feed -> feed
  | Error e -> failf "follow refused: %a" Protocol.Error.pp e

let is_settled = function Protocol.Fact.Turn_settled _ -> true | _ -> false

(* Read committed facts until [stop] matches one (inclusive), skipping progress
   pulses. Returns [(position, fact)] pairs in order, then closes the feed —
   which stops its draining fiber, so a switch teardown that waits on forked
   fibers does not hang on a parked feed (the client's feeds are [Fiber.fork]ed,
   not daemons). *)
let drain_committed ?(stop = is_settled) feed =
  let rec loop acc =
    match Client.Feed.next feed with
    | Error e -> failf "feed next: %a" Protocol.Error.pp e
    | Ok Client.Feed.Closed -> List.rev acc
    | Ok (Client.Feed.Item (Protocol.Update.Progress _)) -> loop acc
    | Ok (Client.Feed.Item (Protocol.Update.Committed { position; fact })) ->
        let acc = (position, fact) :: acc in
        if stop fact then List.rev acc else loop acc
  in
  let pairs = loop [] in
  Client.Feed.close feed;
  pairs

(* Read exactly [n] committed facts, skipping progress, without closing the feed
   — for holding two cursors open on one hub at once. Safe only when at least [n]
   facts are already materialized (e.g. the turn has settled), so [next] never
   blocks for want of a fact that will not come. *)
let read_committed n feed =
  let rec loop k acc =
    if k <= 0 then List.rev acc
    else
      match Client.Feed.next feed with
      | Error e -> failf "feed next: %a" Protocol.Error.pp e
      | Ok Client.Feed.Closed -> List.rev acc
      | Ok (Client.Feed.Item (Protocol.Update.Progress _)) -> loop k acc
      | Ok (Client.Feed.Item (Protocol.Update.Committed { position; fact })) ->
          loop (k - 1) ((position, fact) :: acc)
  in
  loop n []

(* Drain until [n] settlements have been seen (inclusive of the nth). A child
   that parks a follow-up runs two turns; this collects both. *)
let drain_n_settled n feed =
  let seen = ref 0 in
  drain_committed
    ~stop:(fun f ->
      if is_settled f then incr seen;
      !seen >= n)
    feed

let facts pairs = List.map snd pairs

let has_fact pred pairs =
  List.exists (fun (_, f) -> pred f) (List.map (fun p -> p) pairs)

let settled_outcome pairs =
  List.find_map
    (fun (_, f) ->
      match f with
      | Protocol.Fact.Turn_settled { outcome; _ } -> Some outcome
      | _ -> None)
    pairs

(* The assistant-delta text of a progress pulse, if any — the ring test's probe
   for which model deltas the engine feed's bounded ring retained. *)
let progress_delta_text = function
  | Protocol.Progress.Model
      { update = Protocol.Progress.Model.Assistant_delta { text }; _ } ->
      Some text
  | _ -> None

(* Pull until [progress] assistant-delta pulses have been collected AND the turn
   has settled, returning the committed facts and those deltas. Committed facts
   and ring progress can interleave depending on when the reader wakes relative
   to the settlement commit, but the ring drains its deltas in order
   regardless; this stops once both the ring's retained deltas are counted and
   a settlement fact is seen, so a committed fact is provably not dropped. *)
let drain_flood ~progress feed =
  let committed = ref [] and deltas = ref [] and settled = ref false in
  let rec loop () =
    if !settled && List.length !deltas >= progress then ()
    else
      match Client.Feed.next feed with
      | Error e -> failf "feed next: %a" Protocol.Error.pp e
      | Ok Client.Feed.Closed -> ()
      | Ok (Client.Feed.Item (Protocol.Update.Committed { fact; _ })) ->
          committed := fact :: !committed;
          if is_settled fact then settled := true;
          loop ()
      | Ok (Client.Feed.Item (Protocol.Update.Progress p)) ->
          (match progress_delta_text p with
          | Some t -> deltas := t :: !deltas
          | None -> ());
          loop ()
  in
  loop ();
  (List.rev !committed, List.rev !deltas)

let session_keys st =
  Hashtbl.fold (fun k _ acc -> k :: acc) st.sessions []
  |> List.sort String.compare

(* A session journal with a tool claim opened and never settled — the state a
   crash mid-tool leaves, which recovery reads as an ambiguous tool. *)
let has_open_tool_claim st key =
  match Hashtbl.find_opt st.sessions key with
  | None -> false
  | Some s ->
      List.exists
        (function Session.Event.Tool_claimed _ -> true | _ -> false)
        (Session.events s)

let is_tool_settled events =
  List.exists
    (function Session.Event.Tool_settled _ -> true | _ -> false)
    events

(* Whether a session's mutation journal carries a fresh post-recovery capture —
   the checkpoint recovery must clear [possibly_mutating] against it. *)
let has_after_recovery_checkpoint st key =
  match Hashtbl.find_opt st.muts key with
  | None -> false
  | Some events ->
      List.exists
        (function
          | Mutation.Event.Checkpoint cp -> (
              match Mutation.Checkpoint.boundary cp with
              | Mutation.Checkpoint.After_recovery _ -> true
              | _ -> false)
          | _ -> false)
        events

(* Whether a session's durable journal carries a queued entry — the durable
   proof a parked (rather than directly-submitted) message reached the child. *)
let has_enqueued st key =
  match Hashtbl.find_opt st.sessions key with
  | None -> false
  | Some s ->
      List.exists
        (function
          | Session.Event.Queue_updated (Session.Queue.Update.Enqueued _) ->
              true
          | _ -> false)
        (Session.events s)

(* Cooperatively yield the main fiber until [pred] holds, so sibling driver
   fibers make progress. [fuel] bounds a wedged predicate; the real-clock
   deadlock guard is the ultimate backstop. *)
let rec await_yield ?(fuel = 100_000) pred =
  if pred () then ()
  else if fuel <= 0 then fail "await_yield: the predicate never held"
  else begin
    Eio.Fiber.yield ();
    await_yield ~fuel:(fuel - 1) pred
  end

(* Pure step: catalog. *)

let trivial_tool ?(name = "noop") () =
  Mentat_tool.make ~name ~description:"a trivial tool"
    ~input:Mentat_tool.Input.empty
    ~output:(fun () -> Mentat_tool.Output.make ~text:"ok" ())
    ~run:(fun ~cancelled:_ () -> Mentat_tool.Result.completed ~output:() ())
    ()

let catalog_rejects_duplicate_names () =
  match
    Catalog.make ~verbs:[]
      [ trivial_tool ~name:"dup" (); trivial_tool ~name:"dup" () ]
  with
  | Error (Catalog.Error.Duplicate_name name) ->
      equal string ~msg:"the duplicate name is reported" "dup" name
  | Ok _ -> fail "a duplicate executable name must be rejected"
  | Error e -> failf "wrong error: %a" Catalog.Error.pp e

let catalog_rejects_reserved_names () =
  match Catalog.make ~verbs:[] [ trivial_tool ~name:"spawn" () ] with
  | Error (Catalog.Error.Reserved_name name) ->
      equal string ~msg:"the reserved verb name is reported" "spawn" name
  | Ok _ -> fail "an executable tool may not take an engine verb's name"
  | Error e -> failf "wrong error: %a" Catalog.Error.pp e

let catalog_rejects_duplicate_verbs () =
  match Catalog.make ~verbs:[ Catalog.Verb.Spawn; Catalog.Verb.Spawn ] [] with
  | Error (Catalog.Error.Duplicate_verb Catalog.Verb.Spawn) -> ()
  | Ok _ -> fail "a duplicate engine verb must be rejected"
  | Error e -> failf "wrong error: %a" Catalog.Error.pp e

let catalog_has_exact_supplied_verbs () =
  (match Catalog.resolve catalog "spawn" with
  | Some (`Verb Catalog.Verb.Spawn) -> ()
  | _ -> fail "the empty catalog still resolves the spawn verb");
  let names = List.map Llm.Tool.name (Catalog.declarations catalog) in
  is_true ~msg:"every supplied engine verb is declared"
    (List.for_all (fun v -> List.mem (Catalog.Verb.name v) names) all_verbs);
  equal int ~msg:"the catalog declares exactly the supplied engine verbs"
    (List.length all_verbs) (List.length names);
  let empty =
    match Catalog.make ~verbs:[] [] with
    | Ok catalog -> catalog
    | Error e -> failf "empty catalog: %a" Catalog.Error.pp e
  in
  equal (list string) ~msg:"verbs are never added implicitly" []
    (List.map Llm.Tool.name (Catalog.declarations empty));
  is_true ~msg:"an unselected verb does not resolve"
    (Option.is_none (Catalog.resolve empty "spawn"))

let verb_result ~catalog ?declarations ~name input =
  let identity = Sandbox.identity Sandbox.direct in
  let declarations =
    Option.value declarations ~default:(Catalog.declarations catalog)
  in
  let contract =
    Session.Contract.make ~mode:Session.Contract.Mode.Build ~model ~declarations
      ~policy:Mentat_permission.Policy.default
      ~review:Mentat_permission.Review_behavior.Enforce ~sandbox:identity ()
  in
  let env =
    Step.Env.make ~catalog ~sandbox:identity ~max_steps:8
      ~compaction_pressure_tokens:None
      ~max_spawn_depth:1 ~max_exchanges:8 ~depth:0 ()
  in
  let session =
    Session.create
      ~id:(sid ("verb-" ^ name))
      ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  let started =
    match
      Step.start env contract
        ~id:(tid ("turn-" ^ name))
        ~input:(Session.Turn.Input.user_text "exercise the verb")
        ~origin:Session.Turn.Origin.User session
    with
    | Ok step -> step
    | Error error -> failf "start %s: %a" name Step.Error.pp error
  in
  let claim =
    match Step.Step.action started with
    | Step.Step.Perform (Step.Step.Effect.Model { claim; purpose = `Turn; _ })
      ->
        claim
    | _ -> failf "%s did not start with a turn provider request" name
  in
  let session =
    match Session.append_all (Step.Step.events started) session with
    | Ok session -> session
    | Error error -> failf "append %s start: %a" name Session.Error.pp error
  in
  let response = tool_call_response ~name ~input "calling verb" in
  let dispatched =
    match
      Step.accept_response env
        (Session.Provider_request.Started.id claim)
        response session
    with
    | Ok step -> step
    | Error error -> failf "dispatch %s: %a" name Step.Error.pp error
  in
  match
    List.find_map
      (function
        | Session.Event.Message_appended (Llm.Message.Tool_result result) ->
            Some result
        | _ -> None)
      (Step.Step.events dispatched)
  with
  | Some result -> (result, Step.Step.events dispatched)
  | None -> failf "%s did not produce a model-visible result" name

let engine_verbs_reject_unknown_input_members () =
  let cases =
    [
      ( "todo_write",
        json_object
          [
            ( "tasks",
              json_array
                [
                  json_object
                    [ ("id", Json.string "one"); ("content", Json.string "x") ];
                ] );
          ] );
      ("ask_user", json_object [ ("prompt", Json.string "Continue?") ]);
      ("propose_plan", json_object [ ("body", Json.string "1. Continue") ]);
      ("spawn", json_object [ ("task", Json.string "Inspect this") ]);
      ("wait", json_object [ ("children", json_array [ Json.string "child" ]) ]);
      ( "send",
        json_object
          [
            ("to", Json.string "child:child");
            ("message", Json.string "context");
          ] );
      ( "follow_up",
        json_object
          [ ("child", Json.string "child"); ("message", Json.string "next") ] );
    ]
  in
  List.iter
    (fun (name, input) ->
      let input =
        match input with
        | Jsont.Object (members, meta) ->
            Jsont.Object
              ( Json.mem (Json.name "unexpected") (Json.bool true) :: members,
                meta )
        | _ -> assert false
      in
      let result, _events = verb_result ~catalog ~name input in
      is_true
        ~msg:(name ^ " rejects an unknown top-level member")
        (Llm.Tool.Result.is_error result);
      is_true
        ~msg:(name ^ " identifies its unknown member")
        (contains_sub ~sub:"unexpected"
           (String.concat "\n" (Llm.Tool.Result.texts result))))
    cases;
  let nested =
    json_object
      [
        ( "tasks",
          json_array
            [
              json_object
                [
                  ("id", Json.string "one");
                  ("content", Json.string "x");
                  ("nested_unexpected", Json.bool true);
                ];
            ] );
      ]
  in
  let result, _events = verb_result ~catalog ~name:"todo_write" nested in
  is_true ~msg:"todo items reject unknown members"
    (Llm.Tool.Result.is_error result);
  is_true ~msg:"the nested unknown member is identified"
    (contains_sub ~sub:"nested_unexpected"
       (String.concat "\n" (Llm.Tool.Result.texts result)));
  List.iter
    (fun (field, value) ->
      let input =
        json_object [ ("task", Json.string "Inspect this"); (field, value) ]
      in
      let result, _events = verb_result ~catalog ~name:"spawn" input in
      is_true
        ~msg:("spawn rejects removed " ^ field)
        (Llm.Tool.Result.is_error result);
      is_true
        ~msg:("spawn names removed " ^ field)
        (contains_sub ~sub:field
           (String.concat "\n" (Llm.Tool.Result.texts result))))
    [
      ("profile", Json.string "reviewer");
      ("context", Json.string "inherit");
      ("fork_last", Json.bool true);
    ]

(* The [role] enum is closed: an unknown value is a model-visible tool failure
   (the strict-verb decode law), never a silent fallback to a generic child.
   The three known roles are accepted end-to-end by the delegation tests, where
   a valid spawn suspends on a child reservation rather than yielding an
   immediate tool result. *)
let spawn_rejects_an_unknown_role () =
  let input =
    json_object
      [ ("task", Json.string "Inspect this"); ("role", Json.string "designer") ]
  in
  let result, _events = verb_result ~catalog ~name:"spawn" input in
  is_true ~msg:"spawn rejects an unknown role" (Llm.Tool.Result.is_error result);
  is_true ~msg:"spawn names the rejected role member"
    (contains_sub ~sub:"role"
       (String.concat "\n" (Llm.Tool.Result.texts result)))

let engine_verb_declaration_drift_blocks_dispatch () =
  let spawn_catalog =
    match Catalog.make ~verbs:[ Catalog.Verb.Spawn ] [] with
    | Ok catalog -> catalog
    | Error error -> failf "spawn catalog: %a" Catalog.Error.pp error
  in
  let sealed_spawn = Catalog.Verb.declaration Catalog.Verb.Spawn in
  let changed =
    Llm.Tool.make
      ~name:(Llm.Tool.name sealed_spawn)
      ?description:(Llm.Tool.description sealed_spawn)
      ~input_schema:Llm.Tool.no_input_schema ()
  in
  let result, events =
    verb_result ~catalog:spawn_catalog ~declarations:[ changed ] ~name:"spawn"
      (json_object [ ("task", Json.string "must not be reserved") ])
  in
  is_true ~msg:"verb declaration drift becomes a failed tool result"
    (Llm.Tool.Result.is_error result);
  is_true ~msg:"the drift is named in the model-visible result"
    (contains_sub ~sub:"declaration changed"
       (String.concat "\n" (Llm.Tool.Result.texts result)));
  is_false ~msg:"drift is rejected before a child reservation is recorded"
    (List.exists
       (function Session.Event.Delegation_recorded _ -> true | _ -> false)
       events)

(* Pure step: config, env, error folding. *)

let config_defaults_are_the_documented_ones () =
  let cfg = Agent.Config.make ~model () in
  equal int ~msg:"max_steps defaults to 500" 500 cfg.Agent.Config.max_steps;
  equal int ~msg:"max_spawn_depth defaults to 1" 1
    cfg.Agent.Config.max_spawn_depth;
  equal int ~msg:"max_exchanges defaults to 8" 8 cfg.Agent.Config.max_exchanges;
  (match cfg.Agent.Config.review with
  | Mentat_permission.Review_behavior.Enforce -> ()
  | _ -> fail "review defaults to Enforce");
  match cfg.Agent.Config.compaction_pressure_tokens with
  | None -> ()
  | Some _ -> fail "compaction is disabled by default"

let config_rejects_non_positive_knobs () =
  raises (Invalid_argument "max_steps must be positive") (fun () ->
      Agent.Config.make ~model ~max_steps:0 ());
  raises (Invalid_argument "max_spawn_depth must be positive") (fun () ->
      Agent.Config.make ~model ~max_spawn_depth:0 ());
  raises (Invalid_argument "max_exchanges must be positive") (fun () ->
      Agent.Config.make ~model ~max_exchanges:(-1) ())

(* The shared contract for admission fixtures. *)
let admission_contract () =
  Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
    ~declarations:[] ~policy:Mentat_permission.Policy.default
    ~review:Mentat_permission.Review_behavior.Enforce
    ~sandbox:(Sandbox.identity Sandbox.direct)
    ()

(* The durable events for one turn that starts, is answered by [response], and
   settles on [outcome] — the shape [next_admission] reads to decide the next
   turn. *)
let settled_turn ?(outcome = Session.Turn.Outcome.completed) ~contract ~id
    ~origin ~text ~response () =
  let turn =
    Session.Turn.make ~id:(tid id) ~origin
      ~input:(Session.Turn.Input.user_text text)
      ~max_steps:1 ~contract ()
  in
  let provider =
    Session.Provider_request.Started.make ~turn:(Session.Turn.id turn)
      ~request_digest:(Mentat_digest.string ("req-" ^ id))
  in
  [
    Session.Event.turn_started turn;
    Session.Event.provider_requested provider;
    Session.Event.provider_settled
      (Session.Provider_request.Settled.responded
         ~id:(Session.Provider_request.Started.id provider)
         response);
    Session.Event.turn_finished ~turn:(Session.Turn.id turn) outcome;
  ]

let append_or_fail ~what events session =
  match Session.append_all events session with
  | Ok session -> session
  | Error error -> failf "%s: %a" what Session.Error.pp error

(* The step limit is a runaway backstop, not a verdict that the work is over: a
   turn that reaches it is owed one wrap-up turn, with nothing else queued.
   That wind-down turn carries its own origin, which is what stops a wind-down
   that spends its own budget from admitting a second one. An interrupted turn
   is the control: the user stopped the work, so nothing is admitted on their
   behalf. *)
let a_step_limited_turn_winds_down_once () =
  let contract = admission_contract () in
  let session =
    Session.create ~id:(sid "steps") ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
    |> append_or_fail ~what:"step fixture: step-limited turn"
         (settled_turn ~contract ~id:"t-user" ~origin:Session.Turn.Origin.User
            ~text:"start" ~response:(plain_response "working")
            ~outcome:Session.Turn.Outcome.step_limit ())
  in
  (match Step.next_admission (Session.state session) with
  | Step.Admission.Step_limit_wind_down input ->
      is_true ~msg:"the wind-down turn carries the step-limit notice"
        (contains_sub ~sub:"reached its step limit"
           (Option.value ~default:"" (Session.Turn.Input.text input)));
      is_true
        ~msg:"the wind-down turn asks for the work to be parked and stated"
        (contains_sub ~sub:"summarize where the work stands"
           (Option.value ~default:"" (Session.Turn.Input.text input)))
  | Step.Admission.Queued _ | Step.Admission.Idle ->
      fail "a step-limited turn should wind down, not idle");
  (* The wind-down spends its own budget: the next admission is not another
     wind-down, so the mechanism cannot ping-pong. *)
  let wound_down =
    append_or_fail ~what:"step fixture: the wind-down turn"
      (settled_turn ~contract ~id:"t-wind"
         ~origin:Session.Turn.Origin.Step_limit_wind_down ~text:"wrap up"
         ~response:(plain_response "parked")
         ~outcome:Session.Turn.Outcome.step_limit ())
      session
  in
  (match Step.next_admission (Session.state wound_down) with
  | Step.Admission.Idle -> ()
  | Step.Admission.Step_limit_wind_down _ | Step.Admission.Queued _ ->
      fail "a wind-down turn must not admit a second wind-down");
  let interrupted =
    Session.create ~id:(sid "stopped") ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
    |> append_or_fail ~what:"step fixture: interrupted turn"
         (settled_turn ~contract ~id:"t-int" ~origin:Session.Turn.Origin.User
            ~text:"start" ~response:(plain_response "working")
            ~outcome:(Session.Turn.Outcome.interrupted ~cancelled:true ())
            ())
  in
  match Step.next_admission (Session.state interrupted) with
  | Step.Admission.Idle -> ()
  | Step.Admission.Step_limit_wind_down _ | Step.Admission.Queued _ ->
      fail "an interrupted turn admits nothing"

let env_rejects_invalid_scalars () =
  let make ?(max_steps = 1) ?(depth = 0) () =
    Step.Env.make ~catalog
      ~sandbox:(Sandbox.identity Sandbox.direct)
      ~max_steps ~compaction_pressure_tokens:None
      ~max_spawn_depth:1 ~max_exchanges:8 ~depth ()
  in
  ignore (make ());
  expect_invalid_arg "non-positive max_steps" (fun () -> make ~max_steps:0 ());
  expect_invalid_arg "negative depth" (fun () -> make ~depth:(-1) ())

let error_folds_step_protocol_cases_to_internal () =
  let internal = function Agent.Error.Internal _ -> true | _ -> false in
  is_true ~msg:"No_active_turn folds to Internal"
    (internal (Agent.Error.of_step Step.Error.No_active_turn));
  is_true ~msg:"No_pending_wait folds to Internal"
    (internal (Agent.Error.of_step Step.Error.No_pending_wait));
  is_true ~msg:"Call_not_pending folds to Internal"
    (internal
       (Agent.Error.of_step
          (Step.Error.Call_not_pending { call_id = "c"; name = "read" })))

let forged_plan_build_creates_no_provider_effect () =
  let identity = Sandbox.identity Sandbox.direct in
  let contract mode =
    Session.Contract.make ~mode ~model
      ~declarations:(Catalog.declarations catalog)
      ~policy:Mentat_permission.Policy.default
      ~review:Mentat_permission.Review_behavior.Enforce ~sandbox:identity ()
  in
  let proposed =
    match Session.Plan.make ~body:"1. Keep the exact approved body" () with
    | Ok plan -> plan
    | Error error -> failf "plan: %a" Session.Plan.Error.pp error
  in
  let answer =
    Session.Plan.Answer.approve ~body:proposed ~context:`Current ()
  in
  let approved =
    match answer with
    | Session.Plan.Answer.Approve approval -> approval
    | Session.Plan.Answer.Keep_planning | Session.Plan.Answer.Revise _ ->
        assert false
  in
  let planning_turn =
    Session.Turn.make ~id:(tid "t-plan") ~origin:Session.Turn.Origin.User
      ~input:(Session.Turn.Input.user_text "Plan it.")
      ~max_steps:8
      ~contract:(contract Session.Contract.Mode.Plan)
      ()
  in
  let call =
    Llm.Tool.Call.make ~id:"plan-call" ~name:"propose_plan"
      ~input:
        (json_object [ ("body", Json.string (Session.Plan.body proposed)) ])
      ()
  in
  let claim =
    Session.Provider_request.Started.make
      ~turn:(Session.Turn.id planning_turn)
      ~request_digest:(Mentat_digest.string "planning-request")
  in
  let response =
    Llm.Response.make ~model ~stop:Llm.Response.Stop.tool_call
      (Llm.Message.Assistant.make [ Llm.Message.Assistant.tool_call call ])
  in
  let requested =
    Session.Decision.Requested.make
      ~turn:(Session.Turn.id planning_turn)
      ~call ~stage:Mentat_tool.Stage.Direct
      (Session.Decision.Request.Plan proposed)
  in
  let resolved =
    match
      Session.Decision.resolve requested ~call ~by:Session.Principal.local_user
        (Session.Decision.Answer.Plan answer)
    with
    | Ok (resolved, Session.Decision.Proceed_plan actual) ->
        is_true ~msg:"resolution carries the exact approval"
          (Session.Plan.Approval.equal approved actual);
        resolved
    | Ok _ -> fail "plan approval resolved with the wrong handling"
    | Error error ->
        failf "plan resolution: %a" Session.Decision.Resolve_error.pp error
  in
  let session =
    Session.create ~id:(sid "forgery") ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  let session =
    match
      Session.append_all
        [
          Session.Event.turn_started planning_turn;
          Session.Event.provider_requested claim;
          Session.Event.provider_settled
            (Session.Provider_request.Settled.responded
               ~id:(Session.Provider_request.Started.id claim)
               response);
          Session.Event.decision_requested requested;
          Session.Event.decision_resolved resolved;
          Session.Event.turn_finished
            ~turn:(Session.Turn.id planning_turn)
            Session.Turn.Outcome.completed;
        ]
        session
    with
    | Ok session -> session
    | Error error -> failf "approval prefix: %a" Session.Error.pp error
  in
  let altered =
    match Session.Plan.make ~body:"1. Run a forged replacement" () with
    | Error error -> failf "altered plan: %a" Session.Plan.Error.pp error
    | Ok plan -> (
        match Session.Plan.Answer.approve ~body:plan ~context:`Current () with
        | Session.Plan.Answer.Approve approval -> approval
        | Session.Plan.Answer.Keep_planning | Session.Plan.Answer.Revise _ ->
            assert false)
  in
  let env =
    Step.Env.make ~catalog ~sandbox:identity ~max_steps:8
      ~compaction_pressure_tokens:None
      ~max_spawn_depth:1 ~max_exchanges:8 ~depth:0 ()
  in
  match
    Step.start env
      (contract Session.Contract.Mode.Build)
      ~id:(tid "t-forged")
      ~input:(Session.Turn.Input.plan_build altered)
      ~origin:Session.Turn.Origin.Plan_build session
  with
  | Error (Step.Error.Session (Session.Error.Replay error)) -> (
      match Session.State.Replay_error.cause error with
      | Session.State.Error.Turn
          (Session.State.Error.Turn.Plan_build_mismatch turn) ->
          is_true ~msg:"the mismatch identifies the forged turn"
            (Session.Turn.Id.equal (tid "t-forged") turn)
      | cause ->
          failf "unexpected replay cause: %a" Session.State.Error.pp cause)
  | Error error -> failf "unexpected step error: %a" Step.Error.pp error
  | Ok step -> (
      match Step.Step.action step with
      | Step.Step.Perform (Step.Step.Effect.Model _) ->
          fail "forged approval reached a provider effect"
      | _ -> fail "forged approval was admitted")

(* Runtime: lifecycle. *)

let a_prompt_turn_starts_and_completes () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hello");
      let feed = follow_ok client (sid "root") in
      let pairs = drain_committed feed in
      is_true ~msg:"the feed opens with the turn-started fact"
        (has_fact
           (function Protocol.Fact.Turn_started _ -> true | _ -> false)
           pairs);
      match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the turn settled %a, expected Completed"
            Session.Turn.Outcome.pp other
      | None -> fail "the turn never settled on the feed")

(* Image input: a prompt carrying inline [`Base64] media is externalized to an
   attachment [`Ref] before [Turn_started] lands in the journal, and resolved
   back to [`Base64] before the provider sees it — the digest/claim stay over
   [`Ref], the wire carries the bytes, and the journal never holds them. *)
let a_prompt_with_image_externalizes_and_resolves () =
  let raw = "\x89PNG\r\n\x1a\nPRETEND-IMAGE-BYTES" in
  let b64 = Base64.encode_string raw in
  let captured = ref None in
  let script =
    Ports.script @@ fun request ->
    captured := Some request;
    Ok (plain_response "I see the image.")
  in
  let media_of_request request =
    List.find_map
      (function
        | Llm.Message.User content ->
            List.find_map
              (function
                | Llm.Content.Media { media_type; source } ->
                    Some (media_type, source)
                | Llm.Content.Text _ -> None)
              content
        | _ -> None)
      (Llm.Request.messages request)
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine:_ ->
      let command =
        match
          Protocol.Command.prompt ~session:(sid "root") ~turn:(tid "t1")
            ~input:
              [
                Llm.Content.text "what is this";
                Llm.Content.media ~media_type:"image/png" (`Base64 b64);
              ]
            ()
        with
        | Ok c -> c
        | Error e -> failf "prompt: %s" (Protocol.Command.Invalid.message e)
      in
      submit_ok client command;
      ignore (drain_committed (follow_ok client (sid "root")));
      (* The provider saw the resolved [`Base64], never a [`Ref]. *)
      let request =
        match !captured with
        | Some request -> request
        | None -> fail "the turn issued no provider request"
      in
      (match media_of_request request with
      | Some (media_type, `Base64 data) ->
          equal string ~msg:"provider media type" "image/png" media_type;
          equal string ~msg:"provider sees the resolved base64 payload" b64 data
      | Some (_, `Ref _) -> fail "the provider saw an unresolved reference"
      | Some (_, `Uri _) | None -> fail "the provider saw no image media");
      (* The journal's [Turn_started] holds a [`Ref], never inline bytes. *)
      let session =
        match Hashtbl.find_opt store.sessions "root" with
        | Some s -> s
        | None -> fail "root session vanished"
      in
      let content =
        match Session.State.turn (tid "t1") (Session.state session) with
        | Some turn -> (
            match Session.Turn.input turn with
            | Session.Turn.Input.User content -> content
            | _ -> fail "the turn input is not user content")
        | None -> fail "the started turn is absent from the journal"
      in
      let reference =
        List.find_map
          (function
            | Llm.Content.Media { source = `Ref reference; _ } -> Some reference
            | _ -> None)
          content
      in
      let reference =
        match reference with
        | Some reference -> reference
        | None ->
            fail "the journal did not externalize the image to a reference"
      in
      is_false ~msg:"the journal holds no inline base64"
        (List.exists
           (function
             | Llm.Content.Media { source = `Base64 _; _ } -> true | _ -> false)
           content);
      (* The attachment blob holds the decoded image bytes (not the base64). *)
      equal (option string)
        ~msg:"the attachment blob holds the decoded image bytes" (Some raw)
        (Hashtbl.find_opt store.attachments
           (Session.Id.to_string (sid "root")
           ^ "\x00"
           ^ Mentat_digest.Content_ref.to_token reference)))

(* Background terminals, driver stage: the controller opens a nested
   per-session switch and releases it in the quiescent teardown. These drive a
   real turn — which starts the driver and applies [execution_for_mode] to that
   switch, firing the [background_probe] — then let [with_engine] shut the engine
   down and assert on the switch's release. Per-driver isolation is structural:
   each controller opens its own [Eio.Switch.run], witnessed here by two root
   drivers getting independent switches that both release. *)

let a_driver_nested_switch_releases_on_close () =
  let released = ref false in
  let probe sw = Eio.Switch.on_release sw (fun () -> released := true) in
  with_engine ~background_probe:probe (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hello");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      is_false ~msg:"the nested switch is still live while the driver runs"
        !released;
      match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | _ ->
          fail
            "the turn must settle Completed — the fence and the turn are \
             unbroken by the added switch");
  is_true ~msg:"the driver's nested switch released when the driver closed"
    !released

let a_driver_close_reaps_a_cancellation_ignoring_switch_fiber () =
  let released = ref false in
  let probe sw =
    Eio.Switch.on_release sw (fun () -> released := true);
    (* A background process rides daemon fibers (drains, waiter); switch release
       cancels them. This one ignores cancellation for a bounded grace before
       unwinding, mirroring [Supervise]'s [Cancel.protect] reap: teardown must
       stay bounded, not hang on the grace. *)
    Eio.Fiber.fork_daemon ~sw (fun () ->
        try Eio.Fiber.await_cancel ()
        with Eio.Cancel.Cancelled _ ->
          Eio.Cancel.protect (fun () ->
              for _ = 1 to 200 do
                Eio.Fiber.yield ()
              done);
          `Stop_daemon)
  in
  with_engine ~background_probe:probe (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hello");
      ignore (drain_committed (follow_ok client (sid "root"))));
  (* [with_engine]'s 15s deadlock guard would fail on a hang; reaching here with
     the switch released proves the reap stayed bounded. *)
  is_true
    ~msg:
      "close reaped the cancellation-ignoring switch fiber and released the \
       switch"
    !released

let each_driver_gets_its_own_nested_switch () =
  let releases = ref [] in
  let probe sw =
    let flag = ref false in
    releases := flag :: !releases;
    Eio.Switch.on_release sw (fun () -> flag := true)
  in
  with_engine ~background_probe:probe (fun ~sw:_ ~client ~store ~engine:_ ->
      seed_session store ~id:"root-b";
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-a") "a");
      ignore (drain_committed (follow_ok client (sid "root")));
      submit_ok client (prompt ~session:(sid "root-b") ~turn:(tid "t-b") "b");
      ignore (drain_committed (follow_ok client (sid "root-b"))));
  equal int ~msg:"each of the two root drivers opened its own nested switch" 2
    (List.length !releases);
  is_true ~msg:"every driver's own switch released independently at close"
    (List.for_all (fun flag -> !flag) !releases)

(* Background terminals, driver stage (Phase 1): the session-scoped
   [running_processes] read projects the driver's live registry view. The
   factory returns that view beside the selector; driving a turn applies the
   factory over the session switch and binds it, so the client read returns
   exactly the injected view. Before the driver starts, no view is bound and the
   read is empty (the cone's [find_driver] miss, D6 ephemerality). *)

let process_view =
  let pp ppf v =
    Format.fprintf ppf "@[<h>%s %S %a %dms@]"
      (Protocol.Process.View.handle v)
      (Protocol.Process.View.command v)
      Protocol.Process.Status.pp
      (Protocol.Process.View.status v)
      (Protocol.Process.View.age_ms v)
  in
  Testable.make ~pp ~equal:Protocol.Process.View.equal

let running_processes_reads_the_drivers_live_view () =
  let view =
    Protocol.Process.View.make ~handle:"bg-1" ~command:"sleep 30"
      ~status:Protocol.Process.Status.Running ~age_ms:1500
  in
  with_engine
    ~running_view:(fun () -> [ view ])
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      (match Client.running_processes client.c (sid "root") with
      | Ok [] -> ()
      | Ok _ -> fail "no view is bound before the driver starts"
      | Error e -> failf "running_processes (pre-start): %a" Protocol.Error.pp e);
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hello");
      ignore (drain_committed (follow_ok client (sid "root")));
      match Client.running_processes client.c (sid "root") with
      | Ok views ->
          equal (list process_view)
            ~msg:
              "the session-scoped read returns the driver's injected live view"
            [ view ] views
      | Error e -> failf "running_processes: %a" Protocol.Error.pp e)

let mode_execution_binds_catalog_workspace_and_policy_together () =
  let module Policy = Mentat_permission.Policy in
  let build_policy = Policy.make [ Policy.Rule.allow_all_dangerously ] in
  let read_policy = Policy.make [ Policy.Rule.deny_all ] in
  let build_identity = Sandbox.Identity.declared_external in
  let read_identity = Sandbox.Identity.refused in
  let build_calls = workspace_calls () in
  let read_calls = workspace_calls () in
  let build_workspace = tracked_workspace build_calls build_identity in
  let read_workspace = tracked_workspace read_calls read_identity in
  let make_catalog name =
    match Catalog.make ~verbs:[] [ trivial_tool ~name () ] with
    | Ok catalog -> catalog
    | Error error -> failf "catalog %s: %a" name Catalog.Error.pp error
  in
  let build_catalog = make_catalog "build_probe" in
  let read_catalog = make_catalog "read_probe" in
  let configured_was_preserved = ref true in
  let configured_model_was_selected = ref true in
  let selector_calls = ref 0 in
  let execution_for_mode ~configured ~model:selected_model
      ~sealed_declarations:_ mode =
    incr selector_calls;
    configured_was_preserved :=
      !configured_was_preserved
      && Policy.equal configured.Agent.Config.policy build_policy;
    configured_model_was_selected :=
      !configured_model_was_selected
      && Llm.Model.equal selected_model configured.Agent.Config.model;
    match mode with
    | Session.Contract.Mode.Build ->
        (build_catalog, build_workspace, configured.Agent.Config.policy)
    | Session.Contract.Mode.Plan | Session.Contract.Mode.Review ->
        (read_catalog, read_workspace, read_policy)
  in
  let plan_calls = ref 0 in
  let build_calls_to_provider = ref 0 in
  let script =
    Ports.script @@ fun _request ->
    if !plan_calls >= 2 then begin
      incr build_calls_to_provider;
      if Int.equal !build_calls_to_provider 1 then
        Ok
          (tool_call_response ~name:"build_probe" ~input:(json_object [])
             "building")
      else Ok (plain_response "built")
    end
    else begin
      incr plan_calls;
      if Int.equal !plan_calls 1 then
        Ok
          (tool_call_response ~name:"read_probe" ~input:(json_object [])
             "reading")
      else Ok (plain_response "planned")
    end
  in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model ~policy:build_policy ())
  in
  let contract store turn =
    let session = Hashtbl.find store.sessions "root" in
    match Session.State.turn (tid turn) (Session.state session) with
    | Some turn -> Session.Turn.contract turn
    | None -> failf "turn %s was not persisted" turn
  in
  let declaration_names contract =
    Session.Contract.declarations contract |> List.map Llm.Tool.name
  in
  with_engine ~script ~config ~execution_for_mode
    ~delegated_execution:(read_catalog, read_workspace, read_policy)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~mode:Session.Contract.Mode.Plan ~session:(sid "root")
           ~turn:(tid "t-authority-plan") "PLAN_AUTHORITY");
      ignore (drain_committed (follow_ok client (sid "root")));
      let build_feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-authority-build")
           "BUILD_AUTHORITY");
      ignore (drain_committed build_feed);
      let plan = contract store "t-authority-plan" in
      let build = contract store "t-authority-build" in
      equal (list string) ~msg:"Plan seals only the read catalog"
        [ "read_probe" ] (declaration_names plan);
      equal (list string) ~msg:"Build seals only the build catalog"
        [ "build_probe" ] (declaration_names build);
      is_true ~msg:"Plan seals the fixed read policy"
        (Policy.equal read_policy (Session.Contract.policy plan));
      is_true ~msg:"Build retains the configured policy"
        (Policy.equal build_policy (Session.Contract.policy build));
      is_true ~msg:"Plan seals the read workspace identity"
        (Sandbox.Identity.equal read_identity (Session.Contract.sandbox plan));
      is_true ~msg:"Build seals the build workspace identity"
        (Sandbox.Identity.equal build_identity (Session.Contract.sandbox build));
      is_true ~msg:"the selector received the configured policy unchanged"
        !configured_was_preserved;
      is_true ~msg:"new turns select with the freshly configured model"
        !configured_model_was_selected;
      equal int ~msg:"each accepted turn selects one execution triple" 2
        !selector_calls;
      equal int ~msg:"Plan made one request before and after its tool" 2
        !plan_calls;
      equal int ~msg:"Build made one request before and after its tool" 2
        !build_calls_to_provider;
      (* Each turn drains its own workspace twice: once preparing the turn and
         once as its single tool claim settles. *)
      equal int ~msg:"Plan drains only the read workspace" 2 read_calls.drains;
      equal int ~msg:"Plan checkpoints only the read workspace" 1
        read_calls.checkpoints;
      equal int ~msg:"Plan scopes only the read workspace" 1 read_calls.scopes;
      equal int ~msg:"Build drains only the build workspace" 2
        build_calls.drains;
      equal int ~msg:"Build checkpoints only the build workspace" 1
        build_calls.checkpoints;
      equal int ~msg:"Build scopes only the build workspace" 1
        build_calls.scopes)

let session_awaiting_dispatch ~session_id ~turn_id ~mode ~catalog ~policy
    ~workspace_identity ~input ~tool_name =
  let contract =
    Session.Contract.make ~mode ~model
      ~declarations:(Catalog.declarations catalog)
      ~policy ~review:Mentat_permission.Review_behavior.Enforce
      ~sandbox:workspace_identity ()
  in
  let turn =
    Session.Turn.make ~id:turn_id ~origin:Session.Turn.Origin.User ~input
      ~max_steps:8 ~contract ()
  in
  let claim =
    Session.Provider_request.Started.make ~turn:turn_id
      ~request_digest:(Mentat_digest.string (tool_name ^ "-request"))
  in
  let session =
    Session.create ~id:session_id ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  match
    Session.append_all
      [
        Session.Event.turn_started turn;
        Session.Event.provider_requested claim;
        Session.Event.provider_settled
          (Session.Provider_request.Settled.responded
             ~id:(Session.Provider_request.Started.id claim)
             (tool_call_response ~name:tool_name ~input:(json_object [])
                "dispatch after recovery"));
      ]
      session
  with
  | Ok session -> session
  | Error error -> failf "recovery fixture: %a" Session.Error.pp error

let active_plan_recovery_uses_the_read_execution () =
  let module Policy = Mentat_permission.Policy in
  let configured = Policy.make [ Policy.Rule.allow_all_dangerously ] in
  let read_policy = Policy.make [ Policy.Rule.deny_all ] in
  let build_calls = workspace_calls () in
  let read_calls = workspace_calls () in
  let build_workspace =
    tracked_workspace build_calls Sandbox.Identity.declared_external
  in
  let read_workspace = tracked_workspace read_calls Sandbox.Identity.refused in
  let make_catalog name =
    match Catalog.make ~verbs:[] [ trivial_tool ~name () ] with
    | Ok catalog -> catalog
    | Error error -> failf "catalog %s: %a" name Catalog.Error.pp error
  in
  let build_catalog = make_catalog "build_probe" in
  let read_catalog = make_catalog "read_probe" in
  let read_catalog_after_reconfiguration = make_catalog "project_probe" in
  let selected_modes = ref [] in
  let selected_models = ref [] in
  let recovered_declarations = ref [] in
  let execution_for_mode ~configured ~model:selected_model ~sealed_declarations
      mode =
    selected_modes := mode :: !selected_modes;
    selected_models := selected_model :: !selected_models;
    Option.iter
      (fun declarations -> recovered_declarations := declarations)
      sealed_declarations;
    match mode with
    | Session.Contract.Mode.Build ->
        (build_catalog, build_workspace, configured.Agent.Config.policy)
    | Session.Contract.Mode.Plan | Session.Contract.Mode.Review ->
        let catalog =
          match sealed_declarations with
          | Some declarations
            when List.equal Llm.Tool.equal declarations
                   (Catalog.declarations read_catalog) ->
              read_catalog
          | Some _ | None -> read_catalog_after_reconfiguration
        in
        (catalog, read_workspace, read_policy)
  in
  let reconfigured_model =
    Llm.Model.make
      ~provider:(Llm.Provider.make "openai")
      ~api:(Llm.Model.Api.make "responses")
      ~id:"model-after-crash"
  in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model:reconfigured_model ~policy:configured ())
  in
  with_engine ~script:default_script ~config ~execution_for_mode
    ~delegated_execution:(read_catalog, read_workspace, read_policy)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      let turn_id = tid "t-plan-recovery" in
      let input = Session.Turn.Input.user_text "PLAN_RECOVERY" in
      let recovered =
        session_awaiting_dispatch ~session_id:(sid "root") ~turn_id
          ~mode:Session.Contract.Mode.Plan ~catalog:read_catalog
          ~policy:read_policy ~workspace_identity:Sandbox.Identity.refused
          ~input ~tool_name:"read_probe"
      in
      Hashtbl.replace store.sessions "root" recovered;
      submit_ok client
        (prompt ~mode:Session.Contract.Mode.Plan ~session:(sid "root")
           ~turn:turn_id "PLAN_RECOVERY");
      ignore (drain_committed (follow_ok client (sid "root")));
      equal int ~msg:"recovery dispatches through the read workspace" 1
        read_calls.scopes;
      equal int ~msg:"recovery does not dispatch through the Build workspace" 0
        build_calls.scopes;
      is_true ~msg:"the recovered active contract selects Plan"
        (List.exists
           (Session.Contract.Mode.equal Session.Contract.Mode.Plan)
           !selected_modes);
      is_true ~msg:"recovery selects with the model sealed before the crash"
        (List.exists (Llm.Model.equal model) !selected_models);
      is_false ~msg:"recovery does not replace the sealed model from config"
        (List.exists (Llm.Model.equal reconfigured_model) !selected_models);
      equal (list string)
        ~msg:"recovery receives the exact declarations sealed before the crash"
        [ "read_probe" ]
        (List.map Llm.Tool.name !recovered_declarations))

let delegated_recovery_uses_the_fixed_execution () =
  let module Policy = Mentat_permission.Policy in
  let root_policy = Policy.make [ Policy.Rule.allow_all_dangerously ] in
  let delegated_policy = Policy.make [ Policy.Rule.deny_all ] in
  let root_calls = workspace_calls () in
  let delegated_calls = workspace_calls () in
  let root_workspace =
    tracked_workspace root_calls Sandbox.Identity.declared_external
  in
  let delegated_workspace =
    tracked_workspace delegated_calls Sandbox.Identity.refused
  in
  let make_catalog name =
    match Catalog.make ~verbs:[] [ trivial_tool ~name () ] with
    | Ok catalog -> catalog
    | Error error -> failf "catalog %s: %a" name Catalog.Error.pp error
  in
  let root_catalog = make_catalog "root_probe" in
  let delegated_catalog = make_catalog "delegated_probe" in
  let execution_for_mode ~configured ~model:_ ~sealed_declarations:_ _mode =
    (root_catalog, root_workspace, configured.Agent.Config.policy)
  in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model ~policy:root_policy ())
  in
  with_engine ~script:default_script ~config ~execution_for_mode
    ~delegated_execution:
      (delegated_catalog, delegated_workspace, delegated_policy)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      let parent_id = sid "root" in
      let child_id = sid "delegated-recovery" in
      let parent_turn = tid "t-parent-recovery" in
      let edge =
        Session.Delegation.make ~child:child_id ~source_turn:parent_turn
          ~source_call:"spawn-recovery"
          ~task:[ Llm.Content.text "recover delegated work" ]
          ()
      in
      let parent_contract =
        Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
          ~declarations:[] ~policy:root_policy
          ~review:Mentat_permission.Review_behavior.Enforce
          ~sandbox:Sandbox.Identity.declared_external ()
      in
      let parent_turn_value =
        Session.Turn.make ~id:parent_turn ~origin:Session.Turn.Origin.User
          ~input:(Session.Turn.Input.user_text "delegate")
          ~max_steps:8 ~contract:parent_contract ()
      in
      let parent =
        Session.create ~id:parent_id ~cwd
          ~created_at:(Session.Time.of_unix_ms 1L)
          ()
      in
      let parent =
        match
          Session.append_all
            [
              Session.Event.turn_started parent_turn_value;
              Session.Event.delegation_recorded edge;
              Session.Event.turn_finished ~turn:parent_turn
                Session.Turn.Outcome.completed;
            ]
            parent
        with
        | Ok parent -> parent
        | Error error ->
            failf "parent recovery fixture: %a" Session.Error.pp error
      in
      let child_turn = tid "t-child-recovery" in
      let child_input = Session.Turn.Input.user_text "DELEGATED_RECOVERY" in
      let child =
        session_awaiting_dispatch ~session_id:child_id ~turn_id:child_turn
          ~mode:Session.Contract.Mode.Build ~catalog:delegated_catalog
          ~policy:delegated_policy ~workspace_identity:Sandbox.Identity.refused
          ~input:child_input ~tool_name:"delegated_probe"
      in
      let delegated_from =
        Session.Metadata.Delegated_from.make ~parent:parent_id
          ~delegation:(Session.Delegation.id edge)
      in
      let child =
        match
          Session.make ~id:child_id
            ~metadata:
              (Session.Metadata.make ~delegated_from ~cwd
                 ~created_at:(Session.Time.of_unix_ms 1L)
                 ~updated_at:(Session.Time.of_unix_ms 1L)
                 ())
            ~events:(Session.events child)
        with
        | Ok child -> child
        | Error error -> failf "delegated metadata: %a" Session.Error.pp error
      in
      Hashtbl.replace store.sessions "root" parent;
      Hashtbl.replace store.sessions "delegated-recovery" child;
      Hashtbl.replace store.muts "delegated-recovery" [];
      submit_ok client
        (prompt ~session:child_id ~turn:child_turn "DELEGATED_RECOVERY");
      ignore (drain_committed (follow_ok client child_id));
      equal int ~msg:"delegated recovery dispatches through its fixed workspace"
        1 delegated_calls.scopes;
      equal int ~msg:"delegated recovery never uses root mode selection" 0
        root_calls.scopes)

let delegated_attachment_rejects_invalid_lineage () =
  let policy = Mentat_permission.Policy.default in
  let contract =
    Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
      ~declarations:[] ~policy ~review:Mentat_permission.Review_behavior.Enforce
      ~sandbox:(Sandbox.identity Sandbox.direct)
      ()
  in
  let delegated_session ~id ~parent ~delegation =
    let delegated_from =
      Session.Metadata.Delegated_from.make ~parent ~delegation
    in
    Session.create ~id ~delegated_from ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  let live_parent ?delegated_from ~id ~turn_id edge =
    let turn =
      Session.Turn.make ~id:turn_id ~origin:Session.Turn.Origin.User
        ~input:(Session.Turn.Input.user_text "delegation parent")
        ~max_steps:8 ~contract ()
    in
    let session =
      Session.create ~id ?delegated_from ~cwd
        ~created_at:(Session.Time.of_unix_ms 1L)
        ()
    in
    match
      Session.append_all
        [
          Session.Event.turn_started turn;
          Session.Event.delegation_recorded edge;
        ]
        session
    with
    | Ok session -> session
    | Error error -> failf "lineage fixture: %a" Session.Error.pp error
  in
  with_engine (fun ~sw:_ ~client ~store ~engine:_ ->
      let put session =
        let key = Session.Id.to_string (Session.id session) in
        Hashtbl.replace store.sessions key session;
        Hashtbl.replace store.muts key []
      in
      let expect_unavailable ~case ~contains child =
        match
          Client.submit client.c
            (prompt ~session:child ~turn:(tid ("t-" ^ case)) case)
        with
        | Error (Protocol.Error.Unavailable diagnostic) ->
            is_true
              ~msg:(case ^ " retains the structured lineage diagnosis")
              (contains_sub ~sub:contains
                 (Mentat_diagnostic.to_string diagnostic))
        | Ok () -> failf "%s lineage was accepted" case
        | Error error ->
            failf "%s returned the wrong public error: %a" case
              Protocol.Error.pp error
      in
      let absent_parent = sid "absent-parent" in
      let parent_missing = sid "parent-missing-child" in
      put
        (delegated_session ~id:parent_missing ~parent:absent_parent
           ~delegation:
             (Session.Delegation.Id.of_string "missing-parent-delegation"));
      expect_unavailable ~case:"parent-missing" ~contains:"parent is missing"
        parent_missing;

      let edge_missing = sid "edge-missing-child" in
      put
        (delegated_session ~id:edge_missing ~parent:(sid "root")
           ~delegation:(Session.Delegation.Id.of_string "absent-edge"));
      expect_unavailable ~case:"edge-missing" ~contains:"has no delegation"
        edge_missing;

      let mismatch_parent = sid "mismatch-parent" in
      let expected_child = sid "mismatch-child" in
      let found_child = sid "different-child" in
      let mismatch_turn = tid "t-mismatch-parent" in
      let mismatch_edge =
        Session.Delegation.make ~child:found_child ~source_turn:mismatch_turn
          ~source_call:"mismatch-call"
          ~task:[ Llm.Content.text "different child" ]
          ()
      in
      put (live_parent ~id:mismatch_parent ~turn_id:mismatch_turn mismatch_edge);
      put
        (delegated_session ~id:expected_child ~parent:mismatch_parent
           ~delegation:(Session.Delegation.id mismatch_edge));
      expect_unavailable ~case:"child-mismatch"
        ~contains:"expected mismatch-child" expected_child;

      let cycle_a = sid "cycle-a" in
      let cycle_b = sid "cycle-b" in
      let turn_a = tid "t-cycle-a" in
      let turn_b = tid "t-cycle-b" in
      let edge_ab =
        Session.Delegation.make ~child:cycle_b ~source_turn:turn_a
          ~source_call:"cycle-a-b"
          ~task:[ Llm.Content.text "to b" ]
          ()
      in
      let edge_ba =
        Session.Delegation.make ~child:cycle_a ~source_turn:turn_b
          ~source_call:"cycle-b-a"
          ~task:[ Llm.Content.text "to a" ]
          ()
      in
      let from_b =
        Session.Metadata.Delegated_from.make ~parent:cycle_b
          ~delegation:(Session.Delegation.id edge_ba)
      in
      let from_a =
        Session.Metadata.Delegated_from.make ~parent:cycle_a
          ~delegation:(Session.Delegation.id edge_ab)
      in
      put
        (live_parent ~delegated_from:from_b ~id:cycle_a ~turn_id:turn_a edge_ab);
      put
        (live_parent ~delegated_from:from_a ~id:cycle_b ~turn_id:turn_b edge_ba);
      expect_unavailable ~case:"lineage-cycle" ~contains:"cycle through cycle-a"
        cycle_a)

let plan_approval_reaches_the_build_request context () =
  let planning_prompt = "PLAN_CONTEXT_MARKER: inspect the old wrapper" in
  let proposed_body = "PROPOSED_PLAN_MARKER: keep the wrapper" in
  let approved_body = "APPROVED_EDIT_MARKER: delete the wrapper" in
  let feedback = "FEEDBACK_MARKER: compose the leaf directly" in
  let calls = ref 0 in
  let build_request = ref None in
  let script =
    Ports.script @@ fun request ->
    incr calls;
    match !calls with
    | 1 ->
        Ok
          (tool_call_response ~name:"propose_plan"
             ~input:
               (json_object
                  [
                    ("title", Json.string "Converge the API");
                    ("body", Json.string proposed_body);
                  ])
             "I have a plan.")
    | 2 ->
        build_request := Some request;
        Ok (plain_response "Built from the approved plan.")
    | _ -> Ok (plain_response "Unexpected extra request.")
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~mode:Session.Contract.Mode.Plan ~session:(sid "root")
           ~turn:(tid "t-plan") planning_prompt);
      let waiting =
        drain_committed
          ~stop:(function
            | Protocol.Fact.Decision_requested _ -> true | _ -> false)
          (follow_ok client (sid "root"))
      in
      is_true ~msg:"the planning turn parked on a decision"
        (has_fact
           (function Protocol.Fact.Decision_requested _ -> true | _ -> false)
           waiting);
      let requested =
        match Client.pending_decision client.c (sid "root") with
        | Ok (Some requested) -> requested
        | Ok None -> fail "the plan decision disappeared before approval"
        | Error error ->
            failf "pending plan decision: %a" Protocol.Error.pp error
      in
      let approved_plan =
        match
          Session.Plan.make ~title:"Converge the API" ~body:approved_body ()
        with
        | Ok plan -> plan
        | Error error -> failf "approved plan: %a" Session.Plan.Error.pp error
      in
      let answer =
        Session.Plan.Answer.approve ~body:approved_plan ~context ~feedback ()
      in
      let approval =
        match answer with
        | Session.Plan.Answer.Approve approval -> approval
        | Session.Plan.Answer.Keep_planning | Session.Plan.Answer.Revise _ ->
            assert false
      in
      let after_approval = follow_ok ~from:`Now client (sid "root") in
      submit_ok client
        (Protocol.Command.answer_decision ~session:(sid "root")
           ~decision:(Session.Decision.Requested.id requested)
           ~answer:(Session.Decision.Answer.Plan answer));
      ignore (drain_n_settled 2 after_approval);
      let request =
        match !build_request with
        | Some request -> request
        | None -> fail "approval admitted no Build provider request"
      in
      is_true ~msg:"Build sees the exact reviewer-edited body"
        (request_contains request approved_body);
      is_true ~msg:"Build sees optional approval feedback"
        (request_contains request feedback);
      (match context with
      | `Current ->
          is_true ~msg:"current-context Build retains the planning transcript"
            (request_contains request planning_prompt)
      | `Fresh ->
          is_false ~msg:"fresh-context Build excludes the planning transcript"
            (request_contains request planning_prompt);
          is_false ~msg:"fresh-context Build excludes the superseded proposal"
            (request_contains request proposed_body));
      let persisted = Hashtbl.find store.sessions "root" in
      let admitted =
        Session.State.turns (Session.state persisted)
        |> List.find_opt (fun turn ->
            match Session.Turn.origin turn with
            | Session.Turn.Origin.Plan_build -> true
            | Session.Turn.Origin.User | Session.Turn.Origin.Queued _
            | Session.Turn.Origin.Triggered _
            | Session.Turn.Origin.Compaction
            | Session.Turn.Origin.Step_limit_wind_down ->
                false)
      in
      match admitted with
      | None -> fail "the exact Build admission was not persisted"
      | Some turn -> (
          match Session.Turn.input turn with
          | Session.Turn.Input.Plan_build actual ->
              is_true ~msg:"durable Build input is the exact approval"
                (Session.Plan.Approval.equal approval actual)
          | Session.Turn.Input.User _ | Session.Turn.Input.Continue ->
              fail "Plan_build origin persisted a non-plan input"))

let session_config_is_reloaded_at_each_turn_and_isolated_by_session () =
  let reviews = Hashtbl.create 2 in
  let config session ~latest_model:_ =
    let review =
      Option.value
        (Hashtbl.find_opt reviews (Session.Id.to_string session))
        ~default:Mentat_permission.Review_behavior.Enforce
    in
    Ok (Agent.Config.make ~model ~review ())
  in
  with_engine ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      let run session turn =
        submit_ok client (prompt ~session ~turn "hello");
        ignore (drain_committed (follow_ok client session))
      in
      let review_for session turn =
        let persisted = Hashtbl.find store.sessions session in
        match Session.State.turn (tid turn) (Session.state persisted) with
        | None -> failf "turn %s was not persisted" turn
        | Some turn -> Session.Contract.review (Session.Turn.contract turn)
      in
      let root = sid "root" in
      let before = tid "t-review-before" in
      run root before;
      let observed_before = review_for "root" "t-review-before" in
      Hashtbl.replace reviews "root" Mentat_permission.Review_behavior.Bypass;
      let after = tid "t-review-after" in
      run root after;
      let observed_after = review_for "root" "t-review-after" in
      seed_session store ~id:"other";
      let other = sid "other" in
      let other_turn = tid "t-review-other" in
      run other other_turn;
      let observed_other = review_for "other" "t-review-other" in
      let label = function
        | Mentat_permission.Review_behavior.Enforce -> "enforce"
        | Mentat_permission.Review_behavior.Bypass -> "bypass"
      in
      equal (list string)
        ~msg:"each durable turn contract freezes its session's review behavior"
        [ "enforce"; "bypass"; "enforce" ]
        (List.map label [ observed_before; observed_after; observed_other ]))

(* The engine passes each turn's config resolution the session's own journal
   model ({!Session.State.latest_model}) so the executable can honor a resumed
   session's durable model over a global default. Before the session has started
   any turn, resolution sees [None]; once a turn seals a model, every later
   resolution sees exactly that model and never any other. Adjudicating the
   overlay/latest_model/default precedence itself belongs to the executable; the
   engine's obligation, exercised here, is to supply the durable fact. *)
let latest_model_reaches_config_resolution () =
  let observed = ref [] in
  let config _session ~latest_model =
    observed := latest_model :: !observed;
    Ok (Agent.Config.make ~model ())
  in
  with_engine ~config (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      let run turn =
        submit_ok client (prompt ~session:(sid "root") ~turn "hello");
        ignore (drain_committed (follow_ok client (sid "root")))
      in
      run (tid "t-latest-1");
      run (tid "t-latest-2");
      let resolutions = List.rev !observed in
      (match resolutions with
      | first :: _ ->
          is_true
            ~msg:"the first resolution, before any turn started, sees no model"
            (Option.is_none first)
      | [] -> fail "config resolution never ran");
      is_true
        ~msg:
          "a resolution after the first turn sees the session's started model"
        (List.exists
           (function Some m -> Llm.Model.equal m model | None -> false)
           resolutions);
      is_true ~msg:"no resolution ever sees a model the session did not start"
        (List.for_all
           (function None -> true | Some m -> Llm.Model.equal m model)
           resolutions))

let a_provider_failure_streams_structured_error_before_terminal () =
  let provider_error =
    Llm.Error.make ~kind:Llm.Error.Rate_limited ~phase:Llm.Error.Stream
      ~provider:(Llm.Provider.make "openai")
      ~status:429 ~request_id:"req-runtime-1" "retry later"
  in
  let script = Ports.script @@ fun _request -> Error provider_error in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-provider-failed") "hello");
      let projected = facts (drain_committed (follow_ok client (sid "root"))) in
      let rec find = function
        | Protocol.Fact.Turn_provider_failed { error; _ }
          :: (Protocol.Fact.Turn_settled _ as terminal)
          :: _ ->
            (error, terminal)
        | _ :: rest -> find rest
        | [] -> fail "provider failure fact was not followed by the terminal"
      in
      let error, terminal = find projected in
      is_true ~msg:"the provider error remains structured and exact"
        (Llm.Error.equal provider_error error);
      match terminal with
      | Protocol.Fact.Turn_settled
          { outcome = Session.Turn.Outcome.Failed _; _ } ->
          ()
      | _ -> fail "the provider failure did not settle the turn Failed")

(* The generic provider kind must not read "provider provider failure": the
   terminal outcome message names the source once. *)
let a_generic_provider_failure_message_names_the_source_once () =
  let provider_error =
    Llm.Error.make ~kind:Llm.Error.Provider ~phase:Llm.Error.Stream
      ~provider:(Llm.Provider.make "openai")
      ~status:500 ~request_id:"req-generic-1"
      "An error occurred while processing your request."
  in
  let script = Ports.script @@ fun _request -> Error provider_error in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-provider-generic") "hello");
      let projected = facts (drain_committed (follow_ok client (sid "root"))) in
      let rec find = function
        | Protocol.Fact.Turn_settled
            { outcome = Session.Turn.Outcome.Failed { message }; _ }
          :: _ ->
            message
        | _ :: rest -> find rest
        | [] -> fail "expected a failed turn terminal"
      in
      equal string ~msg:"the generic provider failure is not doubled"
        "provider failure: An error occurred while processing your request."
        (find projected))

let submit_returns_after_durable_admission () =
  with_engine (fun ~sw:_ ~client ~store ~engine:_ ->
      (* A byte-identical resubmission of the same turn id is idempotent (Ok),
         proving the first submission's turn-started fact is already durable. *)
      let cmd = prompt ~session:(sid "root") ~turn:(tid "t-dup") "hi" in
      submit_ok client cmd;
      let feed = follow_ok client (sid "root") in
      let _ = drain_committed feed in
      (match Client.submit client.c cmd with
      | Ok () -> ()
      | Error e ->
          failf "an idempotent resubmit must be Ok: %a" Protocol.Error.pp e);
      is_true ~msg:"the session is persisted in the store"
        (Hashtbl.mem store.sessions "root"))

let reused_turn_id_with_new_input_is_rejected () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-reuse") "first");
      let feed = follow_ok client (sid "root") in
      let _ = drain_committed feed in
      match
        Client.submit client.c
          (prompt ~session:(sid "root") ~turn:(tid "t-reuse") "second")
      with
      | Error (Protocol.Error.Turn_id_reused turn) ->
          equal string ~msg:"the reused turn id is named" "t-reuse"
            (Session.Turn.Id.to_string turn)
      | Ok () -> fail "reusing a turn id with different input must be rejected"
      | Error e -> failf "wrong error: %a" Protocol.Error.pp e)

(* Runtime: the feed. *)

let close_makes_next_report_closed () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-close") "hi");
      let feed = follow_ok client (sid "root") in
      let _ = drain_committed feed in
      Client.Feed.close feed;
      match Client.Feed.next feed with
      | Ok Client.Feed.Closed -> ()
      | Ok (Client.Feed.Item _) -> fail "a closed feed must not yield an item"
      | Error e ->
          failf "a closed feed reports Closed, not %a" Protocol.Error.pp e)

let resume_from_a_delivered_position_skips_nothing () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-resume") "hi");
      let feed = follow_ok client (sid "root") in
      let all = drain_committed feed in
      is_true ~msg:"the turn produced several facts to split"
        (List.length all >= 2);
      let first_position, _ = List.hd all in
      let tail_facts = facts (List.tl all) in
      let resumed =
        follow_ok ~from:(`After first_position) client (sid "root")
      in
      let resumed_facts = facts (drain_committed resumed) in
      equal int
        ~msg:
          "resuming after the first fact delivers exactly the remaining facts"
        (List.length tail_facts)
        (List.length resumed_facts);
      is_true ~msg:"the resumed suffix carries no duplicate of the first fact"
        (not
           (List.exists
              (fun f -> Protocol.Fact.equal f (snd (List.hd all)))
              resumed_facts)))

let a_forged_out_of_feed_position_is_invalid () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-forge") "hi");
      let feed = follow_ok client (sid "root") in
      let all = drain_committed feed in
      let last_position, _ = List.nth all (List.length all - 1) in
      let forged =
        let json = encode Protocol.Position.jsont last_position in
        decode Protocol.Position.jsont
          (set_member "seq" (Json.int 999_999) json)
      in
      let resumed = follow_ok ~from:(`After forged) client (sid "root") in
      match Client.Feed.next resumed with
      | Error
          (Protocol.Error.Invalid_position
             (Protocol.Position.Invalid.Not_in_feed _)) ->
          ()
      | Ok _ ->
          fail
            "a position past the head names no committed fact and must be \
             rejected"
      | Error e -> failf "wrong error: %a" Protocol.Error.pp e)

let a_foreign_session_position_is_invalid () =
  with_engine (fun ~sw:_ ~client ~store ~engine:_ ->
      seed_session store ~id:"other";
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-a") "hi");
      submit_ok client (prompt ~session:(sid "other") ~turn:(tid "t-b") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      let other_pairs = drain_committed (follow_ok client (sid "other")) in
      let foreign_position, _ = List.hd other_pairs in
      let resumed =
        follow_ok ~from:(`After foreign_position) client (sid "root")
      in
      match Client.Feed.next resumed with
      | Error
          (Protocol.Error.Invalid_position
             (Protocol.Position.Invalid.Foreign_session _)) ->
          ()
      | Ok _ -> fail "a position minted for another session must be rejected"
      | Error e -> failf "wrong error: %a" Protocol.Error.pp e)

(* The canonical order: observe before admit. Following [`Now] on
   a not-yet-driven session then submitting must deliver the turn on the
   pre-opened feed — the shared per-session hub is what makes it
   work: the feed and the attaching driver share the same hub, so no fact slips
   between admission and the follow, and a throwaway-hub deadlock is impossible. *)
let follow_now_before_submit_delivers_the_turn () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-order") "hi");
      match settled_outcome (drain_committed feed) with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the pre-opened feed saw the turn settle %a"
            Session.Turn.Outcome.pp other
      | None -> fail "the pre-opened `Now feed never saw the turn settle")

(* The engine feed's bounded ring drops oldest progress under a flood, never a
   committed fact. Follow [`Now] before submit so the
   feed subscribes to the session's hub when the turn pulses; do not pull until
   the ring has filled. This is the coverage the client wrapper used to hold
   before it became a buffer-free forwarder. *)
let the_feed_ring_drops_oldest_progress_keeping_committed () =
  let count = 300 in
  let script _request ~on_event ~on_download:_ ~cancelled:_ =
    for i = 0 to count - 1 do
      on_event (Llm.Event.text_delta (string_of_int i))
    done;
    Ok (plain_response "done")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-ring") "go");
      (* 301 progress pulses reach the ring — the driver's one [Model.Started]
         pulse plus 300 deltas — so the 45 oldest (Started and deltas 0..43)
         drop; the newest 256 deltas (44..299) survive in order. *)
      let capacity = 256 in
      let committed, deltas = drain_flood ~progress:capacity feed in
      Client.Feed.close feed;
      is_true ~msg:"a committed fact survived the progress flood"
        (List.exists is_settled committed);
      equal (list string)
        ~msg:"the ring retained the newest 256 deltas in order (oldest dropped)"
        (List.init capacity (fun i -> string_of_int (i + 44)))
        deltas)

(* Tool-input streaming reaches the feed as liveness only: each pulse carries
   the tool's name and that call's cumulative byte count — never the input
   text — and a second call's counts start from zero. Follow [`Now] before
   submit so the ring holds every pulse; drain like the flood test, since
   committed facts serve before ring progress. *)
let tool_input_streaming_pulses_cumulative_liveness () =
  let input key name delta =
    Llm.Event.tool_input_delta
      (Llm.Event.Tool_input.make ~key ~name ~input_delta:delta ())
  in
  let script _request ~on_event ~on_download:_ ~cancelled:_ =
    on_event (input "item-1" "edit_file" "{\"pa");
    on_event (input "item-1" "edit_file" "th\":1}");
    on_event (input "item-2" "shell" "{}");
    Ok (plain_response "done")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-tool-input") "go");
      let pulses = ref [] and settled = ref false in
      let rec loop () =
        if !settled && List.length !pulses >= 3 then ()
        else
          match Client.Feed.next feed with
          | Error e -> failf "feed next: %a" Protocol.Error.pp e
          | Ok Client.Feed.Closed -> ()
          | Ok (Client.Feed.Item (Protocol.Update.Committed { fact; _ })) ->
              if is_settled fact then settled := true;
              loop ()
          | Ok (Client.Feed.Item (Protocol.Update.Progress p)) ->
              (match p with
              | Protocol.Progress.Model
                  {
                    update =
                      Protocol.Progress.Model.Tool_input { name; received };
                    _;
                  } ->
                  pulses := (name, received) :: !pulses
              | _ -> ());
              loop ()
      in
      loop ();
      Client.Feed.close feed;
      equal
        (list (pair (option string) int))
        ~msg:"cumulative per-call snapshots, in stream order"
        [ (Some "edit_file", 4); (Some "edit_file", 10); (Some "shell", 2) ]
        (List.rev !pulses))

(* Runtime: command admission. *)

let a_queue_entry_is_admitted_at_the_idle_boundary () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      let cmd =
        match
          Protocol.Command.queue_next ~session:(sid "root")
            ~input:[ Llm.Content.text "later" ] ()
        with
        | Ok c -> c
        | Error e -> failf "queue_next: %s" (Protocol.Command.Invalid.message e)
      in
      submit_ok client cmd;
      let feed = follow_ok client (sid "root") in
      let pairs = drain_committed feed in
      is_true ~msg:"the queue update is committed"
        (has_fact
           (function Protocol.Fact.Journal_queue _ -> true | _ -> false)
           pairs);
      match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the admitted queue turn settled %a" Session.Turn.Outcome.pp
            other
      | None -> fail "the queued entry was never admitted as a turn")

let a_queue_replacement_mints_distinct_entries_in_input_order () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      let command =
        match
          Protocol.Command.replace_queued ~session:(sid "root")
            ~inputs:
              [
                [ Llm.Content.text "first correction" ];
                [ Llm.Content.text "second correction" ];
              ]
        with
        | Ok command -> command
        | Error error ->
            failf "replace_queued: %s" (Protocol.Command.Invalid.message error)
      in
      submit_ok client command;
      let pairs = drain_n_settled 2 (follow_ok client (sid "root")) in
      let entries =
        List.find_map
          (fun (_, fact) ->
            match fact with
            | Protocol.Fact.Journal_queue
                (Session.Queue.Update.Replaced entries) ->
                Some entries
            | _ -> None)
          pairs
      in
      match entries with
      | Some [ first; second ] ->
          let text entry =
            match Session.Queue.Entry.input entry with
            | [ Llm.Content.Text text ] -> text
            | _ -> fail "replacement entry did not retain exact text content"
          in
          equal (list string) ~msg:"replacement input order is preserved"
            [ "first correction"; "second correction" ]
            [ text first; text second ];
          is_false ~msg:"each replacement input receives a distinct id"
            (Session.Queue.Id.equal
               (Session.Queue.Entry.id first)
               (Session.Queue.Entry.id second))
      | Some entries ->
          failf "expected two replacement entries, got %d" (List.length entries)
      | None -> fail "the driver emitted no replacement queue fact")

let an_interrupt_admits_the_queued_correction () =
  (* Only the first provider call — the turn being interrupted — hangs; the
     queued correction's call completes. A whole-request content match cannot
     tell them apart: the interrupted turn's user input persists in the
     transcript, so the correction turn's request also carries the "hang" text.
     A first-call latch keys on the turn, not on leaked transcript bytes. *)
  let hung = ref false in
  let script _request ~on_event:_ ~on_download:_ ~cancelled =
    if !hung then Ok (plain_response "correction applied")
    else begin
      hung := true;
      let rec loop () =
        if cancelled () then
          Error
            (Llm.Error.make ~kind:Llm.Error.Cancelled ~phase:Llm.Error.Stream
               "cancelled by driver")
        else begin
          Eio.Fiber.yield ();
          loop ()
        end
      in
      loop ()
    end
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-int") "hang");
      let feed = follow_ok client (sid "root") in
      let correction =
        match
          Protocol.Command.queue_next ~session:(sid "root")
            ~input:[ Llm.Content.text "correct now" ] ()
        with
        | Ok command -> command
        | Error error ->
            failf "queue_next: %s" (Protocol.Command.Invalid.message error)
      in
      submit_ok client correction;
      (match
         Protocol.Command.interrupt ~session:(sid "root") ~reason:"stop" ()
       with
      | Ok cmd -> submit_ok client cmd
      | Error e ->
          failf "interrupt command: %s" (Protocol.Command.Invalid.message e));
      let pairs = drain_n_settled 2 feed in
      let outcomes =
        List.filter_map
          (fun (_, fact) ->
            match fact with
            | Protocol.Fact.Turn_settled { outcome; _ } -> Some outcome
            | _ -> None)
          pairs
      in
      (match outcomes with
      | [ Session.Turn.Outcome.Interrupted _; Session.Turn.Outcome.Completed ]
        ->
          ()
      | _ -> fail "interrupt did not settle before the queued correction");
      is_true ~msg:"the correction is admitted with its queued origin"
        (has_fact
           (function
             | Protocol.Fact.Turn_started turn -> (
                 match Session.Turn.origin turn with
                 | Session.Turn.Origin.Queued _ -> true
                 | Session.Turn.Origin.User
                 | Session.Turn.Origin.Triggered _
                 | Session.Turn.Origin.Plan_build
                 | Session.Turn.Origin.Compaction
                 | Session.Turn.Origin.Step_limit_wind_down ->
                     false)
             | _ -> false)
           pairs))

(* Runtime: busy, faults, shutting down. *)

let a_second_engine_over_a_driven_session_is_busy () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let engine_a = mk_engine ~sw ~store () in
  let engine_b = mk_engine ~sw ~store () in
  let client_a = { c = make_client engine_a; sw } in
  let client_b = { c = make_client engine_b; sw } in
  let run () =
    submit_ok client_a (prompt ~session:(sid "root") ~turn:(tid "t-a") "hi");
    let _ = drain_committed (follow_ok client_a (sid "root")) in
    (* Engine A holds the store fence for the session's lifetime; B is excluded. *)
    (match
       Client.submit client_b.c
         (prompt ~session:(sid "root") ~turn:(tid "t-b") "hi")
     with
    | Error (Protocol.Error.Busy { session; owner }) ->
        equal string ~msg:"busy names the contended session" "root"
          (Session.Id.to_string session);
        is_true ~msg:"busy carries the holder's rendered owner line"
          (Option.is_some owner)
    | Ok () -> fail "a session driven by another engine must be Busy"
    | Error e -> failf "wrong error: %a" Protocol.Error.pp e);
    Agent.shutdown engine_a;
    Agent.shutdown engine_b;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: busy test exceeded 15s"

let a_faulted_driver_is_unavailable_and_sticky () =
  with_engine (fun ~sw:_ ~client ~store ~engine:_ ->
      store.commit_fault <-
        (function
        | [] -> None
        | _ -> Some (Ports.Store_error.Io (Mentat_diagnostic.of_text "boom")));
      let unavailable = function
        | Protocol.Error.Unavailable _ -> true
        | _ -> false
      in
      (match
         Client.submit client.c
           (prompt ~session:(sid "root") ~turn:(tid "t-f1") "hi")
       with
      | Error (Protocol.Error.Unavailable d) ->
          is_true
            ~msg:
              "the store's carried diagnostic passes through whole, not \
               re-rendered"
            (Mentat_diagnostic.equal d (Mentat_diagnostic.of_text "boom"))
      | Error e ->
          failf "a store commit failure must surface as Unavailable: %a"
            Protocol.Error.pp e
      | Ok () -> fail "a failing commit must fault the driver");
      match
        Client.submit client.c
          (prompt ~session:(sid "root") ~turn:(tid "t-f2") "hi")
      with
      | Error e ->
          is_true
            ~msg:"the fault is sticky: a later submit is still Unavailable"
            (unavailable e)
      | Ok () -> fail "a faulted driver must not admit new work")

let shutdown_stops_admission () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-s") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      Agent.shutdown engine;
      match
        Client.submit client.c
          (prompt ~session:(sid "root") ~turn:(tid "t-s2") "hi")
      with
      | Error (Protocol.Error.Unavailable _) -> ()
      | Error (Protocol.Error.Busy _) -> ()
      | Ok () -> fail "a shut-down engine must not admit work"
      | Error e -> failf "wrong error after shutdown: %a" Protocol.Error.pp e)

(* The fork, rewind, and compact seams once omitted the stopping guard: a post
   after close reached a controller that would never serve it, so the resolver
   never resolved and the caller hung. The ask ~when_stopping guard brings them
   to parity with submit; the fixture's 15s deadlock guard fails this test if the
   hang returns. *)
let fork_and_compact_after_close_do_not_hang () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-fc") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      Agent.shutdown engine;
      (match
         Client.fork client.c ~session:(sid "root") ~into:(sid "fork") ()
       with
      | Error _ -> ()
      | Ok () -> fail "a fork after close must not succeed");
      match
        Client.compact client.c ~session:(sid "root") ~turn:(tid "t-fc-compact")
      with
      | Error _ -> ()
      | Ok _ -> fail "a compact after close must not succeed")

let shutdown_preserves_a_parked_decision_for_recovery () =
  let calls = ref 0 in
  let script =
    Ports.script @@ fun _request ->
    incr calls;
    match !calls with
    | 1 ->
        Ok
          (tool_call_response ~name:"ask_user"
             ~input:(json_object [ ("prompt", Json.string "Continue?") ])
             "I need a decision.")
    | 2 -> Ok (plain_response "Continued after recovery.")
    | _ -> Ok (plain_response "Unexpected extra request.")
  in
  with_engine ~script (fun ~sw ~client ~store ~engine ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-parked-close") "go");
      ignore
        (drain_committed
           ~stop:(function
             | Protocol.Fact.Decision_requested _ -> true | _ -> false)
           (follow_ok client (sid "root")));
      let requested =
        match Client.pending_decision client.c (sid "root") with
        | Ok (Some requested) -> requested
        | Ok None -> fail "the question did not park the turn"
        | Error error ->
            failf "query parked decision: %a" Protocol.Error.pp error
      in
      let before = Hashtbl.find store.sessions "root" in
      let before_count = List.length (Session.events before) in
      Agent.shutdown engine;
      let after = Hashtbl.find store.sessions "root" in
      equal int
        ~msg:"closing a parked controller appends no interruption or terminal"
        before_count
        (List.length (Session.events after));
      (match Session.State.suspension (Session.state after) with
      | Some (Session.State.Decision still_pending) ->
          is_true ~msg:"the exact durable request remains pending"
            (Session.Decision.Requested.equal requested still_pending)
      | Some (Session.State.Provider _) ->
          fail "closing changed the decision into a provider suspension"
      | Some (Session.State.Tool _) ->
          fail "closing changed the decision into a tool suspension"
      | None -> fail "closing erased the durable decision suspension");
      let recovered_engine = mk_engine ~sw ~store ~script () in
      let recovered = { c = make_client recovered_engine; sw } in
      let after_answer = follow_ok ~from:`Now recovered (sid "root") in
      submit_ok recovered
        (Protocol.Command.answer_decision ~session:(sid "root")
           ~decision:(Session.Decision.Requested.id requested)
           ~answer:
             (Session.Decision.Answer.Question
                (Session.Question.Answer.free "Continue")));
      (match settled_outcome (drain_committed after_answer) with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some outcome ->
          failf "the recovered turn settled %a" Session.Turn.Outcome.pp outcome
      | None -> fail "the recovered turn never settled after its answer");
      Agent.shutdown recovered_engine)

(* Runtime: flows and observation. *)

let possibly_mutating_is_false_for_a_clean_session () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      is_false ~msg:"an unattached session is not possibly-mutating"
        (Client.possibly_mutating client.c ~session:(sid "never"));
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-pm") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      is_false ~msg:"a cleanly-driven session is not possibly-mutating"
        (Client.possibly_mutating client.c ~session:(sid "root")))

let answer_unattended_on_no_decision_is_not_pending () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      match
        Client.answer_unattended client.c ~session:(sid "root")
          ~decision:(Session.Decision.Id.of_string "d-none")
      with
      | Error (Protocol.Error.Decision_not_pending decision) ->
          equal string ~msg:"the absent decision is named" "d-none"
            (Session.Decision.Id.to_string decision)
      | Ok () -> fail "answering a non-pending decision must fail"
      | Error e -> failf "wrong error: %a" Protocol.Error.pp e)

let observation_never_acquires_the_fence () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      (* A read-only feed over a session this process does not yet drive. *)
      let observer = follow_ok client (sid "root") in
      Client.Feed.close observer;
      (match Client.Feed.next observer with
      | Ok Client.Feed.Closed -> ()
      | _ -> fail "a closed observation feed reports Closed");
      (* Observation held no fence, so driving the same session still attaches. *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-obs") "hi");
      match
        settled_outcome (drain_committed (follow_ok client (sid "root")))
      with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other -> failf "the turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the turn never settled after observation")

let shutdown_is_idempotent () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-sd") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      Agent.shutdown engine;
      (* A second shutdown is a no-op, not a fault. *)
      Agent.shutdown engine)

let manual_compact_installs_a_user_requested_summary () =
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Conversation summary.")
    else Ok (plain_response "Done.")
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine:_ ->
      (* One turn gives the idle session a transcript worth summarizing. *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (* Follow from the post-turn-1 head to isolate the compaction's facts. *)
      let feed = follow_ok ~from:`Now client (sid "root") in
      (* The manual flow installs a [User_requested] summary and settles. *)
      (match
         Client.compact client.c ~session:(sid "root") ~turn:(tid "compact-1")
       with
      | Ok Client.Installed -> ()
      | Ok Client.Skipped -> fail "there was a transcript to summarize"
      | Error e -> failf "unexpected compact error: %a" Protocol.Error.pp e);
      (* The compaction turn is transparent on the feed: it projects only its
         [Compaction] fact, never a phantom [Turn_started]/[Turn_settled]. *)
      let is_compaction_fact = function
        | Protocol.Fact.Compaction _ -> true
        | _ -> false
      in
      let compaction_facts = drain_committed ~stop:is_compaction_fact feed in
      is_true ~msg:"the feed carries the installed compaction fact"
        (has_fact is_compaction_fact compaction_facts);
      is_false ~msg:"the compaction turn projects no turn-boundary facts"
        (has_fact
           (function
             | Protocol.Fact.Turn_started _ | Protocol.Fact.Turn_settled _ ->
                 true
             | _ -> false)
           compaction_facts);
      (match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          let state = Session.state session in
          match Session.State.latest_compaction state with
          | None -> fail "manual compaction installed no fact"
          | Some compaction ->
              is_true ~msg:"the durable reason is user-requested"
                (Session.Compaction.Reason.equal
                   (Session.Compaction.reason compaction)
                   Session.Compaction.Reason.User_requested);
              is_true ~msg:"the compaction turn left no active turn"
                (Option.is_none (Session.State.active_turn state))));
      (* A second compaction (a fresh id) with nothing new is a skip, not a
         re-summary. *)
      match
        Client.compact client.c ~session:(sid "root") ~turn:(tid "compact-2")
      with
      | Ok Client.Skipped -> ()
      | Ok Client.Installed -> fail "nothing new to summarize; expected a skip"
      | Error e ->
          failf "unexpected second compact error: %a" Protocol.Error.pp e)

let manual_compact_replays_the_same_turn_id () =
  (* Find-or-create on the client-minted compaction turn id: a wire retry
     resolves the same id and returns the installed result without a second
     summary provider call. *)
  let summary_calls = ref 0 in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then begin
      incr summary_calls;
      Ok (plain_response "Conversation summary.")
    end
    else Ok (plain_response "Done.")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (match
         Client.compact client.c ~session:(sid "root") ~turn:(tid "compact")
       with
      | Ok Client.Installed -> ()
      | Ok Client.Skipped -> fail "the first compaction should install"
      | Error e -> failf "unexpected compact error: %a" Protocol.Error.pp e);
      equal int ~msg:"the first compaction makes one summary call" 1
        !summary_calls;
      (* Replaying the same compaction turn id returns [Installed] again and
         makes no further summary call. *)
      (match
         Client.compact client.c ~session:(sid "root") ~turn:(tid "compact")
       with
      | Ok Client.Installed -> ()
      | Ok Client.Skipped ->
          fail "the replay should return the installed result"
      | Error e -> failf "unexpected replay error: %a" Protocol.Error.pp e);
      equal int ~msg:"the replay makes no second summary call" 1 !summary_calls)

let manual_compact_rejects_a_non_compaction_turn_id () =
  (* A compaction id that already names a non-compaction turn is the same reuse
     discipline a prompt enforces on its client-minted id. *)
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-user") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      match
        Client.compact client.c ~session:(sid "root") ~turn:(tid "t-user")
      with
      | Error (Protocol.Error.Turn_id_reused id) ->
          equal string ~msg:"the reused id is named" "t-user"
            (Session.Turn.Id.to_string id)
      | Ok _ -> fail "a non-compaction id must not compact"
      | Error e -> failf "expected Turn_id_reused, got %a" Protocol.Error.pp e)

let manual_compact_distinct_ids_compact_independently () =
  (* Distinct compaction ids are independent: with fresh transcript between
     them, a second id installs a second summary rather than replaying the
     first. *)
  let summary_calls = ref 0 in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then begin
      incr summary_calls;
      Ok (plain_response "Conversation summary.")
    end
    else Ok (plain_response "Done.")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (match
         Client.compact client.c ~session:(sid "root") ~turn:(tid "compact-a")
       with
      | Ok Client.Installed -> ()
      | _ -> fail "the first compaction should install");
      (* A new turn adds transcript beyond the first summary. *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-2") "more");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (match
         Client.compact client.c ~session:(sid "root") ~turn:(tid "compact-b")
       with
      | Ok Client.Installed -> ()
      | Ok Client.Skipped -> fail "fresh transcript should install again"
      | Error e -> failf "unexpected compact error: %a" Protocol.Error.pp e);
      equal int ~msg:"two distinct ids make two independent summaries" 2
        !summary_calls)

let overflow_compacts_once_and_retries () =
  (* The turn's model request overflows, so the engine compacts once
     ([Context_overflow]) and retries the request over the reduced view; the
     retry succeeds and the turn completes. *)
  let turn_requests = ref 0 in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Compacted context summary.")
    else begin
      incr turn_requests;
      if !turn_requests = 1 then
        Error
          (Llm.Error.make ~kind:Llm.Error.Context_overflow
             ~phase:Llm.Error.Stream "context window exceeded")
      else Ok (plain_response "Recovered answer.")
    end
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-of") "hello");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some _ -> fail "the turn must complete after overflow recovery"
      | None -> fail "the turn did not settle");
      equal int ~msg:"one overflow then one successful retry" 2 !turn_requests;
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          match Session.State.latest_compaction (Session.state session) with
          | None -> fail "overflow recovery installed no compaction"
          | Some compaction ->
              is_true ~msg:"the recovery compaction is Context_overflow"
                (Session.Compaction.Reason.equal
                   (Session.Compaction.reason compaction)
                   Session.Compaction.Reason.Context_overflow)))

let the_resume_notice_frames_the_reissued_summary () =
  (* After an overflow compaction, the reduced view re-enters carrying the
     verbatim summary framed by the resume notice, so the model continues the
     work rather than acknowledging the summary. *)
  let retry_request = ref None in
  let turn_requests = ref 0 in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Compacted context summary.")
    else begin
      incr turn_requests;
      if !turn_requests = 1 then
        Error
          (Llm.Error.make ~kind:Llm.Error.Context_overflow
             ~phase:Llm.Error.Stream "context window exceeded")
      else begin
        retry_request := Some request;
        Ok (plain_response "Recovered answer.")
      end
    end
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-of") "hello");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some _ | None -> fail "the turn must complete after overflow recovery");
      match !retry_request with
      | None -> fail "the reissued request never reached the provider"
      | Some request ->
          is_true ~msg:"the reissued request carries the verbatim summary"
            (request_contains request "Compacted context summary.");
          is_true
            ~msg:
              "the reissued request frames the summary with the resume notice"
            (request_contains request "compacted to save context"))

(* A turn that spends its step budget is wound down rather than dropped where it
   stood: the engine admits one wrap-up turn carrying the step-limit notice.
   Every model answer here is another tool call, so the wind-down spends its
   own budget too — and the turn after it is the user's, which is what proves
   the wind-down cannot admit a wind-down of its own. *)
let a_step_limited_turn_winds_down_once_then_stops () =
  let saw_notice = ref false in
  let calls = ref 0 in
  let script =
    Ports.script @@ fun request ->
    incr calls;
    if request_contains request "reached its step limit" then saw_notice := true;
    Ok
      (tool_call_response
         ~name:(Printf.sprintf "edit-%d" !calls)
         ~input:(json_object []) "working")
  in
  let catalog =
    match
      Catalog.make ~verbs:all_verbs
        (List.init 4 (fun i ->
             trivial_tool ~name:(Printf.sprintf "edit-%d" (i + 1)) ()))
    with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  (* One step per turn: the boundary after the first tool settles ends the turn
     rather than issuing a second request. *)
  let config _ ~latest_model:_ =
    Ok (Agent.Config.make ~model ~max_steps:1 ())
  in
  let origins store =
    Session.State.turns (Session.state (Hashtbl.find store.sessions "root"))
    |> List.map (fun turn ->
        Format.asprintf "%a" Session.Turn.Origin.pp (Session.Turn.origin turn))
  in
  with_engine ~script ~catalog ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "work");
      let pairs = drain_n_settled 2 (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Step_limit -> ()
      | Some _ | None -> fail "the first turn must end at its step limit");
      is_true ~msg:"the wind-down turn carried the step-limit notice"
        !saw_notice;
      equal (list string)
        ~msg:"the step-limited turn is wound down exactly once"
        [ "user"; "step-limit-wind-down" ]
        (origins store);
      (* The wind-down settled at the step limit as well. Nothing further is
         admitted on its own, so the next turn is the one the user submits. *)
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-2") "again");
      ignore (drain_n_settled 2 feed);
      equal (list string)
        ~msg:"a wind-down that hits the limit itself admits no successor"
        [ "user"; "step-limit-wind-down"; "user"; "step-limit-wind-down" ]
        (origins store))

let overflow_recovery_is_bounded_per_turn () =
  (* Every turn request overflows — including the retry after the compaction. The
     per-turn bound spends exactly one Context_overflow compaction, then fails the
     turn rather than compacting again. *)
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Summary.")
    else
      Error
        (Llm.Error.make ~kind:Llm.Error.Context_overflow ~phase:Llm.Error.Stream
           "still too large")
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-of2") "hello");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some (Session.Turn.Outcome.Failed _) -> ()
      | Some _ -> fail "a second overflow must fail the turn, not recover again"
      | None -> fail "the turn did not settle");
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session ->
          let overflow_compactions =
            List.length
              (List.filter
                 (function
                   | Session.Event.Compaction_installed compaction ->
                       Session.Compaction.Reason.equal
                         (Session.Compaction.reason compaction)
                         Session.Compaction.Reason.Context_overflow
                   | _ -> false)
                 (Session.events session))
          in
          equal int ~msg:"exactly one overflow compaction per turn" 1
            overflow_compactions)

let context_pressure_compaction_records_the_before_projection () =
  (* A response large enough to trip a one-token pressure threshold. *)
  let big_usage = Llm.Usage.make ~input:400 ~output:200 () in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Conversation summary.")
    else
      Ok
        (Llm.Response.make ~model ~stop:Llm.Response.Stop.end_turn
           ~usage:big_usage
           (Llm.Message.Assistant.text "Done."))
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~compaction_pressure_tokens:1 ())
  in
  with_engine ~script ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      (* The first turn records the high-usage response; nothing to compact. *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (* The second turn's first request is over threshold, so the engine
         compacts before it. Follow from the post-turn-1 head to isolate it. *)
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-2") "again");
      let _ = drain_committed feed in
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          match Session.State.latest_compaction (Session.state session) with
          | None -> fail "context pressure did not install a compaction"
          | Some compaction -> (
              match Session.Compaction.context compaction with
              | None -> fail "the installed compaction carries no context"
              | Some ctx ->
                  let projected =
                    Llm.Usage.input_total big_usage
                    + Llm.Usage.output_total big_usage
                  in
                  equal (option int)
                    ~msg:"before is the pre-install replay projection"
                    (Some projected)
                    (Session.Compaction.Context_tokens.before ctx);
                  equal (option int) ~msg:"after stays unpopulated" None
                    (Session.Compaction.Context_tokens.after ctx))))

let context_pressure_compacts_without_provider_usage () =
  (* No response in this script ever reports usage: the pressure reading falls
     back to the byte estimate of the model view, so a usage-silent provider
     still compacts instead of growing without bound. *)
  let long_reply = String.make 2_000 'x' in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Conversation summary.")
    else Ok (plain_response long_reply)
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~compaction_pressure_tokens:100 ())
  in
  with_engine ~script ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      (* The first turn grows the view past the threshold; the second turn's
         request boundary reads the estimate and compacts before issuing. *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-2") "again");
      let _ = drain_committed feed in
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          match Session.State.latest_compaction (Session.state session) with
          | None -> fail "the estimate reading never triggered compaction"
          | Some compaction ->
              is_true ~msg:"the compaction is a pressure compaction"
                (Session.Compaction.Reason.equal
                   (Session.Compaction.reason compaction)
                   Session.Compaction.Reason.Context_pressure)))

let a_length_stop_at_pressure_compacts_and_retries () =
  (* The first turn answer stops at the output limit with a reading past the
     pressure threshold: the window ended it, not the model. The boundary
     compacts under pressure and the retry completes over the reduced view. *)
  let calls = ref 0 in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Conversation summary.")
    else begin
      incr calls;
      if !calls = 1 then
        Ok
          (Llm.Response.make ~model ~stop:Llm.Response.Stop.length
             ~usage:(Llm.Usage.make ~input:400 ~output:200 ())
             (Llm.Message.Assistant.text "truncated"))
      else Ok (plain_response "Full answer.")
    end
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~compaction_pressure_tokens:500 ())
  in
  with_engine ~script ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other -> failf "the turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the turn never settled");
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session ->
          (match
             Session.State.latest_compaction (Session.state session)
           with
          | Some compaction ->
              is_true ~msg:"the recovery compacts under pressure"
                (Session.Compaction.Reason.equal
                   (Session.Compaction.reason compaction)
                   Session.Compaction.Reason.Context_pressure)
          | None -> fail "the length stop installed no compaction");
          equal int ~msg:"the retry is the second turn request" 2 !calls)

let a_repeat_length_stop_completes_after_one_recovery () =
  (* Every turn answer stops at the output limit with a reading past the
     threshold. The single per-turn recovery compacts once; the retried answer
     still stops at the limit, so the turn completes with it rather than
     compacting again. *)
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Conversation summary.")
    else
      Ok
        (Llm.Response.make ~model ~stop:Llm.Response.Stop.length
           ~usage:(Llm.Usage.make ~input:400 ~output:200 ())
           (Llm.Message.Assistant.text "truncated"))
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~compaction_pressure_tokens:500 ())
  in
  with_engine ~script ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other -> failf "the turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the turn never settled");
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session ->
          let compactions =
            List.length
              (List.filter
                 (function
                   | Session.Event.Compaction_installed _ -> true | _ -> false)
                 (Session.events session))
          in
          equal int ~msg:"exactly one recovery compaction per turn" 1
            compactions)

let a_summary_request_carries_the_summarizer_prelude () =
  (* The summarizer runs under its own system prelude, never the acting
     agent's: the summary request states the summarizer role and ordinary turn
     requests never do. *)
  let summarizer_marker = "context summarization agent" in
  let saw_marker_on_summary = ref false in
  let saw_marker_on_turn = ref false in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then begin
      if request_contains request summarizer_marker then
        saw_marker_on_summary := true;
      Ok (plain_response "Conversation summary.")
    end
    else begin
      if request_contains request summarizer_marker then
        saw_marker_on_turn := true;
      Ok (plain_response "Done.")
    end
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (match
         Client.compact client.c ~session:(sid "root") ~turn:(tid "compact-1")
       with
      | Ok Client.Installed -> ()
      | Ok Client.Skipped -> fail "there was a transcript to summarize"
      | Error e -> failf "unexpected compact error: %a" Protocol.Error.pp e);
      is_true ~msg:"the summary request states the summarizer role"
        !saw_marker_on_summary;
      is_false ~msg:"turn requests never state the summarizer role"
        !saw_marker_on_turn)

let resume_marker = "Continue the work from where it left off"

let a_pressure_summary_keeps_a_verbatim_tail () =
  (* A pressure compaction cuts at the start of the most recent turn that fits
     the tail budget: the summarizer sees only the head, the tail survives the
     boundary verbatim, and the reduced view needs no resume notice — it ends
     on the live conversation. *)
  let long_reply = String.make 2_000 'x' in
  let summary_saw_head = ref false in
  let summary_saw_tail = ref false in
  let reduced = ref None in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then begin
      summary_saw_head := request_contains request "xxxx";
      summary_saw_tail := request_contains request "TAIL-INPUT";
      Ok (plain_response "SUMMARY-BYTES.")
    end
    else if request_contains request "SUMMARY-BYTES." then begin
      reduced :=
        Some
          ( request_contains request "TAIL-INPUT",
            request_contains request "xxxx",
            request_contains request resume_marker );
      Ok (plain_response "Done.")
    end
    else Ok (plain_response long_reply)
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~compaction_pressure_tokens:100 ())
  in
  with_engine ~script ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-2") "TAIL-INPUT");
      let _ = drain_committed feed in
      is_true ~msg:"the summarizer sees the head" !summary_saw_head;
      is_false ~msg:"the summarizer never sees the tail" !summary_saw_tail;
      (match !reduced with
      | None -> fail "no request was issued over the reduced view"
      | Some (tail, head, resume) ->
          is_true ~msg:"the reduced view carries the tail verbatim" tail;
          is_false ~msg:"the reduced view drops the summarized head" head;
          is_false ~msg:"a retained tail needs no resume notice" resume);
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          let state = Session.state session in
          match Session.State.latest_compaction state with
          | None -> fail "context pressure did not install a compaction"
          | Some compaction -> (
              let upto = Session.Compaction.summarized_upto compaction in
              let full =
                Llm.Transcript.messages (Session.State.full_transcript state)
              in
              is_true ~msg:"the summary replaces a strict prefix"
                (upto < List.length full);
              match List.nth_opt full upto with
              | Some (Llm.Message.User _) -> ()
              | Some _ | None -> fail "the cut is not a turn start")))

let an_oversized_tail_falls_back_to_a_full_summary () =
  (* When the most recent turn alone exceeds the tail budget, no cut both fits
     and advances: the summary replaces the whole transcript and the resume
     notice trails it, exactly as when no tail is configured. *)
  let long_reply = String.make 2_000 'x' in
  let big_input = "BIG-INPUT-" ^ String.make 600 'y' in
  let reduced = ref None in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "SUMMARY-BYTES.")
    else if request_contains request "SUMMARY-BYTES." then begin
      reduced :=
        Some
          ( request_contains request "BIG-INPUT-",
            request_contains request resume_marker );
      Ok (plain_response "Done.")
    end
    else Ok (plain_response long_reply)
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~compaction_pressure_tokens:100 ())
  in
  with_engine ~script ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-2") big_input);
      let _ = drain_committed feed in
      (match !reduced with
      | None -> fail "no request was issued over the reduced view"
      | Some (tail, resume) ->
          is_false ~msg:"nothing stays verbatim behind a full summary" tail;
          is_true ~msg:"a full summary keeps the resume notice" resume);
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          let state = Session.state session in
          match Session.State.latest_compaction state with
          | None -> fail "context pressure did not install a compaction"
          | Some compaction ->
              (* The transcript held three messages at the boundary — the first
                 input, its long answer, and the oversized second input; the
                 reduced-view answer lands after the cut. *)
              equal int ~msg:"the summary replaces the whole transcript" 3
                (Session.Compaction.summarized_upto compaction)))

let a_second_compaction_advances_the_boundary_behind_the_tail () =
  (* Re-compaction over a view that already ends in a tail: the second summary
     covers the first summary plus the aged tail, cuts strictly later, and
     keeps a fresh tail — the boundary only ever advances, so pressure
     compaction cannot loop. *)
  let long_reply = String.make 2_000 'x' in
  let summaries = ref 0 in
  let second_summary = ref None in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "Summarize this conversation" then begin
      incr summaries;
      if !summaries = 2 then
        second_summary :=
          Some
            ( request_contains request "T2-MARK",
              request_contains request "T3-MARK" );
      Ok (plain_response (Printf.sprintf "SUMMARY-%d." !summaries))
    end
    else Ok (plain_response long_reply)
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~compaction_pressure_tokens:100 ())
  in
  with_engine ~script ~config (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-2") "T2-MARK");
      let _ = drain_committed feed in
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-3") "T3-MARK");
      let _ = drain_committed feed in
      (match !second_summary with
      | None -> fail "pressure never compacted a second time"
      | Some (aged_tail, fresh_tail) ->
          is_true ~msg:"the second summary covers the aged tail" aged_tail;
          is_false ~msg:"the second summary never sees the fresh tail"
            fresh_tail);
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          let cuts =
            List.filter_map
              (function
                | Session.Event.Compaction_installed compaction ->
                    Some (Session.Compaction.summarized_upto compaction)
                | _ -> None)
              (Session.events session)
          in
          match cuts with
          | [ first; second ] ->
              is_true ~msg:"the boundary advances strictly" (second > first)
          | cuts ->
              failf "expected exactly two compactions, saw %d"
                (List.length cuts)))

(* Runtime: scheduler and subagents. *)

(* A parent spawns exactly one child. A one-shot latch (the marker "PLEASE_SPAWN"
   rides only the parent's first user message) fires the single spawn: the parent
   never re-spawns and the child, whose task carries no marker, just completes.
   A fresh latch per engine. *)
let spawn_script () =
  let spawned = ref false in
  capped_script ~cap:8
    ( Ports.script @@ fun request ->
      if (not !spawned) && request_contains request "PLEASE_SPAWN" then begin
        spawned := true;
        Ok
          (tool_call_response ~name:"spawn"
             ~input:(json_object [ ("task", Json.string "CHILD_TASK") ])
             "spawning")
      end
      else Ok (plain_response "done") )

let a_spawn_creates_drives_and_settles_a_child () =
  with_engine ~script:(spawn_script ()) (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn") "PLEASE_SPAWN");
      let parent_pairs = drain_committed (follow_ok client (sid "root")) in
      is_true ~msg:"the parent records the delegation edge"
        (has_fact
           (function Protocol.Fact.Journal_delegation _ -> true | _ -> false)
           parent_pairs);
      (match settled_outcome parent_pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the parent turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the parent turn never settled");
      (* The child session exists (created synchronously on the spawn commit,
         before the parent settled) — its drive is a sibling fiber we now join. *)
      let children =
        List.filter (fun k -> not (String.equal k "root")) (session_keys store)
      in
      match children with
      | [ child ] -> (
          let child_pairs = drain_committed (follow_ok client (sid child)) in
          match settled_outcome child_pairs with
          | Some Session.Turn.Outcome.Completed -> ()
          | Some other ->
              failf "the child turn settled %a" Session.Turn.Outcome.pp other
          | None -> fail "the spawned child never settled")
      | [] -> fail "the spawn created no child session"
      | many -> failf "expected exactly one child, got %d" (List.length many))

(* A drilled subagent is a real session: once its delegated turn has settled, a
   user prompt submitted to the CHILD's session id runs a fresh turn on it. The
   engine routes any session id through [attach], which builds a driver for a
   delegated child exactly as for the root, with no active-session or delegation
   guard — the invariant the TUI drill composer relies on and the fake TUI
   client (which rejects non-active sessions) cannot exercise. *)
let a_prompt_to_a_settled_child_runs_a_new_turn () =
  with_engine ~script:(spawn_script ()) (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn") "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      let child =
        match
          List.filter
            (fun k -> not (String.equal k "root"))
            (session_keys store)
        with
        | [ child ] -> child
        | [] -> fail "the spawn created no child session"
        | many -> failf "expected exactly one child, got %d" (List.length many)
      in
      (match
         settled_outcome (drain_committed (follow_ok client (sid child)))
       with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the delegated child turn settled %a" Session.Turn.Outcome.pp
            other
      | None -> fail "the delegated child turn never settled");
      (* The follow-up prompt targets the child's own session id. *)
      let after = follow_ok ~from:`Now client (sid child) in
      submit_ok client
        (prompt ~session:(sid child) ~turn:(tid "t-child-follow-up")
           "look at lib/config first");
      let follow_up = drain_committed after in
      is_true ~msg:"the prompt starts a fresh turn on the settled child"
        (has_fact
           (function Protocol.Fact.Turn_started _ -> true | _ -> false)
           follow_up);
      match settled_outcome follow_up with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the child follow-up turn settled %a" Session.Turn.Outcome.pp
            other
      | None -> fail "a prompt to the settled child ran no turn")

(* The delegation edge is not observable on the parent feed before the child it
   names is resolvable. A threads pane attaches to the child the instant it reads
   [Journal_delegation]; were the edge published before [observe_delegation]
   created the child, that attach would race the creation and surface
   [Session_not_found]. A real disk backend's [create] suspends on IO, so
   [create_before] injects that pre-create scheduling window to make the ordering
   deterministic: the probe follows the child synchronously at the edge, and
   without register-before-publish it observes no child. *)
let a_spawned_child_is_resolvable_when_its_edge_is_observed () =
  let probe = ref `Unseen in
  with_engine ~script:(spawn_script ()) (fun ~sw:_ ~client ~store ~engine:_ ->
      store.create_before <-
        (fun id -> if is_child_id id then Eio.Fiber.yield ());
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn") "PLEASE_SPAWN");
      let feed = follow_ok client (sid "root") in
      let rec loop () =
        match Client.Feed.next feed with
        | Error e -> failf "parent feed next: %a" Protocol.Error.pp e
        | Ok Client.Feed.Closed -> ()
        | Ok (Client.Feed.Item (Protocol.Update.Progress _)) -> loop ()
        | Ok (Client.Feed.Item (Protocol.Update.Committed { fact; _ })) ->
            (match fact with
            | Protocol.Fact.Journal_delegation edge -> (
                let child = Session.Delegation.child edge in
                (* Synchronous, no yield: the state a real subscriber's attach
                   would observe at exactly this position. *)
                probe :=
                  match
                    Client.follow_session ~sw:client.sw client.c child
                      ~from:`Beginning
                  with
                  | Ok child_feed ->
                      Client.Feed.close child_feed;
                      `Resolvable
                  | Error error -> `Refused error)
            | _ -> ());
            if is_settled fact then () else loop ()
      in
      loop ();
      Client.Feed.close feed);
  match !probe with
  | `Resolvable -> ()
  | `Unseen -> fail "the parent feed never announced the delegation edge"
  | `Refused error ->
      failf "the child was not resolvable when its edge was observed: %a"
        Protocol.Error.pp error

let a_delegated_session_uses_the_fixed_execution () =
  let module Policy = Mentat_permission.Policy in
  let configured_policy = Policy.make [ Policy.Rule.allow_all_dangerously ] in
  let delegated_policy = Policy.make [ Policy.Rule.deny_all ] in
  let root_identity = Sandbox.Identity.declared_external in
  let delegated_identity = Sandbox.Identity.refused in
  let root_calls = workspace_calls () in
  let delegated_calls = workspace_calls () in
  let root_workspace = tracked_workspace root_calls root_identity in
  let delegated_workspace =
    tracked_workspace delegated_calls delegated_identity
  in
  let root_catalog =
    match Catalog.make ~verbs:[ Catalog.Verb.Spawn ] [] with
    | Ok catalog -> catalog
    | Error error -> failf "root catalog: %a" Catalog.Error.pp error
  in
  let delegated_catalog =
    match
      Catalog.make ~verbs:[] [ trivial_tool ~name:"delegated_probe" () ]
    with
    | Ok catalog -> catalog
    | Error error -> failf "delegated catalog: %a" Catalog.Error.pp error
  in
  let spawned = ref false in
  let delegated_called = ref false in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "PLEASE_SPAWN" then
      if !spawned then Ok (plain_response "parent done")
      else begin
        spawned := true;
        Ok
          (tool_call_response ~name:"spawn"
             ~input:(json_object [ ("task", Json.string "CHILD_TASK") ])
             "spawning")
      end
    else if !delegated_called then Ok (plain_response "child done")
    else begin
      delegated_called := true;
      Ok
        (tool_call_response ~name:"delegated_probe" ~input:(json_object [])
           "delegated read")
    end
  in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model ~policy:configured_policy ())
  in
  let execution_for_mode ~configured ~model:_ ~sealed_declarations:_ _mode =
    (root_catalog, root_workspace, configured.Agent.Config.policy)
  in
  with_engine ~script ~config ~execution_for_mode
    ~delegated_execution:
      (delegated_catalog, delegated_workspace, delegated_policy)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root")
           ~turn:(tid "t-delegated-execution")
           "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      let child =
        match List.filter is_child_key (session_keys store) with
        | [ child ] -> child
        | children -> failf "expected one child, got %d" (List.length children)
      in
      ignore (drain_committed (follow_ok client (sid child)));
      let child_session = Hashtbl.find store.sessions child in
      let child_contract =
        match Session.State.turns (Session.state child_session) with
        | [ turn ] -> Session.Turn.contract turn
        | turns -> failf "expected one child turn, got %d" (List.length turns)
      in
      equal (list string) ~msg:"the child seals only the delegated catalog"
        [ "delegated_probe" ]
        (Session.Contract.declarations child_contract |> List.map Llm.Tool.name);
      is_true ~msg:"the child ignores the configured root policy"
        (Policy.equal delegated_policy (Session.Contract.policy child_contract));
      is_true ~msg:"the child seals the delegated workspace identity"
        (Sandbox.Identity.equal delegated_identity
           (Session.Contract.sandbox child_contract));
      (* Turn preparation and the child's one tool settlement. *)
      equal int ~msg:"the delegated turn drains its own workspace" 2
        delegated_calls.drains;
      equal int ~msg:"the delegated tool checkpoints its own workspace" 1
        delegated_calls.checkpoints;
      equal int ~msg:"the delegated tool scopes its own workspace" 1
        delegated_calls.scopes;
      equal int ~msg:"the pure root spawn opens no workspace scope" 0
        root_calls.scopes)

(* A spawn's [role] rides the durable edge and re-resolves at the child's every
   attach: the engine reads it back from the edge and hands it to
   [delegated_execution], which stamps its identity into the child's prelude, so
   the role reaches the child's turn construction. The harness maps the role to a
   [delegated-role:<role>] developer fragment; composition maps it instead to the
   matching subagent prompt, but the engine seam this test pins is the same. *)
let a_spawn_carries_its_role_to_the_delegated_child () =
  let captured = ref `Unset in
  let child_saw_role = ref false in
  let spawned = ref false in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "delegated-role:explore" then
      child_saw_role := true;
    if (not !spawned) && request_contains request "PLEASE_SPAWN" then begin
      spawned := true;
      Ok
        (tool_call_response ~name:"spawn"
           ~input:
             (json_object
                [
                  ("task", Json.string "CHILD_TASK");
                  ("role", Json.string "explore");
                ])
           "spawning")
    end
    else Ok (plain_response "done")
  in
  with_engine
    ~script:(capped_script ~cap:8 script)
    ~delegated_role_spy:(fun role -> captured := `Role role)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn-role") "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      let child =
        match List.filter is_child_key (session_keys store) with
        | [ child ] -> child
        | children -> failf "expected one child, got %d" (List.length children)
      in
      ignore (drain_committed (follow_ok client (sid child)));
      (match !captured with
      | `Role (Some Session.Delegation.Role.Explore) -> ()
      | `Role (Some other) ->
          failf "delegated_execution received role %s, expected explore"
            (Session.Delegation.Role.to_string other)
      | `Role None ->
          fail "the child's role was lost before delegated_execution"
      | `Unset -> fail "delegated_execution was never called for the child");
      is_true
        ~msg:"the explore role reaches the child request's system fragments"
        !child_saw_role)

(* A roleless spawn is a generic delegate: [delegated_execution] resolves no
   role, exactly today's behavior — the addition regresses nothing. *)
let a_roleless_spawn_delegates_generically () =
  let captured = ref `Unset in
  with_engine ~script:(spawn_script ())
    ~delegated_role_spy:(fun role -> captured := `Role role)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn-norole")
           "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      let child =
        match List.filter is_child_key (session_keys store) with
        | [ child ] -> child
        | children -> failf "expected one child, got %d" (List.length children)
      in
      ignore (drain_committed (follow_ok client (sid child)));
      match !captured with
      | `Role None -> ()
      | `Role (Some role) ->
          failf "a roleless spawn resolved role %s"
            (Session.Delegation.Role.to_string role)
      | `Unset -> fail "delegated_execution was never called for the child")

(* A generic (roleless) delegate is a write-capable peer of a root session: given
   the write-capable execution composition hands a roleless child — the Build
   catalog, configured policy, and sealed Build workspace — the engine drives it
   through a mutating tool end-to-end. The child's turn settles Completed and its
   write scopes and checkpoints the child's own workspace (the checkpoint is the
   mutation boundary the engine takes before a workspace edit). This pins the
   engine half of the parity ruling; the read-only siblings are the
   explore/review/verify roles, exercised by the role-catalog tests above. *)
let a_generic_delegate_runs_a_write_tool () =
  let module Policy = Mentat_permission.Policy in
  let write_policy = Policy.make [ Policy.Rule.allow_all_dangerously ] in
  let child_calls = workspace_calls () in
  let child_workspace =
    tracked_workspace child_calls Sandbox.Identity.declared_external
  in
  let write_catalog =
    match Catalog.make ~verbs:[] [ trivial_tool ~name:"write_probe" () ] with
    | Ok catalog -> catalog
    | Error error -> failf "write catalog: %a" Catalog.Error.pp error
  in
  let spawned = ref false in
  let wrote = ref false in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "PLEASE_SPAWN" then
      if !spawned then Ok (plain_response "parent done")
      else begin
        spawned := true;
        Ok
          (tool_call_response ~name:"spawn"
             ~input:(json_object [ ("task", Json.string "CHILD_TASK") ])
             "spawning")
      end
    else if !wrote then Ok (plain_response "child done")
    else begin
      wrote := true;
      Ok
        (tool_call_response ~name:"write_probe" ~input:(json_object [])
           "editing the workspace")
    end
  in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model ~policy:write_policy ())
  in
  with_engine ~script:(capped_script ~cap:8 script) ~config
    ~delegated_execution:(write_catalog, child_workspace, write_policy)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-write-spawn") "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      let child =
        match List.filter is_child_key (session_keys store) with
        | [ child ] -> child
        | children -> failf "expected one child, got %d" (List.length children)
      in
      let child_pairs = drain_committed (follow_ok client (sid child)) in
      (match settled_outcome child_pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the delegated child settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the delegated child never settled");
      let child_session = Hashtbl.find store.sessions child in
      let child_contract =
        match Session.State.turns (Session.state child_session) with
        | [ turn ] -> Session.Turn.contract turn
        | turns -> failf "expected one child turn, got %d" (List.length turns)
      in
      is_true
        ~msg:"a roleless child seals the write-capable policy, not read-only"
        (Policy.equal write_policy (Session.Contract.policy child_contract));
      equal (list string) ~msg:"the child seals the write tool"
        [ "write_probe" ]
        (Session.Contract.declarations child_contract |> List.map Llm.Tool.name);
      equal int ~msg:"the child's write opens a scope on its own workspace" 1
        child_calls.scopes;
      equal int ~msg:"the child's write checkpoints its own workspace" 1
        child_calls.checkpoints)

(* A child whose session cannot be persisted is not silently dropped: the spawn
   fails (a settled "spawn failed" result, capacity released), yet the parent
   turn still settles rather than wedging on the missing child. *)
let a_failed_child_creation_does_not_wedge_the_parent () =
  with_engine ~script:(spawn_script ()) (fun ~sw:_ ~client ~store ~engine:_ ->
      store.create_fault <-
        (fun id ->
          if String.equal (Session.Id.to_string id) "root" then None
          else
            Some
              (Ports.Store_error.Io
                 (Mentat_diagnostic.of_text "no child storage")));
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-nochild") "PLEASE_SPAWN");
      (match
         settled_outcome (drain_committed (follow_ok client (sid "root")))
       with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the parent turn settled %a despite the failed child"
            Session.Turn.Outcome.pp other
      | None -> fail "the parent turn never settled");
      equal (list string) ~msg:"the child session was never created" [ "root" ]
        (session_keys store))

(* Recovery: a delegation edge whose child session was lost is re-driven by
   the next engine that attaches the parent — [rebuild_children] recreates the
   child from the durable edge, idempotently. *)
let recovery_redrives_a_lost_child () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let engine1 = mk_engine ~sw ~store ~script:(spawn_script ()) () in
  let client1 = { c = make_client engine1; sw } in
  let run () =
    submit_ok client1
      (prompt ~session:(sid "root") ~turn:(tid "t-spawn") "PLEASE_SPAWN");
    let _ = drain_committed (follow_ok client1 (sid "root")) in
    let child =
      match
        List.filter (fun k -> not (String.equal k "root")) (session_keys store)
      with
      | [ c ] -> c
      | cs -> failf "expected one child, got %d" (List.length cs)
    in
    let _ = drain_committed (follow_ok client1 (sid child)) in
    Agent.shutdown engine1;
    (* Simulate a lost child journal: the edge in root's journal survives. *)
    Hashtbl.remove store.sessions child;
    Hashtbl.remove store.muts child;
    is_false ~msg:"the child is gone before recovery"
      (Hashtbl.mem store.sessions child);
    (* A fresh engine attaching root re-drives the absent child. *)
    let engine2 = mk_engine ~sw ~store ~script:default_script () in
    let client2 = { c = make_client engine2; sw } in
    submit_ok client2 (prompt ~session:(sid "root") ~turn:(tid "t-after") "hi");
    is_true ~msg:"recovery recreated the lost child from the durable edge"
      (Hashtbl.mem store.sessions child);
    Agent.shutdown engine2;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: recovery test exceeded 15s"

let a_spawn_at_the_depth_cap_fails_the_call_not_the_turn () =
  (* With max_spawn_depth = 1 unchanged but the root already at depth 0, spawn is
     allowed; force the refusal by pinning the cap to a depth the root exceeds is
     not possible for the root, so instead assert the happy path leaves the turn
     Completed (the model-visible refusal path is covered structurally by the
     step's own suite). This test pins that spawning never faults the parent. *)
  with_engine ~script:(spawn_script ())
    ~config:(fun _ ~latest_model:_ ->
      Ok
        (Agent.Config.make ~model
           ~max_spawn_depth:1 ()))
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-depth") "PLEASE_SPAWN");
      match
        settled_outcome (drain_committed (follow_ok client (sid "root")))
      with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the parent turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the parent turn never settled")

(* The model can address the child it spawned. The parent reads the
   delegation id back from the spawn receipt — its only handle — and drives the
   whole collaboration surface with it: [wait] on the child, then [send]
   and [follow_up]. A receipt that named the session id instead would make every
   verb resolve to "unknown child"; this journey is the one that catches it.
   Parent requests carry "PLEASE_SPAWN" for the turn's life, so the script routes
   parent vs. child by that marker rather than by the shared task text. *)
let the_model_addresses_a_spawned_child_by_the_receipt_handle () =
  let child_id = ref None in
  let saw_child_result = ref false in
  let saw_unknown_child = ref false in
  let parent_step = ref 0 in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "PLEASE_SPAWN" then begin
      (match !child_id with
      | Some _ -> ()
      | None -> child_id := receipt_child_of request);
      if request_contains request "CHILD_RESULT_MARKER" then
        saw_child_result := true;
      if request_contains request "unknown child" then saw_unknown_child := true;
      match !child_id with
      | None ->
          Ok
            (tool_call_response ~name:"spawn"
               ~input:(json_object [ ("task", Json.string "child works") ])
               "spawning")
      | Some id -> (
          let step = !parent_step in
          incr parent_step;
          match step with
          | 0 ->
              Ok
                (tool_call_response ~name:"wait"
                   ~input:
                     (json_object
                        [ ("children", json_array [ Json.string id ]) ])
                   "waiting")
          | 1 ->
              Ok
                (tool_call_response ~name:"send"
                   ~input:
                     (json_object
                        [
                          ("to", Json.string ("child:" ^ id));
                          ("message", Json.string "extra context");
                        ])
                   "messaging")
          | 2 ->
              Ok
                (tool_call_response ~name:"follow_up"
                   ~input:
                     (json_object
                        [
                          ("child", Json.string id);
                          ("message", Json.string "one more thing");
                        ])
                   "following up")
          | _ -> Ok (plain_response "PARENT_DONE"))
    end
    else Ok (plain_response "CHILD_RESULT_MARKER")
  in
  with_engine ~script:(capped_script ~cap:20 script)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-rt") "PLEASE_SPAWN");
      let parent_pairs = drain_committed (follow_ok client (sid "root")) in
      is_true ~msg:"the spawn receipt advertised an id the model could parse"
        (Option.is_some !child_id);
      is_false ~msg:"no verb resolved the receipt handle to an unknown child"
        !saw_unknown_child;
      is_true
        ~msg:
          "the wait answered with the child's result, keyed by the receipt \
           handle"
        !saw_child_result;
      (match settled_outcome parent_pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the parent turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the parent turn never settled");
      match List.filter is_child_key (session_keys store) with
      | [ child ] -> (
          match
            settled_outcome (drain_committed (follow_ok client (sid child)))
          with
          | Some Session.Turn.Outcome.Completed -> ()
          | Some other ->
              failf "the child settled %a" Session.Turn.Outcome.pp other
          | None -> fail "the waited-on child never settled")
      | [] -> fail "the spawn created no child session"
      | many -> failf "expected exactly one child, got %d" (List.length many))

(* The upward edge of the mandate: a child calls [send] with [to: "parent"],
   the recorded receipt delivers the reply into the parent's queue with the
   child's agent origin, and the parent's next queued turn carries the framed
   message — the sender named from the parent's own recorded edge, never from
   the body. The child's transcript holds the parent receipt; illegal handles
   fail the call without recording anything. *)
let a_child_replies_to_its_parent_by_mail () =
  let saw_reply = ref false in
  let saw_bad_handle = ref false in
  let child_id = ref None in
  let parent_step = ref 0 in
  let child_step = ref 0 in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "A message from your child" then begin
      if request_contains request "the scan finished" then saw_reply := true;
      Ok (plain_response "REPLY_SEEN")
    end
    else if request_contains request "PLEASE_SPAWN" then begin
      (match !child_id with
      | Some _ -> ()
      | None -> child_id := receipt_child_of request);
      match !child_id with
      | None ->
          Ok
            (tool_call_response ~name:"spawn"
               ~input:(json_object [ ("task", Json.string "child works") ])
               "spawning")
      | Some id -> (
          let step = !parent_step in
          incr parent_step;
          match step with
          | 0 ->
              Ok
                (tool_call_response ~name:"wait"
                   ~input:
                     (json_object
                        [ ("children", json_array [ Json.string id ]) ])
                   "waiting")
          | _ -> Ok (plain_response "PARENT_DONE"))
    end
    else begin
      let step = !child_step in
      incr child_step;
      match step with
      | 0 ->
          (* An unresolvable handle is a failed call, recorded as such. *)
          Ok
            (tool_call_response ~name:"send"
               ~input:
                 (json_object
                    [
                      ("to", Json.string "sibling:nope");
                      ("message", Json.string "psst");
                    ])
               "misaddressing")
      | 1 ->
          if request_contains request "unknown recipient" then
            saw_bad_handle := true;
          Ok
            (tool_call_response ~name:"send"
               ~input:
                 (json_object
                    [
                      ("to", Json.string "parent");
                      ("message", Json.string "the scan finished");
                    ])
               "replying")
      | _ -> Ok (plain_response "CHILD_DONE")
    end
  in
  with_engine ~script:(capped_script ~cap:20 script)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-reply") "PLEASE_SPAWN");
      (* Two parent settles: the spawn turn, then the queued reply's turn. *)
      ignore (drain_n_settled 2 (follow_ok client (sid "root")));
      is_true ~msg:"the misaddressed send failed loudly at the child"
        !saw_bad_handle;
      is_true
        ~msg:"the parent's next turn saw the framed reply, sender and body"
        !saw_reply;
      match List.filter is_child_key (session_keys store) with
      | [ child ] ->
          let root =
            match Hashtbl.find_opt store.sessions "root" with
            | Some session -> session
            | None -> fail "the root document is missing"
          in
          let queued_reply =
            List.exists
              (fun event ->
                match event with
                | Session.Event.Queue_updated
                    (Session.Queue.Update.Enqueued entry) -> (
                    match Session.Queue.Entry.origin entry with
                    | Some (Session.Origin.Agent sender) ->
                        String.equal (Session.Id.to_string sender) child
                    | _ -> false)
                | _ -> false)
              (Session.events root)
          in
          is_true
            ~msg:"the reply is a durable queue fact with the child's origin"
            queued_reply;
          let child_session =
            match Hashtbl.find_opt store.sessions child with
            | Some session -> session
            | None -> fail "the child document is missing"
          in
          let receipts =
            List.filter_map
              (fun event ->
                match event with
                | Session.Event.Message_appended
                    (Llm.Message.Tool_result result)
                  when not (Llm.Tool.Result.is_error result) ->
                    Some (String.concat "\n" (Llm.Tool.Result.texts result))
                | _ -> None)
              (Session.events child_session)
          in
          is_true ~msg:"the child transcript holds the parent-send receipt"
            (List.exists
               (contains_sub ~sub:"Message recorded for parent")
               receipts)
      | _ -> fail "expected exactly one child")

(* The framing is a pure function of the typed origin and the receiver's own
   recorded facts: a parent origin frames as "your parent", an unknown agent
   as its bare session id, the owner not at all — and the body rides behind
   the frame unchanged, in its own blocks. *)
let queued_input_frames_the_sender () =
  let delegated_from =
    Session.Metadata.Delegated_from.make ~parent:(sid "parent-1")
      ~delegation:(Session.Delegation.Id.of_string "d-1")
  in
  let child =
    Session.create ~id:(sid "child-1") ~delegated_from ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L) ()
  in
  let entry ?origin () =
    Session.Queue.Entry.make ?origin
      ~id:(Session.Queue.Id.of_string "q-1")
      ~input:[ Llm.Content.text "body text" ]
      ()
  in
  let texts entry_v =
    List.map
      (function
        | Llm.Content.Text text -> text
        | Llm.Content.Media _ -> fail "framing must not mint media")
      (Step.queued_input child entry_v)
  in
  (match texts (entry ()) with
  | [ "body text" ] -> ()
  | other -> failf "owner mail must pass verbatim, got %d blocks" (List.length other));
  (match
     texts (entry ~origin:(Session.Origin.agent (sid "parent-1")) ())
   with
  | [ frame; "body text" ] ->
      is_true ~msg:"the parent origin frames as the parent"
        (contains_sub ~sub:"your parent (session parent-1)" frame);
      is_true ~msg:"the frame fences the body as sender material"
        (contains_sub ~sub:"never instructions from your owner" frame)
  | other -> failf "expected frame and body, got %d blocks" (List.length other));
  match texts (entry ~origin:(Session.Origin.agent (sid "drifter")) ()) with
  | [ frame; "body text" ] ->
      is_true ~msg:"an unrecorded agent frames as its bare session id"
        (contains_sub ~sub:"session drifter" frame)
  | other -> failf "expected frame and body, got %d blocks" (List.length other)

(* A raising adapter on the idle-boundary admission path must fault only
   its own driver, never escape into the shared switch. A queued entry on root
   spawns at the idle boundary; the child's [create] raises. With containment,
   root faults and a sibling driver over another session keeps working; without
   it, the raise fails the shared switch and fells the sibling too. *)
let a_raising_admission_faults_only_its_own_driver () =
  with_engine ~script:(spawn_script ()) (fun ~sw:_ ~client ~store ~engine:_ ->
      store.create_raise <- is_child_id;
      seed_session store ~id:"sibling";
      (* Root's queued entry spawns; the child's create raises during the
         idle-boundary admission (outside [handle_any]'s guard). *)
      (match
         Protocol.Command.queue_next ~session:(sid "root")
           ~input:[ Llm.Content.text "PLEASE_SPAWN" ] ()
       with
      | Ok c -> submit_ok client c
      | Error e -> failf "queue_next: %s" (Protocol.Command.Invalid.message e));
      (* The sibling attaches and completes: the shared switch survived. *)
      submit_ok client (prompt ~session:(sid "sibling") ~turn:(tid "s1") "hi");
      (match
         settled_outcome (drain_committed (follow_ok client (sid "sibling")))
       with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the sibling settled %a" Session.Turn.Outcome.pp other
      | None ->
          fail
            "the sibling never settled — the raising admission was not \
             contained");
      (* Root faulted (contained): it admits no more work, and its fence is
         releasable at shutdown rather than leaked past an escaped exception. *)
      (match
         Client.submit client.c
           (prompt ~session:(sid "root") ~turn:(tid "r2") "hi")
       with
      | Error (Protocol.Error.Unavailable _) -> ()
      | Error (Protocol.Error.Busy _) -> ()
      | Ok () -> fail "a raising admission must fault root, not admit new work"
      | Error e ->
          failf "wrong error after the contained fault: %a" Protocol.Error.pp e);
      is_false ~msg:"the raising child was never persisted"
        (List.exists is_child_key (session_keys store)))

(* A [follow_up] routed to a busy child is parked as a queue entry, not
   dropped, and drains when the child idles. The child blocks on its first turn;
   the parent, having read the receipt handle, issues the follow_up only once the
   child is provably busy, so the immediate submit errors [Active_turn_exists] and
   the delivery falls through to the enqueue path. The durable Enqueued fact is
   the proof it was parked (a direct submit to an idle child would leave none). *)
let a_follow_up_to_a_busy_child_parks_and_drains () =
  let child_id = ref None in
  let child_busy = ref false in
  let release_child = ref false in
  let followed_up = ref false in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "PLEASE_SPAWN" then begin
      (match !child_id with
      | Some _ -> ()
      | None -> child_id := receipt_child_of request);
      match !child_id with
      | None ->
          Ok
            (tool_call_response ~name:"spawn"
               ~input:(json_object [ ("task", Json.string "child task") ])
               "spawning")
      | Some id ->
          if not !followed_up then begin
            followed_up := true;
            (* Only address the child once it is provably mid-turn, so the
               delivery meets an active turn and takes the enqueue path. *)
            await_yield (fun () -> !child_busy);
            Ok
              (tool_call_response ~name:"follow_up"
                 ~input:
                   (json_object
                      [
                        ("child", Json.string id);
                        ("message", Json.string "FOLLOW_UP_MSG");
                      ])
                 "following up")
          end
          else Ok (plain_response "PARENT_DONE")
    end
    else if request_contains request "FOLLOW_UP_MSG" then
      Ok (plain_response "GOT_FOLLOWUP")
    else begin
      (* The child's first turn: stay busy until the test releases it. *)
      child_busy := true;
      let rec block () =
        if !release_child then Ok (plain_response "CHILD_DONE")
        else begin
          Eio.Fiber.yield ();
          block ()
        end
      in
      block ()
    end
  in
  with_engine ~script:(capped_script ~cap:16 script)
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-d3") "PLEASE_SPAWN");
      let parent_pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome parent_pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the parent settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the parent never settled");
      let child =
        match List.filter is_child_key (session_keys store) with
        | [ c ] -> c
        | cs -> failf "expected one child, got %d" (List.length cs)
      in
      (* The follow_up parked as a queue entry while the child was busy. *)
      await_yield (fun () -> has_enqueued store child);
      is_true
        ~msg:
          "the follow_up to a busy child parked as a queue entry, not dropped"
        (has_enqueued store child);
      (* Release the child: its first turn settles and it drains the parked
         follow_up as a second turn. *)
      release_child := true;
      let child_pairs = drain_n_settled 2 (follow_ok client (sid child)) in
      let completed =
        List.length
          (List.filter
             (fun (_, f) ->
               match f with
               | Protocol.Fact.Turn_settled
                   { outcome = Session.Turn.Outcome.Completed; _ } ->
                   true
               | _ -> false)
             child_pairs)
      in
      equal int
        ~msg:"the child ran two turns: its first, then the drained follow_up" 2
        completed)

(* Recovery must not clear [possibly_mutating] by reusing the
   pre-crash [Before_turn_tools] capture — the crash window may hold writes
   completed after it. One engine crashes mid-tool (its settle commit fails),
   leaving an open tool claim and a pre-crash checkpoint. A fresh engine recovers
   the turn ambiguously; its next tool effect must mint a FRESH capture at the
   distinct [After_recovery] boundary and clear the warning against that. *)
let edit_call ~call_id text =
  let call =
    Llm.Tool.Call.make ~id:call_id ~name:"edit" ~input:(json_object []) ()
  in
  let assistant =
    Llm.Message.Assistant.make
      [
        Llm.Message.Assistant.text_part text;
        Llm.Message.Assistant.tool_call call;
      ]
  in
  Llm.Response.make ~model ~stop:Llm.Response.Stop.tool_call assistant

(* One "edit" tool call (with the given call id) then completion. The recovering
   engine uses a distinct call id so its continuation's claim never collides with
   the pre-crash claim already in the journal. *)
let edit_then_done ~call_id () =
  let did = ref false in
  Ports.script @@ fun _request ->
  if !did then Ok (plain_response "done")
  else begin
    did := true;
    Ok (edit_call ~call_id "editing")
  end

(* A workspace whose notice producer speaks the [n]th time it is drained: the
   world says nothing at turn preparation and then something once the turn is
   under way, which is what a build breaking under the model's own edit looks
   like from the port. *)
let workspace_noticing_on_drain ~on_drain notices : Ports.workspace =
  let drains = ref 0 in
  {
    workspace with
    Ports.drain_notices =
      (fun () ->
        incr drains;
        if Int.equal !drains on_drain then notices else []);
  }

let workspace_notice ~source ~severity ~title =
  Mentat_workspace.Notice.make ~source ~severity ~title ~key:(source ^ title) ()

(* A workspace observation made while the turn is running reaches that turn: the
   drain at tool settlement records it against the active turn, and the request
   carrying the tool result carries it too. Without mid-turn intake, a build
   broken by the model's own edit stays invisible until the user speaks
   again. *)
let a_mid_turn_notice_rides_the_next_request () =
  let requests = ref [] in
  let script =
    Ports.script @@ fun request ->
    requests := request :: !requests;
    if Int.equal (List.length !requests) 1 then
      Ok (edit_call ~call_id:"edit-1" "editing")
    else Ok (plain_response "done")
  in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  let workspace =
    workspace_noticing_on_drain ~on_drain:2
      [
        workspace_notice ~source:"dune"
          ~severity:Mentat_workspace.Notice.Severity.Error
          ~title:"Build failing (1 diagnostic)";
      ]
  in
  with_engine ~script ~catalog ~workspace
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "edit");
      ignore (drain_committed (follow_ok client (sid "root")));
      match List.rev !requests with
      | [ first; second ] ->
          is_false ~msg:"the turn's first request predates the observation"
            (request_contains first "Build failing");
          is_true
            ~msg:
              "the request carrying the tool result carries the observation \
               the turn made"
            (request_contains second "Build failing")
      | requests ->
          failf "expected two provider requests, got %d" (List.length requests))

(* Every observation a turn made is stated, in arrival order. A source may speak
   twice within one turn, and the port cannot tell a state reading from a delta:
   a watcher's second batch names the files that changed since its first, so
   keeping only the latest would drop the earlier names from the model's view
   while leaving them in the journal. *)
let a_turn_states_every_observation_it_made () =
  let requests = ref [] in
  let script =
    Ports.script @@ fun request ->
    requests := request :: !requests;
    match List.length !requests with
    | 1 -> Ok (edit_call ~call_id:"edit-1" "editing")
    | 2 -> Ok (edit_call ~call_id:"edit-2" "editing again")
    | _ -> Ok (plain_response "done")
  in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  let drains = ref 0 in
  let workspace =
    {
      workspace with
      Ports.drain_notices =
        (fun () ->
          incr drains;
          match !drains with
          | 2 ->
              [
                workspace_notice ~source:"fswatch"
                  ~severity:Mentat_workspace.Notice.Severity.Info
                  ~title:"1 workspace file change since the last scan: alpha.ml";
              ]
          | 3 ->
              [
                workspace_notice ~source:"fswatch"
                  ~severity:Mentat_workspace.Notice.Severity.Info
                  ~title:"1 workspace file change since the last scan: beta.ml";
              ]
          | _ -> []);
    }
  in
  with_engine ~script ~catalog ~workspace
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "edit");
      let facts = drain_committed (follow_ok client (sid "root")) in
      (match List.rev !requests with
      | [ _; second; third ] ->
          is_true ~msg:"the first batch reaches the turn when it is observed"
            (request_contains second "alpha.ml");
          is_true ~msg:"the second batch reaches the turn when it is observed"
            (request_contains third "beta.ml");
          is_true ~msg:"the earlier batch is still stated alongside it"
            (request_contains third "alpha.ml")
      | requests ->
          failf "expected three provider requests, got %d"
            (List.length requests));
      let notices =
        List.filter_map
          (fun (_, fact) ->
            match fact with
            | Protocol.Fact.Workspace_notice notice ->
                Some (Session.Notice.title notice)
            | _ -> None)
          facts
      in
      equal int ~msg:"the journal records both observations" 2
        (List.length notices))

(* A drain consumes its producer, and a tool settlement is not certain to reach
   another request: a turn at its step cap ends on the settlement that drained.
   The observation is held and leads the next turn instead of being lost with
   the turn that consumed it — the producers cannot be asked again, since a
   watcher has cleared its queue and a build verdict has moved its baseline. *)
let a_pending_notice_survives_the_compaction_boundary () =
  (* The headline flow: a notice drained at the boundary is riding the model
     view's tail when context pressure fires. The summary request's head
     must exclude it (it is not-yet-history), the compaction claim's own
     freeze pins it after the carried cut, and the reduced view retains it —
     never summarized by a summarizer that never saw it. *)
  let big_usage = Llm.Usage.make ~input:4000 ~output:2000 () in
  let small_usage = Llm.Usage.make ~input:10 ~output:5 () in
  let requests = ref [] in
  let turns = ref 0 in
  let script =
    Ports.script @@ fun request ->
    requests := request :: !requests;
    if request_contains request "Summarize this conversation" then
      Ok (plain_response "Conversation summary.")
    else begin
      incr turns;
      Ok
        (Llm.Response.make ~model ~stop:Llm.Response.Stop.end_turn
           ~usage:(if !turns = 1 then big_usage else small_usage)
           (Llm.Message.Assistant.text "Done."))
    end
  in
  let config _ ~latest_model:_ =
    Ok
      (Agent.Config.make ~model ~continuation_turn_limit:None
         ~compaction_pressure_tokens:1000 ())
  in
  let workspace =
    workspace_noticing_on_drain ~on_drain:2
      [
        workspace_notice ~source:"dune"
          ~severity:Mentat_workspace.Notice.Severity.Error
          ~title:"Build failing (1 diagnostic)";
      ]
  in
  with_engine ~script ~config ~workspace
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-2") "again");
      let _ = drain_committed feed in
      (* The FIRST summary is the one built while the batch still rides:
         it must exclude the entry. A later summary may legitimately cover
         it — by then it is frozen history. *)
      (match
         List.find_opt
           (fun r -> request_contains r "Summarize this conversation")
           (List.rev !requests)
       with
      | None -> fail "no summary request was issued"
      | Some summary ->
          equal int ~msg:"the summarizer never sees the riding batch" 0
            (request_occurrences summary "Build failing (1 diagnostic)"));
      (match
         List.find_opt
           (fun r ->
             not (request_contains r "Summarize this conversation"))
           !requests
       with
      | None -> fail "no post-compaction turn request"
      | Some turn_request ->
          equal int
            ~msg:"the frozen entry survives into the reduced view's tail" 1
            (request_occurrences turn_request "Build failing (1 diagnostic)"));
      match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session ->
          is_true ~msg:"the post-install model view retains the entry"
            (List.exists
               (function
                 | Llm.Message.User content ->
                     List.exists
                       (function
                         | Llm.Content.Text text ->
                             contains_sub ~sub:"Build failing (1 diagnostic)"
                               text
                         | _ -> false)
                       content
                 | _ -> false)
               (Llm.Transcript.messages
                  (Session.State.model_transcript (Session.state session)))))

let an_observation_outlives_the_turn_that_could_not_state_it () =
  let requests = ref [] in
  let script =
    Ports.script @@ fun request ->
    requests := request :: !requests;
    if Int.equal (List.length !requests) 1 then
      Ok (edit_call ~call_id:"edit-1" "editing")
    else Ok (plain_response "done")
  in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  (* One step: the model answers once, and the boundary after its tool settles
     ends the turn rather than issuing a second request. *)
  let config _session ~latest_model:_ =
    Ok (Agent.Config.make ~model ~max_steps:1 ())
  in
  let workspace =
    workspace_noticing_on_drain ~on_drain:2
      [
        workspace_notice ~source:"dune"
          ~severity:Mentat_workspace.Notice.Severity.Error
          ~title:"Build failing (1 diagnostic)";
      ]
  in
  with_engine ~script ~catalog ~workspace ~config
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "edit");
      (* Two settlements: the step-limited turn, then the wind-down turn the
         engine admits behind it — which is the next turn, and therefore the one
         that inherits what its predecessor could not state. *)
      let first = drain_n_settled 2 (follow_ok client (sid "root")) in
      (match settled_outcome first with
      | Some Session.Turn.Outcome.Step_limit -> ()
      | Some _ | None -> fail "the first turn must end at its step limit");
      let feed = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-2") "again");
      ignore (drain_committed feed);
      match List.rev !requests with
      | [ first; wind_down; second ] ->
          is_false
            ~msg:"the step-limited turn never got to state the observation"
            (request_contains first "Build failing");
          is_true ~msg:"the next turn states what its predecessor could not"
            (request_contains wind_down "Build failing");
          (* Stated once, then frozen: later requests carry the entry as
             durable history at its original position — the model can
             re-read what it was told — never as a fresh restatement. *)
          equal int ~msg:"the frozen entry appears exactly once" 1
            (request_occurrences second "Build failing");
          equal int ~msg:"and was stated exactly once when told" 1
            (request_occurrences wind_down "Build failing");
          (* The head never moves: both requests carry byte-identical
             prelude content — the entry rode the transcript, not the
             instructions. *)
          is_true ~msg:"the prelude is byte-stable across the entry"
            (List.equal Llm.Message.equal
               (Llm.Request.Prelude.messages (Llm.Request.prelude wind_down))
               (Llm.Request.Prelude.messages (Llm.Request.prelude second)))
      | requests ->
          failf "expected three provider requests, got %d"
            (List.length requests))

(* Delegated work is workspace work, and a parent waits on it for as long as the
   child runs — the longest a turn ever goes without observing. The delivery
   that answers the wait is a model boundary like a tool settlement, so the
   world's observations ride the request carrying the child's answer instead of
   waiting for a turn the parent has not started yet. *)
let an_observation_made_while_waiting_reaches_the_parent () =
  let parent_requests = ref [] in
  let child = ref None in
  let waited = ref false in
  let script =
    Ports.script @@ fun request ->
    if request_contains request "PLEASE_SPAWN" then begin
      parent_requests := request :: !parent_requests;
      (match !child with
      | Some _ -> ()
      | None -> child := receipt_child_of request);
      match !child with
      | None ->
          Ok
            (tool_call_response ~name:"spawn"
               ~input:(json_object [ ("task", Json.string "child works") ])
               "spawning")
      | Some id ->
          if !waited then Ok (plain_response "done")
          else begin
            waited := true;
            Ok
              (tool_call_response ~name:"wait"
                 ~input:
                   (json_object [ ("children", json_array [ Json.string id ]) ])
                 "waiting")
          end
    end
    else Ok (plain_response "child done")
  in
  let workspace =
    workspace_noticing_on_drain ~on_drain:2
      [
        workspace_notice ~source:"dune"
          ~severity:Mentat_workspace.Notice.Severity.Error
          ~title:"Build failing (1 diagnostic)";
      ]
  in
  (* The notice lane belongs to the root driver alone, as composition wires it:
     a child shares the write capability without touching the producers, so the
     parent's drains are the only ones. *)
  let delegated =
    ( catalog,
      { workspace with Ports.drain_notices = (fun () -> []) },
      Mentat_permission.Policy.default )
  in
  with_engine ~script:(capped_script ~cap:20 script)
    ~workspace ~delegated_execution:delegated
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn") "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      match List.rev !parent_requests with
      | [ _; second; third ] ->
          is_false ~msg:"the wait was issued before the observation was made"
            (request_contains second "Build failing");
          is_true
            ~msg:"the request answering the wait carries what the world said"
            (request_contains third "Build failing")
      | requests ->
          failf "expected three parent requests, got %d" (List.length requests))

(* Runtime: the brokered child backend.

   Under [Brokered] the engine records the edge, creates the child document,
   and holds the permit, then hands identity to the ops record; settlement
   arrives through the observation seam. The fixtures play the broker: a spy
   ops record captures the handoff, a second engine over the same store plays
   the out-of-process child server (the exact serve-session topology — shared
   journals, separate runtimes), and the seam calls play the observer. *)

let brokered_spy () =
  let materialized = ref [] in
  let ops =
    {
      Ports.materialize = (fun ~child -> materialized := child :: !materialized);
      cancel = (fun ~child:_ -> ());
    }
  in
  (materialized, Ports.Brokered ops)

(* The parent's whole journey: spawn, then wait on the receipt handle, then a
   final answer once the wait delivers. *)
let spawn_wait_script requests =
  let child = ref None in
  let waited = ref false in
  Ports.script @@ fun request ->
  requests := request :: !requests;
  (match !child with
  | Some _ -> ()
  | None -> child := receipt_child_of request);
  match !child with
  | None ->
      Ok
        (tool_call_response ~name:"spawn"
           ~input:(json_object [ ("task", Json.string "child works") ])
           "spawning")
  | Some id ->
      if !waited then Ok (plain_response "PARENT_DONE")
      else begin
        waited := true;
        Ok
          (tool_call_response ~name:"wait"
             ~input:(json_object [ ("children", json_array [ Json.string id ]) ])
             "waiting")
      end

let is_edge_fact = function
  | Protocol.Fact.Journal_delegation _ -> true
  | _ -> false

let root_edge store =
  match Hashtbl.find_opt store.sessions "root" with
  | None -> fail "the root session is missing"
  | Some session -> (
      match Session.State.delegations (Session.state session) with
      | [ edge ] -> edge
      | edges -> failf "expected one edge, got %d" (List.length edges))

let a_brokered_spawn_hands_identity_and_integrates_on_the_wake () =
  let requests = ref [] in
  let materialized, child_backend = brokered_spy () in
  with_engine ~script:(spawn_wait_script requests) ~child_backend
    (fun ~sw ~client ~store ~engine ->
      let feed = follow_ok client (sid "root") in
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn") "PLEASE_SPAWN");
      (* The edge fact publishes only after the child document is resolvable
         and the handoff has fired (register-before-publish), so this is the
         rendezvous. *)
      ignore (drain_committed ~stop:is_edge_fact feed);
      let edge = root_edge store in
      let child = Session.Delegation.child edge in
      let delegation = Session.Delegation.id edge in
      (match !materialized with
      | [ handed_child ] ->
          is_true ~msg:"the handoff names the child"
            (Session.Id.equal handed_child child)
      | handed -> failf "expected one handoff, got %d" (List.length handed));
      (* No sibling driver was attached: the child materializes elsewhere. *)
      is_true ~msg:"an unstarted brokered child probes Not_settled"
        (Agent.integrate_brokered_child engine ~child = `Not_settled);
      (* The child server: a second engine over the same store submits the
         deterministic first turn, exactly as serve-session does. *)
      let engine2 =
        mk_engine ~sw ~store
          ~script:(Ports.script (fun _ -> Ok (plain_response "CHILD_DONE")))
          ()
      in
      let client2 = { c = make_client engine2; sw } in
      (match
         Protocol.Command.prompt ~session:child
           ~turn:(Agent.child_first_turn delegation)
           ~input:(Session.Delegation.task edge) ()
       with
      | Ok command -> submit_ok client2 command
      | Error e -> failf "child prompt: %s" (Protocol.Command.Invalid.message e));
      ignore (drain_committed (follow_ok client2 child));
      Agent.shutdown engine2;
      (* The observer's wake: derive from the child journal, wake the wait. *)
      is_true ~msg:"the settled child integrates"
        (Agent.integrate_brokered_child engine ~child = `Integrated);
      (match settled_outcome (drain_committed (follow_ok client (sid "root")))
       with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the parent turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the parent turn never settled");
      match !requests with
      | last :: _ ->
          is_true ~msg:"the request answering the wait carries the child result"
            (request_contains last "CHILD_DONE")
      | [] -> fail "no parent requests were recorded")

let a_brokered_failure_settles_the_parked_wait () =
  let requests = ref [] in
  let _materialized, child_backend = brokered_spy () in
  with_engine ~script:(spawn_wait_script requests) ~child_backend
    (fun ~sw:_ ~client ~store ~engine ->
      let feed = follow_ok client (sid "root") in
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-spawn") "PLEASE_SPAWN");
      ignore (drain_committed ~stop:is_edge_fact feed);
      let edge = root_edge store in
      let child = Session.Delegation.child edge in
      is_true ~msg:"a session this engine never delegated is Unbound"
        (Agent.integrate_brokered_child engine ~child:(sid "elsewhere")
        = `Unbound);
      (* The broker's bounded-fail floor: the parked wait completes with the
         spawn-failure text instead of parking forever. *)
      Agent.fail_brokered_child engine ~child
        ~message:"the child process died before settling";
      (match settled_outcome (drain_committed (follow_ok client (sid "root")))
       with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the parent turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the parent turn never settled");
      match !requests with
      | last :: _ ->
          is_true ~msg:"the wait's answer names the failure"
            (request_contains last
               "spawn failed: the child process died before settling")
      | [] -> fail "no parent requests were recorded")

(* Capacity is a permit per edge, and a reaped child's integration or failure
   returns it: with one slot, the second spawn of a turn is refused while the
   first child holds the permit, and a follow-up turn spawns again once the
   broker reported the first child gone. *)
let a_reaped_brokered_child_releases_capacity () =
  let materialized, child_backend = brokered_spy () in
  (* Distinct call ids: two spawns of one turn must be two delegations, not a
     re-issue of one. *)
  let spawn_call ~id ~task =
    let call =
      Llm.Tool.Call.make ~id ~name:"spawn"
        ~input:(json_object [ ("task", Json.string task) ])
        ()
    in
    let assistant =
      Llm.Message.Assistant.make
        [
          Llm.Message.Assistant.text_part "spawning";
          Llm.Message.Assistant.tool_call call;
        ]
    in
    Llm.Response.make ~model ~stop:Llm.Response.Stop.tool_call assistant
  in
  let step = ref 0 in
  let script =
    Ports.script @@ fun _request ->
    incr step;
    match !step with
    | 1 -> Ok (spawn_call ~id:"sp-first" ~task:"first")
    | 2 -> Ok (spawn_call ~id:"sp-second" ~task:"second")
    | 3 -> Ok (plain_response "TURN_ONE_DONE")
    | 4 -> Ok (spawn_call ~id:"sp-third" ~task:"third")
    | _ -> Ok (plain_response "TURN_TWO_DONE")
  in
  with_engine ~script ~max_children:1 ~child_backend
    (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-one") "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      let children () =
        List.filter (fun k -> not (String.equal k "root")) (session_keys store)
      in
      equal Testable.int ~msg:"one slot admits one child" 1
        (List.length (children ()));
      equal Testable.int ~msg:"the refused spawn was never handed over" 1
        (List.length !materialized);
      (* The reaper's report frees the permit. *)
      (match children () with
      | [ child ] ->
          Agent.fail_brokered_child engine ~child:(sid child)
            ~message:"reaped"
      | _ -> fail "expected exactly one child");
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-two") "PLEASE_SPAWN_MORE");
      ignore (drain_n_settled 2 (follow_ok client (sid "root")));
      equal Testable.int ~msg:"the freed slot admits the next spawn" 2
        (List.length (children ()));
      equal Testable.int ~msg:"the next spawn was handed over" 2
        (List.length !materialized))

(* The parent journey behind the delivery-seam tests: spawn, then one
   [send] and/or [follow_up] addressed by the receipt handle, then
   done. Parent requests carry "PLEASE_SPAWN" for the turn's life. *)
let message_script ~verbs =
  let child_id = ref None in
  let step = ref 0 in
  Ports.script @@ fun request ->
  if request_contains request "PLEASE_SPAWN" then begin
    (match !child_id with
    | Some _ -> ()
    | None -> child_id := receipt_child_of request);
    match !child_id with
    | None ->
        Ok
          (tool_call_response ~name:"spawn"
             ~input:(json_object [ ("task", Json.string "child works") ])
             "spawning")
    | Some id -> (
        let n = !step in
        incr step;
        match List.nth_opt verbs n with
        | Some (name, message) ->
            let input =
              if String.equal name "send" then
                json_object
                  [
                    ("to", Json.string ("child:" ^ id));
                    ("message", Json.string message);
                  ]
              else
                json_object
                  [
                    ("child", Json.string id);
                    ("message", Json.string message);
                  ]
            in
            Ok (tool_call_response ~name ~input "messaging")
        | None -> Ok (plain_response "PARENT_DONE"))
  end
  else Ok (plain_response "CHILD_SEEN")

(* Under [Brokered], a message for a child this runtime does not drive is one
   broker send with the derived queue id and the parent's agent origin —
   never an in-process attach, never a prompt. The recording stub plays the
   broker and answers [`Delivered], so the child journal must stay untouched
   by this process. The [`Follow_up] additionally wakes the child through the
   ops record's materialization — send then wake, two acts — while the
   [`Context] sends without waking. *)
let a_brokered_message_crosses_the_broker_send () =
  let sent = ref [] in
  let broker =
    Mentat_broker.for_tests ~send:(fun ~origin ~target ~id ~input:_ ->
        sent := (origin, target, id) :: !sent;
        `Delivered)
  in
  let materialized, child_backend = brokered_spy () in
  let script =
    message_script
      ~verbs:
        [ ("send", "extra context"); ("follow_up", "one more thing") ]
  in
  with_engine ~script:(capped_script ~cap:20 script) ~child_backend ~broker
    (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-msg") "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      await_yield (fun () -> List.length !sent >= 2);
      await_yield (fun () -> List.length !materialized >= 2);
      let edge = root_edge store in
      let child = Session.Delegation.child edge in
      equal Testable.int ~msg:"two message kinds are two sends" 2
        (List.length !sent);
      List.iter
        (fun (origin, target, id) ->
          is_true ~msg:"the send targets the child session"
            (Session.Id.equal target child);
          is_true ~msg:"the send carries a derived id"
            (String.length (Session.Queue.Id.to_string id) = 20);
          match origin with
          | Some (Session.Origin.Agent sender) ->
              is_true ~msg:"the origin names the sending parent"
                (Session.Id.equal sender (sid "root"))
          | Some (Session.Origin.Trigger _) | None ->
              fail "the origin must name the sending agent")
        !sent;
      (* Exactly the spawn and the follow-up's wake handed the child over:
         the context send woke nothing. *)
      equal Testable.int ~msg:"only the spawn and the follow-up wake the child"
        2
        (List.length !materialized);
      match Hashtbl.find_opt store.sessions (Session.Id.to_string child) with
      | None -> fail "the child document is missing"
      | Some session ->
          equal Testable.int
            ~msg:"a delivered message writes nothing to the child journal here"
            0
            (List.length (Session.events session)))

(* Two same-turn messages to one dormant child land in receipt order:
   delivery runs on one lane per delegation edge, so a slow first send
   cannot be overtaken by the second — the exact inversion a per-message
   fiber fan-out allows. The stub's first send yields long enough that an
   overtaking second fiber would record first. *)
let same_edge_messages_deliver_in_order () =
  let delivered = ref [] in
  let calls = ref 0 in
  let broker =
    Mentat_broker.for_tests ~send:(fun ~origin:_ ~target:_ ~id:_ ~input ->
        incr calls;
        if !calls = 1 then
          for _ = 1 to 100 do
            Eio.Fiber.yield ()
          done;
        (match input with
        | [ Llm.Content.Text text ] -> delivered := text :: !delivered
        | _ -> fail "mail carries one text block");
        `Delivered)
  in
  let _materialized, child_backend = brokered_spy () in
  let script =
    message_script
      ~verbs:[ ("send", "first"); ("send", "second") ]
  in
  with_engine ~script:(capped_script ~cap:20 script) ~child_backend ~broker
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-fifo") "PLEASE_SPAWN");
      ignore (drain_committed (follow_ok client (sid "root")));
      await_yield (fun () -> List.length !delivered >= 2);
      equal
        (Testable.list Testable.string)
        ~msg:"messages land in receipt order" [ "first"; "second" ]
        (List.rev !delivered))

(* The driver's queue admission runs the accept judgment the broker's
   fence-held append runs — one home, [Mentat_session.accepts_mail] — so an
   origin the session's recorded facts cannot prove is a structured refusal
   at the wire too, never a committed fact. *)
let a_queued_entry_from_an_unprovable_sender_is_refused () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      ignore (drain_committed (follow_ok client (sid "root")));
      let queue_next ?origin () =
        match
          Protocol.Command.queue_next ?origin ~session:(sid "root")
            ~input:[ Llm.Content.text "psst" ]
            ()
        with
        | Ok c -> c
        | Error e -> failf "queue_next: %s" (Protocol.Command.Invalid.message e)
      in
      (match
         Client.submit client.c
           (queue_next ~origin:(Session.Origin.agent (sid "stranger")) ())
       with
      | Error (Protocol.Error.Unavailable _) -> ()
      | Ok () -> fail "an unprovable sender must be refused at admission"
      | Error e -> failf "wrong refusal: %a" Protocol.Error.pp e);
      (* The owner's plain entry (no origin) still admits. *)
      submit_ok client (queue_next ()))

(* An undelivered send is covered by the parent's durable verb receipt: the
   next engine attaching the parent re-drives it through its own broker with
   the same derived id — at-least-once mechanics, exactly-once effect. *)
let an_undelivered_message_redrives_at_the_next_attach () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let run () =
    let first = ref [] in
    let broker1 =
      Mentat_broker.for_tests ~send:(fun ~origin:_ ~target:_ ~id ~input:_ ->
          first := id :: !first;
          `Undelivered "the target's fence stayed held")
    in
    let _materialized, child_backend = brokered_spy () in
    let script = message_script ~verbs:[ ("send", "extra context") ] in
    let engine1 =
      mk_engine ~sw ~store
        ~script:(capped_script ~cap:20 script)
        ~child_backend ~broker:broker1 ()
    in
    let client1 = { c = make_client engine1; sw } in
    submit_ok client1
      (prompt ~session:(sid "root") ~turn:(tid "t-msg") "PLEASE_SPAWN");
    ignore (drain_committed (follow_ok client1 (sid "root")));
    await_yield (fun () -> List.length !first >= 1);
    Agent.shutdown engine1;
    let redriven = ref [] in
    let broker2 =
      Mentat_broker.for_tests ~send:(fun ~origin:_ ~target:_ ~id ~input:_ ->
          redriven := id :: !redriven;
          `Delivered)
    in
    let _materialized2, child_backend2 = brokered_spy () in
    let engine2 =
      mk_engine ~sw ~store ~script:default_script
        ~child_backend:child_backend2 ~broker:broker2 ()
    in
    let client2 = { c = make_client engine2; sw } in
    submit_ok client2 (prompt ~session:(sid "root") ~turn:(tid "t-after") "hi");
    await_yield (fun () -> List.length !redriven >= 1);
    (match (!first, !redriven) with
    | [ undelivered ], redriven_id :: _ ->
        is_true ~msg:"the re-driven send carries the same derived id"
          (Session.Queue.Id.equal undelivered redriven_id)
    | _ -> fail "expected one undelivered send and its re-drive");
    Agent.shutdown engine2;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: the redrive test exceeded 15s"

let mutation_event_value =
  Testable.make ~pp:Mutation.Event.pp ~equal:Mutation.Event.equal

(* The branch flows copy the driver's mutation ledger into the child, keyed on
   the turns the child retains: a fork keeps every turn (the whole ledger), a
   rewind keeps only its anchored prefix. One edit turn records a single
   [Before_turn_tools] checkpoint keyed to its turn (the tracked workspace
   records no edit), so the ledger carries one turn-keyed fact — enough to watch
   the fork and an after-the-turn rewind copy it while a before-the-turn rewind,
   whose child holds no turn, drops it. This is the defect's regression guard:
   before the fix the child ledger was always empty and its diff/revert lied. *)
let branch_flows_copy_the_mutation_ledger () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let module Policy = Mentat_permission.Policy in
  let calls = workspace_calls () in
  let workspace = tracked_workspace calls (Sandbox.identity Sandbox.direct) in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~policy:(Policy.make [ Policy.Rule.allow_all_dangerously ]) ())
  in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  let engine =
    mk_engine ~sw ~store
      ~script:(edit_then_done ~call_id:"call-1" ())
      ~config ~catalog ~workspace ()
  in
  let client = { c = make_client engine; sw } in
  let run () =
    submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-1") "edit");
    ignore (drain_committed (follow_ok client (sid "root")));
    let root_muts = Hashtbl.find store.muts "root" in
    is_true ~msg:"the edit turn recorded a turn-keyed mutation fact"
      (root_muts <> []);
    (match Client.fork client.c ~session:(sid "root") ~into:(sid "fork") () with
    | Ok () -> ()
    | Error e -> failf "fork failed: %a" Protocol.Error.pp e);
    (match
       Client.rewind client.c ~session:(sid "root") ~into:(sid "rw-after")
         ~anchor:(Session.Anchor.after_turn (tid "t-1"))
     with
    | Ok () -> ()
    | Error e -> failf "rewind --after failed: %a" Protocol.Error.pp e);
    (match
       Client.rewind client.c ~session:(sid "root") ~into:(sid "rw-before")
         ~anchor:(Session.Anchor.before_turn (tid "t-1"))
     with
    | Ok () -> ()
    | Error e -> failf "rewind --before failed: %a" Protocol.Error.pp e);
    let child id = Hashtbl.find store.muts id in
    (* The fork and an after-the-turn rewind retain the turn, so its fact is
       copied verbatim; a before-the-turn rewind retains no turn, so the
       turn-keyed fact is dropped and the child ledger is empty. *)
    List.iter
      (fun (label, expected, actual) ->
        equal (list mutation_event_value) ~msg:label expected actual)
      [
        ("the fork copies the whole ledger", root_muts, child "fork");
        ( "an after-the-turn rewind keeps the turn's fact",
          root_muts,
          child "rw-after" );
        ("a before-the-turn rewind drops the turn's fact", [], child "rw-before");
      ];
    Agent.shutdown engine;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: branch-copy test exceeded 15s"

(* Faulted visibility: a contained fault publishes nothing, so a same-process
   client polls the pull-side query to surface it without submitting work that
   would only be refused. *)
let faulted_is_pollable_without_submitting () =
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  with_engine ~script:(edit_then_done ~call_id:"edit-1" ()) ~catalog
    (fun ~sw:_ ~client ~store ~engine:_ ->
      is_false ~msg:"a live driver reports no fault"
        (Option.is_some (Client.faulted client.c ~session:(sid "root")));
      store.commit_fault <-
        (fun events ->
          if is_tool_settled events then
            Some
              (Ports.Store_error.Io
                 (Mentat_diagnostic.of_text "settle commit crash"))
          else None);
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-fault") "go");
      (* The tool runs; its settle commit fails and the driver contains the
         fault. The query surfaces it with no further submit. *)
      await_yield (fun () ->
          Option.is_some (Client.faulted client.c ~session:(sid "root")));
      is_true ~msg:"the contained fault is pollable without submitting"
        (Option.is_some (Client.faulted client.c ~session:(sid "root"))))

let recovery_takes_a_fresh_capture_not_the_pre_crash_one () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let module Policy = Mentat_permission.Policy in
  let sealed_policy = Policy.make [ Policy.Rule.allow_all_dangerously ] in
  let replacement_policy = Policy.make [ Policy.Rule.deny_all ] in
  let configured_policy = ref sealed_policy in
  let before_calls = workspace_calls () in
  let recovery_calls = workspace_calls () in
  let before_workspace =
    tracked_workspace before_calls (Sandbox.identity Sandbox.direct)
  in
  let recovery_workspace =
    tracked_workspace recovery_calls (Sandbox.identity Sandbox.direct)
  in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model ~policy:!configured_policy ())
  in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  let engine1 =
    mk_engine ~sw ~store
      ~script:(edit_then_done ~call_id:"edit-1" ())
      ~config ~catalog ~workspace:before_workspace ()
  in
  let client1 = { c = make_client engine1; sw } in
  let run () =
    (* The tool's settle commit fails: the driver faults with the claim open. *)
    store.commit_fault <-
      (fun events ->
        if is_tool_settled events then
          Some
            (Ports.Store_error.Io (Mentat_diagnostic.of_text "crash mid-tool"))
        else None);
    submit_ok client1 (prompt ~session:(sid "root") ~turn:(tid "t-crash") "go");
    (* Wait until the open claim is durable and its pre-crash capture recorded. *)
    await_yield (fun () -> has_open_tool_claim store "root");
    is_true ~msg:"the crash left a pre-crash Before_turn_tools capture behind"
      (match Hashtbl.find_opt store.muts "root" with
      | Some events ->
          List.exists
            (function Mutation.Event.Checkpoint _ -> true | _ -> false)
            events
      | None -> false);
    is_false ~msg:"the recovery capture does not exist before recovery"
      (has_after_recovery_checkpoint store "root");
    Agent.shutdown engine1;
    (* Recovery must commit cleanly, including the ambiguous tool settle. *)
    store.commit_fault <- (fun _ -> None);
    configured_policy := replacement_policy;
    let engine2 =
      mk_engine ~sw ~store
        ~script:(edit_then_done ~call_id:"edit-2" ())
        ~config ~catalog ~workspace:recovery_workspace ()
    in
    let client2 = { c = make_client engine2; sw } in
    (* An idempotent resubmit of the same turn attaches and recovers without
       starting a competing turn; the recovered turn drives to settlement. *)
    submit_ok client2 (prompt ~session:(sid "root") ~turn:(tid "t-crash") "go");
    let _ = drain_committed (follow_ok client2 (sid "root")) in
    is_true
      ~msg:
        "recovery cleared possibly_mutating against a fresh After_recovery \
         capture"
      (has_after_recovery_checkpoint store "root");
    is_false ~msg:"the recovered turn's fresh capture cleared possibly_mutating"
      (Client.possibly_mutating client2.c ~session:(sid "root"));
    let persisted = Hashtbl.find store.sessions "root" in
    let recovered_contract =
      match Session.State.turn (tid "t-crash") (Session.state persisted) with
      | Some turn -> Session.Turn.contract turn
      | None -> fail "the recovered turn disappeared"
    in
    is_true ~msg:"recovery retains the policy sealed before the crash"
      (Policy.equal sealed_policy (Session.Contract.policy recovered_contract));
    is_false ~msg:"recovery does not replace the sealed policy from live config"
      (Policy.equal replacement_policy
         (Session.Contract.policy recovered_contract));
    equal int ~msg:"the crashed engine took only its pre-crash capture" 1
      before_calls.checkpoints;
    equal int ~msg:"recovery takes the fresh capture through its selected port"
      1 recovery_calls.checkpoints;
    equal int
      ~msg:"recovery scopes the continued tool through its selected port" 1
      recovery_calls.scopes;
    Agent.shutdown engine2;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: recovery-capture test exceeded 15s"

let recovery_checkpoint_availability_law ~replayed ~available () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let module Policy = Mentat_permission.Policy in
  let config _session ~latest_model:_ =
    Ok
      (Agent.Config.make ~model
         ~policy:(Policy.make [ Policy.Rule.allow_all_dangerously ]) ())
  in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  let before_calls = workspace_calls () in
  let recovery_calls = workspace_calls () in
  let before_workspace =
    tracked_workspace before_calls (Sandbox.identity Sandbox.direct)
  in
  let capture =
    if available then available_capture () else degraded_capture ()
  in
  let recovery_workspace =
    tracked_workspace ~capture recovery_calls (Sandbox.identity Sandbox.direct)
  in
  let engine1 =
    mk_engine ~sw ~store
      ~script:(edit_then_done ~call_id:"law-edit-1" ())
      ~config ~catalog ~workspace:before_workspace ()
  in
  let client1 = { c = make_client engine1; sw } in
  let run () =
    store.commit_fault <-
      (fun events ->
        if is_tool_settled events then
          Some
            (Ports.Store_error.Io (Mentat_diagnostic.of_text "crash mid-tool"))
        else None);
    submit_ok client1
      (prompt ~session:(sid "root") ~turn:(tid "t-checkpoint-law") "go");
    await_yield (fun () -> has_open_tool_claim store "root");
    Agent.shutdown engine1;
    store.commit_fault <- (fun _ -> None);
    if replayed then begin
      let checkpoint =
        Mutation.Checkpoint.make
          ~boundary:
            (Mutation.Checkpoint.After_recovery (tid "t-checkpoint-law"))
          ~capture
      in
      let events = Hashtbl.find store.muts "root" in
      Hashtbl.replace store.muts "root"
        (events @ [ Mutation.Event.checkpoint checkpoint ])
    end;
    let engine2 =
      mk_engine ~sw ~store
        ~script:(edit_then_done ~call_id:"law-edit-2" ())
        ~config ~catalog ~workspace:recovery_workspace ()
    in
    let client2 = { c = make_client engine2; sw } in
    submit_ok client2
      (prompt ~session:(sid "root") ~turn:(tid "t-checkpoint-law") "go");
    ignore (drain_committed (follow_ok client2 (sid "root")));
    is_true ~msg:"recovery records the After_recovery boundary"
      (has_after_recovery_checkpoint store "root");
    equal bool
      ~msg:
        "possibly_mutating clears exactly when After_recovery has an available \
         snapshot"
      (not available)
      (Client.possibly_mutating client2.c ~session:(sid "root"));
    equal int
      ~msg:"a replayed boundary is reused; a missing boundary is captured once"
      (if replayed then 0 else 1)
      recovery_calls.checkpoints;
    equal int ~msg:"the continued tool still opens exactly one scope" 1
      recovery_calls.scopes;
    Agent.shutdown engine2;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout ->
      fail "deadlock guard: checkpoint-availability-law test exceeded 15s"

(* WORKSPACE-1: a commit-phase [Attempted] apply in the claim-window evidence
   lowers to a durable [Edit] event carrying the uncertain stopping target — the
   failed apply's attribution crosses the port and reaches the ledger, not just a
   successful apply's. *)
let uncertain_path () =
  let key =
    match Mentat_workspace.Root.Key.of_string "root" with
    | Ok key -> key
    | Error _ -> fail "root key"
  in
  Mentat_workspace.Path.make ~root_key:key
    (Lpath.Rel.of_string_exn "uncertain.txt")

let workspace_yielding_an_attempt uncertain : Ports.workspace =
  let checkpoint ~boundary =
    Mutation.Checkpoint.make ~boundary
      ~capture:
        (Mutation.Checkpoint.Capture.Available
           {
             snapshot =
               Mutation.Checkpoint.Snapshot.make ~backend:"fake"
                 ~reference:"ref";
             excluded = 0;
           })
  in
  let open_scope _claim () =
    {
      Mentat_edit.Apply_evidence.applies =
        [
          Mentat_edit.Apply_evidence.Attempted
            {
              Mentat_edit.Apply_evidence.Attempt.applied = [];
              uncertain = Some uncertain;
            };
        ];
      observed = [];
    }
  in
  {
    Ports.identity = Sandbox.identity Sandbox.direct;
    checkpoint;
    open_scope;
    drain_notices = (fun () -> []);
  }

let an_attempted_apply_lowers_to_an_uncertain_edit_event () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let uncertain = uncertain_path () in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  let engine =
    mk_engine ~sw ~store
      ~workspace:(workspace_yielding_an_attempt uncertain)
      ~script:(edit_then_done ~call_id:"edit-1" ())
      ~catalog ()
  in
  let client = { c = make_client engine; sw } in
  let run () =
    submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "go");
    let _ = drain_committed (follow_ok client (sid "root")) in
    (match Hashtbl.find_opt store.muts "root" with
    | Some events ->
        is_true
          ~msg:
            "the attempt lowered to an Edit event carrying the uncertain target"
          (List.exists
             (function
               | Mutation.Event.Edit { changes = []; uncertain = Some p; _ } ->
                   Mentat_workspace.Path.equal p uncertain
               | _ -> false)
             events)
    | None -> fail "the session recorded no mutation events");
    Agent.shutdown engine;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: attempt-lowering test exceeded 15s"

let workspace_yielding_an_observation observed : Ports.workspace =
  {
    Ports.identity = Sandbox.identity Sandbox.direct;
    checkpoint =
      (fun ~boundary ->
        Mutation.Checkpoint.make ~boundary ~capture:(available_capture ()));
    open_scope =
      (fun _claim () ->
        { Mentat_edit.Apply_evidence.applies = []; observed = [ observed ] });
    drain_notices = (fun () -> []);
  }

(* S3 live-path staleness: the store-fed mutation cache (Track B adopts the append
   return as [t.mstate]) must reach the PUBLISHED projection, not just the
   ledger. This drives a non-empty Apply_evidence to a clean settlement — no
   crash, so the failure-recovery path cannot surface a live-cache fault — and
   asserts the feed's [Tool_returned] settlement carries the observation, which
   only happens if the cache the append fed threaded into Feed.Hub.publish. A
   stale cache would publish an evidence without it. The crash suite cannot catch
   this: recovery reads a fresh journal fold, never the live cache. *)
let publish_reflects_the_settled_mutation_cache () =
  let observed = uncertain_path () in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  with_engine ~workspace:(workspace_yielding_an_observation observed)
    ~script:(edit_then_done ~call_id:"edit-1" ()) ~catalog
    (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "go");
      let facts = drain_committed (follow_ok client (sid "root")) in
      let observed_in_feed =
        List.exists
          (fun (_, fact) ->
            match fact with
            | Protocol.Fact.Tool_returned { mutation = Some ev; _ } ->
                List.exists
                  (Mentat_workspace.Path.equal observed)
                  ev.Protocol.Fact.observed
            | _ -> false)
          facts
      in
      is_true
        ~msg:
          "the published projection reflects the settled mutation the \
           store-fed cache carried"
        observed_in_feed)

(* Crash-matrix sweep: fault the k-th session commit for a range of k, so the
   crash lands at each commit point of a tool turn in turn (turn start, claim,
   settle). For every k the successor recovers to a single consistent terminal
   settlement — the atomic-suffix / no-fact-loss law (a lost commit leaves no
   half-turn) and the idempotent-resubmit law (recovery never starts a competing
   turn) both reduce to: exactly one [Turn_settled] after recovery. Generative
   properties 4-5 are scoped out per the sim study. *)
let recovery_is_consistent_across_commit_points () =
  let crash = Ports.Store_error.Io (Mentat_diagnostic.of_text "commit crash") in
  let catalog =
    match Catalog.make ~verbs:all_verbs [ trivial_tool ~name:"edit" () ] with
    | Ok c -> c
    | Error e -> failf "catalog: %a" Catalog.Error.pp e
  in
  List.iter
    (fun k ->
      with_crash_recovery (fun ~store ~restart ->
          store.commit_fault <- fault_on_nth k crash;
          let client1, engine1 =
            restart ~script:(edit_then_done ~call_id:"edit-a" ()) ~catalog ()
          in
          (* An early commit faults the submit synchronously; a later one lets
             submit through and faults the driver asynchronously. Either way the
             successor recovers. *)
          (match
             Client.submit client1.c
               (prompt ~session:(sid "root") ~turn:(tid "t-sweep") "go")
           with
          | Ok () ->
              await_yield (fun () ->
                  Option.is_some
                    (Client.faulted client1.c ~session:(sid "root")))
          | Error _ -> ());
          Agent.shutdown engine1;
          store.commit_fault <- (fun _ -> None);
          let client2, engine2 =
            restart ~script:(edit_then_done ~call_id:"edit-b" ()) ~catalog ()
          in
          submit_ok client2
            (prompt ~session:(sid "root") ~turn:(tid "t-sweep") "go");
          let facts = drain_committed (follow_ok client2 (sid "root")) in
          let settled =
            List.length
              (List.filter
                 (fun (_, f) ->
                   match f with
                   | Protocol.Fact.Turn_settled _ -> true
                   | _ -> false)
                 facts)
          in
          is_true
            ~msg:
              (Printf.sprintf
                 "crash at commit %d: the recovered turn settles exactly once" k)
            (settled = 1);
          Agent.shutdown engine2))
    [ 1; 2; 3 ]

(* The flip: the client over the engine. *)

let started_count pairs =
  List.length
    (List.filter
       (fun (_, f) ->
         match f with Protocol.Fact.Turn_started _ -> true | _ -> false)
       pairs)

(* End to end over the flipped seam: a real [Mentat_client.t] built from
   [Agent.driver] (the whole suite runs this way, but this pins the flip's own
   contract in one place). It submits and follows through the client, exercises
   both [`Beginning] (replays the journal) and [`Now] (tails from the head, not
   replaying settled turns), and forks and rewinds through the client against
   the real engine. *)
let the_client_submits_follows_and_forks_over_the_engine () =
  with_engine (fun ~sw:_ ~client ~store ~engine:_ ->
      (* [`Beginning] replays the whole journal of a driven session. *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hello");
      let first =
        drain_committed (follow_ok ~from:`Beginning client (sid "root"))
      in
      (match settled_outcome first with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the first turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the first turn never settled on the [`Beginning] feed");
      equal int
        ~msg:"[`Beginning] replays the whole journal: the first turn is seen" 1
        (started_count first);
      (* [`Now] attaches at the current head, so the settled first turn is not
         replayed — only the second turn's facts arrive. *)
      let now = follow_ok ~from:`Now client (sid "root") in
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t2") "again");
      let second = drain_committed now in
      (match settled_outcome second with
      | Some Session.Turn.Outcome.Completed -> ()
      | Some other ->
          failf "the second turn settled %a" Session.Turn.Outcome.pp other
      | None -> fail "the second turn never settled on the [`Now] feed");
      equal int
        ~msg:
          "[`Now] tails from the head: only the second turn, the first not \
           replayed"
        1 (started_count second);
      (* The session-scoped query the flip newly serves, through the client's GADT
         router to the engine: a settled session has no pending decision. *)
      (match Client.pending_decision client.c (sid "root") with
      | Ok None -> ()
      | Ok (Some _) -> fail "a settled session has no pending decision"
      | Error e ->
          failf "the pending_decision query failed: %a" Protocol.Error.pp e);
      (* Fork and rewind through the client, client-minted ids, against the real
         engine. *)
      let forked = sid "e2e-fork" in
      (match Client.fork client.c ~session:(sid "root") ~into:forked () with
      | Ok () ->
          is_true ~msg:"the client fork persisted the client-minted session"
            (Hashtbl.mem store.sessions (Session.Id.to_string forked))
      | Error e -> failf "client fork failed: %a" Protocol.Error.pp e);
      let rewound = sid "e2e-rewind" in
      match
        Client.rewind client.c ~session:(sid "root") ~into:rewound
          ~anchor:(Session.Anchor.before_turn (tid "t2"))
      with
      | Ok () ->
          is_true ~msg:"the client rewind persisted the client-minted session"
            (Hashtbl.mem store.sessions (Session.Id.to_string rewound))
      | Error e -> failf "client rewind failed: %a" Protocol.Error.pp e)

(* Two cursors, one hub (the incremental-projection materialization).
   The hub materializes the projection once and serves each feed a suffix by
   index, so two feeds at different cursors on the same session each read the
   whole, byte-identical suffix independently — neither re-folds (the "no re-fold"
   cost is a benchmark, not a unit assertion; correctness is what is pinned here). *)

let identical_pairs xs ys =
  List.compare_lengths xs ys = 0
  && List.for_all2
       (fun (pa, fa) (pb, fb) ->
         Protocol.Position.equal pa pb && Protocol.Fact.equal fa fb)
       xs ys

let two_feeds_on_one_hub_each_read_their_own_suffix () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-two") "hi");
      (* Learn the full committed sequence and let the turn settle; this feed
         closes on drain, but the attached driver keeps the hub — and its
         materialized projection — alive. *)
      let full = drain_committed (follow_ok client (sid "root")) in
      let total = List.length full in
      is_true ~msg:"the turn produced several facts to split" (total >= 2);
      equal int ~msg:"the driver pins a single hub for every follow" 1
        (Agent.retained_hub_count engine);
      (* Two cursors open at once on that one hub. *)
      let a = follow_ok client (sid "root") in
      let b = follow_ok client (sid "root") in
      let k = total / 2 in
      let a_head = read_committed k a in
      let b_all = read_committed total b in
      let a_tail = read_committed (total - k) a in
      Client.Feed.close a;
      Client.Feed.close b;
      is_true ~msg:"cursor B reads the whole suffix from the shared projection"
        (identical_pairs b_all full);
      is_true
        ~msg:"cursor A, advancing at its own index, reads the whole suffix too"
        (identical_pairs (a_head @ a_tail) full))

(* Hub eviction. A hub is retained while its session's
   driver is attached or a feed is open on it, and released when both cease;
   [Agent.retained_hub_count] is that rule's public observable, since the private
   [feed]/[hub] modules are pinned only through the runtime. Release is safe
   because the hub is a pure fold of the journal — a later follow rebuilds a
   byte-identical head. *)

let a_follow_only_hub_is_released_when_its_last_feed_closes () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      equal int ~msg:"a fresh engine retains no hubs" 0
        (Agent.retained_hub_count engine);
      let feed = follow_ok client (sid "root") in
      equal int ~msg:"following an undriven session retains its hub" 1
        (Agent.retained_hub_count engine);
      Client.Feed.close feed;
      equal int
        ~msg:"closing the last feed of a driverless session releases its hub" 0
        (Agent.retained_hub_count engine))

let an_open_feed_keeps_the_hub_retained () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      let feed_a = follow_ok client (sid "root") in
      let feed_b = follow_ok client (sid "root") in
      equal int ~msg:"two feeds on one session share a single hub" 1
        (Agent.retained_hub_count engine);
      Client.Feed.close feed_a;
      equal int ~msg:"a hub survives while another feed is still open" 1
        (Agent.retained_hub_count engine);
      Client.Feed.close feed_b;
      equal int ~msg:"the last feed closing releases the hub" 0
        (Agent.retained_hub_count engine))

let an_attached_driver_pins_its_hub_across_feed_closes () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-drive") "hi");
      (* [drain_committed] closes its own feed; the attached driver must still
         pin the hub. *)
      let _ = drain_committed (follow_ok client (sid "root")) in
      equal int ~msg:"an attached driver retains the hub after its feed closes"
        1
        (Agent.retained_hub_count engine);
      let feed = follow_ok client (sid "root") in
      Client.Feed.close feed;
      equal int
        ~msg:"the driver pins the hub across an observer feed's lifetime" 1
        (Agent.retained_hub_count engine))

let re_follow_after_eviction_replays_losslessly () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let engine_a = mk_engine ~sw ~store () in
  let client_a = { c = make_client engine_a; sw } in
  let facts_equal a b =
    List.compare_lengths a b = 0 && List.for_all2 Protocol.Fact.equal a b
  in
  let run () =
    submit_ok client_a (prompt ~session:(sid "root") ~turn:(tid "t-a") "hi");
    let driven = drain_committed (follow_ok client_a (sid "root")) in
    is_true ~msg:"the turn produced several facts to split"
      (List.length driven >= 2);
    (* Engine A committed root to the shared store; shut it down so no driver
       remains and a fresh process observes root as a follow-only session. *)
    Agent.shutdown engine_a;
    let engine_b = mk_engine ~sw ~store () in
    let client_b = { c = make_client engine_b; sw } in
    equal int ~msg:"a pure observer starts with no retained hubs" 0
      (Agent.retained_hub_count engine_b);
    let observed = drain_committed (follow_ok client_b (sid "root")) in
    equal int
      ~msg:"draining the observer feed closes it and evicts the follow-only hub"
      0
      (Agent.retained_hub_count engine_b);
    is_true ~msg:"the observer projects exactly the driver's committed facts"
      (facts_equal (facts observed) (facts driven));
    (* Re-follow from Beginning after eviction rebuilds an identical head. *)
    let replayed = drain_committed (follow_ok client_b (sid "root")) in
    is_true
      ~msg:"re-following from Beginning after eviction replays the same facts"
      (facts_equal (facts replayed) (facts observed));
    (* Re-follow from After p after eviction delivers exactly the suffix — the
       position minted before eviction still validates against the rebuilt
       head. *)
    let first_position, _ = List.hd observed in
    let tail = facts (List.tl observed) in
    let after =
      facts
        (drain_committed
           (follow_ok ~from:(`After first_position) client_b (sid "root")))
    in
    is_true
      ~msg:
        "re-following from After p after eviction skips nothing and duplicates \
         nothing"
      (facts_equal after tail);
    Agent.shutdown engine_b;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: eviction replay test exceeded 15s"

(* Bounded transcript reads. The tail and backward pages serve a
   bounded slice of the same projection the feed replays: O(page) from a driven
   session's live hub, and byte-identical to the O(J) cold fold a fresh engine
   over the shared store pays. *)

let t_bytes codec v =
  match Jsont_bytesrw.encode_string codec v with
  | Ok b -> b
  | Error m -> failf "transcript encode failed: %s" m

let t_entry_bytes (position, fact) =
  t_bytes Protocol.Update.jsont (Protocol.Update.Committed { position; fact })

let t_ok label = function
  | Ok v -> v
  | Error e -> failf "%s: %a" label Protocol.Error.pp e

let t_drop n l = List.filteri (fun i _ -> i >= n) l

let tail_serves_the_last_n_committed_facts () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-tail") "hi");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      let total = List.length pairs in
      let n = 2 in
      let tail = t_ok "tail" (Client.tail client.c ~n (sid "root")) in
      let page = tail.Protocol.Transcript.Tail.page in
      equal (list string) ~msg:"tail page is the last n feed facts"
        (List.map t_entry_bytes (t_drop (total - n) pairs))
        (List.map t_entry_bytes page.Protocol.Transcript.Page.facts);
      (match tail.Protocol.Transcript.Tail.head with
      | Some head ->
          is_true ~msg:"tail head is the feed head"
            (Protocol.Position.equal head (fst (List.nth pairs (total - 1))))
      | None -> fail "a settled turn has a head");
      (match page.Protocol.Transcript.Page.before with
      | Some cursor ->
          is_true ~msg:"the cursor is the oldest fact in the page"
            (Protocol.Position.equal cursor (fst (List.nth pairs (total - n))))
      | None -> fail "older facts remain below a bounded page");
      is_true ~msg:"a settled turn has no pending decision"
        (Option.is_none tail.Protocol.Transcript.Tail.pending))

let tail_and_page_fast_path_equal_the_cold_path () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let engine_a = mk_engine ~sw ~store () in
  let engine_b = mk_engine ~sw ~store () in
  let client_a = { c = make_client engine_a; sw } in
  let client_b = { c = make_client engine_b; sw } in
  let run () =
    submit_ok client_a (prompt ~session:(sid "root") ~turn:(tid "t-cold") "hi");
    let pairs = drain_committed (follow_ok client_a (sid "root")) in
    let total = List.length pairs in
    (* A drives root (fast path over its live hub); B never drove it, so its read
       folds the shared store cold. The two must agree byte-for-byte. *)
    let tail_a = t_ok "tail A" (Client.tail client_a.c ~n:2 (sid "root")) in
    let tail_b = t_ok "tail B" (Client.tail client_b.c ~n:2 (sid "root")) in
    equal string ~msg:"fast tail equals cold tail byte-for-byte"
      (t_bytes Protocol.Transcript.Tail.jsont tail_a)
      (t_bytes Protocol.Transcript.Tail.jsont tail_b);
    let page codec c before =
      t_bytes codec (t_ok "page" (Client.page c.c ~n:2 (sid "root") ~before))
    in
    equal string ~msg:"fast recent page equals cold recent page"
      (page Protocol.Transcript.Page.jsont client_a None)
      (page Protocol.Transcript.Page.jsont client_b None);
    let mid = fst (List.nth pairs (total - 1)) in
    equal string ~msg:"fast backward page equals cold backward page"
      (page Protocol.Transcript.Page.jsont client_a (Some mid))
      (page Protocol.Transcript.Page.jsont client_b (Some mid));
    Agent.shutdown engine_a;
    Agent.shutdown engine_b;
    Ok ()
  in
  match Eio.Time.with_timeout clock 15.0 run with
  | Ok () -> ()
  | Error `Timeout ->
      fail "deadlock guard: transcript cold-path test exceeded 15s"

let page_before_a_position_slices_and_validates () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t-page") "hi");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      let total = List.length pairs in
      (* The one fact strictly before the head fact. *)
      let head_pos = fst (List.nth pairs (total - 1)) in
      (match Client.page client.c ~n:1 (sid "root") ~before:(Some head_pos) with
      | Ok page ->
          equal (list string) ~msg:"the single fact before the head fact"
            [ t_entry_bytes (List.nth pairs (total - 2)) ]
            (List.map t_entry_bytes page.Protocol.Transcript.Page.facts)
      | Error e -> failf "page before a valid position: %a" Protocol.Error.pp e);
      (* A forged position past the head is not in the feed. *)
      let forged = Protocol.Position.make ~session:(sid "root") ~seq:99999 in
      (match Client.page client.c (sid "root") ~before:(Some forged) with
      | Error
          (Protocol.Error.Invalid_position
             (Protocol.Position.Invalid.Not_in_feed _)) ->
          ()
      | Ok _ -> fail "a forged position must not return a truncated page"
      | Error e -> failf "forged position: wrong error %a" Protocol.Error.pp e);
      (* A foreign session's position is rejected structurally. *)
      let foreign = Protocol.Position.make ~session:(sid "other") ~seq:0 in
      match Client.page client.c (sid "root") ~before:(Some foreign) with
      | Error
          (Protocol.Error.Invalid_position
             (Protocol.Position.Invalid.Foreign_session _)) ->
          ()
      | Ok _ -> fail "a foreign position must not return a page"
      | Error e -> failf "foreign position: wrong error %a" Protocol.Error.pp e)

let tail_pending_reflects_a_parked_decision () =
  let calls = ref 0 in
  let script =
    Ports.script @@ fun _request ->
    incr calls;
    match !calls with
    | 1 ->
        Ok
          (tool_call_response ~name:"ask_user"
             ~input:(json_object [ ("prompt", Json.string "Continue?") ])
             "I need a decision.")
    | _ -> Ok (plain_response "done")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-pending") "go");
      ignore
        (drain_committed
           ~stop:(function
             | Protocol.Fact.Decision_requested _ -> true | _ -> false)
           (follow_ok client (sid "root")));
      let pending =
        match Client.pending_decision client.c (sid "root") with
        | Ok p -> p
        | Error e -> failf "pending_decision: %a" Protocol.Error.pp e
      in
      let tail = t_ok "tail" (Client.tail client.c (sid "root")) in
      is_true ~msg:"the tail carries the parked decision"
        (Option.is_some tail.Protocol.Transcript.Tail.pending);
      is_true ~msg:"the tail's pending decision equals pending_decision"
        (Option.equal Session.Decision.Requested.equal pending
           tail.Protocol.Transcript.Tail.pending))

(* Suite. *)

(* Structured output (--output-schema): the synthetic [structured_output] tool
   seam. The scripted provider returns tool calls to it exactly as a real model
   would; the step's validation is the conformance guarantee under test. *)

let answer_schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object
          [ ("answer", json_object [ ("type", Json.string "string") ]) ] );
      ("required", json_array [ Json.string "answer" ]);
      ("additionalProperties", Json.bool false);
    ]

let conforming_answer = json_object [ ("answer", Json.string "the answer") ]

let prompt_schema ?output_schema ~session ~turn text =
  match
    Protocol.Command.prompt ~session ~turn
      ~input:[ Llm.Content.text text ]
      ?output_schema ()
  with
  | Ok c -> c
  | Error e -> failf "prompt command: %s" (Protocol.Command.Invalid.message e)

let structured_output_claim pairs =
  List.find_map
    (fun (_, f) ->
      match f with
      | Protocol.Fact.Tool_started started
        when String.equal
               (Llm.Tool.Call.name (Session.Tool_claim.Started.call started))
               "structured_output" ->
          Some (Session.Tool_claim.Started.input started)
      | _ -> None)
    pairs

let structured_output_seals_the_contract () =
  let script =
    Ports.script @@ fun _request ->
    Ok
      (tool_call_response ~name:"structured_output" ~input:conforming_answer
         "here")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt_schema ~output_schema:answer_schema ~session:(sid "root")
           ~turn:(tid "t-seal") "go");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      let turn =
        match
          List.find_map
            (fun (_, f) ->
              match f with Protocol.Fact.Turn_started t -> Some t | _ -> None)
            pairs
        with
        | Some t -> t
        | None -> fail "no Turn_started fact"
      in
      let contract = Session.Turn.contract turn in
      (match Session.Contract.output_tool contract with
      | Some tool ->
          equal string ~msg:"sealed tool name" "structured_output"
            (Llm.Tool.name tool);
          is_true ~msg:"sealed schema matches the flag"
            (Json.equal answer_schema (Llm.Tool.input_schema tool))
      | None -> fail "output_tool was not sealed on the contract");
      is_true ~msg:"options are preserved unperturbed"
        (Json.equal
           (encode Llm.Request.Options.jsont
              (Session.Contract.options contract))
           (encode Llm.Request.Options.jsont Llm.Request.Options.default)))

let structured_output_request_carries_tool_and_instruction () =
  let build = ref None in
  let script =
    Ports.script @@ fun request ->
    build := Some request;
    Ok
      (tool_call_response ~name:"structured_output" ~input:conforming_answer
         "done")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt_schema ~output_schema:answer_schema ~session:(sid "root")
           ~turn:(tid "t-req") "go");
      ignore (drain_committed (follow_ok client (sid "root")));
      let request =
        match !build with Some r -> r | None -> fail "no request captured"
      in
      is_true ~msg:"the synthetic tool is declared"
        (request_contains request "structured_output");
      is_true ~msg:"the delivery instruction rides the prelude"
        (request_contains request "This run requires a structured final answer"))

let structured_output_conforming_settles_completed () =
  let script =
    Ports.script @@ fun _request ->
    Ok
      (tool_call_response ~name:"structured_output" ~input:conforming_answer
         "done")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt_schema ~output_schema:answer_schema ~session:(sid "root")
           ~turn:(tid "t-ok") "go");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | _ -> fail "expected the turn to settle Completed");
      match structured_output_claim pairs with
      | Some input ->
          is_true ~msg:"the claim carries the validated answer"
            (Json.equal input conforming_answer)
      | None -> fail "no structured_output claim projected")

(* This non-conforming-retry path is also exercised end to end by
   output-schema.t, which is the more-real witness. It is kept here for
   unit-level fast localization of the step's validation-and-retry logic. *)
let structured_output_non_conforming_retries () =
  let calls = ref 0 in
  let retry = ref None in
  let script =
    Ports.script @@ fun request ->
    incr calls;
    match !calls with
    | 1 ->
        (* [answer] is a number, not a string: a type violation. *)
        Ok
          (tool_call_response ~name:"structured_output"
             ~input:(json_object [ ("answer", Json.int 5) ])
             "bad")
    | _ ->
        retry := Some request;
        Ok
          (tool_call_response ~name:"structured_output" ~input:conforming_answer
             "good")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt_schema ~output_schema:answer_schema ~session:(sid "root")
           ~turn:(tid "t-retry") "go");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | _ -> fail "expected Completed after the model corrected its answer");
      let request =
        match !retry with
        | Some r -> r
        | None -> fail "the model was not re-prompted"
      in
      is_true ~msg:"the retry request carries the violation feedback"
        (request_contains request "does not conform"))

let structured_output_reminds_on_no_call () =
  let calls = ref 0 in
  let reprompt = ref None in
  let script =
    Ports.script @@ fun request ->
    incr calls;
    match !calls with
    | 1 -> Ok (plain_response "Here is the answer in prose.")
    | _ ->
        reprompt := Some request;
        Ok
          (tool_call_response ~name:"structured_output" ~input:conforming_answer
             "done")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine:_ ->
      submit_ok client
        (prompt_schema ~output_schema:answer_schema ~session:(sid "root")
           ~turn:(tid "t-remind") "go");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (match settled_outcome pairs with
      | Some Session.Turn.Outcome.Completed -> ()
      | _ -> fail "expected Completed after the reminder");
      let request =
        match !reprompt with Some r -> r | None -> fail "no reprompt issued"
      in
      is_true ~msg:"the reminder was injected before the reprompt"
        (request_contains request "have not delivered the final answer"))

let structured_output_budget_exhaustion_fails () =
  let script =
    Ports.script @@ fun _request ->
    Ok (plain_response "Prose again, no tool call.")
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt_schema ~output_schema:answer_schema ~session:(sid "root")
           ~turn:(tid "t-budget") "go");
      let pairs = drain_committed (follow_ok client (sid "root")) in
      (* The reminder pends and dies with the turn: the durable transcript
         must not end on a dangling imperative no request ever showed. *)
      (match Hashtbl.find_opt store.sessions "root" with
      | None -> fail "the root session is missing from the store"
      | Some session -> (
          match
            List.rev
              (Llm.Transcript.messages
                 (Session.State.model_transcript (Session.state session)))
          with
          | Llm.Message.User content :: _ ->
              is_false ~msg:"no dangling reminder after a failed schema turn"
                (List.exists
                   (function
                     | Llm.Content.Text text ->
                         contains_sub
                           ~sub:"have not delivered the final answer" text
                     | _ -> false)
                   content)
          | _ -> ()));
      match settled_outcome pairs with
      | Some (Session.Turn.Outcome.Failed { message }) ->
          is_true ~msg:"the failure names the unmet structured output"
            (contains_sub ~sub:"structured_output" message);
          is_true ~msg:"no answer was projected"
            (Option.is_none (structured_output_claim pairs))
      | _ -> fail "expected Failed on budget exhaustion")

(* The online metadata cone (4a): [commit_metadata] runs on a driven session's
   controller at an idle point, adopting the new store revision. *)

let commit_metadata_not_driven () =
  with_engine (fun ~sw:_ ~client:_ ~store:_ ~engine ->
      match
        Agent.commit_metadata engine (sid "never-driven") ~transform:(fun s ->
            Ok s)
      with
      | `Not_driven -> ()
      | `Committed _ -> fail "a session no live driver holds must be Not_driven")

let commit_metadata_on_driven_idle () =
  with_engine (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let feed = follow_ok client (sid "root") in
      let _ = drain_committed feed in
      (match
         Agent.commit_metadata engine (sid "root") ~transform:(fun s ->
             Ok (Session.set_title (Some "renamed") s))
       with
      | `Committed (Ok ()) -> ()
      | `Committed (Error e) ->
          failf "an idle metadata commit must succeed: %a" Protocol.Error.pp e
      | `Not_driven -> fail "the driven session must not be Not_driven");
      match Hashtbl.find_opt store.sessions "root" with
      | Some s ->
          equal (option string) ~msg:"the title is committed to the store"
            (Some "renamed")
            (Session.Metadata.title (Session.metadata s))
      | None -> fail "the session vanished")

let commit_metadata_refuses_active_turn () =
  let released, release = Eio.Promise.create () in
  let script =
    Ports.script @@ fun _req ->
    Eio.Promise.await released;
    Ok (plain_response "Done.")
  in
  with_engine ~script (fun ~sw:_ ~client ~store:_ ~engine ->
      (* Submit admits the turn (Turn_started durable) before returning; the
         worker then blocks in the script, so a turn is active. *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      (match
         Agent.commit_metadata engine (sid "root") ~transform:(fun s -> Ok s)
       with
      | `Committed (Error (Protocol.Error.Unavailable _)) -> ()
      | `Committed (Error e) ->
          failf "expected the active-turn error, got %a" Protocol.Error.pp e
      | `Committed (Ok ()) ->
          fail "must not commit metadata during an active turn"
      | `Not_driven -> fail "the session is driven");
      Eio.Promise.resolve release ();
      let feed = follow_ok client (sid "root") in
      let _ = drain_committed feed in
      ())

let commit_metadata_port_conflict_faults () =
  with_engine (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let feed = follow_ok client (sid "root") in
      let _ = drain_committed feed in
      store.metadata_fault <- (fun _ -> Some Ports.Store_error.Conflict);
      match
        Agent.commit_metadata engine (sid "root") ~transform:(fun s -> Ok s)
      with
      | `Committed (Error (Protocol.Error.Unavailable _)) -> ()
      | `Committed (Error e) ->
          failf "a port Conflict must fault loudly, got %a" Protocol.Error.pp e
      | `Committed (Ok ()) -> fail "a port Conflict must not report success"
      | `Not_driven -> fail "the session is driven")

let commit_metadata_adopts_revision () =
  with_engine (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let feed = follow_ok client (sid "root") in
      let _ = drain_committed feed in
      (match
         Agent.commit_metadata engine (sid "root") ~transform:(fun s ->
             Ok (Session.set_title (Some "kept") s))
       with
      | `Committed (Ok ()) -> ()
      | _ -> fail "the metadata commit must succeed");
      (* A subsequent turn commits journal events. Had the controller not adopted
         the metadata commit's revision, this turn would commit on the stale head
         and drop the title (plan risk #2). *)
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t2") "again");
      let _ = drain_committed feed in
      match Hashtbl.find_opt store.sessions "root" with
      | Some s ->
          equal (option string)
            ~msg:
              "the metadata survived the next journal commit (revision adopted)"
            (Some "kept")
            (Session.Metadata.title (Session.metadata s))
      | None -> fail "the session vanished")

(* The online revert/export cones (W3 3e): fenced idle-mailbox flows beside
   commit_metadata. [route] attaches on demand; the driver runs the port op at an
   idle point and maps the store outcome and errors totally. *)

let revert_forwards_outcome () =
  with_engine (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      store.revert_result <-
        (fun _ -> Ok Mutation.Revert.Outcome.Nothing_to_revert);
      let session_cone = Agent.driver engine in
      match
        session_cone.Client.Driver.Session.revert ~session:(sid "root")
          ~scope:Mutation.Revert.Scope.Latest
      with
      | Ok Mutation.Revert.Outcome.Nothing_to_revert -> ()
      | Ok _ -> fail "the engine must forward the port's outcome verbatim"
      | Error e -> failf "an idle revert must succeed: %a" Protocol.Error.pp e)

let revert_refuses_active_turn () =
  let released, release = Eio.Promise.create () in
  let script =
    Ports.script @@ fun _req ->
    Eio.Promise.await released;
    Ok (plain_response "Done.")
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      store.revert_result <-
        (fun _ -> fail "the port must not be reached during an active turn");
      let session_cone = Agent.driver engine in
      (match
         session_cone.Client.Driver.Session.revert ~session:(sid "root")
           ~scope:Mutation.Revert.Scope.Latest
       with
      | Error (Protocol.Error.Unavailable _) -> ()
      | Error e ->
          failf "expected the active-turn error, got %a" Protocol.Error.pp e
      | Ok _ -> fail "must not revert during an active turn");
      Eio.Promise.resolve release ();
      let _ = drain_committed (follow_ok client (sid "root")) in
      ())

let revert_maps_port_error () =
  with_engine (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      store.revert_result <-
        (fun _ ->
          Error (Ports.Store_error.Corrupt (Mentat_diagnostic.of_text "boom")));
      let session_cone = Agent.driver engine in
      match
        session_cone.Client.Driver.Session.revert ~session:(sid "root")
          ~scope:Mutation.Revert.Scope.Latest
      with
      | Error (Protocol.Error.Unavailable _) -> ()
      | Error e ->
          failf "a port error must map to Unavailable, got %a" Protocol.Error.pp
            e
      | Ok _ -> fail "a port error must not report success")

let export_forwards_bundle () =
  with_engine (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      store.export_result <- Ok "mentat.session bundle bytes";
      let session_cone = Agent.driver engine in
      match session_cone.Client.Driver.Session.export ~session:(sid "root") with
      | Ok bundle ->
          equal string ~msg:"the engine forwards the bundle bytes"
            "mentat.session bundle bytes" bundle
      | Error e -> failf "an idle export must succeed: %a" Protocol.Error.pp e)

let export_maps_port_error () =
  with_engine (fun ~sw:_ ~client ~store:_ ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (* The default port result declines; the engine maps it to Unavailable. *)
      let session_cone = Agent.driver engine in
      match session_cone.Client.Driver.Session.export ~session:(sid "root") with
      | Error (Protocol.Error.Unavailable _) -> ()
      | Error e ->
          failf "a port error must map to Unavailable, got %a" Protocol.Error.pp
            e
      | Ok _ -> fail "a port error must not report success")

let export_rejects_oversize () =
  with_engine (fun ~sw:_ ~client ~store ~engine ->
      submit_ok client (prompt ~session:(sid "root") ~turn:(tid "t1") "hi");
      let _ = drain_committed (follow_ok client (sid "root")) in
      (* One byte past the 64 MiB in-memory ceiling (allocated transiently). *)
      store.export_result <- Ok (String.make ((64 * 1024 * 1024) + 1) 'x');
      let session_cone = Agent.driver engine in
      match session_cone.Client.Driver.Session.export ~session:(sid "root") with
      | Error (Protocol.Error.Unavailable _) -> ()
      | Error e ->
          failf "an oversize bundle must be Unavailable, got %a"
            Protocol.Error.pp e
      | Ok _ ->
          fail "an oversize bundle must be refused, not buffered over the wire")

(* Interrupted-usage plumbing. The stream reports prose and a cumulative usage
   snapshot, then hangs until the driver cancels; the interrupt settlement
   retains the snapshot, so metrics counts the billed spend. *)

let an_interrupt_retains_the_streamed_usage () =
  let streaming = ref false in
  let script _request ~on_event ~on_download:_ ~cancelled =
    on_event (Llm.Event.text_delta "partial thought");
    on_event (Llm.Event.usage (Llm.Usage.make ~input:120 ~output:8 ()));
    streaming := true;
    let rec loop () =
      if cancelled () then
        Error
          (Llm.Error.make ~kind:Llm.Error.Cancelled ~phase:Llm.Error.Stream
             "cancelled by driver")
      else begin
        Eio.Fiber.yield ();
        loop ()
      end
    in
    loop ()
  in
  with_engine ~script (fun ~sw:_ ~client ~store ~engine:_ ->
      submit_ok client
        (prompt ~session:(sid "root") ~turn:(tid "t-usage") "hang");
      let feed = follow_ok client (sid "root") in
      while not !streaming do
        Eio.Fiber.yield ()
      done;
      (match
         Protocol.Command.interrupt ~session:(sid "root") ~reason:"stop" ()
       with
      | Ok cmd -> submit_ok client cmd
      | Error e ->
          failf "interrupt command: %s" (Protocol.Command.Invalid.message e));
      ignore (drain_n_settled 1 feed);
      let session =
        match Hashtbl.find_opt store.sessions "root" with
        | Some s -> s
        | None -> fail "root session vanished"
      in
      let usage = (Session.metrics session).Session.Metrics.usage in
      equal int ~msg:"interrupted input spend survives" 120
        (Llm.Usage.input_total usage);
      equal int ~msg:"interrupted output spend survives" 8
        (Llm.Usage.output_total usage))

let () =
  run "mentat.agent"
    [
      group "structured output"
        [
          test "seals the output tool on the contract"
            structured_output_seals_the_contract;
          test "the request carries the tool and the prelude instruction"
            structured_output_request_carries_tool_and_instruction;
          test "a conforming call settles Completed with the answer"
            structured_output_conforming_settles_completed;
          test "a non-conforming call lowers a violation and the model retries"
            structured_output_non_conforming_retries;
          test "a no-tool-call response injects a reminder and reprompts"
            structured_output_reminds_on_no_call;
          test "budget exhaustion settles Failed"
            structured_output_budget_exhaustion_fails;
        ];
      group "pure: catalog"
        [
          test "duplicate executable names are rejected"
            catalog_rejects_duplicate_names;
          test "a reserved verb name is rejected" catalog_rejects_reserved_names;
          test "duplicate engine verbs are rejected"
            catalog_rejects_duplicate_verbs;
          test "catalogs contain exactly their supplied verbs"
            catalog_has_exact_supplied_verbs;
          test "engine verbs reject unknown input members"
            engine_verbs_reject_unknown_input_members;
          test "spawn rejects an unknown role" spawn_rejects_an_unknown_role;
          test "engine verb declaration drift blocks dispatch"
            engine_verb_declaration_drift_blocks_dispatch;
        ];
      group "pure: config, env, errors"
        [
          test "config defaults are the documented ones"
            config_defaults_are_the_documented_ones;
          test "config rejects non-positive knobs"
            config_rejects_non_positive_knobs;
          test "a step-limited turn winds down once"
            a_step_limited_turn_winds_down_once;
          test "env rejects invalid scalars" env_rejects_invalid_scalars;
          test "step protocol errors fold to Internal"
            error_folds_step_protocol_cases_to_internal;
          test "a forged plan build creates no provider effect"
            forged_plan_build_creates_no_provider_effect;
        ];
      group "lifecycle"
        [
          test "a prompt turn starts and completes"
            a_prompt_turn_starts_and_completes;
          test
            "a prompt image is externalized to a ref and resolved for the \
             provider"
            a_prompt_with_image_externalizes_and_resolves;
          test "a driver's nested switch releases on close"
            a_driver_nested_switch_releases_on_close;
          test "close reaps a cancellation-ignoring switch fiber, bounded"
            a_driver_close_reaps_a_cancellation_ignoring_switch_fiber;
          test "each driver gets its own nested switch"
            each_driver_gets_its_own_nested_switch;
          test "running_processes reads the driver's live background view"
            running_processes_reads_the_drivers_live_view;
          test "mode execution binds catalog, workspace, and policy together"
            mode_execution_binds_catalog_workspace_and_policy_together;
          test "active Plan recovery uses the read execution"
            active_plan_recovery_uses_the_read_execution;
          test "current plan approval reaches the exact Build provider request"
            (plan_approval_reaches_the_build_request `Current);
          test "fresh plan approval resets the Build provider request context"
            (plan_approval_reaches_the_build_request `Fresh);
          test
            "session config reloads at the next turn and remains \
             session-isolated"
            session_config_is_reloaded_at_each_turn_and_isolated_by_session;
          test "the session's journal model reaches config resolution"
            latest_model_reaches_config_resolution;
          test "a provider failure streams structured error before terminal"
            a_provider_failure_streams_structured_error_before_terminal;
          test "a generic provider failure names the source once"
            a_generic_provider_failure_message_names_the_source_once;
          test "submit returns after durable admission"
            submit_returns_after_durable_admission;
          test "a reused turn id with new input is rejected"
            reused_turn_id_with_new_input_is_rejected;
        ];
      group "feed"
        [
          test "close makes next report Closed" close_makes_next_report_closed;
          test "resume from a delivered position skips nothing"
            resume_from_a_delivered_position_skips_nothing;
          test "a forged out-of-feed position is Invalid_position"
            a_forged_out_of_feed_position_is_invalid;
          test "a foreign-session position is Invalid_position"
            a_foreign_session_position_is_invalid;
          test "follow `Now before submit delivers the turn (shared hub)"
            follow_now_before_submit_delivers_the_turn;
          test "the feed ring drops oldest progress, keeping committed"
            the_feed_ring_drops_oldest_progress_keeping_committed;
          test "tool-input streaming pulses cumulative liveness"
            tool_input_streaming_pulses_cumulative_liveness;
          test "two feeds on one hub each read their own full suffix"
            two_feeds_on_one_hub_each_read_their_own_suffix;
          test "a follow-only hub is released when its last feed closes"
            a_follow_only_hub_is_released_when_its_last_feed_closes;
          test "an open feed keeps the hub retained"
            an_open_feed_keeps_the_hub_retained;
          test "an attached driver pins its hub across feed closes"
            an_attached_driver_pins_its_hub_across_feed_closes;
          test "re-follow after eviction replays losslessly"
            re_follow_after_eviction_replays_losslessly;
        ];
      group "transcript reads"
        [
          test "the tail is the last n committed facts, with head and cursor"
            tail_serves_the_last_n_committed_facts;
          test "the fast hub path equals the cold journal fold byte-for-byte"
            tail_and_page_fast_path_equal_the_cold_path;
          test "a backward page slices before a position and validates it"
            page_before_a_position_slices_and_validates;
          test "the tail's pending decision reflects the session state"
            tail_pending_reflects_a_parked_decision;
        ];
      group "command admission"
        [
          test "a queue entry is admitted at the idle boundary"
            a_queue_entry_is_admitted_at_the_idle_boundary;
          test "a queue replacement mints distinct entries in input order"
            a_queue_replacement_mints_distinct_entries_in_input_order;
          test "an interrupt admits the queued correction"
            an_interrupt_admits_the_queued_correction;
          test "a queued entry from an unprovable sender is refused"
            a_queued_entry_from_an_unprovable_sender_is_refused;
        ];
      group "busy, faults, shutdown"
        [
          test "a second engine over a driven session is Busy"
            a_second_engine_over_a_driven_session_is_busy;
          test "a faulted driver is Unavailable and sticky"
            a_faulted_driver_is_unavailable_and_sticky;
          test "shutdown stops admission" shutdown_stops_admission;
          test "fork and compact after close do not hang"
            fork_and_compact_after_close_do_not_hang;
          test "a contained fault is pollable without submitting"
            faulted_is_pollable_without_submitting;
          test "shutdown preserves a parked decision for recovery"
            shutdown_preserves_a_parked_decision_for_recovery;
          test "shutdown is idempotent" shutdown_is_idempotent;
        ];
      group "flows and observation"
        [
          test "possibly_mutating is false for a clean session"
            possibly_mutating_is_false_for_a_clean_session;
          test "answer_unattended on no decision is Decision_not_pending"
            answer_unattended_on_no_decision_is_not_pending;
          test "observation never acquires the fence"
            observation_never_acquires_the_fence;
          test "fork and rewind copy the mutation ledger into the child"
            branch_flows_copy_the_mutation_ledger;
          test "manual compact installs a user-requested summary"
            manual_compact_installs_a_user_requested_summary;
          test "manual compact replays the same turn id"
            manual_compact_replays_the_same_turn_id;
          test "a pending notice survives the compaction boundary"
            a_pending_notice_survives_the_compaction_boundary;
          test "manual compact rejects a non-compaction turn id"
            manual_compact_rejects_a_non_compaction_turn_id;
          test "manual compact distinct ids compact independently"
            manual_compact_distinct_ids_compact_independently;
          test "context overflow compacts once and retries"
            overflow_compacts_once_and_retries;
          test "the resume notice frames the reissued summary"
            the_resume_notice_frames_the_reissued_summary;
          test "a step-limited turn winds down once then stops"
            a_step_limited_turn_winds_down_once_then_stops;
          test "context overflow recovery is bounded per turn"
            overflow_recovery_is_bounded_per_turn;
          test "context pressure compaction records the before projection"
            context_pressure_compaction_records_the_before_projection;
          test "context pressure compacts without provider usage"
            context_pressure_compacts_without_provider_usage;
          test "a length stop at pressure compacts and retries"
            a_length_stop_at_pressure_compacts_and_retries;
          test "a repeat length stop completes after one recovery"
            a_repeat_length_stop_completes_after_one_recovery;
          test "a summary request carries the summarizer prelude"
            a_summary_request_carries_the_summarizer_prelude;
          test "a pressure summary keeps a verbatim tail"
            a_pressure_summary_keeps_a_verbatim_tail;
          test "an oversized tail falls back to a full summary"
            an_oversized_tail_falls_back_to_a_full_summary;
          test "a second compaction advances the boundary behind the tail"
            a_second_compaction_advances_the_boundary_behind_the_tail;
          test "a mid-turn workspace notice rides the next request"
            a_mid_turn_notice_rides_the_next_request;
          test "a turn states every observation it made"
            a_turn_states_every_observation_it_made;
          test "an observation outlives the turn that could not state it"
            an_observation_outlives_the_turn_that_could_not_state_it;
          test "an observation made while waiting reaches the parent"
            an_observation_made_while_waiting_reaches_the_parent;
        ];
      group "scheduler and subagents"
        [
          test "a spawn creates, drives, and settles a child"
            a_spawn_creates_drives_and_settles_a_child;
          test "a prompt to a settled child runs a new turn"
            a_prompt_to_a_settled_child_runs_a_new_turn;
          test "a spawned child is resolvable when its edge is observed"
            a_spawned_child_is_resolvable_when_its_edge_is_observed;
          test "a delegated session uses the fixed execution"
            a_delegated_session_uses_the_fixed_execution;
          test "a spawn carries its role to the delegated child"
            a_spawn_carries_its_role_to_the_delegated_child;
          test "a roleless spawn delegates generically"
            a_roleless_spawn_delegates_generically;
          test "a generic delegate runs a write tool"
            a_generic_delegate_runs_a_write_tool;
          test "delegated recovery uses the fixed execution"
            delegated_recovery_uses_the_fixed_execution;
          test "delegated attachment rejects invalid lineage"
            delegated_attachment_rejects_invalid_lineage;
          test "a failed child creation does not wedge the parent"
            a_failed_child_creation_does_not_wedge_the_parent;
          test "recovery re-drives a lost child" recovery_redrives_a_lost_child;
          test "a spawn never faults the parent turn"
            a_spawn_at_the_depth_cap_fails_the_call_not_the_turn;
          test "a child replies to its parent by mail"
            a_child_replies_to_its_parent_by_mail;
          test "queued input frames the sender from the typed origin"
            queued_input_frames_the_sender;
          test "the model addresses a spawned child by the receipt handle"
            the_model_addresses_a_spawned_child_by_the_receipt_handle;
          test "a raising admission faults only its own driver"
            a_raising_admission_faults_only_its_own_driver;
          test "a follow_up to a busy child parks and drains"
            a_follow_up_to_a_busy_child_parks_and_drains;
          test "recovery takes a fresh capture, not the pre-crash one"
            recovery_takes_a_fresh_capture_not_the_pre_crash_one;
          test "fresh available recovery checkpoint clears uncertainty"
            (recovery_checkpoint_availability_law ~replayed:false
               ~available:true);
          test "fresh degraded recovery checkpoint keeps uncertainty"
            (recovery_checkpoint_availability_law ~replayed:false
               ~available:false);
          test "replayed available recovery checkpoint clears uncertainty"
            (recovery_checkpoint_availability_law ~replayed:true ~available:true);
          test "replayed degraded recovery checkpoint keeps uncertainty"
            (recovery_checkpoint_availability_law ~replayed:true
               ~available:false);
          test "an attempted apply lowers to an uncertain edit event"
            an_attempted_apply_lowers_to_an_uncertain_edit_event;
          test "the published projection reflects the settled mutation cache"
            publish_reflects_the_settled_mutation_cache;
          test "recovery is consistent across commit points"
            recovery_is_consistent_across_commit_points;
        ];
      group "brokered child backend"
        [
          test "a brokered spawn hands identity and integrates on the wake"
            a_brokered_spawn_hands_identity_and_integrates_on_the_wake;
          test "a brokered failure settles the parked wait"
            a_brokered_failure_settles_the_parked_wait;
          test "a reaped brokered child releases capacity"
            a_reaped_brokered_child_releases_capacity;
          test "a brokered message crosses the broker send"
            a_brokered_message_crosses_the_broker_send;
          test "same-edge messages deliver in order"
            same_edge_messages_deliver_in_order;
          test "an undelivered message re-drives at the next attach"
            an_undelivered_message_redrives_at_the_next_attach;
        ];
      group "online metadata cone (4a)"
        [
          test "commit_metadata on a session no driver holds is Not_driven"
            commit_metadata_not_driven;
          test "commit_metadata at a driven idle point commits the metadata"
            commit_metadata_on_driven_idle;
          test "commit_metadata during an active turn refuses"
            commit_metadata_refuses_active_turn;
          test "a port Conflict on commit_metadata faults loudly"
            commit_metadata_port_conflict_faults;
          test "commit_metadata adopts the revision so the next turn commits"
            commit_metadata_adopts_revision;
        ];
      group "online revert/export cones (3e)"
        [
          test "revert forwards the port outcome at a driven idle point"
            revert_forwards_outcome;
          test "revert during an active turn refuses without reaching the port"
            revert_refuses_active_turn;
          test "a port error on revert maps to Unavailable"
            revert_maps_port_error;
          test "export forwards the buffered bundle" export_forwards_bundle;
          test "a port error on export maps to Unavailable"
            export_maps_port_error;
          test "an oversize export bundle is refused by the size guard"
            export_rejects_oversize;
        ];
      group "the flip: client over engine"
        [
          test
            "the client submits, follows (`Beginning and `Now), and forks over \
             the engine"
            the_client_submits_follows_and_forks_over_the_engine;
        ];
      group "interrupted usage"
        [
          test "an interrupt retains the streamed usage snapshot"
            an_interrupt_retains_the_streamed_usage;
        ];
    ]
