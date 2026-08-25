(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_session], the journal. The suite pins
   the mechanism laws and the replay invariant families:
   turn lifecycle, the single suspension, provider and tool claims including
   the two-claim staged lifecycle, decisions with their validation and
   derivations, interrupt admissibility, the compaction closer, boards,
   delegations, the queue, branch/rewind, and the durable codecs.

   Everything is tested through the [Mentat_session] facade. Prepared
   payloads are minted the only way the tool facade allows (decode + run of a
   staged tool), so the staged tests drive the same path production does.
   Replay-invalid resolutions are forged by decoding durable JSON — exactly
   the journal-edit surface [State.apply] guards. *)

open Windtrap
open Test_support
module Session = Mentat_session
module State = Session.State
module Event = Session.Event
module Llm = Mentat_llm
module Tool = Mentat_tool
module Permission = Mentat_permission
module Sandbox = Mentat_sandbox
module Json = Jsont.Json

(* Generic helpers. *)

let ok_or msg = function
  | Ok value -> value
  | Error _ -> failf "%s: unexpected error" msg

let rec pp_json ppf = function
  | Jsont.Null _ -> Format.pp_print_string ppf "null"
  | Jsont.Bool (b, _) -> Format.pp_print_bool ppf b
  | Jsont.Number (n, _) -> Format.pp_print_float ppf n
  | Jsont.String (s, _) -> Format.fprintf ppf "%S" s
  | Jsont.Array (elements, _) ->
      Format.fprintf ppf "[@[%a@]]"
        (Format.pp_print_list
           ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
           pp_json)
        elements
  | Jsont.Object (members, _) ->
      let pp_member ppf ((name, _), value) =
        Format.fprintf ppf "%S: %a" name pp_json value
      in
      Format.fprintf ppf "{@[%a@]}"
        (Format.pp_print_list
           ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
           pp_member)
        members

let assert_decode_error ?contains msg codec json =
  match Json.decode codec json with
  | Ok _ -> failf "%s: expected decode error" msg
  | Error actual -> (
      match contains with
      | None -> ()
      | Some fragment ->
          is_true
            ~msg:(msg ^ ": message is " ^ actual)
            (String.includes ~affix:fragment actual))

let encode_text codec value =
  match Jsont_bytesrw.encode_string codec value with
  | Ok text -> text
  | Error message -> failf "encode text: %s" message

(* Durable-JSON tampering helpers: patch an encoded object and decode it
   back, the journal-edit surface strict decoding guards. *)

let members_of = function
  | Jsont.Object (members, meta) -> (members, meta)
  | _ -> fail "expected a JSON object"

let add_member name value json =
  let members, meta = members_of json in
  Jsont.Object (members @ [ (Json.name name, value) ], meta)

let set_member name value json =
  let members, meta = members_of json in
  let members =
    List.map
      (fun ((n, m), v) ->
        if String.equal n name then ((n, m), value) else ((n, m), v))
      members
  in
  Jsont.Object (members, meta)

let get_member name json =
  let members, _ = members_of json in
  match List.find_opt (fun ((n, _), _) -> String.equal n name) members with
  | Some (_, value) -> value
  | None -> failf "missing %S member" name

(* LLM fixtures. *)

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider ~api ~id:"gpt-5"
let other_model = Llm.Model.make ~provider ~api ~id:"gpt-5-mini"
let cwd = Lpath.Abs.of_string_exn "/workspace"
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)
let digest seed = Mentat_digest.string seed
let usage ~input ~output = Llm.Usage.make ~input ~output ()

let tool_call ?(id = "call-1") ?(name = "read_file") ?(input = Json.object' [])
    ?signature () =
  Llm.Tool.Call.make ~id ~name ~input ?signature ()

let assistant_calls calls =
  Llm.Message.Assistant.make (List.map Llm.Message.Assistant.tool_call calls)

let declaration name =
  Llm.Tool.make ~name ~input_schema:Llm.Tool.no_input_schema ()

let messages_of transcript = Llm.Transcript.messages transcript

let tool_result_for call_id state =
  List.find_map
    (function
      | Llm.Message.Tool_result result
        when String.equal (Llm.Tool.Result.call_id result) call_id ->
          Some result
      | _ -> None)
    (messages_of (State.full_transcript state))

let result_text result = String.concat "\n" (Llm.Tool.Result.texts result)

let transcript_text transcript =
  let content_texts =
    List.filter_map (function
      | Llm.Content.Text text -> Some text
      | Llm.Content.Media _ -> None)
  in
  messages_of transcript
  |> List.concat_map (function
    | Llm.Message.System text | Llm.Message.Developer text -> [ text ]
    | Llm.Message.User content -> content_texts content
    | Llm.Message.Assistant assistant -> Llm.Message.Assistant.texts assistant
    | Llm.Message.Tool_result result -> Llm.Tool.Result.texts result)
  |> String.concat "\n"

(* Testables. *)

let state_error = Testable.make ~pp:State.Error.pp ~equal:( = )
let session_error = Testable.make ~pp:Session.Error.pp ~equal:( = )
let event_value = Testable.make ~pp:Event.pp ~equal:Event.equal

let turn_id_value =
  Testable.make ~pp:Session.Turn.Id.pp ~equal:Session.Turn.Id.equal

let turn_value = Testable.make ~pp:Session.Turn.pp ~equal:Session.Turn.equal

let outcome_value =
  Testable.make ~pp:Session.Turn.Outcome.pp ~equal:Session.Turn.Outcome.equal

let message_value = Testable.make ~pp:(fun _ _ -> ()) ~equal:Llm.Message.equal
let usage_value = Testable.make ~pp:Llm.Usage.pp ~equal:Llm.Usage.equal

let contract_value =
  Testable.make ~pp:Session.Contract.pp ~equal:Session.Contract.equal

let queue_entry_value =
  Testable.make ~pp:Session.Queue.Entry.pp ~equal:Session.Queue.Entry.equal

let board_value =
  Testable.make ~pp:Session.Task.Board.pp ~equal:Session.Task.Board.equal

let delegation_value =
  Testable.make ~pp:Session.Delegation.pp ~equal:Session.Delegation.equal

let compaction_value =
  Testable.make ~pp:Session.Compaction.pp ~equal:Session.Compaction.equal

let metrics_value =
  Testable.make ~pp:Session.Metrics.pp ~equal:Session.Metrics.equal

let prepared_value =
  Testable.make
    ~pp:(fun ppf p ->
      Format.fprintf ppf "prepared(%s, %s)" (Tool.Prepared.tool p)
        (Tool.Prepared.description p))
    ~equal:Tool.Prepared.equal

let rule_value =
  Testable.make ~pp:Permission.Policy.Rule.pp
    ~equal:Permission.Policy.Rule.equal

let resolve_error_value =
  Testable.make ~pp:Session.Decision.Resolve_error.pp ~equal:( = )

let json_value = Testable.make ~pp:pp_json ~equal:Json.equal

(* Permission fixtures. *)

let access ?subject name = Permission.Access.custom ?subject name

let request_for subject =
  Permission.Request.of_accesses [ access ~subject "session.test" ]

let review ?(reason = Permission.Policy.Review.Unmatched) acc =
  let request = Permission.Request.of_accesses [ acc ] in
  ok_or "review reconstruction"
    (Permission.Policy.Review.restore request [ (acc, reason) ])

let allow_once = Permission.Answer.once
let allow_exact = Permission.Answer.exact_for_conversation
let deny = Permission.Answer.deny

(* Tool fixtures. *)

let output text = Tool.Output.make ~text ()
let completed text = Tool.Result.completed ~output:(output text) ()

let text_input =
  let codec =
    Jsont.Object.map ~kind:"staged input" Fun.id
    |> Jsont.Object.mem "text" Jsont.string ~enc:Fun.id
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
  in
  Tool.Input.make codec ~schema:(json_object [ ("type", Json.string "object") ])

let input_json text = json_object [ ("text", Json.string text) ]

type plan_payload = { target : string; count : int }

let plan_jsont =
  let make target count = { target; count } in
  Jsont.Object.map ~kind:"staged plan" make
  |> Jsont.Object.mem "target" Jsont.string ~enc:(fun p -> p.target)
  |> Jsont.Object.mem "count" Jsont.int ~enc:(fun p -> p.count)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let describe_plan p = Printf.sprintf "write %s %d times" p.target p.count

let staged_tool =
  Tool.make_staged ~name:"stager" ~description:"Stage a plan before running."
    ~input:text_input ~prepared:plan_jsont ~describe:describe_plan
    ~output:(fun text -> output text)
    ~prepare_permissions:(fun input -> [ request_for ("prepare " ^ input) ])
    ~prepare:(fun ~cancelled:_ input ->
      `Prepared { target = input; count = String.length input })
    ~permissions:(fun plan -> [ request_for plan.target ])
    ~run:(fun ~cancelled:_ plan ->
      Tool.Result.completed ~output:(describe_plan plan) ())
    ()

let no_cancel () = false

let prepare_call text =
  let source = tool_call ~name:"stager" ~input:(input_json text) () in
  match Tool.Call.decode staged_tool source with
  | Ok call -> call
  | Error error ->
      failf "staged decode failed: %s" (Tool.Call.Decode_error.message error)

let prepared_payload text =
  match Tool.Call.run (prepare_call text) ~cancelled:no_cancel with
  | Tool.Call.Prepared prepared -> prepared
  | Tool.Call.Finished _ -> fail "expected a prepared outcome"

(* Session fixtures. *)

let sandbox_identity = Sandbox.identity Sandbox.direct
let external_identity = Sandbox.identity Sandbox.external_
let turn_id id = Session.Turn.Id.of_string id
let queue_id id = Session.Queue.Id.of_string id
let session_id id = Session.Id.of_string id

let make_contract ?(mode = Session.Contract.Mode.Build) ?(model = model)
    ?options ?(declarations = []) ?output_tool
    ?(policy = Permission.Policy.default)
    ?(review = Permission.Review_behavior.Enforce) ?(sandbox = sandbox_identity)
    () =
  Session.Contract.make ~mode ~model ?options ~declarations ?output_tool ~policy
    ~review ~sandbox ()

(* The synthetic structured-output tool a [--output-schema] turn seals on its
   contract; its input schema is the caller's JSON Schema. *)
let structured_output_tool =
  Llm.Tool.make ~name:"structured_output"
    ~input_schema:(json_object [ ("type", Json.string "object") ])
    ()

let turn ?(id = "turn-1") ?(origin = Session.Turn.Origin.User)
    ?(input = Session.Turn.Input.user_text "Refactor.") ?(max_steps = 32)
    ?contract () =
  let contract =
    match contract with Some contract -> contract | None -> make_contract ()
  in
  Session.Turn.make ~id:(turn_id id) ~origin ~input ~max_steps ~contract ()

let claim ?(seed = "req-1") turn =
  Session.Provider_request.Started.make ~turn ~request_digest:(digest seed)

let claim_id claim = Session.Provider_request.Started.id claim

let settle_responded ?(model = model) ?usage claim assistant =
  Event.provider_settled
    (Session.Provider_request.Settled.responded ~id:(claim_id claim)
       (Llm.Response.make ~model ?usage assistant))

let respond ?model ?usage claim text =
  settle_responded ?model ?usage claim (Llm.Message.Assistant.text text)

let settle_interrupted ?usage claim text =
  Event.provider_settled
    (Session.Provider_request.Settled.interrupted ~id:(claim_id claim) ?usage
       ~text ())

let settle_ambiguous claim =
  Event.provider_settled
    (Session.Provider_request.Settled.ambiguous ~id:(claim_id claim))

let provider_failure ?(kind = Llm.Error.Auth) message =
  Llm.Error.make ~kind ~provider message

let settle_failed ?kind ?(message = "authentication rejected") claim =
  Event.provider_settled
    (Session.Provider_request.Settled.failed ~id:(claim_id claim)
       (provider_failure ?kind message))

let tool_claim ?(stage = Tool.Stage.Direct) ?(input = Json.object' [])
    ?(requests = []) ~turn call =
  Session.Tool_claim.Started.make ~turn ~stage ~call ~input ~requests

let tool_claim_id claim = Session.Tool_claim.Started.id claim

let settled_returned claim result =
  Event.tool_settled
    (Session.Tool_claim.Settled.returned ~id:(tool_claim_id claim) result)

let settled_prepared claim prepared =
  Event.tool_settled
    (Session.Tool_claim.Settled.prepared ~id:(tool_claim_id claim) prepared)

let settled_ambiguous claim =
  Event.tool_settled
    (Session.Tool_claim.Settled.ambiguous ~id:(tool_claim_id claim))

let permission_decision ?(stage = Tool.Stage.Direct) ?reason ~turn ~call acc =
  Session.Decision.Requested.make ~turn ~call ~stage
    (Session.Decision.Request.Permission (review ?reason acc))

let resolve_ok ~msg requested ~call ~by answer =
  match Session.Decision.resolve requested ~call ~by answer with
  | Ok (resolved, _) -> resolved
  | Error error ->
      failf "%s: resolve failed: %a" msg Session.Decision.Resolve_error.pp error

let resolved ~msg requested ~call ~by answer =
  Event.decision_resolved (resolve_ok ~msg requested ~call ~by answer)

(* A resolution the [Decision.resolve] witness would refuse, forged through
   the durable codec: validation is replay's job. *)
let forged_resolution id ~by answer =
  decode Session.Decision.Resolved.jsont
    (json_object
       [
         ("id", Json.string (Session.Decision.Id.to_string id));
         ("answered_by", encode Session.Principal.jsont by);
         ("answer", encode Session.Decision.Answer.jsont answer);
       ])

let question ?choices prompt =
  ok_or "question" (Session.Question.make ~prompt ?choices ())

let plan ?title body = ok_or "plan" (Session.Plan.make ?title ~body ())

let plan_approval ?title ?feedback ~context body =
  let answer =
    Session.Plan.Answer.approve ~body:(plan ?title body) ~context ?feedback ()
  in
  match answer with
  | Session.Plan.Answer.Approve approval -> (approval, answer)
  | Session.Plan.Answer.Keep_planning | Session.Plan.Answer.Revise _ ->
      assert false

let approval ?title ?feedback ~context body =
  fst (plan_approval ?title ?feedback ~context body)

let task_item ?(owner = Session.Task.Owner.Main) ?status ?priority ~id ~position
    content =
  ok_or "task item"
    (Session.Task.Item.make
       ~id:(Session.Task.Id.of_string id)
       ~owner ~content ?status ?priority ~position ())

let board items = ok_or "board" (Session.Task.Board.make items)

let queue_entry ?(id = "q-1") text =
  Session.Queue.Entry.make ~id:(queue_id id) ~input:[ Llm.Content.text text ]

let finish ?(outcome = Session.Turn.Outcome.completed) t =
  Event.turn_finished ~turn:(Session.Turn.id t) outcome

(* State helpers. *)

let state events =
  match State.of_events events with
  | Ok state -> state
  | Error error ->
      failf "state reconstruction failed: %a" State.Replay_error.pp error

let expect_apply_error ~msg expected event state =
  match State.apply event state with
  | Ok _ -> failf "%s: expected a state error" msg
  | Error error -> equal state_error ~msg expected error

let expect_replay_error ~msg ?index expected events =
  match State.of_events events with
  | Ok _ -> failf "%s: expected a replay error" msg
  | Error error ->
      (match index with
      | Some index ->
          equal int ~msg:(msg ^ ": index") index
            (State.Replay_error.index error)
      | None -> ());
      equal state_error ~msg expected (State.Replay_error.cause error)

let expect_session_error ~msg expected = function
  | Ok _ -> failf "%s: expected a session error" msg
  | Error error -> equal session_error ~msg expected error

let suspension_equal a b =
  match (a, b) with
  | State.Provider a, State.Provider b ->
      Session.Provider_request.Started.equal a b
  | State.Tool a, State.Tool b -> Session.Tool_claim.Started.equal a b
  | State.Decision a, State.Decision b -> Session.Decision.Requested.equal a b
  | (State.Provider _ | State.Tool _ | State.Decision _), _ -> false

let pp_suspension ppf = function
  | State.Provider s ->
      Format.fprintf ppf "provider(%a)" Session.Provider_request.Started.pp s
  | State.Tool s ->
      Format.fprintf ppf "tool(%a)" Session.Tool_claim.Started.pp s
  | State.Decision d ->
      Format.fprintf ppf "decision(%a)" Session.Decision.Requested.pp d

let suspension_value = Testable.make ~pp:pp_suspension ~equal:suspension_equal

(* Structural equality of two replayed states over every exposed projection:
   the observable meaning of "equal inputs fold to equal states". *)
let assert_states_equal ~msg a b =
  let m sub = msg ^ ": " ^ sub in
  equal (list message_value) ~msg:(m "full transcript")
    (messages_of (State.full_transcript a))
    (messages_of (State.full_transcript b));
  equal (list message_value) ~msg:(m "model transcript")
    (messages_of (State.model_transcript a))
    (messages_of (State.model_transcript b));
  equal (option string) ~msg:(m "final text") (State.final_text a)
    (State.final_text b);
  equal
    (option (pair usage_value (list message_value)))
    ~msg:(m "replay usage") (State.replay_usage a) (State.replay_usage b);
  equal (option compaction_value) ~msg:(m "latest compaction")
    (State.latest_compaction a)
    (State.latest_compaction b);
  equal (list turn_value) ~msg:(m "turns") (State.turns a) (State.turns b);
  equal (option turn_id_value) ~msg:(m "active turn") (State.active_turn_id a)
    (State.active_turn_id b);
  equal (option suspension_value) ~msg:(m "suspension") (State.suspension a)
    (State.suspension b);
  equal bool ~msg:(m "interrupt")
    (State.interrupt_requested a)
    (State.interrupt_requested b);
  equal
    (option (Testable.of_equal Session.Plan.Approval.equal))
    ~msg:(m "approved plan") (State.approved_plan a) (State.approved_plan b);
  equal
    (list
       (pair
          (Testable.of_equal Session.Tool_claim.Started.equal)
          (option (Testable.of_equal Session.Tool_claim.Settled.equal))))
    ~msg:(m "tool claims") (State.tool_claims a) (State.tool_claims b);
  is_true ~msg:(m "grants")
    (Permission.Policy.Grants.equal (State.grants a) (State.grants b));
  equal (list rule_value) ~msg:(m "permission rules") (State.permission_rules a)
    (State.permission_rules b);
  equal board_value ~msg:(m "tasks") (State.tasks a) (State.tasks b);
  equal (list queue_entry_value) ~msg:(m "queue") (State.pending_queue a)
    (State.pending_queue b);
  equal (list delegation_value) ~msg:(m "delegations") (State.delegations a)
    (State.delegations b)

(* The canonical journal. *)

(* A realistic three-turn journey exercising every fact family: a user turn
   with a direct claim, a permission-reviewed claim, an unattended denial, the
   staged pair, a host rejection append, queue/board/delegation facts; a
   triggered turn with a mid-turn compaction; and a queued turn that is
   interrupted. It backs the replay-algebra, determinism, document round-trip,
   and metrics tests. *)

type journal = {
  events : Event.t list;
  t1 : Session.Turn.t;
  t2 : Session.Turn.t;
  t3 : Session.Turn.t;
  probe_access : Permission.Access.t;
  risky_access : Permission.Access.t;
  prepared : Tool.Prepared.t;
  compaction : Session.Compaction.t;
  journal_board : Session.Task.Board.t;
  edge : Session.Delegation.t;
}

let journal () =
  let declarations =
    [
      declaration "read_file";
      declaration "probe";
      Tool.declaration staged_tool;
      declaration "free_form";
      declaration "risky";
    ]
  in
  let t1 =
    turn ~id:"turn-1"
      ~input:(Session.Turn.Input.user_text "Refactor the parser.")
      ~contract:(make_contract ~declarations ())
      ()
  in
  let t1_id = Session.Turn.id t1 in
  let c_direct = tool_call ~id:"call-direct" ~name:"read_file" () in
  let c_probe = tool_call ~id:"call-probe" ~name:"probe" () in
  let c_staged =
    tool_call ~id:"call-staged" ~name:"stager" ~input:(input_json "alpha") ()
  in
  let c_free = tool_call ~id:"call-free" ~name:"free_form" () in
  let c_risky = tool_call ~id:"call-risky" ~name:"risky" () in
  let probe_access = access ~subject:"probe" "session.review" in
  let risky_access = access ~subject:"risky" "session.review" in
  let p1 = claim ~seed:"t1-req-1" t1_id in
  let direct_claim = tool_claim ~turn:t1_id c_direct in
  let d_probe = permission_decision ~turn:t1_id ~call:c_probe probe_access in
  let probe_claim = tool_claim ~turn:t1_id c_probe in
  let d_risky = permission_decision ~turn:t1_id ~call:c_risky risky_access in
  let prepare_boundary = prepare_call "alpha" in
  let prepared = prepared_payload "alpha" in
  let staged_prepare =
    tool_claim ~stage:Tool.Stage.Prepare
      ~input:(Tool.Call.input prepare_boundary)
      ~requests:(Tool.Call.permissions prepare_boundary)
      ~turn:t1_id c_staged
  in
  let d_run =
    permission_decision ~stage:Tool.Stage.Run ~turn:t1_id ~call:c_staged
      (access ~subject:"alpha" "session.review")
  in
  let staged_run =
    tool_claim ~stage:Tool.Stage.Run
      ~input:(Tool.Call.input prepare_boundary)
      ~requests:(Tool.Prepared.requests prepared)
      ~turn:t1_id c_staged
  in
  let p2 = claim ~seed:"t1-req-2" t1_id in
  let journal_board =
    board
      [
        task_item ~id:"task-1" ~position:0
          ~status:Session.Task.Status.In_progress
          ~priority:Session.Task.Priority.High "Parse the grammar";
        task_item ~id:"task-2" ~position:1 "Port the printer";
        task_item ~id:"task-3" ~position:2 ~priority:Session.Task.Priority.Low
          "Explore the corpus";
      ]
  in
  let edge =
    Session.Delegation.make ~child:(session_id "child-sess") ~source_turn:t1_id
      ~source_call:"call-direct"
      ~task:[ Llm.Content.text "Explore the corpus." ]
      ()
  in
  let t2 =
    turn ~id:"turn-2"
      ~origin:
        (Session.Turn.Origin.triggered ~charter:"nightly" ~digest:"d0"
           ~key:"k0")
      ~input:Session.Turn.Input.continue
      ~contract:(make_contract ~declarations ())
      ()
  in
  let t2_id = Session.Turn.id t2 in
  let p3 = claim ~seed:"t2-req-1" t2_id in
  let p4 = claim ~seed:"t2-summary" t2_id in
  let compaction =
    Session.Compaction.make ~reason:Session.Compaction.Reason.Context_pressure
      ~provider_claim:(claim_id p4) ~request_digest:(digest "t2-summary")
      ~summary_messages:[ Llm.Message.user_text "Earlier work, summarized." ]
      ~summarized_upto:8
      ~usage:(usage ~input:200 ~output:40)
      ~context:
        (Session.Compaction.Context_tokens.make ~before:9000 ~after:800 ())
      ()
  in
  let p5 = claim ~seed:"t2-req-2" t2_id in
  let t3 =
    turn ~id:"turn-3"
      ~origin:(Session.Turn.Origin.Queued (queue_id "q-1"))
      ~input:(Session.Turn.Input.user_text "Follow up.")
      ~contract:(make_contract ~declarations ())
      ()
  in
  let t3_id = Session.Turn.id t3 in
  let p6 = claim ~seed:"t3-req-1" t3_id in
  let events =
    [
      (* Turn 1: user turn, five tool calls, every consumption path. *)
      Event.turn_started t1;
      Event.provider_requested p1;
      settle_responded
        ~usage:(usage ~input:12 ~output:7)
        p1
        (assistant_calls [ c_direct; c_probe; c_staged; c_free; c_risky ]);
      Event.tool_claimed direct_claim;
      settled_returned direct_claim (completed "contents");
      Event.message_appended
        (Llm.Message.tool_result
           (Llm.Tool.Result.text ~error:true c_free "not handled"));
      Event.decision_requested d_probe;
      resolved ~msg:"probe allow" d_probe ~call:c_probe
        ~by:Session.Principal.local_user
        (Session.Decision.Answer.Permission
           { answer = allow_exact; message = None });
      Event.tool_claimed probe_claim;
      settled_returned probe_claim
        (Tool.Result.failed `Not_found "missing file");
      Event.decision_requested d_risky;
      resolved ~msg:"risky deny" d_risky ~call:c_risky
        ~by:Session.Principal.unattended_policy
        (Session.Decision.Answer.Permission { answer = deny; message = None });
      Event.tool_claimed staged_prepare;
      settled_prepared staged_prepare prepared;
      Event.decision_requested d_run;
      resolved ~msg:"run allow" d_run ~call:c_staged
        ~by:Session.Principal.local_user
        (Session.Decision.Answer.Permission
           { answer = allow_once; message = None });
      Event.tool_claimed staged_run;
      settled_returned staged_run (completed "write alpha 5 times");
      Event.queue_updated
        (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "Follow up."));
      Event.tasks_replaced journal_board;
      Event.delegation_recorded edge;
      Event.provider_requested p2;
      respond ~usage:(usage ~input:30 ~output:9) p2 "All done.";
      finish t1;
      (* Turn 2: triggered admission with a mid-turn compaction. *)
      Event.turn_started t2;
      Event.provider_requested p3;
      respond ~usage:(usage ~input:100 ~output:50) p3 "Working on the task.";
      Event.provider_requested p4;
      Event.compaction_installed compaction;
      Event.provider_requested p5;
      respond ~usage:(usage ~input:40 ~output:10) p5 "Task advanced.";
      finish t2;
      (* Turn 3: queued admission, then an interrupt. *)
      Event.turn_started t3;
      Event.provider_requested p6;
      Event.interrupt_requested ~turn:t3_id ~reason:"user stop" ();
      settle_interrupted p6 "Stopping here.";
      finish
        ~outcome:
          (Session.Turn.Outcome.interrupted ~reason:"user stop" ~cancelled:true
             ())
        t3;
    ]
  in
  {
    events;
    t1;
    t2;
    t3;
    probe_access;
    risky_access;
    prepared;
    compaction;
    journal_board;
    edge;
  }

let saved_metadata =
  Session.Metadata.make ~cwd ~created_at:(time 1) ~updated_at:(time 2) ()

let saved ?(id = "session-1") events =
  ok_or "session"
    (Session.make ~id:(session_id id) ~metadata:saved_metadata ~events)

(* Generators. *)

let ident_gen =
  Gen.(
    let+ c = char_range 'a' 'z'
    and+ rest = string_of ~size:(int_range 0 8) (char_range 'a' 'z') in
    String.make 1 c ^ rest)

let queue_update_gen =
  let entries_gen =
    Gen.map
      (fun texts ->
        List.mapi
          (fun i text -> queue_entry ~id:(Printf.sprintf "q-%d" i) text)
          texts)
      (Gen.list ~size:(Gen.int_range 0 4) ident_gen)
  in
  Gen.one_of
    [
      Gen.map
        (fun text ->
          Session.Queue.Update.enqueued (queue_entry ~id:"q-solo" text))
        ident_gen;
      Gen.map Session.Queue.Update.replaced entries_gen;
      Gen.pure Session.Queue.Update.cleared;
    ]

let status_gen =
  Gen.of_list Session.Task.Status.[ Pending; In_progress; Completed; Cancelled ]

