(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
module Fact = Mentat_protocol.Fact
module Progress = Mentat_protocol.Progress
module Session = Mentat_session

module Error = struct
  type t =
    | No_active_turn
    | Turn_already_active of {
        active : Session.Turn.Id.t;
        incoming : Session.Turn.Id.t;
      }
    | Pending_turn_mismatch of {
        pending : Session.Turn.Id.t;
        incoming : Session.Turn.Id.t;
      }
    | Turn_mismatch of {
        active : Session.Turn.Id.t;
        incoming : Session.Turn.Id.t;
      }
    | Duplicate_tool_claim of Session.Tool_claim.Id.t
    | Unknown_tool_claim of Session.Tool_claim.Id.t
    | Wrong_tool_stage of {
        claim : Session.Tool_claim.Id.t;
        expected : Mentat_tool.Stage.t;
        actual : Mentat_tool.Stage.t;
      }
    | Decision_already_pending of {
        pending : Session.Decision.Id.t;
        incoming : Session.Decision.Id.t;
      }
    | Unknown_decision of {
        pending : Session.Decision.Id.t option;
        incoming : Session.Decision.Id.t;
      }
    | Open_state_at_settlement of {
        turn : Session.Turn.Id.t;
        tool_claims : int;
        decision_pending : bool;
      }
    | Assistant_message

  let turn_id id = Session.Turn.Id.to_string id
  let tool_id id = Session.Tool_claim.Id.to_string id
  let decision_id id = Session.Decision.Id.to_string id

  let message = function
    | No_active_turn -> "turn-scoped fact arrived with no active turn"
    | Turn_already_active { active; incoming } ->
        Printf.sprintf "turn %s started while turn %s is still active"
          (turn_id incoming) (turn_id active)
    | Pending_turn_mismatch { pending; incoming } ->
        Printf.sprintf "turn %s started while submitted turn %s was pending"
          (turn_id incoming) (turn_id pending)
    | Turn_mismatch { active; incoming } ->
        Printf.sprintf "fact for turn %s arrived while turn %s is active"
          (turn_id incoming) (turn_id active)
    | Duplicate_tool_claim claim ->
        Printf.sprintf "tool claim %s opened more than once" (tool_id claim)
    | Unknown_tool_claim claim ->
        Printf.sprintf "tool settlement references unknown claim %s"
          (tool_id claim)
    | Wrong_tool_stage { claim; expected; actual } ->
        Printf.sprintf
          "tool claim %s settled as prepared at %s stage (expected %s)"
          (tool_id claim)
          (Mentat_tool.Stage.to_string actual)
          (Mentat_tool.Stage.to_string expected)
    | Decision_already_pending { pending; incoming } ->
        Printf.sprintf "decision %s opened while decision %s is still pending"
          (decision_id incoming) (decision_id pending)
    | Unknown_decision { pending; incoming } ->
        let pending =
          match pending with None -> "none" | Some id -> decision_id id
        in
        Printf.sprintf
          "decision resolution %s does not match pending decision %s"
          (decision_id incoming) pending
    | Open_state_at_settlement { turn; tool_claims; decision_pending } ->
        Printf.sprintf
          "turn %s settled with %d open tool claim(s) and pending decision %b"
          (turn_id turn) tool_claims decision_pending
    | Assistant_message ->
        "turn.message carried an assistant message; turn.assistant owns that \
         lane"

  let pp ppf error = Format.pp_print_string ppf (message error)
end

type phase =
  | Idle
  | Pending of { id : Session.Turn.Id.t; prompt : string }
  | Running of Session.Turn.t

type tool =
  | Running_tool of { claim : Session.Tool_claim.Started.t; started : float }
  | Prepared_tool of {
      claim : Session.Tool_claim.Started.t;
      description : string;
      requests : Mentat_permission.Request.t list;
    }

type workspace = {
  totals : Textdiff.stats;
  observed : Mentat_workspace.Path.Set.t;
  change_rows : int;
  revertability : Mentat_mutation.Revertability.t list;
  ambiguous : bool;
}

type retrying = {
  retry_attempt : int;
  retry_limit : int;
  retry_reason : string;
  retry_deadline : float;
      (* When the announced attempt starts, on the caller's clock: the pulse's
         arrival plus its delay. Rendering counts down against [now]. *)
}

type writing = {
  writing_name : string option; (* The tool once the stream has named it. *)
  writing_received : int;
      (* Cumulative input bytes of that call — each pulse carries the whole
         count, so the latest pulse alone is rendered. *)
}

type t = {
  phase : phase;
  turn_started : float;
  step_started : float option;
  assistant_stable_rev : string list;
      (* Complete-line chunks, newest first. A delta conses or moves at most
         its current open line; flattening belongs to rendering. *)
  assistant_open_rev : string list; (* Current-line chunks, newest first. *)
  reasoning_rev : string list; (* Provider deltas, newest first. *)
  assistant_has_visible : bool;
  reasoning_has_visible : bool;
  tools : tool list;
      (* Newest first. Rendering reverses once; start and settlement stay O(n)
         only in the number of simultaneously open claims. *)
  pending_decision : Session.Decision.Requested.t option;
  board : Session.Task.Board.t option;
  workspace : workspace option;
  interrupting : bool;
  committed_output : int;
  step_output : int;
  compacting : bool;
  downloading : Progress.Model_download.t option;
      (* The latest artifact-preparation pulse of the active model call, or
         [None] once the artifact is ready or nothing needed preparing. *)
  writing : writing option;
      (* The latest tool-input pulse of the active model call, or [None]
         outside tool-input streaming. *)
  retrying : retrying option;
      (* The latest retry announcement of the active model call, or [None]
         once an attempt gets through and the stream produces a pulse. *)
  provider_failure_reported : Session.Provider_request.Id.t option;
}

let idle =
  {
    phase = Idle;
    turn_started = 0.;
    step_started = None;
    assistant_stable_rev = [];
    assistant_open_rev = [];
    reasoning_rev = [];
    assistant_has_visible = false;
    reasoning_has_visible = false;
    tools = [];
    pending_decision = None;
    board = None;
    workspace = None;
    interrupting = false;
    committed_output = 0;
    step_output = 0;
    compacting = false;
    downloading = None;
    writing = None;
    retrying = None;
    provider_failure_reported = None;
  }

let validate_now function_name now =
  if not (Float.is_finite now) then
    invalid_arg ("Turn." ^ function_name ^ ": now must be finite")

let in_flight t =
  match t.phase with Idle -> false | Pending _ | Running _ -> true

let active_turn t =
  match t.phase with Running turn -> Some turn | Idle | Pending _ -> None

let pending_decision t = t.pending_decision
let todo_board t = t.board

let request ~now ~turn ~prompt t =
  validate_now "request" now;
  if in_flight t then invalid_arg "Turn.request: a turn is already in flight";
  (* The same constructor used by the eventual settled block is the
     programmer-local visibility gate. Keep the original string so the live
     user block performs the exact same normalization when it renders. *)
  ignore (Transcript.user prompt : Transcript.block);
  { idle with phase = Pending { id = turn; prompt }; turn_started = now }

let interrupting t =
  if not (in_flight t) then
    invalid_arg "Turn.interrupting: no turn is in flight";
  { t with interrupting = true }

let active_id = function
  | Running turn -> Some (Session.Turn.id turn)
  | Idle | Pending _ -> None

let ensure_turn t incoming =
  match active_id t.phase with
  | None -> Error Error.No_active_turn
  | Some active ->
      if Session.Turn.Id.equal active incoming then Ok ()
      else Error (Error.Turn_mismatch { active; incoming })

let tool_claim = function
  | Running_tool { claim; _ } | Prepared_tool { claim; _ } -> claim

let tool_id tool = Session.Tool_claim.Started.id (tool_claim tool)

let tool_call_id tool =
  Mentat_llm.Tool.Call.id (Session.Tool_claim.Started.call (tool_claim tool))

let find_tool claim tools =
  List.find_opt
    (fun tool -> Session.Tool_claim.Id.equal (tool_id tool) claim)
    tools

let remove_tool claim tools =
  List.filter
    (fun tool -> not (Session.Tool_claim.Id.equal (tool_id tool) claim))
    tools

let remove_tool_call call_id tools =
  List.filter (fun tool -> not (String.equal (tool_call_id tool) call_id)) tools

let replace_prepared_call ~call_id replacement tools =
  let rec loop replaced acc = function
    | [] -> if replaced then List.rev acc else replacement :: List.rev acc
    | (Prepared_tool _ as tool) :: rest
      when (not replaced) && String.equal (tool_call_id tool) call_id ->
        loop true (replacement :: acc) rest
    | tool :: rest -> loop replaced (tool :: acc) rest
  in
  loop false [] tools

let clear_model t =
  {
    t with
    step_started = None;
    assistant_stable_rev = [];
    assistant_open_rev = [];
    reasoning_rev = [];
    assistant_has_visible = false;
    reasoning_has_visible = false;
    step_output = 0;
    compacting = false;
    downloading = None;
    writing = None;
  }

let add_saturating a b = if b > max_int - a then max_int else a + b

let elapsed_seconds ~now started =
  let elapsed = now -. started in
  if Float.is_nan elapsed || elapsed <= 0. then 0
  else if elapsed >= Float.of_int max_int then max_int
  else int_of_float elapsed

(* Normalize display text before asking Matrix for grapheme or column
   boundaries. Progress is normally codec-valid UTF-8, but local in-process
   producers can construct the public sum directly; a malformed delta must not
   crash the render loop. Newline shape is preserved. *)
let normalize_text text =
  let buffer = Buffer.create (String.length text) in
  let rec loop offset =
    if offset < String.length text then
      let decoded = String.get_utf_8_uchar text offset in
      let length = Uchar.utf_decode_length decoded in
      if not (Uchar.utf_decode_is_valid decoded) then (
        Buffer.add_utf_8_uchar buffer Uchar.rep;
        loop (offset + length))
      else
        let uchar = Uchar.utf_decode_uchar decoded in
        let code = Uchar.to_int uchar in
        if code = 0x0d then (
          Buffer.add_char buffer '\n';
          let next = offset + length in
          let next =
            if next < String.length text && Char.equal text.[next] '\n' then
              next + 1
            else next
          in
          loop next)
        else if code = 0x2028 || code = 0x2029 then (
          Buffer.add_char buffer '\n';
          loop (offset + length))
        else if code = 0x09 then (
          Buffer.add_string buffer "  ";
          loop (offset + length))
        else if (code < 0x20 && code <> 0x0a) || (code >= 0x7f && code <= 0x9f)
        then (
          Buffer.add_utf_8_uchar buffer Uchar.rep;
          loop (offset + length))
        else (
          Buffer.add_utf_8_uchar buffer uchar;
          loop (offset + length))
  in
  loop 0;
  Buffer.contents buffer

let is_unicode_space code =
  code = 0x20 || code = 0x85 || code = 0xa0 || code = 0x1680
  || (code >= 0x2000 && code <= 0x200a)
  || code = 0x2028 || code = 0x2029 || code = 0x202f || code = 0x205f
  || code = 0x3000

let grapheme_is_space grapheme =
  let rec loop offset =
    if offset >= String.length grapheme then true
    else
      let decoded = String.get_utf_8_uchar grapheme offset in
      is_unicode_space (Uchar.to_int (Uchar.utf_decode_uchar decoded))
      && loop (offset + Uchar.utf_decode_length decoded)
  in
  loop 0

let has_visible_text text =
  let text = normalize_text text in
  try
    Matrix.Text.iter_grapheme_info ~width_method:`Unicode ~tab_width:2
      (fun ~offset ~len ~width ->
        let grapheme = String.sub text offset len in
        if width > 0 && not (grapheme_is_space grapheme) then raise Exit)
      text;
    false
  with Exit -> true

let visible_texts texts = List.filter has_visible_text texts

let media_label media_type =
  let media_type = normalize_text media_type in
  if has_visible_text media_type then "[media: " ^ media_type ^ "]"
  else "[media]"

let content_text content =
  List.filter_map
    (function
      | Mentat_llm.Content.Text text ->
          if has_visible_text text then Some text else None
      | Mentat_llm.Content.Media { media_type; source } ->
          let source =
            match source with
            | `Uri _ -> "URI"
            | `Base64 _ -> "inline"
            | `Ref _ -> "attachment"
          in
          Some (media_label media_type ^ " · " ^ source))
    content
  |> String.concat "\n\n"

