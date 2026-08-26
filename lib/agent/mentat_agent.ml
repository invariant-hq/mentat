(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Catalog = Mentat_agent_step.Catalog
module Config = Config
module Ports = Ports
module Execution = Execution
module Error = Error

type t = {
  sw : Eio.Switch.t;
  store : (module Ports.STORE);
  provider : Ports.provider_call;
  config :
    Mentat_session.Id.t ->
    latest_model:Mentat_llm.Model.t option ->
    (Config.t, Mentat_diagnostic.t) result;
  now : unit -> Mentat_session.Time.t;
  execution_for_mode : Execution.factory;
  delegated_execution : Execution.delegated_factory;
  child_backend : Ports.child_backend;
  scheduler : Scheduler.t;
  drivers : (string, Driver.t) Hashtbl.t;
  hubs : (string, Feed.Hub.t) Hashtbl.t;
      (* One feed hub per observed session: observation subscribes to it
         fence-free and the driver publishes to it, so a feed opened before this
         process drives the session transitions to live tailing at attach. An
         entry is retained while its session's driver is attached or a feed is
         open on it, and released when both cease (see [release_hub_if_idle]), so
         a long-lived process holds hubs only for the sessions it currently
         drives or observes. *)
  mutable shutting_down : bool;
}

(* The cross-backend mint rule for a delegated child's first turn: every
   backend derives the same turn id from the delegation id alone, so a crash
   re-drive or a re-materialization resubmits the same turn and the
   byte-identical prompt is idempotent. *)
let child_first_turn delegation =
  Mentat_session.Turn.Id.of_string
    (Mentat_digest.key ~length:20 ~domain:"mentat.agent.child-turn.v1"
       [ Mentat_session.Delegation.Id.to_string delegation ])

let create ~sw ~store ~provider ~config ~now ?(max_children = 4)
    ?(child_backend = Ports.In_process) ~execution_for_mode ~delegated_execution
    () =
  {
    sw;
    store;
    provider;
    config;
    now;
    execution_for_mode;
    delegated_execution;
    child_backend;
    scheduler = Scheduler.create ~capacity:max_children;
    drivers = Hashtbl.create 8;
    hubs = Hashtbl.create 8;
    shutting_down = false;
  }

let key id = Mentat_session.Id.to_string id
let find_driver t id = Hashtbl.find_opt t.drivers (key id)

(* The runtime owns one feed hub per observed session: observation and the
   session's driver share it. [hub_for] finds the session's hub and catches its
   materialized projection up to the freshly-loaded head, or creates and
   registers one. The journal is append-only and the runtime is single-domain,
   so the head is monotone under both the observation-follow and driver-attach
   sites: a hub adopted at attach serves the fenced-load head, and a repeat
   follow refreshes a hub another process may have advanced.

   The refresh runs only for a hub with no attached driver. A driven session's
   hub is kept current by the driver's own per-commit publishes, so re-folding a
   freshly loaded head into it would be redundant — and unsafe: a commit is
   durable in the store before the driver publishes it, so a concurrent follow's
   fresh load could observe those events and, syncing them in, race the driver's
   pending publish into double-materializing them. [attach] runs this before it
   registers the driver and only when none is attached, so a hub adopted at
   attach is still caught up to the fenced-load head. *)
let hub_for t id ~session ~mutation =
  match Hashtbl.find_opt t.hubs (key id) with
  | Some hub ->
      if not (Hashtbl.mem t.drivers (key id)) then
        Feed.Hub.sync hub session mutation;
      hub
  | None ->
      let hub = Feed.Hub.create ~session ~mutation in
      Hashtbl.replace t.hubs (key id) hub;
      hub

(* Hub retention. A hub entry is retained while its session's driver is attached
   ([Hashtbl.mem t.drivers], the authoritative attachment fact, not a copy of it)
   or a feed is open on it; when both cease the entry holds nothing but a pure
   re-projection of the journal, so it is dropped and a later follow rebuilds a
   byte-identical head by folding the same journal. [release_hub_if_idle] is the
   sole release site: called after a feed closes, it drops the registered hub
   only when it is exactly [hub], now feedless, with no attached driver — so a
   driven session's hub, and any still-open feed's progress ring, are never
   touched. Single-domain scheduling makes the close-then-check atomic against a
   concurrent follow: a feed that subscribes before the check keeps the hub
   non-feedless, and one that subscribes after finds the entry already gone and
   creates a fresh, equivalent hub. *)
let release_hub_if_idle t id hub =
  if Feed.Hub.feedless hub && not (Hashtbl.mem t.drivers (key id)) then
    match Hashtbl.find_opt t.hubs (key id) with
    | Some registered when registered == hub -> Hashtbl.remove t.hubs (key id)
    | Some _ | None -> ()

let retained_hub_count t = Hashtbl.length t.hubs

(* Child settlement derivation.

   A settled child's final result and usage derive from the child journal —
   the single source of truth. *)

let child_result session turn outcome =
  let state = Mentat_session.state session in
  let text =
    match Mentat_session.State.turn_final_text turn state with
    | Some text when not (String.equal (String.trim text) "") -> text
    | Some _ | None ->
        Format.asprintf "(no output; turn %a)" Mentat_session.Turn.Outcome.pp
          outcome
  in
  let usage = (Mentat_session.metrics session).Mentat_session.Metrics.usage in
  ([ Mentat_llm.Content.text text ], Some usage)

(* The one settled-child judgment: the journal's settled head projected into
   the parent's result. Recovery's rebuild and the broker's integration both
   consume it, so "what did the child conclude" has a single home; [None]
   means work is (or must be presumed) outstanding. *)
let settled_result child_session =
  match
    Mentat_session.State.settled_head (Mentat_session.state child_session)
  with
  | None -> None
  | Some (last, outcome) ->
      let turn = Mentat_session.Turn.id last in
      let outcome =
        Option.value outcome
          ~default:
            (Mentat_session.Turn.Outcome.failed ~message:"child outcome unknown")
      in
      Some (child_result child_session turn outcome)

(* The one settlement tail every wake shares: buffer the result, return the
   capacity permit, and nudge the parent's parked wait. The parent driver may
   be absent (its process half is elsewhere, or it has shut down) — the buffered
   result then waits for its next attach, whose recovery rebuild re-derives it
   from the child journal anyway. *)
let settle_delegation t ~parent ~delegation result =
  Scheduler.note_settled t.scheduler delegation result;
  Scheduler.release t.scheduler ~delegation;
  match find_driver t parent with
  | Some parent_driver -> Driver.deliver parent_driver
  | None -> ()

let on_turn_settled t ~session ~turn outcome =
  match Scheduler.parent_of t.scheduler session with
  | None -> ()
  | Some (parent, delegation) -> (
      match find_driver t session with
      | Some driver ->
          let head = Feed.Hub.head (Driver.hub driver) in
          settle_delegation t ~parent ~delegation
            (child_result head turn outcome)
      | None ->
          (* The settling driver is unregistered (a shutdown race): release the
             permit and nudge the parent; the result re-derives from the child
             journal at the parent's next rebuild. *)
          Scheduler.release t.scheduler ~delegation;
          (match find_driver t parent with
          | Some parent_driver -> Driver.deliver parent_driver
          | None -> ()))

(* The delivery idempotency key: stable across re-drives because it derives
   from the recording turn and call, never from time or sequence. *)
let derived_message_id (message : Mentat_agent_step.Step.Child_message.t) =
  Mentat_digest.key ~length:20 ~domain:"mentat.agent.child-message.v1"
    [
      Mentat_session.Turn.Id.to_string
        message.Mentat_agent_step.Step.Child_message.turn;
      message.Mentat_agent_step.Step.Child_message.call_id;
    ]

(* Attachment. *)

let rec attach t id =
  match find_driver t id with
  | Some driver -> Ok driver
  | None -> (
      let module S = (val t.store : Ports.STORE) in
      (* Resolves the delegation depth and this child's own role. The role is
         read from the immediate edge (the one whose child is [child] at this
         level); the recursive parent role is not this child's and is
         discarded. A root session has no lineage and no role. *)
      let rec resolve_lineage ~seen ~child session =
        match
          Mentat_session.Metadata.delegated_from
            (Mentat_session.metadata session)
        with
        | None -> Ok (0, None)
        | Some lineage -> (
            let parent =
              Mentat_session.Metadata.Delegated_from.parent lineage
            in
            let delegation =
              Mentat_session.Metadata.Delegated_from.delegation lineage
            in
            if List.exists (Mentat_session.Id.equal parent) seen then
              Error (Error.Delegation (Error.Delegation.Cycle parent))
            else
              match S.view parent with
              | Error Ports.Store_error.Not_found ->
                  Error
                    (Error.Delegation (Error.Delegation.Parent_not_found parent))
              | Error e -> Error (Error.Store e)
              | Ok loaded -> (
                  let parent_session = S.session_of loaded in
                  let edge =
                    List.find_opt
                      (fun edge ->
                        Mentat_session.Delegation.Id.equal
                          (Mentat_session.Delegation.id edge)
                          delegation)
                      (Mentat_session.State.delegations
                         (Mentat_session.state parent_session))
                  in
                  match edge with
                  | None ->
                      Error
                        (Error.Delegation
                           (Error.Delegation.Edge_not_found
                              { parent; delegation }))
                  | Some edge -> (
                      let found = Mentat_session.Delegation.child edge in
                      if not (Mentat_session.Id.equal found child) then
                        Error
                          (Error.Delegation
                             (Error.Delegation.Child_mismatch
                                { delegation; expected = child; found }))
                      else
                        match
                          resolve_lineage ~seen:(parent :: seen) ~child:parent
                            parent_session
                        with
                        | Error _ as error -> error
                        | Ok (parent_depth, _parent_role) ->
                            Ok
                              ( parent_depth + 1,
                                Mentat_session.Delegation.role edge ))))
      in
      match S.try_acquire id with
      | `Held owner -> Error (Error.Busy { owner })
      | `Io d -> Error (Error.Store (Ports.Store_error.Io d))
      | `Acquired guard -> (
          let release_and e =
            S.release guard;
            Error e
          in
          match S.load guard with
          | Error e -> release_and (Error.Store e)
          | Ok loaded -> (
              match S.mutation_events loaded with
              | Error e -> release_and (Error.Store e)
              | Ok mutation_events -> (
                  match Mentat_mutation.State.of_events mutation_events with
                  | Error e ->
                      release_and
                        (Error.Internal
                           (Mentat_diagnostic.of_text
                              (Mentat_mutation.State.Error.message e)))
                  | Ok mutation -> (
                      let session = S.session_of loaded in
                      match resolve_lineage ~seen:[ id ] ~child:id session with
                      | Error e -> release_and e
                      | Ok (depth, role) ->
                          (* A child drives through [delegated_execution]; its
                             immutable role is closed in here so the driver's
                             generic execution signature stays role-free and the
                             child's prelude re-resolves the same role from the
                             durable edge on every attach. Both factories share
                             the [~background] contract: the delegated factory
                             opens a per-child shell registry over the driver's
                             nested switch (for a generic delegate's write/shell
                             parity) exactly as the root factory does, so its
                             background-process view is live rather than forced
                             empty. *)
                          let execution_for_mode =
                            if Int.equal depth 0 then t.execution_for_mode
                            else fun ~background:session_sw ->
                              t.delegated_execution ~role ~background:session_sw
                          in
                          (* Rebuild reservations and settled buffers from child
                             journals, and re-drive undelivered recorded
                             messages, BEFORE this driver drives. *)
                          rebuild_children t ~parent:id session;
                          redrive_messages t session;
                          let doc = ref loaded in
                          let io =
                            {
                              Driver.session_id = id;
                              commit =
                                (fun events ->
                                  match S.commit guard !doc events with
                                  | Error e -> Error e
                                  | Ok loaded ->
                                      doc := loaded;
                                      Ok (S.session_of loaded));
                              commit_metadata =
                                (fun session ->
                                  match
                                    S.commit_metadata guard !doc session
                                  with
                                  | Error e -> Error e
                                  | Ok loaded ->
                                      (* Adopt the new revision so the next
                                         journal commit CASes against it. *)
                                      doc := loaded;
                                      Ok (S.session_of loaded));
                              append_edit =
                                (fun ~entries event ->
                                  S.append_edit guard !doc ~entries event);
                              append_mutation =
                                (fun events ->
                                  S.append_mutation guard !doc events);
                              put_attachment =
                                (fun bytes -> S.put_attachment id bytes);
                              attachment =
                                (fun reference -> S.attachment id reference);
                              fork =
                                (fun ~events session ->
                                  Result.map
                                    (fun _loaded -> ())
                                    (S.fork ~from:id ~events session));
                              revert =
                                (fun ~scope ->
                                  match S.revert guard !doc ~scope with
                                  | Error e -> Error e
                                  | Ok outcome -> (
                                      (* Re-read the ledger the revert just
                                         appended to, so the controller adopts a
                                         current mutation mirror. *)
                                      match S.mutation_events !doc with
                                      | Error e -> Error e
                                      | Ok events -> (
                                          match
                                            Mentat_mutation.State.of_events
                                              events
                                          with
                                          | Ok mstate -> Ok (outcome, mstate)
                                          | Error se ->
                                              Error
                                                (Ports.Store_error.Corrupt
                                                   (Mentat_diagnostic.of_text
                                                      (Mentat_mutation.State
                                                       .Error
                                                       .message se))))));
                              undo_revert =
                                (fun selection ->
                                  match
                                    S.revert_selection guard !doc ~selection
                                  with
                                  | Error e -> Error e
                                  | Ok outcome -> (
                                      match S.mutation_events !doc with
                                      | Error e -> Error e
                                      | Ok events -> (
                                          match
                                            Mentat_mutation.State.of_events
                                              events
                                          with
                                          | Ok mstate -> Ok (outcome, mstate)
                                          | Error se ->
                                              Error
                                                (Ports.Store_error.Corrupt
                                                   (Mentat_diagnostic.of_text
                                                      (Mentat_mutation.State
                                                       .Error
                                                       .message se))))));
                              truncate =
                                (fun ~keep session ->
                                  match S.truncate guard !doc ~keep session with
                                  | Error e -> Error e
                                  | Ok (loaded, mstate) ->
                                      doc := loaded;
                                      Ok (S.session_of loaded, mstate));
                              export = (fun () -> S.export guard);
                              release = (fun () -> S.release guard);
                              (* Resolve [`Ref] media back to [`Base64] strictly
                                 after the request is digested and claimed, so
                                 the adapters never see an unresolved reference
                                 and the claim's digest stays over the [`Ref]
                                 form. *)
                              provider_call =
                                (fun request
                                  ~on_event
                                  ~on_download
                                  ~cancelled
                                ->
                                  match
                                    Media.resolve_request
                                      ~attachment:(fun reference ->
                                        S.attachment id reference)
                                      request
                                  with
                                  | Ok request ->
                                      t.provider request ~on_event ~on_download
                                        ~cancelled
                                  | Error media_error ->
                                      let message =
                                        match media_error with
                                        | Media.Rebuild detail ->
                                            "request media could not be \
                                             resolved: " ^ detail
                                        | other -> Media.message other
                                      in
                                      Error
                                        (Mentat_llm.Error.make
                                           ~kind:
                                             Mentat_llm.Error.Invalid_request
                                           ~provider:
                                             (Mentat_llm.Model.provider
                                                (Mentat_llm.Request.model
                                                   request))
                                           message));
                            }
                          in
                          let driver =
                            Driver.create ~sw:t.sw ~io ~hooks:(hooks t ~id)
                              ~resolve:(fun ~latest_model ->
                                t.config id ~latest_model)
                              ~execution_for_mode ~now:t.now ~depth ~session
                              ~mutation
                              ~hub:(hub_for t id ~session ~mutation)
                          in
                          (* Register before starting: hooks fired by the first
                             drive resolve this driver through the registry. *)
                          Hashtbl.replace t.drivers (key id) driver;
                          Driver.start driver;
                          Ok driver)))))