let priority_gen = Gen.of_list Session.Task.Priority.[ High; Medium; Low ]

let board_gen =
  Gen.map
    (fun rows ->
      let seen = ref false in
      let items =
        List.mapi
          (fun i (content, status, priority) ->
            let status =
              match status with
              | Session.Task.Status.In_progress when !seen ->
                  Session.Task.Status.Pending
              | Session.Task.Status.In_progress ->
                  seen := true;
                  status
              | status -> status
            in
            task_item
              ~id:(Printf.sprintf "task-%d" i)
              ~position:i ~status ~priority content)
          rows
      in
      board items)
    (Gen.list ~size:(Gen.int_range 0 5)
       (Gen.triple ident_gen status_gen priority_gen))

let origin_gen =
  Gen.one_of
    [
      Gen.pure Session.Turn.Origin.User;
      Gen.map (fun s -> Session.Turn.Origin.Queued (queue_id s)) ident_gen;
      Gen.(
        let+ charter = ident_gen and+ digest = ident_gen and+ key = ident_gen in
        Session.Turn.Origin.Triggered { charter; digest; key });
      Gen.pure Session.Turn.Origin.Plan_build;
      Gen.pure Session.Turn.Origin.Compaction;
      Gen.pure Session.Turn.Origin.Step_limit_wind_down;
    ]

let outcome_gen =
  Gen.one_of
    [
      Gen.pure Session.Turn.Outcome.completed;
      Gen.pure Session.Turn.Outcome.step_limit;
      Gen.(
        let+ reason = Gen.option ident_gen and+ cancelled = Gen.bool in
        match reason with
        | Some reason -> Session.Turn.Outcome.interrupted ~reason ~cancelled ()
        | None -> Session.Turn.Outcome.interrupted ~cancelled ());
      Gen.map (fun message -> Session.Turn.Outcome.failed ~message) ident_gen;
    ]

let event_gen =
  Gen.one_of
    [
      Gen.map Event.queue_updated queue_update_gen;
      Gen.map Event.tasks_replaced board_gen;
      Gen.(
        let+ id = ident_gen
        and+ origin = origin_gen
        and+ text = ident_gen
        and+ max_steps = int_range 1 64
        and+ continue = Gen.bool in
        let input =
          if continue then Session.Turn.Input.continue
          else Session.Turn.Input.user_text text
        in
        Event.turn_started (turn ~id ~origin ~input ~max_steps ()));
      Gen.(
        let+ id = ident_gen and+ outcome = outcome_gen in
        Event.turn_finished ~turn:(turn_id id) outcome);
      Gen.(
        let+ id = ident_gen and+ reason = Gen.option ident_gen in
        match reason with
        | Some reason -> Event.interrupt_requested ~turn:(turn_id id) ~reason ()
        | None -> Event.interrupt_requested ~turn:(turn_id id) ());
      Gen.(
        let+ turn = ident_gen and+ seed = ident_gen in
        Event.provider_requested
          (Session.Provider_request.Started.make ~turn:(turn_id turn)
             ~request_digest:(digest seed)));
    ]

(* Derived ids. *)

let ids_group =
  group "derived ids"
    [
      test "provider claim ids derive from turn and request digest" (fun () ->
          let a = claim ~seed:"req" (turn_id "turn-1") in
          let b = claim ~seed:"req" (turn_id "turn-1") in
          is_true ~msg:"same inputs derive the same id"
            (Session.Provider_request.Id.equal (claim_id a) (claim_id b));
          let other_digest = claim ~seed:"req-2" (turn_id "turn-1") in
          let other_turn = claim ~seed:"req" (turn_id "turn-2") in
          is_false ~msg:"digest participates"
            (Session.Provider_request.Id.equal (claim_id a)
               (claim_id other_digest));
          is_false ~msg:"turn participates"
            (Session.Provider_request.Id.equal (claim_id a)
               (claim_id other_turn)));
      test "tool claim ids discriminate turn, call, and stage" (fun () ->
          let call = tool_call () in
          let base = tool_claim ~turn:(turn_id "turn-1") call in
          let same = tool_claim ~turn:(turn_id "turn-1") call in
          is_true ~msg:"crash re-drive recomputes the same id"
            (Session.Tool_claim.Id.equal (tool_claim_id base)
               (tool_claim_id same));
          let prepare =
            tool_claim ~stage:Tool.Stage.Prepare ~turn:(turn_id "turn-1") call
          in
          let run =
            tool_claim ~stage:Tool.Stage.Run ~turn:(turn_id "turn-1") call
          in
          is_false ~msg:"stage discriminates"
            (Session.Tool_claim.Id.equal (tool_claim_id prepare)
               (tool_claim_id run));
          let other_call =
            tool_claim ~turn:(turn_id "turn-1") (tool_call ~id:"call-2" ())
          in
          is_false ~msg:"call discriminates"
            (Session.Tool_claim.Id.equal (tool_claim_id base)
               (tool_claim_id other_call));
          let other_turn = tool_claim ~turn:(turn_id "turn-2") call in
          is_false ~msg:"turn discriminates"
            (Session.Tool_claim.Id.equal (tool_claim_id base)
               (tool_claim_id other_turn)));
      test "tool claims round-trip the complete source and canonical input"
        (fun () ->
          let source =
            tool_call ~id:"call-signed" ~name:"stager"
              ~input:(input_json "PROVIDER") ~signature:"continuity-token" ()
          in
          let started =
            tool_claim ~stage:Tool.Stage.Prepare ~input:(input_json "canonical")
              ~requests:[ request_for "canonical" ]
              ~turn:(turn_id "turn-1") source
          in
          let decoded =
            decode Session.Tool_claim.Started.jsont
              (encode Session.Tool_claim.Started.jsont started)
          in
          is_true ~msg:"claim round-trips"
            (Session.Tool_claim.Started.equal started decoded);
          let call = Session.Tool_claim.Started.call decoded in
          equal string ~msg:"call id" "call-signed" (Llm.Tool.Call.id call);
          equal string ~msg:"call name" "stager" (Llm.Tool.Call.name call);
          equal (option string) ~msg:"call signature" (Some "continuity-token")
            (Llm.Tool.Call.signature call);
          equal json_value ~msg:"original source input" (input_json "PROVIDER")
            (Llm.Tool.Call.input call);
          equal json_value ~msg:"canonical authorized input"
            (input_json "canonical")
            (Session.Tool_claim.Started.input decoded);
          assert_decode_error "old split call fields"
            Session.Tool_claim.Started.jsont
            (json_object
               [
                 ("turn", Json.string "turn-1");
                 ("stage", Json.string "prepare");
                 ("call_id", Json.string "call-signed");
                 ("name", Json.string "stager");
                 ("input", input_json "canonical");
                 ("requests", json_array []);
               ]));
      test "decision ids keep prepare- and run-stage decisions distinct"
        (fun () ->
          let call = tool_call ~id:"call-staged" ~name:"stager" () in
          let acc = access "session.review" in
          let prepare =
            permission_decision ~stage:Tool.Stage.Prepare
              ~turn:(turn_id "turn-1") ~call acc
          in
          let prepare' =
            permission_decision ~stage:Tool.Stage.Prepare
              ~turn:(turn_id "turn-1") ~call acc
          in
          let run =
            permission_decision ~stage:Tool.Stage.Run ~turn:(turn_id "turn-1")
              ~call acc
          in
          is_true ~msg:"same inputs derive the same id"
            (Session.Decision.Id.equal
               (Session.Decision.Requested.id prepare)
               (Session.Decision.Requested.id prepare'));
          is_false ~msg:"stage discriminates"
            (Session.Decision.Id.equal
               (Session.Decision.Requested.id prepare)
               (Session.Decision.Requested.id run)));
      test "decision requests round-trip the exact blocked call" (fun () ->
          let call =
            tool_call ~id:"call-signed" ~name:"read_file"
              ~input:(input_json "provider-shape")
              ~signature:"continuity-token" ()
          in
          let requested =
            permission_decision ~turn:(turn_id "turn-1") ~call
              (access "session.review")
          in
          let decoded =
            decode Session.Decision.Requested.jsont
              (encode Session.Decision.Requested.jsont requested)
          in
          is_true ~msg:"request round-trips"
            (Session.Decision.Requested.equal requested decoded);
          is_true ~msg:"exact call round-trips"
            (Llm.Tool.Call.equal call (Session.Decision.Requested.call decoded));
          assert_decode_error "old split decision-call fields"
            Session.Decision.Requested.jsont
            (json_object
               [
                 ("turn", Json.string "turn-1");
                 ("call_id", Json.string "call-signed");
                 ("name", Json.string "read_file");
                 ("stage", Json.string "direct");
                 ( "request",
                   encode Session.Decision.Request.jsont
                     (Session.Decision.Request.Permission
                        (review (access "session.review"))) );
               ]));
      test "permission answers round-trip guidance, absent and present"
        (fun () ->
          let roundtrip answer =
            decode Session.Decision.Answer.jsont
              (encode Session.Decision.Answer.jsont answer)
          in
          let bare =
            Session.Decision.Answer.Permission { answer = deny; message = None }
          in
          let guided =
            Session.Decision.Answer.Permission
              { answer = deny; message = Some "run the tests first" }
          in
          is_true ~msg:"a bare deny round-trips"
            (Session.Decision.Answer.equal bare (roundtrip bare));
          is_true ~msg:"a guided deny round-trips its message"
            (Session.Decision.Answer.equal guided (roundtrip guided));
          is_false ~msg:"guidance distinguishes two otherwise-equal answers"
            (Session.Decision.Answer.equal bare guided);
          (* An old document records no [message] member; it decodes to a bare
             deny, byte-identical to the pre-feature answer. *)
          let legacy =
            decode Session.Decision.Answer.jsont
              (json_object
                 [
                   ("type", Json.string "permission");
                   ( "answer",
                     encode Permission.Answer.jsont Permission.Answer.deny );
                 ])
          in
          is_true ~msg:"a message-less permission answer decodes to a bare deny"
            (Session.Decision.Answer.equal bare legacy));
      test "delegation ids derive from source turn and call" (fun () ->
          let make source_call =
            Session.Delegation.make ~child:(session_id "child-1")
              ~source_turn:(turn_id "turn-1") ~source_call
              ~task:[ Llm.Content.text "Go." ]
              ()
          in
          is_true ~msg:"same inputs derive the same id"
            (Session.Delegation.Id.equal
               (Session.Delegation.id (make "call-1"))
               (Session.Delegation.id (make "call-1")));
          is_false ~msg:"source call discriminates"
            (Session.Delegation.Id.equal
               (Session.Delegation.id (make "call-1"))
               (Session.Delegation.id (make "call-2"))));
      test "settlements reference their opener's derived id" (fun () ->
          let c = claim (turn_id "turn-1") in
          let settled =
            Session.Provider_request.Settled.ambiguous ~id:(claim_id c)
          in
          is_true ~msg:"provider settlement id is the opener id"
            (Session.Provider_request.Id.equal (claim_id c)
               (Session.Provider_request.Settled.id settled));
          let call = tool_call () in
          let tc = tool_claim ~turn:(turn_id "turn-1") call in
          let ts =
            Session.Tool_claim.Settled.returned ~id:(tool_claim_id tc)
              (completed "done")
          in
          is_true ~msg:"tool settlement id is the opener id"
            (Session.Tool_claim.Id.equal (tool_claim_id tc)
               (Session.Tool_claim.Settled.id ts)));
      test "id modules reject the empty string" (fun () ->
          expect_invalid_arg "turn id" (fun () -> Session.Turn.Id.of_string "");
          expect_invalid_arg "session id" (fun () -> Session.Id.of_string "");
          expect_invalid_arg "queue id" (fun () ->
              Session.Queue.Id.of_string "");
          expect_invalid_arg "task id" (fun () -> Session.Task.Id.of_string "");
          expect_invalid_arg "decision id" (fun () ->
              Session.Decision.Id.of_string "");
          expect_invalid_arg "tool claim id" (fun () ->
              Session.Tool_claim.Id.of_string "");
          expect_invalid_arg "provider claim id" (fun () ->
              Session.Provider_request.Id.of_string "");
          expect_invalid_arg "delegation id" (fun () ->
              Session.Delegation.Id.of_string "");
          assert_decode_error "turn id decode" Session.Turn.Id.jsont
            (Json.string ""));
      prop "claim id derivation is deterministic over its inputs"
        (Gen.triple ident_gen ident_gen ident_gen) (fun (turn, call_id, seed) ->
          let t = turn_id turn in
          let a = claim ~seed t and b = claim ~seed t in
          is_true ~msg:"provider ids agree"
            (Session.Provider_request.Id.equal (claim_id a) (claim_id b));
          let call = tool_call ~id:call_id () in
          let ca = tool_claim ~turn:t call and cb = tool_claim ~turn:t call in
          is_true ~msg:"tool ids agree"
            (Session.Tool_claim.Id.equal (tool_claim_id ca) (tool_claim_id cb)));
    ]

(* Contract. *)

let contract_group =
  group "contract"
    [
      test "accessors reflect construction and options default" (fun () ->
          let declarations = [ declaration "read_file" ] in
          let contract = make_contract ~declarations () in
          (match Session.Contract.mode contract with
          | Session.Contract.Mode.Build -> ()
          | Session.Contract.Mode.Plan | Session.Contract.Mode.Review ->
              fail "expected Build mode");
          is_true ~msg:"model is frozen"
            (Llm.Model.equal model (Session.Contract.model contract));
          is_true ~msg:"declarations are the exact snapshot"
            (List.equal Llm.Tool.equal declarations
               (Session.Contract.declarations contract));
          equal (option int) ~msg:"options default" None
            (Llm.Request.Options.max_output_tokens
               (Session.Contract.options contract));
          is_true ~msg:"policy is frozen"
            (Permission.Policy.equal Permission.Policy.default
               (Session.Contract.policy contract));
          is_true ~msg:"review behaviour is frozen"
            (Permission.Review_behavior.equal Permission.Review_behavior.Enforce
               (Session.Contract.review contract));
          is_true ~msg:"sandbox identity is frozen"
            (Sandbox.Identity.equal sandbox_identity
               (Session.Contract.sandbox contract)));
      test "equality distinguishes every leg" (fun () ->
          let base = make_contract () in
          equal contract_value ~msg:"reflexive" base (make_contract ());
          let different =
            [
              ("mode", make_contract ~mode:Session.Contract.Mode.Plan ());
              ("model", make_contract ~model:other_model ());
              ( "options",
                make_contract
                  ~options:(Llm.Request.Options.make ~max_output_tokens:1024 ())
                  () );
              ( "declarations",
                make_contract ~declarations:[ declaration "read_file" ] () );
              ( "output_tool",
                make_contract ~output_tool:structured_output_tool () );
              ( "policy",
                make_contract
                  ~policy:
                    (Permission.Policy.make [ Permission.Policy.Rule.deny_all ])
                  () );
              ( "review",
                make_contract ~review:Permission.Review_behavior.Bypass () );
              ("sandbox", make_contract ~sandbox:external_identity ());
            ]
          in
          List.iter
            (fun (leg, contract) ->
              is_false
                ~msg:(leg ^ " participates in equality")
                (Session.Contract.equal base contract))
            different);
      test "jsont round-trips composing the sandbox identity codec" (fun () ->
          let contract =
            make_contract ~mode:Session.Contract.Mode.Review
              ~declarations:[ declaration "read_file"; declaration "probe" ]
              ~output_tool:structured_output_tool
              ~policy:
                (Permission.Policy.make
                   [ Permission.Policy.Rule.review Permission.Policy.Match.any ])
              ~review:Permission.Review_behavior.Bypass
              ~sandbox:external_identity ()
          in
          let decoded =
            decode Session.Contract.jsont
              (encode Session.Contract.jsont contract)
          in
          equal contract_value ~msg:"decoded contract equals constructed one"
            contract decoded;
          is_true ~msg:"the sealed output tool survives the round-trip"
            (match Session.Contract.output_tool decoded with
            | Some tool -> Llm.Tool.equal structured_output_tool tool
            | None -> false);
          is_true ~msg:"identity digest survives the round-trip"
            (Sandbox.Identity.equal external_identity
               (Session.Contract.sandbox decoded)));
      test "jsont omits an absent output tool, decoding it back to None"
        (fun () ->
          let decoded =
            decode Session.Contract.jsont
              (encode Session.Contract.jsont (make_contract ()))
          in
          is_true ~msg:"no output tool round-trips as None"
            (Option.is_none (Session.Contract.output_tool decoded)));
      test "jsont rejects unknown members and unknown mode tags" (fun () ->
          let json = encode Session.Contract.jsont (make_contract ()) in
          assert_decode_error "unknown member" Session.Contract.jsont
            (add_member "extra" (Json.string "x") json);
          assert_decode_error "unknown mode tag" Session.Contract.jsont
            (set_member "mode" (Json.string "yolo") json));
    ]

(* Turn vocabulary. *)

let turn_group =
  group "turn vocabulary"
    [
      test "input constructors validate non-empty content" (fun () ->
          expect_invalid_arg "empty user content" (fun () ->
              Session.Turn.Input.user []);
          expect_invalid_arg "empty user text" (fun () ->
              Session.Turn.Input.user_text "");
          equal (option string) ~msg:"text projection joins text blocks"
            (Some "one two")
            (Session.Turn.Input.text
               (Session.Turn.Input.user
                  [ Llm.Content.text "one"; Llm.Content.text "two" ]));
          equal (option string) ~msg:"continue carries no text" None
            (Session.Turn.Input.text Session.Turn.Input.continue);
          let approval =
            approval ~title:"Typed turn" ~context:`Fresh
              ~feedback:"Keep the feedback." "1. Implement"
          in
          let input = Session.Turn.Input.plan_build approval in
          let text = Option.get (Session.Turn.Input.text input) in
          is_true ~msg:"plan-build text carries the title"
            (String.includes ~affix:"Typed turn" text);
          is_true ~msg:"plan-build text carries the exact body"
            (String.includes ~affix:"1. Implement" text);
          is_true ~msg:"plan-build text carries optional feedback"
            (String.includes ~affix:"Keep the feedback." text);
          is_true ~msg:"plan-build input round-trips through its owner codec"
            (Session.Turn.Input.equal input
               (decode Session.Turn.Input.jsont
                  (encode Session.Turn.Input.jsont input))));
      test "outcome constructors validate their prose" (fun () ->
          expect_invalid_arg "empty interrupt reason" (fun () ->
              Session.Turn.Outcome.interrupted ~reason:"" ~cancelled:false ());
          expect_invalid_arg "empty failure message" (fun () ->
              Session.Turn.Outcome.failed ~message:"");
          is_true ~msg:"reasonless interrupt is allowed"
            (Session.Turn.Outcome.equal
               (Session.Turn.Outcome.interrupted ~cancelled:true ())
               (Session.Turn.Outcome.interrupted ~cancelled:true ())));
      test "turn construction requires a positive step limit" (fun () ->
          expect_invalid_arg "zero max steps" (fun () -> turn ~max_steps:0 ());
          expect_invalid_arg "negative max steps" (fun () ->
              turn ~max_steps:(-3) ()));
      test "origin jsont round-trips every arm and rejects unknown tags"
        (fun () ->
          List.iter
            (fun origin ->
              let decoded =
                decode Session.Turn.Origin.jsont
                  (encode Session.Turn.Origin.jsont origin)
              in
              is_true ~msg:"origin round-trips"
                (Session.Turn.Origin.equal origin decoded))
            [
              Session.Turn.Origin.User;
              Session.Turn.Origin.Queued (queue_id "q-1");
              Session.Turn.Origin.Triggered
                {
                  charter = "nightly-review";
                  digest = "0f9a4c1d2e3b4a5f";
                  key = "delivery-42";
                };
              Session.Turn.Origin.Plan_build;
              Session.Turn.Origin.Compaction;
              Session.Turn.Origin.Step_limit_wind_down;
            ];
          assert_decode_error "unknown origin" Session.Turn.Origin.jsont
            (json_object [ ("type", Json.string "cron") ]);
          assert_decode_error "queued origin without entry"
            Session.Turn.Origin.jsont
            (json_object [ ("type", Json.string "queued") ]);
          assert_decode_error "triggered origin missing a member"
            Session.Turn.Origin.jsont
            (json_object
               [
                 ("type", Json.string "triggered");
                 ("charter", Json.string "nightly-review");
                 ("digest", Json.string "0f9a4c1d2e3b4a5f");
               ]);
          assert_decode_error "triggered origin with an empty member"
            Session.Turn.Origin.jsont
            (json_object
               [
                 ("type", Json.string "triggered");
                 ("charter", Json.string "");
                 ("digest", Json.string "0f9a4c1d2e3b4a5f");
                 ("key", Json.string "delivery-42");
               ]);
          assert_decode_error "triggered origin with an unknown member"
            Session.Turn.Origin.jsont
            (json_object
               [
                 ("type", Json.string "triggered");
                 ("charter", Json.string "nightly-review");
                 ("digest", Json.string "0f9a4c1d2e3b4a5f");
                 ("key", Json.string "delivery-42");
                 ("actor", Json.string "host");
               ]));
      test "turn jsont round-trips and rejects unknown members" (fun () ->
          let t =
            turn ~id:"turn-json"
              ~origin:(Session.Turn.Origin.Queued (queue_id "q-9"))
              ~max_steps:7
              ~contract:
                (make_contract ~declarations:[ declaration "read_file" ] ())
              ()
          in
          let json = encode Session.Turn.jsont t in
          equal turn_value ~msg:"turn round-trips" t
            (decode Session.Turn.jsont json);
          assert_decode_error "unknown member" Session.Turn.jsont
            (add_member "cursor" (Json.int 3) json));
    ]

(* Event codecs. *)

let extra_codec_events () =
  let t = turn () in
  let t_id = Session.Turn.id t in
  let c = claim t_id in
  let call = tool_call () in
  let tc = tool_claim ~turn:t_id call in
  let q = question ~choices:[ "yes"; "no" ] "Proceed?" in
  let d_question =
    Session.Decision.Requested.make ~turn:t_id ~call ~stage:Tool.Stage.Direct
      (Session.Decision.Request.Question q)
  in
  let d_plan =
    Session.Decision.Requested.make ~turn:t_id ~call ~stage:Tool.Stage.Direct
      (Session.Decision.Request.Plan (plan ~title:"Plan" "1. Do it"))
  in
  [
    Event.turn_finished ~turn:t_id Session.Turn.Outcome.step_limit;
    Event.turn_finished ~turn:t_id
      (Session.Turn.Outcome.failed ~message:"provider refused");
    Event.message_appended (Llm.Message.user_text "Hello.");
    Event.message_appended (Llm.Message.system "Be terse.");
    Event.provider_settled
      (Session.Provider_request.Settled.ambiguous ~id:(claim_id c));
    Event.provider_settled
      (Session.Provider_request.Settled.failed ~id:(claim_id c)
         (provider_failure ~kind:Llm.Error.Quota "quota exceeded"));
    Event.tool_settled
      (Session.Tool_claim.Settled.ambiguous ~id:(tool_claim_id tc));
    Event.decision_requested d_question;
    Event.decision_requested d_plan;
    Event.decision_resolved
      (resolve_ok ~msg:"question answer" d_question ~call
         ~by:Session.Principal.local_user
         (Session.Decision.Answer.Question (Session.Question.Answer.choice 1)));
    Event.decision_resolved
      (resolve_ok ~msg:"plan answer" d_plan ~call
         ~by:Session.Principal.local_user
         (Session.Decision.Answer.Plan
            (Session.Plan.Answer.approve ~body:(plan "1. Do it") ~context:`Fresh
               ~feedback:"ship it" ())));
    Event.queue_updated
      (Session.Queue.Update.replaced [ queue_entry ~id:"q-a" "one" ]);
    Event.queue_updated Session.Queue.Update.cleared;
    Event.delegation_recorded
      (Session.Delegation.make ~child:(session_id "child-2") ~source_turn:t_id
         ~source_call:"call-9"
         ~task:[ Llm.Content.text "Read." ]
         ());
    Event.workspace_notice
      (Session.Notice.make ~source:"dune"
         ~severity:Session.Notice.Severity.Error
         ~title:"Build failing (2 diagnostics)"
         ~body:"lib/a.ml:1:1-1:5: Error: Unbound value foo" ());
    Event.undo_updated
      (Session.Undo.Update.armed ~anchor:t_id ~revert:"revert-1" ());
    Event.undo_updated (Session.Undo.Update.armed ~anchor:t_id ());
    Event.undo_updated Session.Undo.Update.released;
  ]