let user_input_blocks turn =
  match (Session.Turn.origin turn, Session.Turn.input turn) with
  | ( ( Session.Turn.Origin.User | Session.Turn.Origin.Queued _
      | Session.Turn.Origin.Triggered _ ),
      Session.Turn.Input.User content ) ->
      let text = content_text content in
      if has_visible_text text then [ Transcript.user text ] else []
  | ( Session.Turn.Origin.Goal_continuation,
      ( Session.Turn.Input.Continue | Session.Turn.Input.User _
      | Session.Turn.Input.Plan_build _ ) )
  | ( Session.Turn.Origin.Plan_build,
      ( Session.Turn.Input.Plan_build _ | Session.Turn.Input.User _
      | Session.Turn.Input.Continue ) )
  | ( ( Session.Turn.Origin.User | Session.Turn.Origin.Queued _
      | Session.Turn.Origin.Triggered _ ),
      (Session.Turn.Input.Continue | Session.Turn.Input.Plan_build _) )
  | ( Session.Turn.Origin.Compaction,
      ( Session.Turn.Input.Continue | Session.Turn.Input.User _
      | Session.Turn.Input.Plan_build _ ) )
  | ( Session.Turn.Origin.Step_limit_wind_down,
      ( Session.Turn.Input.Continue | Session.Turn.Input.User _
      | Session.Turn.Input.Plan_build _ ) ) ->
      (* Cross-origin/input validity is owned by session replay. Do not render
         internal continuation, canonical plan-build, compaction, or wind-down
         turns as user speech. *)
      []

