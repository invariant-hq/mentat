(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_protocol
open Mentat_session

module Error = struct
  type t =
    | No_active_turn
    | Turn_already_active of { active : Turn.Id.t; incoming : Turn.Id.t }
    | Turn_mismatch of { active : Turn.Id.t; incoming : Turn.Id.t }
    | Duplicate_tool_claim of Tool_claim.Id.t
    | Unknown_tool_claim of Tool_claim.Id.t
    | Wrong_tool_stage of {
        claim : Tool_claim.Id.t;
        expected : Mentat_tool.Stage.t;
        actual : Mentat_tool.Stage.t;
      }
    | Decision_already_pending of {
        pending : Decision.Id.t;
        incoming : Decision.Id.t;
      }
    | Unknown_decision of {
        pending : Decision.Id.t option;
        incoming : Decision.Id.t;
      }
    | Open_state_at_settlement of {
        turn : Turn.Id.t;
        tool_claims : int;
        decision_pending : bool;
      }
    | Assistant_message

  let turn_id id = Turn.Id.to_string id
  let tool_id id = Tool_claim.Id.to_string id
  let decision_id id = Decision.Id.to_string id

  let message = function
    | No_active_turn -> "turn-scoped fact arrived with no active turn"
    | Turn_already_active { active; incoming } ->
        Printf.sprintf "turn %s started while turn %s is still active"
          (turn_id incoming) (turn_id active)
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

  let equal a b =
    match (a, b) with
    | No_active_turn, No_active_turn | Assistant_message, Assistant_message ->
        true
    | Turn_already_active a, Turn_already_active b ->
        Turn.Id.equal a.active b.active && Turn.Id.equal a.incoming b.incoming
    | Turn_mismatch a, Turn_mismatch b ->
        Turn.Id.equal a.active b.active && Turn.Id.equal a.incoming b.incoming
    | Duplicate_tool_claim a, Duplicate_tool_claim b
    | Unknown_tool_claim a, Unknown_tool_claim b ->
        Tool_claim.Id.equal a b
    | Wrong_tool_stage a, Wrong_tool_stage b ->
        Tool_claim.Id.equal a.claim b.claim
        && Mentat_tool.Stage.equal a.expected b.expected
        && Mentat_tool.Stage.equal a.actual b.actual
    | Decision_already_pending a, Decision_already_pending b ->
        Decision.Id.equal a.pending b.pending
        && Decision.Id.equal a.incoming b.incoming
    | Unknown_decision a, Unknown_decision b ->
        Option.equal Decision.Id.equal a.pending b.pending
        && Decision.Id.equal a.incoming b.incoming
    | Open_state_at_settlement a, Open_state_at_settlement b ->
        Turn.Id.equal a.turn b.turn
        && Int.equal a.tool_claims b.tool_claims
        && Bool.equal a.decision_pending b.decision_pending
    | _ -> false

  let pp ppf error = Format.pp_print_string ppf (message error)
end

(* ── Accumulator ────────────────────────────────────────────────────────── *)

type phase = Idle | Running of Turn.t

type tool =
  | Running_tool of { claim : Tool_claim.Started.t; started : float }
  | Prepared_tool of {
      claim : Tool_claim.Started.t;
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
  retry_delay : float;
  retry_reason : string;
}

type writing = {
  writing_name : string option; (* The tool once the stream has named it. *)
  writing_received : int;
      (* Cumulative input bytes of that call — each pulse carries the whole
         count, so the latest pulse alone is rendered. *)
}

type acc = {
  phase : phase;
  turn_started : float;
  assistant : string;
  assistant_visible : bool;
  reasoning : string;
  reasoning_visible : bool;
  tools : tool list;
  pending_decision : Decision.Requested.t option;
  board : Task.Board.t option;
  workspace : workspace option;
  committed_output : int;
  step_output : int;
  compacting : bool;
  downloading : Progress.Model_download.t option;
  writing : writing option;
  retrying : retrying option;
  provider_failure_reported : Provider_request.Id.t option;
  queue : Mentat_session.Queue.Update.t option;
}

let initial =
  {
    phase = Idle;
    turn_started = 0.;
    assistant = "";
    assistant_visible = false;
    reasoning = "";
    reasoning_visible = false;
    tools = [];
    pending_decision = None;
    board = None;
    workspace = None;
    committed_output = 0;
    step_output = 0;
    compacting = false;
    downloading = None;
    writing = None;
    retrying = None;
    provider_failure_reported = None;
    queue = None;
  }

(* ── Small text helpers ─────────────────────────────────────────────────── *)

let visible text = String.trim text <> ""
let add_saturating a b = if b > max_int - a then max_int else a + b

let elapsed_seconds ~now started =
  let elapsed = now -. started in
  if Float.is_nan elapsed || elapsed <= 0. then 0
  else if elapsed >= Float.of_int max_int then max_int
  else int_of_float elapsed

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

let duration_text seconds =
  if seconds < 60 then string_of_int seconds ^ "s"
  else Printf.sprintf "%dm %02ds" (seconds / 60) (seconds mod 60)

let content_text content =
  List.filter_map
    (function
      | Mentat_llm.Content.Text text -> if visible text then Some text else None
      | Mentat_llm.Content.Media { media_type; _ } ->
          Some ("[media: " ^ media_type ^ "]"))
    content
  |> String.concat "\n\n"

(* ── DOM ids and swap attributes ────────────────────────────────────────── *)

let seq_id position = "f-" ^ string_of_int (Position.seq position)
let tool_dom_id claim_id = "tool-" ^ Tool_claim.Id.to_string claim_id

let decision_dom_id decision_id =
  "decision-" ^ Decision.Id.to_string decision_id

let open_id turn_id = "turn-" ^ Turn.Id.to_string turn_id ^ "-open"
let user_id turn_id = "turn-" ^ Turn.Id.to_string turn_id ^ "-user"
let reasoning_id turn_id = "turn-" ^ Turn.Id.to_string turn_id ^ "-reasoning"

let committed ~id ~cls =
  [
    Html.At.id id;
    Html.At.class_ cls;
    Html.At.data "swap" "append";
    Html.At.data "target" "transcript";
  ]

let prewrap children = Html.El.p ~at:[ Html.At.class_ "prewrap" ] children

(* ── Markdown ───────────────────────────────────────────────────────────── *)

(* The settled assistant projection (Risk 2): parse with cmarkit, then fold the
   AST into escaping [Html.El] combinators. Every text node passes through
   [El.txt]; cmarkit's own HTML renderer is never used, so no attacker byte
   reaches [unsafe_raw]. A code block is a plain escaped [<pre><code>] with a
   [language-x] class and no highlighting (Risk 3). A link destination is
   dropped when cmarkit deems its URL unsafe, defeating a [javascript:] URL. *)
module Markdown = struct
  open Cmarkit

  let language_class code_block =
    match Block.Code_block.info_string code_block with
    | None -> []
    | Some (info, _) -> (
        match Block.Code_block.language_of_info_string info with
        | Some (language, _) -> [ Html.At.class_ ("language-" ^ language) ]
        | None -> [])

  let code_text code_block =
    String.concat "\n"
      (List.map Block_line.to_string (Block.Code_block.code code_block))

  let html_block_text lines =
    String.concat "\n" (List.map Block_line.to_string lines)

  let raw_html_text tight_lines =
    String.concat "" (List.map Block_line.tight_to_string tight_lines)

  let link_dest defs link =
    match Inline.Link.reference_definition defs link with
    | Some (Link_definition.Def (definition, _)) -> (
        match Link_definition.dest definition with
        | Some (destination, _) -> Some destination
        | None -> None)
    | _ -> None

  let rec inline defs = function
    | Inline.Text (text, _) -> [ Html.El.txt text ]
    | Inline.Break (break, _) -> (
        match Inline.Break.type' break with
        | `Hard -> [ Html.El.br () ]
        | `Soft -> [ Html.El.txt "\n" ])
    | Inline.Code_span (code_span, _) ->
        [ Html.El.code [ Html.El.txt (Inline.Code_span.code code_span) ] ]
    | Inline.Emphasis (emphasis, _) ->
        [ Html.El.em (inline defs (Inline.Emphasis.inline emphasis)) ]
    | Inline.Strong_emphasis (emphasis, _) ->
        [ Html.El.strong (inline defs (Inline.Emphasis.inline emphasis)) ]
    | Inline.Link (link, _) -> [ anchor defs link ]
    | Inline.Image (link, _) ->
        (* No remote <img>: render the alt text only. *)
        inline defs (Inline.Link.text link)
    | Inline.Autolink (autolink, _) -> [ auto defs autolink ]
    | Inline.Raw_html (raw, _) -> [ Html.El.txt (raw_html_text raw) ]
    | Inline.Inlines (inlines, _) -> List.concat_map (inline defs) inlines
    | _ -> []

  and anchor defs link =
    let text = inline defs (Inline.Link.text link) in
    match link_dest defs link with
    | Some url when not (Inline.Link.is_unsafe url) ->
        Html.El.a ~at:[ Html.At.href url ] text
    | _ -> Html.El.splice text

  and auto _defs autolink =
    let url, _ = Inline.Autolink.link autolink in
    let href =
      if Inline.Autolink.is_email autolink then "mailto:" ^ url else url
    in
    if Inline.Link.is_unsafe href then Html.El.txt url
    else Html.El.a ~at:[ Html.At.href href ] [ Html.El.txt url ]

  let rec block defs = function
    | Block.Paragraph (paragraph, _) ->
        [ Html.El.p (inline defs (Block.Paragraph.inline paragraph)) ]
    | Block.Heading (heading, _) ->
        [
          Html.El.h
            (Block.Heading.level heading)
            (inline defs (Block.Heading.inline heading));
        ]
    | Block.Code_block (code_block, _) ->
        [
          Html.El.pre
            [
              Html.El.code
                ~at:(language_class code_block)
                [ Html.El.txt (code_text code_block) ];
            ];
        ]
    | Block.Block_quote (quote, _) ->
        [ Html.El.blockquote (block defs (Block.Block_quote.block quote)) ]
    | Block.List (list, _) -> [ list_block defs list ]
    | Block.Thematic_break _ -> [ Html.El.hr () ]
    | Block.Html_block (lines, _) ->
        (* Escaped, never raw: model-authored HTML is attacker-influenceable. *)
        [ Html.El.pre [ Html.El.code [ Html.El.txt (html_block_text lines) ] ] ]
    | Block.Blocks (blocks, _) -> List.concat_map (block defs) blocks
    | Block.Blank_line _ | Block.Link_reference_definition _ -> []
    | _ -> []

  and list_block defs list =
    let items =
      List.map
        (fun (item, _) -> Html.El.li (block defs (Block.List_item.block item)))
        (Block.List'.items list)
    in
    match Block.List'.type' list with
    | `Ordered _ -> Html.El.ol items
    | `Unordered _ -> Html.El.ul items

  let render text =
    let doc = Doc.of_string ~strict:true text in
    block (Doc.defs doc) (Doc.block doc)
end

(* ── Committed block builders ───────────────────────────────────────────── *)

let user_article ~id text =
  Html.El.article
    ~at:(committed ~id ~cls:"msg user")
    [ prewrap [ Html.El.txt text ] ]

let reasoning_summary_text response =
  String.concat "\n\n" (Mentat_llm.Response.reasoning_summary response)

let reasoning_details ~id response =
  let body = reasoning_summary_text response in
  if not (visible body) then []
  else
    [
      Html.El.details
        ~at:(committed ~id ~cls:"reasoning")
        [
          Html.El.summary [ Html.El.txt "Thinking" ];
          prewrap [ Html.El.txt body ];
        ];
    ]

let assistant_article ~id response =
  let text = Mentat_llm.Response.text response in
  if not (visible text) then []
  else
    [
      Html.El.article
        ~at:(committed ~id ~cls:"msg assistant")
        (Markdown.render text);
    ]

let assistant_interrupted ~id text =
  if not (visible text) then []
  else
    [
      Html.El.article
        ~at:(committed ~id ~cls:"msg assistant interrupted")
        [ prewrap [ Html.El.txt text ] ];
    ]

let notice_failure ~id ~message =
  let message =
    if visible message then message else "The model provider failed."
  in
  Html.El.aside
    ~at:(committed ~id ~cls:"notice failure")
    [
      Html.El.p [ Html.El.txt message ];
      Html.El.p
        ~at:[ Html.At.class_ "next" ]
        [ Html.El.txt "Tell mentat how to proceed." ];
    ]

let notice_event ~id text =
  Html.El.aside ~at:(committed ~id ~cls:"notice event") [ Html.El.txt text ]

(* A durable workspace observation: the level as a class, a source-and-title
   head, and the whole multi-line body preformatted — the committed twin of the
   ephemeral {!notice_frag}, mirroring the TUI transcript's full multi-line
   rendering rather than the truncated one-row glance. *)
let notice_workspace ~id notice =
  let severity =
    match Mentat_session.Notice.severity notice with
    | Mentat_session.Notice.Severity.Error -> "failure"
    | Mentat_session.Notice.Severity.Warning -> "warning"
    | Mentat_session.Notice.Severity.Info -> "info"
  in
  let head =
    Mentat_session.Notice.source notice
    ^ " \u{2014} "
    ^ Mentat_session.Notice.title notice
  in
  let body =
    match Mentat_session.Notice.body notice with
    | Some body when visible body ->
        [ Html.El.pre [ Html.El.code [ Html.El.txt body ] ] ]
    | Some _ | None -> []
  in
  Html.El.aside
    ~at:(committed ~id ~cls:("notice workspace " ^ severity))
    (Html.El.p [ Html.El.txt head ] :: body)

let seam ~id label =
  Html.El.hr ~at:(Html.At.data "label" label :: committed ~id ~cls:"seam") ()

(* The tool-row projection is deliberately minimal (Risk 3): the verb is the
   registered tool name, the summary is the durable result's own status word,
   and the full durable output is disclosure detail. The rich verb table and
   built-in output decoders live in [lib/tui/tool_distill.ml] (Mosaic-coupled);
   this half does not link them and does not duplicate the table. *)
let output_detail text =
  if not (visible text) then []
  else
    [
      Html.El.details
        [
          Html.El.summary [ Html.El.txt "output" ];
          Html.El.pre [ Html.El.code [ Html.El.txt text ] ];
        ];
    ]

let settled_tool_row ~id ~name result =
  let dot, summary =
    match Mentat_tool.Result.status result with
    | Mentat_tool.Result.Completed -> ("done", "done")
    | Mentat_tool.Result.Failed { message; _ } ->
        ("failed", if visible message then message else "tool failed")
    | Mentat_tool.Result.Interrupted { reason; cancelled } ->
        ( (if cancelled then "cancelled" else "interrupted"),
          if visible reason then reason else "interrupted" )
  in
  let detail =
    match Mentat_tool.Result.output result with
    | Some output -> output_detail (Mentat_tool.Output.text output)
    | None -> []
  in
  Html.El.li
    ~at:(committed ~id ~cls:("tool " ^ dot))
    ([
       Html.El.span ~at:[ Html.At.class_ "verb" ] [ Html.El.txt name ];
       Html.El.span ~at:[ Html.At.class_ "summary" ] [ Html.El.txt summary ];
     ]
    @ detail)

let ambiguous_tool_row ~id ~name =
  Html.El.li
    ~at:(committed ~id ~cls:"tool ambiguous")
    [
      Html.El.span ~at:[ Html.At.class_ "verb" ] [ Html.El.txt name ];
      Html.El.span
        ~at:[ Html.At.class_ "summary" ]
        [
          Html.El.txt "the callback may have run; no terminal outcome recorded";
        ];
    ]

let generic_tool_row ~id result =
  let name = Mentat_llm.Tool.Result.name result in
  let failed = Mentat_llm.Tool.Result.is_error result in
  let texts = List.filter visible (Mentat_llm.Tool.Result.texts result) in
  let summary =
    match texts with
    | _ :: _ -> "done"
    | [] -> if failed then "tool failed" else "done"
  in
  let detail = output_detail (String.concat "\n\n" texts) in
  Html.El.li
    ~at:(committed ~id ~cls:("tool " ^ if failed then "failed" else "done"))
    ([
       Html.El.span ~at:[ Html.At.class_ "verb" ] [ Html.El.txt name ];
       Html.El.span ~at:[ Html.At.class_ "summary" ] [ Html.El.txt summary ];
     ]
    @ detail)

let answer_summary resolution =
  match Decision.Resolved.answer resolution with
  | Decision.Answer.Permission { answer; message } -> (
      match answer with
      | Mentat_permission.Answer.Allow _ -> "allowed"
      | Mentat_permission.Answer.Deny -> (
          match message with
          | Some m -> "denied — \"" ^ m ^ "\""
          | None -> "denied"))
  | Decision.Answer.Question answer -> (
      match answer with
      | Mentat_session.Question.Answer.Free text -> text
      | Mentat_session.Question.Answer.Choice index ->
          "choice " ^ string_of_int index)
  | Decision.Answer.Plan answer -> (
      match answer with
      | Mentat_session.Plan.Answer.Keep_planning -> "keep planning"
      | Mentat_session.Plan.Answer.Revise _ -> "revise"
      | Mentat_session.Plan.Answer.Approve _ -> "approved")

let decision_answered ~id resolution =
  Html.El.aside
    ~at:(committed ~id ~cls:"decision answered")
    [ Html.El.txt ("You answered: " ^ answer_summary resolution) ]

let delegation_link ~id edge =
  let child = Id.to_string (Delegation.child edge) in
  let label =
    match Delegation.description edge with Some d -> d | None -> child
  in
  Html.El.p
    ~at:(committed ~id ~cls:"delegation")
    [
      Html.El.txt "Delegated to child ";
      Html.El.a ~at:[ Html.At.href ("/session/" ^ child) ] [ Html.El.txt label ];
    ]

let compaction_label compaction =
  let text count =
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
  match Compaction.context compaction with
  | None -> "compacted"
  | Some context -> (
      match
        ( Compaction.Context_tokens.before context,
          Compaction.Context_tokens.after context )
      with
      | Some before, Some after ->
          Printf.sprintf "compacted ~%s → ~%s tokens" (text before) (text after)
      | Some before, None -> Printf.sprintf "compacted ~%s tokens" (text before)
      | None, Some after -> Printf.sprintf "compacted → ~%s tokens" (text after)
      | None, None -> "compacted")

(* ── Workspace evidence and outcome (settlement) ────────────────────────── *)

let unique strings =
  List.fold_left
    (fun seen string ->
      if List.exists (String.equal string) seen then seen else string :: seen)
    [] strings
  |> List.rev

let workspace_facts (w : workspace) =
  let stats = w.totals in
  let exact =
    if w.change_rows = 0 then []
    else
      [
        Printf.sprintf "%d file%s" stats.Textdiff.files
          (if stats.Textdiff.files = 1 then "" else "s");
        Printf.sprintf "+%d -%d" stats.Textdiff.additions
          stats.Textdiff.deletions;
      ]
  in
  let observed = Mentat_workspace.Path.Set.cardinal w.observed in
  let observed_facts =
    if observed = 0 then []
    else
      [
        Printf.sprintf "%d path%s observed" observed
          (if observed = 1 then "" else "s");
      ]
  in
  let revertability =
    w.revertability
    |> List.filter_map (function
      | Mentat_mutation.Revertability.Available -> None
      | Mentat_mutation.Revertability.Unavailable _ as answer ->
          Some (Mentat_mutation.Revertability.message answer)
      | Mentat_mutation.Revertability.Incomplete _ -> Some "revert incomplete")
    |> unique
  in
  let revertability =
    if revertability <> [] then revertability
    else if w.ambiguous then
      [ "recorded changes are revertible; tool outcome remains unknown" ]
    else [ "revert available" ]
  in
  exact @ observed_facts @ revertability

let workspace_evidence ~id (w : workspace) =
  let source =
    if w.ambiguous then "workspace may still be changing"
    else "workspace changed"
  in
  Html.El.aside
    ~at:(committed ~id ~cls:"notice data")
    [
      Html.El.p ~at:[ Html.At.class_ "source" ] [ Html.El.txt source ];
      Html.El.ul
        (List.map
           (fun fact -> Html.El.li [ Html.El.txt fact ])
           (workspace_facts w));
    ]

let outcome_blocks ~id ~provider_failure_reported outcome =
  match outcome with
  | Turn.Outcome.Completed -> []
  | Turn.Outcome.Step_limit ->
      [
        notice_event ~id
          "The turn stopped at its step limit — the cap on model responses.";
      ]
  | Turn.Outcome.Interrupted _ -> [ notice_event ~id "Interrupted." ]
  | Turn.Outcome.Failed { message } ->
      if provider_failure_reported then []
      else
        let message = if visible message then message else "The turn failed." in
        [ notice_failure ~id ~message ]

let worked_notice ~id ~elapsed ~output =
  let tokens =
    if output = 0 then ""
    else Printf.sprintf " · ↓ %s tokens" (token_text output)
  in
  notice_event ~id
    (Printf.sprintf "Worked for %s%s" (duration_text elapsed) tokens)

(* ── Accumulator manipulation ───────────────────────────────────────────── *)

let active_id = function Running turn -> Some (Turn.id turn) | Idle -> None
let in_flight acc = match acc.phase with Idle -> false | Running _ -> true

let ensure_turn acc incoming =
  match active_id acc.phase with
  | None -> Error Error.No_active_turn
  | Some active ->
      if Turn.Id.equal active incoming then Ok ()
      else Error (Error.Turn_mismatch { active; incoming })

let tool_claim = function
  | Running_tool { claim; _ } | Prepared_tool { claim; _ } -> claim

let tool_id tool = Tool_claim.Started.id (tool_claim tool)

let tool_call_id tool =
  Mentat_llm.Tool.Call.id (Tool_claim.Started.call (tool_claim tool))

let find_tool claim tools =
  List.find_opt (fun tool -> Tool_claim.Id.equal (tool_id tool) claim) tools

let remove_tool claim tools =
  List.filter (fun tool -> not (Tool_claim.Id.equal (tool_id tool) claim)) tools

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

let clear_model acc =
  {
    acc with
    assistant = "";
    assistant_visible = false;
    reasoning = "";
    reasoning_visible = false;
    step_output = 0;
    compacting = false;
    downloading = None;
    writing = None;
    retrying = None;
  }

let add_evidence ~ambiguous evidence acc =
  match evidence with
  | None -> acc
  | Some (evidence : Fact.evidence) ->
      let previous =
        match acc.workspace with
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
      { acc with workspace = Some workspace }

let user_input_blocks ~id turn =
  match (Turn.origin turn, Turn.input turn) with
  | ( (Turn.Origin.User | Turn.Origin.Queued _ | Turn.Origin.Triggered _),
      Turn.Input.User content ) ->
      let text = content_text content in
      if visible text then [ user_article ~id text ] else []
  | _ -> []

(* ── Committed fold ─────────────────────────────────────────────────────── *)

let fact ~now acc position f =
  let id = seq_id position in
  match f with
  | Fact.Turn_started turn -> (
      let incoming = Turn.id turn in
      match acc.phase with
      | Running active ->
          Error
            (Error.Turn_already_active { active = Turn.id active; incoming })
      | Idle ->
          let acc = { initial with phase = Running turn; turn_started = now } in
          Ok (acc, user_input_blocks ~id:(user_id incoming) turn))
  | Fact.Turn_assistant response -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ ->
          let step_final =
            match Mentat_llm.Response.usage response with
            | Some usage -> Mentat_llm.Usage.output_total usage
            | None -> acc.step_output
          in
          let blocks =
            reasoning_details ~id:(id ^ "-reasoning") response
            @ assistant_article ~id response
          in
          let acc = clear_model acc in
          let acc =
            {
              acc with
              committed_output = add_saturating acc.committed_output step_final;
            }
          in
          Ok (acc, blocks))
  | Fact.Turn_assistant_interrupted { text } -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ ->
          let acc = clear_model acc in
          Ok (acc, assistant_interrupted ~id text))
  | Fact.Turn_provider_failed { claim; error } -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ ->
          let acc = clear_model acc in
          Ok
            ( { acc with provider_failure_reported = Some claim },
              [ notice_failure ~id ~message:(Mentat_llm.Error.message error) ]
            ))
  | Fact.Turn_message message -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match message with
          | Mentat_llm.Message.Assistant _ -> Error Error.Assistant_message
          | Mentat_llm.Message.User content ->
              let text = content_text content in
              let blocks =
                if visible text then [ user_article ~id text ] else []
              in
              Ok (acc, blocks)
          | Mentat_llm.Message.System text ->
              let blocks =
                if visible text then [ notice_event ~id ("System — " ^ text) ]
                else []
              in
              Ok (acc, blocks)
          | Mentat_llm.Message.Developer text ->
              let blocks =
                if visible text then
                  [ notice_event ~id ("Developer — " ^ text) ]
                else []
              in
              Ok (acc, blocks)
          | Mentat_llm.Message.Tool_result result ->
              let tools =
                remove_tool_call
                  (Mentat_llm.Tool.Result.call_id result)
                  acc.tools
              in
              Ok ({ acc with tools }, [ generic_tool_row ~id result ])))
  | Fact.Turn_settled { turn; outcome } -> (
      match ensure_turn acc turn with
      | Error error -> Error error
      | Ok () ->
          let tool_claims = List.length acc.tools in
          let decision_pending = Option.is_some acc.pending_decision in
          if tool_claims > 0 || decision_pending then
            Error
              (Error.Open_state_at_settlement
                 { turn; tool_claims; decision_pending })
          else
            let workspace =
              match acc.workspace with
              | None -> []
              | Some workspace ->
                  [ workspace_evidence ~id:(id ^ "-workspace") workspace ]
            in
            let outcome_blocks =
              outcome_blocks ~id:(id ^ "-outcome")
                ~provider_failure_reported:
                  (Option.is_some acc.provider_failure_reported)
                outcome
            in
            let worked =
              match outcome with
              | Turn.Outcome.Completed ->
                  let elapsed = elapsed_seconds ~now acc.turn_started in
                  if elapsed <= 0 then []
                  else
                    [
                      worked_notice ~id:(id ^ "-worked") ~elapsed
                        ~output:acc.committed_output;
                    ]
              | Turn.Outcome.Step_limit | Turn.Outcome.Interrupted _
              | Turn.Outcome.Failed _ ->
                  []
            in
            Ok (initial, workspace @ outcome_blocks @ worked))
  | Fact.Tool_started claim -> (
      let incoming = Tool_claim.Started.turn claim in
      match ensure_turn acc incoming with
      | Error error -> Error error
      | Ok () ->
          let claim_id = Tool_claim.Started.id claim in
          if Option.is_some (find_tool claim_id acc.tools) then
            Error (Error.Duplicate_tool_claim claim_id)
          else
            let started = Running_tool { claim; started = now } in
            let call_id =
              Mentat_llm.Tool.Call.id (Tool_claim.Started.call claim)
            in
            let tools =
              match Tool_claim.Started.stage claim with
              | Mentat_tool.Stage.Run ->
                  replace_prepared_call ~call_id started acc.tools
              | Mentat_tool.Stage.Direct | Mentat_tool.Stage.Prepare ->
                  started :: acc.tools
            in
            Ok ({ acc with tools }, []))
  | Fact.Tool_prepared { claim; description; requests } -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match find_tool claim acc.tools with
          | None -> Error (Error.Unknown_tool_claim claim)
          | Some tool ->
              let started = tool_claim tool in
              let actual = Tool_claim.Started.stage started in
              if not (Mentat_tool.Stage.equal actual Mentat_tool.Stage.Prepare)
              then
                Error
                  (Error.Wrong_tool_stage
                     { claim; expected = Mentat_tool.Stage.Prepare; actual })
              else
                let tools =
                  List.map
                    (fun tool ->
                      if Tool_claim.Id.equal (tool_id tool) claim then
                        Prepared_tool { claim = started; description; requests }
                      else tool)
                    acc.tools
                in
                Ok ({ acc with tools }, [])))
  | Fact.Tool_returned { claim; result; mutation } -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match find_tool claim acc.tools with
          | None -> Error (Error.Unknown_tool_claim claim)
          | Some tool ->
              let started = tool_claim tool in
              let name =
                Mentat_llm.Tool.Call.name (Tool_claim.Started.call started)
              in
              let acc = { acc with tools = remove_tool claim acc.tools } in
              let acc = add_evidence ~ambiguous:false mutation acc in
              Ok (acc, [ settled_tool_row ~id ~name result ])))
  | Fact.Tool_ambiguous { claim; mutation } -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          match find_tool claim acc.tools with
          | None -> Error (Error.Unknown_tool_claim claim)
          | Some tool ->
              let started = tool_claim tool in
              let name =
                Mentat_llm.Tool.Call.name (Tool_claim.Started.call started)
              in
              let acc = { acc with tools = remove_tool claim acc.tools } in
              let acc = add_evidence ~ambiguous:true mutation acc in
              Ok (acc, [ ambiguous_tool_row ~id ~name ])))
  | Fact.Decision_requested request -> (
      let incoming = Decision.Requested.turn request in
      match ensure_turn acc incoming with
      | Error error -> Error error
      | Ok () -> (
          match acc.pending_decision with
          | None -> Ok ({ acc with pending_decision = Some request }, [])
          | Some pending ->
              Error
                (Error.Decision_already_pending
                   {
                     pending = Decision.Requested.id pending;
                     incoming = Decision.Requested.id request;
                   })))
  | Fact.Decision_resolved resolution -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> (
          let incoming = Decision.Resolved.id resolution in
          let pending_id =
            Option.map Decision.Requested.id acc.pending_decision
          in
          match acc.pending_decision with
          | Some pending when Decision.matches pending resolution ->
              let tools =
                match Decision.Resolved.answer resolution with
                | Decision.Answer.Permission
                    {
                      answer =
                        ( Mentat_permission.Answer.Allow _
                        | Mentat_permission.Answer.Deny );
                      _;
                    } ->
                    remove_tool_call
                      (Decision.Requested.call_id pending)
                      acc.tools
                | Decision.Answer.Question _ | Decision.Answer.Plan _ ->
                    acc.tools
              in
              Ok
                ( { acc with pending_decision = None; tools },
                  [ decision_answered ~id resolution ] )
          | None | Some _ ->
              Error (Error.Unknown_decision { pending = pending_id; incoming }))
      )
  | Fact.Journal_task_board board -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> Ok ({ acc with board = Some board }, []))
  | Fact.Compaction compaction ->
      let acc = clear_model acc in
      let committed_output =
        match Compaction.usage compaction with
        | None -> acc.committed_output
        | Some usage ->
            add_saturating acc.committed_output
              (Mentat_llm.Usage.output_total usage)
      in
      Ok
        ( { acc with committed_output },
          [ seam ~id (compaction_label compaction) ] )
  | Fact.Workspace_notice notice -> (
      match active_id acc.phase with
      | None -> Error Error.No_active_turn
      | Some _ -> Ok (acc, [ notice_workspace ~id notice ]))
  | Fact.Journal_goal _ -> Ok (acc, [])
  | Fact.Journal_queue update -> Ok ({ acc with queue = Some update }, [])
  | Fact.Undo { update; dropped_turns; _ } -> (
      (* An armed undo boundary renders a seam; a released one clears it. *)
      match Undo.Update.anchor update with
      | None -> Ok (acc, [])
      | Some _ ->
          let label =
            Printf.sprintf "%d turn%s undone" dropped_turns
              (if dropped_turns = 1 then "" else "s")
          in
          Ok (acc, [ seam ~id label ]))
  | Fact.Journal_delegation edge -> (
      let incoming = Delegation.source_turn edge in
      match ensure_turn acc incoming with
      | Error error -> Error error
      | Ok () -> Ok (acc, [ delegation_link ~id edge ]))