let event_codec_group =
  group "event codecs"
    [
      test "every event arm round-trips through jsont" (fun () ->
          let events = (journal ()).events @ extra_codec_events () in
          List.iter
            (fun event ->
              equal event_value ~msg:"event round-trips" event
                (decode Event.jsont (encode Event.jsont event)))
            events);
      prop "generated algebraic events round-trip through jsont"
        (Gen.with_pp (Testable.pp event_value) event_gen)
        (fun event ->
          equal event_value ~msg:"round-trip" event
            (decode Event.jsont (encode Event.jsont event)));
      test "unknown event tags fail loudly, including old wire shapes"
        (fun () ->
          assert_decode_error "unknown tag" Event.jsont
            (json_object [ ("type", Json.string "telemetry") ]);
          (* The previous generation's vocabulary must not decode silently. *)
          List.iter
            (fun tag ->
              assert_decode_error ("old wire shape " ^ tag) Event.jsont
                (json_object [ ("type", Json.string tag) ]))
            [
              "response_appended";
              "assistant_interrupted";
              "permission_requested";
              "permission_resolved";
              "tool_claim_started";
              "tool_claim_finished";
              "goal_updated";
            ];
          (* A goal-bearing journal fails even with its full old payload. *)
          assert_decode_error "old goal_updated wire shape with payload"
            Event.jsont
            (json_object
               [
                 ("type", Json.string "goal_updated");
                 ( "update",
                   json_object
                     [
                       ("type", Json.string "declare");
                       ("id", Json.string "goal-1");
                       ("objective", Json.string "Ship it");
                     ] );
               ]);
          (* The retired goal-continuation origin is a decode error too. *)
          assert_decode_error "retired goal_continuation origin"
            Session.Turn.Origin.jsont
            (json_object [ ("type", Json.string "goal_continuation") ]));
      test "unknown members are decode errors, never skips" (fun () ->
          let json =
            encode Event.jsont
              (Event.queue_updated Session.Queue.Update.cleared)
          in
          assert_decode_error "unknown member" Event.jsont
            (add_member "at" (Json.int 17) json));
      test "cross-arm members are decode errors" (fun () ->
          let ambiguous =
            Event.provider_settled
              (Session.Provider_request.Settled.ambiguous
                 ~id:(claim_id (claim (turn_id "turn-1"))))
          in
          let json = encode Event.jsont ambiguous in
          let settlement = get_member "settlement" json in
          let tampered =
            set_member "settlement"
              (add_member "text" (Json.string "sneaky") settlement)
              json
          in
          assert_decode_error "ambiguous settlement with interrupted member"
            Event.jsont tampered);
      test "decoding runs the constructors' local checks" (fun () ->
          assert_decode_error "assistant message append" Event.jsont
            (json_object
               [
                 ("type", Json.string "message_appended");
                 ( "message",
                   encode Llm.Message.jsont (Llm.Message.assistant_text "hi") );
               ]);
          assert_decode_error "empty interrupt reason" Event.jsont
            (json_object
               [
                 ("type", Json.string "interrupt_requested");
                 ("turn", Json.string "turn-1");
                 ("reason", Json.string "");
               ]);
          assert_decode_error "empty turn id" Event.jsont
            (json_object
               [
                 ("type", Json.string "interrupt_requested");
                 ("turn", Json.string "");
               ]));
    ]

(* Replay: turns. *)

(* A state mid-turn: the opening response left [calls] pending, no suspension
   is open, and the turn is still active. *)
let mid_turn ?(id = "turn-1") calls =
  let t = turn ~id () in
  let c = claim ~seed:(id ^ "-open") (Session.Turn.id t) in
  let events =
    [
      Event.turn_started t;
      Event.provider_requested c;
      settle_responded c (assistant_calls calls);
    ]
  in
  (t, events)

let expect_step_error ~msg expected base event =
  expect_apply_error ~msg expected event (state base)

let expect_transcript_error ~msg = function
  | Ok _ -> failf "%s: expected a transcript error" msg
  | Error (State.Error.Transcript _) -> ()
  | Error error ->
      failf "%s: unexpected state error: %a" msg State.Error.pp error

let turn_replay_group =
  group "replay: turns"
    [
      test "a turn starts, responds, and finishes" (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c;
                respond ~usage:(usage ~input:5 ~output:2) c "Done.";
                finish t;
              ]
          in
          equal (option turn_id_value) ~msg:"no active turn" None
            (State.active_turn_id st);
          equal (list turn_value) ~msg:"turn order" [ t ] (State.turns st);
          equal (option outcome_value) ~msg:"outcome"
            (Some Session.Turn.Outcome.completed)
            (State.turn_outcome (Session.Turn.id t) st);
          equal int ~msg:"transcript has user and assistant" 2
            (List.length (messages_of (State.full_transcript st)));
          equal (option int) ~msg:"response count" (Some 1)
            (State.turn_response_count (Session.Turn.id t) st);
          equal (option string) ~msg:"turn final text" (Some "Done.")
            (State.turn_final_text (Session.Turn.id t) st);
          equal (option string) ~msg:"session final text" (Some "Done.")
            (State.final_text st);
          is_true ~msg:"latest model is the turn's"
            (Option.equal Llm.Model.equal (Some model) (State.latest_model st)));
      test "turn ids are unique across the session" (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          let base =
            [
              Event.turn_started t;
              Event.provider_requested c;
              respond c "Done.";
              finish t;
            ]
          in
          expect_step_error ~msg:"duplicate turn id"
            (State.Error.Turn (State.Error.Turn.Duplicate (turn_id "turn-1")))
            base
            (Event.turn_started (turn ())));
      test "at most one turn is active" (fun () ->
          expect_step_error ~msg:"second active turn"
            (State.Error.Turn (State.Error.Turn.Active (turn_id "turn-1")))
            [ Event.turn_started (turn ()) ]
            (Event.turn_started (turn ~id:"turn-2" ())));
      test "a terminal outcome names the active turn" (fun () ->
          expect_apply_error ~msg:"finish with no active turn"
            (State.Error.Turn State.Error.Turn.No_active)
            (finish (turn ()))
            State.empty;
          expect_step_error ~msg:"finish naming another turn"
            (State.Error.Turn (State.Error.Turn.Active (turn_id "turn-1")))
            [ Event.turn_started (turn ()) ]
            (finish (turn ~id:"turn-2" ())));
      test "a terminal outcome requires no open suspension" (fun () ->
          let t = turn () in
          expect_step_error ~msg:"finish with open provider claim"
            (State.Error.Turn
               (State.Error.Turn.Open_suspension (Session.Turn.id t)))
            [
              Event.turn_started t;
              Event.provider_requested (claim (Session.Turn.id t));
            ]
            (finish t));
      test "a terminal outcome requires a request-ready transcript" (fun () ->
          let t, base = mid_turn [ tool_call () ] in
          expect_transcript_error ~msg:"finish with a pending call"
            (State.apply (finish t) (state base)));
      test "a continue input appends nothing" (fun () ->
          let t =
            turn ~id:"turn-continue" ~input:Session.Turn.Input.continue ()
          in
          let st =
            state
              [
                Event.message_appended (Llm.Message.user_text "Earlier.");
                Event.turn_started t;
              ]
          in
          equal int ~msg:"only the earlier message" 1
            (List.length (messages_of (State.full_transcript st))));
      test "queued admission consumes exactly the named entry" (fun () ->
          let base =
            [
              Event.queue_updated
                (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "one"));
              Event.queue_updated
                (Session.Queue.Update.enqueued (queue_entry ~id:"q-2" "two"));
            ]
          in
          let admitted =
            turn ~id:"turn-q"
              ~origin:(Session.Turn.Origin.Queued (queue_id "q-1"))
              ()
          in
          let st = state (base @ [ Event.turn_started admitted ]) in
          equal (list queue_entry_value) ~msg:"named entry removed"
            [ queue_entry ~id:"q-2" "two" ]
            (State.pending_queue st);
          expect_step_error ~msg:"unknown entry"
            (State.Error.Turn
               (State.Error.Turn.Unknown_queue_entry (queue_id "q-9")))
            base
            (Event.turn_started
               (turn ~id:"turn-q2"
                  ~origin:(Session.Turn.Origin.Queued (queue_id "q-9"))
                  ())));
      test "a triggered turn pairs with prompt input like a user turn"
        (fun () ->
          let origin =
            Session.Turn.Origin.Triggered
              {
                charter = "nightly-review";
                digest = "0f9a4c1d2e3b4a5f";
                key = "delivery-42";
              }
          in
          let admitted = turn ~id:"turn-trig" ~origin () in
          let st = state [ Event.turn_started admitted; finish admitted ] in
          is_true ~msg:"the triggered turn is recorded with its provenance"
            (match State.turn (Session.Turn.id admitted) st with
            | Some recorded -> Session.Turn.equal admitted recorded
            | None -> false);
          expect_apply_error
            ~msg:"plan-build input cannot ride a triggered origin"
            (State.Error.Turn
               (State.Error.Turn.Unexpected_plan_build_input
                  (turn_id "turn-trig2")))
            (Event.turn_started
               (turn ~id:"turn-trig2" ~origin
                  ~input:
                    (Session.Turn.Input.plan_build
                       (approval ~context:`Current "1. Do the thing"))
                  ()))
            State.empty);
      test "enqueue_recorded is a durable receipt, not queue membership"
        (fun () ->
          let consumed =
            state
              [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "one"));
                Event.turn_started
                  (turn ~id:"turn-q"
                     ~origin:(Session.Turn.Origin.Queued (queue_id "q-1"))
                     ());
              ]
          in
          equal (list queue_entry_value) ~msg:"consumed leaves the queue empty"
            []
            (State.pending_queue consumed);
          is_true ~msg:"a consumed entry's Enqueued fact still proves delivery"
            (State.enqueue_recorded (queue_id "q-1") consumed);
          let replaced =
            state
              [
                Event.queue_updated
                  (Session.Queue.Update.replaced [ queue_entry ~id:"q-r" "r" ]);
              ]
          in
          is_false ~msg:"a Replaced-introduced id records no receipt"
            (State.enqueue_recorded (queue_id "q-r") replaced);
          let cleared =
            state
              [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry ~id:"q-2" "two"));
                Event.queue_updated Session.Queue.Update.cleared;
              ]
          in
          equal (list queue_entry_value) ~msg:"cleared empties the queue" []
            (State.pending_queue cleared);
          is_true ~msg:"the Enqueued receipt outlives a Cleared"
            (State.enqueue_recorded (queue_id "q-2") cleared);
          is_false ~msg:"an id never enqueued is not recorded"
            (State.enqueue_recorded (queue_id "q-never") cleared));
      test "user messages append only between turns" (fun () ->
          expect_step_error ~msg:"user message while a turn is active"
            (State.Error.Turn (State.Error.Turn.Active (turn_id "turn-1")))
            [ Event.turn_started (turn ()) ]
            (Event.message_appended (Llm.Message.user_text "Hi."));
          let st =
            state [ Event.message_appended (Llm.Message.user_text "Hi.") ]
          in
          equal int ~msg:"between turns it appends" 1
            (List.length (messages_of (State.full_transcript st))));
    ]

(* The plan lifecycle: propose -> approve (which canonically consumes the plan
   call) -> finish -> the next turn may consume that exact typed approval as a
   Plan_build input. *)
let approved_plan_prefix ?(context = `Current) ?title ?feedback
    ?(outcome = Session.Turn.Outcome.completed) ?(body = "1. Do the thing") () =
  let t =
    turn ~id:"turn-plan"
      ~contract:(make_contract ~mode:Session.Contract.Mode.Plan ())
      ~input:(Session.Turn.Input.user_text "Plan the work.")
      ()
  in
  let t_id = Session.Turn.id t in
  let call = tool_call ~id:"call-plan" ~name:"propose_plan" () in
  let c = claim t_id in
  let approval, answer = plan_approval ?title ?feedback ~context body in
  let proposal = Session.Plan.Approval.body approval in
  let d_plan =
    Session.Decision.Requested.make ~turn:t_id ~call ~stage:Tool.Stage.Direct
      (Session.Decision.Request.Plan proposal)
  in
  ( approval,
    [
      Event.turn_started t;
      Event.provider_requested c;
      settle_responded c (assistant_calls [ call ]);
      Event.decision_requested d_plan;
      resolved ~msg:"plan approve" d_plan ~call ~by:Session.Principal.local_user
        (Session.Decision.Answer.Plan answer);
      finish ~outcome t;
    ] )

let plan_build_group =
  group "replay: plan-build admission"
    [
      test "approve keeps its flat wire members while owning a typed value"
        (fun () ->
          let _approval, answer =
            plan_approval ~context:`Fresh ~feedback:"Ship it." "1. Go"
          in
          let json = encode Session.Plan.Answer.jsont answer in
          let members, _ = members_of json in
          let names = List.map (fun ((name, _), _) -> name) members in
          is_true ~msg:"approve body remains a direct member"
            (List.mem "body" names);
          is_true ~msg:"approve context remains a direct member"
            (List.mem "context" names);
          is_true ~msg:"approve feedback remains a direct member"
            (List.mem "feedback" names);
          is_false ~msg:"no redundant approval transport wrapper"
            (List.mem "approval" names));
      test "a plan approval admits the next turn as Plan_build" (fun () ->
          let approval, prefix = approved_plan_prefix () in
          let build =
            turn ~id:"turn-build" ~origin:Session.Turn.Origin.Plan_build
              ~input:(Session.Turn.Input.plan_build approval)
              ()
          in
          let st = state (prefix @ [ Event.turn_started build ]) in
          equal (option turn_id_value) ~msg:"build turn is active"
            (Some (turn_id "turn-build"))
            (State.active_turn_id st));
      test "plan-build admission without an approved plan is rejected"
        (fun () ->
          let input =
            Session.Turn.Input.plan_build
              (approval ~context:`Current "1. Unapproved")
          in
          expect_apply_error ~msg:"no approval at all"
            (State.Error.Turn
               (State.Error.Turn.Not_plan_build (turn_id "turn-build")))
            (Event.turn_started
               (turn ~id:"turn-build" ~origin:Session.Turn.Origin.Plan_build
                  ~input ()))
            State.empty);
      test "altered plan-build input is rejected before admission" (fun () ->
          let _approved, prefix = approved_plan_prefix () in
          let altered =
            Session.Turn.Input.plan_build
              (approval ~context:`Current "1. Do something else")
          in
          expect_step_error ~msg:"the exact approval is the admission authority"
            (State.Error.Turn
               (State.Error.Turn.Plan_build_mismatch (turn_id "turn-build")))
            prefix
            (Event.turn_started
               (turn ~id:"turn-build" ~origin:Session.Turn.Origin.Plan_build
                  ~input:altered ())));
      test "plan-build input under another origin is rejected" (fun () ->
          let input =
            Session.Turn.Input.plan_build
              (approval ~context:`Current "1. Do the thing")
          in
          expect_apply_error ~msg:"the input cannot forge its own admission"
            (State.Error.Turn
               (State.Error.Turn.Unexpected_plan_build_input
                  (turn_id "turn-user")))
            (Event.turn_started (turn ~id:"turn-user" ~input ()))
            State.empty);
      test "any other turn start clears the approved-plan mark" (fun () ->
          let approval, prefix = approved_plan_prefix () in
          let ordinary = turn ~id:"turn-user" () in
          let c = claim (Session.Turn.id ordinary) in
          let base =
            prefix
            @ [
                Event.turn_started ordinary;
                Event.provider_requested c;
                respond c "Ok.";
                finish ordinary;
              ]
          in
          expect_step_error ~msg:"mark was consumed by the ordinary turn"
            (State.Error.Turn
               (State.Error.Turn.Not_plan_build (turn_id "turn-build")))
            base
            (Event.turn_started
               (turn ~id:"turn-build" ~origin:Session.Turn.Origin.Plan_build
                  ~input:(Session.Turn.Input.plan_build approval)
                  ())));
      test "the plan-build turn itself does not renew the mark" (fun () ->
          let approval, prefix = approved_plan_prefix () in
          let build =
            turn ~id:"turn-build" ~origin:Session.Turn.Origin.Plan_build
              ~input:(Session.Turn.Input.plan_build approval)
              ()
          in
          let c = claim (Session.Turn.id build) in
          let base =
            prefix
            @ [
                Event.turn_started build;
                Event.provider_requested c;
                respond c "Built.";
                finish build;
              ]
          in
          expect_step_error ~msg:"a second plan-build needs a new approval"
            (State.Error.Turn
               (State.Error.Turn.Not_plan_build (turn_id "turn-build-2")))
            base
            (Event.turn_started
               (turn ~id:"turn-build-2" ~origin:Session.Turn.Origin.Plan_build
                  ~input:(Session.Turn.Input.plan_build approval)
                  ())));
      test "approved_plan retains the exact D8 value through its lifecycle"
        (fun () ->
          equal
            (option (Testable.of_equal Session.Plan.Approval.equal))
            ~msg:"no approval on the empty state" None
            (State.approved_plan State.empty);
          let approval, prefix =
            approved_plan_prefix ~feedback:"Keep the public API small." ()
          in
          let approved = state prefix in
          equal
            (option (Testable.of_equal Session.Plan.Approval.equal))
            ~msg:"settlement retains the exact approval" (Some approval)
            (State.approved_plan approved);
          let build =
            turn ~id:"turn-build" ~origin:Session.Turn.Origin.Plan_build
              ~input:(Session.Turn.Input.plan_build approval)
              ()
          in
          let consumed = state (prefix @ [ Event.turn_started build ]) in
          equal
            (option (Testable.of_equal Session.Plan.Approval.equal))
            ~msg:"the plan-build turn start consumes the approval" None
            (State.approved_plan consumed));
      test "approval settlement makes edited body and feedback model-visible"
        (fun () ->
          let approval, prefix =
            approved_plan_prefix ~title:"Smaller API"
              ~body:"1. Delete the wrapper\n2. Compose the leaf"
              ~feedback:"Keep the typed boundary." ()
          in
          let before_build = state prefix in
          let model_before = State.model_transcript before_build in
          let text = transcript_text model_before in
          is_true ~msg:"current context retains the planning prompt"
            (String.includes ~affix:"Plan the work." text);
          List.iter
            (fun expected ->
              is_true ~msg:("model sees " ^ expected)
                (String.includes ~affix:expected text))
            [
              "Smaller API";
              "1. Delete the wrapper";
              "2. Compose the leaf";
              "Keep the typed boundary.";
            ];
          let build =
            turn ~id:"turn-build" ~origin:Session.Turn.Origin.Plan_build
              ~input:(Session.Turn.Input.plan_build approval)
              ()
          in
          let after_build = state (prefix @ [ Event.turn_started build ]) in
          equal (list message_value)
            ~msg:"current-context Build preserves the exact planning transcript"
            (messages_of model_before)
            (messages_of (State.model_transcript after_build)));
      test "fresh approval starts a durable model context from the exact plan"
        (fun () ->
          let approval, prefix =
            approved_plan_prefix ~context:`Fresh ~title:"Fresh build"
              ~body:"1. Re-read the interface\n2. Implement"
              ~feedback:"Do not recover the old wrapper." ()
          in
          let build =
            turn ~id:"turn-fresh" ~origin:Session.Turn.Origin.Plan_build
              ~input:(Session.Turn.Input.plan_build approval)
              ()
          in
          let st = state (prefix @ [ Event.turn_started build ]) in
          let full = transcript_text (State.full_transcript st) in
          let model = transcript_text (State.model_transcript st) in
          is_true ~msg:"display history retains the planning transcript"
            (String.includes ~affix:"Plan the work." full);
          is_false ~msg:"fresh model context excludes the planning transcript"
            (String.includes ~affix:"Plan the work." model);
          List.iter
            (fun expected ->
              is_true
                ~msg:("fresh model sees " ^ expected)
                (String.includes ~affix:expected model))
            [
              "fresh model context";
              "Fresh build";
              "1. Re-read the interface";
              "2. Implement";
              "Do not recover the old wrapper.";
            ]);
      test "replay reconstructs the same exact plan-build input" (fun () ->
          let approval, prefix =
            approved_plan_prefix ~context:`Fresh ~feedback:"Use the edit." ()
          in
          let build =
            turn ~id:"turn-replayed" ~origin:Session.Turn.Origin.Plan_build
              ~input:(Session.Turn.Input.plan_build approval)
              ()
          in
          let events = prefix @ [ Event.turn_started build ] in
          let decoded =
            List.map
              (fun event -> decode Event.jsont (encode Event.jsont event))
              events
          in
          assert_states_equal ~msg:"plan-build replay" (state events)
            (state decoded));
      test "a non-completed approval turn is rejected" (fun () ->
          let outcome = Session.Turn.Outcome.failed ~message:"forged failure" in
          let _approval, events = approved_plan_prefix ~outcome () in
          expect_replay_error ~msg:"approval only settles Completed"
            ~index:(List.length events - 1)
            (State.Error.Turn
               (State.Error.Turn.Plan_approval_outcome
                  { turn = turn_id "turn-plan"; outcome }))
            events);
      test "fresh reset ignores older compactions and the newest later one wins"
        (fun () ->
          let planning =
            turn ~id:"turn-plan-compacted"
              ~contract:(make_contract ~mode:Session.Contract.Mode.Plan ())
              ~input:(Session.Turn.Input.user_text "OLD PLANNING PROMPT")
              ()
          in
          let planning_id = Session.Turn.id planning in
          let old_summary_claim = claim ~seed:"old-summary" planning_id in
          let old_summary_claim_2 = claim ~seed:"old-summary-2" planning_id in
          let plan_claim = claim ~seed:"plan-after-summary" planning_id in
          let call =
            tool_call ~id:"call-compacted-plan" ~name:"propose_plan" ()
          in
          let approval, answer =
            plan_approval ~context:`Fresh "1. Execute after reset"
          in
          let requested =
            Session.Decision.Requested.make ~turn:planning_id ~call
              ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Plan
                 (Session.Plan.Approval.body approval))
          in
          let old_compaction =
            Session.Compaction.make
              ~reason:Session.Compaction.Reason.Context_pressure
              ~provider_claim:(claim_id old_summary_claim)
              ~request_digest:(digest "old-summary-request")
              ~summary_messages:[ Llm.Message.user_text "OLD SUMMARY" ]
              ~summarized_upto:1 ()
          in
          let old_compaction_2 =
            Session.Compaction.make
              ~reason:Session.Compaction.Reason.User_requested
              ~provider_claim:(claim_id old_summary_claim_2)
              ~request_digest:(digest "old-summary-request-2")
              ~summary_messages:[ Llm.Message.user_text "NEWER OLD SUMMARY" ]
              ~summarized_upto:1 ()
          in
          let prefix =
            [
              Event.turn_started planning;
              Event.provider_requested old_summary_claim;
              Event.compaction_installed old_compaction;
              Event.provider_requested old_summary_claim_2;
              Event.compaction_installed old_compaction_2;
              Event.provider_requested plan_claim;
              settle_responded plan_claim (assistant_calls [ call ]);
              Event.decision_requested requested;
              resolved ~msg:"fresh compacted plan" requested ~call
                ~by:Session.Principal.local_user
                (Session.Decision.Answer.Plan answer);
              finish planning;
            ]
          in
          let build =
            turn ~id:"turn-after-old-summary"
              ~origin:Session.Turn.Origin.Plan_build
              ~input:(Session.Turn.Input.plan_build approval)
              ()
          in
          let pending_call = tool_call ~id:"pending-after-reset" () in
          let build_claim =
            claim ~seed:"build-response" (Session.Turn.id build)
          in
          let after_reset_events =
            prefix
            @ [
                Event.turn_started build;
                Event.provider_requested build_claim;
                settle_responded build_claim (assistant_calls [ pending_call ]);
              ]
          in
          let after_reset = state after_reset_events in
          let reset_model =
            transcript_text (State.model_transcript after_reset)
          in
          is_false ~msg:"pre-reset compaction summary is excluded"
            (String.includes ~affix:"OLD SUMMARY" reset_model);
          is_false ~msg:"newest pre-reset compaction summary is excluded"
            (String.includes ~affix:"NEWER OLD SUMMARY" reset_model);
          is_true ~msg:"fresh plan seeds the reset model view"
            (String.includes ~affix:"1. Execute after reset" reset_model);
          let post_claim =
            claim ~seed:"post-reset-summary" (Session.Turn.id build)
          in
          let upto =
            Llm.Transcript.length (State.full_transcript after_reset) - 1
          in
          let post_compaction =
            Session.Compaction.make
              ~reason:Session.Compaction.Reason.Context_pressure
              ~provider_claim:(claim_id post_claim)
              ~request_digest:(digest "post-reset-summary-request")
              ~summary_messages:[ Llm.Message.user_text "POST RESET SUMMARY" ]
              ~summarized_upto:upto ()
          in
          let post_claim_2 =
            claim ~seed:"post-reset-summary-2" (Session.Turn.id build)
          in
          let post_compaction_2 =
            Session.Compaction.make
              ~reason:Session.Compaction.Reason.User_requested
              ~provider_claim:(claim_id post_claim_2)
              ~request_digest:(digest "post-reset-summary-request-2")
              ~summary_messages:
                [ Llm.Message.user_text "NEWEST POST RESET SUMMARY" ]
              ~summarized_upto:upto ()
          in
          let after_compaction =
            state
              (after_reset_events
              @ [
                  Event.provider_requested post_claim;
                  Event.compaction_installed post_compaction;
                  Event.provider_requested post_claim_2;
                  Event.compaction_installed post_compaction_2;
                ])
          in
          equal (list message_value)
            ~msg:
              "the newest post-reset compaction retains the pending-call opener"
            [
              Llm.Message.user_text "NEWEST POST RESET SUMMARY";
              Llm.Message.assistant (assistant_calls [ pending_call ]);
            ]
            (messages_of (State.model_transcript after_compaction));
          equal (option compaction_value) ~msg:"only the newest cache is read"
            (Some post_compaction_2)
            (State.latest_compaction after_compaction));
    ]

(* Replay: the single suspension. *)

let suspension_group =
  group "replay: single suspension"
    [
      test "openers require an active turn" (fun () ->
          expect_apply_error ~msg:"provider opener"
            (State.Error.Turn State.Error.Turn.No_active)
            (Event.provider_requested (claim (turn_id "turn-1")))
            State.empty;
          expect_apply_error ~msg:"tool opener"
            (State.Error.Turn State.Error.Turn.No_active)
            (Event.tool_claimed
               (tool_claim ~turn:(turn_id "turn-1") (tool_call ())))
            State.empty;
          expect_apply_error ~msg:"decision opener"
            (State.Error.Turn State.Error.Turn.No_active)
            (Event.decision_requested
               (permission_decision ~turn:(turn_id "turn-1")
                  ~call:(tool_call ()) (access "session.review")))
            State.empty);
      test "a second opener while one is open is rejected" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let base =
            [ Event.turn_started t; Event.provider_requested (claim t_id) ]
          in
          let open_suspension =
            State.Error.Turn (State.Error.Turn.Open_suspension t_id)
          in
          expect_step_error ~msg:"provider then provider" open_suspension base
            (Event.provider_requested (claim ~seed:"req-2" t_id));
          expect_step_error ~msg:"provider then tool claim" open_suspension base
            (Event.tool_claimed (tool_claim ~turn:t_id (tool_call ())));
          expect_step_error ~msg:"provider then decision" open_suspension base
            (Event.decision_requested
               (permission_decision ~turn:t_id ~call:(tool_call ())
                  (access "session.review")));
          let t2, with_calls = mid_turn ~id:"turn-2" [ tool_call () ] in
          let t2_id = Session.Turn.id t2 in
          let claimed =
            with_calls
            @ [ Event.tool_claimed (tool_claim ~turn:t2_id (tool_call ())) ]
          in
          expect_step_error ~msg:"tool claim then provider"
            (State.Error.Turn (State.Error.Turn.Open_suspension t2_id)) claimed
            (Event.provider_requested (claim ~seed:"later" t2_id)));
      test "settling clears the suspension for the next opener" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c1 = claim ~seed:"one" t_id in
          let c2 = claim ~seed:"two" t_id in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c1;
                respond c1 "First.";
                Event.provider_requested c2;
              ]
          in
          equal (option suspension_value) ~msg:"second claim is the suspension"
            (Some (State.Provider c2)) (State.suspension st));
      test "the suspension read mirrors the open fact" (fun () ->
          let t, base = mid_turn [ tool_call () ] in
          let t_id = Session.Turn.id t in
          let claim_started = tool_claim ~turn:t_id (tool_call ()) in
          let st = state (base @ [ Event.tool_claimed claim_started ]) in
          equal (option suspension_value) ~msg:"tool suspension"
            (Some (State.Tool claim_started)) (State.suspension st);
          equal (option suspension_value) ~msg:"empty state has none" None
            (State.suspension State.empty));
    ]

(* Replay: provider claims. *)

let provider_group =
  group "replay: provider claims"
    [
      test "a responded settlement must match the contract model" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c = claim t_id in
          expect_step_error ~msg:"model drift is rejected"
            (State.Error.Turn
               (State.Error.Turn.Response_model_mismatch
                  { turn = t_id; expected = model; actual = other_model }))
            [ Event.turn_started t; Event.provider_requested c ]
            (respond ~model:other_model c "Wrong model."));
      test "an interrupted settlement retains the prose" (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c;
                settle_interrupted c "Partial thought.";
              ]
          in
          equal (option string) ~msg:"prose is model-visible"
            (Some "Partial thought.") (State.final_text st);
          equal int ~msg:"user plus retained assistant" 2
            (List.length (messages_of (State.full_transcript st))));
      test "an ambiguous settlement appends nothing" (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c;
                settle_ambiguous c;
              ]
          in
          equal int ~msg:"only the user message" 1
            (List.length (messages_of (State.full_transcript st)));
          equal (option suspension_value) ~msg:"claim settled" None
            (State.suspension st));
      test "an ambiguous settlement still admits an interrupted outcome"
        (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c;
                settle_ambiguous c;
                finish
                  ~outcome:
                    (Session.Turn.Outcome.interrupted ~cancelled:false ())
                  t;
              ]
          in
          equal (option outcome_value) ~msg:"interrupted outcome"
            (Some (Session.Turn.Outcome.interrupted ~cancelled:false ()))
            (State.turn_outcome (Session.Turn.id t) st));
      test "an ambiguous settlement forces an interrupted turn" (fun () ->
          (* After a provider claim settles Ambiguous the
             turn may only settle Interrupted — a crash never replays as a
             clean completion, and no new work opens. *)
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c = claim t_id in
          let base =
            [
              Event.turn_started t;
              Event.provider_requested c;
              settle_ambiguous c;
            ]
          in
          expect_step_error ~msg:"completed after ambiguous"
            (State.Error.Turn (State.Error.Turn.Interrupted t_id)) base
            (finish t);
          expect_step_error ~msg:"no new provider claim after ambiguous"
            (State.Error.Turn (State.Error.Turn.Interrupted t_id)) base
            (Event.provider_requested (claim ~seed:"retry" t_id)));
      test "a failed settlement closes the claim and fails the turn" (fun () ->
          (* A known provider failure appends nothing and,
             unlike Ambiguous, forces no interrupt — the outcome is proven, so
             the turn settles Failed in the same suffix, never Interrupted. *)
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c = claim t_id in
          let base =
            [
              Event.turn_started t; Event.provider_requested c; settle_failed c;
            ]
          in
          let st = state base in
          equal int ~msg:"nothing appended, only the user message" 1
            (List.length (messages_of (State.full_transcript st)));
          equal (option suspension_value) ~msg:"claim closed" None
            (State.suspension st);
          (* The proven failure admits a Failed terminal with no interrupt
             forcing — the [settle_failed; Turn_finished Failed] suffix replays. *)
          let failed =
            Session.Turn.Outcome.failed ~message:"provider refused"
          in
          let st = state (base @ [ finish ~outcome:failed t ]) in
          equal (option outcome_value) ~msg:"turn settles Failed" (Some failed)
            (State.turn_outcome t_id st);
          (* The settlement round-trips, carrying its structured diagnostic. *)
          let settled =
            Session.Provider_request.Settled.failed ~id:(claim_id c)
              (provider_failure "authentication rejected")
          in
          is_true ~msg:"failed settlement round-trips"
            (Session.Provider_request.Settled.equal settled
               (decode Session.Provider_request.Settled.jsont
                  (encode Session.Provider_request.Settled.jsont settled))));
      test "exactly one settlement is admitted per claim" (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          let base =
            [
              Event.turn_started t;
              Event.provider_requested c;
              respond c "Done.";
            ]
          in
          expect_step_error ~msg:"second settlement is not pending"
            (State.Error.Provider
               (State.Error.Provider.Not_pending (claim_id c)))
            base (settle_ambiguous c);
          let unknown = claim ~seed:"never-opened" (Session.Turn.id t) in
          expect_step_error ~msg:"settlement for an unopened claim"
            (State.Error.Provider
               (State.Error.Provider.Unknown (claim_id unknown)))
            base (settle_ambiguous unknown));
      test "a re-driven provider claim is detected structurally" (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          expect_step_error ~msg:"duplicate claim id"
            (State.Error.Provider (State.Error.Provider.Duplicate (claim_id c)))
            [
              Event.turn_started t; Event.provider_requested c; respond c "Hi.";
            ]
            (Event.provider_requested c));
      test "interrupted settlements require visible prose" (fun () ->
          expect_invalid_arg "whitespace-only prose" (fun () ->
              Session.Provider_request.Settled.interrupted
                ~id:(claim_id (claim (turn_id "turn-1")))
                ~text:"  \n " ()));
      test "an interrupted settlement retains provider usage" (fun () ->
          let id = claim_id (claim (turn_id "turn-1")) in
          let with_usage =
            Session.Provider_request.Settled.interrupted ~id
              ~usage:(usage ~input:120 ~output:8) ~text:"partial" ()
          in
          is_true ~msg:"usage round-trips"
            (Session.Provider_request.Settled.equal with_usage
               (decode Session.Provider_request.Settled.jsont
                  (encode Session.Provider_request.Settled.jsont with_usage)));
          let bare =
            Session.Provider_request.Settled.interrupted ~id ~text:"partial" ()
          in
          is_false ~msg:"usage distinguishes two otherwise-equal settlements"
            (Session.Provider_request.Settled.equal with_usage bare);
          (* An old document records no [usage] member; it decodes to a
             usage-less settlement, byte-identical to the pre-field shape. *)
          let legacy =
            decode Session.Provider_request.Settled.jsont
              (json_object
                 [
                   ("type", Json.string "interrupted");
                   ("id", encode Session.Provider_request.Id.jsont id);
                   ("text", Json.string "partial");
                 ])
          in
          is_true ~msg:"a usage-less document decodes to a usage-less settlement"
            (Session.Provider_request.Settled.equal bare legacy));
    ]

(* Replay: tool claims. *)

let tool_claim_group =
  group "replay: tool claims"
    [
      test
        "a direct claim settles with the result lowered from the stored value"
        (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let started = tool_claim ~turn:(Session.Turn.id t) call in
          let result = completed "contents" in
          let st =
            state
              (base
              @ [ Event.tool_claimed started; settled_returned started result ]
              )
          in
          (match tool_result_for "call-1" st with
          | None -> fail "expected a lowered tool result"
          | Some lowered ->
              is_true ~msg:"lowering matches Result.to_model"
                (Llm.Tool.Result.equal
                   (Tool.Result.to_model ~call result)
                   lowered);
              is_false ~msg:"completed lowers to a non-error"
                (Llm.Tool.Result.is_error lowered));
          (match State.tool_claims st with
          | [ (recorded, Some settled) ] ->
              is_true ~msg:"history keeps the opener"
                (Session.Tool_claim.Started.equal started recorded);
              is_true ~msg:"history keeps the settlement"
                (Session.Tool_claim.Id.equal (tool_claim_id started)
                   (Session.Tool_claim.Settled.id settled))
          | _ -> fail "expected one settled claim");
          is_true ~msg:"transcript is request-ready again"
            (Llm.Transcript.is_ready (State.model_transcript st)));
      test "failure kinds survive replay verbatim" (fun () ->
          let call = tool_call ~name:"probe" () in
          let t, base = mid_turn [ call ] in
          let started = tool_claim ~turn:(Session.Turn.id t) call in
          let st =
            state
              (base
              @ [
                  Event.tool_claimed started;
                  settled_returned started
                    (Tool.Result.failed `Not_found "missing file");
                ])
          in
          (match State.tool_claims st with
          | [ (_, Some settled) ] -> (
              match Session.Tool_claim.Settled.outcome settled with
              | Session.Tool_claim.Settled.Returned result -> (
                  match Tool.Result.status result with
                  | Tool.Result.Failed { kind = `Not_found; message; _ } ->
                      equal string ~msg:"message survives" "missing file"
                        message
                  | _ -> fail "expected the Not_found failure kind")
              | _ -> fail "expected a returned settlement")
          | _ -> fail "expected one settled claim");
          match tool_result_for "call-1" st with
          | Some lowered ->
              is_true ~msg:"failures lower to error results"
                (Llm.Tool.Result.is_error lowered)
          | None -> fail "expected a lowered tool result");
      test "an ambiguous settlement appends the pinned synthetic result"
        (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let started = tool_claim ~turn:(Session.Turn.id t) call in
          let st =
            state
              (base @ [ Event.tool_claimed started; settled_ambiguous started ])
          in
          (match tool_result_for "call-1" st with
          | Some lowered ->
              is_true ~msg:"synthetic result is an error"
                (Llm.Tool.Result.is_error lowered);
              (* Version-pinned spelling: replay feeds this to the model. *)
              equal string ~msg:"pinned ambiguous spelling"
                "tool result ambiguous after crash recovery"
                (result_text lowered)
          | None -> fail "expected the synthetic result");
          is_true ~msg:"transcript stays request-ready"
            (Llm.Transcript.is_ready (State.model_transcript st)));
      test "a claim requires its call to be pending" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let t_id = Session.Turn.id t in
          let ghost_call = tool_call ~id:"call-ghost" () in
          let ghost = tool_claim ~turn:t_id ghost_call in
          expect_step_error ~msg:"unknown call id"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Call_not_pending
                  { claim = tool_claim_id ghost; call_id = "call-ghost" }))
            base (Event.tool_claimed ghost);
          let started = tool_claim ~turn:t_id call in
          let consumed =
            base
            @ [
                Event.tool_claimed started;
                settled_returned started (completed "done");
              ]
          in
          (* Re-claiming the answered call now trips the structural duplicate
             guard: the same (turn, call, stage) derives the same id. *)
          expect_step_error ~msg:"claim after the call was answered"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Duplicate (tool_claim_id started)))
            consumed
            (Event.tool_claimed started));
      test "exactly one settlement is admitted per claim" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let started = tool_claim ~turn:(Session.Turn.id t) call in
          let settledbase =
            base
            @ [
                Event.tool_claimed started;
                settled_returned started (completed "done");
              ]
          in
          expect_step_error ~msg:"second settlement is not pending"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Not_pending (tool_claim_id started)))
            settledbase
            (settled_ambiguous started);
          let unknown =
            tool_claim ~turn:(Session.Turn.id t) (tool_call ~id:"call-x" ())
          in
          expect_step_error ~msg:"settlement for an unopened claim"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Unknown (tool_claim_id unknown)))
            settledbase
            (settled_ambiguous unknown));
      test "stage and outcome must be compatible" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let started = tool_claim ~turn:(Session.Turn.id t) call in
          expect_step_error ~msg:"a direct claim never settles prepared"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Stage_mismatch (tool_claim_id started)))
            (base @ [ Event.tool_claimed started ])
            (settled_prepared started (prepared_payload "alpha")));
      test "a run claim requires its prepared sibling" (fun () ->
          let call = tool_call ~id:"call-staged" ~name:"stager" () in
          let t, base = mid_turn [ call ] in
          let run =
            tool_claim ~stage:Tool.Stage.Run ~turn:(Session.Turn.id t) call
          in
          expect_step_error ~msg:"run without prepare"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Missing_prepare (tool_claim_id run)))
            base (Event.tool_claimed run));
      test "claims and decisions must retain the exact pending call" (fun () ->
          (* The claim stores the complete source call; a different name is a
             different source even when its call id is reused. *)
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let t_id = Session.Turn.id t in
          let imposter =
            Session.Tool_claim.Started.make ~turn:t_id ~stage:Tool.Stage.Direct
              ~call:(tool_call ~id:"call-1" ~name:"imposter" ())
              ~input:(Json.object' []) ~requests:[]
          in
          expect_step_error ~msg:"tool claim name mismatch"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Call_not_pending
                  {
                    claim = Session.Tool_claim.Started.id imposter;
                    call_id = "call-1";
                  }))
            base
            (Event.tool_claimed imposter);
          let imposter_decision =
            Session.Decision.Requested.make ~turn:t_id
              ~call:(tool_call ~id:"call-1" ~name:"imposter" ())
              ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Permission
                 (review (access "session.review")))
          in
          expect_step_error ~msg:"decision request name mismatch"
            (State.Error.Decision
               (State.Error.Decision.Call_not_pending
                  {
                    decision = Session.Decision.Requested.id imposter_decision;
                    call_id = "call-1";
                  }))
            base
            (Event.decision_requested imposter_decision);
          let changed_input_decision =
            Session.Decision.Requested.make ~turn:t_id
              ~call:(tool_call ~input:(input_json "changed") ())
              ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Permission
                 (review (access "session.review")))
          in
          expect_step_error ~msg:"decision request input mismatch"
            (State.Error.Decision
               (State.Error.Decision.Call_not_pending
                  {
                    decision =
                      Session.Decision.Requested.id changed_input_decision;
                    call_id = "call-1";
                  }))
            base
            (Event.decision_requested changed_input_decision);
          let changed_signature_decision =
            Session.Decision.Requested.make ~turn:t_id
              ~call:(tool_call ~signature:"continuity-token" ())
              ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Permission
                 (review (access "session.review")))
          in
          expect_step_error ~msg:"decision request signature mismatch"
            (State.Error.Decision
               (State.Error.Decision.Call_not_pending
                  {
                    decision =
                      Session.Decision.Requested.id changed_signature_decision;
                    call_id = "call-1";
                  }))
            base
            (Event.decision_requested changed_signature_decision));
      test "replay rejects a changed provider signature on the claimed call"
        (fun () ->
          let pending = tool_call ~signature:"signature-a" () in
          let t, base = mid_turn [ pending ] in
          let changed = tool_call ~signature:"signature-b" () in
          let started = tool_claim ~turn:(Session.Turn.id t) changed in
          expect_step_error ~msg:"signature mismatch"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Call_not_pending
                  {
                    claim = Session.Tool_claim.Started.id started;
                    call_id = "call-1";
                  }))
            base
            (Event.tool_claimed started));
    ]

(* Replay: the staged lifecycle. *)

let staged_group =
  group "replay: staged lifecycle"
    [
      test "the staged pair replays across the process boundary" (fun () ->
          let call =
            tool_call ~id:"call-staged" ~name:"stager"
              ~input:(input_json "alpha") ()
          in
          let t, base = mid_turn [ call ] in
          let t_id = Session.Turn.id t in
          let boundary = prepare_call "alpha" in
          let prepared = prepared_payload "alpha" in
          let prepare_claim =
            tool_claim ~stage:Tool.Stage.Prepare
              ~input:(Tool.Call.input boundary)
              ~requests:(Tool.Call.permissions boundary)
              ~turn:t_id call
          in
          let after_prepare =
            state
              (base
              @ [
                  Event.tool_claimed prepare_claim;
                  settled_prepared prepare_claim prepared;
                ])
          in
          equal (option suspension_value)
            ~msg:"prepared is terminal for its claim" None
            (State.suspension after_prepare);
          (* The settlement is a bare Prepared.t: reconstruction equality via
             the tool library is the resume contract. *)
          let reloaded =
            decode Tool.Prepared.jsont (encode Tool.Prepared.jsont prepared)
          in
          equal prepared_value ~msg:"prepared round-trips durably" prepared
            reloaded;
          (match Tool.Call.resume (prepare_call "alpha") reloaded with
          | Ok resumed ->
              is_true ~msg:"resume yields the run stage"
                (Tool.Stage.equal Tool.Stage.Run (Tool.Call.stage resumed))
          | Error error ->
              failf "resume failed: %s" (Tool.Call.Resume_error.message error));
          let run_claim =
            tool_claim ~stage:Tool.Stage.Run ~input:(Tool.Call.input boundary)
              ~requests:(Tool.Prepared.requests prepared)
              ~turn:t_id call
          in
          let finished =
            state
              (base
              @ [
                  Event.tool_claimed prepare_claim;
                  settled_prepared prepare_claim prepared;
                  Event.tool_claimed run_claim;
                  settled_returned run_claim (completed "write alpha 5 times");
                  finish t;
                ])
          in
          equal (option outcome_value) ~msg:"turn completes"
            (Some Session.Turn.Outcome.completed)
            (State.turn_outcome t_id finished);
          equal int ~msg:"two claims over one model call" 2
            (List.length (State.tool_claims finished)));
      test "a prepared settlement leaves the model call pending" (fun () ->
          let call =
            tool_call ~id:"call-staged" ~name:"stager"
              ~input:(input_json "alpha") ()
          in
          let t, base = mid_turn [ call ] in
          let prepare_claim =
            tool_claim ~stage:Tool.Stage.Prepare ~turn:(Session.Turn.id t) call
          in
          let st =
            state
              (base
              @ [
                  Event.tool_claimed prepare_claim;
                  settled_prepared prepare_claim (prepared_payload "alpha");
                ])
          in
          is_false ~msg:"the call still awaits its result"
            (Llm.Transcript.is_ready (State.full_transcript st));
          expect_transcript_error ~msg:"the turn cannot finish yet"
            (State.apply (finish t) st));
      test "a prepare claim may settle returned when the tool finishes early"
        (fun () ->
          let call =
            tool_call ~id:"call-staged" ~name:"stager"
              ~input:(input_json "alpha") ()
          in
          let t, base = mid_turn [ call ] in
          let prepare_claim =
            tool_claim ~stage:Tool.Stage.Prepare ~turn:(Session.Turn.id t) call
          in
          let st =
            state
              (base
              @ [
                  Event.tool_claimed prepare_claim;
                  settled_returned prepare_claim (completed "nothing to stage");
                  finish t;
                ])
          in
          equal (option outcome_value) ~msg:"turn completes"
            (Some Session.Turn.Outcome.completed)
            (State.turn_outcome (Session.Turn.id t) st));
      test "run-stage requests derive from the prepared payload" (fun () ->
          let prepared = prepared_payload "alpha" in
          equal
            (list
               (Testable.make ~pp:Permission.Request.pp
                  ~equal:Permission.Request.equal))
            ~msg:"final requests come from the plan"
            [ request_for "alpha" ]
            (Tool.Prepared.requests prepared));
      test "pending-fix F8: a direct claim after a prepare claim is rejected"
        (fun () ->
          (* One call follows one lifecycle: once staged, the only admissible
             follow-up claim is the run claim. Target semantics: a Direct claim
             on the staged call is rejected. *)
          let call =
            tool_call ~id:"call-staged" ~name:"stager"
              ~input:(input_json "alpha") ()
          in
          let t, base = mid_turn [ call ] in
          let t_id = Session.Turn.id t in
          let prepare_claim =
            tool_claim ~stage:Tool.Stage.Prepare ~turn:t_id call
          in
          let direct = tool_claim ~turn:t_id call in
          expect_step_error ~msg:"direct claim on a staged call"
            (State.Error.Tool_claim
               (State.Error.Tool_claim.Illegal_sequence (tool_claim_id direct)))
            (base
            @ [
                Event.tool_claimed prepare_claim;
                settled_prepared prepare_claim (prepared_payload "alpha");
              ])
            (Event.tool_claimed direct));
    ]

(* Decisions. *)

let expect_resolve_error ~msg expected requested ~call ~by answer =
  match Session.Decision.resolve requested ~call ~by answer with
  | Ok _ -> failf "%s: expected a resolve error" msg
  | Error error -> equal resolve_error_value ~msg expected error

let question_decision ?choices ~turn ~call prompt =
  Session.Decision.Requested.make ~turn ~call ~stage:Tool.Stage.Direct
    (Session.Decision.Request.Question (question ?choices prompt))

let decision_group =
  group "decisions"
    [
      test "resolve checks the answer tag against the pending request"
        (fun () ->
          let call = tool_call () in
          let requested =
            question_decision ~turn:(turn_id "turn-1") ~call "Proceed?"
          in
          expect_resolve_error ~msg:"plan answer to a question"
            (Session.Decision.Resolve_error.Tag_mismatch
               { expected = "question"; got = "plan" })
            requested ~call ~by:Session.Principal.local_user
            (Session.Decision.Answer.Plan Session.Plan.Answer.keep_planning));
      test "resolve checks the blocked call" (fun () ->
          let call = tool_call () in
          let requested =
            question_decision ~turn:(turn_id "turn-1") ~call "Proceed?"
          in
          expect_resolve_error ~msg:"another call cannot answer"
            (Session.Decision.Resolve_error.Call_mismatch
               {
                 expected = "call-1";
                 got = "call-2";
                 expected_name = "read_file";
                 got_name = "read_file";
               })
            requested
            ~call:(tool_call ~id:"call-2" ())
            ~by:Session.Principal.local_user
            (Session.Decision.Answer.Question
               (Session.Question.Answer.free "yes"));
          (* F7: a same-id name drift stays legible through the name fields. *)
          expect_resolve_error ~msg:"a same-id name mismatch names both tools"
            (Session.Decision.Resolve_error.Call_mismatch
               {
                 expected = "call-1";
                 got = "call-1";
                 expected_name = "read_file";
                 got_name = "imposter";
               })
            requested
            ~call:(tool_call ~id:"call-1" ~name:"imposter" ())
            ~by:Session.Principal.local_user
            (Session.Decision.Answer.Question
               (Session.Question.Answer.free "yes"));
          expect_resolve_error ~msg:"same-id and name input drift is rejected"
            (Session.Decision.Resolve_error.Call_mismatch
               {
                 expected = "call-1";
                 got = "call-1";
                 expected_name = "read_file";
                 got_name = "read_file";
               })
            requested
            ~call:(tool_call ~input:(input_json "changed") ())
            ~by:Session.Principal.local_user
            (Session.Decision.Answer.Question
               (Session.Question.Answer.free "yes"));
          let signed = tool_call ~signature:"signature-a" () in
          let signed_request =
            question_decision ~turn:(turn_id "turn-1") ~call:signed "Proceed?"
          in
          expect_resolve_error
            ~msg:"same-id and name signature drift is rejected"
            (Session.Decision.Resolve_error.Call_mismatch
               {
                 expected = "call-1";
                 got = "call-1";
                 expected_name = "read_file";
                 got_name = "read_file";
               })
            signed_request
            ~call:(tool_call ~signature:"signature-b" ())
            ~by:Session.Principal.local_user
            (Session.Decision.Answer.Question
               (Session.Question.Answer.free "yes")));
      test "resolve checks a choice answer's index" (fun () ->
          let call = tool_call () in
          let with_choices =
            question_decision ~choices:[ "red"; "blue" ]
              ~turn:(turn_id "turn-1") ~call "Which?"
          in
          expect_resolve_error ~msg:"out of range"
            (Session.Decision.Resolve_error.Invalid_choice
               { index = 5; count = 2 })
            with_choices ~call ~by:Session.Principal.local_user
            (Session.Decision.Answer.Question (Session.Question.Answer.choice 5));
          let free_question =
            question_decision ~turn:(turn_id "turn-1") ~call "Say more?"
          in
          expect_resolve_error ~msg:"choice on a free question"
            (Session.Decision.Resolve_error.Invalid_choice
               { index = 0; count = 0 })
            free_question ~call ~by:Session.Principal.local_user
            (Session.Decision.Answer.Question (Session.Question.Answer.choice 0));
          ignore
            (require_ok ~msg:"a valid choice resolves"
               (Session.Decision.resolve with_choices ~call
                  ~by:Session.Principal.local_user
                  (Session.Decision.Answer.Question
                     (Session.Question.Answer.choice 1)))));
      test "an unattended policy principal may only deny a permission"
        (fun () ->
          let call = tool_call () in
          let permission =
            permission_decision ~turn:(turn_id "turn-1") ~call
              (access "session.review")
          in
          expect_resolve_error ~msg:"unattended allow"
            Session.Decision.Resolve_error.Unattended_not_permitted permission
            ~call ~by:Session.Principal.unattended_policy
            (Session.Decision.Answer.Permission
               { answer = allow_once; message = None });
          let q = question_decision ~turn:(turn_id "turn-1") ~call "Ok?" in
          expect_resolve_error ~msg:"unattended question answer"
            Session.Decision.Resolve_error.Unattended_not_permitted q ~call
            ~by:Session.Principal.unattended_policy
            (Session.Decision.Answer.Question
               (Session.Question.Answer.free "yes"));
          match
            Session.Decision.resolve permission ~call
              ~by:Session.Principal.unattended_policy
              (Session.Decision.Answer.Permission
                 { answer = deny; message = None })
          with
          | Ok (resolved, Session.Decision.Consume _) ->
              is_true ~msg:"the denial is attributed to the policy"
                (Session.Principal.equal Session.Principal.unattended_policy
                   (Session.Decision.Resolved.answered_by resolved))
          | Ok (_, _) -> fail "unattended denial must consume the call"
          | Error error ->
              failf "unattended deny refused: %a"
                Session.Decision.Resolve_error.pp error);
      test "resolve returns the justified proceeding handling" (fun () ->
          let call = tool_call () in
          let permission =
            permission_decision ~turn:(turn_id "turn-1") ~call
              (access "session.review")
          in
          (match
             Session.Decision.resolve permission ~call
               ~by:Session.Principal.local_user
               (Session.Decision.Answer.Permission
                  { answer = allow_once; message = None })
           with
          | Ok (_, Session.Decision.Proceed_permission) -> ()
          | Ok (_, _) -> fail "permission allow returned the wrong handling"
          | Error error ->
              failf "permission allow failed: %a"
                Session.Decision.Resolve_error.pp error);
          let plan_decision =
            Session.Decision.Requested.make ~turn:(turn_id "turn-1") ~call
              ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Plan (plan "1. Go"))
          in
          let expected = approval ~context:`Current "1. Go" in
          match
            Session.Decision.resolve plan_decision ~call
              ~by:Session.Principal.local_user
              (Session.Decision.Answer.Plan
                 (Session.Plan.Answer.approve ~body:(plan "1. Go")
                    ~context:`Current ()))
          with
          | Ok (_, Session.Decision.Proceed_plan actual) ->
              is_true ~msg:"plan handling carries the exact approval"
                (Session.Plan.Approval.equal expected actual)
          | Ok (_, _) -> fail "plan approval returned the wrong handling"
          | Error error ->
              failf "plan approval failed: %a" Session.Decision.Resolve_error.pp
                error);
      test "consuming handling pins the canonical results" (fun () ->
          let call = tool_call () in
          let permission =
            permission_decision ~turn:(turn_id "turn-1") ~call
              (access "session.review")
          in
          let handling answer requested =
            match
              Session.Decision.resolve requested ~call
                ~by:Session.Principal.local_user answer
            with
            | Ok (_, handling) -> handling
            | Error error ->
                failf "resolve failed: %a" Session.Decision.Resolve_error.pp
                  error
          in
          (match
             handling
               (Session.Decision.Answer.Permission
                  { answer = deny; message = None })
               permission
           with
          | Session.Decision.Consume lowered ->
              is_true ~msg:"deny is an error result"
                (Llm.Tool.Result.is_error lowered);
              equal string ~msg:"pinned deny spelling"
                "The user denied permission to run this command."
                (result_text lowered)
          | _ -> fail "deny must consume");
          (match
             handling
               (Session.Decision.Answer.Permission
                  { answer = deny; message = Some "run the tests first" })
               permission
           with
          | Session.Decision.Consume lowered ->
              is_true ~msg:"guided deny is an error result"
                (Llm.Tool.Result.is_error lowered);
              equal string ~msg:"pinned guided-deny spelling appends the reason"
                "The user denied permission to run this command. They said: \
                 run the tests first"
                (result_text lowered)
          | _ -> fail "guided deny must consume");
          let plan_decision =
            Session.Decision.Requested.make ~turn:(turn_id "turn-1") ~call
              ~stage:Tool.Stage.Direct
              (Session.Decision.Request.Plan (plan "1. Go"))
          in
          (match
             handling
               (Session.Decision.Answer.Plan Session.Plan.Answer.keep_planning)
               plan_decision
           with
          | Session.Decision.Consume lowered ->
              is_false ~msg:"keep-planning is not an error"
                (Llm.Tool.Result.is_error lowered);
              equal string ~msg:"pinned keep-planning spelling"
                "The plan was not approved; continue planning."
                (result_text lowered)
          | _ -> fail "keep-planning must consume");
          (match
             handling
               (Session.Decision.Answer.Plan
                  (Session.Plan.Answer.revise "Split the second step."))
               plan_decision
           with
          | Session.Decision.Consume lowered ->
              equal string ~msg:"revise feedback verbatim"
                "Split the second step." (result_text lowered)
          | _ -> fail "revise must consume");
          let free = question_decision ~turn:(turn_id "turn-1") ~call "Say?" in
          (match
             handling
               (Session.Decision.Answer.Question
                  (Session.Question.Answer.free "Use the second option."))
               free
           with
          | Session.Decision.Consume lowered ->
              equal string ~msg:"free text verbatim" "Use the second option."
                (result_text lowered)
          | _ -> fail "question must consume");
          let choices =
            question_decision ~choices:[ "red"; "blue" ]
              ~turn:(turn_id "turn-1") ~call "Which?"
          in
          match
            handling
              (Session.Decision.Answer.Question
                 (Session.Question.Answer.choice 1))
              choices
          with
          | Session.Decision.Consume lowered ->
              equal string ~msg:"selected option text verbatim" "blue"
                (result_text lowered)
          | _ -> fail "choice must consume");
      test "a decision requires its blocked call to be pending" (fun () ->
          let _, base = mid_turn [ tool_call () ] in
          let ghost = tool_call ~id:"call-ghost" () in
          let requested =
            permission_decision ~turn:(turn_id "turn-1") ~call:ghost
              (access "session.review")
          in
          expect_step_error ~msg:"ghost call"
            (State.Error.Decision
               (State.Error.Decision.Call_not_pending
                  {
                    decision = Session.Decision.Requested.id requested;
                    call_id = "call-ghost";
                  }))
            base
            (Event.decision_requested requested));
      test "first valid resolution wins; a second is not pending" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let requested =
            permission_decision ~turn:(Session.Turn.id t) ~call
              (access "session.review")
          in
          let first =
            resolve_ok ~msg:"deny" requested ~call
              ~by:Session.Principal.local_user
              (Session.Decision.Answer.Permission
                 { answer = deny; message = None })
          in
          let resolved_base =
            base
            @ [
                Event.decision_requested requested;
                Event.decision_resolved first;
              ]
          in
          expect_step_error ~msg:"second resolution"
            (State.Error.Decision
               (State.Error.Decision.Not_pending
                  (Session.Decision.Requested.id requested)))
            resolved_base
            (Event.decision_resolved
               (forged_resolution
                  (Session.Decision.Requested.id requested)
                  ~by:Session.Principal.local_user
                  (Session.Decision.Answer.Permission
                     { answer = allow_once; message = None })));
          (match
             State.decision
               (Session.Decision.Requested.id requested)
               (state resolved_base)
           with
          | Some (_, Some recorded) ->
              is_true ~msg:"the first answer is retained"
                (Session.Decision.Answer.equal
                   (Session.Decision.Answer.Permission
                      { answer = deny; message = None })
                   (Session.Decision.Resolved.answer recorded))
          | Some (_, None) | None -> fail "expected the resolved decision");
          expect_step_error ~msg:"resolution for an unknown decision"
            (State.Error.Decision
               (State.Error.Decision.Unknown
                  (Session.Decision.Id.of_string "d-ghost")))
            resolved_base
            (Event.decision_resolved
               (forged_resolution
                  (Session.Decision.Id.of_string "d-ghost")
                  ~by:Session.Principal.local_user
                  (Session.Decision.Answer.Permission
                     { answer = deny; message = None }))));
      test "State.decision reads a single decision by id" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let requested =
            permission_decision ~turn:(Session.Turn.id t) ~call
              (access "session.review")
          in
          let id = Session.Decision.Requested.id requested in
          let pending = state (base @ [ Event.decision_requested requested ]) in
          (match State.decision id pending with
          | Some (r, None) ->
              is_true ~msg:"the pending decision is returned"
                (Session.Decision.Id.equal id (Session.Decision.Requested.id r))
          | Some (_, Some _) -> fail "the decision is not yet resolved"
          | None -> fail "expected the pending decision");
          let first =
            resolve_ok ~msg:"deny" requested ~call
              ~by:Session.Principal.local_user
              (Session.Decision.Answer.Permission
                 { answer = deny; message = None })
          in
          let resolved =
            state
              (base
              @ [
                  Event.decision_requested requested;
                  Event.decision_resolved first;
                ])
          in
          (match State.decision id resolved with
          | Some (_, Some recorded) ->
              is_true ~msg:"the resolution is returned"
                (Session.Decision.Resolved.equal first recorded)
          | _ -> fail "expected the resolved decision");
          match
            State.decision (Session.Decision.Id.of_string "d-absent") resolved
          with
          | None -> ()
          | Some _ -> fail "an absent id is None");
      test "replay re-runs the resolve checks on forged resolutions" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let requested =
            question_decision ~choices:[ "red"; "blue" ]
              ~turn:(Session.Turn.id t) ~call "Which?"
          in
          let pending = base @ [ Event.decision_requested requested ] in
          let id = Session.Decision.Requested.id requested in
          expect_step_error ~msg:"forged out-of-range choice"
            (State.Error.Decision
               (State.Error.Decision.Resolve
                  (Session.Decision.Resolve_error.Invalid_choice
                     { index = 5; count = 2 })))
            pending
            (Event.decision_resolved
               (forged_resolution id ~by:Session.Principal.local_user
                  (Session.Decision.Answer.Question
                     (Session.Question.Answer.choice 5))));
          expect_step_error ~msg:"forged tag mismatch"
            (State.Error.Decision
               (State.Error.Decision.Resolve
                  (Session.Decision.Resolve_error.Tag_mismatch
                     { expected = "question"; got = "permission" })))
            pending
            (Event.decision_resolved
               (forged_resolution id ~by:Session.Principal.local_user
                  (Session.Decision.Answer.Permission
                     { answer = deny; message = None })));
          expect_step_error ~msg:"forged unattended non-deny"
            (State.Error.Decision
               (State.Error.Decision.Resolve
                  Session.Decision.Resolve_error.Unattended_not_permitted))
            pending
            (Event.decision_resolved
               (forged_resolution id ~by:Session.Principal.unattended_policy
                  (Session.Decision.Answer.Question
                     (Session.Question.Answer.choice 1)))));
      test "a consuming answer appends the derived result" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let requested =
            permission_decision ~turn:(Session.Turn.id t) ~call
              (access "session.review")
          in
          let st =
            state
              (base
              @ [
                  Event.decision_requested requested;
                  resolved ~msg:"deny" requested ~call
                    ~by:Session.Principal.unattended_policy
                    (Session.Decision.Answer.Permission
                       { answer = deny; message = None });
                ])
          in
          (match tool_result_for "call-1" st with
          | Some lowered ->
              is_true ~msg:"denial reaches the transcript as an error"
                (Llm.Tool.Result.is_error lowered);
              equal string ~msg:"replayed pinned spelling"
                "The user denied permission to run this command."
                (result_text lowered)
          | None -> fail "expected the consuming result");
          is_true ~msg:"the call is consumed"
            (Llm.Transcript.is_ready (State.full_transcript st)));
      test "a proceeding answer leaves the call for its claim" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let requested =
            permission_decision ~turn:(Session.Turn.id t) ~call
              (access "session.review")
          in
          let st =
            state
              (base
              @ [
                  Event.decision_requested requested;
                  resolved ~msg:"allow" requested ~call
                    ~by:Session.Principal.local_user
                    (Session.Decision.Answer.Permission
                       { answer = allow_once; message = None });
                  Event.tool_claimed (tool_claim ~turn:(Session.Turn.id t) call);
                ])
          in
          match State.suspension st with
          | Some (State.Tool _) -> ()
          | _ -> fail "expected the claim to open on the released call");
      test "principal jsont accepts only the closed set" (fun () ->
          List.iter
            (fun principal ->
              is_true ~msg:"principal round-trips"
                (Session.Principal.equal principal
                   (decode Session.Principal.jsont
                      (encode Session.Principal.jsont principal))))
            [
              Session.Principal.local_user; Session.Principal.unattended_policy;
            ];
          assert_decode_error "unknown principal" Session.Principal.jsont
            (Json.string "user");
          assert_decode_error "free-string principal" Session.Principal.jsont
            (Json.string "remote_reviewer"));
      test "question and plan constructors validate their shapes" (fun () ->
          ignore
            (require_error ~msg:"empty prompt"
               (Session.Question.make ~prompt:"" ()));
          ignore
            (require_error ~msg:"empty choice list"
               (Session.Question.make ~prompt:"Pick" ~choices:[] ()));
          ignore
            (require_error ~msg:"empty choice"
               (Session.Question.make ~prompt:"Pick" ~choices:[ "a"; "" ] ()));
          expect_invalid_arg "negative choice index" (fun () ->
              Session.Question.Answer.choice (-1));
          expect_invalid_arg "empty free answer" (fun () ->
              Session.Question.Answer.free "");
          ignore
            (require_error ~msg:"empty plan body"
               (Session.Plan.make ~body:"" ()));
          ignore
            (require_error ~msg:"empty plan title"
               (Session.Plan.make ~title:"" ~body:"1. Go" ()));
          expect_invalid_arg "empty revise feedback" (fun () ->
              Session.Plan.Answer.revise ""));
    ]

(* Grants. *)

let resolved_permission ~msg ?reason ~by acc answer base t call =
  let requested =
    permission_decision ?reason ~turn:(Session.Turn.id t) ~call acc
  in
  state
    (base
    @ [
        Event.decision_requested requested;
        resolved ~msg requested ~call ~by
          (Session.Decision.Answer.Permission { answer; message = None });
      ])

let grants_group =
  group "grants"
    [
      test "exact-for-conversation adds the reviewed access as a grant"
        (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let acc = access ~subject:"grant" "session.review" in
          let st =
            resolved_permission ~msg:"allow exact"
              ~by:Session.Principal.local_user acc allow_exact base t call
          in
          is_true ~msg:"grant recorded"
            (Permission.Policy.Grants.allows (State.grants st) acc);
          is_false ~msg:"no unrelated grant"
            (Permission.Policy.Grants.allows (State.grants st)
               (access "session.other")));
      test "allow-once and deny record no grant" (fun () ->
          let call = tool_call () in
          let acc = access ~subject:"grant" "session.review" in
          let t, base = mid_turn [ call ] in
          let once =
            resolved_permission ~msg:"allow once"
              ~by:Session.Principal.local_user acc allow_once base t call
          in
          is_false ~msg:"once leaves no grant"
            (Permission.Policy.Grants.allows (State.grants once) acc);
          let t2, base2 = mid_turn ~id:"turn-deny" [ call ] in
          let denied =
            resolved_permission ~msg:"deny"
              ~by:Session.Principal.unattended_policy acc deny base2 t2 call
          in
          is_false ~msg:"deny is absolute: no grant"
            (Permission.Policy.Grants.allows (State.grants denied) acc);
          equal (list rule_value) ~msg:"deny installs no rule" []
            (State.permission_rules denied));
      test "a grant recorded through a review-rule prompt is retained"
        (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let acc = access ~subject:"reviewed" "session.review" in
          let rule =
            Permission.Policy.Rule.review Permission.Policy.Match.any
          in
          let st =
            resolved_permission ~msg:"allow exact through a review rule"
              ~reason:(Permission.Policy.Review.By_rule rule)
              ~by:Session.Principal.local_user acc allow_exact base t call
          in
          is_true ~msg:"the review-rule-matched grant is retained"
            (Permission.Policy.Grants.allows (State.grants st) acc));
      test "conversation-family answers append visible rules once" (fun () ->
          let call_a = tool_call ~id:"call-a" () in
          let call_b = tool_call ~id:"call-b" () in
          let t, base = mid_turn [ call_a; call_b ] in
          let acc = access ~subject:"family" "session.review" in
          let rule =
            Permission.Policy.Rule.allow (Permission.Policy.Match.kind `Custom)
          in
          let family =
            Permission.Answer.family ~lifetime:Permission.Answer.Conversation
              ~rules:[ rule ]
          in
          let d_a =
            permission_decision ~turn:(Session.Turn.id t) ~call:call_a acc
          in
          let d_b =
            permission_decision ~turn:(Session.Turn.id t) ~call:call_b acc
          in
          let st =
            state
              (base
              @ [
                  Event.decision_requested d_a;
                  resolved ~msg:"family a" d_a ~call:call_a
                    ~by:Session.Principal.local_user
                    (Session.Decision.Answer.Permission
                       { answer = family; message = None });
                  Event.decision_requested d_b;
                  resolved ~msg:"family b" d_b ~call:call_b
                    ~by:Session.Principal.local_user
                    (Session.Decision.Answer.Permission
                       { answer = family; message = None });
                ])
          in
          equal (list rule_value) ~msg:"rule installed once, in order" [ rule ]
            (State.permission_rules st));
      test "user-lifetime family rules are not conversation rules" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let acc = access ~subject:"family" "session.review" in
          let family =
            Permission.Answer.family ~lifetime:Permission.Answer.User
              ~rules:
                [
                  Permission.Policy.Rule.allow
                    (Permission.Policy.Match.kind `Custom);
                ]
          in
          let st =
            resolved_permission ~msg:"user family"
              ~by:Session.Principal.local_user acc family base t call
          in
          equal (list rule_value)
            ~msg:"user-lifetime persistence is config's, not the journal's" []
            (State.permission_rules st));
    ]

(* Interrupt and the bypass rule. *)

let interrupt_group =
  group "replay: interrupt"
    [
      test "an interrupt request names the active turn" (fun () ->
          expect_apply_error ~msg:"no active turn"
            (State.Error.Turn State.Error.Turn.No_active)
            (Event.interrupt_requested ~turn:(turn_id "turn-1") ())
            State.empty;
          expect_step_error ~msg:"another turn is active"
            (State.Error.Turn (State.Error.Turn.Active (turn_id "turn-1")))
            [ Event.turn_started (turn ()) ]
            (Event.interrupt_requested ~turn:(turn_id "turn-2") ()));
      test "a second interrupt request is idempotent" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let st =
            state
              [
                Event.turn_started t;
                Event.interrupt_requested ~turn:t_id ~reason:"stop" ();
                Event.interrupt_requested ~turn:t_id ();
              ]
          in
          is_true ~msg:"still interrupt-requested"
            (State.interrupt_requested st));
      test "after an interrupt only settlements and an interrupted end admit"
        (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c = claim t_id in
          let base =
            [
              Event.turn_started t;
              Event.provider_requested c;
              Event.interrupt_requested ~turn:t_id ~reason:"user stop" ();
            ]
          in
          let interrupted_error =
            State.Error.Turn (State.Error.Turn.Interrupted t_id)
          in
          expect_step_error ~msg:"no new provider claim" interrupted_error base
            (Event.provider_requested (claim ~seed:"late" t_id));
          expect_step_error ~msg:"no new queue fact" interrupted_error base
            (Event.queue_updated
               (Session.Queue.Update.enqueued (queue_entry "late")));
          expect_step_error ~msg:"no clean completion" interrupted_error base
            (finish t);
          let settled =
            base
            @ [
                settle_interrupted c "Stopping.";
                finish
                  ~outcome:
                    (Session.Turn.Outcome.interrupted ~reason:"user stop"
                       ~cancelled:true ())
                  t;
              ]
          in
          let st = state settled in
          equal (option outcome_value) ~msg:"interrupted end admitted"
            (Some
               (Session.Turn.Outcome.interrupted ~reason:"user stop"
                  ~cancelled:true ()))
            (State.turn_outcome t_id st));
      test "pending-fix F2: reconciliation results are admitted after interrupt"
        (fun () ->
          (* Target semantics: after Interrupt_requested, a non-bypassing tool
             result — the engine reconciling unclaimed sibling calls — is an
             ordinary append, so the interrupt -> settle -> reconcile ->
             Turn_finished(Interrupted) journey replays. *)
          let call_a = tool_call ~id:"call-a" () in
          let call_b = tool_call ~id:"call-b" () in
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c = claim t_id in
          let claim_a = tool_claim ~turn:t_id call_a in
          let prefix =
            [
              Event.turn_started t;
              Event.provider_requested c;
              settle_responded c (assistant_calls [ call_a; call_b ]);
              Event.tool_claimed claim_a;
              Event.interrupt_requested ~turn:t_id ~reason:"user stop" ();
            ]
          in
          (* The admission stays narrow: no new claim opens, and the open
             claim's own call cannot be answered by a bypassing append. *)
          expect_step_error ~msg:"no new tool claim after interrupt"
            (State.Error.Turn (State.Error.Turn.Interrupted t_id)) prefix
            (Event.tool_claimed (tool_claim ~turn:t_id call_b));
          expect_step_error ~msg:"the open claim's call is still guarded"
            (State.Error.Result_bypass "call-a") prefix
            (Event.message_appended
               (Llm.Message.tool_result
                  (Llm.Tool.Result.text ~error:true call_a "sneaky")));
          let events =
            prefix
            @ [
                settled_returned claim_a
                  (Tool.Result.interrupted ~reason:"stopped" ~cancelled:true ());
                Event.message_appended
                  (Llm.Message.tool_result
                     (Llm.Tool.Result.text ~error:true call_b
                        "interrupted before start"));
                finish
                  ~outcome:
                    (Session.Turn.Outcome.interrupted ~reason:"user stop"
                       ~cancelled:true ())
                  t;
              ]
          in
          match State.of_events events with
          | Ok st ->
              is_true ~msg:"transcript reconciled"
                (Llm.Transcript.is_ready (State.full_transcript st))
          | Error error ->
              failf "interrupt reconciliation journey rejected: %a"
                State.Replay_error.pp error);
      test
        "an interrupt reconciliation abandons a parked decision (F2/section \
         11.6)" (fun () ->
          (* Interrupted while parked on a decision, the engine's reconciliation
             answer for the parked call is admitted and clears the suspension —
             abandoning the ask with no Decision_resolved fact. Absent the
             interrupt the same result is still a bypass. *)
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let t_id = Session.Turn.id t in
          let requested =
            permission_decision ~turn:t_id ~call (access "session.review")
          in
          let parked = base @ [ Event.decision_requested requested ] in
          let reconcile =
            Event.message_appended
              (Llm.Message.tool_result
                 (Llm.Tool.Result.text ~error:true call
                    "abandoned: interrupted while awaiting a decision"))
          in
          (* Non-interrupt: a result answering the parked call is still a bypass;
             the proper closer would be Decision_resolved. *)
          expect_step_error ~msg:"a parked decision is not answered by a result"
            (State.Error.Result_bypass "call-1") parked reconcile;
          (* Interrupt-forced: the reconciliation is admitted and clears it. *)
          let interrupted =
            parked
            @ [ Event.interrupt_requested ~turn:t_id ~reason:"user stop" () ]
          in
          let abandoned = interrupted @ [ reconcile ] in
          let st = state abandoned in
          equal (option suspension_value) ~msg:"decision suspension cleared"
            None (State.suspension st);
          is_true ~msg:"the abandonment answer is appended"
            (Option.is_some (tool_result_for "call-1" st));
          (match
             State.decision (Session.Decision.Requested.id requested) st
           with
          | Some (_, resolved) ->
              is_true ~msg:"no Decision_resolved fact — abandoned, not answered"
                (Option.is_none resolved)
          | None -> fail "expected the abandoned decision on record");
          (* Terminal-by-interrupt: a later resolution finds the ask gone. *)
          expect_step_error ~msg:"a later resolution is not pending"
            (State.Error.Decision
               (State.Error.Decision.Not_pending
                  (Session.Decision.Requested.id requested)))
            abandoned
            (resolved ~msg:"late answer" requested ~call
               ~by:Session.Principal.local_user
               (Session.Decision.Answer.Permission
                  { answer = deny; message = None }));
          (* And the turn reaches its interrupted terminal without wedging. *)
          let interrupted_outcome =
            Session.Turn.Outcome.interrupted ~reason:"user stop" ~cancelled:true
              ()
          in
          let st =
            state (abandoned @ [ finish ~outcome:interrupted_outcome t ])
          in
          equal (option outcome_value) ~msg:"turn settles interrupted"
            (Some interrupted_outcome)
            (State.turn_outcome t_id st));
      test "the interrupt flag clears when the turn finishes" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let next = turn ~id:"turn-2" () in
          let c = claim (Session.Turn.id next) in
          let st =
            state
              [
                Event.turn_started t;
                Event.interrupt_requested ~turn:t_id ();
                finish
                  ~outcome:
                    (Session.Turn.Outcome.interrupted ~cancelled:false ())
                  t;
                Event.turn_started next;
                Event.provider_requested c;
                respond c "Fresh turn.";
              ]
          in
          is_false ~msg:"interrupt does not leak into the next turn"
            (State.interrupt_requested st));
      test "failure clears the queue while interrupt preserves correction"
        (fun () ->
          let run outcome =
            let t = turn () in
            let c = claim (Session.Turn.id t) in
            State.pending_queue
              (state
                 [
                   Event.turn_started t;
                   Event.queue_updated
                     (Session.Queue.Update.enqueued (queue_entry "queued"));
                   Event.provider_requested c;
                   respond c "Done.";
                   finish ~outcome t;
                 ])
          in
          equal (list queue_entry_value) ~msg:"failed empties the queue" []
            (run (Session.Turn.Outcome.failed ~message:"boom"));
          equal (list queue_entry_value)
            ~msg:"interrupted preserves the queued correction"
            [ queue_entry "queued" ]
            (run (Session.Turn.Outcome.interrupted ~cancelled:true ()));
          equal (list queue_entry_value) ~msg:"completed keeps the queue"
            [ queue_entry "queued" ]
            (run Session.Turn.Outcome.completed));
    ]

let bypass_group =
  group "replay: tool-result bypass"
    [
      test "a result answering the open tool claim's call is rejected"
        (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let started = tool_claim ~turn:(Session.Turn.id t) call in
          expect_step_error ~msg:"bypass of an open claim"
            (State.Error.Result_bypass "call-1")
            (base @ [ Event.tool_claimed started ])
            (Event.message_appended
               (Llm.Message.tool_result (Llm.Tool.Result.text call "sneaky"))));
      test "a result answering the open decision's call is rejected" (fun () ->
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let requested =
            permission_decision ~turn:(Session.Turn.id t) ~call
              (access "session.review")
          in
          expect_step_error ~msg:"bypass of an open decision"
            (State.Error.Result_bypass "call-1")
            (base @ [ Event.decision_requested requested ])
            (Event.message_appended
               (Llm.Message.tool_result (Llm.Tool.Result.text call "sneaky"))));
      test "every other tool result is an ordinary append" (fun () ->
          let call_a = tool_call ~id:"call-a" () in
          let call_b = tool_call ~id:"call-b" () in
          let t, base = mid_turn [ call_a; call_b ] in
          let started = tool_claim ~turn:(Session.Turn.id t) call_a in
          let st =
            state
              (base
              @ [
                  Event.tool_claimed started;
                  Event.message_appended
                    (Llm.Message.tool_result
                       (Llm.Tool.Result.text call_b "host answered"));
                ])
          in
          match tool_result_for "call-b" st with
          | Some _ -> ()
          | None -> fail "expected the sibling result to append");
      test "tool results require an active turn" (fun () ->
          expect_apply_error ~msg:"no active turn"
            (State.Error.Turn State.Error.Turn.No_active)
            (Event.message_appended
               (Llm.Message.tool_result
                  (Llm.Tool.Result.text (tool_call ()) "stray")))
            State.empty);
    ]

(* Compaction. *)

let summary_compaction ?(reason = Session.Compaction.Reason.User_requested)
    ?(seed = "summary-req") ?usage ~claim ~upto () =
  Session.Compaction.make ~reason ~provider_claim:(claim_id claim)
    ~request_digest:(digest seed)
    ~summary_messages:[ Llm.Message.user_text "Summary." ]
    ~summarized_upto:upto ?usage ()

let compaction_group =
  group "replay: compaction"
    [
      test
        "the install closes the open summary claim and derives the model view"
        (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c1 = claim ~seed:"work" t_id in
          let c2 = claim ~seed:"summary" t_id in
          let compaction = summary_compaction ~claim:c2 ~upto:2 () in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c1;
                respond ~usage:(usage ~input:9 ~output:3) c1 "Long history.";
                Event.provider_requested c2;
                Event.compaction_installed compaction;
              ]
          in
          equal (option suspension_value) ~msg:"summary claim closed" None
            (State.suspension st);
          equal (option compaction_value) ~msg:"latest compaction"
            (Some compaction)
            (State.latest_compaction st);
          equal int ~msg:"full history keeps every message (nothing deleted)" 2
            (List.length (messages_of (State.full_transcript st)));
          equal (list message_value) ~msg:"model view is summary plus tail"
            [ Llm.Message.user_text "Summary." ]
            (messages_of (State.model_transcript st));
          equal (option pass) ~msg:"replay usage clears at the boundary" None
            (State.replay_usage st);
          expect_apply_error ~msg:"a compaction-closed claim is not pending"
            (State.Error.Provider
               (State.Error.Provider.Not_pending (claim_id c2)))
            (settle_ambiguous c2) st;
          expect_apply_error ~msg:"a compaction-closed claim remains seen"
            (State.Error.Provider (State.Error.Provider.Duplicate (claim_id c2)))
            (Event.provider_requested c2)
            st);
      test "two views agree outside the boundary" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c1 = claim ~seed:"work" t_id in
          let c2 = claim ~seed:"summary" t_id in
          let c3 = claim ~seed:"after" t_id in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c1;
                respond c1 "Long history.";
                Event.provider_requested c2;
                Event.compaction_installed
                  (summary_compaction ~claim:c2 ~upto:1 ());
                Event.provider_requested c3;
                respond c3 "Fresh work.";
              ]
          in
          let last list = List.nth list (List.length list - 1) in
          let full = messages_of (State.full_transcript st) in
          let modelv = messages_of (State.model_transcript st) in
          equal message_value ~msg:"post-compaction work shows in both views"
            (last full) (last modelv);
          equal int ~msg:"full view keeps the whole history" 3
            (List.length full);
          equal int ~msg:"model view replaces the summarized prefix" 3
            (List.length modelv);
          equal (option string) ~msg:"a real change never renders unchanged"
            (Some "Fresh work.") (State.final_text st));
      test "the install must name the open provider suspension" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c1 = claim ~seed:"work" t_id in
          let base =
            [
              Event.turn_started t;
              Event.provider_requested c1;
              respond c1 "History.";
            ]
          in
          expect_step_error ~msg:"a settled claim cannot be the closer"
            (State.Error.Provider
               (State.Error.Provider.Not_pending (claim_id c1)))
            base
            (Event.compaction_installed
               (summary_compaction ~claim:c1 ~upto:1 ()));
          let never = claim ~seed:"never" t_id in
          expect_step_error ~msg:"an unopened claim is unknown"
            (State.Error.Provider
               (State.Error.Provider.Unknown (claim_id never)))
            base
            (Event.compaction_installed
               (summary_compaction ~claim:never ~upto:1 ())));
      test "a duplicate (request digest, reason) key is rejected" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c1 = claim ~seed:"work" t_id in
          let c2 = claim ~seed:"summary" t_id in
          let c3 = claim ~seed:"summary-2" t_id in
          let base =
            [
              Event.turn_started t;
              Event.provider_requested c1;
              respond c1 "History.";
              Event.provider_requested c2;
              Event.compaction_installed
                (summary_compaction ~seed:"same" ~claim:c2 ~upto:1 ());
              Event.provider_requested c3;
            ]
          in
          expect_step_error ~msg:"double summary"
            (State.Error.Compaction
               (State.Error.Compaction.Duplicate_key
                  { reason = Session.Compaction.Reason.User_requested }))
            base
            (Event.compaction_installed
               (summary_compaction ~seed:"same" ~claim:c3 ~upto:1 ()));
          let st =
            state
              (base
              @ [
                  Event.compaction_installed
                    (summary_compaction ~seed:"same"
                       ~reason:Session.Compaction.Reason.Context_overflow
                       ~claim:c3 ~upto:1 ());
                ])
          in
          equal (option compaction_value)
            ~msg:"the second reason admits and becomes latest"
            (Some
               (summary_compaction ~seed:"same"
                  ~reason:Session.Compaction.Reason.Context_overflow ~claim:c3
                  ~upto:1 ()))
            (State.latest_compaction st));
      test "an out-of-range boundary is rejected" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c1 = claim ~seed:"work" t_id in
          let c2 = claim ~seed:"summary" t_id in
          expect_step_error ~msg:"boundary past the transcript"
            (State.Error.Compaction
               (State.Error.Compaction.Bad_boundary
                  { summarized_upto = 9; length = 2 }))
            [
              Event.turn_started t;
              Event.provider_requested c1;
              respond c1 "History.";
              Event.provider_requested c2;
            ]
            (Event.compaction_installed
               (summary_compaction ~claim:c2 ~upto:9 ())));
      test "pending-fix F1: an install must not orphan a pending call"
        (fun () ->
          (* Dropping the assistant message that carries a still-pending call
             leaves its later settlement unanswerable in the model view; the
             install must be rejected so model_transcript stays total. *)
          let call = tool_call () in
          let t, base = mid_turn [ call ] in
          let c2 = claim ~seed:"summary" (Session.Turn.id t) in
          expect_step_error ~msg:"boundary swallowing a pending call"
            (State.Error.Compaction
               (State.Error.Compaction.Dropped_pending_call
                  { call_id = "call-1" }))
            (base @ [ Event.provider_requested c2 ])
            (Event.compaction_installed
               (summary_compaction ~claim:c2 ~upto:2 ()));
          (* The control: a boundary that retains the pending call's opening
             assistant message is admitted mid-call. *)
          let st =
            state
              (base
              @ [
                  Event.provider_requested c2;
                  Event.compaction_installed
                    (summary_compaction ~claim:c2 ~upto:1 ());
                ])
          in
          is_true ~msg:"retained-opener install is accepted"
            (Option.is_some (State.latest_compaction st));
          is_false ~msg:"the call is still pending in the model view"
            (Llm.Transcript.is_ready (State.model_transcript st)));
      test "a claimed-but-uninstalled summary recovers ambiguously" (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c1 = claim ~seed:"work" t_id in
          let c2 = claim ~seed:"summary" t_id in
          let st =
            state
              [
                Event.turn_started t;
                Event.provider_requested c1;
                respond c1 "History.";
                Event.provider_requested c2;
                (* Crash before the install: ordinary recovery, no compaction
                   knowledge needed. *)
                settle_ambiguous c2;
                finish
                  ~outcome:
                    (Session.Turn.Outcome.interrupted ~cancelled:false ())
                  t;
              ]
          in
          equal (option compaction_value) ~msg:"no compaction was installed"
            None
            (State.latest_compaction st);
          equal (option outcome_value) ~msg:"the turn interrupted"
            (Some (Session.Turn.Outcome.interrupted ~cancelled:false ()))
            (State.turn_outcome t_id st));
      test "constructors validate boundaries and context estimates" (fun () ->
          expect_invalid_arg "negative boundary" (fun () ->
              summary_compaction ~claim:(claim (turn_id "turn-1")) ~upto:(-1) ());
          expect_invalid_arg "empty context estimate" (fun () ->
              Session.Compaction.Context_tokens.make ());
          expect_invalid_arg "negative context estimate" (fun () ->
              Session.Compaction.Context_tokens.make ~before:(-5) ()));
      test
        "a manual-compaction turn installs, settles, and stays transparent to \
         the round count" (fun () ->
          let t1 = turn ~id:"work" () in
          let c1 = claim ~seed:"work-req" (Session.Turn.id t1) in
          let t2 =
            turn ~id:"compaction" ~origin:Session.Turn.Origin.Compaction
              ~input:Session.Turn.Input.continue ()
          in
          let cs = claim ~seed:"summary-req" (Session.Turn.id t2) in
          let compaction =
            summary_compaction ~seed:"summary-req" ~claim:cs ~upto:2
              ~usage:(usage ~input:40 ~output:8)
              ()
          in
          let events =
            [
              Event.turn_started t1;
              Event.provider_requested c1;
              respond ~usage:(usage ~input:12 ~output:4) c1 "Done.";
              finish t1;
              Event.turn_started t2;
              Event.provider_requested cs;
              Event.compaction_installed compaction;
              finish t2;
            ]
          in
          let st = state events in
          equal (option compaction_value)
            ~msg:"the user_requested summary is the latest compaction"
            (Some compaction)
            (State.latest_compaction st);
          equal (option turn_id_value) ~msg:"the compaction turn settled" None
            (State.active_turn_id st);
          equal int ~msg:"State.turns keeps every accepted turn" 2
            (List.length (State.turns st));
          (* Every user-facing projection treats the compaction turn as an
             internal mechanism, not a conversational round. *)
          let doc = saved events in
          equal int ~msg:"the round count excludes the compaction turn" 1
            (Session.Summary.turns (Session.Summary.of_session doc));
          equal int ~msg:"metrics counts one round, not the compaction turn" 1
            (Session.metrics doc).Session.Metrics.turns;
          (* The summarizer usage still folds into the session total. *)
          equal usage_value ~msg:"the summarizer usage is still billed"
            (usage ~input:52 ~output:12)
            (Session.metrics doc).Session.Metrics.usage);
      test "a compaction origin admits only continue input" (fun () ->
          (* The engine's manual flow always uses Continue; a journal pairing the
             Compaction origin with user content is rejected at replay. *)
          expect_step_error ~msg:"compaction turn carrying user content"
            (State.Error.Turn
               (State.Error.Turn.Unexpected_compaction_input
                  (turn_id "compaction")))
            []
            (Event.turn_started
               (turn ~id:"compaction" ~origin:Session.Turn.Origin.Compaction
                  ~input:(Session.Turn.Input.user_text "not allowed")
                  ()));
          let ok =
            turn ~id:"compaction-ok" ~origin:Session.Turn.Origin.Compaction
              ~input:Session.Turn.Input.continue ()
          in
          equal (option turn_id_value) ~msg:"continue input is accepted"
            (Some (turn_id "compaction-ok"))
            (State.active_turn_id (state [ Event.turn_started ok ])));
    ]

(* Boards, queue, delegations. *)

let board_group =
  group "task board"
    [
      test "items default to pending medium and validate their shape" (fun () ->
          let item = task_item ~id:"task-1" ~position:0 "Write tests" in
          is_true ~msg:"status defaults to pending"
            (Session.Task.Status.equal Session.Task.Status.Pending
               item.Session.Task.Item.status);
          is_true ~msg:"priority defaults to medium"
            (Session.Task.Priority.equal Session.Task.Priority.Medium
               item.Session.Task.Item.priority);
          (match
             Session.Task.Item.make
               ~id:(Session.Task.Id.of_string "task-1")
               ~owner:Session.Task.Owner.Main ~content:"" ~position:0 ()
           with
          | Error Session.Task.Error.Empty_content -> ()
          | _ -> fail "expected Empty_content");
          match
            Session.Task.Item.make
              ~id:(Session.Task.Id.of_string "task-1")
              ~owner:Session.Task.Owner.Main ~content:"x" ~position:(-1) ()
          with
          | Error Session.Task.Error.Negative_position -> ()
          | _ -> fail "expected Negative_position");
      test "the board is self-validating" (fun () ->
          (match
             Session.Task.Board.make
               [
                 task_item ~id:"task-1" ~position:0 "one";
                 task_item ~id:"task-1" ~position:1 "two";
               ]
           with
          | Error (Session.Task.Error.Duplicate_id _) -> ()
          | _ -> fail "expected Duplicate_id");
          (match
             Session.Task.Board.make
               [
                 task_item ~id:"task-1" ~position:0 "one";
                 task_item ~id:"task-2" ~position:2 "two";
               ]
           with
          | Error Session.Task.Error.Non_contiguous_positions -> ()
          | _ -> fail "expected Non_contiguous_positions");
          match
            Session.Task.Board.make
              [
                task_item ~id:"task-1" ~position:0
                  ~status:Session.Task.Status.In_progress "one";
                task_item ~id:"task-2" ~position:1
                  ~status:Session.Task.Status.In_progress "two";
              ]
          with
          | Error Session.Task.Error.Multiple_in_progress -> ()
          | _ -> fail "expected Multiple_in_progress");
      test "tasks_replaced replaces the whole board atomically" (fun () ->
          let first = board [ task_item ~id:"task-1" ~position:0 "one" ] in
          let second = board [ task_item ~id:"task-9" ~position:0 "nine" ] in
          equal board_value ~msg:"the board starts empty"
            Session.Task.Board.empty (State.tasks State.empty);
          let st =
            state [ Event.tasks_replaced first; Event.tasks_replaced second ]
          in
          equal board_value ~msg:"the last replacement wins" second
            (State.tasks st));
    ]

let queue_group =
  group "queue"
    [
      test "updates append, replace, and clear" (fun () ->
          let st =
            state
              [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "one"));
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry ~id:"q-2" "two"));
              ]
          in
          equal (list queue_entry_value) ~msg:"append order"
            [ queue_entry ~id:"q-1" "one"; queue_entry ~id:"q-2" "two" ]
            (State.pending_queue st);
          let replaced =
            state
              [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "one"));
                Event.queue_updated
                  (Session.Queue.Update.replaced
                     [ queue_entry ~id:"q-9" "nine" ]);
              ]
          in
          equal (list queue_entry_value) ~msg:"whole-queue replacement"
            [ queue_entry ~id:"q-9" "nine" ]
            (State.pending_queue replaced);
          let cleared =
            state
              [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "one"));
                Event.queue_updated Session.Queue.Update.cleared;
              ]
          in
          equal (list queue_entry_value) ~msg:"cleared" []
            (State.pending_queue cleared));
      test "constructors validate entries" (fun () ->
          expect_invalid_arg "empty input" (fun () ->
              Session.Queue.Entry.make ~id:(queue_id "q-1") ~input:[]);
          expect_invalid_arg "duplicate ids in a replacement" (fun () ->
              Session.Queue.Update.replaced
                [ queue_entry ~id:"q-1" "one"; queue_entry ~id:"q-1" "two" ]));
      test "pending-fix F13: a duplicate pending entry id is rejected"
        (fun () ->
          (* Two pending entries with one id would make Queued-origin admission
             ambiguous about which entry it consumed. *)
          let base =
            [
              Event.queue_updated
                (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "one"));
            ]
          in
          expect_step_error ~msg:"duplicate enqueue"
            (State.Error.Queue (State.Error.Queue.Duplicate (queue_id "q-1")))
            base
            (Event.queue_updated
               (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "two")));
          (* A replacement edits the whole queue, so it may reuse an id that is
             currently pending. *)
          let st =
            state
              (base
              @ [
                  Event.queue_updated
                    (Session.Queue.Update.replaced
                       [ queue_entry ~id:"q-1" "rewritten" ]);
                ])
          in
          equal (list queue_entry_value) ~msg:"replacement reuses the id"
            [ queue_entry ~id:"q-1" "rewritten" ]
            (State.pending_queue st));
    ]

let delegation_group =
  group "delegations"
    [
      test "the edge records during its active source turn" (fun () ->
          let t, base = mid_turn [ tool_call () ] in
          let edge =
            Session.Delegation.make ~child:(session_id "child-1")
              ~source_turn:(Session.Turn.id t) ~source_call:"call-1"
              ~task:[ Llm.Content.text "Explore." ]
              ()
          in
          let st = state (base @ [ Event.delegation_recorded edge ]) in
          equal (list delegation_value) ~msg:"edge recorded" [ edge ]
            (State.delegations st);
          is_true ~msg:"the child id is the parent-minted session id"
            (Session.Id.equal (session_id "child-1")
               (Session.Delegation.child edge)));
      test "the optional role rides the edge and round-trips durably" (fun () ->
          let t, base = mid_turn [ tool_call () ] in
          let make ?role () =
            Session.Delegation.make ~child:(session_id "child-1")
              ~source_turn:(Session.Turn.id t) ~source_call:"call-1" ?role
              ~task:[ Llm.Content.text "Explore." ]
              ()
          in
          is_true ~msg:"a spawn without a role records a generic delegate"
            (Option.is_none (Session.Delegation.role (make ())));
          List.iter
            (fun role ->
              let edge = make ~role () in
              is_true
                ~msg:
                  ("the accessor reflects the role "
                  ^ Session.Delegation.Role.to_string role)
                (match Session.Delegation.role edge with
                | Some recorded -> Session.Delegation.Role.equal recorded role
                | None -> false);
              (* Same journal bytes rebuild the identical edge, so replay
                 reconstructs the same role deterministically. *)
              let text = encode_text Session.Delegation.jsont edge in
              (match
                 Jsont_bytesrw.decode_string Session.Delegation.jsont text
               with
              | Ok decoded ->
                  is_true ~msg:"the role survives the durable jsont round-trip"
                    (Session.Delegation.equal edge decoded)
              | Error message -> failf "decode edge: %s" message);
              let st = state (base @ [ Event.delegation_recorded edge ]) in
              equal (list delegation_value)
                ~msg:"the replayed edge keeps its role" [ edge ]
                (State.delegations st))
            [
              Session.Delegation.Role.Explore;
              Session.Delegation.Role.Review;
              Session.Delegation.Role.Verify;
            ]);
      test "the optional description rides the edge and normalizes blanks"
        (fun () ->
          let t, base = mid_turn [ tool_call () ] in
          let make ?description () =
            Session.Delegation.make ~child:(session_id "child-1")
              ~source_turn:(Session.Turn.id t) ~source_call:"call-1"
              ?description
              ~task:[ Llm.Content.text "Explore." ]
              ()
          in
          is_true ~msg:"a spawn without a description records none"
            (Option.is_none (Session.Delegation.description (make ())));
          is_true ~msg:"a blank description normalizes to none"
            (Option.is_none
               (Session.Delegation.description (make ~description:"   " ())));
          let edge = make ~description:"audit the loader" () in
          equal (option string) ~msg:"the accessor reflects the description"
            (Some "audit the loader")
            (Session.Delegation.description edge);
          (* Same journal bytes rebuild the identical edge, so replay
             reconstructs the same description deterministically. *)
          let text = encode_text Session.Delegation.jsont edge in
          (match Jsont_bytesrw.decode_string Session.Delegation.jsont text with
          | Ok decoded ->
              is_true
                ~msg:"the description survives the durable jsont round-trip"
                (Session.Delegation.equal edge decoded)
          | Error message -> failf "decode edge: %s" message);
          let st = state (base @ [ Event.delegation_recorded edge ]) in
          equal (list delegation_value)
            ~msg:"the replayed edge keeps its description" [ edge ]
            (State.delegations st));
      test "the source turn must be the active turn" (fun () ->
          let _, base = mid_turn [ tool_call () ] in
          let foreign =
            Session.Delegation.make ~child:(session_id "child-1")
              ~source_turn:(turn_id "turn-other") ~source_call:"call-1"
              ~task:[ Llm.Content.text "Explore." ]
              ()
          in
          expect_step_error ~msg:"foreign source turn"
            (State.Error.Turn (State.Error.Turn.Active (turn_id "turn-1")))
            base
            (Event.delegation_recorded foreign);
          expect_apply_error ~msg:"no active turn"
            (State.Error.Turn State.Error.Turn.No_active)
            (Event.delegation_recorded foreign)
            State.empty);
      test "constructors validate local shape" (fun () ->
          let make ?(source_call = "call-1")
              ?(task = [ Llm.Content.text "Go." ]) () =
            Session.Delegation.make ~child:(session_id "child-1")
              ~source_turn:(turn_id "turn-1") ~source_call ~task ()
          in
          expect_invalid_arg "empty source call" (fun () ->
              make ~source_call:"" ());
          expect_invalid_arg "empty task" (fun () -> make ~task:[] ());
          (* R15: a delegation task is text-only; a media block would ride the
             edge without joining the media relocation and versioning passes. *)
          expect_invalid_arg "media task" (fun () ->
              make
                ~task:
                  [
                    Llm.Content.media ~media_type:"image/png"
                      (`Ref (Mentat_digest.Content_ref.of_contents "image"));
                  ]
                ()));
      test "pending-fix F6: duplicate edges and reused children are rejected"
        (fun () ->
          let t, base = mid_turn [ tool_call () ] in
          let make ?(child = "child-1") source_call =
            Session.Delegation.make ~child:(session_id child)
              ~source_turn:(Session.Turn.id t) ~source_call
              ~task:[ Llm.Content.text "Explore." ]
              ()
          in
          let edge = make "call-1" in
          let recorded = base @ [ Event.delegation_recorded edge ] in
          expect_step_error ~msg:"the edge is immutable and unique"
            (State.Error.Delegation
               (State.Error.Delegation.Duplicate (Session.Delegation.id edge)))
            recorded
            (Event.delegation_recorded edge);
          expect_step_error ~msg:"a fresh edge may not reuse a child session id"
            (State.Error.Delegation
               (State.Error.Delegation.Duplicate_child (session_id "child-1")))
            recorded
            (Event.delegation_recorded (make "call-2"));
          equal int ~msg:"a fresh edge with a fresh child is admitted" 2
            (List.length
               (State.delegations
                  (state
                     (recorded
                     @ [
                         Event.delegation_recorded
                           (make ~child:"child-2" "call-2");
                       ])))));
    ]

(* Replay algebra. *)

let replay_group =
  group "replay algebra"
    [
      test "the canonical journal replays to the expected projections"
        (fun () ->
          let j = journal () in
          let st = state j.events in
          equal (list turn_value) ~msg:"three turns in start order"
            [ j.t1; j.t2; j.t3 ] (State.turns st);
          equal (option suspension_value) ~msg:"quiescent at the end" None
            (State.suspension st);
          equal (option turn_id_value) ~msg:"no active turn" None
            (State.active_turn_id st);
          equal int ~msg:"four tool claims (staged pair counts twice)" 4
            (List.length (State.tool_claims st));
          is_true ~msg:"every claim settled"
            (List.for_all
               (fun (_, settled) -> Option.is_some settled)
               (State.tool_claims st));
          (match
             List.find_opt
               (fun (started, _) ->
                 Tool.Stage.equal Tool.Stage.Prepare
                   (Session.Tool_claim.Started.stage started))
               (State.tool_claims st)
           with
          | Some (started, Some settled) -> (
              equal json_value ~msg:"the prepare claim snapshots the call input"
                (input_json "alpha")
                (Session.Tool_claim.Started.input started);
              match Session.Tool_claim.Settled.outcome settled with
              | Session.Tool_claim.Settled.Prepared recorded ->
                  equal prepared_value
                    ~msg:"the prepared payload survives replay" j.prepared
                    recorded
              | _ -> fail "expected the prepared settlement")
          | _ -> fail "expected the settled prepare claim");
          let requested_decisions =
            List.filter_map
              (function
                | Session.Event.Decision_requested requested -> Some requested
                | _ -> None)
              j.events
          in
          equal int ~msg:"three decision facts" 3
            (List.length requested_decisions);
          is_true ~msg:"every keyed decision resolved"
            (List.for_all
               (fun requested ->
                 match
                   State.decision (Session.Decision.Requested.id requested) st
                 with
                 | Some (_, Some _) -> true
                 | Some (_, None) | None -> false)
               requested_decisions);
          is_true ~msg:"the reviewed access became a grant"
            (Permission.Policy.Grants.allows (State.grants st) j.probe_access);
          is_false ~msg:"the denied access did not"
            (Permission.Policy.Grants.allows (State.grants st) j.risky_access);
          equal (list queue_entry_value)
            ~msg:"queued admission consumed the entry" []
            (State.pending_queue st);
          equal board_value ~msg:"board replayed" j.journal_board
            (State.tasks st);
          equal (list delegation_value) ~msg:"delegation edge replayed"
            [ j.edge ] (State.delegations st);
          equal (option compaction_value) ~msg:"compaction installed"
            (Some j.compaction)
            (State.latest_compaction st);
          equal (option string) ~msg:"final text is the retained prose"
            (Some "Stopping here.") (State.final_text st);
          (match messages_of (State.model_transcript st) with
          | first :: _ ->
              equal message_value ~msg:"model view starts at the summary"
                (Llm.Message.user_text "Earlier work, summarized.")
                first
          | [] -> fail "expected a model view");
          is_true ~msg:"model view is request-ready"
            (Llm.Transcript.is_ready (State.model_transcript st));
          match tool_result_for "call-risky" st with
          | Some lowered ->
              equal string ~msg:"the denial spelling replays"
                "The user denied permission to run this command."
                (result_text lowered)
          | None -> fail "expected the denial result");
      test "replay is prefix-compositional at every split" (fun () ->
          let events = (journal ()).events in
          let direct = state events in
          let n = List.length events in
          for i = 0 to n do
            let prefix = List.filteri (fun index _ -> index < i) events in
            let suffix = List.filteri (fun index _ -> index >= i) events in
            let via_split =
              match State.apply_all suffix (state prefix) with
              | Ok st -> st
              | Error error ->
                  failf "split at %d failed: %a" i State.Replay_error.pp error
            in
            assert_states_equal
              ~msg:(Printf.sprintf "split at %d" i)
              direct via_split
          done);
      test "equal inputs fold to equal states" (fun () ->
          let events = (journal ()).events in
          assert_states_equal ~msg:"two folds of one journal" (state events)
            (state events));
      test "serialize, decode, and refold equals the direct fold" (fun () ->
          let j = journal () in
          let session = saved j.events in
          let decoded = decode Session.jsont (encode Session.jsont session) in
          is_true ~msg:"id round-trips"
            (Session.Id.equal (Session.id session) (Session.id decoded));
          is_true ~msg:"metadata round-trips"
            (Session.Metadata.equal (Session.metadata session)
               (Session.metadata decoded));
          equal (list event_value) ~msg:"events round-trip in order" j.events
            (Session.events decoded);
          assert_states_equal ~msg:"decoded state equals direct fold"
            (Session.state session) (Session.state decoded));
      test "a batch fails at the first located error" (fun () ->
          let t = turn () in
          let c = claim (Session.Turn.id t) in
          let events =
            [
              Event.turn_started t;
              Event.provider_requested c;
              Event.turn_started (turn ~id:"turn-2" ());
              Event.turn_started (turn ~id:"turn-3" ());
            ]
          in
          expect_replay_error ~msg:"first invalid event wins" ~index:2
            (State.Error.Turn (State.Error.Turn.Active (turn_id "turn-1")))
            events);
      test "replay errors expose their event and shift validates" (fun () ->
          let bad =
            Event.turn_finished ~turn:(turn_id "turn-1")
              Session.Turn.Outcome.completed
          in
          match State.of_events [ bad ] with
          | Ok _ -> fail "expected a replay error"
          | Error error ->
              equal event_value ~msg:"the offending event is retained" bad
                (State.Replay_error.event error);
              equal int ~msg:"shift adds" 5
                (State.Replay_error.index
                   (State.Replay_error.shift ~by:5 error));
              expect_invalid_arg "negative shift" (fun () ->
                  State.Replay_error.shift ~by:(-1) error));
    ]

(* The journal as a state machine.

   Every replay group above pins one hand-written journey. The architecture's
   load-bearing replay claim is stronger than any list of journeys: over *every*
   valid lifecycle, the projection [State.apply] maintains incrementally equals
   the one [State.of_events] folds from scratch — full replay equals
   snapshot-plus-suffix. Only a model over generated command sequences states
   that quantifier, and when it breaks it shrinks to the shortest event sequence
   that shows it.

   The model is the turn-and-claim spec, not a second projection: which turn is
   active, whether a provider claim is open, and whether the turn has been
   forced interrupt-only — by an explicit request, or by an ambiguous
   settlement, which the provider group pins as forcing the same way. *)

type journal_model = {
  next_turn : int;  (** names the next turn; ids are [turn-1], [turn-2], ... *)
  next_claim : int;  (** names the next claim seed, so no turn reuses one *)
  active : string option;  (** the active turn's id, when one is *)
  pending : string option;  (** the open provider claim's seed, when one is *)
  interrupt_asked : bool;  (** [Interrupt_requested] ran on the active turn *)
  forced : bool;  (** the active turn may settle only [Interrupted] *)
}

let journal_model_empty =
  {
    next_turn = 1;
    next_claim = 1;
    active = None;
    pending = None;
    interrupt_asked = false;
    forced = false;
  }

let pp_journal_model ppf m =
  let opt ppf = function
    | None -> Format.pp_print_string ppf "-"
    | Some s -> Format.pp_print_string ppf s
  in
  Format.fprintf ppf "{ active = %a; claim = %a; interrupt = %b; forced = %b }"
    opt m.active opt m.pending m.interrupt_asked m.forced

(* The system under test: the incrementally maintained projection beside the
   log that produced it, so the invariant can re-fold that log and compare. *)
type journal_sut = { mutable proj : State.t; mutable rlog : Event.t list }

(* The model claims every event it generates is admissible, so a refusal is a
   failure of the specification, not an expected outcome to assert on. *)
let journal_apply sut event =
  match State.apply event sut.proj with
  | Ok proj ->
      sut.proj <- proj;
      sut.rlog <- event :: sut.rlog
  | Error error ->
      failf "the model offered an event the journal refused: %s"
        (State.Error.message error)

let model_turn_id m = turn_id (Option.get m.active)
let claim_seed n = Printf.sprintf "req-%d" n
let turn_name n = Printf.sprintf "turn-%d" n

(* What a provider claim settles as. [Responded] appends an assistant message;
   [Failed] proves an outcome and forces nothing; [Ambiguous] is the crash
   report, and forces the turn interrupt-only. *)
type settlement = Responded | Settle_failed | Ambiguous

let pp_settlement ppf s =
  Format.pp_print_string ppf
    (match s with
    | Responded -> "responded"
    | Settle_failed -> "failed"
    | Ambiguous -> "ambiguous")

let settlement_gen =
  Gen.of_list [ Responded; Settle_failed; Ambiguous ]
  |> Gen.with_pp pp_settlement

let journal_commands =
  [
    call "start turn"
      ~pre:(fun m -> m.active = None)
      ~next:(fun m ->
        {
          m with
          next_turn = m.next_turn + 1;
          active = Some (turn_name m.next_turn);
          pending = None;
          interrupt_asked = false;
          forced = false;
        })
      (fun m sut ->
        let id = turn_name m.next_turn in
        journal_apply sut (Event.turn_started (turn ~id ()));
        equal (option string) ~msg:"the started turn is the active one"
          (Some id)
          (Option.map Session.Turn.Id.to_string (State.active_turn_id sut.proj)));
    call "request provider"
      ~pre:(fun m -> m.active <> None && m.pending = None && not m.forced)
      ~next:(fun m ->
        {
          m with
          next_claim = m.next_claim + 1;
          pending = Some (claim_seed m.next_claim);
        })
      (fun m sut ->
        let c = claim ~seed:(claim_seed m.next_claim) (model_turn_id m) in
        journal_apply sut (Event.provider_requested c);
        equal (option suspension_value) ~msg:"the open claim suspends the turn"
          (Some (State.Provider c))
          (State.suspension sut.proj));
    command "settle provider" settlement_gen
      ~pre:(fun m _ -> m.pending <> None)
      ~next:(fun m s ->
        { m with pending = None; forced = m.forced || s = Ambiguous })
      (fun m s sut ->
        let c = claim ~seed:(Option.get m.pending) (model_turn_id m) in
        journal_apply sut
          (match s with
          | Responded -> respond c "done"
          | Settle_failed -> settle_failed c
          | Ambiguous -> settle_ambiguous c);
        equal (option suspension_value) ~msg:"settling closes the suspension"
          None
          (State.suspension sut.proj));
    call "request interrupt"
      ~pre:(fun m -> m.active <> None && not m.forced)
      ~next:(fun m -> { m with interrupt_asked = true; forced = true })
      (fun m sut ->
        journal_apply sut (Event.interrupt_requested ~turn:(model_turn_id m) ());
        is_true ~msg:"the interrupt is recorded"
          (State.interrupt_requested sut.proj));
    call "finish turn"
      ~pre:(fun m -> m.active <> None && m.pending = None)
      ~next:(fun m ->
        { m with active = None; interrupt_asked = false; forced = false })
      (fun m sut ->
        (* A forced turn may settle only [Interrupted]; anything else is the
           replay error the provider group pins. *)
        let outcome =
          if m.forced then Session.Turn.Outcome.interrupted ~cancelled:false ()
          else Session.Turn.Outcome.completed
        in
        let t_id = model_turn_id m in
        journal_apply sut (Event.turn_finished ~turn:t_id outcome);
        equal (option outcome_value) ~msg:"the turn settles with its outcome"
          (Some outcome)
          (State.turn_outcome t_id sut.proj);
        equal (option turn_id_value) ~msg:"no turn is active after finishing"
          None
          (State.active_turn_id sut.proj));
  ]

let journal_machine_group =
  group "replay: the journal as a state machine"
    [
      stateful "the incremental projection equals the full fold"
        ~model:journal_model_empty ~pp_model:pp_journal_model
        ~scope:(fun run -> run { proj = State.empty; rlog = [] })
        ~invariant:(fun m sut ->
          (* The load-bearing law: re-folding the whole log from empty must
             reach the state the per-event applies built. *)
          assert_states_equal ~msg:"incremental apply equals the full fold"
            (state (List.rev sut.rlog))
            sut.proj;
          equal (option string) ~msg:"the model agrees on the active turn"
            m.active
            (Option.map Session.Turn.Id.to_string
               (State.active_turn_id sut.proj));
          equal bool ~msg:"the model agrees on the interrupt flag"
            m.interrupt_asked
            (State.interrupt_requested sut.proj);
          equal bool ~msg:"a claim is open exactly when the model says so"
            (m.pending <> None)
            (Option.is_some (State.suspension sut.proj));
          (* Both rare states have to be reached, or the commands that depend
             on them never ran and the suite is quietly weaker than it reads. *)
          cover "a turn forced interrupt-only" m.forced;
          cover "an open provider claim" (m.pending <> None))
        journal_commands;
    ]

(* The session document. *)

let document_group =
  group "session document"
    [
      test "create starts an empty active session" (fun () ->
          let session =
            Session.create ~id:(session_id "s-1") ~title:"Fresh" ~cwd
              ~created_at:(time 5) ()
          in
          equal (list event_value) ~msg:"no events" [] (Session.events session);
          equal (option string) ~msg:"title kept" (Some "Fresh")
            (Session.Metadata.title (Session.metadata session));
          is_true ~msg:"active"
            (Session.Metadata.is_active (Session.metadata session));
          expect_invalid_arg "empty title" (fun () ->
              Session.create ~id:(session_id "s-2") ~title:"" ~cwd
                ~created_at:(time 5) ()));
      test "make validates replay and locates the failure" (fun () ->
          match
            Session.make ~id:(session_id "s-1") ~metadata:saved_metadata
              ~events:
                [
                  Event.turn_started (turn ());
                  Event.turn_started (turn ~id:"turn-2" ());
                ]
          with
          | Ok _ -> fail "expected a replay error"
          | Error (Session.Error.Replay error) ->
              equal int ~msg:"located at the second event" 1
                (State.Replay_error.index error)
          | Error error -> failf "unexpected error: %a" Session.Error.pp error);
      test "metadata persists its workspace as the bare \"cwd\" path member"
        (fun () ->
          (* Workspace identity unified on [Mentat_workspace.Root], but the
             durable shape is byte-unchanged: "cwd" is still the plain directory
             string, never a root object carrying a key. Old documents load and
             new ones stay byte-identical on disk. *)
          let json = encode Session.Metadata.jsont saved_metadata in
          (match get_member "cwd" json with
          | Jsont.String (path, _) ->
              equal string
                ~msg:"the durable cwd member is the bare directory string"
                "/workspace" path
          | other -> failf "cwd is not a plain path string: %a" pp_json other);
          is_true ~msg:"metadata round-trips through the unchanged wire shape"
            (Session.Metadata.equal saved_metadata
               (decode Session.Metadata.jsont json));
          is_true ~msg:"the cwd accessor still projects the creation directory"
            (Lpath.Abs.equal cwd (Session.Metadata.cwd saved_metadata)));
      test "jsont rejects unsupported versions and unknown members" (fun () ->
          let json = encode Session.jsont (saved (journal ()).events) in
          (* Versions 2 (structured-output), 3 (durable workspace notices), 4
             (deny-with-guidance), and 5 (undo boundary) are supported; the first
             unsupported future version is 6. *)
          assert_decode_error
            ~contains:"unsupported session version 6 (supported: 5)"
            "future version" Session.jsont
            (set_member "version" (Json.int 6) json);
          assert_decode_error
            ~contains:"unsupported session version 0 (supported: 5)"
            "version zero" Session.jsont
            (set_member "version" (Json.int 0) json);
          assert_decode_error "fractional version" Session.jsont
            (set_member "version" (Json.number 1.9) json);
          assert_decode_error "string version" Session.jsont
            (set_member "version" (Json.string "1") json);
          assert_decode_error "unknown member" Session.jsont
            (add_member "cursor" (Json.int 9) json));
      test "F5: the version gate is checked before any member is decoded"
        (fun () ->
          (* An unsupported version must report as such before any member is
             even decoded, let alone trusted: neither an undecodable event tag
             (fails member decode) nor a replay-invalid log (fails the
             object-finish trust step) behind version 99 preempts the version
             diagnostic. The export escape hatch depends on the diagnostic
             naming the version. *)
          let events ~undecodable =
            Json.list
              [
                (if undecodable then
                   (* An event tag this build does not know: under a supported
                      version the [events] member decode fails on it. *)
                   json_object [ ("type", Json.string "telemetry") ]
                 else
                   encode Event.jsont
                     (Event.turn_finished ~turn:(turn_id "turn-1")
                        Session.Turn.Outcome.completed));
              ]
          in
          let document ~undecodable version =
            json_object
              [
                ("version", version);
                ("id", Json.string "s-future");
                ("metadata", encode Session.Metadata.jsont saved_metadata);
                ("events", events ~undecodable);
              ]
          in
          (* Premise: under the supported version each log is a genuine
             failure — the unknown tag fails member decode, the finished turn
             fails replay — so the version diagnostics below prove ordering. *)
          assert_decode_error "supported version reaches member decode"
            Session.jsont
            (document ~undecodable:true (Json.int 1));
          assert_decode_error ~contains:"no turn is active"
            "supported version reaches replay" Session.jsont
            (document ~undecodable:false (Json.int 1));
          (* The unknown tag fails member decode strictly before the
             object-finish trust step; the version gate still wins. *)
          assert_decode_error ~contains:"version"
            "version gate precedes member decode" Session.jsont
            (document ~undecodable:true (Json.int 99));
          assert_decode_error ~contains:"version" "version gate precedes replay"
            Session.jsont
            (document ~undecodable:false (Json.int 99)));
      test "log appends respect the lifecycle status" (fun () ->
          let session = saved [] in
          let user = Event.message_appended (Llm.Message.user_text "Hi.") in
          let appended = ok_or "append" (Session.append user session) in
          equal (list event_value) ~msg:"event appended" [ user ]
            (Session.events appended);
          let archived = ok_or "archive" (Session.archive session) in
          expect_session_error ~msg:"append on archived" Session.Error.Archived
            (Session.append user archived);
          let deleted = ok_or "delete" (Session.delete session) in
          expect_session_error ~msg:"append on deleted" Session.Error.Deleted
            (Session.append user deleted);
          match Session.append (finish (turn ())) session with
          | Error
              (Session.Error.State (State.Error.Turn State.Error.Turn.No_active))
            ->
              ()
          | _ -> fail "expected the located state error");
      test "append_all locates errors at absolute log indices" (fun () ->
          let t = turn () in
          let session =
            saved
              [
                Event.turn_started t;
                Event.provider_requested (claim (Session.Turn.id t));
              ]
          in
          match
            Session.append_all
              [
                settle_ambiguous (claim (Session.Turn.id t));
                Event.turn_started (turn ~id:"turn-1" ());
              ]
              session
          with
          | Error (Session.Error.Replay error) ->
              equal int ~msg:"index counts the existing log" 3
                (State.Replay_error.index error)
          | Ok _ -> fail "expected a replay error"
          | Error error -> failf "unexpected error: %a" Session.Error.pp error);
      test "lifecycle transitions are idempotent and guarded" (fun () ->
          let session = saved (journal ()).events in
          let archived = ok_or "archive" (Session.archive session) in
          is_true ~msg:"archived"
            (Session.Metadata.is_archived (Session.metadata archived));
          ignore
            (require_ok ~msg:"archive is idempotent" (Session.archive archived));
          let restored = ok_or "restore" (Session.restore archived) in
          is_true ~msg:"restored"
            (Session.Metadata.is_active (Session.metadata restored));
          let deleted = ok_or "delete" (Session.delete restored) in
          expect_session_error ~msg:"restore after delete" Session.Error.Deleted
            (Session.restore deleted);
          expect_session_error ~msg:"archive after delete" Session.Error.Deleted
            (Session.archive deleted);
          ignore
            (require_ok ~msg:"delete is idempotent" (Session.delete deleted));
          let active =
            saved ~id:"session-active" [ Event.turn_started (turn ()) ]
          in
          expect_session_error ~msg:"archive with an active turn"
            (Session.Error.Active_turn (turn_id "turn-1"))
            (Session.archive active);
          expect_session_error ~msg:"delete with an active turn"
            (Session.Error.Active_turn (turn_id "turn-1"))
            (Session.delete active));
      test "metadata updates validate their shape" (fun () ->
          let session = saved [] in
          expect_invalid_arg "empty title" (fun () ->
              Session.set_title (Some "") session);
          expect_invalid_arg "touch before creation" (fun () ->
              Session.touch (time 0) session);
          let touched = Session.touch (time 9) session in
          is_true ~msg:"touch moves updated_at"
            (Session.Time.equal (time 9)
               (Session.Metadata.updated_at (Session.metadata touched)));
          expect_invalid_arg "negative time" (fun () ->
              Session.Time.of_unix_ms (-1L));
          expect_invalid_arg "metadata timestamp order" (fun () ->
              Session.Metadata.make ~cwd ~created_at:(time 5)
                ~updated_at:(time 1) ()));
    ]

(* Branch and rewind. *)

let finished_turn_events ?(id = "turn-1") ?(text = "Done.") () =
  let t = turn ~id ~input:(Session.Turn.Input.user_text ("Do " ^ id)) () in
  let c = claim ~seed:(id ^ "-req") (Session.Turn.id t) in
  [ Event.turn_started t; Event.provider_requested c; respond c text; finish t ]

let finished_delegating_turn_events ?(id = "turn-1") ?(call = "spawn-1")
    ?(child = "child-1") () =
  let t = turn ~id ~input:(Session.Turn.Input.user_text ("Do " ^ id)) () in
  let c = claim ~seed:(id ^ "-req") (Session.Turn.id t) in
  let edge =
    Session.Delegation.make ~child:(session_id child)
      ~source_turn:(Session.Turn.id t) ~source_call:call
      ~task:[ Llm.Content.text "Inspect the branch." ]
      ()
  in
  ( [
      Event.turn_started t;
      Event.provider_requested c;
      respond c "Done.";
      Event.delegation_recorded edge;
      finish t;
    ],
    edge )

let branch_metadata copied_events =
  let forked_from =
    Session.Metadata.Forked_from.make ~parent:(session_id "parent")
      ~copied_events
  in
  Session.Metadata.make ~forked_from ~cwd ~created_at:(time 10)
    ~updated_at:(time 10) ()

let reconstruct_branch prefix suffix =
  Session.make ~id:(session_id "branch")
    ~metadata:(branch_metadata (List.length prefix))
    ~events:(prefix @ suffix)

let branch_group =
  group "branch and rewind"
    [
      test "fork copies the prefix and appends the audited reset suffix"
        (fun () ->
          let delegated, edge = finished_delegating_turn_events () in
          let parent_events =
            delegated
            @ [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry "queued"));
              ]
          in
          let parent = saved parent_events in
          let child =
            ok_or "fork"
              (Session.fork ~id:(session_id "child") ~cwd ~created_at:(time 10)
                 parent)
          in
          let n = List.length parent_events in
          equal (list event_value) ~msg:"the copied prefix is byte-identical"
            parent_events
            (List.filteri (fun i _ -> i < n) (Session.events child));
          equal (list event_value) ~msg:"the reset suffix is auditable"
            [
              Event.queue_updated Session.Queue.Update.cleared;
              Event.delegations_detached;
            ]
            (List.filteri (fun i _ -> i >= n) (Session.events child));
          (match Session.Metadata.fork (Session.metadata child) with
          | Some lineage ->
              is_true ~msg:"lineage names the parent"
                (Session.Id.equal (Session.id parent)
                   (Session.Metadata.Forked_from.parent lineage));
              equal int ~msg:"copied_events excludes the reset suffix" n
                (Session.Metadata.Forked_from.copied_events lineage)
          | None -> fail "expected fork lineage");
          equal (list queue_entry_value) ~msg:"child inherits no queue" []
            (State.pending_queue (Session.state child));
          equal (list delegation_value) ~msg:"child inherits no live children"
            []
            (State.delegations (Session.state child));
          equal (list delegation_value) ~msg:"parent still owns its child"
            [ edge ]
            (State.delegations (Session.state parent));
          (* Reset-suffix orthogonality: everything else matches the parent. *)
          equal (list turn_value) ~msg:"turns unchanged"
            (State.turns (Session.state parent))
            (State.turns (Session.state child));
          equal (list message_value) ~msg:"transcript unchanged"
            (messages_of (State.full_transcript (Session.state parent)))
            (messages_of (State.full_transcript (Session.state child))));
      test "reconstruction requires every reset product in canonical order"
        (fun () ->
          let queue_prefix =
            finished_turn_events ()
            @ [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry "queued"));
              ]
          in
          let delegation_prefix, _ = finished_delegating_turn_events () in
          let all_prefix =
            delegation_prefix
            @ [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry "queued"));
              ]
          in
          ignore
            (require_ok ~msg:"queue reset"
               (reconstruct_branch queue_prefix
                  [ Event.queue_updated Session.Queue.Update.cleared ]));
          ignore
            (require_ok ~msg:"delegation reset"
               (reconstruct_branch delegation_prefix
                  [ Event.delegations_detached ]));
          ignore
            (require_ok ~msg:"combined reset"
               (reconstruct_branch all_prefix
                  [
                    Event.queue_updated Session.Queue.Update.cleared;
                    Event.delegations_detached;
                  ])));
      test "reconstruction reports the first missing or different reset event"
        (fun () ->
          let queue_prefix =
            finished_turn_events ()
            @ [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry "queued"));
              ]
          in
          let queue_reset = Event.queue_updated Session.Queue.Update.cleared in
          expect_session_error ~msg:"missing queue reset"
            (Session.Error.Branch_reset_mismatch
               {
                 index = List.length queue_prefix;
                 expected = queue_reset;
                 found = None;
               })
            (reconstruct_branch queue_prefix []);
          let all_prefix, _ = finished_delegating_turn_events () in
          let all_prefix =
            all_prefix
            @ [
                Event.queue_updated
                  (Session.Queue.Update.enqueued (queue_entry "queued"));
              ]
          in
          expect_session_error ~msg:"reordered reset"
            (Session.Error.Branch_reset_mismatch
               {
                 index = List.length all_prefix;
                 expected = queue_reset;
                 found = Some Event.delegations_detached;
               })
            (reconstruct_branch all_prefix
               [ Event.delegations_detached; queue_reset ]);
          let delegation_prefix, _ = finished_delegating_turn_events () in
          expect_session_error ~msg:"filler before detachment"
            (Session.Error.Branch_reset_mismatch
               {
                 index = List.length delegation_prefix;
                 expected = Event.delegations_detached;
                 found = Some queue_reset;
               })
            (reconstruct_branch delegation_prefix
               [ queue_reset; Event.delegations_detached ]));
      test "reconstruction rejects impossible boundaries and later detachments"
        (fun () ->
          let prefix = [ finish (turn ()) ] in
          let event_count = List.length prefix in
          expect_session_error ~msg:"copied boundary past the log"
            (Session.Error.Branch_copy_out_of_range
               { copied_events = event_count + 1; event_count })
            (Session.make ~id:(session_id "branch")
               ~metadata:(branch_metadata (event_count + 1))
               ~events:prefix);
          let delegated, _ = finished_delegating_turn_events () in
          let first_detach = List.length delegated in
          expect_session_error ~msg:"a later second detachment"
            (Session.Error.Unexpected_delegation_detachment
               { index = first_detach + 1 })
            (reconstruct_branch delegated
               [ Event.delegations_detached; Event.delegations_detached ]));
      test "append APIs cannot introduce delegation detachment" (fun () ->
          let root = saved [] in
          expect_session_error ~msg:"single append"
            (Session.Error.Unexpected_delegation_detachment { index = 0 })
            (Session.append Event.delegations_detached root);
          expect_session_error ~msg:"batch append"
            (Session.Error.Unexpected_delegation_detachment { index = 1 })
            (Session.append_all
               [
                 Event.queue_updated Session.Queue.Update.cleared;
                 Event.delegations_detached;
               ]
               root));
      test "a later branch treats the earlier detachment as history" (fun () ->
          let first_events, _ = finished_delegating_turn_events () in
          let first = saved first_events in
          let second =
            ok_or "first fork"
              (Session.fork ~id:(session_id "second") ~cwd ~created_at:(time 10)
                 first)
          in
          let later_events, _ =
            finished_delegating_turn_events ~id:"turn-2" ~call:"spawn-2"
              ~child:"child-2" ()
          in
          let second =
            ok_or "record later child" (Session.append_all later_events second)
          in
          let third =
            ok_or "second fork"
              (Session.fork ~id:(session_id "third") ~cwd ~created_at:(time 20)
                 second)
          in
          let detachments =
            List.fold_left
              (fun count -> function
                | Event.Delegations_detached -> count + 1 | _ -> count)
              0 (Session.events third)
          in
          equal int ~msg:"one historical and one current detachment" 2
            detachments;
          equal (list delegation_value) ~msg:"the new branch owns no children"
            []
            (State.delegations (Session.state third)));
      test "the reset suffix guards hold" (fun () ->
          let parent_events = finished_turn_events () in
          let parent = saved parent_events in
          let child =
            ok_or "fork"
              (Session.fork ~id:(session_id "child") ~cwd ~created_at:(time 10)
                 parent)
          in
          equal (list event_value)
            ~msg:"empty queue and no live children append nothing"
            parent_events (Session.events child));
      test "fork refuses active turns and deleted parents" (fun () ->
          let active = saved [ Event.turn_started (turn ()) ] in
          expect_session_error ~msg:"active turn"
            (Session.Error.Active_turn (turn_id "turn-1"))
            (Session.fork ~id:(session_id "child") ~cwd ~created_at:(time 10)
               active);
          let deleted = ok_or "delete" (Session.delete (saved [])) in
          expect_session_error ~msg:"deleted parent" Session.Error.Deleted
            (Session.fork ~id:(session_id "child") ~cwd ~created_at:(time 10)
               deleted);
          expect_invalid_arg "empty title" (fun () ->
              Session.fork ~id:(session_id "child") ~title:"" ~cwd
                ~created_at:(time 10) (saved [])));
      test "rewind at the last boundary is exactly fork" (fun () ->
          let parent = saved (finished_turn_events ()) in
          let forked =
            ok_or "fork"
              (Session.fork ~id:(session_id "child-a") ~cwd
                 ~created_at:(time 10) parent)
          in
          let rewound =
            ok_or "rewind"
              (Session.rewind ~id:(session_id "child-b") ~cwd
                 ~created_at:(time 10)
                 (Session.Anchor.after_turn (turn_id "turn-1"))
                 parent)
          in
          equal (list event_value) ~msg:"same events" (Session.events forked)
            (Session.events rewound));
      test "rewind before a turn drops it and everything later" (fun () ->
          let events =
            finished_turn_events () @ finished_turn_events ~id:"turn-2" ()
          in
          let parent = saved events in
          equal (result int session_error) ~msg:"before turn-2 cuts at index 4"
            (Ok 4)
            (Session.resolve_anchor
               (Session.Anchor.before_turn (turn_id "turn-2"))
               parent);
          equal
            (result (list turn_id_value) session_error)
            ~msg:"dropped turns are the suffix"
            (Ok [ turn_id "turn-2" ])
            (Session.dropped_turns
               (Session.Anchor.before_turn (turn_id "turn-2"))
               parent);
          let child =
            ok_or "rewind"
              (Session.rewind ~id:(session_id "child") ~cwd
                 ~created_at:(time 10)
                 (Session.Anchor.before_turn (turn_id "turn-2"))
                 parent)
          in
          equal (list turn_id_value) ~msg:"only the first turn survives"
            [ turn_id "turn-1" ]
            (List.map Session.Turn.id (State.turns (Session.state child)));
          equal
            (result (list turn_id_value) session_error)
            ~msg:"before the first turn drops both"
            (Ok [ turn_id "turn-1"; turn_id "turn-2" ])
            (Session.dropped_turns
               (Session.Anchor.before_turn (turn_id "turn-1"))
               parent));
      test "anchors fail loudly" (fun () ->
          let parent = saved (finished_turn_events ()) in
          expect_session_error ~msg:"unknown turn"
            (Session.Error.Unknown_turn (turn_id "turn-ghost"))
            (Session.resolve_anchor
               (Session.Anchor.before_turn (turn_id "turn-ghost"))
               parent);
          let active =
            saved ~id:"session-active" [ Event.turn_started (turn ()) ]
          in
          expect_session_error ~msg:"after an unfinished turn"
            (Session.Error.Turn_not_finished (turn_id "turn-1"))
            (Session.resolve_anchor
               (Session.Anchor.after_turn (turn_id "turn-1"))
               active));
    ]