let first_nonempty_line text =
  String.split_on_char '\n' text
  |> List.find_opt has_visible_text
  |> Option.map String.trim

let strip_bold line =
  let length = String.length line in
  if
    length >= 4
    && String.starts_with ~prefix:"**" line
    && String.ends_with ~suffix:"**" line
  then Some (String.trim (String.sub line 2 (length - 4)))
  else None

let first_sentence text =
  let text = String.trim text in
  match String.index_opt text '.' with
  | Some index -> String.sub text 0 index
  | None -> (
      match String.index_opt text '\n' with
      | Some index -> String.sub text 0 index
      | None -> text)

let reasoning_title body =
  match first_nonempty_line body with
  | None -> None
  | Some line -> (
      match strip_bold line with
      | Some title when has_visible_text title -> Some title
      | Some _ -> None
      | None ->
          let title = first_sentence body in
          if has_visible_text title then Some title else None)

let reasoning_blocks ~duration_s response =
  let body =
    String.concat "\n\n" (Mentat_llm.Response.reasoning_summary response)
  in
  if not (has_visible_text body) then []
  else
    [ Transcript.reasoning ~duration_s ?title:(reasoning_title body) ~body () ]

let assistant_blocks response =
  let text = Mentat_llm.Response.text response in
  if has_visible_text text then [ Transcript.assistant text ] else []

let provider_failure error =
  let message = Mentat_llm.Error.message error in
  let message =
    if has_visible_text message then message else "The model provider failed."
  in
  Transcript.notice
    (Notice.Failure
       { message; next_step = "Tell mentat how to proceed."; count = 1 })

let generic_tool_result result =
  let texts = Mentat_llm.Tool.Result.texts result |> visible_texts in
  let media =
    List.fold_left
      (fun count -> function
        | Mentat_llm.Content.Text _ -> count
        | Mentat_llm.Content.Media _ -> count + 1)
      0
      (Mentat_llm.Tool.Result.content result)
  in
  let failed = Mentat_llm.Tool.Result.is_error result in
  let summary =
    match texts with
    | _ :: _ -> String.concat "\n\n" texts
    | [] -> if failed then "tool failed" else "done"
  in
  let facts =
    if media = 0 then []
    else
      [
        Printf.sprintf "%d media result%s" media (if media = 1 then "" else "s");
      ]
  in
  let verb = Tool_distill.verb_of_name (Mentat_llm.Tool.Result.name result) in
  Transcript.tool
    (Tool_block.make verb ~argument:""
       ~dot:(if failed then Tool_block.Failed else Tool_block.Succeeded)
       ~summary ~facts ())

let message_blocks = function
  | Mentat_llm.Message.User content ->
      let text = content_text content in
      if has_visible_text text then Ok [ Transcript.user text ] else Ok []
  | Mentat_llm.Message.System text ->
      if has_visible_text text then
        Ok [ Transcript.notice (Notice.Event ("System — " ^ text)) ]
      else Ok []
  | Mentat_llm.Message.Developer text ->
      if has_visible_text text then
        Ok [ Transcript.notice (Notice.Event ("Developer — " ^ text)) ]
      else Ok []
  | Mentat_llm.Message.Tool_result result -> Ok [ generic_tool_result result ]
  | Mentat_llm.Message.Assistant _ -> Error Error.Assistant_message

let add_evidence ~ambiguous evidence t =
  match evidence with
  | None -> t
  | Some (evidence : Fact.evidence) ->
      let previous =
        match t.workspace with
        | None ->
            {
              totals = evidence.Fact.totals;
              observed = Mentat_workspace.Path.Set.empty;
              change_rows = 0;
              revertability = [];
              ambiguous = false;
            }
        | Some workspace -> workspace
      in
      let observed =
        List.fold_left
          (fun paths path -> Mentat_workspace.Path.Set.add path paths)
          previous.observed evidence.Fact.observed
      in
      let workspace =
        {
          totals = evidence.Fact.totals;
          observed;
          change_rows =
            add_saturating previous.change_rows
              (List.length evidence.Fact.changes);
          revertability = evidence.Fact.revertability :: previous.revertability;
          ambiguous = previous.ambiguous || ambiguous;
        }
      in
      { t with workspace = Some workspace }

let unique strings =
  List.fold_left
    (fun seen string ->
      if List.exists (String.equal string) seen then seen else string :: seen)
    [] strings
  |> List.rev

