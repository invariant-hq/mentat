(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Engine latency: the mentat-owned span between "start a turn" and the first
    streamed token, as a function of conversation length.

    The felt moment is pressing Enter in a long session and the model beginning
    to answer — the part mentat owns end to end, before any network byte. This
    drives the real engine ({!Mentat_agent}) over a real store root in a fresh
    temp directory (the engine links the store directly) and a
    streaming provider stub: the stub records [t0] the instant it is called and
    emits one assistant delta, and the harness watches a pre-opened [`Now] feed
    for that delta. Two spans compose the latency: [submit -> provider_call]
    (the engine acquiring the session fence, loading, recovering to quiescence,
    and committing [Turn_started] before dispatching the request) and
    [t0 -> first Assistant_delta] (the delta crossing the driver's fan-out to
    the feed). Both should be flat across the 100/1k/10k session axis — the
    engine reads the head, not the whole journal, per turn.

    [submit -> provider_call] is O(conversation): before a turn's first byte,
    mentat projects the whole model-visible transcript and assembles and digests
    the request over it — the cost [bench_enter]'s pure group isolates, inherent
    because the model is sent the whole conversation as context.
    [provider -> delta] is O(1): the streaming fan-out to the feed does not grow
    with history.

    Each session is driven through two turns, COLD (the driver attaches — loads
    and replays the journal from the store) and WARM (the driver is attached,
    its head cached, no store read). The measured surprise is that cold ≈ warm
    at every size: the dominant linear term is NOT the store reload — a warm
    turn skips it and is nearly as slow — but the per-turn request assembly
    over the conversation. So the lever for the optimization campaign is an
    incremental request/digest, not a driver-side cache of the loaded journal.

    It is a WALL TREND, recorded and never gated: engine orchestration is
    multi-fiber and stateful per run, so it is driven directly (fresh session
    per sample, first samples discarded) rather than through the alloc-exact
    sampler the Tier A gates use, and printed for the nightly log. Wall time on
    a shared runner under load is noise, not a regression — the gate-worthy
    scaling property (that one feed poll is O(1) in journal length) is asserted
    separately and deterministically by [bench_poll_scaling]. *)

module Agent = Mentat_agent
module Client = Mentat_client
module Ports = Mentat_agent.Ports
module Protocol = Mentat_protocol
module Session = Mentat_session
module Mutation = Mentat_mutation
module Sandbox = Mentat_sandbox
module Llm = Mentat_llm
module Fixture = Bench_support.Session_fixture

let monotonic () = Mtime.Span.to_float_ns (Mtime_clock.elapsed ()) *. 1e-9

let model =
  Llm.Model.make
    ~provider:(Llm.Provider.make "openai")
    ~api:(Llm.Model.Api.make "responses")
    ~id:"gpt-5"

let plain_response text =
  Llm.Response.make ~model ~stop:Llm.Response.Stop.end_turn
    (Llm.Message.Assistant.text text)

(* A real store root in a fresh temp directory — the engine's direct
   substrate, the same one the unit suite drives. Sessions are seeded through
   the store's own create; mutation ledgers stay empty. *)
type store_state = {
  root : Mentat_store.t;
  owner : Mentat_store.Run_lock.Owner.t;
}

let fresh_store ~sw ~fs () =
  let base =
    Unix.realpath (Filename.temp_dir ~perms:0o700 "mentat-bench-store" "")
  in
  match Mentat_store.open_ ~sw (Eio.Path.( / ) fs base) with
  | Ok root -> { root; owner = Mentat_store.Run_lock.Owner.make () }
  | Error e ->
      Format.kasprintf failwith "open store root: %s"
        (Mentat_store.Error.message e)

(* Seed a session of [events] semantic events under [id], ready to be driven. *)
let seed_session st ~id ~events =
  let session = Fixture.build ~id ~events () in
  match Mentat_store.Session.create st.root session with
  | Ok _ -> ()
  | Error e ->
      Format.kasprintf failwith "seed session %s: %s" id
        (Mentat_store.Session.Error.message e)

let workspace : Ports.workspace =
  let checkpoint ~boundary =
    Mutation.Checkpoint.make ~boundary
      ~capture:
        (Mutation.Checkpoint.Capture.Available
           {
             snapshot =
               Mutation.Checkpoint.Snapshot.make ~backend:"bench"
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

let catalog =
  match Agent.Catalog.make ~verbs:[] [] with
  | Ok c -> c
  | Error e -> Format.kasprintf failwith "catalog: %a" Agent.Catalog.Error.pp e

let config _id ~latest_model:_ =
  Ok (Agent.Config.make ~model ())

(* The client's non-session responders are inert stubs: a latency run exercises
   only submit and follow, which route to the engine's session driver. *)
let stub_unavailable () =
  Error (Protocol.Error.Unavailable (Mentat_diagnostic.of_text "bench stub"))

let stub_accounts : Client.Driver.Accounts.t =
  {
    Client.Driver.Accounts.login =
      (fun ~provider:_ ~method_:_ -> stub_unavailable ());
    save_api_key = (fun ~provider:_ ~key:_ -> stub_unavailable ());
    logout = (fun ?revoke:_ _provider -> stub_unavailable ());
    account_readiness = (fun () -> stub_unavailable ());
    model_readiness = (fun ?refresh:_ () -> stub_unavailable ());
  }

let stub_settings : Client.Driver.Settings.t =
  {
    Client.Driver.Settings.set_model =
      (fun ~session:_ ?reasoning_effort:_ _selector -> stub_unavailable ());
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
    set_goal = (fun ~session:_ ~goal:_ -> stub_unavailable ());
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

let no_user_commands () = Ok []
let no_expand_command ~name:_ ~arguments:_ = Ok []

let no_attach ~session:_ _source =
  Error
    (Protocol.Attach.Error.Unavailable
       (Mentat_diagnostic.of_text "attach unused in this bench"))

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

let mk_engine ~sw ~store ~provider =
  let now =
    let r = ref 1_000L in
    fun () ->
      let v = !r in
      r := Int64.add v 1L;
      Session.Time.of_unix_ms v
  in
  let execution_for_mode ~background:_ =
    ( (fun ~configured ~model:_ ~sealed_declarations:_ _mode ->
        Agent.Execution.make ~catalog ~workspace
          ~policy:configured.Agent.Config.policy
          ~prelude:Llm.Request.Prelude.empty),
      fun () -> [] )
  in
  let delegated_execution ~role:_ ~background:_ =
    ( (fun ~configured:_ ~model:_ ~sealed_declarations:_ _mode ->
        Agent.Execution.make ~catalog ~workspace
          ~policy:Mentat_permission.Policy.default
          ~prelude:Llm.Request.Prelude.empty),
      fun () -> [] )
  in
  Agent.create ~sw ~store:store.root ~owner:store.owner ~provider ~config ~now
    ~merge:true
    ~revert_observe:(fun _path -> Mentat_edit.Observed.Missing)
    ~revert_checkpoint:(fun ~boundary ->
      Mutation.Checkpoint.make ~boundary
        ~capture:
          (Mutation.Checkpoint.Capture.Available
             {
               snapshot =
                 Mutation.Checkpoint.Snapshot.make ~backend:"bench"
                   ~reference:"ref";
               excluded = 0;
             }))
    ~revert_apply:(fun _edit -> failwith "bench revert cone unused")
    ~revert_new_id:(fun () -> Mutation.Revert.Id.of_string "revert-bench")
    ~broker:
      (Mentat_broker.for_tests
         ~send:(fun ~origin:_ ~target:_ ~id:_ ~input:_ -> `Delivered)
         ())
    ~broker_engine:
      {
        Mentat_broker.Engine.root = Lpath.Abs.of_string_exn (Sys.getcwd ());
        environment = [];
        integrate_child = (fun ~child:_ -> `Unbound);
        fail_child = (fun ~child:_ ~message:_ -> ());
      }
    ~execution_for_mode ~delegated_execution ()

let prompt ~session ~turn text =
  match
    Protocol.Command.prompt ~session ~turn ~input:[ Llm.Content.text text ] ()
  with
  | Ok c -> c
  | Error e ->
      Format.kasprintf failwith "prompt: %s"
        (Protocol.Command.Invalid.message e)

let is_assistant_delta = function
  | Protocol.Update.Progress
      (Protocol.Progress.Model
         { update = Protocol.Progress.Model.Assistant_delta _; _ }) ->
      true
  | _ -> false

(* The engine's provider is created once; each turn swaps in its own stub through
   this ref so the stub can close over that turn's [t0]. *)
let provider_ref :
    (Llm.Request.t ->
    on_event:(Llm.Event.t -> unit) ->
    on_download:(Protocol.Progress.Model_download.t -> unit) ->
    cancelled:(unit -> bool) ->
    (Llm.Response.t, Llm.Error.t) result)
    ref =
  ref (fun _ ~on_event:_ ~on_download:_ ~cancelled:_ ->
      Ok (plain_response "unset"))

(* Install a per-turn provider stub that stamps [t0] the instant it is called and
   streams one assistant delta. Returns the [t0] ref the caller reads after. *)
let install_provider () =
  let t0 = ref nan in
  (provider_ref :=
     fun _request ~on_event ~on_download:_ ~cancelled:_ ->
       t0 := monotonic ();
       on_event (Llm.Event.text_delta "hi");
       Ok (plain_response "hi"));
  t0

(* Submit [turn] and time the two spans to the first streamed delta: submit ->
   provider-call (admission: fence, load/replay, recover, Turn_started commit)
   and provider-t0 -> first Assistant_delta (the delta crossing to the feed). *)
let submit_and_time ~client ~feed ~sid ~turn =
  let t0 = install_provider () in
  let t_submit = monotonic () in
  (match
     Client.submit client
       (prompt ~session:sid ~turn:(Session.Turn.Id.of_string turn) "go")
   with
  | Ok () -> ()
  | Error e -> Format.kasprintf failwith "submit: %a" Protocol.Error.pp e);
  let rec drain () =
    match Client.Feed.next feed with
    | Error e -> Format.kasprintf failwith "feed: %a" Protocol.Error.pp e
    | Ok Client.Feed.Closed -> failwith "feed closed before first delta"
    | Ok (Client.Feed.Item update) ->
        if is_assistant_delta update then monotonic () else drain ()
  in
  let t_delta = drain () in
  (!t0 -. t_submit, t_delta -. !t0)

(* Pull to the turn's terminal settlement so the next turn admits at an idle
   controller. *)
let drain_to_settled feed =
  let rec loop () =
    match Client.Feed.next feed with
    | Error e -> Format.kasprintf failwith "feed: %a" Protocol.Error.pp e
    | Ok Client.Feed.Closed -> ()
    | Ok (Client.Feed.Item (Protocol.Update.Committed { fact; _ }))
      when match fact with Protocol.Fact.Turn_settled _ -> true | _ -> false ->
        ()
    | Ok (Client.Feed.Item _) -> loop ()
  in
  loop ()

(* One fresh session of [events] events driven through two turns: the first is
   COLD (the driver attaches — load and replay the whole journal), the second is
   WARM (the driver is attached, its head cached). The contrast isolates the
   resume-replay cost from the steady per-turn cost. Returns [(cold, warm)] span
   pairs, each [(submit->provider, provider->delta)] in seconds. *)
let session_run ~sw ~client ~store ~serial ~events =
  let id = Printf.sprintf "s-%d" serial in
  seed_session store ~id ~events;
  let sid = Session.Id.of_string id in
  let feed =
    match Client.follow_session ~sw client sid ~from:`Now with
    | Ok feed -> feed
    | Error e -> Format.kasprintf failwith "follow: %a" Protocol.Error.pp e
  in
  let cold = submit_and_time ~client ~feed ~sid ~turn:"t-0" in
  drain_to_settled feed;
  let warm = submit_and_time ~client ~feed ~sid ~turn:"t-1" in
  drain_to_settled feed;
  Client.Feed.close feed;
  (cold, warm)

let median xs =
  let a = Array.of_list xs in
  Array.sort Float.compare a;
  let n = Array.length a in
  if n = 0 then nan
  else if n land 1 = 1 then a.(n / 2)
  else (a.((n / 2) - 1) +. a.(n / 2)) /. 2.

let ms x = median x *. 1e3

let () =
  let sizes = Fixture.event_sizes in
  let warmup = 2 and samples = 6 in
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store ~sw ~fs () in
  let engine =
    mk_engine ~sw ~store
      ~provider:(fun request ~on_event ~on_download ~cancelled ->
        !provider_ref request ~on_event ~on_download ~cancelled)
  in
  let client = make_client engine in
  let serial = ref 0 in
  Printf.printf
    "engine-latency (submit -> first assistant delta, ms; cold = first turn / \
     driver attach, warm = steady turn):\n";
  List.iter
    (fun (label, events) ->
      let cold_sp = ref [] and cold_pd = ref [] in
      let warm_sp = ref [] and warm_pd = ref [] in
      for i = 0 to warmup + samples - 1 do
        incr serial;
        let (c_sp, c_pd), (w_sp, w_pd) =
          session_run ~sw ~client ~store ~serial:!serial ~events
        in
        if i >= warmup then begin
          cold_sp := c_sp :: !cold_sp;
          cold_pd := c_pd :: !cold_pd;
          warm_sp := w_sp :: !warm_sp;
          warm_pd := w_pd :: !warm_pd
        end
      done;
      Printf.printf
        "  %-4s events  cold: submit->provider %.3f + provider->delta %.3f = \
         %.3f ms | warm: %.3f + %.3f = %.3f ms\n"
        label (ms !cold_sp) (ms !cold_pd)
        (ms !cold_sp +. ms !cold_pd)
        (ms !warm_sp) (ms !warm_pd)
        (ms !warm_sp +. ms !warm_pd))
    sizes;
  Agent.shutdown engine