(* Metrics. *)

let metrics_group =
  group "metrics"
    [
      test "the canonical journal folds to the expected metrics" (fun () ->
          let m = Session.metrics (saved (journal ()).events) in
          equal usage_value ~msg:"usage sums responses and the summarizer"
            (usage ~input:382 ~output:116)
            m.Session.Metrics.usage;
          equal int ~msg:"responses" 4 m.Session.Metrics.responses;
          equal int ~msg:"turns" 3 m.Session.Metrics.turns;
          equal int ~msg:"returned tool calls" 3 m.Session.Metrics.tool_calls;
          equal int ~msg:"tool failures" 1 m.Session.Metrics.tool_failures;
          equal int ~msg:"claimless error results are rejections" 1
            m.Session.Metrics.tool_rejections;
          equal
            (list (pair string int))
            ~msg:"per-name counts sorted"
            [ ("probe", 1); ("read_file", 1); ("stager", 1) ]
            m.Session.Metrics.tool_calls_by_name;
          equal int ~msg:"permission denials" 1
            m.Session.Metrics.permission_denials);
      test "interrupted spend folds into usage without counting a response"
        (fun () ->
          let t = turn () in
          let t_id = Session.Turn.id t in
          let c = claim t_id in
          let events =
            [
              Event.turn_started t;
              Event.provider_requested c;
              Event.interrupt_requested ~turn:t_id ();
              settle_interrupted ~usage:(usage ~input:120 ~output:8) c
                "Stopping.";
              finish
                ~outcome:(Session.Turn.Outcome.interrupted ~cancelled:true ())
                t;
            ]
          in
          let m = Session.metrics (saved events) in
          equal usage_value ~msg:"usage counts the retained snapshot"
            (usage ~input:120 ~output:8)
            m.Session.Metrics.usage;
          equal int ~msg:"no response is counted" 0 m.Session.Metrics.responses);
      test "metrics jsont round-trips and rejects invalid shapes" (fun () ->
          let m = Session.metrics (saved (journal ()).events) in
          let json = encode Session.Metrics.jsont m in
          equal metrics_value ~msg:"metrics round-trip" m
            (decode Session.Metrics.jsont json);
          assert_decode_error "negative counter" Session.Metrics.jsont
            (set_member "responses" (Json.int (-1)) json);
          assert_decode_error "failures exceed calls" Session.Metrics.jsont
            (set_member "tool_failures" (Json.int 99) json);
          assert_decode_error "unsorted names" Session.Metrics.jsont
            (set_member "tool_calls_by_name"
               (Json.list
                  [
                    json_object
                      [ ("name", Json.string "zeta"); ("count", Json.int 1) ];
                    json_object
                      [ ("name", Json.string "alpha"); ("count", Json.int 1) ];
                  ])
               json);
          assert_decode_error "unknown member" Session.Metrics.jsont
            (add_member "spend" (Json.int 3) json));
    ]

