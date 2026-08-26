(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_protocol], the pure protocol core.
   The suite pins the projection laws (determinism, suffix
   consistency, live/replay byte-identity over a realistic multi-turn
   journal), the mutation-evidence prefix law (a settled claim's
   evidence is the answer at its ledger prefix, not the full-state one), fact
   completeness against the session event vocabulary, the wire codecs for
   Update, Fact, Progress, Command, and Error with their strict rejections
   (unknown tag, unknown member, cross-arm member, the [v] envelope), and
   constructor/decode validation parity for the ten command verbs.

   Everything is tested through the [Mentat_protocol] facade. Journals
   are built the way the session suite builds them; mutation ledgers are
   forged through the durable [Mentat_mutation.Event.jsont] codec with
   pinned, correctly derived change ids — exactly the shape the store persists.
   *)

open Windtrap
open Test_support
module Protocol = Mentat_protocol
module Session = Mentat_session
module Mutation = Mentat_mutation
module Edit = Mentat_edit
module Event = Session.Event
module Llm = Mentat_llm
module Tool = Mentat_tool
module Permission = Mentat_permission
module Sandbox = Mentat_sandbox
module Workspace = Mentat_workspace
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

let json_value = Testable.make ~pp:pp_json ~equal:Json.equal

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

let remove_member name json =
  let members, meta = members_of json in
  Jsont.Object
    (List.filter (fun ((n, _), _) -> not (String.equal n name)) members, meta)

let get_member name json =
  let members, _ = members_of json in
  match List.find_opt (fun ((n, _), _) -> String.equal n name) members with
  | Some (_, value) -> value
  | None -> failf "missing %S member" name

let member_string name json =
  match get_member name json with
  | Jsont.String (s, _) -> s
  | _ -> failf "member %S is not a string" name

let encode_bytes codec value =
  match Jsont_bytesrw.encode_string codec value with
  | Ok bytes -> bytes
  | Error message -> failf "byte encode failed: %s" message

let rec drop n l =
  if n <= 0 then l else match l with [] -> [] | _ :: t -> drop (n - 1) t

let take n l = List.filteri (fun i _ -> i < n) l

(* LLM fixtures. *)

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider ~api ~id:"gpt-5"
let cwd = Lpath.Abs.of_string_exn "/workspace"
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)
let digest seed = Mentat_digest.string seed
let usage ~input ~output = Llm.Usage.make ~input ~output ()