let workspace_block workspace =
  let stats : Textdiff.stats = workspace.totals in
  let observed = Mentat_workspace.Path.Set.cardinal workspace.observed in
  let exact_facts =
    if workspace.change_rows = 0 then []
    else
      [
        Notice.Fact
          (Printf.sprintf "%d file%s" stats.Textdiff.files
             (if stats.Textdiff.files = 1 then "" else "s"));
        Notice.Change
          {
            added = stats.Textdiff.additions;
            removed = stats.Textdiff.deletions;
          };
      ]
      @
      if workspace.change_rows > stats.Textdiff.files then
        [
          Notice.Fact
            (Printf.sprintf "%d recorded changes" workspace.change_rows);
        ]
      else []
  in
  let observed_facts =
    if observed = 0 then []
    else
      [
        Notice.Fact
          (Printf.sprintf "%d path%s observed" observed
             (if observed = 1 then "" else "s"));
      ]
  in
  let facts = exact_facts @ observed_facts in
  let revertability =
    workspace.revertability
    |> List.filter_map (fun answer ->
        match answer with
        | Mentat_mutation.Revertability.Available -> None
        | Mentat_mutation.Revertability.Unavailable _ ->
            Some (Mentat_mutation.Revertability.message answer)
        | Mentat_mutation.Revertability.Incomplete _ -> Some "revert incomplete")
    |> unique
    |> List.map (fun message -> Notice.Fact message)
  in
  let facts =
    if revertability <> [] then facts @ revertability
    else if workspace.ambiguous then
      facts
      @ [
          Notice.Fact
            "recorded changes are revertible; tool outcome remains unknown";
        ]
    else facts @ [ Notice.Fact "revert available" ]
  in
  Transcript.notice
    (Notice.Data
       {
         source =
           (if workspace.ambiguous then "workspace may still be changing"
            else "workspace changed");
         facts;
         atom = None;
       })

let outcome_blocks ~provider_failure_reported outcome =
  match outcome with
  | Session.Turn.Outcome.Completed -> []
  | Session.Turn.Outcome.Step_limit ->
      [
        Transcript.notice
          (Notice.Event
             "The turn stopped at its step limit — the cap on model responses.");
      ]
  | Session.Turn.Outcome.Interrupted _ -> [ Transcript.notice Notice.Interrupt ]
  | Session.Turn.Outcome.Failed { message } ->
      if provider_failure_reported then []
      else
        let message =
          if has_visible_text message then message else "The turn failed."
        in
        [
          Transcript.notice
            (Notice.Failure
               { message; next_step = "Tell mentat how to proceed."; count = 1 });
        ]

let compaction_label compaction =
  let token_text count =
    if count < 1000 then string_of_int count
    else
      let text = Printf.sprintf "%.1f" (Float.of_int count /. 1000.) in
      let text =
        if String.ends_with ~suffix:".0" text then
          String.sub text 0 (String.length text - 2)
        else text
      in
      text ^ "k"
  in
  match Session.Compaction.context compaction with
  | None -> "compacted"
  | Some context -> (
      match
        ( Session.Compaction.Context_tokens.before context,
          Session.Compaction.Context_tokens.after context )
      with
      | Some before, Some after ->
          Printf.sprintf "compacted ~%s → ~%s tokens" (token_text before)
            (token_text after)
      | Some before, None ->
          Printf.sprintf "compacted ~%s tokens" (token_text before)
      | None, Some after ->
          Printf.sprintf "compacted → ~%s tokens" (token_text after)
      | None, None -> "compacted")

(* The armed undo boundary's transcript seam label: the dropped-turn count, the
   per-file line stats, and the [/redo] affordance on one centered rule, mirroring
   the compaction seam. A [Released] boundary renders no seam. Rendered from the
   projected [Fact.Undo], never from ephemeral state, so resume reconstructs it.
   The richer multi-line per-file layout the design sketches is a later
   refinement; this single-line form carries the same facts. *)
let undo_seam_label ~dropped_turns ~files =
  let turns =
    Printf.sprintf "%d turn%s undone" dropped_turns
      (if dropped_turns = 1 then "" else "s")
  in
  let file_text (file : Fact.undo_file) =
    Printf.sprintf "%s +%d −%d"
      (Lpath.Rel.to_string (Mentat_workspace.Path.rel file.Fact.path))
      file.Fact.additions file.Fact.deletions
  in
  let files_part =
    match files with
    | [] -> "no file changes"
    | _ -> String.concat ", " (List.map file_text files)
  in
  Printf.sprintf "%s · %s · /redo to restore" turns files_part

let duration_text seconds =
  if seconds < 60 then string_of_int seconds ^ "s"
  else Printf.sprintf "%dm %02ds" (seconds / 60) (seconds mod 60)

let token_text count =
  if count < 1000 then string_of_int count
  else
    let text = Printf.sprintf "%.1f" (Float.of_int count /. 1000.) in
    let text =
      if String.ends_with ~suffix:".0" text then
        String.sub text 0 (String.length text - 2)
      else text
    in
    text ^ "k"

let byte_text bytes =
  if bytes < 1024 then string_of_int bytes ^ " B"
  else if bytes < 1024 * 1024 then
    Printf.sprintf "%.1f KB" (Float.of_int bytes /. 1024.)
  else Printf.sprintf "%.1f MB" (Float.of_int bytes /. (1024. *. 1024.))

(* The settled-turn receipt: the working line's live "(elapsed · ↓ tokens)"
   resolves into one muted event line so a completed turn confirms its cost
   instead of vanishing. Sub-second turns carry no receipt. *)
let worked_notice ~elapsed ~output =
  let tokens =
    if output = 0 then ""
    else Theme.separator ^ Printf.sprintf "↓ %s tokens" (token_text output)
  in
  Transcript.notice
    (Notice.Event
       (Printf.sprintf "Worked for %s%s" (duration_text elapsed) tokens))

(* A durable workspace observation rendered as its full structured transcript
   block: the level-colored head and the whole multi-line body, never the
   truncated one-row glance the live footer shows. *)