(* Listing and detail projections. *)

let user_turn ?(id = "turn-1") text =
  turn ~id ~input:(Session.Turn.Input.user_text text) ()

(* A finished single-turn journal: user prompt, one provider response, terminal
   outcome — an idle session with a first-prompt preview. *)
let finished_events ?(id = "turn-1") text =
  let t = user_turn ~id text in
  let c = claim (Session.Turn.id t) in
  [ Event.turn_started t; Event.provider_requested c; respond c "ok"; finish t ]

let summary_session ?(id = "sum-1") ?title
    ?(status = Session.Metadata.Status.Active) ?forked_from ?delegated_from
    ?(created = 10) ?(updated = 20) events =
  let metadata =
    Session.Metadata.make ?title ~status ?forked_from ?delegated_from ~cwd
      ~created_at:(time created) ~updated_at:(time updated) ()
  in
  ok_or "summary session" (Session.make ~id:(session_id id) ~metadata ~events)

let summary_group =
  group "summary projection"
    [
      test "of_session derives the list row from metadata and state" (fun () ->
          let session =
            summary_session ~id:"sum-idle" ~title:"My Session" ~created:10
              ~updated:99
              (finished_events "First prompt here")
          in
          let s = Session.Summary.of_session session in
          is_true ~msg:"id"
            (Session.Id.equal (session_id "sum-idle") (Session.Summary.id s));
          is_true ~msg:"title"
            (Option.equal String.equal (Some "My Session")
               (Session.Summary.title s));
          is_true ~msg:"preview is the first user prompt"
            (Option.equal String.equal (Some "First prompt here")
               (Session.Summary.preview s));
          is_true ~msg:"lifecycle active"
            (Session.Metadata.Status.equal Session.Metadata.Status.Active
               (Session.Summary.lifecycle s));
          is_true ~msg:"idle after finish"
            (Session.Summary.Phase.equal Session.Summary.Phase.Idle
               (Session.Summary.phase s));
          is_true ~msg:"one turn" (Int.equal 1 (Session.Summary.turns s));
          is_true ~msg:"cwd" (Lpath.Abs.equal cwd (Session.Summary.cwd s));
          is_true ~msg:"updated_at carried"
            (Session.Time.equal (time 99) (Session.Summary.updated_at s)));
      test "phase is working mid-turn and waiting under a suspension" (fun () ->
          let t = user_turn "Prompt" in
          let c = claim (Session.Turn.id t) in
          let working =
            summary_session ~id:"work"
              [
                Event.turn_started t; Event.provider_requested c; respond c "hi";
              ]
          in
          is_true ~msg:"active turn, no suspension => working"
            (Session.Summary.Phase.equal Session.Summary.Phase.Working
               (Session.Summary.phase (Session.Summary.of_session working)));
          let waiting =
            summary_session ~id:"wait"
              [ Event.turn_started t; Event.provider_requested c ]
          in
          is_true ~msg:"open provider claim => waiting"
            (Session.Summary.Phase.equal Session.Summary.Phase.Waiting
               (Session.Summary.phase (Session.Summary.of_session waiting))));
      test "compare_recency orders newest first with id tie-break" (fun () ->
          let s id updated =
            Session.Summary.of_session
              (summary_session ~id ~updated (finished_events id))
          in
          let a = s "a" 100 and b = s "b" 200 and c = s "c" 100 in
          is_true ~msg:"newer updated_at sorts first"
            (Session.Summary.compare_recency b a < 0);
          is_true ~msg:"equal times break by id"
            (Session.Summary.compare_recency a c < 0));
      test "matches is a case-insensitive substring over id/title/preview/cwd"
        (fun () ->
          let s =
            Session.Summary.of_session
              (summary_session ~id:"needle-1" ~title:"Alpha Project"
                 (finished_events "Refactor the parser"))
          in
          is_true ~msg:"id" (Session.Summary.matches ~query:"NEEDLE" s);
          is_true ~msg:"title" (Session.Summary.matches ~query:"alpha" s);
          is_true ~msg:"preview" (Session.Summary.matches ~query:"parser" s);
          is_true ~msg:"cwd" (Session.Summary.matches ~query:"workspace" s);
          is_false ~msg:"absent" (Session.Summary.matches ~query:"zzz" s));
      test "display_title falls back to the id when untitled" (fun () ->
          let s =
            Session.Summary.of_session
              (summary_session ~id:"untitled" (finished_events "x"))
          in
          is_true ~msg:"id fallback"
            (String.equal "untitled" (Session.Summary.display_title s)));
      test "jsont round-trips and rejects unknown members" (fun () ->
          let s =
            Session.Summary.of_session
              (summary_session ~id:"rt" ~title:"T"
                 (finished_events "hello world"))
          in
          let json = encode Session.Summary.jsont s in
          is_true ~msg:"round-trips"
            (Session.Summary.equal s (decode Session.Summary.jsont json));
          assert_decode_error "unknown member" Session.Summary.jsont
            (add_member "extra" (Json.int 1) json));
      test "delegation lineage survives projection and JSON transport"
        (fun () ->
          let delegated_from =
            Session.Metadata.Delegated_from.make ~parent:(session_id "parent")
              ~delegation:(Session.Delegation.Id.of_string "delegation-1")
          in
          let summary =
            Session.Summary.of_session
              (summary_session ~id:"child" ~delegated_from
                 (finished_events "Inspect the parser"))
          in
          is_true ~msg:"projection retains exact delegation lineage"
            (Option.equal Session.Metadata.Delegated_from.equal
               (Some delegated_from)
               (Session.Summary.delegated_from summary));
          let decoded =
            summary
            |> encode Session.Summary.jsont
            |> decode Session.Summary.jsont
          in
          is_true ~msg:"summary JSON retains delegation lineage"
            (Session.Summary.equal summary decoded));
    ]