(* ── Progress fold ──────────────────────────────────────────────────────── *)

let assistant_delta text acc =
  if String.equal text "" then acc
  else
    {
      acc with
      assistant = acc.assistant ^ text;
      assistant_visible = acc.assistant_visible || visible text;
      compacting = false;
    }

let progress acc pulse =
  let applies turn =
    match active_id acc.phase with
    | Some active -> Turn.Id.equal active turn
    | None -> false
  in
  match pulse with
  | Progress.Model { turn; update } when applies turn -> (
      match update with
      | Progress.Model.Started ->
          {
            acc with
            assistant = "";
            assistant_visible = false;
            reasoning = "";
            reasoning_visible = false;
            step_output = 0;
            compacting = false;
            downloading = None;
            writing = None;
            retrying = None;
          }
      | Progress.Model.Assistant_delta { text } ->
          assistant_delta text { acc with retrying = None }
      | Progress.Model.Reasoning_delta { text } ->
          {
            acc with
            reasoning = acc.reasoning ^ text;
            reasoning_visible = acc.reasoning_visible || visible text;
            compacting = false;
            retrying = None;
          }
      | Progress.Model.Usage usage ->
          {
            acc with
            step_output = Mentat_llm.Usage.output_total usage;
            retrying = None;
          }
      | Progress.Model.Tool_input { name; received } ->
          {
            acc with
            writing = Some { writing_name = name; writing_received = received };
            compacting = false;
            retrying = None;
          }
      | Progress.Model.Retrying retry ->
          {
            acc with
            retrying =
              Some
                {
                  retry_attempt = Mentat_llm.Event.Retry.attempt retry;
                  retry_limit = Mentat_llm.Event.Retry.limit retry;
                  retry_delay = Mentat_llm.Event.Retry.delay retry;
                  retry_reason = Mentat_llm.Event.Retry.reason retry;
                };
          })
  | Progress.Model_download { turn; update } when applies turn -> (
      match update.Progress.Model_download.phase with
      | Progress.Model_download.Ready -> { acc with downloading = None }
      | Progress.Model_download.Checking | Progress.Model_download.Downloading
      | Progress.Model_download.Verifying ->
          { acc with downloading = Some update })
  | Progress.Compaction { turn; update } when applies turn -> (
      match update with
      | Progress.Compaction.Started _ | Progress.Compaction.Summarizing ->
          { acc with compacting = true }
      | Progress.Compaction.Failed _ -> { acc with compacting = false })
  | Progress.Model _ | Progress.Model_download _ | Progress.Compaction _ ->
      acc