let workspace_notice_block notice =
  let level =
    match Session.Notice.severity notice with
    | Session.Notice.Severity.Info -> Notice.Info
    | Session.Notice.Severity.Warning -> Notice.Warning
    | Session.Notice.Severity.Error -> Notice.Error
  in
  Transcript.notice
    (Notice.Workspace
       {
         level;
         source = Session.Notice.source notice;
         title = Session.Notice.title notice;
         body = Session.Notice.body notice;
       })

let fact ~now ~show_reasoning fact t =
  validate_now "fact" now;
  match fact with
  | Fact.Turn_started turn -> (
      let incoming = Session.Turn.id turn in
      match t.phase with
      | Running active ->
          Error
            (Error.Turn_already_active
               { active = Session.Turn.id active; incoming })
      | Pending { id = pending; _ }
        when not (Session.Turn.Id.equal pending incoming) ->
          Error (Error.Pending_turn_mismatch { pending; incoming })
      | Pending _ | Idle ->
          let turn_started =
            match t.phase with
            | Pending _ -> t.turn_started
            | Idle -> now
            | Running _ -> assert false
          in
          let t = { idle with phase = Running turn; turn_started } in
          Ok (t, user_input_blocks turn))
  | Fact.Turn_assistant response -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ ->
          let duration_s =
            match t.step_started with
            | None -> 0
            | Some started -> elapsed_seconds ~now started
          in
          let step_final =
            match Mentat_llm.Response.usage response with
            | Some usage -> Mentat_llm.Usage.output_total usage
            | None -> t.step_output
          in
          let blocks =
            (if show_reasoning then reasoning_blocks ~duration_s response
             else [])
            @ assistant_blocks response
          in
          let t = clear_model t in
          let t =
            {
              t with
              committed_output = add_saturating t.committed_output step_final;
            }
          in
          Ok (t, blocks))
  | Fact.Turn_assistant_interrupted { text } -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ ->
          let t = clear_model t in
          let blocks =
            if has_visible_text text then [ Transcript.assistant text ] else []
          in
          Ok (t, blocks))
  | Fact.Turn_provider_failed { claim; error } -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ ->
          let t = clear_model t in
          Ok
            ( { t with provider_failure_reported = Some claim },
              [ provider_failure error ] ))
  | Fact.Turn_message message -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match message_blocks message with
          | Error error -> Error error
          | Ok blocks ->
              let tools =
                match message with
                | Mentat_llm.Message.Tool_result result ->
                    remove_tool_call
                      (Mentat_llm.Tool.Result.call_id result)
                      t.tools
                | Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
                | Mentat_llm.Message.User _ | Mentat_llm.Message.Assistant _ ->
                    t.tools
              in
              Ok ({ t with tools }, blocks)))
  | Fact.Workspace_notice notice -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> Ok (t, [ workspace_notice_block notice ]))
  | Fact.Turn_settled { turn; outcome } -> (
      match ensure_turn t turn with
      | Error error -> Error error
      | Ok () ->
          let tool_claims = List.length t.tools in
          let decision_pending = Option.is_some t.pending_decision in
          if tool_claims > 0 || decision_pending then
            Error
              (Error.Open_state_at_settlement
                 { turn; tool_claims; decision_pending })
          else
            let workspace =
              match t.workspace with
              | None -> []
              | Some workspace -> [ workspace_block workspace ]
            in
            let worked =
              match outcome with
              | Session.Turn.Outcome.Completed ->
                  let elapsed = elapsed_seconds ~now t.turn_started in
                  if elapsed <= 0 then []
                  else [ worked_notice ~elapsed ~output:t.committed_output ]
              | Session.Turn.Outcome.Step_limit
              | Session.Turn.Outcome.Interrupted _
              | Session.Turn.Outcome.Failed _ ->
                  []
            in
            let outcome =
              outcome_blocks
                ~provider_failure_reported:
                  (Option.is_some t.provider_failure_reported)
                outcome
            in
            Ok (idle, workspace @ outcome @ worked))
  | Fact.Tool_started claim -> (
      let incoming = Session.Tool_claim.Started.turn claim in
      match ensure_turn t incoming with
      | Error error -> Error error
      | Ok () ->
          let id = Session.Tool_claim.Started.id claim in
          if Option.is_some (find_tool id t.tools) then
            Error (Error.Duplicate_tool_claim id)
          else
            let started = Running_tool { claim; started = now } in
            let call_id =
              Mentat_llm.Tool.Call.id (Session.Tool_claim.Started.call claim)
            in
            let tools =
              match Session.Tool_claim.Started.stage claim with
              | Mentat_tool.Stage.Run ->
                  replace_prepared_call ~call_id started t.tools
              | Mentat_tool.Stage.Direct | Mentat_tool.Stage.Prepare ->
                  started :: t.tools
            in
            Ok ({ t with tools }, []))
  | Fact.Tool_prepared { claim; description; requests } -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match find_tool claim t.tools with
          | None -> Error (Error.Unknown_tool_claim claim)
          | Some tool ->
              let started = tool_claim tool in
              let actual = Session.Tool_claim.Started.stage started in
              if not (Mentat_tool.Stage.equal actual Mentat_tool.Stage.Prepare)
              then
                Error
                  (Error.Wrong_tool_stage
                     { claim; expected = Mentat_tool.Stage.Prepare; actual })
              else
                let tools =
                  List.map
                    (fun tool ->
                      if Session.Tool_claim.Id.equal (tool_id tool) claim then
                        Prepared_tool { claim = started; description; requests }
                      else tool)
                    t.tools
                in
                Ok ({ t with tools }, [])))
  | Fact.Tool_returned { claim; result; mutation } -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match find_tool claim t.tools with
          | None -> Error (Error.Unknown_tool_claim claim)
          | Some tool ->
              let started = tool_claim tool in
              let t = { t with tools = remove_tool claim t.tools } in
              let t = add_evidence ~ambiguous:false mutation t in
              Ok (t, [ Transcript.tool (Tool_distill.returned started result) ])
          ))
  | Fact.Tool_ambiguous { claim; mutation } -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match find_tool claim t.tools with
          | None -> Error (Error.Unknown_tool_claim claim)
          | Some tool ->
              let started = tool_claim tool in
              let t = { t with tools = remove_tool claim t.tools } in
              let t = add_evidence ~ambiguous:true mutation t in
              Ok (t, [ Transcript.tool (Tool_distill.ambiguous started) ])))
  | Fact.Decision_requested request -> (
      let incoming = Session.Decision.Requested.turn request in
      match ensure_turn t incoming with
      | Error error -> Error error
      | Ok () -> (
          match t.pending_decision with
          | None -> Ok ({ t with pending_decision = Some request }, [])
          | Some pending ->
              Error
                (Error.Decision_already_pending
                   {
                     pending = Session.Decision.Requested.id pending;
                     incoming = Session.Decision.Requested.id request;
                   })))
  | Fact.Decision_resolved resolution -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          let incoming = Session.Decision.Resolved.id resolution in
          let pending_id =
            Option.map Session.Decision.Requested.id t.pending_decision
          in
          match t.pending_decision with
          | Some pending when Session.Decision.matches pending resolution ->
              let tools =
                match Session.Decision.Resolved.answer resolution with
                | Session.Decision.Answer.Permission
                    {
                      answer =
                        ( Mentat_permission.Answer.Allow _
                        | Mentat_permission.Answer.Deny );
                      _;
                    } ->
                    remove_tool_call
                      (Session.Decision.Requested.call_id pending)
                      t.tools
                | Session.Decision.Answer.Question _
                | Session.Decision.Answer.Plan _ ->
                    t.tools
              in
              Ok ({ t with pending_decision = None; tools }, [])
          | None | Some _ ->
              Error (Error.Unknown_decision { pending = pending_id; incoming }))
      )
  | Fact.Journal_task_board board -> (
      match active_id t.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> Ok ({ t with board = Some board }, [ Transcript.board board ])
      )
  | Fact.Compaction compaction ->
      let t = clear_model t in
      let committed_output =
        match Session.Compaction.usage compaction with
        | None -> t.committed_output
        | Some usage ->
            add_saturating t.committed_output
              (Mentat_llm.Usage.output_total usage)
      in
      Ok
        ( { t with committed_output },
          [ Transcript.notice (Notice.Seam (compaction_label compaction)) ] )
  (* Queue transitions are session-scoped and committed between turns, so
     these facts legitimately arrive with no active turn. The transcript does
     not render them; the queue surface re-reads session state at the app
     level. Goal facts are retired vocabulary, dropped until the constructor
     is deleted with the rest of the goal machinery. Accept and drop. *)
  | Fact.Journal_goal _ | Fact.Journal_queue _ -> Ok (t, [])
  | Fact.Undo { update; dropped_turns; files } -> (
      (* The undo boundary is committed at an idle head. An [Armed] boundary
         renders a seam. The transcript is append-only, so a [Released] one
         cannot retract that seam — it appends the restore receipt instead;
         without it a [/redo] succeeds invisibly while the armed seam above
         keeps advertising "/redo to restore". The durable fact does not
         distinguish [/redo] from cancel, so the receipt is exit-neutral. *)
      match Session.Undo.Update.anchor update with
      | None ->
          Ok
            ( t,
              [
                Transcript.notice (Notice.Seam "turns restored · undo released");
              ] )
      | Some _ ->
          Ok
            ( t,
              [
                Transcript.notice
                  (Notice.Seam (undo_seam_label ~dropped_turns ~files));
              ] ))
  | Fact.Journal_delegation edge -> (
      let incoming = Session.Delegation.source_turn edge in
      match ensure_turn t incoming with
      | Error error -> Error error
      | Ok () -> Ok (t, []))