let listing_ids ~cwd listing summaries =
  Session.Listing.select ~cwd listing summaries
  |> List.map (fun summary -> Session.Id.to_string (Session.Summary.id summary))

let listing_group =
  group "listing selection"
    [
      test "search is applied before its row limit" (fun () ->
          let summaries =
            [
              Session.Summary.of_session (saved ~id:"a-nonmatch" []);
              Session.Summary.of_session (saved ~id:"z-needle" []);
            ]
          in
          let listing : Session.Listing.t =
            {
              Session.Listing.scope = `Cwd;
              lifecycles = [ Session.Metadata.Status.Active ];
              search = Some "needle";
              limit = Some 1;
            }
          in
          is_true ~msg:"the later matching row survives the cap"
            (List.equal String.equal [ "z-needle" ]
               (listing_ids ~cwd listing summaries)));
      test "a zero limit selects no rows" (fun () ->
          let summaries =
            [ Session.Summary.of_session (saved ~id:"selected" []) ]
          in
          let listing : Session.Listing.t =
            {
              Session.Listing.scope = `Cwd;
              lifecycles = [ Session.Metadata.Status.Active ];
              search = None;
              limit = Some 0;
            }
          in
          is_true ~msg:"Some 0 is an exact empty cap"
            (List.equal String.equal [] (listing_ids ~cwd listing summaries)));
      test "a negative limit selects no rows" (fun () ->
          let summaries =
            [ Session.Summary.of_session (saved ~id:"selected" []) ]
          in
          let listing : Session.Listing.t =
            {
              Session.Listing.scope = `Cwd;
              lifecycles = [ Session.Metadata.Status.Active ];
              search = None;
              limit = Some (-1);
            }
          in
          is_true ~msg:"a negative cap selects nothing"
            (List.equal String.equal [] (listing_ids ~cwd listing summaries)));
      test "a delegated child is excluded from a listing" (fun () ->
          let delegated_from =
            Session.Metadata.Delegated_from.make ~parent:(session_id "parent")
              ~delegation:(Session.Delegation.Id.of_string "delegation-1")
          in
          let child_metadata =
            Session.Metadata.make ~cwd ~created_at:(time 1) ~updated_at:(time 2)
              ~delegated_from ()
          in
          let child =
            ok_or "child replay"
              (Session.make ~id:(session_id "sub-child")
                 ~metadata:child_metadata ~events:[])
          in
          let summaries =
            [
              Session.Summary.of_session (saved ~id:"real" []);
              Session.Summary.of_session child;
            ]
          in
          let listing : Session.Listing.t =
            {
              Session.Listing.scope = `Cwd;
              lifecycles = [ Session.Metadata.Status.Active ];
              search = None;
              limit = None;
            }
          in
          is_true
            ~msg:"the delegated child is absent; only the conversation lists"
            (List.equal String.equal [ "real" ]
               (listing_ids ~cwd listing summaries)));
      test "cwd scope keeps the summaries sharing the host workspace-root key"
        (fun () ->
          (* Scope is now a workspace-root key comparison, not path text. For
             normal absolute paths [Root.of_dir] is injective, so key equality
             agrees with the former [Abs.equal cwd (Summary.cwd s)] exactly. *)
          let under dir id =
            let metadata =
              Session.Metadata.make
                ~cwd:(Lpath.Abs.of_string_exn dir)
                ~created_at:(time 1) ~updated_at:(time 2) ()
            in
            Session.Summary.of_session
              (ok_or "scope session"
                 (Session.make ~id:(session_id id) ~metadata ~events:[]))
          in
          let summaries =
            [ under "/workspace" "here"; under "/other" "away" ]
          in
          let cwd_listing : Session.Listing.t =
            {
              Session.Listing.scope = `Cwd;
              lifecycles = [ Session.Metadata.Status.Active ];
              search = None;
              limit = None;
            }
          in
          is_true ~msg:"only the host-workspace session survives the cwd scope"
            (List.equal String.equal [ "here" ]
               (listing_ids
                  ~cwd:(Lpath.Abs.of_string_exn "/workspace")
                  cwd_listing summaries));
          is_true ~msg:"scoping to the other root selects only its session"
            (List.equal String.equal [ "away" ]
               (listing_ids
                  ~cwd:(Lpath.Abs.of_string_exn "/other")
                  cwd_listing summaries));
          let all_listing = { cwd_listing with Session.Listing.scope = `All } in
          is_true ~msg:"the all scope keeps both regardless of root key"
            (Int.equal 2
               (List.length
                  (listing_ids
                     ~cwd:(Lpath.Abs.of_string_exn "/workspace")
                     all_listing summaries))));
    ]

