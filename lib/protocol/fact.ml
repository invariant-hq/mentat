(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

(* The turn/tool/decision/journal families are a presentational grouping; the
   type is one flat sum of uniquely-named constructors, so the
   turn and tool [Started] arms never collide and every match is one level
   deep. The dotted wire tags are the grouping's only durable trace. *)

type evidence = {
  changes : Mentat_mutation.Change.t list;
  observed : Mentat_workspace.Path.t list;
  totals : Textdiff.stats;
  revertability : Mentat_mutation.Revertability.t;
}

let evidence_equal a b =
  List.equal Mentat_mutation.Change.equal a.changes b.changes
  && List.equal Mentat_workspace.Path.equal a.observed b.observed
  && Textdiff.Stats.equal a.totals b.totals
  && Mentat_mutation.Revertability.equal a.revertability b.revertability

type undo_file = {
  path : Mentat_workspace.Path.t;
  additions : int;
  deletions : int;
}

let undo_file_equal a b =
  Mentat_workspace.Path.equal a.path b.path
  && Int.equal a.additions b.additions
  && Int.equal a.deletions b.deletions

type t =
  | Turn_started of Mentat_session.Turn.t
  | Turn_assistant of Mentat_llm.Response.t
  | Turn_assistant_interrupted of { text : string }
  | Turn_provider_failed of {
      claim : Mentat_session.Provider_request.Id.t;
      error : Mentat_llm.Error.t;
    }
  | Turn_message of Mentat_llm.Message.t
  | Turn_settled of {
      turn : Mentat_session.Turn.Id.t;
      outcome : Mentat_session.Turn.Outcome.t;
    }
  | Tool_started of Mentat_session.Tool_claim.Started.t
  | Tool_prepared of {
      claim : Mentat_session.Tool_claim.Id.t;
      description : string;
      requests : Mentat_permission.Request.t list;
    }
  | Tool_returned of {
      claim : Mentat_session.Tool_claim.Id.t;
      result : Mentat_tool.Output.t Mentat_tool.Result.t;
      mutation : evidence option;
    }
  | Tool_ambiguous of {
      claim : Mentat_session.Tool_claim.Id.t;
      mutation : evidence option;
    }
  | Decision_requested of Mentat_session.Decision.Requested.t
  | Decision_resolved of Mentat_session.Decision.Resolved.t
  | Journal_task_board of Mentat_session.Task.Board.t
  | Journal_delegation of Mentat_session.Delegation.t
  | Journal_queue of Mentat_session.Queue.Update.t
  | Compaction of Mentat_session.Compaction.t
  | Workspace_notice of Mentat_session.Notice.t
  | Undo of {
      update : Mentat_session.Undo.Update.t;
      dropped_turns : int;
      files : undo_file list;
    }

let equal a b =
  match (a, b) with
  | Turn_started a, Turn_started b -> Mentat_session.Turn.equal a b
  | Turn_assistant a, Turn_assistant b -> Mentat_llm.Response.equal a b
  | ( Turn_assistant_interrupted { text = a },
      Turn_assistant_interrupted { text = b } ) ->
      String.equal a b
  | Turn_provider_failed a, Turn_provider_failed b ->
      Mentat_session.Provider_request.Id.equal a.claim b.claim
      && Mentat_llm.Error.equal a.error b.error
  | Turn_message a, Turn_message b -> Mentat_llm.Message.equal a b
  | Turn_settled a, Turn_settled b ->
      Mentat_session.Turn.Id.equal a.turn b.turn
      && Mentat_session.Turn.Outcome.equal a.outcome b.outcome
  | Tool_started a, Tool_started b ->
      Mentat_session.Tool_claim.Started.equal a b
  | Tool_prepared a, Tool_prepared b ->
      Mentat_session.Tool_claim.Id.equal a.claim b.claim
      && String.equal a.description b.description
      && List.equal Mentat_permission.Request.equal a.requests b.requests
  | Tool_returned a, Tool_returned b ->
      Mentat_session.Tool_claim.Id.equal a.claim b.claim
      && Mentat_tool.Result.equal Mentat_tool.Output.equal a.result b.result
      && Option.equal evidence_equal a.mutation b.mutation
  | Tool_ambiguous a, Tool_ambiguous b ->
      Mentat_session.Tool_claim.Id.equal a.claim b.claim
      && Option.equal evidence_equal a.mutation b.mutation
  | Decision_requested a, Decision_requested b ->
      Mentat_session.Decision.Requested.equal a b
  | Decision_resolved a, Decision_resolved b ->
      Mentat_session.Decision.Resolved.equal a b
  | Journal_task_board a, Journal_task_board b ->
      Mentat_session.Task.Board.equal a b
  | Journal_delegation a, Journal_delegation b ->
      Mentat_session.Delegation.equal a b
  | Journal_queue a, Journal_queue b -> Mentat_session.Queue.Update.equal a b
  | Compaction a, Compaction b -> Mentat_session.Compaction.equal a b
  | Workspace_notice a, Workspace_notice b -> Mentat_session.Notice.equal a b
  | Undo a, Undo b ->
      Mentat_session.Undo.Update.equal a.update b.update
      && Int.equal a.dropped_turns b.dropped_turns
      && List.equal undo_file_equal a.files b.files
  | ( ( Turn_started _ | Turn_assistant _ | Turn_assistant_interrupted _
      | Turn_provider_failed _ | Turn_message _ | Turn_settled _
      | Tool_started _ | Tool_prepared _ | Tool_returned _ | Tool_ambiguous _
      | Decision_requested _ | Decision_resolved _ | Journal_task_board _
      | Journal_delegation _ | Journal_queue _ | Compaction _
      | Workspace_notice _ | Undo _ ),
      _ ) ->
      false

let pp ppf t =
  let tag name = Format.pp_print_string ppf name in
  let tagged name pp_id id = Format.fprintf ppf "%s(%a)" name pp_id id in
  match t with
  | Turn_started turn ->
      tagged "turn.started" Mentat_session.Turn.Id.pp
        (Mentat_session.Turn.id turn)
  | Turn_assistant _ -> tag "turn.assistant"
  | Turn_assistant_interrupted _ -> tag "turn.assistant_interrupted"
  | Turn_provider_failed { claim; _ } ->
      tagged "turn.provider_failed" Mentat_session.Provider_request.Id.pp claim
  | Turn_message _ -> tag "turn.message"
  | Turn_settled { turn; _ } ->
      tagged "turn.finished" Mentat_session.Turn.Id.pp turn
  | Tool_started started ->
      tagged "tool.started" Mentat_session.Tool_claim.Id.pp
        (Mentat_session.Tool_claim.Started.id started)
  | Tool_prepared { claim; _ } ->
      tagged "tool.prepared" Mentat_session.Tool_claim.Id.pp claim
  | Tool_returned { claim; _ } ->
      tagged "tool.returned" Mentat_session.Tool_claim.Id.pp claim
  | Tool_ambiguous { claim; _ } ->
      tagged "tool.ambiguous" Mentat_session.Tool_claim.Id.pp claim
  | Decision_requested request ->
      tagged "decision.requested" Mentat_session.Decision.Id.pp
        (Mentat_session.Decision.Requested.id request)
  | Decision_resolved resolution ->
      tagged "decision.resolved" Mentat_session.Decision.Id.pp
        (Mentat_session.Decision.Resolved.id resolution)
  | Journal_task_board _ -> tag "journal.tasks"
  | Journal_delegation _ -> tag "journal.delegation"
  | Journal_queue _ -> tag "journal.queue"
  | Compaction _ -> tag "compaction.installed"
  | Workspace_notice _ -> tag "workspace.notice"
  | Undo { update; _ } ->
      Format.fprintf ppf "undo.updated(%a)" Mentat_session.Undo.Update.pp update

let evidence_jsont =
  let make changes observed totals revertability =
    if List.is_empty changes && List.is_empty observed then
      decode_error
        "mutation evidence must carry at least one change or observation";
    { changes; observed; totals; revertability }
  in
  Jsont.Object.map ~kind:"mutation evidence" make
  |> Jsont.Object.mem "changes" (Jsont.list Mentat_mutation.Change.jsont)
       ~enc:(fun e -> e.changes)
  |> Jsont.Object.mem "observed" (Jsont.list Mentat_workspace.Path.jsont)
       ~enc:(fun e -> e.observed)
  |> Jsont.Object.mem "totals" Textdiff.Stats.jsont ~enc:(fun e -> e.totals)
  |> Jsont.Object.mem "revertability" Mentat_mutation.Revertability.jsont
       ~enc:(fun e -> e.revertability)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let undo_file_jsont =
  Jsont.Object.map ~kind:"undo file" (fun path additions deletions ->
      { path; additions; deletions })
  |> Jsont.Object.mem "path" Mentat_workspace.Path.jsont ~enc:(fun f -> f.path)
  |> Jsont.Object.mem "additions" Jsont.int ~enc:(fun f -> f.additions)
  |> Jsont.Object.mem "deletions" Jsont.int ~enc:(fun f -> f.deletions)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let jsont =
  let single kind tag mem_name value inj proj =
    Jsont.Object.map ~kind inj
    |> Jsont.Object.mem mem_name value ~enc:proj
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let turn_started_case =
    single "turn-started fact" "turn.started" "turn" Mentat_session.Turn.jsont
      (fun turn -> Turn_started turn)
      (function Turn_started turn -> turn | _ -> assert false)
  in
  let turn_assistant_case =
    single "turn-assistant fact" "turn.assistant" "response"
      Mentat_llm.Response.jsont
      (fun response -> Turn_assistant response)
      (function Turn_assistant response -> response | _ -> assert false)
  in
  let turn_assistant_interrupted_case =
    Jsont.Object.map ~kind:"turn-assistant-interrupted fact" (fun text ->
        if String.is_empty text then
          decode_error "interrupted assistant text must not be empty";
        Turn_assistant_interrupted { text })
    |> Jsont.Object.mem "text" Jsont.string ~enc:(function
      | Turn_assistant_interrupted { text } -> text
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "turn.assistant_interrupted" ~dec:Fun.id
  in
  let turn_provider_failed_case =
    Jsont.Object.map ~kind:"turn-provider-failed fact" (fun claim error ->
        Turn_provider_failed { claim; error })
    |> Jsont.Object.mem "claim" Mentat_session.Provider_request.Id.jsont
         ~enc:(function
         | Turn_provider_failed { claim; _ } -> claim
         | _ -> assert false)
    |> Jsont.Object.mem "error" Mentat_llm.Error.jsont ~enc:(function
      | Turn_provider_failed { error; _ } -> error
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "turn.provider_failed" ~dec:Fun.id
  in
  let turn_message_case =
    single "turn-message fact" "turn.message" "message" Mentat_llm.Message.jsont
      (fun message -> Turn_message message)
      (function Turn_message message -> message | _ -> assert false)
  in
  let turn_finished_case =
    Jsont.Object.map ~kind:"turn-finished fact" (fun turn outcome ->
        Turn_settled { turn; outcome })
    |> Jsont.Object.mem "turn" Mentat_session.Turn.Id.jsont ~enc:(function
      | Turn_settled { turn; _ } -> turn
      | _ -> assert false)
    |> Jsont.Object.mem "outcome" Mentat_session.Turn.Outcome.jsont
         ~enc:(function
         | Turn_settled { outcome; _ } -> outcome
         | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "turn.finished" ~dec:Fun.id
  in
  let tool_started_case =
    single "tool-started fact" "tool.started" "claim"
      Mentat_session.Tool_claim.Started.jsont
      (fun claim -> Tool_started claim)
      (function Tool_started claim -> claim | _ -> assert false)
  in
  let tool_prepared_case =
    Jsont.Object.map ~kind:"tool-prepared fact"
      (fun claim description requests ->
        Tool_prepared { claim; description; requests })
    |> Jsont.Object.mem "claim" Mentat_session.Tool_claim.Id.jsont
         ~enc:(function
         | Tool_prepared { claim; _ } -> claim
         | _ -> assert false)
    |> Jsont.Object.mem "description" Jsont.string ~enc:(function
      | Tool_prepared { description; _ } -> description
      | _ -> assert false)
    |> Jsont.Object.mem "requests" (Jsont.list Mentat_permission.Request.jsont)
         ~enc:(function
         | Tool_prepared { requests; _ } -> requests
         | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "tool.prepared" ~dec:Fun.id
  in
  let tool_returned_case =
    Jsont.Object.map ~kind:"tool-returned fact" (fun claim result mutation ->
        Tool_returned { claim; result; mutation })
    |> Jsont.Object.mem "claim" Mentat_session.Tool_claim.Id.jsont
         ~enc:(function
         | Tool_returned { claim; _ } -> claim
         | _ -> assert false)
    |> Jsont.Object.mem "result"
         (Mentat_tool.Result.jsont Mentat_tool.Output.jsont) ~enc:(function
         | Tool_returned { result; _ } -> result
         | _ -> assert false)
    |> Jsont.Object.opt_mem "mutation" evidence_jsont ~enc:(function
      | Tool_returned { mutation; _ } -> mutation
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "tool.returned" ~dec:Fun.id
  in
  let tool_ambiguous_case =
    Jsont.Object.map ~kind:"tool-ambiguous fact" (fun claim mutation ->
        Tool_ambiguous { claim; mutation })
    |> Jsont.Object.mem "claim" Mentat_session.Tool_claim.Id.jsont
         ~enc:(function
         | Tool_ambiguous { claim; _ } -> claim
         | _ -> assert false)
    |> Jsont.Object.opt_mem "mutation" evidence_jsont ~enc:(function
      | Tool_ambiguous { mutation; _ } -> mutation
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "tool.ambiguous" ~dec:Fun.id
  in
  let decision_requested_case =
    single "decision-requested fact" "decision.requested" "request"
      Mentat_session.Decision.Requested.jsont
      (fun request -> Decision_requested request)
      (function Decision_requested request -> request | _ -> assert false)
  in
  let decision_resolved_case =
    single "decision-resolved fact" "decision.resolved" "resolution"
      Mentat_session.Decision.Resolved.jsont
      (fun resolution -> Decision_resolved resolution)
      (function
        | Decision_resolved resolution -> resolution | _ -> assert false)
  in
  let journal_tasks_case =
    single "journal-tasks fact" "journal.tasks" "board"
      Mentat_session.Task.Board.jsont
      (fun board -> Journal_task_board board)
      (function Journal_task_board board -> board | _ -> assert false)
  in
  let journal_delegation_case =
    single "journal-delegation fact" "journal.delegation" "edge"
      Mentat_session.Delegation.jsont
      (fun edge -> Journal_delegation edge)
      (function Journal_delegation edge -> edge | _ -> assert false)
  in
  let journal_queue_case =
    single "journal-queue fact" "journal.queue" "update"
      Mentat_session.Queue.Update.jsont
      (fun update -> Journal_queue update)
      (function Journal_queue update -> update | _ -> assert false)
  in
  let compaction_case =
    single "compaction fact" "compaction.installed" "compaction"
      Mentat_session.Compaction.jsont
      (fun compaction -> Compaction compaction)
      (function Compaction compaction -> compaction | _ -> assert false)
  in
  let workspace_notice_case =
    single "workspace-notice fact" "workspace.notice" "notice"
      Mentat_session.Notice.jsont
      (fun notice -> Workspace_notice notice)
      (function Workspace_notice notice -> notice | _ -> assert false)
  in
  let undo_case =
    Jsont.Object.map ~kind:"undo fact" (fun update dropped_turns files ->
        Undo { update; dropped_turns; files })
    |> Jsont.Object.mem "update" Mentat_session.Undo.Update.jsont ~enc:(function
      | Undo { update; _ } -> update
      | _ -> assert false)
    |> Jsont.Object.mem "dropped_turns" Jsont.int ~enc:(function
      | Undo { dropped_turns; _ } -> dropped_turns
      | _ -> assert false)
    |> Jsont.Object.mem "files" (Jsont.list undo_file_jsont) ~enc:(function
      | Undo { files; _ } -> files
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "undo.updated" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [
        turn_started_case;
        turn_assistant_case;
        turn_assistant_interrupted_case;
        turn_provider_failed_case;
        turn_message_case;
        turn_finished_case;
        tool_started_case;
        tool_prepared_case;
        tool_returned_case;
        tool_ambiguous_case;
        decision_requested_case;
        decision_resolved_case;
        journal_tasks_case;
        journal_delegation_case;
        journal_queue_case;
        compaction_case;
        workspace_notice_case;
        undo_case;
      ]
  in
  let enc_case = function
    | Turn_started _ as f -> Jsont.Object.Case.value turn_started_case f
    | Turn_assistant _ as f -> Jsont.Object.Case.value turn_assistant_case f
    | Turn_assistant_interrupted _ as f ->
        Jsont.Object.Case.value turn_assistant_interrupted_case f
    | Turn_provider_failed _ as f ->
        Jsont.Object.Case.value turn_provider_failed_case f
    | Turn_message _ as f -> Jsont.Object.Case.value turn_message_case f
    | Turn_settled _ as f -> Jsont.Object.Case.value turn_finished_case f
    | Tool_started _ as f -> Jsont.Object.Case.value tool_started_case f
    | Tool_prepared _ as f -> Jsont.Object.Case.value tool_prepared_case f
    | Tool_returned _ as f -> Jsont.Object.Case.value tool_returned_case f
    | Tool_ambiguous _ as f -> Jsont.Object.Case.value tool_ambiguous_case f
    | Decision_requested _ as f ->
        Jsont.Object.Case.value decision_requested_case f
    | Decision_resolved _ as f ->
        Jsont.Object.Case.value decision_resolved_case f
    | Journal_task_board _ as f -> Jsont.Object.Case.value journal_tasks_case f
    | Journal_delegation _ as f ->
        Jsont.Object.Case.value journal_delegation_case f
    | Journal_queue _ as f -> Jsont.Object.Case.value journal_queue_case f
    | Compaction _ as f -> Jsont.Object.Case.value compaction_case f
    | Workspace_notice _ as f -> Jsont.Object.Case.value workspace_notice_case f
    | Undo _ as f -> Jsont.Object.Case.value undo_case f
  in
  Jsont.Object.map ~kind:"fact" (fun v f ->
      Wire.check v;
      f)
  |> Wire.mem
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.finish