let tool_call ?(id = "call-1") ?(name = "read_file") ?(input = Json.object' [])
    () =
  Llm.Tool.Call.make ~id ~name ~input ()

let assistant_calls calls =
  Llm.Message.Assistant.make (List.map Llm.Message.Assistant.tool_call calls)

let declaration name =
  Llm.Tool.make ~name ~input_schema:Llm.Tool.no_input_schema ()

(* Permission fixtures. *)

let access ?subject name = Permission.Access.custom ?subject name

let request_for subject =
  Permission.Request.of_accesses [ access ~subject "session.test" ]

let review ?(reason = Permission.Policy.Review.Unmatched) acc =
  let request = Permission.Request.of_accesses [ acc ] in
  ok_or "review reconstruction"
    (Permission.Policy.Review.restore request [ (acc, reason) ])

let allow_once = Permission.Answer.once
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
let turn_id id = Session.Turn.Id.of_string id
let queue_id id = Session.Queue.Id.of_string id
let session_id id = Session.Id.of_string id

let make_contract ?(mode = Session.Contract.Mode.Build) ?(model = model)
    ?options ?(declarations = []) ?(policy = Permission.Policy.default)
    ?(review = Permission.Review_behavior.Enforce) ?(sandbox = sandbox_identity)
    () =
  Session.Contract.make ~mode ~model ?options ~declarations ~policy ~review
    ~sandbox ()

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

let settle_interrupted claim text =
  Event.provider_settled
    (Session.Provider_request.Settled.interrupted ~id:(claim_id claim) ~text ())

let settle_ambiguous claim =
  Event.provider_settled
    (Session.Provider_request.Settled.ambiguous ~id:(claim_id claim))

let provider_failure ?(kind = Llm.Error.Auth) message =
  Llm.Error.make ~kind ~provider message

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

let saved_metadata =
  Session.Metadata.make ~cwd ~created_at:(time 1) ~updated_at:(time 2) ()

let saved ?(id = "session-1") events =
  match Session.make ~id:(session_id id) ~metadata:saved_metadata ~events with
  | Ok session -> session
  | Error error -> failf "session replay failed: %a" Session.Error.pp error

(* Mutation fixtures. *)

let root_key = Workspace.Root.Key.of_string_exn "ws"
let wpath rel = Workspace.Path.make ~root_key (Lpath.Rel.of_string_exn rel)

(* A change id is derived internally from its claim, ordinal, and path — never
   accepted from callers — so the fixture must mint the same value the library
   does, or a workspace-identity change silently invalidates a hardcoded digest.
   [derived_change_id] runs the authoritative derivation ({!Edit.apply} then
   {!Mutation.Event.of_edit}, the path the mutation suite uses) over the fixture's
   own [root_key], keeping the ledger's change ids correct by construction. The
   id depends only on the coordinates, not the transition, so a dummy create over
   [path] suffices regardless of the fixture change's real before/after images. *)
let workspace =
  Workspace.single
    (Workspace.Root.make ~key:root_key (Lpath.Abs.of_string_exn "/workspace"))

let pure_io =
  {
    Edit.Apply.with_write_lock = (fun _paths f -> f ());
    revalidate = (fun path -> Ok path);
    read = (fun _path -> Ok Edit.Observed.Missing);
    commit = (fun ~path:_ ~before:_ ~after:_ -> Ok ());
  }

let derived_change_id ~claim ~ordinal ~path =
  let plan =
    match Edit.create ~path ~contents:"placeholder\n" with
    | Ok plan -> plan
    | Error error -> failf "derive: edit plan failed: %a" Edit.Error.pp error
  in
  let result =
    match Edit.apply ~io:pure_io ~workspace plan with
    | Ok result -> result
    | Error error -> failf "derive: apply failed: %a" Edit.Apply_error.pp error
  in
  match
    Mutation.Event.of_edit
      ~turn:(Session.Turn.Id.of_string "derive-turn")
      ~claim ~ordinal ~checkpoint:None result
  with
  | Mutation.Event.Edit { changes = [ change ]; _ } ->
      Mutation.Change.Id.to_string (Mutation.Change.id change)
  | _ -> fail "derive: expected exactly one lowered change"

let text_image contents =
  Mutation.Image.Text (Mentat_digest.Content_ref.of_contents contents)

(* These ids pin the durable fixture bytes after the public derivation oracle
   was removed. Event decode re-derives and verifies every value. *)
let change ~id ~path ~before ~after ~additions ~deletions =
  decode Mutation.Change.jsont
    (json_object
       [
         ("id", Json.string id);
         ("path", encode Workspace.Path.jsont path);
         ("before", encode Mutation.Image.jsont before);
         ("after", encode Mutation.Image.jsont after);
         ("additions", Json.int additions);
         ("deletions", Json.int deletions);
       ])

let edit_event ~turn ~claim changes =
  decode Mutation.Event.jsont
    (json_object
       [
         ("type", Json.string "edit");
         ("turn", encode Session.Turn.Id.jsont turn);
         ("claim", encode Session.Tool_claim.Id.jsont claim);
         ("ordinal", Json.int 0);
         ( "changes",
           json_array (List.map (encode Mutation.Change.jsont) changes) );
       ])

let mutation_state events =
  match Mutation.State.of_events events with
  | Ok state -> state
  | Error error ->
      failf "mutation replay failed: %s" (Mutation.State.Error.message error)

(* Testables. *)

let position_value =
  Testable.make ~pp:Protocol.Position.pp ~equal:Protocol.Position.equal

let fact_value = Testable.make ~pp:Protocol.Fact.pp ~equal:Protocol.Fact.equal
let projected_value = pair position_value fact_value

let update_value =
  Testable.make ~pp:Protocol.Update.pp ~equal:Protocol.Update.equal

let progress_value =
  Testable.make ~pp:Protocol.Progress.pp ~equal:Protocol.Progress.equal

let command_value =
  Testable.make ~pp:Protocol.Command.pp ~equal:(fun a b ->
      Json.equal
        (encode Protocol.Command.jsont a)
        (encode Protocol.Command.jsont b))

let error_value =
  Testable.make ~pp:Protocol.Error.pp ~equal:(fun a b ->
      Json.equal (encode Protocol.Error.jsont a) (encode Protocol.Error.jsont b))

let stats_value =
  let pp ppf (s : Textdiff.stats) =
    Format.fprintf ppf "{files=%d; additions=%d; deletions=%d}" s.Textdiff.files
      s.Textdiff.additions s.Textdiff.deletions
  in
  Testable.make ~pp ~equal:Textdiff.Stats.equal

let paths_value =
  list (Testable.make ~pp:Workspace.Path.pp ~equal:Workspace.Path.equal)

let revertability_value =
  Testable.make ~pp:Mutation.Revertability.pp
    ~equal:Mutation.Revertability.equal

let change_value =
  Testable.make ~pp:Mutation.Change.pp ~equal:Mutation.Change.equal

(* The canonical journey. *)

(* A realistic five-turn journal joined with a mutation ledger, exercising
   every fact family and every non-projecting event: a user turn with a
   no-change read, a two-file write, an ambiguous claim that recorded
   changes, an unattended denial, the staged pair, a rejection append, and
   queue/board/delegation facts; a triggered turn with a mid-turn
   compaction; a queued turn that is interrupted; a
   turn whose provider call fails; and a turn whose provider call settles
   ambiguously at recovery. Each step pairs a session event with the
   mutation events durable before it commits (ordering), so the suite can
   replay live emission exactly. *)

type journey = {
  steps : (Mutation.Event.t list * Event.t) list;
  amb_claim : Session.Tool_claim.Started.t;
  failed_provider_claim : Session.Provider_request.Started.t;
  failed_provider_error : Llm.Error.t;
  prepared : Tool.Prepared.t;
  a1 : Mutation.Change.t;
  b1 : Mutation.Change.t;
  amb1 : Mutation.Change.t;
  s1 : Mutation.Change.t;
}

let a_v1 = "let a = 1\nlet b = 2\nlet c = 3\n"
let a_v2 = "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4\n"
let a_v3 = "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4\nlet e = 5\n"

let journey () =
  let declarations =
    [
      declaration "read_file";
      declaration "write_file";
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
  let c_read = tool_call ~id:"call-read" ~name:"read_file" () in
  let c_write = tool_call ~id:"call-write" ~name:"write_file" () in
  let c_amb = tool_call ~id:"call-amb" ~name:"write_file" () in
  let c_staged =
    tool_call ~id:"call-staged" ~name:"stager" ~input:(input_json "alpha") ()
  in
  let c_free = tool_call ~id:"call-free" ~name:"free_form" () in
  let c_risky = tool_call ~id:"call-risky" ~name:"risky" () in
  let p1 = claim ~seed:"t1-req-1" t1_id in
  let read_claim = tool_claim ~turn:t1_id c_read in
  let write_claim = tool_claim ~turn:t1_id c_write in
  let amb_claim = tool_claim ~turn:t1_id c_amb in
  let d_risky =
    permission_decision ~turn:t1_id ~call:c_risky
      (access ~subject:"risky" "session.review")
  in
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
  let path_a = wpath "src/a.ml" in
  let path_b = wpath "src/b.ml" in
  let write_id = tool_claim_id write_claim in
  let amb_id = tool_claim_id amb_claim in
  let run_id = tool_claim_id staged_run in
  (* Ordinal 0 matches [edit_event]'s per-event ordinal; within one event paths
     are unique, so the claim and path fully determine each change id. *)
  let a1 =
    change
      ~id:(derived_change_id ~claim:write_id ~ordinal:0 ~path:path_a)
      ~path:path_a ~before:Mutation.Image.Missing ~after:(text_image a_v1)
      ~additions:3 ~deletions:0
  in
  let b1 =
    change
      ~id:(derived_change_id ~claim:write_id ~ordinal:0 ~path:path_b)
      ~path:path_b
      ~before:(text_image "let old = 0\n")
      ~after:(text_image "let fresh = 0\n")
      ~additions:1 ~deletions:1
  in
  let amb1 =
    change
      ~id:(derived_change_id ~claim:amb_id ~ordinal:0 ~path:path_a)
      ~path:path_a ~before:(text_image a_v1) ~after:(text_image a_v2)
      ~additions:2 ~deletions:1
  in
  let s1 =
    change
      ~id:(derived_change_id ~claim:run_id ~ordinal:0 ~path:path_a)
      ~path:path_a ~before:(text_image a_v2) ~after:(text_image a_v3)
      ~additions:1 ~deletions:0
  in
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
      ~source_call:"call-read"
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
  let t4 =
    turn ~id:"turn-4"
      ~input:(Session.Turn.Input.user_text "Retry the port.")
      ~contract:(make_contract ~declarations ())
      ()
  in
  let p7 = claim ~seed:"t4-req-1" (Session.Turn.id t4) in
  let failed_provider_error = provider_failure "authentication rejected" in
  let t5 =
    turn ~id:"turn-5"
      ~input:(Session.Turn.Input.user_text "Once more.")
      ~contract:(make_contract ~declarations ())
      ()
  in
  let p8 = claim ~seed:"t5-req-1" (Session.Turn.id t5) in
  let steps =
    [
      (* Turn 1. *)
      ([], Event.turn_started t1);
      ([], Event.provider_requested p1);
      ( [],
        settle_responded
          ~usage:(usage ~input:12 ~output:7)
          p1
          (assistant_calls
             [ c_read; c_write; c_amb; c_staged; c_free; c_risky ]) );
      ([], Event.tool_claimed read_claim);
      ([], settled_returned read_claim (completed "contents"));
      ([], Event.tool_claimed write_claim);
      ( [ edit_event ~turn:t1_id ~claim:write_id [ a1; b1 ] ],
        settled_returned write_claim (completed "wrote 2 files") );
      ([], Event.tool_claimed amb_claim);
      ( [ edit_event ~turn:t1_id ~claim:amb_id [ amb1 ] ],
        settled_ambiguous amb_claim );
      ( [],
        Event.message_appended
          (Llm.Message.tool_result
             (Llm.Tool.Result.text ~error:true c_free "not handled")) );
      ([], Event.decision_requested d_risky);
      ( [],
        resolved ~msg:"risky deny" d_risky ~call:c_risky
          ~by:Session.Principal.unattended_policy
          (Session.Decision.Answer.Permission { answer = deny; message = None })
      );
      ([], Event.tool_claimed staged_prepare);
      ([], settled_prepared staged_prepare prepared);
      ([], Event.decision_requested d_run);
      ( [],
        resolved ~msg:"run allow" d_run ~call:c_staged
          ~by:Session.Principal.local_user
          (Session.Decision.Answer.Permission
             { answer = allow_once; message = None }) );
      ([], Event.tool_claimed staged_run);
      ( [ edit_event ~turn:t1_id ~claim:run_id [ s1 ] ],
        settled_returned staged_run (completed "write alpha 5 times") );
      ( [],
        Event.queue_updated
          (Session.Queue.Update.enqueued (queue_entry ~id:"q-1" "Follow up."))
      );
      ([], Event.tasks_replaced journal_board);
      ([], Event.delegation_recorded edge);
      ([], Event.provider_requested p2);
      ([], respond ~usage:(usage ~input:30 ~output:9) p2 "All done.");
      ([], finish t1);
      (* Turn 2: triggered admission with a mid-turn compaction. *)
      ([], Event.turn_started t2);
      ([], Event.provider_requested p3);
      ([], respond ~usage:(usage ~input:100 ~output:50) p3 "Working on it.");
      ([], Event.provider_requested p4);
      ([], Event.compaction_installed compaction);
      ([], Event.provider_requested p5);
      ([], respond ~usage:(usage ~input:40 ~output:10) p5 "Task advanced.");
      ([], finish t2);
      (* Turn 3: queued admission, then an interrupt. *)
      ([], Event.turn_started t3);
      ([], Event.provider_requested p6);
      ([], Event.interrupt_requested ~turn:t3_id ~reason:"user stop" ());
      ([], settle_interrupted p6 "Stopping here.");
      ( [],
        finish
          ~outcome:
            (Session.Turn.Outcome.interrupted ~reason:"user stop"
               ~cancelled:true ())
          t3 );
      (* Turn 4: a proven provider failure fails the turn. *)
      ([], Event.turn_started t4);
      ([], Event.provider_requested p7);
      ( [],
        Event.provider_settled
          (Session.Provider_request.Settled.failed ~id:(claim_id p7)
             failed_provider_error) );
      ( [],
        finish
          ~outcome:
            (Session.Turn.Outcome.failed ~message:"authentication rejected")
          t4 );
      (* Turn 5: an ambiguous provider settlement forces an interrupt. *)
      ([], Event.turn_started t5);
      ([], Event.provider_requested p8);
      ([], settle_ambiguous p8);
      ( [],
        finish
          ~outcome:(Session.Turn.Outcome.interrupted ~cancelled:false ())
          t5 );
    ]
  in
  {
    steps;
    amb_claim;
    failed_provider_claim = p7;
    failed_provider_error;
    prepared;
    a1;
    b1;
    amb1;
    s1;
  }

let session_events j = List.map snd j.steps
let mutation_events j = List.concat_map fst j.steps
let full_session j = saved (session_events j)
let full_mutation j = mutation_state (mutation_events j)

(* [project ~since] threads the two projector entry points: [None] is the whole
   feed, [Some p] the validated suffix after [p]. A membership failure here is a
   fixture bug, so the helper raises; the adversarial cases below call
   {!Protocol.Projection.after} directly to inspect the structured failure. *)
let project ~since ~session ~mutation =
  match since with
  | None -> Protocol.Projection.all ~session ~mutation
  | Some position -> (
      match Protocol.Projection.after position ~session ~mutation with
      | Ok facts -> facts
      | Error invalid ->
          failf "unexpected invalid position: %s"
            (Protocol.Position.Invalid.message invalid))

let project_all j =
  project ~since:None ~session:(full_session j) ~mutation:(full_mutation j)

let fact_tag fact = member_string "type" (encode Protocol.Fact.jsont fact)

(* The projection of the canonical journey, arm by arm — the fact-completeness
   pin: every projectable event maps to exactly one fact. The eight provider
   claims, interrupt request, and ambiguous provider settlement project to
   nothing; the known failed settlement preserves its structured error. *)
let expected_tags =
  [
    (* turn 1 *)
    "turn.started";
    "turn.assistant";
    "tool.started";
    "tool.returned";
    "tool.started";
    "tool.returned";
    "tool.started";
    "tool.ambiguous";
    "turn.message";
    "decision.requested";
    "decision.resolved";
    "tool.started";
    "tool.prepared";
    "decision.requested";
    "decision.resolved";
    "tool.started";
    "tool.returned";
    "journal.queue";
    "journal.tasks";
    "journal.delegation";
    "turn.assistant";
    "turn.finished";
    (* turn 2 *)
    "turn.started";
    "turn.assistant";
    "compaction.installed";
    "turn.assistant";
    "turn.finished";
    (* turn 3 *)
    "turn.started";
    "turn.assistant_interrupted";
    "turn.finished";
    (* turn 4 *)
    "turn.started";
    "turn.provider_failed";
    "turn.finished";
    (* turn 5 *)
    "turn.started";
    "turn.finished";
  ]

let returned_evidence ~msg fact =
  match fact with
  | Protocol.Fact.Tool_returned { mutation; _ } -> mutation
  | _ -> failf "%s: expected a tool.returned fact" msg

let ambiguous_evidence ~msg fact =
  match fact with
  | Protocol.Fact.Tool_ambiguous { mutation; _ } -> mutation
  | _ -> failf "%s: expected a tool.ambiguous fact" msg

(* Projection: determinism, suffix law, live/replay identity. *)

let projection_group =
  group "projection: the one projector"
    [
      test "same inputs project to the same positions and facts" (fun () ->
          let j = journey () in
          let first = project_all j in
          let second = project_all j in
          equal (list projected_value) ~msg:"two projections" first second);
      test "projection preserves the complete durable tool output" (fun () ->
          let semantics =
            json_object
              [ ("version", Json.int 1); ("shape", Json.string "compact") ]
          in
          let output =
            Tool.Output.make ~text:"value=42" ~json:semantics ~truncated:true ()
          in
          let call = tool_call ~id:"call-present" () in
          let turn = turn ~id:"turn-present" () in
          let turn_id = Session.Turn.id turn in
          let provider_claim = claim ~seed:"present-provider" turn_id in
          let tool_claim = tool_claim ~turn:turn_id call in
          let session =
            saved
              [
                Event.turn_started turn;
                Event.provider_requested provider_claim;
                settle_responded provider_claim (assistant_calls [ call ]);
                Event.tool_claimed tool_claim;
                settled_returned tool_claim (Tool.Result.completed ~output ());
              ]
          in
          let facts =
            Protocol.Projection.all ~session ~mutation:(mutation_state [])
            |> List.map snd
          in
          match
            List.find_map
              (function
                | Protocol.Fact.Tool_returned { result; _ } -> Some result
                | _ -> None)
              facts
          with
          | None -> fail "expected the returned tool fact"
          | Some result -> (
              match Tool.Result.output result with
              | None -> fail "completed result lost its output"
              | Some projected ->
                  is_true ~msg:"the TUI-facing fact keeps every projection"
                    (Tool.Output.equal output projected)));
      test "every projectable event yields exactly one fact, in order"
        (fun () ->
          let j = journey () in
          let facts = List.map snd (project_all j) in
          equal (list string) ~msg:"projected tag sequence" expected_tags
            (List.map fact_tag facts);
          equal int ~msg:"event count" 45 (List.length (session_events j)));
      test "a known provider failure preserves its owner error before terminal"
        (fun () ->
          let j = journey () in
          let rec find = function
            | Protocol.Fact.Turn_provider_failed { claim; error }
              :: (Protocol.Fact.Turn_settled _ as terminal)
              :: _ ->
                (claim, error, terminal)
            | _ :: rest -> find rest
            | [] -> fail "expected provider failure followed by turn terminal"
          in
          let claim, error, terminal = find (List.map snd (project_all j)) in
          is_true ~msg:"claim correlation is exact"
            (Session.Provider_request.Id.equal claim
               (claim_id j.failed_provider_claim));
          is_true ~msg:"structured provider error is preserved"
            (Llm.Error.equal error j.failed_provider_error);
          match terminal with
          | Protocol.Fact.Turn_settled
              { outcome = Session.Turn.Outcome.Failed _; _ } ->
              ()
          | _ -> fail "provider failure must precede a failed turn terminal");
      test "suffix projection equals the strict suffix at every position"
        (fun () ->
          let j = journey () in
          let session = full_session j in
          let mutation = full_mutation j in
          let full = project ~since:None ~session ~mutation in
          List.iteri
            (fun i (position, _) ->
              let suffix = project ~since:(Some position) ~session ~mutation in
              equal (list projected_value)
                ~msg:(Printf.sprintf "suffix after fact %d" i)
                (drop (i + 1) full)
                suffix)
            full);
      test "live emission equals replay projection byte-for-byte" (fun () ->
          let j = journey () in
          let events = session_events j in
          (* Live emission: after each commit, project the strict suffix over
             the cumulative session and mutation state — the feed-serving
             pattern of the incremental-projection producer. *)
          let live =
            let rec go k last mut_events acc = function
              | [] -> List.concat (List.rev acc)
              | (batch, _event) :: rest ->
                  let mut_events = mut_events @ batch in
                  let session = saved (take k events) in
                  let mutation = mutation_state mut_events in
                  let items = project ~since:last ~session ~mutation in
                  let last =
                    match List.rev items with
                    | (position, _) :: _ -> Some position
                    | [] -> last
                  in
                  go (k + 1) last mut_events (items :: acc) rest
            in
            go 1 None [] [] j.steps
          in
          let replay = project_all j in
          equal (list projected_value) ~msg:"live equals replay" replay live;
          let bytes items =
            List.map
              (fun (position, fact) ->
                encode_bytes Protocol.Update.jsont
                  (Protocol.Update.Committed { position; fact }))
              items
          in
          equal (list string) ~msg:"byte-identical committed updates"
            (bytes replay) (bytes live));
      test "serialize, decode, and reproject: the same facts" (fun () ->
          let j = journey () in
          let facts = List.map snd (project_all j) in
          (* Each fact round-trips through its own codec. *)
          List.iteri
            (fun i fact ->
              equal fact_value
                ~msg:(Printf.sprintf "fact %d round-trips" i)
                fact
                (decode Protocol.Fact.jsont (encode Protocol.Fact.jsont fact)))
            facts;
          (* The saved documents round-trip and reproject identically. *)
          let session' =
            decode Session.jsont (encode Session.jsont (full_session j))
          in
          let mutation' =
            mutation_state
              (List.map
                 (fun event ->
                   decode Mutation.Event.jsont
                     (encode Mutation.Event.jsont event))
                 (mutation_events j))
          in
          let reprojected =
            project ~since:None ~session:session' ~mutation:mutation'
          in
          equal (list projected_value) ~msg:"reprojected facts" (project_all j)
            reprojected);
      test "a position minted for another session is rejected structurally"
        (fun () ->
          let j = journey () in
          let other = turn ~id:"turn-o" () in
          let other_session =
            saved ~id:"other-session" [ Event.turn_started other; finish other ]
          in
          let foreign =
            match
              project ~since:None ~session:other_session
                ~mutation:(mutation_state [])
            with
            | (position, _) :: _ -> position
            | [] -> fail "expected a projected fact"
          in
          match
            Protocol.Projection.after foreign ~session:(full_session j)
              ~mutation:(full_mutation j)
          with
          | Ok _ -> fail "expected a foreign-session rejection"
          | Error
              (Protocol.Position.Invalid.Foreign_session { expected; actual })
            ->
              is_true ~msg:"expected is this session"
                (Session.Id.equal expected (Session.id (full_session j)));
              is_true ~msg:"actual is the other session"
                (Session.Id.equal actual (Session.id other_session))
          | Error other ->
              failf "expected Foreign_session, got %s"
                (Protocol.Position.Invalid.message other));
      test "a decoded position is usable for its own session only" (fun () ->
          let j = journey () in
          let full = project_all j in
          let position = fst (List.hd full) in
          let json = encode Protocol.Position.jsont position in
          let position' = decode Protocol.Position.jsont json in
          equal position_value ~msg:"position round-trips" position position';
          let resumed =
            project ~since:(Some position') ~session:(full_session j)
              ~mutation:(full_mutation j)
          in
          equal (list projected_value) ~msg:"decoded position resumes"
            (drop 1 full) resumed);
      test "a forged-future position past the head is not in the feed"
        (fun () ->
          let j = journey () in
          let full = project_all j in
          let last = fst (List.nth full (List.length full - 1)) in
          (* Encode the last real position, bump its sequence past the journal,
             and thread it back: a token this feed never minted. *)
          let forged =
            let json = encode Protocol.Position.jsont last in
            decode Protocol.Position.jsont
              (set_member "seq" (Json.int 9999) json)
          in
          match
            Protocol.Projection.after forged ~session:(full_session j)
              ~mutation:(full_mutation j)
          with
          | Error (Protocol.Position.Invalid.Not_in_feed p) ->
              equal position_value ~msg:"reports the forged token" forged p
          | Ok _ -> fail "expected a not-in-feed rejection"
          | Error other ->
              failf "expected Not_in_feed, got %s"
                (Protocol.Position.Invalid.message other));
      test "position construction exposes shape, not feed membership" (fun () ->
          let j = journey () in
          let session = full_session j in
          let id = Session.id session in
          let candidate = Protocol.Position.make ~session:id ~seq:9999 in
          is_true ~msg:"the public alias exposes the owning session"
            (Session.Id.equal id (Protocol.Position.session candidate));
          equal int ~msg:"the public alias exposes the journal sequence" 9999
            (Protocol.Position.seq candidate);
          match
            Protocol.Projection.after candidate ~session
              ~mutation:(full_mutation j)
          with
          | Error (Protocol.Position.Invalid.Not_in_feed found) ->
              equal position_value ~msg:"membership rejects the candidate"
                candidate found
          | Ok _ -> fail "construction must not establish feed membership"
          | Error other ->
              failf "expected Not_in_feed, got %s"
                (Protocol.Position.Invalid.message other));
      test "a position at a non-fact-emitting sequence is not in the feed"
        (fun () ->
          (* In the journey, sequence 1 is [Provider_requested], a recovery-only
             event that projects no fact, so no position was ever minted there:
             the seq-0 token retargeted to seq 1 is a token this feed never
             produced. *)
          let j = journey () in
          let session = full_session j in
          let mutation = full_mutation j in
          let full = project_all j in
          let non_emitting =
            let template =
              encode Protocol.Position.jsont (fst (List.hd full))
            in
            decode Protocol.Position.jsont
              (set_member "seq" (Json.int 1) template)
          in
          match Protocol.Projection.after non_emitting ~session ~mutation with
          | Error (Protocol.Position.Invalid.Not_in_feed _) -> ()
          | Ok _ -> fail "expected a not-in-feed rejection"
          | Error other ->
              failf "expected Not_in_feed, got %s"
                (Protocol.Position.Invalid.message other));
    ]

(* Projection: mutation evidence and the prefix law. *)

let evidence_group =
  group "projection: mutation evidence"
    [
      test "a claim that recorded no change carries no evidence" (fun () ->
          let j = journey () in
          let facts = List.map snd (project_all j) in
          match returned_evidence ~msg:"read claim" (List.nth facts 3) with
          | None -> ()
          | Some _ -> fail "expected no evidence on the read claim");
      test
        "a settled claim carries its own rows, cumulative totals, and \
         settlement-time revertability" (fun () ->
          let j = journey () in
          let facts = List.map snd (project_all j) in
          match returned_evidence ~msg:"write claim" (List.nth facts 5) with
          | None -> fail "expected evidence on the write claim"
          | Some evidence ->
              equal (list change_value) ~msg:"change rows" [ j.a1; j.b1 ]
                evidence.Protocol.Fact.changes;
              equal paths_value ~msg:"no observations" []
                evidence.Protocol.Fact.observed;
              equal stats_value ~msg:"run-cumulative totals"
                (Textdiff.Stats.v ~files:2 ~additions:4 ~deletions:1)
                evidence.Protocol.Fact.totals;
              equal revertability_value ~msg:"revertability"
                Mutation.Revertability.Available
                evidence.Protocol.Fact.revertability);
      test
        "evidence is the prefix answer: later superseding changes do not \
         rewrite a settled fact" (fun () ->
          let j = journey () in
          let facts = List.map snd (project_all j) in
          (match returned_evidence ~msg:"write claim" (List.nth facts 5) with
          | None -> fail "expected evidence on the write claim"
          | Some evidence ->
              (* The fact freezes the settlement-time answer. *)
              equal revertability_value ~msg:"prefix answer"
                Mutation.Revertability.Available
                evidence.Protocol.Fact.revertability);
          (* The full replayed ledger disagrees: the ambiguous claim and the
             staged run superseded src/a.ml after the write settled, so the
             full-state answer is Unavailable. The fact must not carry it. *)
          let selection =
            Mutation.Revert.Selection.changes
              [ Mutation.Change.id j.a1; Mutation.Change.id j.b1 ]
          in
          match Mutation.State.revertability (full_mutation j) selection with
          | Mutation.Revertability.Unavailable _ -> ()
          | Mutation.Revertability.Available ->
              fail "full-state answer unexpectedly Available"
          | Mutation.Revertability.Incomplete _ ->
              fail "full-state answer unexpectedly Incomplete");
      test
        "an ambiguous settlement carries its recorded rows as evidence, which \
         also enter the turn's cumulative totals" (fun () ->
          let j = journey () in
          let facts = List.map snd (project_all j) in
          (match List.nth facts 7 with
          | Protocol.Fact.Tool_ambiguous { claim; _ } ->
              is_true ~msg:"ambiguous claim id"
                (Session.Tool_claim.Id.equal claim (tool_claim_id j.amb_claim))
          | _ -> fail "expected the ambiguous tool fact");
          (* B2: an ambiguous settlement that recorded a durable change carries
             it — honesty matters most exactly here. *)
          (match
             ambiguous_evidence ~msg:"ambiguous claim" (List.nth facts 7)
           with
          | None -> fail "expected evidence on the ambiguous claim"
          | Some evidence ->
              equal (list change_value) ~msg:"ambiguous own rows" [ j.amb1 ]
                evidence.Protocol.Fact.changes;
              equal paths_value ~msg:"no observations" []
                evidence.Protocol.Fact.observed;
              (* cumulative through the ambiguous settlement: a1,b1,amb1. *)
              equal stats_value ~msg:"cumulative includes the ambiguous rows"
                (Textdiff.Stats.v ~files:2 ~additions:6 ~deletions:2)
                evidence.Protocol.Fact.totals);
          match returned_evidence ~msg:"staged run" (List.nth facts 16) with
          | None -> fail "expected evidence on the staged run"
          | Some evidence ->
              equal (list change_value) ~msg:"own rows only" [ j.s1 ]
                evidence.Protocol.Fact.changes;
              (* files: src/a.ml + src/b.ml; additions 3+1+2+1; deletions
                 0+1+1+0 — the ambiguous claim's recorded rows count. *)
              equal stats_value ~msg:"cumulative totals include ambiguous rows"
                (Textdiff.Stats.v ~files:2 ~additions:7 ~deletions:2)
                evidence.Protocol.Fact.totals;
              equal revertability_value ~msg:"own revertability"
                Mutation.Revertability.Available
                evidence.Protocol.Fact.revertability);
      test "an observed-only claim carries its observations, not exact rows"
        (fun () ->
          (* A claim window that recorded only a [Tool_observed] fact — no exact
             edit — still projects evidence: the opaque observed paths and an
             [Incomplete] revertability, on the ambiguous settlement. *)
          let turn0 = turn ~id:"turn-obs" () in
          let turn0_id = Session.Turn.id turn0 in
          let call = tool_call ~id:"call-obs" ~name:"shell" () in
          let obs_claim = tool_claim ~turn:turn0_id call in
          let obs_id = tool_claim_id obs_claim in
          let observed_path = wpath "src/touched.ml" in
          let observed_event =
            Mutation.Event.tool_observed ~turn:turn0_id ~claim:obs_id
              [ observed_path ]
          in
          let pclaim = claim turn0_id in
          let session =
            saved
              [
                Event.turn_started turn0;
                Event.provider_requested pclaim;
                settle_responded pclaim (assistant_calls [ call ]);
                Event.tool_claimed obs_claim;
                settled_ambiguous obs_claim;
                finish turn0;
              ]
          in
          let mutation = mutation_state [ observed_event ] in
          let facts =
            List.map snd (Protocol.Projection.all ~session ~mutation)
          in
          let ambiguous =
            List.find
              (function Protocol.Fact.Tool_ambiguous _ -> true | _ -> false)
              facts
          in
          match ambiguous_evidence ~msg:"observed-only" ambiguous with
          | None -> fail "expected observed-only evidence"
          | Some evidence -> (
              equal (list change_value) ~msg:"no exact rows" []
                evidence.Protocol.Fact.changes;
              equal paths_value ~msg:"observed path" [ observed_path ]
                evidence.Protocol.Fact.observed;
              match evidence.Protocol.Fact.revertability with
              | Mutation.Revertability.Incomplete _ -> ()
              | _ -> fail "expected Incomplete revertability for observations"));
      test
        "the prepared fact composes the tool description with the settlement's \
         one request list" (fun () ->
          let j = journey () in
          let facts = List.map snd (project_all j) in
          match List.nth facts 12 with
          | Protocol.Fact.Tool_prepared { claim = _; description; requests } ->
              equal string ~msg:"description"
                (Tool.Prepared.description j.prepared)
                description;
              equal int ~msg:"request count"
                (List.length (Tool.Prepared.requests j.prepared))
                (List.length requests)
          | _ -> fail "expected the tool.prepared fact");
    ]

(* Projection: the resumable fold is the from-scratch fold, split across calls.
   The materialized feed hub grows its projection through {!Projection.advance},
   one commit's events at a time; these arms prove that path emits byte-identical
   facts to {!Projection.all} at every chunk boundary — the determinism law for
   the
   incremental projection. *)

let projected_bytes items =
  List.map
    (fun (position, fact) ->
      encode_bytes Protocol.Update.jsont
        (Protocol.Update.Committed { position; fact }))
    items

(* Advance [delta] from [start] in fixed-size chunks, chaining the resume state,
   and concatenate the emitted facts. *)
let advance_in_chunks ~session ~mutation ~size delta =
  let rec go resume acc rest =
    match rest with
    | [] -> List.concat (List.rev acc)
    | _ ->
        let resume, emitted =
          Protocol.Projection.advance resume ~session ~mutation
            ~delta:(take size rest)
        in
        go resume (emitted :: acc) (drop size rest)
  in
  go Protocol.Projection.start [] delta

let incremental_group =
  group "projection: incremental fold equivalence"
    [
      test
        "chained advance with each commit's own mutation state equals the full \
         replay, byte-identical" (fun () ->
          let j = journey () in
          let session = full_session j in
          (* Mirror the hub exactly: advance one commit at a time, each with the
             mutation state as of that commit — the intermediate ledger, not the
             final one — as [Feed.Hub.publish] folds [t.mstate] at each commit.
             The settlement evidence still matches the full replay because it
             reads each claim's immutable ledger prefix, so [projected] is
             append-only. *)
          let rec go resume mut_events acc = function
            | [] -> List.concat (List.rev acc)
            | (batch, event) :: rest ->
                let mut_events = mut_events @ batch in
                let resume, emitted =
                  Protocol.Projection.advance resume ~session
                    ~mutation:(mutation_state mut_events)
                    ~delta:[ event ]
                in
                go resume mut_events (emitted :: acc) rest
          in
          let incremental = go Protocol.Projection.start [] [] j.steps in
          let replay =
            Protocol.Projection.all ~session ~mutation:(full_mutation j)
          in
          equal (list projected_value)
            ~msg:"per-commit-mutation advance equals full replay" replay
            incremental;
          equal (list string) ~msg:"byte-identical committed updates"
            (projected_bytes replay)
            (projected_bytes incremental));
      test
        "chunked advance equals the whole projection, byte-identical, at every \
         chunk size" (fun () ->
          let j = journey () in
          let session = full_session j in
          let mutation = full_mutation j in
          let events = session_events j in
          let whole = Protocol.Projection.all ~session ~mutation in
          List.iter
            (fun size ->
              let incremental =
                advance_in_chunks ~session ~mutation ~size events
              in
              equal (list projected_value)
                ~msg:(Printf.sprintf "chunk size %d: facts" size)
                whole incremental;
              equal (list string)
                ~msg:(Printf.sprintf "chunk size %d: bytes" size)
                (projected_bytes whole)
                (projected_bytes incremental))
            [ 1; 2; 3; 5; 13; 46; 1000 ]);
      test "any two-part split of any journal prefix folds to its whole"
        (fun () ->
          let j = journey () in
          let session = full_session j in
          let mutation = full_mutation j in
          let events = session_events j in
          let n = List.length events in
          List.iter
            (fun k ->
              let prefix = take k events in
              let whole =
                snd
                  (Protocol.Projection.advance Protocol.Projection.start
                     ~session ~mutation ~delta:prefix)
              in
              List.iter
                (fun split ->
                  let resume, head =
                    Protocol.Projection.advance Protocol.Projection.start
                      ~session ~mutation ~delta:(take split prefix)
                  in
                  let _resume, tail =
                    Protocol.Projection.advance resume ~session ~mutation
                      ~delta:(drop split prefix)
                  in
                  equal (list projected_value)
                    ~msg:(Printf.sprintf "prefix %d split %d" k split)
                    whole (head @ tail))
                [ 0; 1; k / 2; k ])
            [ 0; 1; 5; 12; 24; n ]);
      test
        "the last materialized position is the whole-journal head (O(1) head)"
        (fun () ->
          let j = journey () in
          let session = full_session j in
          let mutation = full_mutation j in
          let head items =
            match List.rev items with
            | (position, _) :: _ -> Some position
            | [] -> None
          in
          let _resume, emitted =
            Protocol.Projection.advance Protocol.Projection.start ~session
              ~mutation ~delta:(session_events j)
          in
          equal (option position_value)
            ~msg:"incremental head equals the whole-fold head"
            (head (Protocol.Projection.all ~session ~mutation))
            (head emitted));
      test "consumed counts every folded event; an empty delta is a no-op"
        (fun () ->
          let j = journey () in
          let session = full_session j in
          let mutation = full_mutation j in
          let events = session_events j in
          let resume, _ =
            Protocol.Projection.advance Protocol.Projection.start ~session
              ~mutation ~delta:events
          in
          equal int ~msg:"consumed equals journal length" (List.length events)
            (Protocol.Projection.consumed resume);
          let resume', emitted' =
            Protocol.Projection.advance resume ~session ~mutation ~delta:[]
          in
          equal int ~msg:"an empty delta leaves consumed unchanged"
            (List.length events)
            (Protocol.Projection.consumed resume');
          equal (list projected_value) ~msg:"an empty delta emits nothing" []
            emitted');
    ]

(* Codec fixtures. *)

(* Small, journey-independent values for per-arm codec tests. *)

let fix_turn = turn ~id:"turn-c" ()
let fix_turn_id = Session.Turn.id fix_turn
let fix_call = tool_call ~id:"call-c" ~name:"read_file" ()
let fix_claim = tool_claim ~turn:fix_turn_id fix_call
let fix_claim_id = tool_claim_id fix_claim

let fix_decision =
  permission_decision ~turn:fix_turn_id ~call:fix_call
    (access ~subject:"c" "session.review")

let fix_resolution =
  resolve_ok ~msg:"fixture resolve" fix_decision ~call:fix_call
    ~by:Session.Principal.local_user
    (Session.Decision.Answer.Permission { answer = allow_once; message = None })

let fix_prepared = prepared_payload "beta"
let fix_change = (journey ()).a1

let fix_evidence =
  {
    Protocol.Fact.changes = [ fix_change ];
    observed = [];
    totals = Mutation.Change.of_changes [ fix_change ];
    revertability = Mutation.Revertability.Available;
  }

let fix_response =
  Llm.Response.make ~model ~usage:(usage ~input:5 ~output:2)
    (Llm.Message.Assistant.text "Hello.")

let fix_provider_claim = claim ~seed:"fix-provider-failure" fix_turn_id

let fix_provider_error =
  Llm.Error.make ~kind:Llm.Error.Rate_limited ~phase:Llm.Error.Stream ~provider
    ~status:429 ~request_id:"req-provider-1" "rate limited"

let fix_compaction =
  let p = claim ~seed:"fix-summary" fix_turn_id in
  Session.Compaction.make ~reason:Session.Compaction.Reason.User_requested
    ~provider_claim:(claim_id p) ~request_digest:(digest "fix-summary")
    ~summary_messages:[ Llm.Message.user_text "Summary." ]
    ~summarized_upto:2 ()

let fix_board =
  board [ task_item ~id:"task-c" ~position:0 "Chart the module graph" ]

let fix_edge =
  Session.Delegation.make ~child:(session_id "child-c") ~source_turn:fix_turn_id
    ~source_call:"call-c"
    ~task:[ Llm.Content.text "Chart it." ]
    ()

let all_facts =
  [
    ("turn.started", Protocol.Fact.Turn_started fix_turn);
    ("turn.assistant", Protocol.Fact.Turn_assistant fix_response);
    ( "turn.assistant_interrupted",
      Protocol.Fact.Turn_assistant_interrupted { text = "Stopping." } );
    ( "turn.provider_failed",
      Protocol.Fact.Turn_provider_failed
        { claim = claim_id fix_provider_claim; error = fix_provider_error } );
    ("turn.message", Protocol.Fact.Turn_message (Llm.Message.user_text "hi"));
    ( "turn.finished",
      Protocol.Fact.Turn_settled
        { turn = fix_turn_id; outcome = Session.Turn.Outcome.completed } );
    ("tool.started", Protocol.Fact.Tool_started fix_claim);
    ( "tool.prepared",
      Protocol.Fact.Tool_prepared
        {
          claim = fix_claim_id;
          description = Tool.Prepared.description fix_prepared;
          requests = Tool.Prepared.requests fix_prepared;
        } );
    ( "tool.returned",
      Protocol.Fact.Tool_returned
        {
          claim = fix_claim_id;
          result = completed "done";
          mutation = Some fix_evidence;
        } );
    ( "tool.ambiguous",
      Protocol.Fact.Tool_ambiguous
        { claim = fix_claim_id; mutation = Some fix_evidence } );
    ("decision.requested", Protocol.Fact.Decision_requested fix_decision);
    ("decision.resolved", Protocol.Fact.Decision_resolved fix_resolution);
    ("journal.tasks", Protocol.Fact.Journal_task_board fix_board);
    ("journal.delegation", Protocol.Fact.Journal_delegation fix_edge);
    ( "journal.queue",
      Protocol.Fact.Journal_queue
        (Session.Queue.Update.enqueued (queue_entry ~id:"q-c" "Next.")) );
    ("compaction.installed", Protocol.Fact.Compaction fix_compaction);
    ( "workspace.notice",
      Protocol.Fact.Workspace_notice
        (Session.Notice.make ~source:"fswatch"
           ~severity:Session.Notice.Severity.Info
           ~title:"2 workspace file changes since the last scan"
           ~body:"- changed lib/a.ml\n- changed lib/b.ml" ()) );
    ( "undo.updated",
      Protocol.Fact.Undo
        {
          update =
            Session.Undo.Update.armed ~anchor:fix_turn_id ~revert:"revert-1" ();
          dropped_turns = 2;
          files =
            [
              {
                Protocol.Fact.path = wpath "lib/a.ml";
                additions = 12;
                deletions = 4;
              };
            ];
        } );
  ]

let all_progress =
  [
    ( "model.started",
      Protocol.Progress.Model
        { turn = fix_turn_id; update = Protocol.Progress.Model.Started } );
    ( "model.assistant_delta",
      Protocol.Progress.Model
        {
          turn = fix_turn_id;
          update = Protocol.Progress.Model.Assistant_delta { text = "He" };
        } );
    ( "model.reasoning_delta",
      Protocol.Progress.Model
        {
          turn = fix_turn_id;
          update = Protocol.Progress.Model.Reasoning_delta { text = "hm" };
        } );
    ( "model.usage",
      Protocol.Progress.Model
        {
          turn = fix_turn_id;
          update = Protocol.Progress.Model.Usage (usage ~input:9 ~output:4);
        } );
    ( "model.tool_input",
      Protocol.Progress.Model
        {
          turn = fix_turn_id;
          update =
            Protocol.Progress.Model.Tool_input
              { name = Some "edit_file"; received = 4096 };
        } );
    ( "model.retrying",
      Protocol.Progress.Model
        {
          turn = fix_turn_id;
          update =
            Protocol.Progress.Model.Retrying
              (Llm.Event.Retry.make ~attempt:3 ~limit:10 ~delay:8.5
                 ~reason:"provider overloaded" ());
        } );
    ( "model.download",
      Protocol.Progress.Model_download
        {
          turn = fix_turn_id;
          update =
            {
              Protocol.Progress.Model_download.model = "gpt-oss-20b";
              received = 1_200_000_000L;
              total = Some 12_109_566_624L;
              phase = Protocol.Progress.Model_download.Downloading;
            };
        } );
    ( "compaction.started",
      Protocol.Progress.Compaction
        {
          turn = fix_turn_id;
          update =
            Protocol.Progress.Compaction.Started
              { reason = Session.Compaction.Reason.Context_pressure };
        } );
    ( "compaction.summarizing",
      Protocol.Progress.Compaction
        {
          turn = fix_turn_id;
          update = Protocol.Progress.Compaction.Summarizing;
        } );
    ( "compaction.failed",
      Protocol.Progress.Compaction
        {
          turn = fix_turn_id;
          update =
            Protocol.Progress.Compaction.Failed
              {
                reason = Session.Compaction.Reason.Context_pressure;
                message = "summary model gone";
              };
        } );
  ]

let fix_session_id = session_id "session-c"

let all_commands =
  [
    ( "prompt",
      ok_or "prompt"
        (Protocol.Command.prompt ~session:fix_session_id
           ~turn:(turn_id "turn-cmd")
           ~input:[ Llm.Content.text "Go." ]
           ~mode:Session.Contract.Mode.Build ~max_steps:8 ()) );
    ( "answer_decision",
      Protocol.Command.answer_decision ~session:fix_session_id
        ~decision:(Session.Decision.Requested.id fix_decision)
        ~answer:
          (Session.Decision.Answer.Permission
             { answer = allow_once; message = None }) );
    ( "interrupt",
      ok_or "interrupt"
        (Protocol.Command.interrupt ~session:fix_session_id ~reason:"stop" ())
    );
    ( "queue_next",
      ok_or "queue_next"
        (Protocol.Command.queue_next ~session:fix_session_id
           ~input:[ Llm.Content.text "Next." ] ()) );
    ( "replace_queued",
      ok_or "replace_queued"
        (Protocol.Command.replace_queued ~session:fix_session_id
           ~inputs:
             [
               [ Llm.Content.text "First instead." ];
               [ Llm.Content.text "Then this." ];
             ]) );
    ("clear_queued", Protocol.Command.clear_queued ~session:fix_session_id);
  ]

let all_errors =
  [
    ( "busy",
      Protocol.Error.Busy
        { session = fix_session_id; owner = Some "pid 4242 on mac-studio" } );
    ("session_not_found", Protocol.Error.Session_not_found fix_session_id);
    ( "invalid_position",
      Protocol.Error.Invalid_position
        (Protocol.Position.Invalid.Foreign_session
           { expected = fix_session_id; actual = session_id "session-d" }) );
    ("no_active_turn", Protocol.Error.No_active_turn fix_session_id);
    ("active_turn_exists", Protocol.Error.Active_turn_exists fix_turn_id);
    ("turn_id_reused", Protocol.Error.Turn_id_reused fix_turn_id);
    ( "decision_not_pending",
      Protocol.Error.Decision_not_pending
        (Session.Decision.Requested.id fix_decision) );
    ( "already_resolved",
      Protocol.Error.Already_resolved
        (Session.Decision.Requested.id fix_decision) );
    ("invalid_title", Protocol.Error.Invalid_title);
    ("invalid_api_key", Protocol.Error.Invalid_api_key);
    ("archived", Protocol.Error.Archived fix_session_id);
    ("deleted", Protocol.Error.Deleted fix_session_id);
    ( "unknown_command",
      Protocol.Error.Unknown_command
        (Result.get_ok (Protocol.User_command.Name.of_string "git:commit")) );
    ( "file_unresolved",
      Protocol.Error.File_unresolved
        { path = "src/foo.ml"; reason = "resolves outside the workspace" } );
    ( "unavailable",
      Protocol.Error.Unavailable
        (Mentat_diagnostic.make ~context:"connection refused"
           ~hints:[ "retry shortly" ] "store unreachable") );
  ]

let assert_v_and_tag ~msg tag json =
  equal json_value ~msg:(msg ^ ": v") (Json.int 1) (get_member "v" json);
  equal string ~msg:(msg ^ ": tag") tag (member_string "type" json)

(* The strictness attacks every versioned tagged codec must repel. *)
let assert_strict ~msg codec valid =
  assert_decode_error ~contains:"unsupported protocol version 2"
    (msg ^ ": v = 2") codec
    (set_member "v" (Json.int 2) valid);
  assert_decode_error (msg ^ ": missing v") codec (remove_member "v" valid);
  assert_decode_error (msg ^ ": unknown tag") codec
    (set_member "type" (Json.string "mystery.tag") valid);
  assert_decode_error (msg ^ ": unknown member") codec
    (add_member "mystery" (Json.bool true) valid)

(* Fact codec. *)

let fact_codec_group =
  group "codec: facts"
    [
      test "every fact arm round-trips under its pinned tag and v" (fun () ->
          List.iter
            (fun (tag, fact) ->
              let json = encode Protocol.Fact.jsont fact in
              assert_v_and_tag ~msg:tag tag json;
              equal fact_value ~msg:(tag ^ ": round-trip") fact
                (decode Protocol.Fact.jsont json))
            all_facts);
      test "strict decode: unknown tag, unknown member, and the v envelope"
        (fun () ->
          let valid =
            encode Protocol.Fact.jsont (List.assoc "turn.finished" all_facts)
          in
          assert_strict ~msg:"fact" Protocol.Fact.jsont valid);
      test "strict decode: a cross-arm member is an unknown member" (fun () ->
          let ambiguous =
            encode Protocol.Fact.jsont (List.assoc "tool.ambiguous" all_facts)
          in
          assert_decode_error "tool.ambiguous with a result member"
            Protocol.Fact.jsont
            (add_member "result" (Json.string "ok") ambiguous));
      test "a returned fact without evidence omits the mutation member"
        (fun () ->
          let fact =
            Protocol.Fact.Tool_returned
              {
                claim = fix_claim_id;
                result = completed "done";
                mutation = None;
              }
          in
          let json = encode Protocol.Fact.jsont fact in
          let members, _ = members_of json in
          is_true ~msg:"no mutation member"
            (not
               (List.exists
                  (fun ((n, _), _) -> String.equal n "mutation")
                  members));
          equal fact_value ~msg:"round-trip" fact
            (decode Protocol.Fact.jsont json));
      test "mutation evidence must carry at least one change" (fun () ->
          let json =
            encode Protocol.Fact.jsont (List.assoc "tool.returned" all_facts)
          in
          assert_decode_error ~contains:"at least one change" "empty changes"
            Protocol.Fact.jsont
            (set_member "mutation"
               (set_member "changes" (json_array [])
                  (get_member "mutation" json))
               json));
      test "an interrupted assistant fact rejects empty text on decode"
        (fun () ->
          let json =
            encode Protocol.Fact.jsont
              (List.assoc "turn.assistant_interrupted" all_facts)
          in
          assert_decode_error ~contains:"must not be empty" "empty text"
            Protocol.Fact.jsont
            (set_member "text" (Json.string "") json));
    ]

(* Update codec. *)

let update_codec_group =
  let committed j =
    let position, fact = List.hd (project_all j) in
    Protocol.Update.Committed { position; fact }
  in
  group "codec: updates"
    [
      test "committed and progress updates round-trip" (fun () ->
          let j = journey () in
          let committed = committed j in
          equal update_value ~msg:"committed" committed
            (decode Protocol.Update.jsont
               (encode Protocol.Update.jsont committed));
          let progress =
            Protocol.Update.Progress (List.assoc "model.usage" all_progress)
          in
          equal update_value ~msg:"progress" progress
            (decode Protocol.Update.jsont
               (encode Protocol.Update.jsont progress)));
      test "update tags and v are pinned" (fun () ->
          let j = journey () in
          assert_v_and_tag ~msg:"committed" "committed"
            (encode Protocol.Update.jsont (committed j));
          assert_v_and_tag ~msg:"progress" "progress"
            (encode Protocol.Update.jsont
               (Protocol.Update.Progress
                  (List.assoc "model.started" all_progress))));
      test "strict decode on the update envelope" (fun () ->
          let j = journey () in
          let valid = encode Protocol.Update.jsont (committed j) in
          assert_strict ~msg:"update" Protocol.Update.jsont valid;
          (* Cross-arm: a committed update must not carry the progress
             member. *)
          assert_decode_error "committed with progress member"
            Protocol.Update.jsont
            (add_member "progress"
               (encode Protocol.Progress.jsont
                  (List.assoc "model.started" all_progress))
               valid);
          (* The nested fact keeps its own envelope: a version bump inside
             the fact member fails too. *)
          assert_decode_error ~contains:"unsupported protocol version"
            "nested fact v" Protocol.Update.jsont
            (set_member "fact"
               (set_member "v" (Json.int 2) (get_member "fact" valid))
               valid));
      test "update equality distinguishes arms" (fun () ->
          let j = journey () in
          let committed = committed j in
          let progress =
            Protocol.Update.Progress (List.assoc "model.started" all_progress)
          in
          is_true ~msg:"same committed"
            (Protocol.Update.equal committed committed);
          is_true ~msg:"committed <> progress"
            (not (Protocol.Update.equal committed progress)));
    ]

(* Progress codec. *)

let progress_codec_group =
  group "codec: progress"
    [
      test "every pulse arm round-trips under its pinned tag and v" (fun () ->
          List.iter
            (fun (tag, pulse) ->
              let json = encode Protocol.Progress.jsont pulse in
              assert_v_and_tag ~msg:tag tag json;
              equal progress_value ~msg:(tag ^ ": round-trip") pulse
                (decode Protocol.Progress.jsont json))
            all_progress);
      test "every pulse carries its turn" (fun () ->
          List.iter
            (fun (tag, pulse) ->
              is_true ~msg:tag
                (Session.Turn.Id.equal fix_turn_id
                   (Protocol.Progress.turn pulse)))
            all_progress);
      test "strict decode on the progress envelope" (fun () ->
          let valid =
            encode Protocol.Progress.jsont
              (List.assoc "model.assistant_delta" all_progress)
          in
          assert_strict ~msg:"progress" Protocol.Progress.jsont valid);
      test "decode rejects an empty compaction failure message" (fun () ->
          let failed =
            encode Protocol.Progress.jsont
              (List.assoc "compaction.failed" all_progress)
          in
          assert_decode_error ~contains:"must not be empty" "empty message"
            Protocol.Progress.jsont
            (set_member "message" (Json.string "") failed));
      test "decode rejects a malformed tool-input pulse" (fun () ->
          let tool_input =
            encode Protocol.Progress.jsont
              (List.assoc "model.tool_input" all_progress)
          in
          assert_decode_error ~contains:"positive" "zero received"
            Protocol.Progress.jsont
            (set_member "received" (Json.int 0) tool_input);
          assert_decode_error ~contains:"must not be empty" "empty name"
            Protocol.Progress.jsont
            (set_member "name" (Json.string "") tool_input));
      test "decode rejects malformed retry announcements" (fun () ->
          let retrying =
            encode Protocol.Progress.jsont
              (List.assoc "model.retrying" all_progress)
          in
          assert_decode_error ~contains:"at least 1" "zero attempt"
            Protocol.Progress.jsont
            (set_member "attempt" (Json.int 0) retrying);
          assert_decode_error ~contains:"at least attempt" "limit below attempt"
            Protocol.Progress.jsont
            (set_member "limit" (Json.int 2) retrying);
          assert_decode_error ~contains:"non-negative" "negative delay"
            Protocol.Progress.jsont
            (set_member "delay" (Json.number (-1.)) retrying);
          assert_decode_error ~contains:"must not be empty" "empty reason"
            Protocol.Progress.jsont
            (set_member "reason" (Json.string "") retrying));
    ]

(* Command codec and constructor parity. *)

let command_codec_group =
  group "codec: commands"
    [
      test "every verb round-trips under its pinned tag and v" (fun () ->
          List.iter
            (fun (tag, command) ->
              let json = encode Protocol.Command.jsont command in
              assert_v_and_tag ~msg:tag tag json;
              equal command_value ~msg:(tag ^ ": round-trip") command
                (decode Protocol.Command.jsont json))
            all_commands);
      test "queue_next round-trips its client-minted id" (fun () ->
          (* The optional [id] member: present it survives the round trip
             (the delivery paths' idempotency key), absent it stays absent —
             the corpus entry above pins the id-less shape. *)
          let command =
            ok_or "queue_next with id"
              (Protocol.Command.queue_next
                 ~id:(Session.Queue.Id.of_string "q-derived")
                 ~session:fix_session_id
                 ~input:[ Llm.Content.text "Next." ]
                 ())
          in
          let json = encode Protocol.Command.jsont command in
          assert_v_and_tag ~msg:"queue_next with id" "queue_next" json;
          equal command_value ~msg:"queue_next with id: round-trip" command
            (decode Protocol.Command.jsont json));
      test "retired goal vocabulary is a loud decode error" (fun () ->
          (* Goals were retired outright: the tags never decode again, and a
             payload that carries them stops loading rather than being
             silently dropped. *)
          List.iter
            (fun tag ->
              assert_decode_error ("retired command tag " ^ tag)
                Protocol.Command.jsont
                (json_object
                   [
                     ("v", Json.int 1);
                     ("type", Json.string tag);
                     ("session", Json.string "session-c");
                     ("goal", Json.string "goal-c");
                   ]))
            [ "goal.pause"; "goal.edit"; "goal.resume"; "goal.clear" ];
          assert_decode_error "retired fact tag journal.goal"
            Protocol.Fact.jsont
            (json_object
               [
                 ("v", Json.int 1);
                 ("type", Json.string "journal.goal");
                 ( "update",
                   json_object
                     [
                       ("type", Json.string "declare");
                       ("id", Json.string "goal-c");
                       ("objective", Json.string "Chart everything");
                     ] );
               ]);
          List.iter
            (fun (tag, payload) ->
              assert_decode_error ("retired error tag " ^ tag)
                Protocol.Error.jsont
                (json_object
                   (("v", Json.int 1) :: ("type", Json.string tag) :: payload)))
            [
              ("goal_not_found", [ ("session", Json.string "session-c") ]);
              ("goal_is_not_current", [ ("goal", Json.string "goal-c") ]);
              ("goal_transition_not_allowed", [ ("goal", Json.string "goal-c") ]);
            ];
          let prompt =
            encode Protocol.Command.jsont (List.assoc "prompt" all_commands)
          in
          assert_decode_error "prompt with the retired goal member"
            Protocol.Command.jsont
            (add_member "goal"
               (json_object [ ("objective", Json.string "Port the parser") ])
               prompt));
      test "a prompt carries optional trigger provenance round-trip" (fun () ->
          (* Trigger provenance rides the prompt payload: the wire tag stays
             [prompt], the optional [triggered] member carries charter, digest,
             and key, and an absent member decodes as none — the
             backward-compatible codec addition. *)
          let with_triggered =
            ok_or "prompt.triggered"
              (Protocol.Command.prompt ~session:fix_session_id
                 ~turn:(turn_id "turn-trig")
                 ~input:[ Llm.Content.text "Review the diff." ]
                 ~triggered:
                   {
                     Protocol.Command.charter = "nightly-review";
                     digest = "0f9a4c1d2e3b4a5f";
                     key = "delivery-42";
                   }
                 ())
          in
          let json = encode Protocol.Command.jsont with_triggered in
          assert_v_and_tag ~msg:"prompt.triggered" "prompt" json;
          equal command_value ~msg:"prompt.triggered round-trip" with_triggered
            (decode Protocol.Command.jsont json);
          (* An empty member is rejected by the constructor. *)
          is_true ~msg:"empty triggered charter rejected"
            (Result.is_error
               (Protocol.Command.prompt ~session:fix_session_id
                  ~turn:(turn_id "turn-trig2")
                  ~input:[ Llm.Content.text "x" ]
                  ~triggered:
                    {
                      Protocol.Command.charter = "";
                      digest = "0f9a4c1d2e3b4a5f";
                      key = "delivery-42";
                    }
                  ())));
      test "every command targets exactly one session" (fun () ->
          List.iter
            (fun (tag, command) ->
              is_true ~msg:tag
                (Session.Id.equal fix_session_id
                   (Protocol.Command.session command)))
            all_commands);
      test "strict decode on the command envelope" (fun () ->
          let valid =
            encode Protocol.Command.jsont (List.assoc "prompt" all_commands)
          in
          assert_strict ~msg:"command" Protocol.Command.jsont valid);
      test "strict decode: a cross-arm member is an unknown member" (fun () ->
          let prompt =
            encode Protocol.Command.jsont (List.assoc "prompt" all_commands)
          in
          assert_decode_error "prompt with an interrupt reason"
            Protocol.Command.jsont
            (add_member "reason" (Json.string "stop") prompt);
          let interrupt =
            encode Protocol.Command.jsont (List.assoc "interrupt" all_commands)
          in
          assert_decode_error "interrupt with a turn member"
            Protocol.Command.jsont
            (add_member "turn" (Json.string "turn-x") interrupt));
    ]

let command_parity_group =
  (* Every locally-invalid command must be equally unconstructible via
     decode: the codec re-runs the constructors' validations, with the same
     message. *)
  let parity ~msg ~constructor ~tag ~corrupt =
    let message =
      match constructor () with
      | Error invalid -> Protocol.Command.Invalid.message invalid
      | Ok _ -> failf "%s: expected a constructor error" msg
    in
    let valid = encode Protocol.Command.jsont (List.assoc tag all_commands) in
    assert_decode_error ~contains:message (msg ^ ": decode parity")
      Protocol.Command.jsont (corrupt valid)
  in
  group "commands: constructor/decode validation parity"
    [
      test "prompt rejects an empty content list" (fun () ->
          parity ~msg:"empty prompt input"
            ~constructor:(fun () ->
              Protocol.Command.prompt ~session:fix_session_id
                ~turn:(turn_id "turn-cmd") ~input:[] ())
            ~tag:"prompt"
            ~corrupt:(set_member "input" (json_array [])));
      test "prompt rejects a non-positive step cap" (fun () ->
          parity ~msg:"max_steps 0"
            ~constructor:(fun () ->
              Protocol.Command.prompt ~session:fix_session_id
                ~turn:(turn_id "turn-cmd")
                ~input:[ Llm.Content.text "Go." ]
                ~max_steps:0 ())
            ~tag:"prompt"
            ~corrupt:(set_member "max_steps" (Json.int 0)));
      test "interrupt rejects an empty reason" (fun () ->
          parity ~msg:"empty reason"
            ~constructor:(fun () ->
              Protocol.Command.interrupt ~session:fix_session_id ~reason:"" ())
            ~tag:"interrupt"
            ~corrupt:(set_member "reason" (Json.string "")));
      test "queue_next rejects empty input" (fun () ->
          parity ~msg:"empty queue input"
            ~constructor:(fun () ->
              Protocol.Command.queue_next ~session:fix_session_id ~input:[] ())
            ~tag:"queue_next"
            ~corrupt:(set_member "input" (json_array [])));
      test "replace_queued rejects an empty replacement" (fun () ->
          (match
             Protocol.Command.replace_queued ~session:fix_session_id ~inputs:[]
           with
          | Error Protocol.Command.Invalid.Empty_queue_replacement -> ()
          | Error invalid ->
              failf "wrong empty-replacement error: %s"
                (Protocol.Command.Invalid.message invalid)
          | Ok _ -> fail "an empty replacement must be rejected structurally");
          parity ~msg:"empty replacement"
            ~constructor:(fun () ->
              Protocol.Command.replace_queued ~session:fix_session_id ~inputs:[])
            ~tag:"replace_queued"
            ~corrupt:(set_member "inputs" (json_array [])));
      test "replace_queued identifies an empty replacement entry" (fun () ->
          (match
             Protocol.Command.replace_queued ~session:fix_session_id
               ~inputs:[ [ Llm.Content.text "keep" ]; [] ]
           with
          | Error (Protocol.Command.Invalid.Empty_queue_entry 1) -> ()
          | Error invalid ->
              failf "wrong empty-entry error: %s"
                (Protocol.Command.Invalid.message invalid)
          | Ok _ -> fail "an empty entry must be rejected structurally");
          parity ~msg:"empty replacement entry"
            ~constructor:(fun () ->
              Protocol.Command.replace_queued ~session:fix_session_id
                ~inputs:[ [ Llm.Content.text "keep" ]; [] ])
            ~tag:"replace_queued"
            ~corrupt:
              (set_member "inputs"
                 (json_array
                    [
                      json_array
                        [ encode Llm.Content.jsont (Llm.Content.text "keep") ];
                      json_array [];
                    ])));
      test "prompt rejects an empty triggered member" (fun () ->
          parity ~msg:"empty triggered charter"
            ~constructor:(fun () ->
              Protocol.Command.prompt ~session:fix_session_id
                ~turn:(turn_id "turn-cmd")
                ~input:[ Llm.Content.text "Go." ]
                ~triggered:
                  {
                    Protocol.Command.charter = "";
                    digest = "0f9a4c1d2e3b4a5f";
                    key = "delivery-42";
                  }
                ())
            ~tag:"prompt"
            ~corrupt:
              (add_member "triggered"
                 (json_object
                    [
                      ("charter", Json.string "");
                      ("digest", Json.string "0f9a4c1d2e3b4a5f");
                      ("key", Json.string "delivery-42");
                    ])));
      prop "prompt accepts any positive step cap" (Gen.int_range 1 500)
        (fun max_steps ->
          match
            Protocol.Command.prompt ~session:fix_session_id
              ~turn:(turn_id "turn-cmd")
              ~input:[ Llm.Content.text "Go." ]
              ~max_steps ()
          with
          | Ok _ -> ()
          | Error _ -> fail "prompt rejected a positive step cap");
    ]

(* Error codec. *)

let error_codec_group =
  group "codec: errors"
    [
      test "every error arm round-trips under its pinned tag and v" (fun () ->
          List.iter
            (fun (tag, error) ->
              let json = encode Protocol.Error.jsont error in
              assert_v_and_tag ~msg:tag tag json;
              equal error_value ~msg:(tag ^ ": round-trip") error
                (decode Protocol.Error.jsont json))
            all_errors);
      test "strict decode on the error envelope" (fun () ->
          let valid =
            encode Protocol.Error.jsont (List.assoc "busy" all_errors)
          in
          assert_strict ~msg:"error" Protocol.Error.jsont valid);
      test "closed input errors reject payload members" (fun () ->
          let title =
            encode Protocol.Error.jsont Protocol.Error.Invalid_title
            |> add_member "title" (Json.string "")
          in
          let key =
            encode Protocol.Error.jsont Protocol.Error.Invalid_api_key
            |> add_member "key" (Json.string "secret")
          in
          assert_decode_error "invalid_title payload" Protocol.Error.jsont title;
          assert_decode_error "invalid_api_key payload" Protocol.Error.jsont key);
      test "busy carries an optional owner string, omitting it when absent"
        (fun () ->
          let no_owner =
            Protocol.Error.Busy { session = fix_session_id; owner = None }
          in
          let json = encode Protocol.Error.jsont no_owner in
          let members, _ = members_of json in
          is_true ~msg:"owner member omitted when None"
            (not
               (List.exists (fun ((n, _), _) -> String.equal n "owner") members));
          equal error_value ~msg:"no-owner round-trip" no_owner
            (decode Protocol.Error.jsont json));
      test "a not-in-feed invalid position round-trips whole" (fun () ->
          let j = journey () in
          let position = fst (List.hd (project_all j)) in
          let error =
            Protocol.Error.Invalid_position
              (Protocol.Position.Invalid.Not_in_feed position)
          in
          equal error_value ~msg:"not-in-feed round-trip" error
            (decode Protocol.Error.jsont (encode Protocol.Error.jsont error)));
      test "unavailable crosses the wire as its structured diagnostic"
        (fun () ->
          (* B7b: the diagnostic is preserved structurally — message, context,
             and hints — not merely as rendered text. *)
          let diagnostic =
            Mentat_diagnostic.make ~context:"during append"
              ~hints:[ "retry"; "check the lock" ]
              "store sealed"
          in
          match
            decode Protocol.Error.jsont
              (encode Protocol.Error.jsont
                 (Protocol.Error.Unavailable diagnostic))
          with
          | Protocol.Error.Unavailable decoded ->
              is_true ~msg:"structure preserved"
                (Mentat_diagnostic.equal diagnostic decoded)
          | _ -> fail "expected Unavailable");
      test "the unavailable constructor is total over dynamic text" (fun () ->
          (* A formatted lower-error or [Printexc.to_string] rendering may be
             multi-line or empty, which [Mentat_diagnostic.make] rejects;
             [unavailable] never raises, falling back and keeping the text. *)
          (match
             Protocol.Error.unavailable "boom\n  at frame 1\n  at frame 2"
           with
          | Protocol.Error.Unavailable d ->
              equal string ~msg:"first line becomes the message" "boom"
                (Mentat_diagnostic.message d)
          | _ -> fail "expected Unavailable");
          (match Protocol.Error.unavailable "\nleading newline trace" with
          | Protocol.Error.Unavailable d ->
              equal string ~msg:"blank first line falls back"
                "the operation is unavailable"
                (Mentat_diagnostic.message d)
          | _ -> fail "expected Unavailable");
          match Protocol.Error.unavailable "" with
          | Protocol.Error.Unavailable d ->
              equal string ~msg:"empty text falls back"
                "the operation is unavailable"
                (Mentat_diagnostic.message d)
          | _ -> fail "expected Unavailable");
      test "Error.equal composes the arm owners' equalities" (fun () ->
          List.iter
            (fun (tag, error) ->
              is_true ~msg:(tag ^ ": reflexive")
                (Protocol.Error.equal error error))
            all_errors;
          is_true ~msg:"busy owner distinguishes"
            (not
               (Protocol.Error.equal
                  (Protocol.Error.Busy
                     { session = fix_session_id; owner = Some "a" })
                  (Protocol.Error.Busy
                     { session = fix_session_id; owner = Some "b" })));
          is_true ~msg:"unavailable structure distinguishes"
            (not
               (Protocol.Error.equal
                  (Protocol.Error.Unavailable (Mentat_diagnostic.make "a"))
                  (Protocol.Error.Unavailable (Mentat_diagnostic.make "b"))));
          is_true ~msg:"different arms differ"
            (not
               (Protocol.Error.equal
                  (Protocol.Error.Session_not_found fix_session_id)
                  (Protocol.Error.Deleted fix_session_id))));
      test "every error renders a diagnostic" (fun () ->
          List.iter
            (fun (tag, error) ->
              is_true ~msg:tag
                (String.length
                   (Mentat_diagnostic.to_string
                      (Protocol.Error.diagnostic error))
                > 0))
            all_errors);
    ]

(* Position codec. *)

let position_group =
  group "codec: positions"
    [
      test "positions round-trip and compare by session and sequence" (fun () ->
          let j = journey () in
          let positions = List.map fst (project_all j) in
          List.iteri
            (fun i position ->
              equal position_value
                ~msg:(Printf.sprintf "position %d round-trips" i)
                position
                (decode Protocol.Position.jsont
                   (encode Protocol.Position.jsont position)))
            (take 5 positions);
          let first = List.hd positions in
          let second = List.nth positions 1 in
          is_true ~msg:"distinct positions differ"
            (not (Protocol.Position.equal first second)));
      test "decode rejects a negative sequence and unknown members" (fun () ->
          let j = journey () in
          let valid =
            encode Protocol.Position.jsont (fst (List.hd (project_all j)))
          in
          assert_decode_error ~contains:"non-negative" "negative seq"
            Protocol.Position.jsont
            (set_member "seq" (Json.int (-1)) valid);
          assert_decode_error "unknown member" Protocol.Position.jsont
            (add_member "host" (Json.string "mac") valid));
    ]

(* Bounded transcript reads: the tail view and backward pages carve a bounded
   sub-range of the one projection, so each page equals the matching slice of
   [Projection.all], a backward walk tiles the whole feed exactly once
   byte-identically, and [before]'s membership check is [Projection.after]'s. *)

let page_value =
  Testable.make ~pp:Protocol.Transcript.Page.pp
    ~equal:Protocol.Transcript.Page.equal

let tail_value =
  Testable.make ~pp:Protocol.Transcript.Tail.pp
    ~equal:Protocol.Transcript.Tail.equal

let transcript_array j = Array.of_list (project_all j)

let transcript_group =
  group "transcript: bounded reads over the one projection"
    [
      test "recent is the last n facts, oldest-first, with a backward cursor"
        (fun () ->
          let j = journey () in
          let full = project_all j in
          let arr = transcript_array j in
          let length = Array.length arr in
          let n = 5 in
          let page =
            Protocol.Transcript.Page.recent ~length ~get:(Array.get arr) ~n
          in
          equal (list projected_value) ~msg:"last n facts"
            (drop (length - n) full)
            page.Protocol.Transcript.Page.facts;
          match page.Protocol.Transcript.Page.before with
          | Some p ->
              equal position_value ~msg:"cursor is the first returned position"
                (fst (List.nth full (length - n)))
                p
          | None -> fail "expected a backward cursor below a full page");
      test "a page wider than the feed reaches the beginning with no cursor"
        (fun () ->
          let j = journey () in
          let full = project_all j in
          let arr = transcript_array j in
          let length = Array.length arr in
          let page =
            Protocol.Transcript.Page.recent ~length ~get:(Array.get arr)
              ~n:(length + 10)
          in
          equal (list projected_value) ~msg:"the whole feed" full
            page.Protocol.Transcript.Page.facts;
          equal (option position_value) ~msg:"no cursor at the beginning" None
            page.Protocol.Transcript.Page.before);
      test "before p is the n facts strictly before p, oldest-first" (fun () ->
          let j = journey () in
          let full = project_all j in
          let arr = transcript_array j in
          let length = Array.length arr in
          let owner = Session.id (full_session j) in
          let idx = 20 in
          let p = fst (List.nth full idx) in
          let n = 4 in
          match
            Protocol.Transcript.Page.before ~owner ~length ~get:(Array.get arr)
              p ~n
          with
          | Error invalid ->
              failf "unexpected invalid: %s"
                (Protocol.Position.Invalid.message invalid)
          | Ok page -> (
              equal (list projected_value) ~msg:"the n facts before p"
                (take n (drop (idx - n) full))
                page.Protocol.Transcript.Page.facts;
              match page.Protocol.Transcript.Page.before with
              | Some cursor ->
                  equal position_value ~msg:"cursor is the oldest in the page"
                    (fst (List.nth full (idx - n)))
                    cursor
              | None -> fail "expected a backward cursor"));
      test "chained backward pages tile the whole journal once, byte-identical"
        (fun () ->
          let j = journey () in
          let full = project_all j in
          let arr = transcript_array j in
          let length = Array.length arr in
          let owner = Session.id (full_session j) in
          let n = 4 in
          let rec walk before acc =
            let page =
              match before with
              | None ->
                  Protocol.Transcript.Page.recent ~length ~get:(Array.get arr)
                    ~n
              | Some p -> (
                  match
                    Protocol.Transcript.Page.before ~owner ~length
                      ~get:(Array.get arr) p ~n
                  with
                  | Ok page -> page
                  | Error invalid ->
                      failf "unexpected invalid: %s"
                        (Protocol.Position.Invalid.message invalid))
            in
            let acc = page.Protocol.Transcript.Page.facts @ acc in
            match page.Protocol.Transcript.Page.before with
            | None -> acc
            | Some _ as b -> walk b acc
          in
          let tiled = walk None [] in
          equal (list projected_value) ~msg:"tiled equals all" full tiled;
          equal (list string) ~msg:"byte-identical committed updates"
            (projected_bytes full) (projected_bytes tiled));
      test "before rejects a foreign, forged, or non-emitting position as after"
        (fun () ->
          let j = journey () in
          let full = project_all j in
          let arr = transcript_array j in
          let length = Array.length arr in
          let owner = Session.id (full_session j) in
          let session = full_session j in
          let mutation = full_mutation j in
          let via_before p =
            Protocol.Transcript.Page.before ~owner ~length ~get:(Array.get arr)
              p ~n:4
          in
          let via_after p = Protocol.Projection.after p ~session ~mutation in
          let same label p =
            match (via_before p, via_after p) with
            | Error a, Error b ->
                is_true
                  ~msg:(label ^ ": rejection matches after")
                  (Protocol.Position.Invalid.equal a b)
            | _ -> failf "%s: expected both reads to reject the position" label
          in
          let other_turn = turn ~id:"turn-o" () in
          let other_session =
            saved ~id:"other-session"
              [ Event.turn_started other_turn; finish other_turn ]
          in
          let foreign =
            fst
              (List.hd
                 (Protocol.Projection.all ~session:other_session
                    ~mutation:(mutation_state [])))
          in
          same "foreign" foreign;
          let last = fst (List.nth full (length - 1)) in
          let retarget seq =
            decode Protocol.Position.jsont
              (set_member "seq" (Json.int seq)
                 (encode Protocol.Position.jsont last))
          in
          same "forged past the head" (retarget 9999);
          same "non-emitting sequence" (retarget 1));
      test "tail head is the last position; its page is the recent page"
        (fun () ->
          let j = journey () in
          let full = project_all j in
          let arr = transcript_array j in
          let length = Array.length arr in
          let n = 6 in
          let pending = Some fix_decision in
          let tail =
            Protocol.Transcript.Tail.of_projection ~length ~get:(Array.get arr)
              ~n ~pending
          in
          equal (option position_value) ~msg:"head is the last position"
            (Some (fst (List.nth full (length - 1))))
            tail.Protocol.Transcript.Tail.head;
          equal page_value ~msg:"page is the recent page"
            (Protocol.Transcript.Page.recent ~length ~get:(Array.get arr) ~n)
            tail.Protocol.Transcript.Tail.page;
          is_true ~msg:"pending is threaded through"
            (Option.equal Session.Decision.Requested.equal pending
               tail.Protocol.Transcript.Tail.pending));
      test "an empty projection has no head and an empty page" (fun () ->
          let tail =
            Protocol.Transcript.Tail.of_projection ~length:0
              ~get:(fun _ -> assert false)
              ~n:10 ~pending:None
          in
          equal (option position_value) ~msg:"no head" None
            tail.Protocol.Transcript.Tail.head;
          equal (list projected_value) ~msg:"empty page" []
            tail.Protocol.Transcript.Tail.page.Protocol.Transcript.Page.facts);
      test "page and tail round-trip through their codecs" (fun () ->
          let j = journey () in
          let arr = transcript_array j in
          let length = Array.length arr in
          let n = 5 in
          let page =
            Protocol.Transcript.Page.recent ~length ~get:(Array.get arr) ~n
          in
          equal page_value ~msg:"page round-trips" page
            (decode Protocol.Transcript.Page.jsont
               (encode Protocol.Transcript.Page.jsont page));
          List.iter
            (fun pending ->
              let tail =
                Protocol.Transcript.Tail.of_projection ~length
                  ~get:(Array.get arr) ~n ~pending
              in
              equal tail_value ~msg:"tail round-trips" tail
                (decode Protocol.Transcript.Tail.jsont
                   (encode Protocol.Transcript.Tail.jsont tail)))
            [ None; Some fix_decision ]);
      test "transcript decode is strict about members and the envelope version"
        (fun () ->
          let j = journey () in
          let arr = transcript_array j in
          let length = Array.length arr in
          let page =
            Protocol.Transcript.Page.recent ~length ~get:(Array.get arr) ~n:3
          in
          let page_json = encode Protocol.Transcript.Page.jsont page in
          assert_decode_error "unknown page member"
            Protocol.Transcript.Page.jsont
            (add_member "extra" (Json.bool true) page_json);
          assert_decode_error ~contains:"version" "wrong page version"
            Protocol.Transcript.Page.jsont
            (set_member "v" (Json.int 2) page_json);
          let tail =
            Protocol.Transcript.Tail.of_projection ~length ~get:(Array.get arr)
              ~n:3 ~pending:(Some fix_decision)
          in
          let tail_json = encode Protocol.Transcript.Tail.jsont tail in
          assert_decode_error "unknown tail member"
            Protocol.Transcript.Tail.jsont
            (add_member "extra" (Json.bool true) tail_json);
          assert_decode_error ~contains:"version" "wrong tail version"
            Protocol.Transcript.Tail.jsont
            (set_member "v" (Json.int 2) tail_json));
    ]

(* The wire golden corpus: wire compatibility as a failing test. *)

(* The envelope carries a version [v] with strict decode, but the JSON shapes
   are produced by owner libraries' codecs — llm content, diff stats,
   permission requests, tool results, mutation evidence, decision payloads —
   composed into Fact/Command/Update/Progress/Error. An owner-codec change
   alters the wire silently: [v] never moves, so a deployed client breaks
   undetectably. This corpus pins one canonical JSON encoding per surface shape
   as a checked-in file under [wire-corpus/] and compares byte-for-byte; any
   drift fails, naming the rule. A [manifest.json] records the [v] the corpus
   was minted under and the shape inventory, so a version bump without
   regeneration — and regeneration without a bump — both fail, and an added or
   removed arm is caught. The corpus pins the wire for remote clients — a
   remote TUI or CLI attaching over the wire, and future programmatic SDKs;
   the server-rendered web UI consumes owner values in-process and never
   decodes wire JSON.

   The goldens are deterministic: every id in the fixtures is a content-derived
   digest, and no clock, pid, or randomness reaches the wire — so the same
   fixture encodes to the same bytes across runs and machines.

   Regenerate from the project root after an intentional wire change:
   [WIRE_CORPUS_DIR=$PWD/test/unit/wire-corpus WIRE_CORPUS_UPDATE=1 \
    dune exec --no-build -- ./test/unit/test_protocol.exe]. *)

let corpus_dir =
  (* [WIRE_CORPUS_DIR] overrides for regeneration — it must point at the source
     tree, never [_build]. Unset, default beside the executable: dune
     materializes [wire-corpus/*.json] there as a build dep, so the goldens are
     found under a bare [dune exec] and under the runtest sandbox alike. *)
  match Sys.getenv_opt "WIRE_CORPUS_DIR" with
  | Some dir -> dir
  | None -> Filename.concat (Filename.dirname Sys.executable_name) "wire-corpus"

let corpus_updating =
  match Sys.getenv_opt "WIRE_CORPUS_UPDATE" with
  | Some ("1" | "true") -> true
  | _ -> false

(* Stable, deterministic bytes: indented layout, the default number format, and
   one trailing newline so the files stay diff- and git-friendly. *)
let canonical codec value =
  match Jsont_bytesrw.encode_string ~format:Jsont.Indent codec value with
  | Ok bytes -> bytes ^ "\n"
  | Error message -> failf "canonical encode failed: %s" message

let canonical_json = canonical Jsont.json
let corpus_file name = Filename.concat corpus_dir (name ^ ".json")

let write_corpus name contents =
  Out_channel.with_open_bin (corpus_file name) (fun oc ->
      Out_channel.output_string oc contents)

let read_corpus name =
  let path = corpus_file name in
  if Sys.file_exists path then
    In_channel.with_open_bin path In_channel.input_all
  else
    failf
      "wire corpus file %s is missing — regenerate the corpus by running this \
       suite with WIRE_CORPUS_UPDATE=1 and WIRE_CORPUS_DIR set to \
       test/unit/wire-corpus"
      path

(* One canonical encoding per surface shape. The fact, progress, command, and
   error inventories reuse the per-arm fixture lists the codec suites already
   exercise; the update and position shapes use small journey-independent
   fixtures so a corpus entry never drifts because the canonical journey was
   edited. *)
let corpus_position = Protocol.Position.make ~session:fix_session_id ~seq:7

(* The transcript shapes: a backward page of two projected facts with a
   continuation, and a tail carrying the head, the pending decision, and that
   page. Journey-independent, so the goldens never drift with the canonical
   journey. *)
let corpus_projection =
  [
    ( Protocol.Position.make ~session:fix_session_id ~seq:2,
      Protocol.Fact.Turn_started fix_turn );
    ( Protocol.Position.make ~session:fix_session_id ~seq:5,
      Protocol.Fact.Turn_settled
        { turn = fix_turn_id; outcome = Session.Turn.Outcome.completed } );
  ]

let corpus_page =
  {
    Protocol.Transcript.Page.facts = corpus_projection;
    before = Some (Protocol.Position.make ~session:fix_session_id ~seq:1);
  }

let corpus_tail =
  {
    Protocol.Transcript.Tail.head =
      Some (Protocol.Position.make ~session:fix_session_id ~seq:5);
    pending = Some fix_decision;
    page = corpus_page;
  }

(* Variant goldens for the high-churn composed enums — permission answers,
   model-download phases, turn outcomes, and compaction reasons. A generated or
   remote decoder cannot check enum membership, so an owner renaming an enum tag
   inside a composed payload is exactly the drift the per-arm goldens miss: they
   pin one representative value per arm, not every tag. These pin the enum tags
   the base arms do not, so every wire enum tag of a high-churn enum has a
   golden somewhere in the corpus. *)
let answer_command answer =
  Protocol.Command.answer_decision ~session:fix_session_id
    ~decision:(Session.Decision.Requested.id fix_decision)
    ~answer:(Session.Decision.Answer.Permission { answer; message = None })

let download_variant phase =
  Protocol.Progress.Model_download
    {
      turn = fix_turn_id;
      update =
        {
          Protocol.Progress.Model_download.model = "gpt-oss-20b";
          received = 1_200_000_000L;
          total = Some 12_109_566_624L;
          phase;
        };
    }

let compaction_started_variant reason =
  Protocol.Progress.Compaction
    {
      turn = fix_turn_id;
      update = Protocol.Progress.Compaction.Started { reason };
    }

let turn_settled_variant outcome =
  Protocol.Fact.Turn_settled { turn = fix_turn_id; outcome }

let variant_shapes =
  [
    (* Permission answers: allow-once rides the base command.answer_decision;
       these pin deny, allow-exact-for-conversation, and allow-family. *)
    ( "command.answer_decision.deny",
      canonical Protocol.Command.jsont (answer_command Permission.Answer.deny)
    );
    ( "command.answer_decision.exact_for_conversation",
      canonical Protocol.Command.jsont
        (answer_command Permission.Answer.exact_for_conversation) );
    ( "command.answer_decision.family",
      canonical Protocol.Command.jsont
        (answer_command
           (Permission.Answer.family ~lifetime:Permission.Answer.User
              ~rules:
                [ Permission.Policy.Rule.allow Permission.Policy.Match.any ]))
    );
    (* Model-download phases: downloading rides the base arm. *)
    ( "progress.model.download.checking",
      canonical Protocol.Progress.jsont
        (download_variant Protocol.Progress.Model_download.Checking) );
    ( "progress.model.download.verifying",
      canonical Protocol.Progress.jsont
        (download_variant Protocol.Progress.Model_download.Verifying) );
    ( "progress.model.download.ready",
      canonical Protocol.Progress.jsont
        (download_variant Protocol.Progress.Model_download.Ready) );
    (* Turn origins: user rides the base fact.turn.started; triggered is the
       one origin whose payload is more than an id. *)
    ( "fact.turn.started.triggered",
      canonical Protocol.Fact.jsont
        (Protocol.Fact.Turn_started
           (turn ~id:"turn-c"
              ~origin:
                (Session.Turn.Origin.Triggered
                   {
                     charter = "nightly-review";
                     digest = "0f9a4c1d2e3b4a5f";
                     key = "delivery-42";
                   })
              ())) );
    (* Turn outcomes: completed rides the base fact.turn.finished. *)
    ( "fact.turn.finished.interrupted",
      canonical Protocol.Fact.jsont
        (turn_settled_variant
           (Session.Turn.Outcome.interrupted ~reason:"user stop" ~cancelled:true
              ())) );
    ( "fact.turn.finished.failed",
      canonical Protocol.Fact.jsont
        (turn_settled_variant
           (Session.Turn.Outcome.failed ~message:"authentication rejected")) );
    (* Compaction reasons: user-requested rides fact.compaction.installed and
       context-pressure rides the base progress.compaction.started. *)
    ( "progress.compaction.started.context_overflow",
      canonical Protocol.Progress.jsont
        (compaction_started_variant Session.Compaction.Reason.Context_overflow)
    );
    ( "progress.compaction.started.model_downshift",
      canonical Protocol.Progress.jsont
        (compaction_started_variant Session.Compaction.Reason.Model_downshift)
    );
  ]

let wire_shapes =
  List.concat
    [
      List.map
        (fun (tag, fact) -> ("fact." ^ tag, canonical Protocol.Fact.jsont fact))
        all_facts;
      List.map
        (fun (tag, pulse) ->
          ("progress." ^ tag, canonical Protocol.Progress.jsont pulse))
        all_progress;
      List.map
        (fun (tag, command) ->
          ("command." ^ tag, canonical Protocol.Command.jsont command))
        all_commands;
      List.map
        (fun (tag, error) ->
          ("error." ^ tag, canonical Protocol.Error.jsont error))
        all_errors;
      [
        ( "update.committed",
          canonical Protocol.Update.jsont
            (Protocol.Update.Committed
               {
                 position = corpus_position;
                 fact = Protocol.Fact.Turn_started fix_turn;
               }) );
        ( "update.progress",
          canonical Protocol.Update.jsont
            (Protocol.Update.Progress (List.assoc "model.usage" all_progress))
        );
        ("position.head", canonical Protocol.Position.jsont corpus_position);
        ("transcript.page", canonical Protocol.Transcript.Page.jsont corpus_page);
        ("transcript.tail", canonical Protocol.Transcript.Tail.jsont corpus_tail);
      ];
      variant_shapes;
    ]

(* The live envelope version, read from an actual encoding rather than an
   internal constant — the wire's own answer to "what is v". *)
let live_wire_version =
  match
    get_member "v"
      (encode Protocol.Fact.jsont (Protocol.Fact.Turn_started fix_turn))
  with
  | Jsont.Number (n, _) -> int_of_float n
  | _ -> fail "the fact envelope must carry an integer v member"

let corpus_manifest =
  json_object
    [
      ("wire_version", Json.int live_wire_version);
      ( "shapes",
        json_array
          (List.map
             (fun name -> Json.string name)
             (List.sort String.compare (List.map fst wire_shapes))) );
    ]

let shape_change_message name =
  Printf.sprintf
    "wire shape %S changed — bump Wire.v (lib/protocol/wire.mli) and \
     regenerate the corpus (WIRE_CORPUS_UPDATE=1), or revert the codec change"
    name

let wire_corpus_group =
  group "governance: the wire golden corpus"
    [
      test "the manifest tracks the wire version and the surface inventory"
        (fun () ->
          if corpus_updating then
            write_corpus "manifest" (canonical_json corpus_manifest);
          let stored = read_corpus "manifest" in
          let json =
            match Jsont_bytesrw.decode_string Jsont.json stored with
            | Ok json -> json
            | Error message -> failf "manifest is not valid JSON: %s" message
          in
          let stored_v =
            match get_member "wire_version" json with
            | Jsont.Number (n, _) -> int_of_float n
            | _ -> fail "manifest wire_version must be an integer"
          in
          equal int
            ~msg:
              (Printf.sprintf
                 "the wire corpus was minted under v=%d but the live envelope \
                  is v=%d — after an intentional version bump regenerate the \
                  corpus (WIRE_CORPUS_UPDATE=1); otherwise revert the change \
                  to Wire.version (lib/protocol/wire.mli)"
                 stored_v live_wire_version)
            live_wire_version stored_v;
          let stored_shapes =
            match get_member "shapes" json with
            | Jsont.Array (elements, _) ->
                List.map
                  (function
                    | Jsont.String (s, _) -> s
                    | _ -> fail "a manifest shape name must be a string")
                  elements
            | _ -> fail "manifest shapes must be an array"
          in
          equal (list string)
            ~msg:
              "the wire surface inventory changed — an arm was added or \
               removed; regenerate the corpus (WIRE_CORPUS_UPDATE=1) so the \
               manifest and shape files track the vocabulary"
            (List.sort String.compare (List.map fst wire_shapes))
            stored_shapes);
      (* Regeneration is one test, because it is one side effect over the whole
         inventory; the comparison below is one test per shape. *)
      test "regeneration rewrites every shape under WIRE_CORPUS_UPDATE"
        (fun () ->
          if corpus_updating then
            List.iter (fun (name, json) -> write_corpus name json) wire_shapes
          else skip ~reason:"WIRE_CORPUS_UPDATE is unset" ());
      (* One selectable test per shape: a drifted arm names itself in the
         report and the 71 shapes behind it still run, where a single
         [List.iter] stopped at the first and hid the blast radius of a codec
         change behind one failure. *)
      cases ~name:fst "every wire shape encodes byte-for-byte to its golden"
        wire_shapes (fun (name, json) ->
          equal string ~msg:(shape_change_message name) (read_corpus name) json);
    ]

(* User command codec. *)

let user_command_value =
  Testable.make
    ~pp:(fun ppf t ->
      Format.pp_print_string ppf
        (Protocol.User_command.Name.to_string t.Protocol.User_command.name))
    ~equal:(fun a b ->
      Json.equal
        (encode Protocol.User_command.jsont a)
        (encode Protocol.User_command.jsont b))

let user_command_name s = Result.get_ok (Protocol.User_command.Name.of_string s)

let user_command_samples =
  [
    {
      Protocol.User_command.name = user_command_name "review";
      description = Some "Review a PR";
      argument_hint = Some "<pr>";
      scope = Protocol.User_command.Project;
    };
    {
      Protocol.User_command.name = user_command_name "git:commit";
      description = None;
      argument_hint = None;
      scope = Protocol.User_command.User;
    };
  ]

let user_command_codec_group =
  group "codec: user commands"
    [
      test "every user command round-trips through jsont" (fun () ->
          List.iter
            (fun c ->
              equal user_command_value
                ~msg:
                  (Protocol.User_command.Name.to_string
                     c.Protocol.User_command.name)
                c
                (decode Protocol.User_command.jsont
                   (encode Protocol.User_command.jsont c)))
            user_command_samples);
      test "strict decode rejects an unknown member" (fun () ->
          assert_decode_error "user command unknown member"
            Protocol.User_command.jsont
            (add_member "mystery" (Json.bool true)
               (encode Protocol.User_command.jsont
                  (List.hd user_command_samples))));
      test "a malformed name is rejected on decode" (fun () ->
          assert_decode_error "user command name" Protocol.User_command.jsont
            (set_member "name" (Json.string "Bad Name")
               (encode Protocol.User_command.jsont
                  (List.hd user_command_samples))));
    ]

let () =
  run "mentat.protocol"
    [
      user_command_codec_group;
      projection_group;
      evidence_group;
      incremental_group;
      fact_codec_group;
      update_codec_group;
      progress_codec_group;
      command_codec_group;
      command_parity_group;
      error_codec_group;
      position_group;
      transcript_group;
      wire_corpus_group;
    ]