let view_group =
  group "session view projection"
    [
      test "of_session carries the summary plus execution detail" (fun () ->
          let session =
            summary_session ~id:"view-1" ~title:"V" (finished_events "Prompt")
          in
          let v = Session.Session_view.of_session session in
          is_true ~msg:"summary embedded"
            (Session.Summary.equal
               (Session.Summary.of_session session)
               (Session.Session_view.summary v));
          is_true ~msg:"last outcome completed"
            (Option.equal Session.Turn.Outcome.equal
               (Some Session.Turn.Outcome.completed)
               (Session.Session_view.last_outcome v));
          is_true ~msg:"no open suspension => no waiting"
            (Option.is_none (Session.Session_view.waiting v));
          is_true ~msg:"workflow mode from the turn contract"
            (Option.is_some (Session.Session_view.workflow_mode v));
          is_true ~msg:"active model recorded"
            (Option.is_some (Session.Session_view.active_model v)));
      test "waiting projects the open suspension kind" (fun () ->
          let t = user_turn "Prompt" in
          let c = claim (Session.Turn.id t) in
          let v =
            Session.Session_view.of_session
              (summary_session ~id:"await"
                 [ Event.turn_started t; Event.provider_requested c ])
          in
          is_true ~msg:"awaiting provider"
            (Option.equal Session.Session_view.Waiting.equal
               (Some Session.Session_view.Waiting.Awaiting_provider)
               (Session.Session_view.waiting v)));
      test "jsont round-trips and pins the transport members" (fun () ->
          let events = finished_events "Prompt" in
          let v =
            Session.Session_view.of_session
              (summary_session ~id:"view-json" events)
          in
          let json = encode Session.Session_view.jsont v in
          let members, _ = members_of json in
          is_false ~msg:"the full compaction is absent from detail transport"
            (List.exists
               (fun ((name, _), _) -> String.equal name "latest_compaction")
               members);
          is_true ~msg:"view round-trips"
            (Session.Session_view.equal v
               (decode Session.Session_view.jsont json));
          assert_decode_error "old latest_compaction field is rejected"
            Session.Session_view.jsont
            (add_member "latest_compaction" (Json.null ()) json);
          assert_decode_error "unknown member" Session.Session_view.jsont
            (add_member "extra" (Json.int 1) json));
    ]