(* Fold CRLF across the open buffer and an incoming assistant delta. The open
   line is the only previous text a newline-bearing delta flattens; complete
   lines move into a newest-first chunk list. Appending a delta with no newline
   is O(delta), not O(the accumulated response). *)
let fold_crlf text =
  if not (String.contains text '\r') then text
  else
    let buffer = Buffer.create (String.length text) in
    let length = String.length text in
    for index = 0 to length - 1 do
      if
        not
          (Char.equal text.[index] '\r'
          && index + 1 < length
          && Char.equal text.[index + 1] '\n')
      then Buffer.add_char buffer text.[index]
    done;
    Buffer.contents buffer

let assistant_delta text t =
  if String.equal text "" then t
  else
    let open_ends_in_cr =
      match t.assistant_open_rev with
      | [] -> false
      | chunk :: _ ->
          let length = String.length chunk in
          length > 0 && Char.equal chunk.[length - 1] '\r'
    in
    if (not (String.contains text '\n')) && not open_ends_in_cr then
      {
        t with
        assistant_open_rev = text :: t.assistant_open_rev;
        assistant_has_visible = t.assistant_has_visible || has_visible_text text;
        compacting = false;
      }
    else
      let open_line = String.concat "" (List.rev t.assistant_open_rev) in
      let joined = fold_crlf (open_line ^ text) in
      match String.rindex_opt joined '\n' with
      | None ->
          {
            t with
            assistant_open_rev = [ joined ];
            assistant_has_visible =
              t.assistant_has_visible || has_visible_text text;
            compacting = false;
          }
      | Some index ->
          let cut = index + 1 in
          let stable = String.sub joined 0 cut in
          let open_line = String.sub joined cut (String.length joined - cut) in
          {
            t with
            assistant_stable_rev = stable :: t.assistant_stable_rev;
            assistant_open_rev =
              (if String.equal open_line "" then [] else [ open_line ]);
            assistant_has_visible =
              t.assistant_has_visible || has_visible_text text;
            compacting = false;
          }