and hooks t ~id =
  {
    Driver.try_reserve =
      (fun reservation ->
        Scheduler.try_reserve t.scheduler
          ~delegation:
            (Mentat_agent_step.Step.Reservation.delegation reservation));
    release_permit =
      (fun ~delegation -> Scheduler.release t.scheduler ~delegation);
    observe_delegation =
      (fun edge ->
        (* Drivers register before starting, so the parent resolves. *)
        match find_driver t id with
        | None -> ()
        | Some driver ->
            let cwd =
              Mentat_session.Metadata.cwd
                (Mentat_session.metadata (Feed.Hub.head (Driver.hub driver)))
            in
            observe_delegation t ~parent:id ~parent_cwd:cwd edge);
    deliver_message =
      (fun message ->
        (* Drivers register before starting, so the parent resolves. *)
        match find_driver t id with
        | None -> ()
        | Some driver ->
            let edges =
              Mentat_session.State.delegations
                (Mentat_session.state (Feed.Hub.head (Driver.hub driver)))
            in
            deliver_child_message t ~edges message);
    settled_children =
      (fun children -> Scheduler.settled_for t.scheduler children);
    cancel_children = (fun children -> cancel_children t ~parent:id children);
    on_turn_settled =
      (fun ~turn outcome -> on_turn_settled t ~session:id ~turn outcome);
  }

