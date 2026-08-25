(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Transcript = Mentat_llm.Transcript
module Policy = Mentat_permission.Policy
module Turn_map = Map.Make (Turn.Id)
module Provider_id_set = Set.Make (Provider_request.Id)
module Tool_claim_map = Map.Make (Tool_claim.Id)
module Decision_map = Map.Make (Decision.Id)
module Queue_id_set = Set.Make (Queue.Id)

(* The [Error] families below shadow these fact modules with error types of the
   same name; capture them first so the diagnostics can still reach the id
   printers. *)
module Session_turn = Turn
module Session_tool_claim = Tool_claim
module Session_decision = Decision
module Session_compaction = Compaction
module Session_delegation = Delegation
module Session_queue = Queue

module Error = struct
  module Undo = struct
    type t =
      | Active_turn of Turn.Id.t
      | Unknown_anchor of Turn.Id.t
      | Anchor_not_user of Turn.Id.t
      | Anchor_before_context of Turn.Id.t
  end

  module Turn = struct
    type t =
      | Active of Turn.Id.t
      | No_active
      | Duplicate of Turn.Id.t
      | Open_suspension of Turn.Id.t
      | Response_model_mismatch of {
          turn : Turn.Id.t;
          expected : Mentat_llm.Model.t;
          actual : Mentat_llm.Model.t;
        }
      | Interrupted of Turn.Id.t
      | Unknown_queue_entry of Queue.Id.t
      | Not_plan_build of Turn.Id.t
      | Plan_build_mismatch of Turn.Id.t
      | Unexpected_plan_build_input of Turn.Id.t
      | Unexpected_compaction_input of Turn.Id.t
      | Plan_approval_outcome of { turn : Turn.Id.t; outcome : Turn.Outcome.t }
  end

  module Provider = struct
    type t =
      | Duplicate of Provider_request.Id.t
      | Unknown of Provider_request.Id.t
      | Not_pending of Provider_request.Id.t
  end

  module Tool_claim = struct
    type t =
      | Duplicate of Tool_claim.Id.t
      | Unknown of Tool_claim.Id.t
      | Not_pending of Tool_claim.Id.t
      | Missing_prepare of Tool_claim.Id.t
      | Stage_mismatch of Tool_claim.Id.t
      | Illegal_sequence of Tool_claim.Id.t
      | Call_not_pending of { claim : Tool_claim.Id.t; call_id : string }
      | Result_mismatch of { claim : Tool_claim.Id.t; call_id : string }
  end

  module Decision = struct
    type t =
      | Duplicate of Decision.Id.t
      | Unknown of Decision.Id.t
      | Not_pending of Decision.Id.t
      | Resolve of Decision.Resolve_error.t
      | Call_not_pending of { decision : Decision.Id.t; call_id : string }
  end

  module Compaction = struct
    type t =
      | Bad_boundary of { summarized_upto : int; length : int }
      | Duplicate_key of { reason : Compaction.Reason.t }
      | Dropped_pending_call of { call_id : string }
  end

  module Delegation = struct
    type t =
      | Duplicate of Delegation.Id.t
      | Duplicate_child of Delegation.session_id
  end

  module Queue = struct
    type t = Duplicate of Queue.Id.t
  end

  type t =
    | Turn of Turn.t
    | Provider of Provider.t
    | Tool_claim of Tool_claim.t
    | Decision of Decision.t
    | Compaction of Compaction.t
    | Delegation of Delegation.t
    | Queue of Queue.t
    | Undo of Undo.t
    | Result_bypass of string
    | Transcript of Mentat_llm.Transcript.Error.t

  let turn_message = function
    | Turn.Active id ->
        Format.asprintf "turn is still active: %a" Session_turn.Id.pp id
    | Turn.No_active -> "no turn is active"
    | Turn.Duplicate id ->
        Format.asprintf "duplicate turn id: %a" Session_turn.Id.pp id
    | Turn.Open_suspension id ->
        Format.asprintf "turn has an open suspension: %a" Session_turn.Id.pp id
    | Turn.Response_model_mismatch { turn; expected; actual } ->
        Format.asprintf
          "response model does not match turn %a: expected %a, got %a"
          Session_turn.Id.pp turn Mentat_llm.Model.pp expected
          Mentat_llm.Model.pp actual
    | Turn.Interrupted id ->
        Format.asprintf "turn is interrupted, event inadmissible: %a"
          Session_turn.Id.pp id
    | Turn.Unknown_queue_entry id ->
        Format.asprintf "queued origin names unknown entry: %a"
          Session_queue.Id.pp id
    | Turn.Not_plan_build id ->
        Format.asprintf "plan-build turn without an approved plan: %a"
          Session_turn.Id.pp id
    | Turn.Plan_build_mismatch id ->
        Format.asprintf
          "plan-build turn input does not match the approved plan: %a"
          Session_turn.Id.pp id
    | Turn.Unexpected_plan_build_input id ->
        Format.asprintf "plan-build input used under a non-plan origin: %a"
          Session_turn.Id.pp id
    | Turn.Unexpected_compaction_input id ->
        Format.asprintf "compaction turn requires continue input: %a"
          Session_turn.Id.pp id
    | Turn.Plan_approval_outcome { turn; outcome } ->
        Format.asprintf
          "turn %a resolved a plan approval but settled with outcome %a"
          Session_turn.Id.pp turn Session_turn.Outcome.pp outcome

  let provider_message = function
    | Provider.Duplicate id ->
        Format.asprintf "duplicate provider claim id: %a" Provider_request.Id.pp
          id
    | Provider.Unknown id ->
        Format.asprintf "unknown provider claim: %a" Provider_request.Id.pp id
    | Provider.Not_pending id ->
        Format.asprintf "provider claim is not pending: %a"
          Provider_request.Id.pp id

  let tool_claim_message = function
    | Tool_claim.Duplicate id ->
        Format.asprintf "duplicate tool claim id: %a" Session_tool_claim.Id.pp
          id
    | Tool_claim.Unknown id ->
        Format.asprintf "unknown tool claim: %a" Session_tool_claim.Id.pp id
    | Tool_claim.Not_pending id ->
        Format.asprintf "tool claim is not pending: %a" Session_tool_claim.Id.pp
          id
    | Tool_claim.Missing_prepare id ->
        Format.asprintf "run claim has no prepared sibling: %a"
          Session_tool_claim.Id.pp id
    | Tool_claim.Stage_mismatch id ->
        Format.asprintf "settlement is incompatible with claim stage: %a"
          Session_tool_claim.Id.pp id
    | Tool_claim.Illegal_sequence id ->
        Format.asprintf "tool claim stage sequence is illegal for this call: %a"
          Session_tool_claim.Id.pp id
    | Tool_claim.Call_not_pending { claim; call_id } ->
        Format.asprintf "tool claim %a references non-pending call: %s"
          Session_tool_claim.Id.pp claim call_id
    | Tool_claim.Result_mismatch { claim; call_id } ->
        Format.asprintf "tool claim %a result does not answer call: %s"
          Session_tool_claim.Id.pp claim call_id

  let decision_message = function
    | Decision.Duplicate id ->
        Format.asprintf "duplicate decision id: %a" Session_decision.Id.pp id
    | Decision.Unknown id ->
        Format.asprintf "unknown decision: %a" Session_decision.Id.pp id
    | Decision.Not_pending id ->
        Format.asprintf "decision is not pending: %a" Session_decision.Id.pp id
    | Decision.Resolve error -> Session_decision.Resolve_error.message error
    | Decision.Call_not_pending { decision; call_id } ->
        Format.asprintf "decision %a references non-pending call: %s"
          Session_decision.Id.pp decision call_id

  let compaction_message = function
    | Compaction.Bad_boundary { summarized_upto; length } ->
        Format.asprintf "compaction boundary %d out of range [0,%d]"
          summarized_upto length
    | Compaction.Duplicate_key { reason } ->
        Format.asprintf "duplicate compaction key for reason %a"
          Session_compaction.Reason.pp reason
    | Compaction.Dropped_pending_call { call_id } ->
        Printf.sprintf
          "compaction would drop the opener of pending call %s from the model \
           view"
          call_id

  let delegation_message = function
    | Delegation.Duplicate id ->
        Format.asprintf "duplicate delegation id: %a" Session_delegation.Id.pp
          id
    | Delegation.Duplicate_child id ->
        Format.asprintf "delegation reuses an existing child session: %a" Id.pp
          id

  let queue_message = function
    | Queue.Duplicate id ->
        Format.asprintf "duplicate queue entry id: %a" Session_queue.Id.pp id

  let undo_message = function
    | Undo.Active_turn id ->
        Format.asprintf "undo requires an idle head, turn is active: %a"
          Session_turn.Id.pp id
    | Undo.Unknown_anchor id ->
        Format.asprintf "undo anchor names unknown turn: %a" Session_turn.Id.pp
          id
    | Undo.Anchor_not_user id ->
        Format.asprintf "undo anchor carries no user-authored input: %a"
          Session_turn.Id.pp
          id
    | Undo.Anchor_before_context id ->
        Format.asprintf "undo anchor is at or before the model-context head: %a"
          Session_turn.Id.pp id

  let message = function
    | Turn error -> turn_message error
    | Provider error -> provider_message error
    | Tool_claim error -> tool_claim_message error
    | Decision error -> decision_message error
    | Compaction error -> compaction_message error
    | Delegation error -> delegation_message error
    | Queue error -> queue_message error
    | Undo error -> undo_message error
    | Result_bypass call_id ->
        Printf.sprintf "tool result for %s bypasses an open claim or decision"
          call_id
    | Transcript error -> Transcript.Error.message error

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Replay_error = struct
  type t = { index : int; event : Event.t; cause : Error.t }

  let index t = t.index
  let event t = t.event
  let cause t = t.cause

  let shift ~by t =
    if by < 0 then invalid_arg "Mentat_session.State.Replay_error.shift";
    { t with index = t.index + by }

  let message t = Printf.sprintf "event %d: %s" t.index (Error.message t.cause)
  let pp ppf t = Format.pp_print_string ppf (message t)
end

(* Records. *)

type turn_record = {
  turn : Turn.t;
  outcome : Turn.Outcome.t option;
  response_count : int;
  final_text : string option;
  usage_total : int;
  first_message_index : int option;
      (* Absolute index in [full] of a [User] turn's appended user input, or
         [None] for a turn that appended none ([Continue] or a plan-build). An
         undo boundary anchors only at a turn carrying user-authored input, so
         its excluded suffix begins at this index. *)
}

(* The folded undo boundary: the armed record, or [None]. Latest-wins over the
   journal, exactly like the queue and compaction folds. A commit truncates the
   boundary events away, so a committed journal folds to [None]. *)
type undo = { anchor : Turn.Id.t; revert : string option }

type tool_claim_record = {
  claim_started : Tool_claim.Started.t;
  claim_settled : Tool_claim.Settled.t option;
}

type decision_record = {
  requested : Decision.Requested.t;
  resolved : Decision.Resolved.t option;
}

(* The one open suspension, exposed directly as the honest read. *)
type suspension =
  | Provider of Provider_request.Started.t
  | Tool of Tool_claim.Started.t
  | Decision of Decision.Requested.t

type t = {
  full : Transcript.t;
  latest_compaction : Compaction.t option;
  compaction_keys : (Mentat_digest.t * Compaction.Reason.t) list;
  last_usage : (Mentat_llm.Usage.t * int) option;
  turn_order_rev : Turn.Id.t list;
  turns : turn_record Turn_map.t;
  active_turn : Turn.Id.t option;
  interrupt : bool;
  (* [active_plan_approval] records the exact approval resolved by the active
     turn. [approved_plan] is set from it at [Turn_finished] so the next turn
     may consume that same value as [Input.Plan_build]. *)
  active_plan_approval : Plan.Approval.t option;
  approved_plan : Plan.Approval.t option;
  (* Absolute index in [full] where the current model context begins. A Fresh
     plan-build input advances it while retaining the earlier display history.
     Replay derives the boundary from the durable Turn_started event. *)
  model_context_start : int;
  (* Set when a provider claim settles [Ambiguous] (a crash between claim and
     response): the active turn may then only settle [Interrupted] and admits no
     further openers, exactly like an interrupt request. Reset per turn. *)
  provider_ambiguous : bool;
  (* Workspace observations recorded but not yet folded into the model
     transcript, in record order. What the model is shown is part of its
     durable transcript — bytes and position frozen the moment a request
     shows them — so these fold in as one ordinary user-role entry at the
     next request-ready seam (a user message cannot sit between a tool
     call and its result) and never reset: an observation a dying turn
     recorded is pending for the next request by construction. *)
  pending_notices : Notice.t list;
  (* Whether the active schema turn has whiffed a structured delivery since
     the last flush — the reminder pends exactly like a notice: shown by the
     next request's tail, frozen at its [Provider_requested], and cleared
     with the turn — a turn that dies unstated leaves no dangling
     imperative in history. *)
  pending_reminder : bool;
  suspension : suspension option;
  provider_ids : Provider_id_set.t;
  tool_claim_order_rev : Tool_claim.Id.t list;
  tool_claims : tool_claim_record Tool_claim_map.t;
  decisions : decision_record Decision_map.t;
  grants : Policy.Grants.t;
  permission_rules : Policy.Rule.t list;
  board : Task.Board.t;
  queue : Queue.Entry.t list;
  enqueued_ever : Queue_id_set.t;
      (* Every id ever [Enqueued], kept past consumption and clearing: an
         [Enqueued] fact is a durable delivery receipt, not queue membership. *)
  delegations_rev : Delegation.t list;
  undo : undo option;
}

let empty =
  {
    full = Transcript.empty;
    latest_compaction = None;
    compaction_keys = [];
    last_usage = None;
    turn_order_rev = [];
    turns = Turn_map.empty;
    active_turn = None;
    interrupt = false;
    active_plan_approval = None;
    approved_plan = None;
    model_context_start = 0;
    provider_ambiguous = false;
    pending_notices = [];
    pending_reminder = false;
    suspension = None;
    provider_ids = Provider_id_set.empty;
    tool_claim_order_rev = [];
    tool_claims = Tool_claim_map.empty;
    decisions = Decision_map.empty;
    grants = Policy.Grants.empty;
    permission_rules = [];
    board = Task.Board.empty;
    queue = [];
    enqueued_ever = Queue_id_set.empty;
    delegations_rev = [];
    undo = None;
  }

(* Derived transcripts. *)

let full_transcript t = t.full

(* The absolute index in [full] where the model view begins — the compaction
   retained-tail start when a compaction predates no later Fresh boundary, else
   the Fresh plan-build reset. An undo anchor's first message must lie at or
   after this head, so the armed suffix exclusion and the existing prefix/summary
   cut never overlap. *)
let model_view_head t =
  match t.latest_compaction with
  | Some compaction
    when Compaction.summarized_upto compaction > t.model_context_start ->
      Compaction.summarized_upto compaction
  | None | Some _ -> t.model_context_start

let turn_first_message_index id t =
  match Turn_map.find_opt id t.turns with
  | Some record -> record.first_message_index
  | None -> None

let can_undo_anchor id t =
  match turn_first_message_index id t with
  | Some index -> index >= model_view_head t
  | None -> false

(* The model-view rendering of workspace observations: one ordinary
   user-role entry per flushed batch, a stable header then each notice's
   facts as [- [severity] source: title] (plus body). Session-owned
   vocabulary, not a prompt: the entry is a projection of the durable
   {!Event.Workspace_notice} facts, and changing these bytes changes what
   replay claims the model was shown. *)
let rendered_notice notice =
  let severity =
    Format.asprintf "%a" Notice.Severity.pp (Notice.severity notice)
  in
  let body =
    match Notice.body notice with Some body -> "\n" ^ body | None -> ""
  in
  Printf.sprintf "- [%s] %s: %s%s" severity (Notice.source notice)
    (Notice.title notice) body

let notices_entry notices =
  Mentat_llm.Message.user_text
    ("Workspace notices:\n"
    ^ String.concat "\n" (List.map rendered_notice notices))

(* Fold the pending batch — the notices entry, then the whiff reminder —
   into the durable transcript. Two seams, and only two: an idle
   conversational append (so a batch pins before younger input, keeping
   event order) and [Provider_requested] (freezing exactly the bytes the
   request's tail ride just showed). Tool-result application deliberately
   does not flush — the tail ride carries the batch to the claim that pins
   it, and an eager pin under an open provider claim would land the entry
   before a response whose request never showed it. The appends can only
   be refused while tool calls await results, and flushes run only at
   request-ready seams, so a refusal is unreachable; leaving the batch
   pending on one keeps the projection total either way. *)
(* The structured-output reminder, pending like a notice after a schema
   whiff. Session-owned projection vocabulary, like the notices header:
   changing these bytes changes what replay claims the model was shown. *)
let structured_output_reminder =
  "You have not delivered the final answer yet. Call the \
   `structured_output` tool now with a value that matches its input \
   schema; that is the only way to complete this run."

let pending_entries t =
  (match t.pending_notices with
  | [] -> []
  | notices -> [ notices_entry notices ])
  @
  if t.pending_reminder then
    [ Mentat_llm.Message.user_text structured_output_reminder ]
  else []

let flush_pending_notices t =
  match pending_entries t with
  | [] -> t
  | entries when Transcript.is_ready t.full ->
      List.fold_left
        (fun t entry ->
          match Transcript.add entry t.full with
          | Ok full -> { t with full; pending_notices = []; pending_reminder = false }
          | Error _ -> t)
        t entries
  | _ -> t

let model_messages t =
  let msgs =
    match t.undo with
    | Some { anchor; _ } ->
        (* Exclude the armed suffix: keep only the messages before the anchor
           turn's own first message. Arming validated the index is present and
           at or after [model_view_head], so the cut below stays in the tail. *)
        let first =
          match turn_first_message_index anchor t with
          | Some index -> index
          | None -> Transcript.length t.full
        in
        List.take first (Transcript.messages t.full)
    | None -> Transcript.messages t.full
  in
  let msgs =
    match t.latest_compaction with
    | Some compaction
      when Compaction.summarized_upto compaction > t.model_context_start ->
        Compaction.summary_messages compaction
        @ List.drop (Compaction.summarized_upto compaction) msgs
    | None | Some _ -> List.drop t.model_context_start msgs
  in
  (* The still-open pending batch rides the tail so the request built before
     its freezing [Provider_requested] shows it; the flush then pins the same
     bytes at the same positions. *)
  match pending_entries t with
  | [] -> msgs
  | entries when Transcript.is_ready t.full -> msgs @ entries
  | _ -> msgs

(* Whether the model view currently carries the open pending batch at its
   tail — the one way the view is longer than the durable transcript. The
   compaction arithmetic must subtract it: the batch is not-yet-history,
   and the compaction claim's own freeze pins it after any cut. *)
let pending_entries_riding t =
  if Transcript.is_ready t.full then List.length (pending_entries t) else 0

let model_transcript t =
  match Transcript.of_list (model_messages t) with
  | Ok transcript -> transcript
  | Error _ ->
      (* Replay validates the derived model view is a valid transcript. *)
      assert false

let assistant_text assistant =
  Mentat_llm.Message.Assistant.texts assistant
  |> String.concat "\n" |> String.trim

let final_text t =
  let rec loop = function
    | [] -> None
    | Mentat_llm.Message.Assistant assistant :: rest ->
        let text = assistant_text assistant in
        if String.is_empty text then loop rest else Some text
    | ( Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
      | Mentat_llm.Message.User _ | Mentat_llm.Message.Tool_result _ )
      :: rest ->
        loop rest
  in
  loop (List.rev (Transcript.messages t.full))

let replay_usage t =
  Option.map
    (fun (usage, covered) -> (usage, List.drop covered (model_messages t)))
    t.last_usage

let latest_compaction t = t.latest_compaction
let undo t = t.undo

(* Turn accessors. *)

let active_turn_id t = t.active_turn

let active_turn t =
  Option.map (fun id -> (Turn_map.find id t.turns).turn) t.active_turn

let turns t =
  List.filter_map
    (fun id -> Option.map (fun r -> r.turn) (Turn_map.find_opt id t.turns))
    (List.rev t.turn_order_rev)

let turn id t = Option.map (fun r -> r.turn) (Turn_map.find_opt id t.turns)

let turn_outcome id t =
  Option.bind (Turn_map.find_opt id t.turns) (fun r -> r.outcome)

let turn_response_count id t =
  Option.map (fun r -> r.response_count) (Turn_map.find_opt id t.turns)

let turn_final_text id t =
  Option.bind (Turn_map.find_opt id t.turns) (fun r -> r.final_text)

let latest_model t =
  let turn_model id =
    Option.map
      (fun r -> Contract.model (Turn.contract r.turn))
      (Turn_map.find_opt id t.turns)
  in
  match t.active_turn with
  | Some id -> turn_model id
  | None -> (
      match t.turn_order_rev with [] -> None | id :: _ -> turn_model id)

let interrupt_requested t = t.interrupt
let approved_plan t = t.approved_plan
let grants t = t.grants
let permission_rules t = t.permission_rules
let tasks t = t.board
let pending_queue t = t.queue
let enqueue_recorded id t = Queue_id_set.mem id t.enqueued_ever
let delegations t = List.rev t.delegations_rev
let suspension t = t.suspension

let tool_claims t =
  List.filter_map
    (fun id ->
      Option.map
        (fun r -> (r.claim_started, r.claim_settled))
        (Tool_claim_map.find_opt id t.tool_claims))
    (List.rev t.tool_claim_order_rev)

let decision id t =
  Option.map
    (fun r -> (r.requested, r.resolved))
    (Decision_map.find_opt id t.decisions)

(* Error smart constructors. *)

let turn_error e = Error (Error.Turn e)
let provider_error e = Error (Error.Provider e)
let tool_claim_error e = Error (Error.Tool_claim e)
let decision_error e = Error (Error.Decision e)
let compaction_error e = Error (Error.Compaction e)
let delegation_error e = Error (Error.Delegation e)
let queue_error e = Error (Error.Queue e)
let undo_error e = Error (Error.Undo e)
let transcript_error e = Error (Error.Transcript e)

let pending_call t ~call_id =
  List.find_opt
    (fun call -> String.equal (Mentat_llm.Tool.Call.id call) call_id)
    (Transcript.pending t.full)

let require_active_turn t =
  match t.active_turn with
  | Some turn -> Ok turn
  | None -> turn_error Error.Turn.No_active

(* A suspension is only ever installed inside an active turn and cleared before
   the turn ends, so [suspension] implies [active_turn]; the turn id is read back
   from the suspension itself rather than trusting a separate [active_turn]. *)
let require_no_open_suspension t =
  match t.suspension with
  | None -> Ok ()
  | Some (Provider s) ->
      turn_error (Error.Turn.Open_suspension (Provider_request.Started.turn s))
  | Some (Tool s) ->
      turn_error (Error.Turn.Open_suspension (Tool_claim.Started.turn s))
  | Some (Decision d) ->
      turn_error (Error.Turn.Open_suspension (Decision.Requested.turn d))

let add_transcript message t =
  match Transcript.add message t.full with
  | Ok full -> Ok { t with full }
  | Error error -> transcript_error error

(* Turn lifecycle. *)

let apply_turn_started turn t =
  match t.active_turn with
  | Some active -> turn_error (Error.Turn.Active active)
  | None ->
      let id = Turn.id turn in
      if Turn_map.mem id t.turns then turn_error (Error.Turn.Duplicate id)
      else
        (* The user input a [User] turn is about to append lands at the current
           length; [handle_origin] never appends, so this is the pre-append
           index. Only a turn carrying user-authored input is an undo
           anchor. *)
        let first_message_index =
          match Turn.input turn with
          | Turn.Input.User _ -> Some (Transcript.length t.full)
          | Turn.Input.Continue | Turn.Input.Plan_build _ -> None
        in
        let handle_origin t =
          match (Turn.origin turn, Turn.input turn) with
          | Turn.Origin.Plan_build, Turn.Input.Plan_build approval -> (
              match t.approved_plan with
              | Some expected when Plan.Approval.equal expected approval -> Ok t
              | Some _ -> turn_error (Error.Turn.Plan_build_mismatch id)
              | None -> turn_error (Error.Turn.Not_plan_build id))
          | Turn.Origin.Plan_build, (Turn.Input.User _ | Turn.Input.Continue) ->
              turn_error (Error.Turn.Plan_build_mismatch id)
          | ( ( Turn.Origin.User | Turn.Origin.Queued _ | Turn.Origin.Triggered _
              | Turn.Origin.Compaction | Turn.Origin.Step_limit_wind_down ),
              Turn.Input.Plan_build _ ) ->
              turn_error (Error.Turn.Unexpected_plan_build_input id)
          | Turn.Origin.Compaction, Turn.Input.Continue -> Ok t
          | Turn.Origin.Compaction, Turn.Input.User _ ->
              turn_error (Error.Turn.Unexpected_compaction_input id)
          | Turn.Origin.Queued entry, (Turn.Input.User _ | Turn.Input.Continue)
            ->
              if
                List.exists
                  (fun e -> Queue.Id.equal (Queue.Entry.id e) entry)
                  t.queue
              then
                Ok
                  {
                    t with
                    queue =
                      List.filter
                        (fun e -> not (Queue.Id.equal (Queue.Entry.id e) entry))
                        t.queue;
                  }
              else turn_error (Error.Turn.Unknown_queue_entry entry)
          | ( ( Turn.Origin.User | Turn.Origin.Triggered _
              | Turn.Origin.Step_limit_wind_down ),
              (Turn.Input.User _ | Turn.Input.Continue) ) ->
              Ok t
        in
        let append_input t =
          match Turn.input turn with
          | Turn.Input.Continue -> Ok t
          | Turn.Input.User content ->
              add_transcript (Mentat_llm.Message.user content) t
          | Turn.Input.Plan_build approval -> (
              match Plan.Approval.context approval with
              | `Current -> Ok t
              | `Fresh ->
                  let model_context_start = Transcript.length t.full in
                  let text =
                    "Begin implementation in a fresh model context. Re-read "
                    ^ "files as needed.\n\n"
                    ^ Plan.Approval.to_model_text approval
                  in
                  add_transcript
                    (Mentat_llm.Message.user_text text)
                    { t with model_context_start; last_usage = None })
        in
        Result.bind (handle_origin t) (fun t ->
            Result.map
              (fun t ->
                {
                  t with
                  interrupt = false;
                  active_plan_approval = None;
                  approved_plan = None;
                  provider_ambiguous = false;
                  turn_order_rev = id :: t.turn_order_rev;
                  turns =
                    Turn_map.add id
                      {
                        turn;
                        outcome = None;
                        response_count = 0;
                        final_text = None;
                        usage_total = 0;
                        first_message_index;
                      }
                      t.turns;
                  active_turn = Some id;
                })
              (append_input t))

let apply_interrupt_requested ~turn t =
  match t.active_turn with
  | None -> turn_error Error.Turn.No_active
  | Some active when Turn.Id.equal active turn -> Ok { t with interrupt = true }
  | Some active -> turn_error (Error.Turn.Active active)

let apply_turn_finished ~turn ~outcome t =
  match t.active_turn with
  | None -> turn_error Error.Turn.No_active
  | Some active when not (Turn.Id.equal active turn) ->
      turn_error (Error.Turn.Active active)
  | Some _ -> (
      let interrupted_ok =
        (not (t.interrupt || t.provider_ambiguous))
        ||
        match outcome with
        | Turn.Outcome.Interrupted _ -> true
        | Turn.Outcome.Completed | Turn.Outcome.Step_limit
        | Turn.Outcome.Failed _ ->
            false
      in
      if not interrupted_ok then turn_error (Error.Turn.Interrupted turn)
      else if
        Option.is_some t.active_plan_approval
        && not (Turn.Outcome.equal outcome Turn.Outcome.completed)
      then turn_error (Error.Turn.Plan_approval_outcome { turn; outcome })
      else
        match require_no_open_suspension t with
        | Error _ as e -> e
        | Ok () -> (
            (* The contractual readiness check is on the model view the provider
               sees, not the full display transcript. The two agree because
               every pending call keeps its opener in the model view. *)
            match Transcript.require_ready (model_transcript t) with
            | Error error -> transcript_error error
            | Ok () ->
                let record = Turn_map.find turn t.turns in
                let queue =
                  match outcome with
                  | Turn.Outcome.Failed _ -> []
                  | Turn.Outcome.Completed | Turn.Outcome.Step_limit
                  | Turn.Outcome.Interrupted _ ->
                      t.queue
                in
                Ok
                  {
                    t with
                    turns =
                      Turn_map.add turn
                        { record with outcome = Some outcome }
                        t.turns;
                    active_turn = None;
                    interrupt = false;
                    provider_ambiguous = false;
                    (* A reminder is the dying turn's own imperative — it
                       must not survive into a turn whose contract may not
                       even declare the tool; pending notices do survive:
                       observations belong to the workspace, not the turn. *)
                    pending_reminder = false;
                    approved_plan = t.active_plan_approval;
                    queue;
                  }))

(* Transcript spine. *)

let apply_message_appended message t =
  match message with
  | Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
  | Mentat_llm.Message.User _ -> (
      match t.active_turn with
      | Some active -> turn_error (Error.Turn.Active active)
      | None -> add_transcript message (flush_pending_notices t))
  | Mentat_llm.Message.Tool_result result -> (
      (* A tool result that bypasses an open claim or decision — answering the
         call it holds — is rejected; the proper closer is [Tool_settled] or
         [Decision_resolved]. The one exception is the parked-decision interrupt
         closer: once the turn is interrupt-forced, a result answering the call
         a Decision suspension holds is the reconciliation answer for a parked
         ask — it is admitted and clears the suspension, terminally abandoning
         the decision with no [Decision_resolved] fact. A later resolution then
         finds the suspension gone and is [Not_pending]. Every other tool result
         is an ordinary append. *)
      match require_active_turn t with
      | Error _ as e -> e
      | Ok _ -> (
          let call_id = Mentat_llm.Tool.Result.call_id result in
          let interrupt_forced = t.interrupt || t.provider_ambiguous in
          match t.suspension with
          | Some (Decision d)
            when interrupt_forced
                 && String.equal (Decision.Requested.call_id d) call_id ->
              Result.map
                (fun t -> { t with suspension = None })
                (add_transcript message t)
          | Some (Tool s)
            when String.equal
                   (Mentat_llm.Tool.Call.id (Tool_claim.Started.call s))
                   call_id ->
              Error (Error.Result_bypass call_id)
          | Some (Decision d)
            when String.equal (Decision.Requested.call_id d) call_id ->
              Error (Error.Result_bypass call_id)
          | Some (Provider _) | Some (Tool _) | Some (Decision _) | None ->
              (* An errored result of the schema turn's own output tool is
                 the other whiff class: the payload did not conform. The
                 reminder pends the same way. *)
              let t =
                match t.active_turn with
                | Some active -> (
                    let record = Turn_map.find active t.turns in
                    match Contract.output_tool (Turn.contract record.turn) with
                    | Some output_tool
                      when String.equal
                             (Mentat_llm.Tool.Result.name result)
                             (Mentat_llm.Tool.name output_tool)
                           && Mentat_llm.Tool.Result.is_error result ->
                        { t with pending_reminder = true }
                    | Some _ | None -> t)
                | None -> t
              in
              add_transcript message t))
  (* [Event.message_appended] rejects assistant messages in the constructor and
     the decoder, so this never arises. *)
  | Mentat_llm.Message.Assistant _ -> assert false

(* Provider claims. *)

let apply_provider_requested started t =
  let t = flush_pending_notices t in
  let id = Provider_request.Started.id started in
  if Provider_id_set.mem id t.provider_ids then
    provider_error (Error.Provider.Duplicate id)
  else
    match require_active_turn t with
    | Error _ as e -> e
    | Ok _ -> (
        match require_no_open_suspension t with
        | Error _ as e -> e
        | Ok () ->
            Ok
              {
                t with
                suspension = Some (Provider started);
                provider_ids = Provider_id_set.add id t.provider_ids;
              })

let apply_provider_settled settled t =
  let id = Provider_request.Settled.id settled in
  match t.suspension with
  | Some (Provider started)
    when Provider_request.Id.equal (Provider_request.Started.id started) id -> (
      let commit t = Ok { t with suspension = None } in
      match Provider_request.Settled.outcome settled with
      | Provider_request.Settled.Ambiguous ->
          commit { t with provider_ambiguous = true }
      | Provider_request.Settled.Failed _ ->
          (* A known provider failure closes the claim and appends nothing; the
             outcome is proven, so — unlike [Ambiguous] — it forces no
             interrupt. The engine settles the turn [Failed] in the same
             suffix. *)
          commit t
      | Provider_request.Settled.Interrupted { text; _ } -> (
          match add_transcript (Mentat_llm.Message.assistant_text text) t with
          | Error _ as e -> e
          | Ok t -> commit t)
      | Provider_request.Settled.Responded response -> (
          let active = Option.get t.active_turn in
          let record_turn = Turn_map.find active t.turns in
          let expected = Contract.model (Turn.contract record_turn.turn) in
          let actual = Mentat_llm.Response.model response in
          if not (Mentat_llm.Model.equal actual expected) then
            turn_error
              (Error.Turn.Response_model_mismatch
                 { turn = active; expected; actual })
          else
            match Transcript.add_response response t.full with
            | Error error -> transcript_error error
            | Ok full ->
                (* A schema turn's response without a tool call whiffed the
                   delivery: the reminder pends — shown by the next
                   request's tail, frozen at its claim, gone with a turn
                   that dies before one. *)
                let pending_reminder =
                  t.pending_reminder
                  ||
                  match
                    Contract.output_tool (Turn.contract record_turn.turn)
                  with
                  | Some _ ->
                      not (Mentat_llm.Response.has_tool_calls response)
                  | None -> false
                in
                let t = { t with pending_reminder } in
                let text =
                  String.trim (Mentat_llm.Response.text ~sep:"\n" response)
                in
                let final_text =
                  if String.is_empty text then record_turn.final_text
                  else Some text
                in
                let usage_total =
                  match Mentat_llm.Response.usage response with
                  | None -> record_turn.usage_total
                  | Some usage ->
                      record_turn.usage_total + Mentat_llm.Usage.sum_lanes usage
                in
                let t = { t with full } in
                let last_usage =
                  match Mentat_llm.Response.usage response with
                  | None -> t.last_usage
                  | Some usage -> Some (usage, List.length (model_messages t))
                in
                commit
                  {
                    t with
                    last_usage;
                    turns =
                      Turn_map.add active
                        {
                          record_turn with
                          response_count = record_turn.response_count + 1;
                          final_text;
                          usage_total;
                        }
                        t.turns;
                  }))
  | Some (Provider _) | Some (Tool _) | Some (Decision _) | None ->
      if Provider_id_set.mem id t.provider_ids then
        provider_error (Error.Provider.Not_pending id)
      else provider_error (Error.Provider.Unknown id)

(* Tool claims. *)

let prepared_sibling t ~turn ~call_id =
  List.exists
    (fun id ->
      match Tool_claim_map.find_opt id t.tool_claims with
      | Some { claim_started; claim_settled = Some settled } -> (
          let call = Tool_claim.Started.call claim_started in
          Turn.Id.equal (Tool_claim.Started.turn claim_started) turn
          && String.equal (Mentat_llm.Tool.Call.id call) call_id
          && Mentat_tool.Stage.equal
               (Tool_claim.Started.stage claim_started)
               Mentat_tool.Stage.Prepare
          &&
          match Tool_claim.Settled.outcome settled with
          | Tool_claim.Settled.Prepared _ -> true
          | Tool_claim.Settled.Returned _ | Tool_claim.Settled.Ambiguous ->
              false)
      | Some _ | None -> false)
    t.tool_claim_order_rev

(* The stages already claimed for a given call in a turn, used to enforce the
   Direct-alone / Prepare-then-Run sequence discipline. *)
let claimed_stages t ~turn ~call_id =
  List.filter_map
    (fun claim_id ->
      match Tool_claim_map.find_opt claim_id t.tool_claims with
      | Some { claim_started; _ } ->
          let source = Tool_claim.Started.call claim_started in
          if
            Turn.Id.equal (Tool_claim.Started.turn claim_started) turn
            && String.equal (Mentat_llm.Tool.Call.id source) call_id
          then Some (Tool_claim.Started.stage claim_started)
          else None
      | None -> None)
    t.tool_claim_order_rev

let apply_tool_claimed started t =
  let id = Tool_claim.Started.id started in
  if Tool_claim_map.mem id t.tool_claims then
    tool_claim_error (Error.Tool_claim.Duplicate id)
  else
    match require_active_turn t with
    | Error _ as e -> e
    | Ok _ -> (
        match require_no_open_suspension t with
        | Error _ as e -> e
        | Ok () -> (
            let source = Tool_claim.Started.call started in
            let call_id = Mentat_llm.Tool.Call.id source in
            let turn = Tool_claim.Started.turn started in
            match pending_call t ~call_id with
            | None ->
                tool_claim_error
                  (Error.Tool_claim.Call_not_pending { claim = id; call_id })
            | Some call when not (Mentat_llm.Tool.Call.equal call source) ->
                (* The durable claim must retain the exact pending source call.
                   Besides id and name, this includes the original input and
                   provider continuity signature. *)
                tool_claim_error
                  (Error.Tool_claim.Call_not_pending { claim = id; call_id })
            | Some _ ->
                let stage = Tool_claim.Started.stage started in
                let existing = claimed_stages t ~turn ~call_id in
                (* Direct is the sole claim for a call; a Run may only follow a
                   Prepare. Any other stage already present is illegal. *)
                let sequence_ok =
                  match stage with
                  | Mentat_tool.Stage.Direct | Mentat_tool.Stage.Prepare ->
                      List.is_empty existing
                  | Mentat_tool.Stage.Run ->
                      List.for_all
                        (fun s ->
                          Mentat_tool.Stage.equal s Mentat_tool.Stage.Prepare)
                        existing
                in
                if not sequence_ok then
                  tool_claim_error (Error.Tool_claim.Illegal_sequence id)
                else
                  let stage_ok =
                    match stage with
                    | Mentat_tool.Stage.Run -> prepared_sibling t ~turn ~call_id
                    | Mentat_tool.Stage.Prepare | Mentat_tool.Stage.Direct ->
                        true
                  in
                  if not stage_ok then
                    tool_claim_error (Error.Tool_claim.Missing_prepare id)
                  else
                    Ok
                      {
                        t with
                        suspension = Some (Tool started);
                        tool_claim_order_rev = id :: t.tool_claim_order_rev;
                        tool_claims =
                          Tool_claim_map.add id
                            { claim_started = started; claim_settled = None }
                            t.tool_claims;
                      }))

let apply_tool_settled settled t =
  let id = Tool_claim.Settled.id settled in
  match t.suspension with
  | Some (Tool started)
    when Tool_claim.Id.equal (Tool_claim.Started.id started) id -> (
      let record = Tool_claim_map.find id t.tool_claims in
      let source = Tool_claim.Started.call started in
      let call_id = Mentat_llm.Tool.Call.id source in
      (* The settlement answers the claimed call only if that exact source call
         remains pending, including its continuity signature. *)
      let pending_source () =
        match pending_call t ~call_id with
        | Some call when Mentat_llm.Tool.Call.equal call source -> Some call
        | Some _ | None -> None
      in
      let commit ?full t =
        let full = Option.value full ~default:t.full in
        Ok
          {
            t with
            full;
            suspension = None;
            tool_claims =
              Tool_claim_map.add id
                { record with claim_settled = Some settled }
                t.tool_claims;
          }
      in
      match Tool_claim.Settled.outcome settled with
      | Tool_claim.Settled.Prepared _ -> (
          match Tool_claim.Started.stage started with
          | Mentat_tool.Stage.Prepare -> commit t
          | Mentat_tool.Stage.Run | Mentat_tool.Stage.Direct ->
              tool_claim_error (Error.Tool_claim.Stage_mismatch id))
      | Tool_claim.Settled.Returned result -> (
          match pending_source () with
          | None ->
              tool_claim_error
                (Error.Tool_claim.Result_mismatch { claim = id; call_id })
          | Some call -> (
              let lowered = Mentat_tool.Result.to_model ~call result in
              match
                Transcript.add (Mentat_llm.Message.tool_result lowered) t.full
              with
              | Error error -> transcript_error error
              | Ok full -> commit ~full t))
      | Tool_claim.Settled.Ambiguous -> (
          match pending_source () with
          | None ->
              tool_claim_error
                (Error.Tool_claim.Result_mismatch { claim = id; call_id })
          | Some call -> (
              let result =
                Mentat_llm.Tool.Result.text ~error:true call
                  "tool result ambiguous after crash recovery"
              in
              match
                Transcript.add (Mentat_llm.Message.tool_result result) t.full
              with
              | Error error -> transcript_error error
              | Ok full -> commit ~full t)))
  | Some (Provider _) | Some (Tool _) | Some (Decision _) | None ->
      if Tool_claim_map.mem id t.tool_claims then
        tool_claim_error (Error.Tool_claim.Not_pending id)
      else tool_claim_error (Error.Tool_claim.Unknown id)

(* Decisions. *)

let apply_decision_requested requested t =
  let id = Decision.Requested.id requested in
  if Decision_map.mem id t.decisions then
    decision_error (Error.Decision.Duplicate id)
  else
    match require_active_turn t with
    | Error _ as e -> e
    | Ok _ -> (
        match require_no_open_suspension t with
        | Error _ as e -> e
        | Ok () -> (
            let call_id = Decision.Requested.call_id requested in
            (* The decision must retain the exact pending call, or replay could
               authorize different input under the same call id and name. *)
            match pending_call t ~call_id with
            | Some call
              when Mentat_llm.Tool.Call.equal call
                     (Decision.Requested.call requested) ->
                Ok
                  {
                    t with
                    suspension = Some (Decision requested);
                    decisions =
                      Decision_map.add id
                        { requested; resolved = None }
                        t.decisions;
                  }
            | Some _ | None ->
                decision_error
                  (Error.Decision.Call_not_pending { decision = id; call_id })))

let reconstruct_grants requested answer t =
  match answer with
  | Decision.Answer.Permission
      {
        answer =
          Mentat_permission.Answer.Allow
            Mentat_permission.Answer.Exact_for_conversation;
        _;
      } -> (
      match Decision.Requested.request requested with
      | Decision.Request.Permission review ->
          (Policy.Review.remember review t.grants, t.permission_rules)
      | Decision.Request.Question _ | Decision.Request.Plan _ ->
          (t.grants, t.permission_rules))
  | Decision.Answer.Permission
      {
        answer =
          Mentat_permission.Answer.Allow
            (Mentat_permission.Answer.Family
               { lifetime = Mentat_permission.Answer.Conversation; rules });
        _;
      } ->
      let rules =
        List.fold_left
          (fun existing rule ->
            if List.exists (Policy.Rule.equal rule) existing then existing
            else existing @ [ rule ])
          t.permission_rules rules
      in
      (t.grants, rules)
  | Decision.Answer.Permission _ | Decision.Answer.Question _
  | Decision.Answer.Plan _ ->
      (t.grants, t.permission_rules)

let apply_decision_resolved resolved t =
  let id = Decision.Resolved.id resolved in
  match t.suspension with
  | Some (Decision requested) when Decision.matches requested resolved -> (
      let record = Decision_map.find id t.decisions in
      let answer = Decision.Resolved.answer resolved in
      let by = Decision.Resolved.answered_by resolved in
      let call_id = Decision.Requested.call_id requested in
      match pending_call t ~call_id with
      | None ->
          decision_error
            (Error.Decision.Call_not_pending { decision = id; call_id })
      | Some call -> (
          match Decision.resolve requested ~call ~by answer with
          | Error error -> decision_error (Error.Decision.Resolve error)
          | Ok (_, handling) -> (
              (* The exact approved value, not a boolean or its rendered text,
                 becomes the one-shot Build admission authority once this turn
                 settles. *)
              let active_plan_approval =
                match handling with
                | Decision.Proceed_plan approval -> Some approval
                | Decision.Proceed_permission | Decision.Consume _ ->
                    t.active_plan_approval
              in
              let commit ?full t =
                let full = Option.value full ~default:t.full in
                let grants, permission_rules =
                  reconstruct_grants requested answer t
                in
                Ok
                  {
                    t with
                    full;
                    suspension = None;
                    active_plan_approval;
                    grants;
                    permission_rules;
                    decisions =
                      Decision_map.add id
                        { record with resolved = Some resolved }
                        t.decisions;
                  }
              in
              match handling with
              | Decision.Proceed_permission -> commit t
              | Decision.Proceed_plan approval -> (
                  let result =
                    Mentat_llm.Tool.Result.text call
                      (Plan.Approval.to_model_text approval)
                  in
                  match
                    Transcript.add
                      (Mentat_llm.Message.tool_result result)
                      t.full
                  with
                  | Error error -> transcript_error error
                  | Ok full -> commit ~full t)
              | Decision.Consume result -> (
                  match
                    Transcript.add
                      (Mentat_llm.Message.tool_result result)
                      t.full
                  with
                  | Error error -> transcript_error error
                  | Ok full -> commit ~full t))))
  | Some (Provider _) | Some (Tool _) | Some (Decision _) | None ->
      if Decision_map.mem id t.decisions then
        decision_error (Error.Decision.Not_pending id)
      else decision_error (Error.Decision.Unknown id)

(* Compaction. *)

let apply_compaction_installed compaction t =
  (* The compaction is the honest-success closer of the summary call's provider
     claim: it must name the currently open provider suspension and clears it.
     A crash mid-summary leaves that claim open for ordinary ambiguous
     recovery. *)
  let claim = Compaction.provider_claim compaction in
  match t.suspension with
  | Some (Provider started)
    when Provider_request.Id.equal (Provider_request.Started.id started) claim
    -> (
      let length = Transcript.length t.full in
      let upto = Compaction.summarized_upto compaction in
      if upto > length then
        compaction_error
          (Error.Compaction.Bad_boundary { summarized_upto = upto; length })
      else
        let key =
          (Compaction.request_digest compaction, Compaction.reason compaction)
        in
        if
          List.exists
            (fun (digest, reason) ->
              Mentat_digest.equal digest (fst key)
              && Compaction.Reason.equal reason (snd key))
            t.compaction_keys
        then
          compaction_error
            (Error.Compaction.Duplicate_key
               { reason = Compaction.reason compaction })
        else
          let candidate = { t with latest_compaction = Some compaction } in
          match Transcript.of_list (model_messages candidate) with
          | Error error -> transcript_error error
          | Ok model -> (
              (* Every unanswered call in the full transcript must keep its
                 opening assistant message in the retained tail. A pending call
                 whose opener the summary dropped is simply absent — not
                 pending — in the model view; a later result for it would then
                 orphan the derived model view and make [model_transcript]
                 non-total. This is the weakest condition that keeps
                 [model_transcript] total: it admits a compaction installed
                 while a call is still pending, as long as its opener
                 survives. *)
              let model_pending =
                List.map Mentat_llm.Tool.Call.id (Transcript.pending model)
              in
              let orphaned =
                List.find_opt
                  (fun call ->
                    not (List.mem (Mentat_llm.Tool.Call.id call) model_pending))
                  (Transcript.pending t.full)
              in
              match orphaned with
              | Some call ->
                  compaction_error
                    (Error.Compaction.Dropped_pending_call
                       { call_id = Mentat_llm.Tool.Call.id call })
              | None ->
                  Ok
                    {
                      candidate with
                      compaction_keys = key :: t.compaction_keys;
                      last_usage = None;
                      suspension = None;
                    }))
  | Some (Provider _) | Some (Tool _) | Some (Decision _) | None ->
      if Provider_id_set.mem claim t.provider_ids then
        provider_error (Error.Provider.Not_pending claim)
      else provider_error (Error.Provider.Unknown claim)

(* Product vocabularies. *)

let apply_tasks_replaced board t = Ok { t with board }

let apply_delegation_recorded edge t =
  match require_active_turn t with
  | Error _ as e -> e
  | Ok active ->
      if not (Turn.Id.equal (Delegation.source_turn edge) active) then
        turn_error (Error.Turn.Active active)
      else
        let id = Delegation.id edge in
        let child = Delegation.child edge in
        if
          List.exists
            (fun e -> Delegation.Id.equal (Delegation.id e) id)
            t.delegations_rev
        then delegation_error (Error.Delegation.Duplicate id)
        else if
          List.exists
            (fun e -> Id.equal (Delegation.child e) child)
            t.delegations_rev
        then delegation_error (Error.Delegation.Duplicate_child child)
        else Ok { t with delegations_rev = edge :: t.delegations_rev }

let apply_delegations_detached t =
  match t.active_turn with
  | Some active -> turn_error (Error.Turn.Active active)
  | None -> Ok { t with delegations_rev = [] }

(* The pending queue never holds two entries with the same id: an [Enqueued]
   whose id is already pending is rejected, and a [Replaced] batch with an
   internal duplicate is rejected. A [Replaced] may reuse ids currently pending
   (it edits the whole queue); uniqueness is a property of the resulting queue,
   not of the id's whole history. *)
let apply_queue_updated update t =
  match update with
  | Queue.Update.Enqueued entry ->
      let id = Queue.Entry.id entry in
      if List.exists (fun e -> Queue.Id.equal (Queue.Entry.id e) id) t.queue
      then queue_error (Error.Queue.Duplicate id)
      else
        Ok
          {
            t with
            queue = t.queue @ [ entry ];
            enqueued_ever = Queue_id_set.add id t.enqueued_ever;
          }
  | Queue.Update.Replaced entries -> (
      let rec first_duplicate seen = function
        | [] -> None
        | entry :: rest ->
            let id = Queue.Entry.id entry in
            if List.exists (Queue.Id.equal id) seen then Some id
            else first_duplicate (id :: seen) rest
      in
      match first_duplicate [] entries with
      | Some id -> queue_error (Error.Queue.Duplicate id)
      | None -> Ok { t with queue = entries })
  | Queue.Update.Cleared -> Ok { t with queue = [] }

(* A workspace observation is admitted only while a turn is active — the
   drain runs under one — but what it records is the workspace's, not the
   turn's: it pends until a request states it, across turn boundaries if
   need be. *)
let apply_workspace_notice notice t =
  match require_active_turn t with
  | Error _ as e -> e
  | Ok _ -> Ok { t with pending_notices = t.pending_notices @ [ notice ] }

(* The undo boundary is a suffix cut over the model view, so arming is admitted
   only at an idle head and only at a finished turn carrying user-authored
   input whose first message is at or after the model-context head — then the
   excluded suffix stays inside the live tail and never overlaps the
   compaction/prefix cut. A [Released] update clears the boundary
   unconditionally. Latest-wins. *)
let apply_undo_updated update t =
  match (update : Undo.Update.t) with
  | Undo.Update.Released -> Ok { t with undo = None }
  | Undo.Update.Armed { anchor; revert } -> (
      match t.active_turn with
      | Some active -> undo_error (Error.Undo.Active_turn active)
      | None -> (
          match Turn_map.find_opt anchor t.turns with
          | None -> undo_error (Error.Undo.Unknown_anchor anchor)
          | Some record -> (
              match record.first_message_index with
              | None -> undo_error (Error.Undo.Anchor_not_user anchor)
              | Some index ->
                  if index < model_view_head t then
                    undo_error (Error.Undo.Anchor_before_context anchor)
                  else Ok { t with undo = Some { anchor; revert } })))

(* Dispatch. *)

let apply_step event t =
  match event with
  | Event.Turn_started turn -> apply_turn_started turn t
  | Event.Interrupt_requested { turn; _ } -> apply_interrupt_requested ~turn t
  | Event.Turn_finished { turn; outcome } ->
      apply_turn_finished ~turn ~outcome t
  | Event.Message_appended message -> apply_message_appended message t
  | Event.Provider_requested started -> apply_provider_requested started t
  | Event.Provider_settled settled -> apply_provider_settled settled t
  | Event.Tool_claimed started -> apply_tool_claimed started t
  | Event.Tool_settled settled -> apply_tool_settled settled t
  | Event.Decision_requested requested -> apply_decision_requested requested t
  | Event.Decision_resolved resolved -> apply_decision_resolved resolved t
  | Event.Compaction_installed compaction ->
      apply_compaction_installed compaction t
  | Event.Tasks_replaced board -> apply_tasks_replaced board t
  | Event.Delegation_recorded edge -> apply_delegation_recorded edge t
  | Event.Delegations_detached -> apply_delegations_detached t
  | Event.Queue_updated update -> apply_queue_updated update t
  | Event.Workspace_notice notice -> apply_workspace_notice notice t
  | Event.Undo_updated update -> apply_undo_updated update t

(* Once the active turn is interrupt-forced — an [Interrupt_requested] or an
   [Ambiguous] provider settlement — only settlements, an interrupted terminal
   outcome, a repeated interrupt request, and reconciliation tool results are
   admissible; every opener is rejected. Reconciliation results are the
   synthesized answers to never-claimed sibling calls the live engine appends;
   the bypass guard in [apply_message_appended] still rejects a tool result that
   answers the very call the open suspension holds. *)
let interrupt_admits = function
  | Event.Provider_settled _ | Event.Tool_settled _ | Event.Decision_resolved _
  | Event.Turn_finished _ | Event.Interrupt_requested _ ->
      true
  | Event.Message_appended (Mentat_llm.Message.Tool_result _) -> true
  | Event.Message_appended
      ( Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
      | Mentat_llm.Message.User _ | Mentat_llm.Message.Assistant _ ) ->
      false
  | Event.Turn_started _ | Event.Provider_requested _ | Event.Tool_claimed _
  | Event.Decision_requested _ | Event.Compaction_installed _
  | Event.Tasks_replaced _ | Event.Delegation_recorded _
  | Event.Delegations_detached | Event.Queue_updated _
  | Event.Workspace_notice _ | Event.Undo_updated _ ->
      false

let apply event t =
  match t.active_turn with
  | Some turn
    when (t.interrupt || t.provider_ambiguous) && not (interrupt_admits event)
    ->
      turn_error (Error.Turn.Interrupted turn)
  | Some _ | None -> apply_step event t

let apply_all events t =
  let rec loop index t = function
    | [] -> Ok t
    | event :: events -> (
        match apply event t with
        | Error cause -> Error { Replay_error.index; event; cause }
        | Ok t -> loop (index + 1) t events)
  in
  loop 0 t events

let of_events events = apply_all events empty
