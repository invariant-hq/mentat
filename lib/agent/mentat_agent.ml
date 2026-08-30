(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Catalog = Mentat_agent_step.Catalog
module Config = Config
module Ports = Ports
module Execution = Execution
module Error = Error

(* One delivery lane per (sender, target) pair — a delegation edge downward,
   or the sender's lineage upward: the in-order queue of recorded messages
   one fiber drains, so two messages to one target can never race each other
   across the fence or the wire — per-sender FIFO is a structure, not a
   hope. A registered lane always has a live drain fiber; the fiber removes
   the lane in the same non-suspending step that finds the queue empty, so a
   later message finds no lane and starts a fresh one. *)
type lane_target =
  | To_child of Mentat_session.Delegation.t
  | To_parent of Mentat_session.Id.t

type lane = {
  lane_key : string;
  sender : Mentat_session.Id.t;
  target : lane_target;
  pending : Mentat_agent_step.Step.Mail.t Queue.t;
}

let lane_session lane =
  match lane.target with
  | To_child edge -> Mentat_session.Delegation.child edge
  | To_parent parent -> parent

type t = {
  sw : Eio.Switch.t;
  store : Mentat_store.t;
  owner : Mentat_store.Run_lock.Owner.t;
  provider : Ports.provider_call;
  config :
    Mentat_session.Id.t ->
    latest_model:Mentat_llm.Model.t option ->
    (Config.t, Mentat_diagnostic.t) result;
  now : unit -> Mentat_session.Time.t;
  merge : bool;
  revert_observe : Mentat_workspace.Path.t -> Mentat_edit.Observed.t;
  revert_checkpoint :
    boundary:Mentat_mutation.Checkpoint.boundary -> Mentat_mutation.Checkpoint.t;
  revert_apply :
    Mentat_edit.t -> (Mentat_edit.Result.t, Mentat_edit.Apply_error.t) result;
  revert_new_id : unit -> Mentat_mutation.Revert.Id.t;
  execution_for_mode : Execution.factory;
  delegated_execution : Execution.delegated_factory;
  broker : Mentat_broker.t;
  broker_engine : Mentat_broker.Engine.t;
      (* This runtime, as its broker reaches back into it: the workspace
         identity a child is spawned and dialed under, and the wrappers a
         brokered observation reports through. Handed at creation by the
         composition that owns both halves. *)
  scheduler : Scheduler.t;
  drivers : (string, Driver.t) Hashtbl.t;
  lanes : (string, lane) Hashtbl.t;
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

(* The cross-process mint rule for a delegated child's first turn: every
   minter — the child's own serve boot, a crash re-drive — derives the same
   turn id from the delegation id alone, so a re-materialization resubmits
   the same turn and the byte-identical prompt is idempotent. *)
let child_first_turn delegation =
  Mentat_session.Turn.Id.of_string
    (Mentat_digest.key ~length:20 ~domain:"mentat.agent.child-turn.v1"
       [ Mentat_session.Delegation.Id.to_string delegation ])

let create ~sw ~store ~owner ~provider ~config ~now ~merge ~revert_observe
    ~revert_checkpoint ~revert_apply ~revert_new_id ?(max_children = 4) ~broker
    ~broker_engine ~execution_for_mode ~delegated_execution () =
  {
    sw;
    store;
    owner;
    provider;
    config;
    now;
    merge;
    revert_observe;
    revert_checkpoint;
    revert_apply;
    revert_new_id;
    execution_for_mode;
    delegated_execution;
    broker;
    broker_engine;
    scheduler = Scheduler.create ~capacity:max_children;
    drivers = Hashtbl.create 8;
    lanes = Hashtbl.create 8;
    hubs = Hashtbl.create 8;
    shutting_down = false;
  }

let key id = Mentat_session.Id.to_string id
let find_driver t id = Hashtbl.find_opt t.drivers (key id)

(* The engine-private store-error classification. The engine links the store
   directly, so each domain's errors are classified where they surface: a
   session-document not-found is the engine's [Not_found]; every other arm —
   a session [Locked] (unreachable on the fenced paths: the engine holds the
   fence), a CAS [Conflict] under the fence (a fence violation or an engine
   bug — a fault, never a silent retry), corrupt data, IO — folds into
   [Error.Store] carrying the store's own diagnostic whole. *)
let session_store_error (e : Mentat_store.Session.Error.t) : Error.t =
  match e with
  | Mentat_store.Session.Error.Not_found _ -> Error.Not_found
  | Mentat_store.Session.Error.Already_exists _
  | Mentat_store.Session.Error.Conflict _ | Mentat_store.Session.Error.Locked _
  | Mentat_store.Session.Error.Corrupt _ | Mentat_store.Session.Error.Io _ ->
      Error.Store (Mentat_store.Session.Error.diagnostic e)

(* Mutation errors — decode damage, replay rejection, correlation, blob
   integrity, a nested document failure, IO — are all report-only faults at the
   engine's altitude; the located diagnostic crosses whole. *)
let mutation_error ~session (e : Mentat_store.Mutation.Error.t) : Error.t =
  Error.Store (Mentat_store.Mutation.Error.diagnostic ~session e)

(* The attachment namespace is fence-free like the capture store: an attach
   happens before the run fence exists ([-i]) or with no active turn (TUI).
   Integrity and IO failures alike surface as the store's diagnostic — the
   currency of the media seam. *)
let attachment_error ~session (e : Mentat_store.Attachment.Error.t) :
    Mentat_diagnostic.t =
  Mentat_store.Attachment.Error.diagnostic ~session e

(* The one commit composition, engine-owned: stamp [updated_at] from the
   injected clock, then CAS-save under the held fence — and for a journal
   commit, first fold the suffix through the session's checked append. A
   refused append is [Error.Session]: a step or driver bug, surfaced loudly. *)
let commit_stamped t guard doc session =
  Result.map_error session_store_error
    (Mentat_store.Session.commit t.store ~fence:guard doc
       (Mentat_session.touch (t.now ()) session))

let commit_events t guard doc events =
  match
    Mentat_session.append_all events (Mentat_store.Session.Document.session doc)
  with
  | Error e -> Error (Error.Session e)
  | Ok appended -> commit_stamped t guard doc appended

(* The wire outcome the online cones carry: the store keeps the refusal
   structured, so the engine projects it to the string-valued [Refused] here —
   the offline twin instead reads the structured problems for its consent
   surface. *)
let outcome_of_store : Mentat_store.Mutation.revert_outcome ->
    Mentat_mutation.Revert.Outcome.t = function
  | Mentat_store.Mutation.Nothing_to_revert ->
      Mentat_mutation.Revert.Outcome.Nothing_to_revert
  | Mentat_store.Mutation.Refused problems ->
      Mentat_mutation.Revert.Outcome.Refused
        (List.map Mentat_mutation.Revert.Problem.message problems)
  | Mentat_store.Mutation.Applied settled ->
      Mentat_mutation.Revert.Outcome.Applied settled

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
   means work is (or must be presumed) outstanding, gated on the state's own
   {!Mentat_session.State.finished} — a settled head with unconsumed mail is
   not finished, the mail buys the child another turn, so the delegation must
   not settle against the pre-mail result. *)
let settled_result child_session =
  let state = Mentat_session.state child_session in
  if not (Mentat_session.State.finished state) then None
  else
    match Mentat_session.State.settled_head state with
    | None -> None
    | Some (last, outcome) ->
        let turn = Mentat_session.Turn.id last in
        let outcome =
          Option.value outcome
            ~default:
              (Mentat_session.Turn.Outcome.failed
                 ~message:"child outcome unknown")
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
   from the recording turn and call, never from time or sequence. The domain
   predates the parent target and deliberately stays: a pre-existing
   journal's receipts redrive through the new path under the same ids. *)
let derived_message_id (message : Mentat_agent_step.Step.Mail.t) =
  Mentat_digest.key ~length:20 ~domain:"mentat.agent.child-message.v1"
    [
      Mentat_session.Turn.Id.to_string message.Mentat_agent_step.Step.Mail.turn;
      message.Mentat_agent_step.Step.Mail.call_id;
    ]

(* Attachment. A shutting-down runtime attaches nothing — the guard lives
   here, not only at the protocol boundary, so the internal wakers are
   covered too: a delivery fiber that outlives [shutdown] must not register
   a driver whose controller nothing will ever stop, pinning the runtime
   switch forever. *)

let rec attach t id =
  if t.shutting_down then Error Error.Shutting_down
  else
    match find_driver t id with
    | Some driver -> Ok driver
    | None -> (
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
                match Mentat_store.Session.load t.store parent with
                | Error (Mentat_store.Session.Error.Not_found _) ->
                    Error
                      (Error.Delegation (Error.Delegation.Parent_not_found parent))
                | Error e -> Error (session_store_error e)
                | Ok loaded -> (
                    let parent_session =
                      Mentat_store.Session.Document.session loaded
                    in
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
        match
          Mentat_store.Run_lock.try_acquire ~sw:t.sw t.store ~session:id
            ~owner:t.owner
        with
        | Error (`Held holder) ->
            let owner =
              Option.map
                (fun o -> Format.asprintf "%a" Mentat_store.Run_lock.Owner.pp o)
                holder
            in
            Error (Error.Busy { owner })
        | Error (`Io io) ->
            Error
              (Error.Store
                 (Mentat_diagnostic.of_text (Mentat_store.Io.message io)))
        | Ok guard -> (
            let release_and e =
              Mentat_store.Run_lock.release guard;
              Error e
            in
            match Mentat_store.Session.load t.store id with
            | Error e -> release_and (session_store_error e)
            | Ok loaded -> (
                match Mentat_store.Mutation.read t.store loaded with
                | Error e -> release_and (mutation_error ~session:id e)
                | Ok mutation -> (
                    let session = Mentat_store.Session.Document.session loaded in
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
                        let attachment reference =
                          Result.map_error
                            (attachment_error ~session:id)
                            (Mentat_store.Attachment.get t.store ~session:id
                               reference)
                        in
                        (* The post-revert re-read: the controller adopts a
                           current mutation mirror carrying the facts the revert
                           just appended. *)
                        let reread_after outcome =
                          match Mentat_store.Mutation.read t.store !doc with
                          | Error e -> Error (mutation_error ~session:id e)
                          | Ok mstate -> Ok (outcome_of_store outcome, mstate)
                        in
                        let revert_selection selection =
                          match
                            Mentat_store.Mutation.revert_apply ~merge:t.merge
                              t.store ~fence:guard ~document:!doc ~selection
                              ~observe:t.revert_observe
                              ~checkpoint:t.revert_checkpoint
                              ~apply:t.revert_apply ~new_id:t.revert_new_id
                          with
                          | Error e -> Error (mutation_error ~session:id e)
                          | Ok outcome -> reread_after outcome
                        in
                        let io =
                          {
                            Driver.session_id = id;
                            commit =
                              (fun events ->
                                match commit_events t guard !doc events with
                                | Error e -> Error e
                                | Ok loaded ->
                                    doc := loaded;
                                    Ok
                                      (Mentat_store.Session.Document.session
                                         loaded));
                            commit_metadata =
                              (fun session ->
                                match commit_stamped t guard !doc session with
                                | Error e -> Error e
                                | Ok loaded ->
                                    (* Adopt the new revision so the next
                                       journal commit CASes against it. *)
                                    doc := loaded;
                                    Ok
                                      (Mentat_store.Session.Document.session
                                         loaded));
                            append_edit =
                              (fun ~entries event ->
                                Result.map_error
                                  (mutation_error ~session:id)
                                  (Mentat_store.Mutation.append_edit t.store
                                     ~fence:guard ~document:!doc ~entries event));
                            append_mutation =
                              (fun events ->
                                Result.map_error
                                  (mutation_error ~session:id)
                                  (Mentat_store.Mutation.append t.store
                                     ~fence:guard ~document:!doc events));
                            put_attachment =
                              (fun bytes ->
                                Result.map_error
                                  (attachment_error ~session:id)
                                  (Mentat_store.Attachment.put t.store
                                     ~session:id bytes));
                            attachment;
                            fork =
                              (fun ~events session ->
                                match
                                  Mentat_store.fork t.store ~from:id ~events
                                    session
                                with
                                | Error e -> Error (session_store_error e)
                                | Ok (_ : Mentat_store.Session.Document.t) ->
                                    Ok ());
                            revert =
                              (fun ~scope ->
                                (* Resolve the wire scope against the replayed
                                   history, then run the store's fenced revert
                                   lifecycle over the resolved selection. *)
                                match
                                  Mentat_store.Mutation.read t.store !doc
                                with
                                | Error e -> Error (mutation_error ~session:id e)
                                | Ok state ->
                                    revert_selection
                                      (Mentat_mutation.Revert.Scope.resolve state
                                         scope));
                            undo_revert =
                              (fun selection -> revert_selection (Some selection));
                            truncate =
                              (fun ~keep session ->
                                (* Derive the surviving-turn ledger prefix from
                                   the current validated history, then drop both
                                   durable halves ledger-first. *)
                                match
                                  Mentat_store.Mutation.read t.store !doc
                                with
                                | Error e -> Error (mutation_error ~session:id e)
                                | Ok mstate -> (
                                    let ledger =
                                      Mentat_mutation.State.prefix_for_turns
                                        mstate ~keep
                                    in
                                    match
                                      Mentat_store.truncate t.store ~fence:guard
                                        ~document:!doc ~ledger session
                                    with
                                    | Error e -> Error (session_store_error e)
                                    | Ok (loaded, mstate) ->
                                        doc := loaded;
                                        Ok
                                          ( Mentat_store.Session.Document.session
                                              loaded,
                                            mstate )));
                            export =
                              (fun () ->
                                (* Buffer the whole fenced bundle into one value
                                   — the frontend owns where the bytes land, and
                                   the engine size-guards it before it crosses
                                   the wire. *)
                                let buf = Buffer.create 4096 in
                                match
                                  Mentat_store.Export.write ~root:t.store
                                    ~fence:guard ~write:(Buffer.add_string buf)
                                with
                                | Ok () -> Ok (Buffer.contents buf)
                                | Error (`Session e) ->
                                    Error (session_store_error e)
                                | Error (`Mutation e) ->
                                    Error (mutation_error ~session:id e));
                            release =
                              (fun () -> Mentat_store.Run_lock.release guard);
                            (* Resolve [`Ref] media back to [`Base64] strictly
                               after the request is digested and claimed, so
                               the adapters never see an unresolved reference
                               and the claim's digest stays over the [`Ref]
                               form. *)
                            provider_call =
                              (fun request ~on_event ~on_download ~cancelled ->
                                match
                                  Media.resolve_request ~attachment request
                                with
                                | Ok request ->
                                    t.provider request ~on_event ~on_download
                                      ~cancelled
                                | Error media_error ->
                                    let message =
                                      match media_error with
                                      | Media.Rebuild detail ->
                                          "request media could not be resolved: "
                                          ^ detail
                                      | other -> Media.message other
                                    in
                                    Error
                                      (Mentat_llm.Error.make
                                         ~kind:Mentat_llm.Error.Invalid_request
                                         ~provider:
                                           (Mentat_llm.Model.provider
                                              (Mentat_llm.Request.model request))
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
                        Ok driver))))and hooks t ~id =
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
        (* Drivers register before starting, so the sender resolves. *)
        match find_driver t id with
        | None -> ()
        | Some driver ->
            deliver_mail t ~sender:id
              ~head:(Feed.Hub.head (Driver.hub driver))
              message);
    settled_children =
      (fun children -> Scheduler.settled_for t.scheduler children);
    cancel_children = (fun children -> cancel_children t ~parent:id children);
    on_turn_settled =
      (fun ~turn outcome -> on_turn_settled t ~session:id ~turn outcome);
  }

(* Idempotent on the parent-minted child id: create the child session if
   absent, then hand it to the broker to run. A child never runs before its
   edge is durable — this is called only after the [Delegation_recorded]
   commit, or from recovery's re-drive. *)
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
  | Error e -> fail_spawn (Error.message e)
  | Ok () ->
      (* Identity only crosses: the broker re-reads the task and role from
         the durable edge. A child this runtime already drives (a resumed
         session holding a sibling driver) is skipped — its own driver and
         fence are the materialization, and handing its identity to the
         broker would race a second process against a fence this process
         holds. *)
      if Option.is_none (find_driver t child) then
        Mentat_broker.materialize t.broker t.broker_engine ~child
and ensure_child_session t ~parent ~delegation ~cwd child =
  match Mentat_store.Session.load t.store child with
  | Ok _ -> Ok ()
  | Error (Mentat_store.Session.Error.Not_found _) -> (
      let session =
        let delegated_from =
          Mentat_session.Metadata.Delegated_from.make ~parent ~delegation
        in
        Mentat_session.create ~id:child ~delegated_from ~cwd
          ~created_at:(t.now ()) ()
      in
      (* Idempotent on the parent-minted id: a concurrent or replayed create
         finding the document already present is success. *)
      match Mentat_store.Session.create t.store session with
      | Ok _ | Error (Mentat_store.Session.Error.Already_exists _) -> Ok ()
      | Error e -> Error (session_store_error e))
  | Error e -> Error (session_store_error e)

(* Recovery: rebuild the permit count and the settled buffer from
   child journals, and re-drive any edge whose child is absent or unfinished. *)
and rebuild_children t ~parent session =
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
      match Mentat_store.Session.load t.store child with
      | Error _ -> redrive ()
      | Ok loaded -> (
          match
            settled_result (Mentat_store.Session.Document.session loaded)
          with
          | None -> redrive ()
          | Some result -> Scheduler.note_settled t.scheduler delegation result))    (Mentat_session.State.delegations (Mentat_session.state session))

(* Delivery of a recorded message — one story for both directions. The
   idempotency id derives from the recording (turn, call), so
   an at-least-once re-drive lands the same queue entry once; both kinds are
   mail. Delivery is queued on the (sender, target) lane and performed by its
   one drain fiber, in receipt order — recovery's re-drives fold into the
   same lane, so a re-driven message cannot overtake a fresh one either. The
   target resolves against the sender's own recorded facts: a message naming
   an edge the sender never recorded, or a parent it does not have, delivers
   nowhere. *)
and deliver_mail t ~sender ~head (message : Mentat_agent_step.Step.Mail.t) =
  let target =
    match message.Mentat_agent_step.Step.Mail.target with
    | Mentat_agent_step.Step.Mail.Child child ->
        Option.map
          (fun edge -> To_child edge)
          (List.find_opt
             (fun edge ->
               Mentat_session.Delegation.Id.equal
                 (Mentat_session.Delegation.id edge)
                 child)
             (Mentat_session.State.delegations (Mentat_session.state head)))
    | Mentat_agent_step.Step.Mail.Parent ->
        Option.map
          (fun lineage ->
            To_parent (Mentat_session.Metadata.Delegated_from.parent lineage))
          (Mentat_session.Metadata.delegated_from (Mentat_session.metadata head))
  in
  match target with
  | None -> ()
  | Some target -> (
      let lane_key =
        key sender ^ "/"
        ^
        match target with
        | To_child edge ->
            Mentat_session.Delegation.Id.to_string
              (Mentat_session.Delegation.id edge)
        | To_parent _ -> "parent"
      in
      match Hashtbl.find_opt t.lanes lane_key with
      | Some lane -> Queue.push message lane.pending
      | None ->
          let lane = { lane_key; sender; target; pending = Queue.create () } in
          Queue.push message lane.pending;
          Hashtbl.replace t.lanes lane_key lane;
          Eio.Fiber.fork ~sw:t.sw (fun () -> drain_lane t lane))

(* The lane's drain fiber: one message at a time, in queue order. A failed
   delivery is contained loudly and the drain moves on — the durable receipt
   re-drives it later, and one message's failure must not park the lane's
   siblings. On shutdown the rest of the queue is abandoned the same way:
   receipts re-drive at the next attach, and a fiber that kept sending would
   outlive the runtime it delivers for. The lane is removed in the same
   non-suspending step that finds the queue empty, so a message enqueued
   after that starts a fresh lane and fiber. *)
and drain_lane t lane =
  if t.shutting_down then Hashtbl.remove t.lanes lane.lane_key
  else
    match Queue.take_opt lane.pending with
    | None -> Hashtbl.remove t.lanes lane.lane_key
    | Some message ->
        (try deliver_one t lane message with
        | Eio.Cancel.Cancelled _ as exn ->
            Hashtbl.remove t.lanes lane.lane_key;
            raise exn
        | exn ->
            Eio.traceln "mentat: message to %s undelivered: %s"
              (Mentat_session.Id.to_string (lane_session lane))
              (Printexc.to_string exn));
        drain_lane t lane

(* One message's delivery: the broker's send, the one road — durable in the
   target's journal, or a loud undelivered answer the durable receipt
   re-drives — at the sender's next attach, or the observed child exit for a
   downward message. The target is always another process's session: a
   parent is its own agent behind its own socket, a child is the broker's to
   run. Sending never wakes: a [`Follow_up] additionally wakes the child —
   send then wake, two acts — while a [`Context] entry waits for whatever
   next runs the target; a child holds no wake authority over its parent at
   all. *)
and deliver_one t lane (message : Mentat_agent_step.Step.Mail.t) =
  let target_session = lane_session lane in
  let id = Mentat_session.Queue.Id.of_string (derived_message_id message) in
  let input =
    [ Mentat_llm.Content.text message.Mentat_agent_step.Step.Mail.message ]
  in
  let origin = Mentat_session.Origin.agent lane.sender in
  (match
     Mentat_broker.send t.broker ~origin ~target:target_session ~id ~input ()
   with
  | `Delivered -> ()
  | `Undelivered reason ->
      (* The receipt already promised delivery: the sender's next attach —
         or, for a downward message, the observed child exit — re-drives the
         same derived id. *)
      Eio.traceln "mentat: message to %s undelivered: %s"
        (Mentat_session.Id.to_string target_session)
        reason);
  match (message.Mentat_agent_step.Step.Mail.kind, lane.target) with
  | `Follow_up, To_child edge -> wake_child t edge
  | `Follow_up, To_parent _ | `Context, _ -> ()

(* The wake half of a follow-up: make the child run so it consumes the mail.
   Materialization is the wake — the broker's unfinished-work probe sees the
   queued mail. The guard is the materialization law above: a child whose
   driver this process still holds is never handed to the broker — a second
   process racing that fence could only lose, and the driver's own idle
   boundary consumes durable mail. *)
and wake_child t edge =
  let child = Mentat_session.Delegation.child edge in
  if Option.is_none (find_driver t child) then
    Mentat_broker.materialize t.broker t.broker_engine ~child

(* Recovery's message re-drive (the idempotent pattern): a settled receipt
   whose derived id is not recorded as an enqueue in the target journal was
   never delivered — the process died between the receipt commit and the
   send. Re-drive it; the derived id makes the replay safe. A child's
   undelivered reply re-drives here too, at its own next activation. [only]
   narrows the sweep to one delegation edge — the brokered wake re-drives a
   child's messages the moment its process exits and frees the fence, without
   touching its siblings. *)
and redrive_messages ?only t session =
  let sender = Mentat_session.id session in
  let relevant (message : Mentat_agent_step.Step.Mail.t) =
    match only with
    | None -> true
    | Some delegation -> (
        match message.Mentat_agent_step.Step.Mail.target with
        | Mentat_agent_step.Step.Mail.Child child ->
            Mentat_session.Delegation.Id.equal child delegation
        | Mentat_agent_step.Step.Mail.Parent -> false)
  in
  List.iter
    (fun (message : Mentat_agent_step.Step.Mail.t) ->
      if relevant message then begin
        let target_session =
          match message.Mentat_agent_step.Step.Mail.target with
          | Mentat_agent_step.Step.Mail.Child child ->
              Option.map Mentat_session.Delegation.child
                (List.find_opt
                   (fun edge ->
                     Mentat_session.Delegation.Id.equal
                       (Mentat_session.Delegation.id edge)
                       child)
                   (Mentat_session.State.delegations
                      (Mentat_session.state session)))
          | Mentat_agent_step.Step.Mail.Parent ->
              Option.map Mentat_session.Metadata.Delegated_from.parent
                (Mentat_session.Metadata.delegated_from
                   (Mentat_session.metadata session))
        in
        let delivered =
          match target_session with
          | None -> true (* no target: nothing to deliver to *)
          | Some target -> (
              match Mentat_store.Session.load t.store target with
              | Error (Mentat_store.Session.Error.Not_found _) ->
                  true (* no target session: nothing to deliver to *)
              | Error _ -> false
              | Ok loaded ->
                  Mentat_session.State.enqueue_recorded
                    (Mentat_session.Queue.Id.of_string
                       (derived_message_id message))
                    (Mentat_session.state
                       (Mentat_store.Session.Document.session loaded)))
        in
        if not delivered then deliver_mail t ~sender ~head:session message
      end)    (Mentat_agent_step.settled_messages session)

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
          | None ->
              let active =
                match Mentat_store.Session.load t.store child with
                | Error _ -> false
                | Ok loaded ->
                    Option.is_some
                      (Mentat_session.State.active_turn
                         (Mentat_session.state
                            (Mentat_store.Session.Document.session loaded)))
              in
              if active then Mentat_broker.cancel t.broker ~child
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
  | Error.Not_found -> Mentat_protocol.Error.Session_not_found session
  | Error.Store _ | Error.Request _ | Error.Session _ | Error.Decision _
  | Error.Configuration _ | Error.Delegation _ | Error.Internal _
  | Error.Shutting_down ->
      Mentat_protocol.Error.Unavailable (Error.diagnostic e)

let route t session =
  Result.map_error (protocol_error ~session) (attach t session)

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
      let head =
        match find_driver t child with
        | Some driver -> Ok (Feed.Hub.head (Driver.hub driver))
        | None ->
            Result.map Mentat_store.Session.Document.session
              (Mentat_store.Session.load t.store child)
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
              (match Mentat_store.Session.load t.store parent with
              | Error _ -> ()
              | Ok loaded ->
                  redrive_messages ~only:delegation t
                    (Mentat_store.Session.Document.session loaded));
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
  match Mentat_store.Session.load t.store session with
  | Error e -> Error (protocol_error ~session (session_store_error e))
  | Ok loaded -> (
      match Mentat_store.Mutation.read t.store loaded with
      | Error e -> Error (protocol_error ~session (mutation_error ~session e))
      | Ok mutation ->
          Ok (Mentat_store.Session.Document.session loaded, mutation))

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
   head, else a fence-free store load. *)
let head_session t session =
  match find_driver t session with
  | Some driver -> Ok (Feed.Hub.head (Driver.hub driver))
  | None ->
      Result.map_error
        (fun e -> protocol_error ~session (session_store_error e))
        (Result.map Mentat_store.Session.Document.session
           (Mentat_store.Session.load t.store session))

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
  Result.bind (head_projection t session) (fun (_loaded, mutation) ->
      match Mentat_mutation.State.change mutation change with
      | None ->
          Error
            (Mentat_protocol.Error.unavailable
               (Printf.sprintf "no recorded change %s"
                  (Mentat_mutation.Change.Id.to_string change)))
      | Some row -> (
          let blob ref =
            match Mentat_store.Mutation.blob t.store ~session ref with
            | Ok bytes -> bytes
            | Error _ -> None
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