(* ── Live region builders ───────────────────────────────────────────────── *)

let active_turn_id acc =
  match acc.phase with Running turn -> Some (Turn.id turn) | Idle -> None

let reasoning_ticker acc =
  if not acc.reasoning_visible then []
  else
    match active_turn_id acc with
    | None -> []
    | Some turn_id ->
        [
          Html.El.details
            ~at:
              [
                Html.At.id (reasoning_id turn_id);
                Html.At.class_ "reasoning";
                Html.At.bool "open" true;
              ]
            [
              Html.El.summary [ Html.El.txt "Thinking" ];
              prewrap [ Html.El.txt acc.reasoning ];
            ];
        ]

let open_assistant acc =
  if not acc.assistant_visible then []
  else
    match active_turn_id acc with
    | None -> []
    | Some turn_id ->
        [
          Html.El.article
            ~at:
              [
                Html.At.id (open_id turn_id);
                Html.At.class_ "msg assistant streaming";
              ]
            [ prewrap [ Html.El.txt acc.assistant ] ];
        ]

let running_tool_row tool =
  match tool with
  | Running_tool { claim; started } ->
      let name = Mentat_llm.Tool.Call.name (Tool_claim.Started.call claim) in
      Html.El.li
        ~at:
          [
            Html.At.id (tool_dom_id (Tool_claim.Started.id claim));
            Html.At.class_ "tool running";
            Html.At.data "started" (string_of_float started);
          ]
        [
          Html.El.span ~at:[ Html.At.class_ "verb" ] [ Html.El.txt name ];
          Html.El.span ~at:[ Html.At.class_ "spinner" ] [];
          Html.El.time [ Html.El.txt "0s" ];
        ]
  | Prepared_tool { claim; description; requests } ->
      let name = Mentat_llm.Tool.Call.name (Tool_claim.Started.call claim) in
      let count = List.length requests in
      let facts =
        if count = 0 then []
        else
          [
            Html.El.span
              ~at:[ Html.At.class_ "facts" ]
              [
                Html.El.txt
                  (Printf.sprintf "%d permission request%s" count
                     (if count = 1 then "" else "s"));
              ];
          ]
      in
      Html.El.li
        ~at:
          [
            Html.At.id (tool_dom_id (Tool_claim.Started.id claim));
            Html.At.class_ "tool awaiting";
          ]
        ([
           Html.El.span ~at:[ Html.At.class_ "verb" ] [ Html.El.txt name ];
           Html.El.span
             ~at:[ Html.At.class_ "summary" ]
             [ Html.El.txt description ];
         ]
        @ facts)