(* Idempotent on the parent-minted child id: create the child session if
   absent, then materialize it through the configured backend.
   A child never runs before its edge is durable — this is called only after
   the [Delegation_recorded] commit, or from recovery's re-drive. *)
and observe_delegation t ~parent ~parent_cwd edge =
  let child = Mentat_session.Delegation.child edge in
  let delegation = Mentat_session.Delegation.id edge in
  Scheduler.bind t.scheduler ~child ~parent ~delegation;
  let fail_spawn message =
    (* The child cannot exist; a parked wait must still complete. *)
    settle_delegation t ~parent ~delegation
      ([ Mentat_llm.Content.text ("spawn failed: " ^ message) ], None)
  in
  match ensure_child_session t ~parent ~delegation ~cwd:parent_cwd child with
  | Error e -> fail_spawn (Ports.Store_error.message e)
  | Ok () -> (
      match t.child_backend with
      | Ports.In_process -> materialize_in_process t ~fail_spawn edge
      | Ports.Brokered ops ->
          (* Identity only crosses: the broker re-reads the task and role from
             the durable edge. A child this runtime already drives in-process
             (a message delivery attached it) is skipped — its own driver and
             fence are the materialization, and handing its identity to the
             broker would race a second process against a fence this process
             holds. *)
          if Option.is_none (find_driver t child) then
            ops.Ports.materialize ~child)

(* In-process materialization: attach a child driver as a sibling and submit
   its first turn. The started guard makes a re-drive idempotent — a child
   whose journal already holds a turn is running or settled, never
   re-prompted. *)
and materialize_in_process t ~fail_spawn edge =
  let child = Mentat_session.Delegation.child edge in
  let delegation = Mentat_session.Delegation.id edge in
  match attach t child with
  | Error e -> fail_spawn (Error.message e)
  | Ok driver ->
      let head = Feed.Hub.head (Driver.hub driver) in
      let started =
        Mentat_session.State.turns (Mentat_session.state head) <> []
      in
      if not started then begin
        let turn = child_first_turn delegation in
        let input = Mentat_session.Delegation.task edge in
        match Mentat_protocol.Command.prompt ~session:child ~turn ~input () with
        | Error invalid ->
            fail_spawn (Mentat_protocol.Command.Invalid.message invalid)
        | Ok command ->
            (* Eager drive; never on the parent's controller fiber. *)
            Eio.Fiber.fork ~sw:t.sw (fun () ->
                ignore (Driver.submit driver command))
      end

and ensure_child_session t ~parent ~delegation ~cwd child =
  let module S = (val t.store : Ports.STORE) in
  match S.view child with
  | Ok _ -> Ok ()
  | Error Ports.Store_error.Not_found -> (
      let session =
        let delegated_from =
          Mentat_session.Metadata.Delegated_from.make ~parent ~delegation
        in
        Mentat_session.create ~id:child ~delegated_from ~cwd
          ~created_at:(t.now ()) ()
      in
      match S.create session with
      | Ok _ | Error Ports.Store_error.Conflict -> Ok ()
      | Error e -> Error e)
  | Error e -> Error e

(* Recovery: rebuild the permit count and the settled buffer from
   child journals, and re-drive any edge whose child is absent or unfinished. *)
and rebuild_children t ~parent session =
  let module S = (val t.store : Ports.STORE) in
  let cwd = Mentat_session.Metadata.cwd (Mentat_session.metadata session) in
  List.iter
    (fun edge ->
      let child = Mentat_session.Delegation.child edge in
      let delegation = Mentat_session.Delegation.id edge in
      Scheduler.bind t.scheduler ~child ~parent ~delegation;
      let redrive () =
        Scheduler.force_reserve t.scheduler ~delegation;
        observe_delegation t ~parent ~parent_cwd:cwd edge
      in
      match S.view child with
      | Error Ports.Store_error.Not_found -> redrive ()
      | Error _ -> redrive ()
      | Ok loaded -> (
          match settled_result (S.session_of loaded) with
          | None -> redrive ()
          | Some result -> Scheduler.note_settled t.scheduler delegation result))
    (Mentat_session.State.delegations (Mentat_session.state session))

(* Delivery of a recorded parent-to-child message. The idempotency id
   derives from the recording (turn, call): a [`Follow_up] prompts the child
   with a turn of that id — the byte-identical resubmission is [Ok] and a busy
   child falls back to the queue entry — and a [`Context] enqueues a queue
   entry of that id, deduplicated against the child journal's [Enqueued] facts
   (a consumed entry's fact persists; the session's own [Queue.Duplicate]
   rejection covers only the still-pending window). A delivery this leg drops
   is re-driven by the next attach's recovery scan.

   Under [Brokered], a child this runtime does not drive is the broker's
   first: while it holds the child — a live process, or one still booting —
   the message crosses the wire and lands in the running driver, kinds and
   fallbacks exactly as in-process ([`Follow_up] prompts, a refusal parks the
   derived-id queue entry). Only [`Gone] — the broker holds no
   materialization, so the child settled and exited or never crossed the seam
   — falls back to attaching here: the fence is free, and this is the same
   in-process delivery the exit-time and attach-time re-drives perform. An
   attach against a fence some other process holds stays a silent drop, as
   ever covered by the durable receipt. *)
and deliver_child_message t ~edges
    (message : Mentat_agent_step.Step.Child_message.t) =
  let { Mentat_agent_step.Step.Child_message.kind; child; message = text; _ } =
    message
  in
  match
    List.find_opt
      (fun edge ->
        Mentat_session.Delegation.Id.equal
          (Mentat_session.Delegation.id edge)
          child)
      edges
  with
  | None -> ()
  | Some edge -> (
      let child_session = Mentat_session.Delegation.child edge in
      let derived = derived_message_id message in
      let input = [ Mentat_llm.Content.text text ] in
      let deliver_in_process () =
        match attach t child_session with
        | Error _ -> ()
        | Ok driver -> (
            let enqueue () =
              ignore
                (Driver.enqueue driver
                   (Mentat_session.Queue.Entry.make
                      ~id:(Mentat_session.Queue.Id.of_string derived)
                      ~input))
            in
            match kind with
            | `Context -> Eio.Fiber.fork ~sw:t.sw (fun () -> enqueue ())
            | `Follow_up -> (
                match
                  Mentat_protocol.Command.prompt ~session:child_session
                    ~turn:(Mentat_session.Turn.Id.of_string derived)
                    ~input ()
                with
                | Error _ -> ()
                | Ok command ->
                    Eio.Fiber.fork ~sw:t.sw (fun () ->
                        match Driver.submit driver command with
                        | Ok () -> ()
                        | Error _ ->
                            (* The immediate turn did not take: a busy child
                               ([Active_turn_exists]) admits the parked entry at
                               its next idle boundary; a faulted or shutting-down
                               child ([Unavailable]) leaves the parent's durable
                               receipt to re-drive it on the next attach. The
                               receipt already promised delivery, so no submit
                               error may drop the message on the floor. The queue
                               entry carries the same derived id, so this park is
                               idempotent with that recovery. *)
                            enqueue ())))
      in
      match t.child_backend with
      | Ports.In_process -> deliver_in_process ()
      | Ports.Brokered ops ->
          if Option.is_some (find_driver t child_session) then
            deliver_in_process ()
          else
            Eio.Fiber.fork ~sw:t.sw (fun () ->
                let queued () =
                  match
                    Mentat_protocol.Command.queue_next
                      ~id:(Mentat_session.Queue.Id.of_string derived)
                      ~session:child_session ~input ()
                  with
                  | Error _ -> `Refused
                  | Ok command -> ops.Ports.deliver ~command
                in
                let wire =
                  match kind with
                  | `Context -> queued ()
                  | `Follow_up -> (
                      match
                        Mentat_protocol.Command.prompt ~session:child_session
                          ~turn:(Mentat_session.Turn.Id.of_string derived)
                          ~input ()
                      with
                      | Error _ -> `Delivered (* malformed: mirror the drop *)
                      | Ok command -> (
                          match ops.Ports.deliver ~command with
                          | `Refused -> queued ()
                          | (`Delivered | `Gone) as outcome -> outcome))
                in
                match wire with
                | `Delivered | `Refused -> ()
                | `Gone -> deliver_in_process ()))

(* Recovery's message re-drive (the idempotent pattern): a settled receipt
   whose derived id reached neither a child turn nor a child queue fact was
   never delivered — the process died between the receipt commit and the
   routing. Re-drive it; the derived id makes the replay safe. [only] narrows
   the sweep to one delegation edge — the brokered wake re-drives a child's
   messages the moment its process exits and frees the fence, without touching
   its siblings. *)
and redrive_messages ?only t session =
  let module S = (val t.store : Ports.STORE) in
  let edges = Mentat_session.State.delegations (Mentat_session.state session) in
  let relevant (message : Mentat_agent_step.Step.Child_message.t) =
    match only with
    | None -> true
    | Some delegation ->
        Mentat_session.Delegation.Id.equal
          message.Mentat_agent_step.Step.Child_message.child delegation
  in
  List.iter
    (fun (message : Mentat_agent_step.Step.Child_message.t) ->
      if relevant message then begin
        let child_edge =
          List.find_opt
            (fun edge ->
              Mentat_session.Delegation.Id.equal
                (Mentat_session.Delegation.id edge)
                message.Mentat_agent_step.Step.Child_message.child)
            edges
        in
        let delivered =
          match child_edge with
          | None -> true (* no edge: nothing to deliver to *)
          | Some edge -> (
              let derived = derived_message_id message in
              match S.view (Mentat_session.Delegation.child edge) with
              | Error _ -> false
              | Ok loaded ->
                  let child_session = S.session_of loaded in
                  let state = Mentat_session.state child_session in
                  Option.is_some
                    (Mentat_session.State.turn
                       (Mentat_session.Turn.Id.of_string derived)
                       state)
                  || Mentat_session.State.enqueue_recorded
                       (Mentat_session.Queue.Id.of_string derived)
                       state)
        in
        if not delivered then deliver_child_message t ~edges message
      end)
    (Mentat_agent_step.settled_messages session)

(* Semantic cascade: interrupt each named child's driver and await
   its committed terminal fact — never by failing switches across sessions.
   A stuck descendant leaves the cascade visibly pending.

   A brokered child with no sibling driver runs in another process: the cascade
   hands its interrupt to the broker and returns without awaiting quiescence —
   this process has no event for a foreign driver's settlement short of polling
   a clock the engine does not hold, and a wedged foreign child must never
   wedge the parent's own interrupt. Its committed terminal fact arrives
   through the broker's observation and settles into the scheduler buffer as
   any brokered settlement does. *)
and cancel_children t ~parent children =
  let edges =
    match find_driver t parent with
    | None -> []
    | Some driver ->
        Mentat_session.State.delegations
          (Mentat_session.state (Feed.Hub.head (Driver.hub driver)))
  in
  List.iter
    (fun delegation ->
      match
        List.find_opt
          (fun edge ->
            Mentat_session.Delegation.Id.equal
              (Mentat_session.Delegation.id edge)
              delegation)
          edges
      with
      | None -> ()
      | Some edge -> (
          let child = Mentat_session.Delegation.child edge in
          match find_driver t child with
          | None -> (
              match t.child_backend with
              | Ports.In_process -> ()
              | Ports.Brokered ops ->
                  let module S = (val t.store : Ports.STORE) in
                  let active =
                    match S.view child with
                    | Error _ -> false
                    | Ok loaded ->
                        Option.is_some
                          (Mentat_session.State.active_turn
                             (Mentat_session.state (S.session_of loaded)))
                  in
                  if active then ops.Ports.cancel ~child)
          | Some child_driver ->
              let hub = Driver.hub child_driver in
              let quiescent () =
                match
                  Mentat_session.State.active_turn
                    (Mentat_session.state (Feed.Hub.head hub))
                with
                | None -> Some ()
                | Some _ -> None
              in
              (match quiescent () with
              | Some () -> ()
              | None -> (
                  match
                    Mentat_protocol.Command.interrupt ~session:child
                      ~reason:"parent interrupted" ()
                  with
                  | Error _ -> ()
                  | Ok command -> ignore (Driver.submit child_driver command)));
              Feed.Hub.await hub quiescent))
    children

(* The client-facing session driver.

   The engine fills the session half of the client's multi-source construction
   seam. {!driver} returns a {!Mentat_client.Driver.Session.t} whose field
   closures submit commands, follow pull feeds, run the fenced fork/rewind/
   compact flows, and serve the session-scoped queries. Every field returns
   {!Mentat_protocol.Error.t} — the one-error-type law — so a
   frontend holding the assembled client never observes the engine [Error.t] and
   the firewall is a compiler fact. The executable's composition root
   assembles the full {!Mentat_client.Driver.t} from this value plus its own
   account/settings/lifecycle responders. *)

(* Total bridge of the engine {!Error.t} onto {!Mentat_protocol.Error.t}.
   [Busy] carries the session id the engine arm omits and the
   store's rendered owner line verbatim; a store [Not_found] on a session op is
   [Session_not_found]; every remaining report-only failure collapses to
   [Unavailable] over the error's structured diagnostic. The match is exhaustive
   so a new engine arm forces a mapping decision. *)
let protocol_error ~session (e : Error.t) : Mentat_protocol.Error.t =
  match e with
  | Error.Busy { owner } -> Mentat_protocol.Error.Busy { session; owner }
  | Error.Store Ports.Store_error.Not_found ->
      Mentat_protocol.Error.Session_not_found session
  | Error.Store
      ( Ports.Store_error.Conflict | Ports.Store_error.Rejected _
      | Ports.Store_error.Corrupt _ | Ports.Store_error.Io _ )
  | Error.Request _ | Error.Session _ | Error.Decision _ | Error.Configuration _
  | Error.Delegation _ | Error.Internal _ | Error.Shutting_down ->
      Mentat_protocol.Error.Unavailable (Error.diagnostic e)

let route t session =
  if t.shutting_down then Error (protocol_error ~session Error.Shutting_down)
  else Result.map_error (protocol_error ~session) (attach t session)

let adopt t session =
  Result.map (fun (_ : Driver.t) -> ()) (route t session)

(* The brokered observation seam.

   A brokered child's driver lives in another process; what this runtime holds
   is the durable child journal and the parent's scheduler bookkeeping. The
   broker observes the child — its feed, its process exit — and reports here;
   both reports resolve entirely against journals, so a spurious or repeated
   call converges to the same state. *)

let integrate_brokered_child t ~child =
  match Scheduler.parent_of t.scheduler child with
  | None -> `Unbound
  | Some (parent, delegation) -> (
      let module S = (val t.store : Ports.STORE) in
      let head =
        match find_driver t child with
        | Some driver -> Ok (Feed.Hub.head (Driver.hub driver))
        | None -> Result.map S.session_of (S.view child)
      in
      match head with
      | Error _ -> `Not_settled
      | Ok child_session -> (
          match settled_result child_session with
          | None -> `Not_settled
          | Some result ->
              settle_delegation t ~parent ~delegation result;
              (* The child's fence is free once its process exits, so a
                 message its lifetime shadowed is deliverable now; the
                 derived-id dedup makes a repeat sweep harmless. *)
              (match S.view parent with
              | Error _ -> ()
              | Ok loaded ->
                  redrive_messages ~only:delegation t (S.session_of loaded));
              `Integrated))

let fail_brokered_child t ~child ~message =
  match Scheduler.parent_of t.scheduler child with
  | None -> ()
  | Some (parent, delegation) ->
      settle_delegation t ~parent ~delegation
        ([ Mentat_llm.Content.text ("spawn failed: " ^ message) ], None)

let submit t command =
  let session = Mentat_protocol.Command.session command in
  match route t session with
  | Error e -> Error e
  | Ok driver -> Driver.submit driver command

let answer_unattended t ~session ~decision =
  match route t session with
  | Error e -> Error e
  | Ok driver -> Driver.answer_unattended driver ~decision

let possibly_mutating t ~session =
  match find_driver t session with
  | Some driver -> Driver.possibly_mutating driver
  | None -> false

let faulted t ~session =
  match find_driver t session with
  | Some driver -> Driver.faulted driver
  | None -> None

(* A {!Mentat_client.Feed.seam} over one engine feed: the raw pull the
   client's [subscribe] wrapper forwards. The engine feed already implements the
   whole delivery contract — committed-before-progress, bounded drop-oldest
   progress, and an [Ok Closed] outcome after close — and names the
   client's own outcome vocabulary, so the seam is the identity record. *)
let seam_of t id hub feed : Mentat_client.Feed.seam =
  {
    Mentat_client.Feed.next = (fun () -> Feed.next feed);
    close =
      (fun () ->
        Feed.close feed;
        release_hub_if_idle t id hub);
  }

(* The three-case [from] over the engine feed: [`Beginning]
   subscribes the whole journal, [`After] resumes strictly after a delivered
   position, and [`Now] subscribes after the current head so the feed catches up
   nothing and tails only future facts. Membership of a threaded [`After]
   position is [Projection.after]'s alone: a foreign or forged position
   surfaces structurally at the first [next], never re-checked here. *)
let subscribe_from hub ~(from : Mentat_client.Feed.from) =
  match from with
  | `Beginning -> Feed.subscribe hub
  | `After position -> Feed.subscribe ~from:position hub
  | `Now -> (
      match Feed.Hub.head_position hub with
      | Some position -> Feed.subscribe ~from:position hub
      | None -> Feed.subscribe hub)

(* The head projection for a session this process does not drive: a fence-free
   view folded into its session value and mutation state. The driven path reads
   the live hub instead; this is the static snapshot the offline reads share
   (follow, tail, page, change_diff). *)
let head_projection t session =
  let module S = (val t.store : Ports.STORE) in
  match S.view session with
  | Error e -> Error (protocol_error ~session (Error.Store e))
  | Ok loaded -> (
      match S.mutation_events loaded with
      | Error e -> Error (protocol_error ~session (Error.Store e))
      | Ok events -> (
          match Mentat_mutation.State.of_events events with
          | Error e ->
              Error
                (Mentat_protocol.Error.unavailable
                   (Mentat_mutation.State.Error.message e))
          | Ok mutation -> Ok (S.session_of loaded, mutation)))

let follow t session ~(from : Mentat_client.Feed.from) =
  match find_driver t session with
  | Some driver ->
      let hub = Driver.hub driver in
      Ok (seam_of t session hub (subscribe_from hub ~from))
  | None ->
      (* Observation never acquires the fence: it subscribes to the session's
         runtime-owned hub, refreshed here from a fence-free view. The hub has no
         publisher until this process drives the session; when a driver later
         attaches it adopts this same hub, so the feed transitions from a static
         snapshot to live tailing. *)
      Result.bind (head_projection t session) (fun (session_value, mutation) ->
          let hub = hub_for t session ~session:session_value ~mutation in
          Ok (seam_of t session hub (subscribe_from hub ~from)))

let flow t session f =
  if t.shutting_down then Error (protocol_error ~session Error.Shutting_down)
  else
    match attach t session with
    | Error e -> Error (protocol_error ~session e)
    | Ok d -> Result.map_error (protocol_error ~session) (f d)

(* Fork and rewind take the client-minted target id and return [unit]: the
   caller holds the id and may follow it before this returns. *)
let fork t ~session ~into =
  Result.map
    (fun (_ : Mentat_session.Id.t) -> ())
    (flow t session (fun driver -> Driver.fork driver ~id:into))

let rewind t ~session ~into ~anchor =
  Result.map
    (fun (_ : Mentat_session.Id.t) -> ())
    (flow t session (fun driver -> Driver.rewind driver ~id:into ~anchor))

(* Compact takes the caller's client-minted compaction turn id and returns the
   protocol-typed result directly (like {!submit}): the driver already speaks
   {!Mentat_protocol.Error.t} on this flow, so it needs no error re-mapping. *)
let compact t ~session ~turn =
  match route t session with
  | Error e -> Error e
  | Ok driver -> Driver.compact driver ~turn

(* Metadata commit on a session {b this} engine already drives (the online
   lifecycle cone). Uses [find_driver], not [route]: it never attaches on
   demand — a session no live driver holds is [`Not_driven], which the composition
   root falls back to the offline metadata twin for. The commit runs at the
   driver's idle point. *)
let commit_metadata t id ~transform =
  match find_driver t id with
  | None -> `Not_driven
  | Some driver -> `Committed (Driver.commit_metadata driver ~transform)

(* The session value a snapshot query reads: a driven session's live committed
   head, else a fence-free {!Ports.STORE.view}. *)
let head_session t session =
  match find_driver t session with
  | Some driver -> Ok (Feed.Hub.head (Driver.hub driver))
  | None ->
      let module S = (val t.store : Ports.STORE) in
      Result.map_error
        (fun e -> protocol_error ~session (Error.Store e))
        (Result.map S.session_of (S.view session))

let pending_of session =
  match Mentat_session.State.suspension (Mentat_session.state session) with
  | Some (Mentat_session.State.Decision requested) -> Some requested
  | Some (Mentat_session.State.Provider _ | Mentat_session.State.Tool _) | None
    ->
      None

let pending_decision t session = Result.map pending_of (head_session t session)

(* Clamp a requested page size to [[1, max_n]], defaulting an omitted one — the
   page-size cap the responder owns, keeping a bounded read bounded. *)
let clamp_page n =
  let open Mentat_protocol.Transcript in
  match n with
  | None -> Tail.default_n
  | Some k -> if k < 1 then 1 else if k > Tail.max_n then Tail.max_n else k

let tail t ?n session =
  let n = clamp_page n in
  match find_driver t session with
  | Some driver ->
      let hub = Driver.hub driver in
      Ok
        (Mentat_protocol.Transcript.Tail.of_projection
           ~length:(Feed.Hub.projected_length hub)
           ~get:(Feed.Hub.projected_entry hub)
           ~n
           ~pending:(pending_of (Feed.Hub.head hub)))
  | None ->
      Result.map
        (fun (loaded, mutation) ->
          let arr =
            Array.of_list
              (Mentat_protocol.Projection.all ~session:loaded ~mutation)
          in
          Mentat_protocol.Transcript.Tail.of_projection
            ~length:(Array.length arr) ~get:(Array.get arr) ~n
            ~pending:(pending_of loaded))
        (head_projection t session)

let page t ?n session ~before =
  let n = clamp_page n in
  let slice ~length ~get =
    match before with
    | None -> Ok (Mentat_protocol.Transcript.Page.recent ~length ~get ~n)
    | Some p ->
        Result.map_error
          (fun invalid -> Mentat_protocol.Error.Invalid_position invalid)
          (Mentat_protocol.Transcript.Page.before ~owner:session ~length ~get p
             ~n)
  in
  match find_driver t session with
  | Some driver ->
      let hub = Driver.hub driver in
      slice
        ~length:(Feed.Hub.projected_length hub)
        ~get:(Feed.Hub.projected_entry hub)
  | None ->
      Result.bind (head_projection t session) (fun (loaded, mutation) ->
          let arr =
            Array.of_list
              (Mentat_protocol.Projection.all ~session:loaded ~mutation)
          in
          slice ~length:(Array.length arr) ~get:(Array.get arr))

let change_diff t ~session ~change =
  let module S = (val t.store : Ports.STORE) in
  Result.bind (head_projection t session) (fun (_loaded, mutation) ->
      match Mentat_mutation.State.change mutation change with
      | None ->
          Error
            (Mentat_protocol.Error.unavailable
               (Printf.sprintf "no recorded change %s"
                  (Mentat_mutation.Change.Id.to_string change)))
      | Some row -> (
          let blob ref =
            match S.blob session ref with Ok bytes -> bytes | Error _ -> None
          in
          match Mentat_mutation.Change.hunks ~blob row with
          | Ok hunks -> Ok hunks
          | Error err ->
              Error
                (Mentat_protocol.Error.unavailable
                   (Format.asprintf "%a" Mentat_mutation.Change.Hunks_error.pp
                      err))))

(* The online revert cone: [route] attaches on demand when this process is
   the one that should drive the session — exactly as {!compact} — and the driver
   runs the fenced revert at its idle point. *)
let revert t ~session ~scope =
  match route t session with
  | Error e -> Error e
  | Ok driver -> Driver.revert driver ~scope

(* The online undo cone: [route] attaches on demand, exactly as {!revert},
   and the driver runs one fenced undo step at its idle point. *)
let undo t ~session ~op =
  let op =
    match op with
    | `Undo -> Driver.Undo
    | `Redo -> Driver.Redo
    | `Cancel -> Driver.Cancel
  in
  match route t session with
  | Error e -> Error e
  | Ok driver -> Driver.undo driver ~op

(* The buffered export is bounded: a bundle past this ceiling is refused rather
   than materialized whole over the wire, naming the offline streaming path. The
   cap is a generous single-session limit — a session whose NDJSON bundle exceeds
   64 MiB is pathological for an in-memory response, and the streaming lane
   remains a named future rather than a third wire endpoint. *)
let export_max_bytes = 64 * 1024 * 1024

let export t ~session =
  match route t session with
  | Error e -> Error e
  | Ok driver -> (
      match Driver.export driver with
      | Error _ as e -> e
      | Ok bundle ->
          if String.length bundle > export_max_bytes then
            Error
              (Mentat_protocol.Error.unavailable
                 "session export exceeds the in-memory bundle limit; stream it \
                  offline instead")
          else Ok bundle)

(* A session's live background-process view: this process's driver projects its
   ephemeral registry on demand; a session this process does not drive has no
   live registry here, so the honest answer is the empty view (nothing is
   persisted to fold). *)
let running_processes t session =
  match find_driver t session with
  | Some driver -> Ok (Driver.running_processes driver)
  | None -> Ok []

let driver t : Mentat_client.Driver.Session.t =
  {
    Mentat_client.Driver.Session.submit = (fun command -> submit t command);
    running_processes = (fun session -> running_processes t session);
    follow = (fun session ~from -> follow t session ~from);
    answer_unattended =
      (fun ~session ~decision -> answer_unattended t ~session ~decision);
    possibly_mutating = (fun ~session -> possibly_mutating t ~session);
    faulted = (fun ~session -> faulted t ~session);
    fork = (fun ~session ~into -> fork t ~session ~into);
    rewind = (fun ~session ~into ~anchor -> rewind t ~session ~into ~anchor);
    compact = (fun ~session ~turn -> compact t ~session ~turn);
    pending_decision = (fun session -> pending_decision t session);
    change_diff = (fun ~session ~change -> change_diff t ~session ~change);
    tail = (fun ?n session -> tail t ?n session);
    page = (fun ?n session ~before -> page t ?n session ~before);
    revert = (fun ~session ~scope -> revert t ~session ~scope);
    undo = (fun ~session ~op -> undo t ~session ~op);
    export = (fun ~session -> export t ~session);
  }

let shutdown t =
  t.shutting_down <- true;
  let drivers = Hashtbl.fold (fun _ driver acc -> driver :: acc) t.drivers [] in
  (* Close the drivers concurrently: [Driver.close] blocks until its driver
     quiesces, so a sequential close would let one driver stuck on a
     cancellation-ignoring callback keep every other driver from being
     asked to stop — leaking their fences. Forked closes let the independent
     drivers quiesce and release regardless; [Fiber.all] still joins them all,
     preserving "returns once every driver is quiescent." *)
  Eio.Fiber.all (List.map (fun driver () -> Driver.close driver) drivers);
  Hashtbl.reset t.drivers;
  (* Feeds hold their hub directly, so resetting the registry strands nothing:
     a still-open feed keeps serving its now-detached hub until switch teardown
     closes it, and that late close finds no registry entry to release. *)
  Hashtbl.reset t.hubs