(* The document version is content-derived: a sealed contract carrying a
   structured-output tool ([structured_output_tool]) raises it to 2 so a
   pre-feature reader refuses at the gate rather than erroring on the unfamiliar
   member; a document with no such contract stays at version 1 and readable by
   that reader. *)
let document_version_of session =
  match
    Json.find_mem "version" (fst (members_of (encode Session.jsont session)))
  with
  | Some (_, value) -> value
  | None -> fail "encoded session has no version member"

let content_ref =
  Testable.make ~pp:Mentat_digest.Content_ref.pp
    ~equal:Mentat_digest.Content_ref.equal

let media_refs_group =
  group "media refs"
    [
      test "collects document media refs in order, deduplicated" (fun () ->
          let ref_a = Mentat_digest.Content_ref.of_contents "image-a" in
          let ref_b = Mentat_digest.Content_ref.of_contents "image-b" in
          let media r = Llm.Content.media ~media_type:"image/png" (`Ref r) in
          (* One turn references a then b then a again; the walk keeps document
             order and deduplicates. *)
          let input =
            Session.Turn.Input.user
              [ Llm.Content.text "a"; media ref_a; media ref_b; media ref_a ]
          in
          let session = saved [ Event.turn_started (turn ~input ()) ] in
          equal (list content_ref) ~msg:"document order, deduplicated"
            [ ref_a; ref_b ]
            (Session.media_refs session));
      test "a media-free document has no media refs" (fun () ->
          equal (list content_ref) ~msg:"none" []
            (Session.media_refs (saved [ Event.turn_started (turn ()) ])));
    ]

let notice_fixture =
  Session.Notice.make ~source:"dune" ~severity:Session.Notice.Severity.Error
    ~title:"Build failing (1 diagnostic)"
    ~body:"lib/a.ml:1:1-1:5: Error: Unbound value foo" ()

let notice_title s =
  Session.Notice.make ~source:"fswatch" ~severity:Session.Notice.Severity.Info
    ~title:s ()

let last_user_text st =
  match List.rev (messages_of (State.model_transcript st)) with
  | Llm.Message.User content :: _ ->
      String.concat "\n"
        (List.filter_map
           (function Llm.Content.Text text -> Some text | _ -> None)
           content)
  | _ -> ""

let workspace_notice_group =
  group "replay: workspace notices"
    [
      test "a pending notice rides the model view, not yet the journal view"
        (fun () ->
          expect_step_error ~msg:"a notice with no active turn is rejected"
            (State.Error.Turn State.Error.Turn.No_active) []
            (Event.workspace_notice notice_fixture);
          let st =
            state
              [
                Event.turn_started (turn ());
                Event.workspace_notice notice_fixture;
              ]
          in
          (* Not yet frozen: the durable transcript holds only the turn's
             input; the model view shows the pending batch as its tail. *)
          equal int ~msg:"the durable transcript is not yet touched" 1
            (List.length (messages_of (State.full_transcript st)));
          equal int ~msg:"the model view carries the pending entry" 2
            (List.length (messages_of (State.model_transcript st)));
          is_true ~msg:"the entry is the rendered notice"
            (String.includes ~affix:"Workspace notices:" (last_user_text st));
          is_true ~msg:"the body rides the entry"
            (String.includes ~affix:"Unbound value foo" (last_user_text st)));
      test "a provider request freezes the batch at its position" (fun () ->
          let t1 = turn ~id:"turn-1" () in
          let c = claim ~seed:"freeze-req" (Session.Turn.id t1) in
          let st =
            state
              [
                Event.turn_started t1;
                Event.workspace_notice (notice_title "first");
                Event.workspace_notice (notice_title "second");
                Event.provider_requested c;
              ]
          in
          (* One entry for the whole pending batch, now durable. *)
          equal int ~msg:"the batch is one frozen entry" 2
            (List.length (messages_of (State.full_transcript st)));
          is_true ~msg:"both notices share the entry"
            (String.includes ~affix:"first" (last_user_text st)
            && String.includes ~affix:"second" (last_user_text st)));
      test "a batch pins before younger conversational input" (fun () ->
          let t1 = turn ~id:"turn-1" () in
          let st =
            state
              [
                Event.turn_started t1;
                Event.workspace_notice (notice_title "orphaned");
                finish t1;
                Event.message_appended
                  (Llm.Message.user_text "hello afterwards");
              ]
          in
          (* The idle append flushes first: the observation precedes the
             input that arrived after it. *)
          match List.rev (messages_of (State.full_transcript st)) with
          | Llm.Message.User hello :: Llm.Message.User entry :: _ ->
              is_true ~msg:"input last"
                (List.exists
                   (function
                     | Llm.Content.Text text ->
                         String.includes ~affix:"hello afterwards" text
                     | _ -> false)
                   hello);
              is_true ~msg:"the entry precedes it"
                (List.exists
                   (function
                     | Llm.Content.Text text ->
                         String.includes ~affix:"orphaned" text
                     | _ -> false)
                   entry)
          | _ -> fail "expected the entry then the input at the tail");
      test "the frozen entry is the bytes the ride showed" (fun () ->
          let t1 = turn ~id:"turn-1" () in
          let c = claim ~seed:"bytes-req" (Session.Turn.id t1) in
          let before =
            state
              [
                Event.turn_started t1;
                Event.workspace_notice notice_fixture;
              ]
          in
          let ridden = last_user_text before in
          let frozen =
            state
              [
                Event.turn_started t1;
                Event.workspace_notice notice_fixture;
                Event.provider_requested c;
              ]
          in
          equal string ~msg:"same bytes, same tail position" ridden
            (last_user_text frozen);
          equal int ~msg:"the view did not grow at the freeze"
            (List.length (messages_of (State.model_transcript before)))
            (List.length (messages_of (State.model_transcript frozen))));
      test "an unstated notice survives its turn and states once" (fun () ->
          let t1 = turn ~id:"turn-1" () in
          let t2 = turn ~id:"turn-2" () in
          let c = claim ~seed:"carry-req" (Session.Turn.id t2) in
          let st =
            state
              [
                Event.turn_started t1;
                Event.workspace_notice (notice_title "orphaned");
                finish t1;
                Event.turn_started t2;
                Event.workspace_notice (notice_title "fresh");
                Event.provider_requested c;
              ]
          in
          (* The dying turn's observation pends into the next request — one
             entry, no duplicate fact, nothing lost. *)
          is_true ~msg:"the orphaned observation reaches the next request"
            (String.includes ~affix:"orphaned" (last_user_text st));
          is_true ~msg:"beside the fresh one, in one entry"
            (String.includes ~affix:"fresh" (last_user_text st)));
    ]

(* A complete finished user turn: user input, one response, terminal outcome. *)
let user_turn ~id ~text =
  let t = turn ~id ~input:(Session.Turn.Input.user_text text) () in
  let c = claim ~seed:(id ^ "-req") (Session.Turn.id t) in
  ( t,
    [
      Event.turn_started t;
      Event.provider_requested c;
      respond c (text ^ " done.");
      finish t;
    ] )

let undo_group =
  group "replay: undo"
    [
      test "arming excludes the anchor turn's suffix from the model view"
        (fun () ->
          let t1, e1 = user_turn ~id:"t1" ~text:"A" in
          let t2, e2 = user_turn ~id:"t2" ~text:"B" in
          let st = state (e1 @ e2) in
          equal int ~msg:"full has four messages" 4
            (List.length (messages_of (State.full_transcript st)));
          equal int ~msg:"model view has four before arming" 4
            (List.length (messages_of (State.model_transcript st)));
          equal (option turn_id_value) ~msg:"no boundary before arming" None
            (Option.map (fun u -> u.State.anchor) (State.undo st));
          let armed =
            state
              (e1 @ e2
              @ [
                  Event.undo_updated
                    (Session.Undo.Update.armed ~anchor:(Session.Turn.id t2) ());
                ])
          in
          equal (option turn_id_value) ~msg:"boundary anchored at t2"
            (Some (Session.Turn.id t2))
            (Option.map (fun u -> u.State.anchor) (State.undo armed));
          equal int ~msg:"model view drops t2's suffix" 2
            (List.length (messages_of (State.model_transcript armed)));
          ignore t1);
      test "arming at the first turn empties the model view" (fun () ->
          let t1, e1 = user_turn ~id:"t1" ~text:"A" in
          let armed =
            state
              (e1
              @ [
                  Event.undo_updated
                    (Session.Undo.Update.armed ~anchor:(Session.Turn.id t1) ());
                ])
          in
          equal int ~msg:"empty model view" 0
            (List.length (messages_of (State.model_transcript armed))));
      test "releasing clears the boundary and restores the model view"
        (fun () ->
          let t1, e1 = user_turn ~id:"t1" ~text:"A" in
          let t2, e2 = user_turn ~id:"t2" ~text:"B" in
          let released =
            state
              (e1 @ e2
              @ [
                  Event.undo_updated
                    (Session.Undo.Update.armed ~anchor:(Session.Turn.id t2) ());
                  Event.undo_updated Session.Undo.Update.released;
                ])
          in
          equal (option turn_id_value) ~msg:"boundary cleared" None
            (Option.map (fun u -> u.State.anchor) (State.undo released));
          equal int ~msg:"model view restored" 4
            (List.length (messages_of (State.model_transcript released)));
          ignore (t1, t2));
      test "the armed revert id round-trips through the fold" (fun () ->
          let t1, e1 = user_turn ~id:"t1" ~text:"A" in
          let t2, e2 = user_turn ~id:"t2" ~text:"B" in
          let armed =
            state
              (e1 @ e2
              @ [
                  Event.undo_updated
                    (Session.Undo.Update.armed ~anchor:(Session.Turn.id t2)
                       ~revert:"revert-abc" ());
                ])
          in
          equal
            (option (option string))
            ~msg:"revert id folded" (Some (Some "revert-abc"))
            (Option.map (fun u -> u.State.revert) (State.undo armed));
          ignore (t1, t2));
      test "arming refuses an unknown anchor" (fun () ->
          let _, e1 = user_turn ~id:"t1" ~text:"A" in
          expect_replay_error ~msg:"unknown anchor"
            (State.Error.Undo
               (State.Error.Undo.Unknown_anchor (turn_id "ghost")))
            (e1
            @ [
                Event.undo_updated
                  (Session.Undo.Update.armed ~anchor:(turn_id "ghost") ());
              ]));
      test "arming refuses a non-user anchor" (fun () ->
          let tc =
            turn ~id:"tc" ~origin:Session.Turn.Origin.Step_limit_wind_down
              ~input:Session.Turn.Input.continue ()
          in
          let c = claim ~seed:"tc-req" (Session.Turn.id tc) in
          let events =
            [
              Event.message_appended (Llm.Message.user_text "Earlier.");
              Event.turn_started tc;
              Event.provider_requested c;
              respond c "Continuing.";
              finish tc;
            ]
          in
          expect_replay_error ~msg:"non-user anchor"
            (State.Error.Undo
               (State.Error.Undo.Anchor_not_user (Session.Turn.id tc)))
            (events
            @ [
                Event.undo_updated
                  (Session.Undo.Update.armed ~anchor:(Session.Turn.id tc) ());
              ]));
      test "arming refuses while a turn is active" (fun () ->
          let t1 = turn ~id:"t1" ~input:(Session.Turn.Input.user_text "A") () in
          expect_replay_error ~msg:"active turn"
            (State.Error.Undo
               (State.Error.Undo.Active_turn (Session.Turn.id t1)))
            [
              Event.turn_started t1;
              Event.undo_updated
                (Session.Undo.Update.armed ~anchor:(Session.Turn.id t1) ());
            ]);
      test "an undo update round-trips through the codec" (fun () ->
          List.iter
            (fun update ->
              equal
                (Testable.make ~pp:Session.Undo.Update.pp
                   ~equal:Session.Undo.Update.equal)
                ~msg:"undo update round-trips" update
                (decode Session.Undo.Update.jsont
                   (encode Session.Undo.Update.jsont update)))
            [
              Session.Undo.Update.armed ~anchor:(turn_id "t2") ~revert:"r-1" ();
              Session.Undo.Update.armed ~anchor:(turn_id "t2") ();
              Session.Undo.Update.released;
            ]);
    ]

let document_version_group =
  group "document version gate"
    [
      test "a plain session encodes at version 1" (fun () ->
          let session = saved [ Event.turn_started (turn ()) ] in
          is_true ~msg:"version 1"
            (Json.equal (Json.number 1.) (document_version_of session)));
      test "a structured-output contract raises the document to version 2"
        (fun () ->
          let contract = make_contract ~output_tool:structured_output_tool () in
          let session = saved [ Event.turn_started (turn ~contract ()) ] in
          is_true ~msg:"version 2"
            (Json.equal (Json.number 2.) (document_version_of session)));
      test "media content raises the document to version 2" (fun () ->
          let reference = Mentat_digest.Content_ref.of_contents "image bytes" in
          let input =
            Session.Turn.Input.user
              [
                Llm.Content.text "look";
                Llm.Content.media ~media_type:"image/png" (`Ref reference);
              ]
          in
          let session = saved [ Event.turn_started (turn ~input ()) ] in
          is_true ~msg:"a media-bearing document is version 2"
            (Json.equal (Json.number 2.) (document_version_of session)));
      test "a workspace notice raises the document to version 3" (fun () ->
          let session =
            saved
              [
                Event.turn_started (turn ());
                Event.workspace_notice notice_fixture;
              ]
          in
          is_true ~msg:"a notice-bearing document is version 3"
            (Json.equal (Json.number 3.) (document_version_of session)));
      test "a guided permission deny raises the document to version 4"
        (fun () ->
          let call = tool_call () in
          let t, events = mid_turn [ call ] in
          let requested =
            permission_decision ~turn:(Session.Turn.id t) ~call
              (access "session.review")
          in
          let session =
            saved
              (events
              @ [
                  Event.decision_requested requested;
                  resolved ~msg:"guided deny" requested ~call
                    ~by:Session.Principal.local_user
                    (Session.Decision.Answer.Permission
                       { answer = deny; message = Some "add a test first" });
                ])
          in
          is_true ~msg:"a guided-deny document is version 4"
            (Json.equal (Json.number 4.) (document_version_of session)));
      test "a bare permission deny leaves the document at the base version"
        (fun () ->
          let call = tool_call () in
          let t, events = mid_turn [ call ] in
          let requested =
            permission_decision ~turn:(Session.Turn.id t) ~call
              (access "session.review")
          in
          let session =
            saved
              (events
              @ [
                  Event.decision_requested requested;
                  resolved ~msg:"bare deny" requested ~call
                    ~by:Session.Principal.local_user
                    (Session.Decision.Answer.Permission
                       { answer = deny; message = None });
                ])
          in
          is_true ~msg:"a bare-deny document stays at version 1"
            (Json.equal (Json.number 1.) (document_version_of session)));
      test "an undo event raises the document to version 5" (fun () ->
          let t = turn () in
          let session =
            saved
              [
                Event.turn_started t;
                finish t;
                Event.undo_updated
                  (Session.Undo.Update.armed ~anchor:(Session.Turn.id t) ());
              ]
          in
          is_true ~msg:"an undo-bearing document is version 5"
            (Json.equal (Json.number 5.) (document_version_of session)));
      test "a committed (undo-free) session stays at the lower version"
        (fun () ->
          (* A commit truncates the undo events away, so the surviving prefix is
             byte-identical to an old reader: it takes the lower version again. *)
          let t = turn () in
          let session = saved [ Event.turn_started t; finish t ] in
          is_true ~msg:"no undo event, version 1"
            (Json.equal (Json.number 1.) (document_version_of session)));
      test "all versions round-trip through the codec" (fun () ->
          let contract = make_contract ~output_tool:structured_output_tool () in
          let t = turn () in
          List.iter
            (fun session ->
              let json = encode Session.jsont session in
              is_true ~msg:"round-trip"
                (Json.equal json
                   (encode Session.jsont (decode Session.jsont json))))
            [
              saved [ Event.turn_started (turn ()) ];
              saved [ Event.turn_started (turn ~contract ()) ];
              saved
                [
                  Event.turn_started (turn ());
                  Event.workspace_notice notice_fixture;
                ];
              saved
                [
                  Event.turn_started t;
                  finish t;
                  Event.undo_updated
                    (Session.Undo.Update.armed ~anchor:(Session.Turn.id t)
                       ~revert:"r-1" ());
                ];
            ]);
    ]

let () =
  run "mentat.session"
    [
      ids_group;
      media_refs_group;
      contract_group;
      document_version_group;
      turn_group;
      event_codec_group;
      turn_replay_group;
      workspace_notice_group;
      plan_build_group;
      suspension_group;
      provider_group;
      tool_claim_group;
      staged_group;
      decision_group;
      grants_group;
      interrupt_group;
      bypass_group;
      compaction_group;
      board_group;
      queue_group;
      delegation_group;
      undo_group;
      replay_group;
      journal_machine_group;
      document_group;
      branch_group;
      metrics_group;
      summary_group;
      listing_group;
      view_group;
    ]