let progress ~now pulse t =
  validate_now "progress" now;
  let applies turn =
    match active_id t.phase with
    | Some active -> Session.Turn.Id.equal active turn
    | None -> false
  in
  match pulse with
  | Progress.Model { turn; update } when applies turn -> (
      match update with
      | Progress.Model.Started ->
          {
            t with
            step_started = Some now;
            assistant_stable_rev = [];
            assistant_open_rev = [];
            reasoning_rev = [];
            assistant_has_visible = false;
            reasoning_has_visible = false;
            step_output = 0;
            compacting = false;
            downloading = None;
            writing = None;
            retrying = None;
          }
      | Progress.Model.Assistant_delta { text } ->
          assistant_delta text { t with retrying = None }
      | Progress.Model.Reasoning_delta { text } ->
          {
            t with
            reasoning_rev = text :: t.reasoning_rev;
            reasoning_has_visible =
              t.reasoning_has_visible || has_visible_text text;
            compacting = false;
            retrying = None;
          }
      | Progress.Model.Usage usage ->
          {
            t with
            step_output = Mentat_llm.Usage.output_total usage;
            retrying = None;
          }
      | Progress.Model.Tool_input { name; received } ->
          {
            t with
            writing = Some { writing_name = name; writing_received = received };
            compacting = false;
            retrying = None;
          }
      | Progress.Model.Retrying retry ->
          {
            t with
            retrying =
              Some
                {
                  retry_attempt = Mentat_llm.Event.Retry.attempt retry;
                  retry_limit = Mentat_llm.Event.Retry.limit retry;
                  retry_reason = Mentat_llm.Event.Retry.reason retry;
                  retry_deadline = now +. Mentat_llm.Event.Retry.delay retry;
                };
          })
  | Progress.Model_download { turn; update } when applies turn -> (
      match update.Progress.Model_download.phase with
      | Progress.Model_download.Ready -> { t with downloading = None }
      | Progress.Model_download.Checking | Progress.Model_download.Downloading
      | Progress.Model_download.Verifying ->
          { t with downloading = Some update })
  | Progress.Compaction { turn; update } when applies turn -> (
      match update with
      | Progress.Compaction.Started _ | Progress.Compaction.Summarizing ->
          { t with compacting = true }
      | Progress.Compaction.Failed _ -> { t with compacting = false })
  | Progress.Model _ | Progress.Model_download _ | Progress.Compaction _ ->
      t

(* ── Views ──────────────────────────────────────────────────────────────── *)

let zero_size = { width = px 0; height = px 0 }
let fill_width = { width = pct 100; height = auto }
let blank_row = box ~size:{ width = pct 100; height = px 1 } []

let shrinking_space columns =
  box ~flex_shrink:100. ~min_size:zero_size
    ~size:{ width = px columns; height = auto }
    []

