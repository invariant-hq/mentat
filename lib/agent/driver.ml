(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type io = {
  session_id : Mentat_session.Id.t;
  commit :
    Mentat_session.Event.t list ->
    (Mentat_session.t, Ports.Store_error.t) result;
  commit_metadata :
    Mentat_session.t -> (Mentat_session.t, Ports.Store_error.t) result;
  append_edit :
    entries:Mentat_edit.Result.Entry.t list ->
    Mentat_mutation.Event.t ->
    (Mentat_mutation.State.t, Ports.Store_error.t) result;
  append_mutation :
    Mentat_mutation.Event.t list ->
    (Mentat_mutation.State.t, Ports.Store_error.t) result;
  put_attachment :
    string -> (Mentat_digest.Content_ref.t, Ports.Store_error.t) result;
  attachment :
    Mentat_digest.Content_ref.t -> (string option, Ports.Store_error.t) result;
  fork :
    events:Mentat_mutation.Event.t list ->
    Mentat_session.t ->
    (unit, Ports.Store_error.t) result;
  revert :
    scope:Mentat_mutation.Revert.Scope.t ->
    ( Mentat_mutation.Revert.Outcome.t * Mentat_mutation.State.t,
      Ports.Store_error.t )
    result;
  undo_revert :
    Mentat_mutation.Revert.Selection.t ->
    ( Mentat_mutation.Revert.Outcome.t * Mentat_mutation.State.t,
      Ports.Store_error.t )
    result;
  truncate :
    keep:(Mentat_session.Turn.Id.t -> bool) ->
    Mentat_session.t ->
    (Mentat_session.t * Mentat_mutation.State.t, Ports.Store_error.t) result;
  export : unit -> (string, Ports.Store_error.t) result;
  release : unit -> unit;
  provider_call :
    Mentat_llm.Request.t ->
    on_event:(Mentat_llm.Event.t -> unit) ->
    on_download:(Mentat_protocol.Progress.Model_download.t -> unit) ->
    cancelled:(unit -> bool) ->
    (Mentat_llm.Response.t, Mentat_llm.Error.t) result;
}

type hooks = {
  try_reserve :
    Mentat_agent_step.Step.Reservation.t ->
    [ `Granted | `Refused of Mentat_agent_step.Step.Reservation.Refusal.t ];
  release_permit : delegation:Mentat_session.Delegation.Id.t -> unit;
  observe_delegation : Mentat_session.Delegation.t -> unit;
  deliver_message : Mentat_agent_step.Step.Child_message.t -> unit;
  settled_children :
    Mentat_session.Delegation.Id.t list ->
    (Mentat_session.Delegation.Id.t * Scheduler.child_result) list;
  cancel_children : Mentat_session.Delegation.Id.t list -> unit;
  on_turn_settled :
    turn:Mentat_session.Turn.Id.t -> Mentat_session.Turn.Outcome.t -> unit;
}

(* The undo operations the TUI drives at an idle head. [Undo] steps the boundary
   back one user turn (widen), [Redo] forward one (narrow, past the last undone
   turn it releases), and [Cancel] un-reverts and releases. Each re-derives the
   working tree from the arm-time baseline and appends the durable boundary — an
   ordinary journal append the feed carries. The commit-on-submit truncation the
   design specifies needs feed truncation the append-only hub does not yet
   support; until then the TUI guards submit while a boundary is armed. *)
type undo_op = Undo | Redo | Cancel

(* The controller fails the worker switch with this after committing the
   durable interrupt request; the settle path recognizes it. *)
exception Interrupted_by_driver

(* A worker-side store append failed: the driver faults without settling —
   the open claim degrades to Ambiguous at a successor's recovery. *)
exception Store_failed of Ports.Store_error.t

type phase =
  | Running
  | Idle
  | Parked_decision of Mentat_session.Decision.Requested.t
  | Parked_children of Mentat_agent_step.Step.Children_wait.t
  | Faulted of Error.t

type msg =
  | Command of
      Mentat_protocol.Command.t
      * (unit, Mentat_protocol.Error.t) result Eio.Promise.u
  | Unattended of
      Mentat_session.Decision.Id.t
      * (unit, Mentat_protocol.Error.t) result Eio.Promise.u
  | Deliver
  | Fork of
      Mentat_session.Id.t * (Mentat_session.Id.t, Error.t) result Eio.Promise.u
  | Rewind of
      Mentat_session.Id.t
      * Mentat_session.Anchor.t
      * (Mentat_session.Id.t, Error.t) result Eio.Promise.u
  | Compact of
      Mentat_session.Turn.Id.t
      * (Mentat_client.Driver.compaction_result, Mentat_protocol.Error.t) result
        Eio.Promise.u
  | Commit_metadata of
      (Mentat_session.t -> (Mentat_session.t, Mentat_protocol.Error.t) result)
      * (unit, Mentat_protocol.Error.t) result Eio.Promise.u
  | Revert of
      Mentat_mutation.Revert.Scope.t
      * (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result
        Eio.Promise.u
  | Undo_op of
      undo_op
      * (Mentat_mutation.Revert.Outcome.t, Mentat_protocol.Error.t) result
        Eio.Promise.u
  | Export of (string, Mentat_protocol.Error.t) result Eio.Promise.u
  | Enqueue of
      Mentat_session.Queue.Entry.t
      * (unit, Mentat_protocol.Error.t) result Eio.Promise.u
  | Stop

(* The worker's yield: the effect's raw runtime outcome. *)
type work =
  | Model_work of (Mentat_llm.Response.t, Mentat_llm.Error.t) result
  | Tool_work of Mentat_tool.Call.outcome

type t = {
  io : io;
  hooks : hooks;
  resolve :
    latest_model:Mentat_llm.Model.t option ->
    (Config.t, Mentat_diagnostic.t) result;
  execution_for_mode : Execution.factory;
  now : unit -> Mentat_session.Time.t;
  depth : int;
  sw : Eio.Switch.t;
  mutable select_execution : Execution.selector option;
  mutable running_view : (unit -> Mentat_protocol.Process.View.t list) option;
      (* [execution_for_mode] applied to the driver's nested per-session switch
         once at controller start yields both the per-turn selector and this
         live background-process view over the same session registry. Set once —
         the controller is the sole writer, at start — and [None] until then.
         [running_processes] reads it on the caller's fiber (the client's session
         cone), not inside the controller; that is safe because the binding is
         set-once and the engine is single-domain, so no reader observes a torn
         or stale view — the same posture as the workspace-glance cone read. *)
  hub : Feed.Hub.t;
  mailbox : msg Queue.t;
  cond : Eio.Condition.t;
  flag : bool Atomic.t; (* Cooperative cancellation; controller sole writer. *)
  mutable session : Mentat_session.t;
  mutable mstate : Mentat_mutation.State.t;
  mutable execution : (Mentat_agent_step.Env.t * Ports.workspace) option;
      (* Selected atomically before recovering or starting an active turn and
         cleared when admission parks on a genuinely idle head. *)
  mutable phase : phase;
  mutable stopping : bool;
  mutable interrupt_reason : string option;
  mutable turn_checkpoint :
    (Mentat_session.Turn.Id.t * Mentat_mutation.Checkpoint.Id.t option) option;
      (* The active turn's conservative capture, id present when available. *)
  mutable possibly_mutating : bool;
      (* The possibly-still-mutating recovery condition. *)
  mutable compaction_pending :
    (Mentat_session.Turn.Id.t
    * (Mentat_client.Driver.compaction_result, Mentat_protocol.Error.t) result
      Eio.Promise.u)
    option;
      (* A manual compaction's awaiting resolver, keyed by its compaction turn.
         Resolved when that turn settles (or the driver faults): the flow is
         asynchronous over the summary provider call, so the [Compact]
         message's reply cannot be produced inline. *)
  quiesced : unit Eio.Promise.t * unit Eio.Promise.u;
}

let hub t = t.hub
let possibly_mutating t = t.possibly_mutating

let faulted t =
  match t.phase with Faulted e -> Some (Error.diagnostic e) | _ -> None

let state t = Mentat_session.state t.session
let active_turn t = Mentat_session.State.active_turn (state t)

let execution t =
  match t.execution with
  | Some execution -> execution
  | None -> invalid_arg "Driver: execution read without an active turn"

(* The per-turn execution selector, bound to the driver's nested per-session
   switch. Every selection runs inside the controller, after [start] binds it. *)
let select_execution t =
  match t.select_execution with
  | Some select -> select
  | None ->
      invalid_arg "Driver: execution selected before the controller started"

(* A live snapshot of the session's background processes; empty before the
   controller binds the session execution, or when the catalog has no background
   tools. Derived on demand, never persisted. *)
let running_processes t =
  match t.running_view with Some running -> running () | None -> []

let env t = fst (execution t)
let workspace t = snd (execution t)

let internal_error exn =
  Error.Internal (Mentat_diagnostic.of_text (Printexc.to_string exn))

let unavailable e = Mentat_protocol.Error.Unavailable (Error.diagnostic e)

(* Externalize inline [`Base64] media in a command's content to attachment
   [`Ref]s before it enters a durable event, and validate an incoming [`Ref]
   resolves to a present blob. A malformed payload or fabricated reference is a
   client error surfaced as [Unavailable]; the attach flow carries the richer
   rejection vocabulary. *)
let externalize_content t input =
  match
    Media.externalize ~put_attachment:t.io.put_attachment
      ~attachment:t.io.attachment input
  with
  | Ok content -> Ok content
  | Error media_error ->
      Error (Mentat_protocol.Error.unavailable (Media.message media_error))

let mint domain t =
  Mentat_digest.key ~length:20
    ~domain:("mentat.agent." ^ domain ^ ".v1")
    [
      Mentat_session.Id.to_string t.io.session_id;
      string_of_int (List.length (Mentat_session.events t.session));
    ]

let mint_turn_id t = Mentat_session.Turn.Id.of_string (mint "turn" t)
let mint_queue_id t = Mentat_session.Queue.Id.of_string (mint "queue" t)

let mint_replacement_queue_id t ordinal =
  Mentat_session.Queue.Id.of_string
    (Mentat_digest.key ~length:20 ~domain:"mentat.agent.queue-replacement.v1"
       [
         Mentat_session.Id.to_string t.io.session_id;
         string_of_int (List.length (Mentat_session.events t.session));
         string_of_int ordinal;
       ])

let pulse t p = Feed.Hub.pulse t.hub p

(* Environment and contract. *)

(* Convert a live workspace notice to the durable, session-owned observation the
   journal records. The producer-side coalescing key does not cross: it is
   live-queue identity, never model-visible, so the durable core keeps only the
   observation's content. *)
let session_notice_of_workspace notice =
  let severity =
    match Mentat_workspace.Notice.severity notice with
    | Mentat_workspace.Notice.Severity.Info ->
        Mentat_session.Notice.Severity.Info
    | Mentat_workspace.Notice.Severity.Warning ->
        Mentat_session.Notice.Severity.Warning
    | Mentat_workspace.Notice.Severity.Error ->
        Mentat_session.Notice.Severity.Error
  in
  Mentat_session.Notice.make
    ~source:(Mentat_workspace.Notice.source notice)
    ~severity
    ~title:(Mentat_workspace.Notice.title notice)
    ?body:(Mentat_workspace.Notice.body notice)
    ()

let build_env t ~context_prelude ~workspace catalog cfg ~max_steps =
  (* The context prelude (system prompt, workspace instructions, skills) is
     the whole request context [Env] holds — stable for the session, so the
     conversation head never moves. Workspace notices are not here: they are
     durable facts ({!Mentat_session.Event.Workspace_notice}) the session
     projects into the model transcript as ordinary entries. *)
  Mentat_agent_step.Env.make ~catalog ~sandbox:workspace.Ports.identity
    ~prelude:context_prelude
    ~max_steps:(Option.value max_steps ~default:cfg.Config.max_steps)
    ~compaction_pressure_tokens:cfg.Config.compaction_pressure_tokens
    ~max_spawn_depth:cfg.Config.max_spawn_depth
    ~max_exchanges:cfg.Config.max_exchanges ~depth:t.depth ()

let seal ~workspace catalog cfg ~policy ~mode ~options ?output_schema () =
  let output_tool =
    Option.map
      (fun schema ->
        Mentat_llm.Tool.make ~name:Mentat_agent_step.Catalog.output_tool_name
          ~description:Mentat_prompts.Tools.structured_output
          ~input_schema:schema ())
      output_schema
  in
  Mentat_session.Contract.make ~mode ~model:cfg.Config.model
    ~options:(Option.value options ~default:cfg.Config.options)
    ~declarations:(Mentat_agent_step.Catalog.declarations catalog)
    ?output_tool ~policy ~review:cfg.Config.review
    ~sandbox:workspace.Ports.identity ()

(* Committing. *)

(* A manual compaction's terminal outcome, as its client-facing result. A
   compaction turn only reaches [Completed] by installing its summary, so that is
   [Installed]; any other terminal outcome (a failed or interrupted summary) is
   the flow's operational error, honestly carrying the turn's diagnostic. *)
let compaction_result_of_outcome outcome =
  match (outcome : Mentat_session.Turn.Outcome.t) with
  | Mentat_session.Turn.Outcome.Completed -> Ok Mentat_client.Driver.Installed
  | Mentat_session.Turn.Outcome.Failed { message } ->
      Error (Mentat_protocol.Error.unavailable message)
  | Mentat_session.Turn.Outcome.Interrupted { reason; _ } ->
      Error
        (Mentat_protocol.Error.unavailable
           (Option.value reason ~default:"manual compaction was interrupted"))
  | Mentat_session.Turn.Outcome.Step_limit ->
      Error
        (Mentat_protocol.Error.unavailable
           "manual compaction did not install a summary")

let resolve_compaction t result =
  match t.compaction_pending with
  | Some (_, resolver) ->
      t.compaction_pending <- None;
      Eio.Promise.resolve resolver result
  | None -> ()

(* Externalize a settled tool output's inline [`Base64] media to attachment
   [`Ref]s before the [Tool_settled] fact commits — the read-path counterpart of
   the admission externalize, at the one commit choke point where
   io.put_attachment is available. The other carriers already hold [`Ref] from
   admission and pass through untouched. *)
let externalize_tool_media t event =
  let has_base64 media =
    List.exists
      (function
        | Mentat_llm.Content.Media { source = `Base64 _; _ } -> true
        | _ -> false)
      media
  in
  match event with
  | Mentat_session.Event.Tool_settled settled -> (
      match Mentat_session.Tool_claim.Settled.outcome settled with
      | Mentat_session.Tool_claim.Settled.Returned result -> (
          match Mentat_tool.Result.output result with
          | Some output when has_base64 (Mentat_tool.Output.media output) -> (
              match
                Media.externalize ~put_attachment:t.io.put_attachment
                  ~attachment:t.io.attachment
                  (Mentat_tool.Output.media output)
              with
              | Error (Media.Store e) -> Error (Error.Store e)
              | Error
                  ( Media.Malformed_base64 | Media.Missing_attachment _
                  | Media.Rebuild _ ) ->
                  Error
                    (Error.Internal
                       (Mentat_diagnostic.of_text
                          "tool-output media could not be externalized"))
              | Ok media ->
                  let output =
                    Mentat_tool.Output.make
                      ~text:(Mentat_tool.Output.text output)
                      ?json:(Mentat_tool.Output.json output)
                      ~media
                      ~truncated:(Mentat_tool.Output.truncated output)
                      ()
                  in
                  let result =
                    Mentat_tool.Result.map (fun _ -> output) result
                  in
                  Ok
                    (Mentat_session.Event.tool_settled
                       (Mentat_session.Tool_claim.Settled.returned
                          ~id:(Mentat_session.Tool_claim.Settled.id settled)
                          result)))
          | Some _ | None -> Ok event)
      | Mentat_session.Tool_claim.Settled.Prepared _
      | Mentat_session.Tool_claim.Settled.Ambiguous ->
          Ok event)
  | _ -> Ok event

let externalize_events t events =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | event :: rest -> (
        match externalize_tool_media t event with
        | Error _ as error -> error
        | Ok event -> loop (event :: acc) rest)
  in
  loop [] events

let commit_step t step =
  match Mentat_agent_step.Step.events step with
  | [] -> Ok ()
  | events -> (
      match externalize_events t events with
      | Error _ as error -> error
      | Ok events -> (
          match t.io.commit events with
          | Error e ->
              List.iter
                (function
                  | Mentat_session.Event.Delegation_recorded d ->
                      t.hooks.release_permit
                        ~delegation:(Mentat_session.Delegation.id d)
                  | _ -> ())
                events;
              Error (Error.Store e)
          | Ok session ->
              t.session <- session;
              (* Register each newly delegated child before the hub announces its
             edge. A feed subscriber reacts to the published [Journal_delegation]
             fact by attaching to the child; were the edge announced first, that
             attach could win the race against [observe_delegation]'s child
             creation and observe a [Session_not_found]. The edge is already
             durable — [t.io.commit] returned above — so this preserves the "a
             child never runs before its edge is durable" invariant while adding
             the converse: the edge is not observable until the child it names
             is resolvable. *)
              List.iter
                (function
                  | Mentat_session.Event.Delegation_recorded d ->
                      t.hooks.observe_delegation d
                  | _ -> ())
                events;
              Feed.Hub.publish t.hub ~delta:events session t.mstate;
              List.iter
                (function
                  | Mentat_session.Event.Delegation_recorded _ -> ()
                  | Mentat_session.Event.Turn_finished { turn; outcome } -> (
                      Atomic.set t.flag false;
                      t.interrupt_reason <- None;
                      match t.compaction_pending with
                      | Some (pending, _)
                        when Mentat_session.Turn.Id.equal pending turn ->
                          (* A manual compaction turn's settlement resolves its
                         caller; it is not real work, so it fires no
                         child-settlement notification. *)
                          resolve_compaction t
                            (compaction_result_of_outcome outcome)
                      | Some _ | None -> t.hooks.on_turn_settled ~turn outcome)
                  | Mentat_session.Event.Message_appended _ as event -> (
                      (* A settled send_message/follow_up receipt commits here;
                     the runtime routes the recorded message to the child. *)
                      match Mentat_agent_step.settled_message session event with
                      | Some message -> t.hooks.deliver_message message
                      | None -> ())
                  | _ -> ())
                events;
              Ok ()))

let commit_events t events =
  match t.io.commit events with
  | Error e -> Error (Error.Store e)
  | Ok session ->
      t.session <- session;
      Feed.Hub.publish t.hub ~delta:events session t.mstate;
      Ok ()

(* A metadata-only commit (rename/archive/restore/delete): a whole-document CAS
   of a metadata-transformed session under the fence, no journal delta. The
   controller adopts the returned session — and [io] adopts its held store
   revision — so the {b next} journal commit CASes against the fresh head, never
   a stale one (the interleaving the idle-only discipline exists to close). No
   fact is emitted, so the feed does not publish: metadata is not journal state. *)
let commit_metadata_committed t session' =
  match t.io.commit_metadata session' with
  | Error e -> Error (Error.Store e)
  | Ok session ->
      t.session <- session;
      Ok ()

let fault t e =
  t.phase <- Faulted e;
  (* A fault aborts the compaction drive before its turn can settle; its awaiting
     caller must not hang. *)
  resolve_compaction t (Error (unavailable e))

(* Fault containment: no exception escapes a driver fiber. An escape into the
   shared Agent runtime switch would fail [t.sw] and cancel every sibling
   driver, so each entry point into effectful work runs here. Cancellation is
   runtime teardown, never a driver fault, so it re-raises unchanged. *)
let contain t f =
  try f () with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exn -> fault t (internal_error exn)

(* The drive loop.

   [act] is the iterative loop: protection wraps only [settle], which commits
   the settlement and returns the next step; the loop re-enters in the normal
   cancellation context, so the next effect is cancellable. *)

let rec drive t step =
  t.phase <- Running;
  match commit_step t step with Error e -> fault t e | Ok () -> act t step

and act t step =
  match Mentat_agent_step.Step.action step with
  | Mentat_agent_step.Step.Settled _ | Mentat_agent_step.Step.Idle ->
      admission t
  | Mentat_agent_step.Step.Await_decision d -> t.phase <- Parked_decision d
  | Mentat_agent_step.Step.Await_children w ->
      t.phase <- Parked_children w;
      try_deliver t w
  | Mentat_agent_step.Step.Reserve_child r -> (
      let answer = t.hooks.try_reserve r in
      match Mentat_agent_step.reserve_result (env t) r answer t.session with
      | Error e ->
          (match answer with
          | `Granted ->
              t.hooks.release_permit
                ~delegation:(Mentat_agent_step.Step.Reservation.delegation r)
          | `Refused _ -> ());
          fault t (Error.of_step e)
      | Ok step -> drive t step)
  | Mentat_agent_step.Step.Perform eff -> perform t eff

and try_deliver t w =
  let children = w.Mentat_agent_step.Step.Children_wait.children in
  let settled = t.hooks.settled_children children in
  if List.length settled = List.length children then
    (* Delegated work is workspace work: children write through the same build
       workspace, and a parent can wait on them for minutes, so this is where
       the world is most likely to have moved under the turn. Delivery answers
       the wait call and the model must be shown the answer, so a request
       follows exactly as it does from a tool settlement. *)
    match drain_workspace_notices t with
    | Error e -> fault t e
    | Ok () -> (
        match
          Mentat_agent_step.deliver_child (env t) ~wait:w ~settled t.session
        with
        | Error e -> fault t (Error.of_step e)
        | Ok step -> drive t step)

(* Admission. *)

(* The shared Build-turn constants: every admission path starts a Build turn
   with no options, no step cap, a freshly minted id, no output schema, and an
   ignored ack — only the input and origin vary. *)
and start_build_turn t cfg ~input ~origin =
  start_turn t cfg ~mode:Mentat_session.Contract.Mode.Build ~options:None
    ~max_steps:None ~id:(mint_turn_id t) ~input ~origin ~output_schema:None
    ~ack:ignore

and admission t =
  if t.stopping then begin
    t.execution <- None;
    t.phase <- Idle
  end
  else
    match
      t.resolve ~latest_model:(Mentat_session.State.latest_model (state t))
    with
    | Error d -> fault t (Error.Configuration d)
    | Ok cfg -> (
        match Mentat_session.State.approved_plan (state t) with
        | Some approval ->
            start_build_turn t cfg
              ~input:(Mentat_session.Turn.Input.plan_build approval)
              ~origin:Mentat_session.Turn.Origin.Plan_build
        | None -> (
            match Mentat_agent_step.next_admission (state t) with
            | Mentat_agent_step.Admission.Queued entry ->
                start_build_turn t cfg
                  ~input:
                    (Mentat_session.Turn.Input.user
                       (Mentat_session.Queue.Entry.input entry))
                  ~origin:
                    (Mentat_session.Turn.Origin.Queued
                       (Mentat_session.Queue.Entry.id entry))
            | Mentat_agent_step.Admission.Step_limit_wind_down input ->
                start_build_turn t cfg ~input
                  ~origin:Mentat_session.Turn.Origin.Step_limit_wind_down
            | Mentat_agent_step.Admission.Idle ->
                t.execution <- None;
                t.phase <- Idle))

and start_turn t cfg ~mode ~options ~max_steps ~id ~input ~origin ~output_schema
    ~ack =
  let { Execution.catalog; workspace; policy; prelude = context_prelude } =
    select_execution t ~configured:cfg ~model:cfg.Config.model
      ~sealed_declarations:None mode
  in
  (* A drain consumes its producers, and the recorded events are the whole
     story: an observation a dying turn recorded stays pending in session
     state until a request states it — no driver memory carries it. *)
  let notices = workspace.Ports.drain_notices () in
  let turn_env =
    build_env t ~context_prelude ~workspace catalog cfg ~max_steps
  in
  let contract =
    seal ~workspace catalog cfg ~policy ~mode ~options ?output_schema ()
  in
  match
    Mentat_agent_step.start
      ~notices:(List.map session_notice_of_workspace notices)
      turn_env contract ~id ~input ~origin t.session
  with
  | Error e ->
      let e = Error.of_step e in
      ack (Error e);
      fault t e
  | Ok step -> (
      t.execution <- Some (turn_env, workspace);
      match commit_step t step with
      | Error e ->
          ack (Error e);
          fault t e
      | Ok () ->
          Atomic.set t.flag false;
          t.interrupt_reason <- None;
          ack (Ok ());
          act t step)

(* The worker. *)

and perform t eff =
  match active_turn t with
  | None -> fault t (internal_error (Failure "perform without an active turn"))
  | Some turn -> (
      let turn_id = Mentat_session.Turn.id turn in
      let buffer = Buffer.create 256 in
      let stream_usage = ref None in
      let closer = ref None in
      let sw_cell = ref None in
      let done_p, done_r = Eio.Promise.create () in
      Eio.Fiber.fork ~sw:t.sw (fun () ->
          let outcome =
            try
              Ok
                (Eio.Switch.run (fun sw ->
                     sw_cell := Some sw;
                     exec t eff ~turn:turn_id ~buffer ~stream_usage ~closer))
            with exn -> Error exn
          in
          Eio.Promise.resolve done_r outcome);
      let outcome = supervise t ~done_p ~sw_cell ~turn:turn_id in
      let result =
        Eio.Cancel.protect (fun () ->
            settle t eff ~outcome ~buffer ~stream_usage ~closer)
      in
      match result with Error e -> fault t e | Ok step -> act t step)

and exec t eff ~turn ~buffer ~stream_usage ~closer =
  match eff with
  | Mentat_agent_step.Step.Effect.Model { request; purpose; _ } ->
      (match purpose with
      | `Turn ->
          pulse t
            (Mentat_protocol.Progress.Model
               { turn; update = Mentat_protocol.Progress.Model.Started })
      | `Compaction (reason, _) ->
          pulse t
            (Mentat_protocol.Progress.Compaction
               {
                 turn;
                 update = Mentat_protocol.Progress.Compaction.Started { reason };
               }));
      (* Per-call cumulative input bytes, keyed by the provider's stream-local
         output key. Scoped to this one call: a fresh effect streams fresh
         counts. *)
      let tool_input_bytes = Hashtbl.create 4 in
      Model_work
        (t.io.provider_call request
           ~on_event:
             (model_event t ~turn ~purpose ~buffer ~stream_usage
                ~tool_input_bytes)
           ~on_download:(fun update ->
             pulse t (Mentat_protocol.Progress.Model_download { turn; update }))
           ~cancelled:(fun () -> Atomic.get t.flag))
  | Mentat_agent_step.Step.Effect.Tool { claim; call } ->
      ensure_checkpoint t ~turn;
      let close =
        (workspace t).Ports.open_scope
          (Mentat_session.Tool_claim.Started.id claim)
      in
      closer := Some close;
      Tool_work
        (Mentat_tool.Call.run call ~cancelled:(fun () -> Atomic.get t.flag))

and model_event t ~turn ~purpose ~buffer ~stream_usage ~tool_input_bytes event =
  match purpose with
  | `Compaction _ -> (
      match event with
      | Mentat_llm.Event.Text_delta _ ->
          pulse t
            (Mentat_protocol.Progress.Compaction
               {
                 turn;
                 update = Mentat_protocol.Progress.Compaction.Summarizing;
               })
      | _ -> ())
  | `Turn -> (
      let model update =
        pulse t (Mentat_protocol.Progress.Model { turn; update })
      in
      match event with
      | Mentat_llm.Event.Text_delta text ->
          Buffer.add_string buffer text;
          model (Mentat_protocol.Progress.Model.Assistant_delta { text })
      | Mentat_llm.Event.Reasoning_summary_delta text ->
          model (Mentat_protocol.Progress.Model.Reasoning_delta { text })
      | Mentat_llm.Event.Usage usage ->
          (* Retained for the interrupt settlement: snapshots are cumulative,
             so the last one is the spend the provider reported. *)
          stream_usage := Some usage;
          model (Mentat_protocol.Progress.Model.Usage usage)
      | Mentat_llm.Event.Retry retry ->
          (* The announced attempt restarts the stream, so its input counts
             restart with it. *)
          Hashtbl.reset tool_input_bytes;
          model (Mentat_protocol.Progress.Model.Retrying retry)
      | Mentat_llm.Event.Tool_input_delta input ->
          (* Liveness only: the input text never crosses — the canonical call
             is reconciled durably from the terminal response. The pulse is a
             cumulative per-call snapshot, so the ring dropping any prefix of
             pulses leaves the latest one whole. *)
          let key = Mentat_llm.Event.Tool_input.key input in
          let received =
            Option.value (Hashtbl.find_opt tool_input_bytes key) ~default:0
            + String.length (Mentat_llm.Event.Tool_input.input_delta input)
          in
          Hashtbl.replace tool_input_bytes key received;
          model
            (Mentat_protocol.Progress.Model.Tool_input
               { name = Mentat_llm.Event.Tool_input.name input; received })
      | Mentat_llm.Event.Tool_call _ ->
          (* Reconciled durably from the terminal response; never early-run. *)
          ())

and ensure_checkpoint t ~turn =
  let current =
    match t.turn_checkpoint with
    | Some (id, _) -> Mentat_session.Turn.Id.equal id turn
    | None -> false
  in
  if not current then begin
    (* A recovered turn ([possibly_mutating]) must not trust its
       pre-crash [Before_turn_tools] capture — the crash window may hold writes
       completed after it. Capture fresh at the distinct [After_recovery]
       boundary and clear the warning against THAT; a clean turn captures its
       pre-tools boundary. *)
    let boundary =
      if t.possibly_mutating then Mentat_mutation.Checkpoint.After_recovery turn
      else Mentat_mutation.Checkpoint.Before_turn_tools turn
    in
    let available_id cp =
      match Mentat_mutation.Checkpoint.snapshot cp with
      | Some _ -> Some (Mentat_mutation.Checkpoint.id cp)
      | None -> None
    in
    let record cp =
      let snapshot = available_id cp in
      t.turn_checkpoint <- Some (turn, snapshot);
      (* Recovery uncertainty is discharged only by usable rollback evidence.
         A degraded [After_recovery] capture still records the boundary (and is
         therefore not recaptured during this drive), but cannot prove that the
         possibly-mutating condition ended. The same law applies whether the
         boundary was replayed or captured below. *)
      if t.possibly_mutating && Option.is_some snapshot then
        t.possibly_mutating <- false
    in
    match Mentat_mutation.State.checkpoint_at t.mstate boundary with
    | Some cp ->
        (* The boundary is its identity: one capture per boundary per turn, so a
           re-entry that already captured this boundary proceeds on it — the
           lookup routes through the library's own fold, never a raw event
           scan. *)
        record cp
    | None -> (
        let cp = (workspace t).Ports.checkpoint ~boundary in
        let event = Mentat_mutation.Event.checkpoint cp in
        match t.io.append_mutation [ event ] with
        | Error e -> raise (Store_failed e)
        | Ok mstate ->
            t.mstate <- mstate;
            record cp)
  end

(* The controller stays live while the worker runs: it selects between the
   worker's completion and its mailbox, handling the durable-first interrupt
   and the journal commands that are legal mid-effect. *)
and supervise t ~done_p ~sw_cell ~turn =
  let wake =
    Eio.Fiber.first
      (fun () -> `Done (Eio.Promise.await done_p))
      (fun () ->
        Eio.Condition.loop_no_mutex t.cond (fun () ->
            if Queue.is_empty t.mailbox then None else Some `Mail))
  in
  match wake with
  | `Done outcome -> outcome
  | `Mail -> (
      match Queue.take_opt t.mailbox with
      | None -> supervise t ~done_p ~sw_cell ~turn
      | Some msg -> (
          match msg with
          | Command (Mentat_protocol.Command.Interrupt { reason; _ }, ack) ->
              interrupt_worker t ~done_p ~sw_cell ~turn ~reason ~ack:(fun r ->
                  Eio.Promise.resolve ack r)
          | Stop ->
              t.stopping <- true;
              interrupt_worker t ~done_p ~sw_cell ~turn
                ~reason:(Some "shutting down") ~ack:ignore
          | msg ->
              handle_any t msg ~mid_effect:true;
              supervise t ~done_p ~sw_cell ~turn))

and interrupt_worker t ~done_p ~sw_cell ~turn ~reason ~ack =
  let event = Mentat_session.Event.interrupt_requested ~turn ?reason () in
  match commit_events t [ event ] with
  | Error e ->
      ack (Error (unavailable e));
      supervise t ~done_p ~sw_cell ~turn
  | Ok () ->
      (* Durable first, then acknowledge, then the dual cancel: the atomic flag
         for cooperative polls and the worker switch for Eio scopes. The
         switch-fail is the sole prompt cancel of a blocking transport read —
         [cancelled] is polled only between provider events, so a fiber parked
         in a native Eio read observes the flag only once that read returns;
         failing the worker scope aborts the parked read at once. *)
      ack (Ok ());
      t.interrupt_reason <- reason;
      Atomic.set t.flag true;
      (match !sw_cell with
      | Some sw -> (
          try Eio.Switch.fail sw Interrupted_by_driver with _ -> ())
      | None -> ());
      Eio.Promise.await done_p

(* Settlement — one bounded protected region.

   Each branch computes the feed-back step, commits it, and returns it; the
   caller leaves protection before advancing. *)

and feed_commit t f =
  match f t.session with
  | Error e -> Error (Error.of_step e)
  | Ok step -> (
      match commit_step t step with Error e -> Error e | Ok () -> Ok step)

and settle t eff ~outcome ~buffer ~stream_usage ~closer =
  match eff with
  | Mentat_agent_step.Step.Effect.Model { claim; purpose; _ } ->
      let id = Mentat_session.Provider_request.Started.id claim in
      let prose =
        let text = String.trim (Buffer.contents buffer) in
        if String.equal text "" then None else Some text
      in
      settle_model t ~id ~purpose ~prose ~stream_usage outcome
  | Mentat_agent_step.Step.Effect.Tool { claim; _ } ->
      let id = Mentat_session.Tool_claim.Started.id claim in
      let turn = Mentat_session.Tool_claim.Started.turn claim in
      settle_tool_effect t ~id ~turn ~closer outcome

and settle_model t ~id ~purpose ~prose ~stream_usage outcome =
  match outcome with
  | Ok (Model_work (Ok response)) -> (
      match purpose with
      | `Turn ->
          feed_commit t (fun s ->
              Mentat_agent_step.accept_response (env t) id response s)
      | `Compaction (reason, summarized_upto) ->
          install_summary t ~id ~reason ~summarized_upto response)
  | Ok (Model_work (Error err)) -> (
      match Mentat_llm.Error.kind err with
      | Mentat_llm.Error.Cancelled
        when Mentat_session.State.interrupt_requested (state t) ->
          feed_commit t (fun s ->
              Mentat_agent_step.interrupt ?reason:t.interrupt_reason
                ?assistant_text:prose ?usage:!stream_usage s)
      | Mentat_llm.Error.Context_overflow -> (
          match purpose with
          | `Turn ->
              (* Per-turn overflow recovery: the step settles the claim
                 Failed and either keeps the turn active for one
                 compaction-and-retry or, having already spent the turn's overflow
                 compaction, finishes it Failed. *)
              feed_commit t (fun s ->
                  Mentat_agent_step.settle_provider_overflow (env t) id err s)
          | `Compaction (reason, _) ->
              (* A summary request that itself overflows is an ordinary failed
                 compaction — no recovery on the recovery. *)
              compaction_failed t ~reason
                ~message:(Mentat_llm.Error.message err);
              feed_commit t (fun s ->
                  Mentat_agent_step.settle_provider_failed id err s))
      | _ -> (
          match purpose with
          | `Turn ->
              feed_commit t (fun s ->
                  Mentat_agent_step.settle_provider_failed id err s)
          | `Compaction (reason, _) ->
              compaction_failed t ~reason
                ~message:(Mentat_llm.Error.message err);
              feed_commit t (fun s ->
                  Mentat_agent_step.settle_provider_failed id err s)))
  | Ok (Tool_work _) ->
      Error (internal_error (Failure "model effect yielded a tool outcome"))
  | Error Interrupted_by_driver ->
      feed_commit t (fun s ->
          Mentat_agent_step.interrupt ?reason:t.interrupt_reason
            ?assistant_text:prose ?usage:!stream_usage s)
  | Error (Store_failed e) -> Error (Error.Store e)
  | Error _exn ->
      (* A callback exception does not prove the call produced no effects:
         the live Ambiguous mint. *)
      feed_commit t (fun s -> Mentat_agent_step.settle_provider_ambiguous id s)

and install_summary t ~id ~reason ~summarized_upto response =
  let usable =
    (not (Mentat_llm.Response.has_tool_calls response))
    && not (String.equal (String.trim (Mentat_llm.Response.text response)) "")
  in
  if usable then
    feed_commit t (fun s ->
        Mentat_agent_step.install_summary (env t) id
          ~summary:[ Mentat_llm.Response.message response ]
          ~reason ~summarized_upto
          ?usage:(Mentat_llm.Response.usage response)
          s)
  else begin
    (* A failed or empty summary is a flow failure, never a durable
       fact — but the summary call's claim is durable and must
       close. The proven-failure arm closes it honestly. *)
    compaction_failed t ~reason ~message:"summary response was unusable";
    let err =
      Mentat_llm.Error.make ~kind:Mentat_llm.Error.Decode
        "compaction summary response was empty or carried tool calls"
    in
    feed_commit t (fun s -> Mentat_agent_step.settle_provider_failed id err s)
  end

and compaction_failed t ~reason ~message =
  match active_turn t with
  | None -> ()
  | Some turn ->
      pulse t
        (Mentat_protocol.Progress.Compaction
           {
             turn = Mentat_session.Turn.id turn;
             update =
               Mentat_protocol.Progress.Compaction.Failed { reason; message };
           })

(* Mid-turn workspace intake. The producers are drained again as each tool claim
   settles, so an observation the world made during the turn — the build verdict
   that followed the model's own edit, a file the user changed in their editor —
   reaches the turn that saw it instead of waiting for the next one. A tool
   settlement is the boundary a turn request all but always follows, since the
   model must be shown the tool's result; it is not a guarantee, so what a turn
   records without stating pends in session state — replay-derived, no
   driver memory — and rides the next request whichever turn issues it. *)
and drain_workspace_notices t =
  match active_turn t with
  | None -> Ok ()
  (* A turn under an interrupt admits settlements and nothing else, so recording
     an observation against it would be refused and the refusal would fault the
     driver. Nothing is taken either: an undrained producer keeps what it holds
     for the next turn's preparation, which is both durable and free, whereas
     draining here would move it into driver memory — lost outright when the
     interrupt is a shutdown — and would put a build probe and a workspace walk
     on the path the user is waiting to see stop. *)
  | Some _ when Mentat_session.State.interrupt_requested (state t) -> Ok ()
  | Some _ -> (
      match (workspace t).Ports.drain_notices () with
      | [] -> Ok ()
      | notices -> (
          let events =
            List.map
              (fun notice ->
                Mentat_session.Event.workspace_notice
                  (session_notice_of_workspace notice))
              notices
          in
          match commit_events t events with
          | Error e -> Error e
          | Ok () -> Ok ()))

and settle_tool_effect t ~id ~turn ~closer outcome =
  let evidence = Option.map (fun close -> close ()) !closer in
  match append_evidence t ~turn ~claim:id evidence with
  | Error e -> Error e
  | Ok () -> (
      (* An outcome that settles the claim reaches a model boundary on every
         ordinary path — the model must be shown the result — so the workspace
         is drained first and rides that same request. The turn can still end at
         this boundary instead (its step cap, a refused review, an interrupt
         recorded while the tool ran); what it recorded without stating then
         pends in session state for the next request. A driver-side interrupt
         or a store failure ends the turn outright and drains nothing. *)
      let settling f =
        match drain_workspace_notices t with
        | Error e -> Error e
        | Ok () -> feed_commit t f
      in
      match outcome with
      | Ok (Tool_work call_outcome) ->
          settling (fun s ->
              Mentat_agent_step.settle_tool (env t) id call_outcome s)
      | Ok (Model_work _) ->
          Error (internal_error (Failure "tool effect yielded a model outcome"))
      | Error Interrupted_by_driver ->
          feed_commit t (fun s ->
              Mentat_agent_step.interrupt ?reason:t.interrupt_reason s)
      | Error (Store_failed e) -> Error (Error.Store e)
      | Error _exn ->
          (* The exception does not prove the callback produced no effects. *)
          settling (fun s ->
              Mentat_agent_step.settle_tool_ambiguous (env t) id s))

and append_evidence t ~turn ~claim evidence =
  match evidence with
  | None -> Ok ()
  | Some { Mentat_edit.Apply_evidence.applies; observed } -> (
      let checkpoint =
        match t.turn_checkpoint with Some (_, id) -> id | None -> None
      in
      (* One loop, one ordinal counter over the chronological applies: an empty
         successful result records no event and does not consume an ordinal, so
         density (the k-th recorded apply carries ordinal k) holds across
         successes and commit-phase attempts alike. An attempt always left
         workspace effect, so it always records and consumes an ordinal;
         [entries] carries the confirmed bytes (an uncertain-only attempt
         appends its event with no blobs). *)
      let lower ordinal = function
        | Mentat_edit.Apply_evidence.Applied result ->
            if Mentat_edit.Result.is_empty result then None
            else
              let event =
                Mentat_mutation.Event.of_edit ~turn ~claim ~ordinal ~checkpoint
                  result
              in
              Some (Mentat_edit.Result.entries result, event)
        | Mentat_edit.Apply_evidence.Attempted
            { Mentat_edit.Apply_evidence.Attempt.applied; uncertain } ->
            let event =
              Mentat_mutation.Event.of_attempt ~turn ~claim ~ordinal ~checkpoint
                ~applied ~uncertain
            in
            Some (applied, event)
      in
      let rec applies_loop ordinal = function
        | [] -> Ok ()
        | apply :: rest -> (
            match lower ordinal apply with
            | None -> applies_loop ordinal rest
            | Some (entries, event) -> (
                match t.io.append_edit ~entries event with
                | Error e -> Error (Error.Store e)
                | Ok mstate ->
                    t.mstate <- mstate;
                    applies_loop (ordinal + 1) rest))
      in
      match applies_loop 0 applies with
      | Error e -> Error e
      | Ok () -> (
          match observed with
          | [] -> Ok ()
          | paths -> (
              let event =
                Mentat_mutation.Event.tool_observed ~turn ~claim paths
              in
              match t.io.append_mutation [ event ] with
              | Error e -> Error (Error.Store e)
              | Ok mstate ->
                  t.mstate <- mstate;
                  Ok ())))

(* Command intake. *)

and handle_any t msg ~mid_effect =
  match msg with
  | Command (command, ack) -> (
      let resolve r = Eio.Promise.resolve ack r in
      match t.phase with
      | Faulted e -> resolve (Error (unavailable e))
      | _ -> handle_command t command ~mid_effect ~ack:resolve)
  | Unattended (decision, ack) -> (
      let resolve r = Eio.Promise.resolve ack r in
      match t.phase with
      | Faulted e -> resolve (Error (unavailable e))
      | _ ->
          answer_decision t ~decision
            ~answer:
              (Mentat_session.Decision.Answer.Permission
                 { answer = Mentat_permission.Answer.deny; message = None })
            ~by:Mentat_session.Principal.unattended_policy ~ack:resolve)
  | Deliver -> (
      match t.phase with
      | Parked_children w when not mid_effect -> try_deliver t w
      | _ -> ())
  | Fork (id, ack) -> Eio.Promise.resolve ack (fork_flow t ~id)
  | Rewind (id, anchor, ack) ->
      Eio.Promise.resolve ack (rewind_flow t ~id anchor)
  | Compact (id, ack) -> compact_flow t ~id ~ack
  | Commit_metadata (transform, ack) -> commit_metadata_flow t ~transform ~ack
  | Revert (scope, ack) -> revert_flow t ~scope ~ack
  | Undo_op (op, ack) -> undo_flow t ~op ~ack
  | Export ack -> export_flow t ~ack
  | Enqueue (entry, ack) -> (
      let resolve r = Eio.Promise.resolve ack r in
      match t.phase with
      | Faulted e -> resolve (Error (unavailable e))
      | _ ->
          let id = Mentat_session.Queue.Entry.id entry in
          let delivered =
            (* A consumed entry's [Enqueued] fact still proves delivery: the
               session fold keeps the receipt past consumption. *)
            Mentat_session.State.enqueue_recorded id
              (Mentat_session.state t.session)
          in
          if delivered then resolve (Ok ())
          else
            journal_commit t ~ack:resolve
              [
                Mentat_session.Event.queue_updated
                  (Mentat_session.Queue.Update.enqueued entry);
              ])
  | Stop -> (
      t.stopping <- true;
      if not mid_effect then
        (* Closing the process is resource lifetime, not a user interrupt. A
           decision is already a durable suspension point, so release its
           fence without fabricating a terminal fact; recovery reconstructs
           [Await_decision] from the unchanged journal. A faulted driver
           likewise writes nothing further. Running effects are stopped
           by [supervise], while the remaining parked/running states retain the
           shutdown reconciliation below. *)
        match t.phase with
        | Faulted _ | Parked_decision _ -> ()
        | Running | Idle | Parked_children _ -> stop_active t)

and handle_command t command ~mid_effect ~ack =
  match command with
  | Mentat_protocol.Command.Prompt
      {
        turn;
        input;
        options;
        mode;
        max_steps;
        triggered;
        output_schema;
        _;
      } ->
      prompt t ~turn ~input ~options ~mode ~max_steps ~triggered ~output_schema
        ~ack
  | Mentat_protocol.Command.Answer_decision { decision; answer; _ } ->
      if mid_effect then
        ack (Error (Mentat_protocol.Error.Decision_not_pending decision))
      else
        answer_decision t ~decision ~answer
          ~by:Mentat_session.Principal.local_user ~ack
  | Mentat_protocol.Command.Interrupt { reason; _ } ->
      (* Mid-effect interrupts are consumed by [supervise]; this is the
         parked path. *)
      parked_interrupt t ~reason ~ack
  | Mentat_protocol.Command.Queue_next { input; _ } -> (
      match externalize_content t input with
      | Error e -> ack (Error e)
      | Ok input ->
          journal_commit t ~ack
            [
              Mentat_session.Event.queue_updated
                (Mentat_session.Queue.Update.enqueued
                   (Mentat_session.Queue.Entry.make ~id:(mint_queue_id t) ~input));
            ])
  | Mentat_protocol.Command.Replace_queued { inputs; _ } -> (
      let rec externalize_all acc = function
        | [] -> Ok (List.rev acc)
        | input :: rest -> (
            match externalize_content t input with
            | Error _ as error -> error
            | Ok content -> externalize_all (content :: acc) rest)
      in
      match externalize_all [] inputs with
      | Error e -> ack (Error e)
      | Ok inputs ->
          let entries =
            List.mapi
              (fun ordinal input ->
                Mentat_session.Queue.Entry.make
                  ~id:(mint_replacement_queue_id t ordinal)
                  ~input)
              inputs
          in
          journal_commit t ~ack
            [
              Mentat_session.Event.queue_updated
                (Mentat_session.Queue.Update.replaced entries);
            ])
  | Mentat_protocol.Command.Clear_queued _ ->
      journal_commit t ~ack
        [
          Mentat_session.Event.queue_updated Mentat_session.Queue.Update.cleared;
        ]

and journal_commit t ~ack events =
  match commit_events t events with
  | Error e -> ack (Error (unavailable e))
  | Ok () -> ack (Ok ())

and prompt t ~turn ~input ~options ~mode ~max_steps ~triggered ~output_schema
    ~ack =
  (* The engine mints the turn input from the command's content after admission:
     [Command.Prompt] carries content, never the engine-only [Continue]. The
     content is non-empty by the command constructor's contract. Inline
     [`Base64] media is externalized to attachment [`Ref]s first, so the
     [Turn_started] fact holds only references. *)
  match externalize_content t input with
  | Error e -> ack (Error e)
  | Ok input -> (
      let input = Mentat_session.Turn.Input.user input in
      match Mentat_session.State.turn turn (state t) with
      | Some existing ->
          if
            Mentat_session.Turn.Input.equal
              (Mentat_session.Turn.input existing)
              input
          then ack (Ok ())
          else ack (Error (Mentat_protocol.Error.Turn_id_reused turn))
      | None -> (
          match active_turn t with
          | Some active ->
              ack
                (Error
                   (Mentat_protocol.Error.Active_turn_exists
                      (Mentat_session.Turn.id active)))
          | None -> (
              if t.stopping then ack (Error (unavailable Error.Shutting_down))
              else
                match
                  t.resolve
                    ~latest_model:(Mentat_session.State.latest_model (state t))
                with
                | Error d -> ack (Error (unavailable (Error.Configuration d)))
                | Ok cfg ->
                    (* Trigger provenance is attribution, never authority: it
                       selects the minted origin and changes nothing else
                       about admission. *)
                    let origin =
                      match triggered with
                      | None -> Mentat_session.Turn.Origin.User
                      | Some { Mentat_protocol.Command.charter; digest; key } ->
                          Mentat_session.Turn.Origin.triggered ~charter ~digest
                            ~key
                    in
                    start_turn t cfg
                      ~mode:
                        (Option.value mode
                           ~default:Mentat_session.Contract.Mode.Build)
                      ~options ~max_steps ~id:turn ~input ~origin ~output_schema
                      ~ack:(fun r ->
                        ack (Result.map_error (fun e -> unavailable e) r)))))

and answer_decision t ~decision ~answer ~by ~ack =
  match t.phase with
  | Parked_decision requested
    when Mentat_session.Decision.Id.equal
           (Mentat_session.Decision.Requested.id requested)
           decision -> (
      match
        Mentat_agent_step.resolve_decision (env t) decision ~answered_by:by
          answer t.session
      with
      | Error (Mentat_agent_step.Error.Decision _) ->
          (* A wrong-kind or invalid answer reads as not-pending at the
             protocol boundary. *)
          ack (Error (Mentat_protocol.Error.Decision_not_pending decision))
      | Error e -> ack (Error (unavailable (Error.of_step e)))
      | Ok step -> (
          match commit_step t step with
          | Error e ->
              ack (Error (unavailable e));
              fault t e
          | Ok () ->
              ack (Ok ());
              act t step))
  | _ -> (
      match Mentat_session.State.decision decision (state t) with
      | Some (_, Some _) ->
          ack (Error (Mentat_protocol.Error.Already_resolved decision))
      | Some (_, None) | None ->
          ack (Error (Mentat_protocol.Error.Decision_not_pending decision)))

and parked_interrupt t ~reason ~ack =
  match active_turn t with
  | None -> ack (Error (Mentat_protocol.Error.No_active_turn t.io.session_id))
  | Some turn -> (
      let turn_id = Mentat_session.Turn.id turn in
      let event =
        Mentat_session.Event.interrupt_requested ~turn:turn_id ?reason ()
      in
      match commit_events t [ event ] with
      | Error e -> ack (Error (unavailable e))
      | Ok () -> (
          ack (Ok ());
          t.interrupt_reason <- reason;
          match t.phase with
          | Parked_children w ->
              (* Cascade semantically, await committed terminals, then
                 answer the wait from the children's terminal states before
                 the parent settles. *)
              t.hooks.cancel_children
                w.Mentat_agent_step.Step.Children_wait.children;
              try_deliver t w;
              if has_active_turn t then finish_interrupt t ~reason
          | _ -> finish_interrupt t ~reason))

and finish_interrupt t ~reason =
  match Mentat_agent_step.interrupt ?reason t.session with
  | Error e -> fault t (Error.of_step e)
  | Ok step -> drive t step

and has_active_turn t = Option.is_some (active_turn t)

and stop_active t =
  if has_active_turn t then
    parked_interrupt t ~reason:(Some "shutting down") ~ack:ignore

(* Flows. *)

(* The mutation ledger a branch child copies: the prefix of this driver's
   replayed history that references only the child's retained turns. A fork keeps
   every turn, so the whole ledger; a rewind keeps the anchored prefix. Blobs and
   ledger are seeded before the child document by the store's fork op. *)
and branch_events t child =
  let kept turn =
    Option.is_some (Mentat_session.State.turn turn (Mentat_session.state child))
  in
  Mentat_mutation.State.prefix_for_turns t.mstate ~keep:kept

and fork_flow t ~id =
  let cwd = Mentat_session.Metadata.cwd (Mentat_session.metadata t.session) in
  match Mentat_session.fork ~id ~cwd ~created_at:(t.now ()) t.session with
  | Error e -> Error (Error.Session e)
  | Ok forked -> (
      match t.io.fork ~events:(branch_events t forked) forked with
      | Error e -> Error (Error.Store e)
      | Ok () -> Ok id)

and rewind_flow t ~id anchor =
  let cwd = Mentat_session.Metadata.cwd (Mentat_session.metadata t.session) in
  match
    Mentat_session.rewind ~id ~cwd ~created_at:(t.now ()) anchor t.session
  with
  | Error e -> Error (Error.Session e)
  | Ok rewound -> (
      match t.io.fork ~events:(branch_events t rewound) rewound with
      | Error e -> Error (Error.Store e)
      | Ok () -> Ok id)

(* Manual compaction. *)

and active_turn_error id =
  unavailable
    (Error.Session
       (Mentat_session.Error.State
          (Mentat_session.State.Error.Turn
             (Mentat_session.State.Error.Turn.Active id))))

and compact_flow t ~id ~ack =
  (* Find-or-create on the client-minted compaction turn id (mirroring a
     prompt's client-minted turn). A wire retry resolves the same
     id: an already-installed compaction returns [Installed] without a second
     summary call, and a [Skipped] mints no turn so re-evaluating the idle head
     re-derives [Skipped] with no provider call either. The found-turn check
     precedes the active-turn guard, exactly as {!prompt} orders its own. *)
  let resolve r = Eio.Promise.resolve ack r in
  match t.phase with
  | Faulted e -> resolve (Error (unavailable e))
  | Running | Idle | Parked_decision _ | Parked_children _ -> (
      match Mentat_session.State.turn id (state t) with
      | Some existing ->
          if
            Mentat_session.Turn.Origin.equal
              (Mentat_session.Turn.origin existing)
              Mentat_session.Turn.Origin.Compaction
          then
            (* A replay of this compaction: its recorded terminal outcome is the
               result. An unfinished compaction turn is the one still in flight —
               its result is not yet derivable, so name the honest active id. *)
            resolve
              (match Mentat_session.State.turn_outcome id (state t) with
              | Some outcome -> compaction_result_of_outcome outcome
              | None -> Error (active_turn_error id))
          else
            (* The id already names a non-compaction turn: the same reuse
               discipline a prompt enforces on its client-minted id. *)
            resolve (Error (Mentat_protocol.Error.Turn_id_reused id))
      | None -> (
          match active_turn t with
          | Some active ->
              (* Manual compaction requires an idle head — a turn is running, so
                 refuse without touching the journal (the CLI guards this
                 offline; this is the live backstop). *)
              resolve
                (Error (active_turn_error (Mentat_session.Turn.id active)))
          | None -> (
              match
                t.resolve
                  ~latest_model:(Mentat_session.State.latest_model (state t))
              with
              | Error d -> resolve (Error (unavailable (Error.Configuration d)))
              | Ok cfg -> compact_start t cfg ~id ~ack)))

(* The idle-head guard the metadata, revert, and export flows share: refuse when
   faulted, refuse mid-turn with the active-turn error, and otherwise run [body]
   at the quiescent head. Polymorphic in the ack's result so one guard serves all
   three. Compaction does not use it — its found-turn check must precede the
   active-turn guard so a wire retry of a completed compaction returns the
   idempotent outcome rather than [active_turn_error]. *)
and with_idle_head :
    'ok.
    t ->
    ack:('ok, Mentat_protocol.Error.t) result Eio.Promise.u ->
    ((('ok, Mentat_protocol.Error.t) result -> unit) -> unit) ->
    unit =
 fun t ~ack body ->
  let resolve r = Eio.Promise.resolve ack r in
  match t.phase with
  | Faulted e -> resolve (Error (unavailable e))
  | Running | Idle | Parked_decision _ | Parked_children _ -> (
      match active_turn t with
      | Some active ->
          resolve (Error (active_turn_error (Mentat_session.Turn.id active)))
      | None -> body resolve)

(* Metadata commit (rename/archive/restore/delete) at a driven session's idle
   point: the online lifecycle cone. It reuses compact's idle guard —
   a running turn refuses with the active-turn error rather than CAS mid-turn
   (plan risk #2) — but is {b synchronous}: it applies the pure [transform] to the
   held session and CAS-saves its metadata inline, with no async resolver over a
   provider call. Success adopts the new revision (see {!commit_metadata_committed}).
   It creates nothing under the [~background] switch. *)
and commit_metadata_flow t ~transform ~ack =
  with_idle_head t ~ack (fun resolve ->
      match transform t.session with
      | Error _ as e -> resolve e
      | Ok session' -> (
          match commit_metadata_committed t session' with
          | Ok () -> resolve (Ok ())
          | Error e -> resolve (Error (unavailable e))))

(* The online revert cone at a driven session's idle point: the
   port op resolves the scope, captures a [Before_revert] checkpoint, freezes the
   plan, applies it, and settles — all under the held fence, {b synchronously}.
   Success adopts the re-read mutation state the port returns, so the driver's
   ledger mirror reflects the revert facts a subsequent turn's checkpoint and a
   branch's copied prefix depend on (the mutation analogue of
   {!commit_metadata_committed}'s revision adoption). A store [Conflict] under the
   held fence surfaces loudly as [Unavailable] — never a silent retry. *)
and revert_flow t ~scope ~ack =
  with_idle_head t ~ack (fun resolve ->
      match t.io.revert ~scope with
      | Error e -> resolve (Error (unavailable (Error.Store e)))
      | Ok (outcome, mstate) ->
          t.mstate <- mstate;
          resolve (Ok outcome))

(* The online undo cone at a driven session's idle point. Every operation
   re-derives the working tree from the arm-time baseline — un-revert the current
   armed revert, then revert the new crossed selection — and appends the durable
   boundary, adopting the re-read mutation state as {!revert_flow} does. A drift
   refusal surfaces as [Refused] messages and never touches the boundary; a
   no-op (no earlier turn, nothing armed) surfaces as [Refused] too so the TUI
   flashes it. The armed state and seam the client renders are pure functions of
   the projected [Fact.Undo] the boundary append emits. *)
and undo_flow t ~op ~ack =
  with_idle_head t ~ack (fun resolve ->
      let st = state t in
      let store_error e = resolve (Error (unavailable (Error.Store e))) in
      let refuse messages =
        resolve (Ok (Mentat_mutation.Revert.Outcome.Refused messages))
      in
      let ok outcome = resolve (Ok outcome) in
      let ordered = Mentat_session.State.turns st in
      let user_turn_ids =
        List.filter_map
          (fun turn ->
            let id = Mentat_session.Turn.id turn in
            if Mentat_session.State.can_undo_anchor id st then Some id else None)
          ordered
      in
      let current = Mentat_session.State.undo st in
      let current_anchor =
        Option.map (fun u -> u.Mentat_session.State.anchor) current
      in
      let crossed_from anchor =
        let rec from = function
          | [] -> []
          | turn :: rest ->
              if
                Mentat_session.Turn.Id.equal
                  (Mentat_session.Turn.id turn)
                  anchor
              then turn :: rest
              else from rest
        in
        List.map Mentat_session.Turn.id (from ordered)
      in
      let user_before anchor =
        let rec loop prev = function
          | [] -> None
          | id :: rest ->
              if Mentat_session.Turn.Id.equal id anchor then prev
              else loop (Some id) rest
        in
        loop None user_turn_ids
      in
      let user_after anchor =
        let rec loop = function
          | id :: (next :: _ as rest) ->
              if Mentat_session.Turn.Id.equal id anchor then Some next
              else loop rest
          | [ _ ] | [] -> None
        in
        loop user_turn_ids
      in
      let latest_user () =
        match List.rev user_turn_ids with id :: _ -> Some id | [] -> None
      in
      let un_revert () =
        match Option.bind current (fun u -> u.Mentat_session.State.revert) with
        | None -> Ok ()
        | Some rid -> (
            match
              Mentat_mutation.State.settled_revert t.mstate
                (Mentat_mutation.Revert.Id.of_string rid)
            with
            | None -> Ok ()
            | Some settled -> (
                match
                  List.map Mentat_mutation.Change.id
                    (Mentat_mutation.Revert.Settled.changes settled)
                with
                | [] -> Ok ()
                | ids -> (
                    match
                      t.io.undo_revert
                        (Mentat_mutation.Revert.Selection.changes ids)
                    with
                    | Error _ as error -> error
                    | Ok (_outcome, mstate) ->
                        t.mstate <- mstate;
                        Ok ())))
      in
      let commit_boundary ~outcome update =
        match commit_events t [ Mentat_session.Event.undo_updated update ] with
        | Ok () -> ok outcome
        | Error e -> resolve (Error (unavailable e))
      in
      let arm anchor =
        match crossed_from anchor with
        | [] -> refuse [ "nothing to undo" ]
        | crossed -> (
            match
              t.io.undo_revert (Mentat_mutation.Revert.Selection.turns crossed)
            with
            | Error e -> store_error e
            | Ok (Mentat_mutation.Revert.Outcome.Refused messages, _) ->
                refuse messages
            | Ok (Mentat_mutation.Revert.Outcome.Nothing_to_revert, mstate) ->
                t.mstate <- mstate;
                commit_boundary
                  ~outcome:Mentat_mutation.Revert.Outcome.Nothing_to_revert
                  (Mentat_session.Undo.Update.armed ~anchor ())
            | Ok (Mentat_mutation.Revert.Outcome.Applied settled, mstate) ->
                t.mstate <- mstate;
                let rid =
                  Mentat_mutation.Revert.Id.to_string
                    (Mentat_mutation.Revert.Settled.revert settled)
                in
                commit_boundary
                  ~outcome:(Mentat_mutation.Revert.Outcome.Applied settled)
                  (Mentat_session.Undo.Update.armed ~anchor ~revert:rid ()))
      in
      let step_to target =
        match un_revert () with
        | Error e -> store_error e
        | Ok () -> (
            match target with
            | `Release ->
                commit_boundary
                  ~outcome:Mentat_mutation.Revert.Outcome.Nothing_to_revert
                  Mentat_session.Undo.Update.released
            | `Arm anchor -> arm anchor)
      in
      match op with
      | Undo -> (
          if not (List.is_empty (Mentat_session.State.pending_queue st)) then
            refuse [ "clear the queue before undoing" ]
          else
            let target =
              match current_anchor with
              | None -> latest_user ()
              | Some anchor -> user_before anchor
            in
            match target with
            | None -> refuse [ "nothing to undo" ]
            | Some anchor -> step_to (`Arm anchor))
      | Redo -> (
          match current_anchor with
          | None -> refuse [ "nothing to redo" ]
          | Some anchor -> (
              match user_after anchor with
              | Some next -> step_to (`Arm next)
              | None -> step_to `Release))
      | Cancel -> (
          match current_anchor with
          | None -> ok Mentat_mutation.Revert.Outcome.Nothing_to_revert
          | Some _ -> step_to `Release))

(* The online export cone: the whole fenced bundle buffered into one value
   at an idle point. Like {!revert_flow} it refuses mid-turn — a coherent bundle
   is a quiescent read — but mutates nothing, so it adopts no state. The
   engine-level size guard bounds the buffered value before it crosses the
   wire. *)
and export_flow t ~ack =
  with_idle_head t ~ack (fun resolve ->
      match t.io.export () with
      | Error e -> resolve (Error (unavailable (Error.Store e)))
      | Ok bundle -> resolve (Ok bundle))

and compact_start t cfg ~id ~ack =
  let mode = Mentat_session.Contract.Mode.Build in
  let { Execution.catalog; workspace; policy; prelude = context_prelude } =
    select_execution t ~configured:cfg ~model:cfg.Config.model
      ~sealed_declarations:None mode
  in
  (* A compaction turn is not a user turn: it drains no workspace notices, so it
     carries no notice message. It does carry the same context prelude as a
     normal turn — the summarizer sees the workspace it is summarizing — which
     comes for free from the shared execution selection. *)
  let turn_env =
    build_env t ~context_prelude ~workspace catalog cfg ~max_steps:None
  in
  let contract = seal ~workspace catalog cfg ~policy ~mode ~options:None () in
  match Mentat_agent_step.compact turn_env contract ~id t.session with
  | Error e -> Eio.Promise.resolve ack (Error (unavailable (Error.of_step e)))
  | Ok Mentat_agent_step.Nothing_to_compact ->
      Eio.Promise.resolve ack (Ok Mentat_client.Driver.Skipped)
  | Ok (Mentat_agent_step.Compact_step step) ->
      t.execution <- Some (turn_env, workspace);
      t.compaction_pending <- Some (id, ack);
      drive t step

(* The controller. *)

let next_msg t =
  Eio.Condition.loop_no_mutex t.cond (fun () -> Queue.take_opt t.mailbox)

let serve t =
  let faulted t = match t.phase with Faulted _ -> true | _ -> false in
  let can_quiesce t =
    match t.phase with
    | Faulted _ | Parked_decision _ -> true
    | Running | Idle | Parked_children _ -> not (has_active_turn t)
  in
  let running = ref true in
  while !running do
    if t.stopping && can_quiesce t then running := false
    else begin
      let msg = next_msg t in
      contain t (fun () -> handle_any t msg ~mid_effect:false);
      (* The idle boundary: a command that landed on an idle session —
         a queue entry — may make an admission available now
         rather than at a settle that already passed. It reaches the same
         adapter and hook code a settle does (a queued spawn attaches its
         child here), so it is contained identically. *)
      if (not t.stopping) && (not (faulted t)) && not (has_active_turn t) then
        contain t (fun () -> admission t)
    end
  done

let recovery_execution t turn =
  match
    t.resolve ~latest_model:(Mentat_session.State.latest_model (state t))
  with
  | Error d -> Error (Error.Configuration d)
  | Ok cfg ->
      let mode =
        Mentat_session.Contract.mode (Mentat_session.Turn.contract turn)
      in
      let sealed = Mentat_session.Turn.contract turn in
      let {
        Execution.catalog;
        workspace;
        prelude = context_prelude;
        policy = _;
      } =
        select_execution t ~configured:cfg
          ~model:(Mentat_session.Contract.model sealed)
          ~sealed_declarations:
            (Some (Mentat_session.Contract.declarations sealed))
          mode
      in
      let env =
        build_env t ~context_prelude ~workspace catalog cfg ~max_steps:None
      in
      Ok (env, workspace)

let controller t =
  (* The nested per-session switch: a child of the shared runtime [sw], held
     across every turn and released here when [serve] returns — killing and
     reaping every background process spawned under it, leader-only, before the
     fence releases below. Binding the selector to it first makes the
     session's background-process registry available to every turn's catalog
     build. Its release also fires if the shared [sw] is cancelled by a sibling
     fault, so a crash reaps too. *)
  Eio.Switch.run (fun session_sw ->
      (* Bind the selector under the same fault boundary [start_turn] uses: a
         raising factory (a bad catalog build) faults only this driver — it never
         escapes to the shared [sw] to cancel siblings, and [serve] below still
         runs to quiesce and release the fence. A faulted driver leaves the
         selector unset; [serve] treats [Faulted] as quiescible and rejects
         turns, so the unset selector is never selected. *)
      contain t (fun () ->
          let select, running = t.execution_for_mode ~background:session_sw in
          t.select_execution <- Some select;
          t.running_view <- Some running);
      contain t (fun () ->
          match active_turn t with
          | None ->
              (* Preserve crash-time queue admission without speculatively
                 selecting a Build execution merely to recover an idle head. *)
              admission t
          | Some turn -> (
              match recovery_execution t turn with
              | Error e -> fault t e
              | Ok ((env, _) as execution) ->
                  t.execution <- Some execution;
                  let step = Mentat_agent_step.recover env t.session in
                  let ambiguous_tool =
                    List.exists
                      (function
                        | Mentat_session.Event.Tool_settled settled -> (
                            match
                              Mentat_session.Tool_claim.Settled.outcome settled
                            with
                            | Mentat_session.Tool_claim.Settled.Ambiguous ->
                                true
                            | _ -> false)
                        | _ -> false)
                      (Mentat_agent_step.Step.events step)
                  in
                  if ambiguous_tool then t.possibly_mutating <- true;
                  drive t step));
      (* [serve] contains its own message and admission work; wrapping it too
         keeps an unforeseen escape from skipping the fence release below. *)
      contain t (fun () -> serve t));
  t.io.release ();
  Eio.Promise.resolve (snd t.quiesced) ()

let create ~sw ~io ~hooks ~resolve ~execution_for_mode ~now ~depth ~session
    ~mutation ~hub =
  let t =
    {
      io;
      hooks;
      resolve;
      execution_for_mode;
      now;
      depth;
      sw;
      select_execution = None;
      running_view = None;
      hub;
      mailbox = Queue.create ();
      cond = Eio.Condition.create ();
      flag = Atomic.make false;
      session;
      mstate = mutation;
      execution = None;
      phase = Running;
      stopping = false;
      interrupt_reason = None;
      turn_checkpoint = None;
      possibly_mutating = false;
      compaction_pending = None;
      quiesced = Eio.Promise.create ();
    }
  in
  t

let start t = Eio.Fiber.fork ~sw:t.sw (fun () -> controller t)

(* The public seam. *)

let post t msg =
  Queue.push msg t.mailbox;
  Eio.Condition.broadcast t.cond

(* Post [make resolver] and await its ack — unless the driver is stopping. A
   post after [close] is never served, so its resolver would never resolve and
   the caller would hang; refusing up front with [when_stopping] is the parity
   the fork, rewind, and compact seams previously omitted. Each entry point
   supplies its own [when_stopping]: fork and rewind answer in the raw agent
   error, the rest in the protocol error. *)
let ask t ~when_stopping make =
  if t.stopping then when_stopping
  else begin
    let promise, resolver = Eio.Promise.create () in
    post t (make resolver);
    Eio.Promise.await promise
  end

let submit t command =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Command (command, resolver))

let answer_unattended t ~decision =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Unattended (decision, resolver))

let deliver t = post t Deliver

let enqueue t entry =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Enqueue (entry, resolver))

let fork t ~id =
  ask t ~when_stopping:(Error Error.Shutting_down) (fun resolver ->
      Fork (id, resolver))

let rewind t ~id ~anchor =
  ask t ~when_stopping:(Error Error.Shutting_down) (fun resolver ->
      Rewind (id, anchor, resolver))

let compact t ~turn =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Compact (turn, resolver))

let commit_metadata t ~transform =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Commit_metadata (transform, resolver))

let revert t ~scope =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Revert (scope, resolver))

let undo t ~op =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Undo_op (op, resolver))

let export t =
  ask t
    ~when_stopping:(Error (unavailable Error.Shutting_down))
    (fun resolver -> Export resolver)

let close t =
  post t Stop;
  Eio.Promise.await (fst t.quiesced)