let tool_rows acc =
  match List.rev acc.tools with
  | [] -> []
  | tools ->
      [
        Html.El.ul
          ~at:[ Html.At.class_ "tools" ]
          (List.map running_tool_row tools);
      ]

let permission_fields review =
  let request = Mentat_permission.Policy.Review.request review in
  let display =
    match Mentat_permission.Request.display request with
    | Some display -> display
    | None -> "Permission requested"
  in
  let accesses = Mentat_permission.Policy.Review.accesses review in
  [
    Html.El.p [ Html.El.txt display ];
    Html.El.ul
      (List.map
         (fun access ->
           Html.El.li
             [ Html.El.txt (Mentat_permission.Access.stable_text access) ])
         accesses);
    Html.El.button
      ~at:
        [
          Html.At.type' "submit";
          Html.At.name "answer";
          Html.At.value "allow-once";
        ]
      [ Html.El.txt "Allow" ];
    Html.El.button
      ~at:
        [
          Html.At.type' "submit";
          Html.At.name "answer";
          Html.At.value "allow-always";
        ]
      [ Html.El.txt "Allow always" ];
    Html.El.button
      ~at:
        [ Html.At.type' "submit"; Html.At.name "answer"; Html.At.value "deny" ]
      [ Html.El.txt "Deny" ];
  ]

let question_fields question =
  Html.El.p [ Html.El.txt (Mentat_session.Question.prompt question) ]
  ::
  (match Mentat_session.Question.choices question with
  | None ->
      [
        Html.El.textarea ~at:[ Html.At.name "text" ] [];
        Html.El.button
          ~at:
            [
              Html.At.type' "submit";
              Html.At.name "answer";
              Html.At.value "free";
            ]
          [ Html.El.txt "Answer" ];
      ]
  | Some choices ->
      List.mapi
        (fun index choice ->
          Html.El.label
            [
              Html.El.input
                ~at:
                  [
                    Html.At.type' "radio";
                    Html.At.name "choice";
                    Html.At.value (string_of_int index);
                  ]
                ();
              Html.El.txt choice;
            ])
        choices
      @ [
          Html.El.button
            ~at:
              [
                Html.At.type' "submit";
                Html.At.name "answer";
                Html.At.value "choice";
              ]
            [ Html.El.txt "Select" ];
        ])

let plan_fields plan =
  let title =
    match Mentat_session.Plan.title plan with
    | Some title -> [ Html.El.h 3 [ Html.El.txt title ] ]
    | None -> []
  in
  title
  @ [
      Html.El.pre
        ~at:[ Html.At.class_ "plan" ]
        [ Html.El.txt (Mentat_session.Plan.body plan) ];
      Html.El.textarea
        ~at:[ Html.At.name "feedback"; Html.At.class_ "feedback" ]
        [];
      Html.El.button
        ~at:
          [
            Html.At.type' "submit";
            Html.At.name "answer";
            Html.At.value "approve";
          ]
        [ Html.El.txt "Approve" ];
      Html.El.button
        ~at:
          [
            Html.At.type' "submit";
            Html.At.name "answer";
            Html.At.value "revise";
          ]
        [ Html.El.txt "Revise" ];
      Html.El.button
        ~at:
          [
            Html.At.type' "submit";
            Html.At.name "answer";
            Html.At.value "keep-planning";
          ]
        [ Html.El.txt "Keep planning" ];
    ]

let decision_form ~session requested =
  let decision_id = Decision.Requested.id requested in
  let action =
    "/session/" ^ Id.to_string session ^ "/decision/"
    ^ Decision.Id.to_string decision_id
  in
  let fields =
    match Decision.Requested.request requested with
    | Decision.Request.Permission review -> permission_fields review
    | Decision.Request.Question question -> question_fields question
    | Decision.Request.Plan plan -> plan_fields plan
  in
  [
    Html.El.section
      ~at:
        [ Html.At.id (decision_dom_id decision_id); Html.At.class_ "decision" ]
      [
        Html.El.form
          ~at:[ Html.At.method' "post"; Html.At.action action ]
          fields;
      ];
  ]

let board_section acc =
  match acc.board with
  | None -> []
  | Some board ->
      [
        Html.El.section
          ~at:[ Html.At.id "board"; Html.At.class_ "board" ]
          [
            Html.El.ul
              (List.map
                 (fun item ->
                   Html.El.li
                     ~at:
                       [
                         Html.At.class_
                           ("task "
                           ^ Task.Status.to_string item.Task.Item.status);
                       ]
                     [ Html.El.txt item.Task.Item.content ])
                 (Task.Board.items board));
          ];
      ]


let queue_row acc =
  match acc.queue with
  | Some (Mentat_session.Queue.Update.Enqueued _) ->
      [
        Html.El.div
          ~at:[ Html.At.id "queue"; Html.At.class_ "queue" ]
          [ Html.El.txt "1 queued" ];
      ]
  | Some (Mentat_session.Queue.Update.Replaced entries) ->
      let count = List.length entries in
      if count = 0 then []
      else
        [
          Html.El.div
            ~at:[ Html.At.id "queue"; Html.At.class_ "queue" ]
            [ Html.El.txt (Printf.sprintf "%d queued" count) ];
        ]
  | Some Mentat_session.Queue.Update.Cleared | None -> []

let download_row acc =
  match acc.downloading with
  | None -> []
  | Some download ->
      let phase =
        match download.Progress.Model_download.phase with
        | Progress.Model_download.Checking -> "Preparing"
        | Progress.Model_download.Downloading -> "Downloading"
        | Progress.Model_download.Verifying -> "Verifying"
        | Progress.Model_download.Ready -> "Downloading"
      in
      [
        Html.El.div
          ~at:[ Html.At.class_ "download" ]
          [
            Html.El.progress [];
            Html.El.span
              [
                Html.El.txt
                  (phase ^ " " ^ download.Progress.Model_download.model);
              ];
          ];
      ]

let working_row acc =
  if not (in_flight acc) then []
  else
    let output = add_saturating acc.committed_output acc.step_output in
    let tokens =
      if output = 0 then ""
      else Printf.sprintf " · ↓ %s tokens" (token_text output)
    in
    let label =
      if Option.is_some acc.pending_decision then "Waiting for your answer"
      else
        match acc.retrying with
        | Some retry ->
            Printf.sprintf "%s — retry %d/%d · next attempt in %.0fs"
              (String.capitalize_ascii retry.retry_reason)
              retry.retry_attempt retry.retry_limit
              (Float.round retry.retry_delay)
        | None -> (
            if acc.compacting then "Compacting…"
            else
              match acc.writing with
              | Some { writing_name; writing_received } ->
                  Printf.sprintf "Writing %s… · %s"
                    (Option.value writing_name ~default:"tool call")
                    (byte_text writing_received)
              | None -> "Working…")
    in
    [
      Html.El.div
        ~at:
          [
            Html.At.class_ "working";
            Html.At.data "started" (string_of_float acc.turn_started);
          ]
        [
          Html.El.span ~at:[ Html.At.class_ "spinner" ] [];
          Html.El.txt (label ^ tokens);
        ];
    ]

let live ~now:_ ~session acc =
  let decision =
    match acc.pending_decision with
    | Some requested -> decision_form ~session requested
    | None -> []
  in
  let parts =
    List.concat
      [
        reasoning_ticker acc;
        open_assistant acc;
        tool_rows acc;
        decision;
        board_section acc;
        queue_row acc;
        download_row acc;
        working_row acc;
      ]
  in
  Html.El.div ~at:[ Html.At.id "live"; Html.At.data "swap" "morph" ] parts

(* ── Cold load ──────────────────────────────────────────────────────────── *)

let truncation_marker =
  Html.El.aside
    ~at:(committed ~id:"transcript-truncated" ~cls:"notice truncated")
    [ Html.El.txt "Earlier messages in this turn are not shown." ]

(* Fold a bounded window of committed facts. A bounded read (a tail page, a
   backward page, a feed-resume suffix) can begin partway through a turn whose
   opening [Turn_started] fell above the window; a turn-scoped fact then has no
   active turn and [fact] rejects it. That leading edge is a window boundary,
   not a projector bug, so it is absorbed and flagged [truncated] rather than
   rejected. Once a [Turn_started] establishes a turn context the fold is strict
   again: a later rejection is a genuine firewall violation. [strict] governs
   only that established-state rejection — a seed fold ([attach]) sets it
   [false] to stay total over trusted committed history; a rendering fold
   surfaces the violation so the firewall (the assistant-message lane, every
   reducer invariant) stays intact for what a page actually shows. *)
let scan ~now ~strict facts =
  let rec loop acc rev truncated established = function
    | [] -> (acc, List.rev rev, truncated, None)
    | (position, f) :: rest -> (
        match fact ~now acc position f with
        | Ok (acc, blocks) ->
            let established =
              established
              || match f with Fact.Turn_started _ -> true | _ -> false
            in
            loop acc (List.rev_append blocks rev) truncated established rest
        | Error error ->
            if established && strict then
              (acc, List.rev rev, truncated, Some error)
            else loop acc rev true established rest)
  in
  loop initial [] false false facts

let page ~now facts =
  let acc, blocks, _truncated, violation = scan ~now ~strict:true facts in
  match violation with Some error -> Error error | None -> Ok (acc, blocks)

let attach ~now facts =
  let acc, _blocks, _truncated, _violation = scan ~now ~strict:false facts in
  acc

let cold ~now ~session view =
  let tail_page = view.Transcript.Tail.page in
  let acc, blocks, truncated, violation =
    scan ~now ~strict:true tail_page.Transcript.Page.facts
  in
  match violation with
  | Some error -> Error error
  | None ->
      let acc =
        match view.Transcript.Tail.pending with
        | Some _ as pending -> { acc with pending_decision = pending }
        | None -> acc
      in
      let transcript =
        if truncated then truncation_marker :: blocks else blocks
      in
      let body =
        Html.El.div
          ~at:[ Html.At.id "session" ]
          [
            Html.El.div ~at:[ Html.At.id "transcript" ] transcript;
            live ~now ~session acc;
          ]
      in
      Ok (acc, body)