let reasoning_body ~palette reasoning =
  text
    ~style:(Theme.Palette.thinking_style palette)
    ~wrap:`Word ~flex_grow:1. ~flex_shrink:1. ~min_size:zero_size
    (normalize_text reasoning)

let ticker ~palette ~expanded reasoning =
  let body = reasoning_body ~palette reasoning in
  let body =
    if expanded then body
    else
      scroll_box ~key:"turn.reasoning" ~scroll_x:false ~scroll_y:true
        ~sticky_scroll:true ~sticky_start:`Bottom ~show_scrollbars:false
        ~focusable:false ~flex_grow:0. ~flex_shrink:1. ~min_size:zero_size
        ~max_size:{ width = pct 100; height = px 3 }
        ~size:fill_width [ body ]
  in
  box ~flex_direction:Flex_direction.Column ~min_size:zero_size ~size:fill_width
    [
      text
        ~style:(Theme.Palette.thinking_style palette)
        ~wrap:`None ~truncate:true ~min_size:zero_size
        (Theme.thought ^ " Thinking");
      box ~flex_direction:Flex_direction.Row ~min_size:zero_size
        ~size:fill_width
        [ shrinking_space 2; body ];
    ]

let assistant_tail ~palette ~stable_text ~open_text =
  let stable =
    if has_visible_text stable_text then
      [ Prose.view ~streaming:true ~palette (normalize_text stable_text) ]
    else []
  in
  let open_line =
    if has_visible_text open_text then
      [
        text ~style:Ansi.Style.default ~wrap:`Word ~flex_grow:1. ~flex_shrink:1.
          ~min_size:zero_size (normalize_text open_text);
      ]
    else []
  in
  box ~flex_direction:Flex_direction.Row ~min_size:zero_size ~size:fill_width
    ~gap:{ width = px 1; height = px 0 }
    [
      text
        ~style:(Theme.Palette.running_style palette)
        ~wrap:`None ~flex_shrink:0. Theme.tool;
      box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
        ~min_size:zero_size (stable @ open_line);
    ]

let running_block ~now = function
  | Running_tool { claim; started } ->
      let call = Session.Tool_claim.Started.call claim in
      Tool_block.make
        (Tool_distill.verb_of_name (Mentat_llm.Tool.Call.name call))
        ~argument:"" ~dot:Tool_block.Running ~summary:"running"
        ~facts:[ duration_text (elapsed_seconds ~now started) ]
        ()
  | Prepared_tool { claim; description; requests } ->
      let count = List.length requests in
      if count = 0 then Tool_distill.prepared claim ~description
      else
        let call = Session.Tool_claim.Started.call claim in
        Tool_block.make
          (Tool_distill.verb_of_name (Mentat_llm.Tool.Call.name call))
          ~argument:"" ~dot:Tool_block.Awaiting ~summary:description
          ~facts:
            [
              Printf.sprintf "%d permission request%s" count
                (if count = 1 then "" else "s");
            ]
          ()

let assistant_text t =
  ( String.concat "" (List.rev t.assistant_stable_rev),
    String.concat "" (List.rev t.assistant_open_rev) )

let reasoning_text t = String.concat "" (List.rev t.reasoning_rev)

let tail ~palette ~now ~show_reasoning ~expanded t =
  validate_now "tail" now;
  let pending =
    match t.phase with
    | Pending { prompt; _ } -> [ Transcript.user_block ~palette prompt ]
    | Idle | Running _ -> []
  in
  let reasoning_text =
    if t.reasoning_has_visible then reasoning_text t else ""
  in
  let assistant_stable, assistant_open =
    if t.assistant_has_visible then assistant_text t else ("", "")
  in
  let reasoning =
    if show_reasoning && has_visible_text reasoning_text then
      [ ticker ~palette ~expanded reasoning_text ]
    else []
  in
  let assistant =
    if has_visible_text assistant_stable || has_visible_text assistant_open then
      [
        assistant_tail ~palette ~stable_text:assistant_stable
          ~open_text:assistant_open;
      ]
    else []
  in
  let tools =
    List.rev t.tools
    |> List.map (fun tool -> Tool_block.view ~palette (running_block ~now tool))
  in
  let parts = pending @ reasoning @ assistant @ tools in
  match parts with
  | [] -> None
  | _ :: _ ->
      let parts =
        List.concat
          (List.mapi
             (fun index part ->
               if index = 0 then [ part ] else [ blank_row; part ])
             parts)
      in
      Some
        (box ~flex_direction:Flex_direction.Column ~min_size:zero_size
           ~size:fill_width parts)

let spinner_frame spinner =
  let frames = Theme.spinner_frames in
  let length = Array.length frames in
  if length = 0 then "⠿"
  else
    let index = spinner mod length in
    frames.(if index < 0 then index + length else index)

let download_gb bytes = Int64.to_float bytes /. 1_000_000_000.

let download_label (d : Progress.Model_download.t) =
  let verb =
    match d.Progress.Model_download.phase with
    | Progress.Model_download.Checking -> "Preparing"
    | Progress.Model_download.Downloading -> "Downloading"
    | Progress.Model_download.Verifying -> "Verifying"
    | Progress.Model_download.Ready -> "Downloading"
  in
  verb ^ " " ^ d.Progress.Model_download.model

(* Bytes detail only while transferring; checking and verifying have no
   meaningful running total to show. *)
let download_detail (d : Progress.Model_download.t) =
  match d.Progress.Model_download.phase with
  | Progress.Model_download.Downloading -> (
      let received = d.Progress.Model_download.received in
      match d.Progress.Model_download.total with
      | Some total when Int64.compare total 0L > 0 ->
          let percent =
            Int64.to_float received /. Int64.to_float total *. 100.
          in
          [
            Printf.sprintf "%.1f / %.1f GB (%.0f%%)" (download_gb received)
              (download_gb total) percent;
          ]
      | Some _ | None -> [ Printf.sprintf "%.1f GB" (download_gb received) ])
  | Progress.Model_download.Checking | Progress.Model_download.Verifying
  | Progress.Model_download.Ready ->
      []

let working_line ~palette ~now ~spinner t =
  validate_now "working_line" now;
  if not (in_flight t) then None
  else
    let elapsed = duration_text (elapsed_seconds ~now t.turn_started) in
    let spin = spinner_frame spinner in
    let working verb extras =
      let details =
        String.concat Theme.separator
          ((elapsed :: extras) @ [ "esc to interrupt" ])
      in
      [
        text
          ~style:(Theme.Palette.running_style palette)
          ~wrap:`None ~flex_shrink:0. spin;
        shrinking_space 1;
        text ~style:Ansi.Style.default ~wrap:`None ~truncate:true
          ~flex_shrink:1. ~min_size:zero_size (verb ^ "…");
        shrinking_space 1;
        text
          ~style:(Theme.Palette.muted_style palette)
          ~wrap:`None ~truncate:true ~flex_shrink:100. ~min_size:zero_size
          ("(" ^ details ^ ")");
      ]
    in
    let parts =
      if t.interrupting then
        [
          text
            ~style:(Theme.Palette.running_style palette)
            ~wrap:`None ~flex_shrink:0. spin;
          shrinking_space 1;
          text ~style:Ansi.Style.default ~wrap:`None ~truncate:true
            ~flex_shrink:1. ~min_size:zero_size "Interrupting…";
        ]
      else if Option.is_some t.pending_decision then
        [
          text
            ~style:(Theme.Palette.muted_style palette)
            ~wrap:`None ~flex_shrink:0. Theme.waiting;
          shrinking_space 1;
          text
            ~style:(Theme.Palette.muted_style palette)
            ~wrap:`None ~truncate:true ~flex_shrink:1. ~min_size:zero_size
            "Waiting for your answer";
        ]
      else if Option.is_some t.retrying then
        let r = Option.get t.retrying in
        let remaining = Float.ceil (r.retry_deadline -. now) in
        let wait =
          if remaining > 0. then
            Printf.sprintf "next attempt in %.0fs" remaining
          else "retrying now"
        in
        working
          (Printf.sprintf "%s — retry %d/%d"
             (String.capitalize_ascii r.retry_reason)
             r.retry_attempt r.retry_limit)
          [ wait ]
      else if Option.is_some t.downloading then
        let d = Option.get t.downloading in
        working (download_label d) (download_detail d)
      else if t.compacting then working "Compacting conversation" []
      else
        let reasoning_only =
          t.reasoning_has_visible
          && (not t.assistant_has_visible)
          && t.tools = []
        in
        let output = add_saturating t.committed_output t.step_output in
        let extras =
          if output = 0 then []
          else [ Printf.sprintf "↓ %s tokens" (token_text output) ]
        in
        match t.writing with
        | Some { writing_name; writing_received } ->
            let verb =
              match writing_name with
              | Some name -> "Writing " ^ name
              | None -> "Writing tool call"
            in
            working verb (byte_text writing_received :: extras)
        | None ->
            working (if reasoning_only then "Thinking" else "Working") extras
    in
    Some
      (box ~flex_direction:Flex_direction.Row ~min_size:zero_size
         ~size:{ width = pct 100; height = px 1 }
         parts)

(* CR: Why do we have a separate compacting_line when we have a condition above for compacting?! One of the two is wrong surely? *)
let compacting_line ~palette ~now ~spinner ~started =
  validate_now "compacting_line" now;
  let elapsed = duration_text (elapsed_seconds ~now started) in
  let spin = spinner_frame spinner in
  box ~flex_direction:Flex_direction.Row ~min_size:zero_size
    ~size:{ width = pct 100; height = px 1 }
    [
      text
        ~style:(Theme.Palette.running_style palette)
        ~wrap:`None ~flex_shrink:0. spin;
      shrinking_space 1;
      text ~style:Ansi.Style.default ~wrap:`None ~truncate:true ~flex_shrink:1.
        ~min_size:zero_size "Compacting…";
      shrinking_space 1;
      text
        ~style:(Theme.Palette.muted_style palette)
        ~wrap:`None ~truncate:true ~flex_shrink:100. ~min_size:zero_size
        ("(" ^ elapsed ^ ")");
    ]
