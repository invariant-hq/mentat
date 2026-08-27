(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Exact spellings from the executable declarations in [lib/tools] and the
   fixed host verbs in [lib/agent/step/catalog.ml]. Keep this exhaustive
   table literal: accepting removed aliases would make an obsolete call look
   current, while deriving a verb from a substring would misclassify extensions.

   Every tool name maps to its own verb so two tools never share a transcript
   label, and toolchain-backed tools carry their [Ocaml_] verb so a language-
   aware call is visibly distinct from a plain workspace call. [glob] is
   path-pattern search, not directory enumeration. Task-board state still
   renders from its own journal facts; these entries classify only the call
   header. *)
module Output_semantics = Mentat_tools_output

let verb_of_name = function
  | "read_file" -> Tool_block.Read
  | "search_text" -> Tool_block.Search
  | "glob" -> Tool_block.Glob
  | "edit_file" -> Tool_block.Edit
  | "apply_patch" -> Tool_block.Patch
  | "write_file" -> Tool_block.Create
  | "shell" -> Tool_block.Shell
  | "shell_output" -> Tool_block.Shell_output
  | "shell_kill" -> Tool_block.Shell_kill
  | "web_fetch" -> Tool_block.Fetch
  | "web_search" -> Tool_block.Web_search
  | "ocaml_search_expressions" -> Tool_block.Ocaml_search
  | "ocaml_ast_edit" -> Tool_block.Ocaml_edit
  | "ocaml_replace_expressions" -> Tool_block.Ocaml_replace
  | "ocaml_rename" -> Tool_block.Ocaml_rename
  | "ocaml_eval" -> Tool_block.Ocaml_eval
  | "ocaml_docs" -> Tool_block.Ocaml_docs
  | "ocaml_type_at" -> Tool_block.Ocaml_type
  | "ocaml_find_definitions" -> Tool_block.Ocaml_definition
  | "ocaml_find_references" -> Tool_block.Ocaml_references
  | "skill" -> Tool_block.Skill
  | "todo_write" -> Tool_block.Todo
  | "ask_user" -> Tool_block.Question
  | "propose_plan" -> Tool_block.Plan
  | "spawn" -> Tool_block.Task
  | "wait" -> Tool_block.Wait
  | "send" | "send_message" -> Tool_block.Message
  | "follow_up" -> Tool_block.Follow_up
  | name -> Tool_block.Other name

let name claim =
  Mentat_llm.Tool.Call.name (Mentat_session.Tool_claim.Started.call claim)

(* The header argument is the tool's own salient input, projected by the public
   presenter in the tools estate from the durable call input. That presenter
   owns every per-tool projection rule and yields no argument for tools whose
   content renders elsewhere and for unknown extensions. The local [!] shell
   keeps its verbatim command through [local_shell]. *)
let argument claim =
  let call = Mentat_session.Tool_claim.Started.call claim in
  Option.value ~default:""
    (Output_semantics.Argument.headline
       ~tool:(Mentat_llm.Tool.Call.name call)
       ~input:(Mentat_llm.Tool.Call.input call))

let make claim ~dot ~summary ?(facts = []) ?detail () =
  Tool_block.make
    (verb_of_name (name claim))
    ~argument:(argument claim) ~dot ~summary ~facts ?detail ()

let running claim = make claim ~dot:Tool_block.Running ~summary:"running" ()

let prepared claim ~description =
  make claim ~dot:Tool_block.Awaiting ~summary:description ()

let failure_fact : Mentat_tool.Result.failure -> string option = function
  | `Invalid_input -> Some "invalid input"
  | `Permission_denied -> Some "permission denied"
  | `Not_found -> Some "not found"
  | `Stale -> Some "stale"
  | `Unavailable -> Some "unavailable"
  | `Timed_out -> Some "timed out"
  | `Failed -> None

let output_fact ~partial output =
  if Mentat_tool.Output.truncated output then
    Some (if partial then "partial output truncated" else "output truncated")
  else None

let facts options = List.filter_map Fun.id options

let count number ~one ~many =
  Printf.sprintf "%d %s" number (if number = 1 then one else many)

let decode codec output = Output_semantics.Codec.decode codec output
let unavailable_details = "details unavailable"

(* Split durable text into semantic source rows without creating a presentation
   window. A final newline terminates the last row; it does not add a blank row.
   Every resulting row is passed to Mosaic, which owns viewport selection and
   overflow indication. *)
let source_rows text =
  if String.is_empty text then []
  else
    match List.rev (String.split_on_char '\n' text) with
    | "" :: rows -> List.rev rows
    | rows -> List.rev rows

let read_preview_height = 5

let read_detail output =
  let text = Mentat_tool.Output.text output in
  match String.index_opt text '\n' with
  | None -> None
  | Some header_end ->
      let body_start = header_end + 1 in
      let body = String.sub text body_start (String.length text - body_start) in
      let rows = source_rows body in
      if List.is_empty rows then None
      else
        Some
          (Tool_block.preview ~take:`First ~max_rows:read_preview_height rows)

let extension_preview_height = 5

let extension_detail output =
  match source_rows (Mentat_tool.Output.text output) with
  | [] -> None
  | rows ->
      Some
        (Tool_block.preview ~take:`First ~max_rows:extension_preview_height rows)

type presentation = {
  summary : string option;
  detail : Tool_block.detail option;
}

let known ?detail summary = { summary = Some summary; detail }
let extension output = { summary = None; detail = extension_detail output }

let read_presentation output =
  match decode Output_semantics.Read.jsont output with
  | Some (Output_semantics.Read.File { lines }) ->
      known ?detail:(read_detail output)
        ("Read " ^ count lines ~one:"line" ~many:"lines")
  | Some (Output_semantics.Read.Listing { entries }) ->
      known (count entries ~one:"entry" ~many:"entries")
  | Some Output_semantics.Read.Image -> known "Read image"
  | Some Output_semantics.Read.Unchanged -> known "unchanged"
  | None -> known unavailable_details

let search_summary output =
  match decode Output_semantics.Search.jsont output with
  | Some (Output_semantics.Search.Files { total }) ->
      "Found " ^ count total ~one:"file" ~many:"files"
  | Some (Output_semantics.Search.Matches { total; files }) ->
      Printf.sprintf "Found %s in %s"
        (count total ~one:"match" ~many:"matches")
        (count files ~one:"file" ~many:"files")
  | Some (Output_semantics.Search.Matching_lines { total }) ->
      "Found " ^ count total ~one:"matching line" ~many:"matching lines"
  | None -> unavailable_details

let write_summary output =
  match decode Output_semantics.Write.jsont output with
  | Some (Output_semantics.Write.Wrote { lines }) ->
      "Wrote " ^ count lines ~one:"line" ~many:"lines"
  | Some Output_semantics.Write.Unchanged -> "unchanged"
  | None -> unavailable_details

let update_summary output =
  match decode Output_semantics.Update.jsont output with
  | None -> unavailable_details
  | Some update ->
      let disposition =
        match Output_semantics.Update.disposition update with
        | Output_semantics.Update.Applied -> "Updated"
        | Output_semantics.Update.Previewed -> "Would update"
      in
      let summary =
        disposition ^ " "
        ^ count (Output_semantics.Update.files update) ~one:"file" ~many:"files"
      in
      let changes =
        List.filter_map Fun.id
          [
            Option.map (Printf.sprintf "+%d")
              (Output_semantics.Update.additions update);
            Option.map (Printf.sprintf "-%d")
              (Output_semantics.Update.deletions update);
          ]
      in
      let skipped = Output_semantics.Update.skipped update in
      let details =
        if skipped = 0 then changes
        else changes @ [ Printf.sprintf "%d skipped" skipped ]
      in
      if List.is_empty details then summary
      else summary ^ " (" ^ String.concat ", " details ^ ")"

let process_summary output =
  match decode Output_semantics.Process.jsont output with
  | None -> unavailable_details
  | Some process ->
      let elapsed =
        Printf.sprintf " in %d ms"
          (Output_semantics.Process.duration_ms process)
      in
      let completion =
        match Output_semantics.Process.termination process with
        | Output_semantics.Process.Exited 0 -> "Completed"
        | Output_semantics.Process.Exited code ->
            Printf.sprintf "Exited with code %d" code
        | Output_semantics.Process.Signaled signal ->
            Printf.sprintf "Terminated by signal %d" signal
        | Output_semantics.Process.Timed_out -> "Timed out"
        | Output_semantics.Process.Stopped -> "Stopped"
        | Output_semantics.Process.Output_limit { stream; limit } ->
            let stream =
              match stream with
              | Output_semantics.Process.Stdout -> "stdout"
              | Output_semantics.Process.Stderr -> "stderr"
            in
            Printf.sprintf "%s exceeded %d bytes" stream limit
        | Output_semantics.Process.Supervision_failed -> "Supervision failed"
      in
      completion ^ elapsed

let process_preview_height = 5

(* The command and evaluation transcripts share one convention: a leading
   metadata envelope, then the two captured streams under fixed [stdout:] and
   [stderr:] labels ([Shell] and [Ocaml.eval] both write it). The preview shows
   only the captured output, in stream order, without the envelope or the
   labels; an empty stream contributes no rows, so a run with no output has no
   preview at all. Text without the convention (an unexpected producer) falls
   back to its own rows unchanged. *)
let process_output_rows text =
  match String.split_first ~sep:"\n\nstdout:\n" text with
  | None -> source_rows text
  | Some (_envelope, streams) ->
      let out, err =
        match String.split_first ~sep:"\nstderr:\n" streams with
        | Some (out, err) -> (out, err)
        | None -> (streams, "")
      in
      source_rows out @ source_rows err

let process_detail output =
  match process_output_rows (Mentat_tool.Output.text output) with
  | [] -> None
  | rows ->
      Some
        (Tool_block.preview ~take:`Last ~max_rows:process_preview_height rows)

let process_presentation output =
  known ?detail:(process_detail output) (process_summary output)

let type_at_summary output =
  match decode Output_semantics.Ocaml.Type_at.jsont output with
  | None -> unavailable_details
  | Some result ->
      let head = Output_semantics.Ocaml.Type_at.head result in
      let more = Output_semantics.Ocaml.Type_at.more result in
      if more = 0 then head else Printf.sprintf "%s (+%d more)" head more

let definition_summary output =
  match decode Output_semantics.Ocaml.Definition.jsont output with
  | None -> unavailable_details
  | Some definition ->
      Printf.sprintf "%s:%d"
        (Output_semantics.Ocaml.Definition.path definition)
        (Output_semantics.Ocaml.Definition.line definition)

let references_summary output =
  match decode Output_semantics.Ocaml.References.jsont output with
  | None -> unavailable_details
  | Some result ->
      Printf.sprintf "Found %s in %s"
        (count
           (Output_semantics.Ocaml.References.references result)
           ~one:"reference" ~many:"references")
        (count
           (Output_semantics.Ocaml.References.files result)
           ~one:"file" ~many:"files")

let docs_summary output =
  match decode Output_semantics.Ocaml.Docs.jsont output with
  | None -> unavailable_details
  | Some result ->
      let clause number ~one ~many =
        if number = 0 then None else Some (count number ~one ~many)
      in
      let clauses =
        List.filter_map Fun.id
          [
            clause
              (Output_semantics.Ocaml.Docs.values result)
              ~one:"value" ~many:"values";
            clause
              (Output_semantics.Ocaml.Docs.types result)
              ~one:"type" ~many:"types";
            clause
              (Output_semantics.Ocaml.Docs.modules result)
              ~one:"module" ~many:"modules";
          ]
      in
      if List.is_empty clauses then "empty" else String.concat " · " clauses

let rename_summary output =
  match decode Output_semantics.Ocaml.Rename.jsont output with
  | None -> unavailable_details
  | Some result ->
      let action =
        match Output_semantics.Ocaml.Rename.disposition result with
        | Output_semantics.Ocaml.Rename.Applied -> "Renamed"
        | Output_semantics.Ocaml.Rename.Previewed -> "Would rename"
      in
      Printf.sprintf "%s %s in %s" action
        (count
           (Output_semantics.Ocaml.Rename.occurrences result)
           ~one:"occurrence" ~many:"occurrences")
        (count
           (Output_semantics.Ocaml.Rename.files result)
           ~one:"file" ~many:"files")

let web_fetch_summary output =
  match decode Output_semantics.Web.Fetch.jsont output with
  | None -> unavailable_details
  | Some result -> (
      let status = Output_semantics.Web.Fetch.status result in
      let bytes = Output_semantics.Web.Fetch.bytes result in
      match Output_semantics.Web.Fetch.disposition result with
      | Output_semantics.Web.Fetch.Fetched ->
          Printf.sprintf "Fetched %s (HTTP %d)"
            (count bytes ~one:"byte" ~many:"bytes")
            status
      | Output_semantics.Web.Fetch.Redirected ->
          Printf.sprintf "Redirected (HTTP %d)" status
      | Output_semantics.Web.Fetch.Http_error ->
          Printf.sprintf "HTTP error %d (%s)" status
            (count bytes ~one:"byte" ~many:"bytes"))

(* The exact tool name selects a small durable semantic codec. Known built-ins
   never promote undecodable text into a semantic summary. Unknown extension
   text remains available only as disclosure detail; Tool_block passes every
   row to Mosaic's viewport. *)
let completed_presentation tool output =
  match tool with
  | "read_file" -> read_presentation output
  | "glob" | "search_text" | "ocaml_search_expressions" ->
      known (search_summary output)
  | "write_file" -> known (write_summary output)
  | "edit_file" | "apply_patch" | "ocaml_ast_edit" | "ocaml_replace_expressions"
    ->
      known (update_summary output)
  | "ocaml_rename" -> known (rename_summary output)
  | "shell" | "ocaml_eval" -> process_presentation output
  | "ocaml_docs" -> known (docs_summary output)
  | "ocaml_type_at" -> known (type_at_summary output)
  | "ocaml_find_definitions" -> known (definition_summary output)
  | "ocaml_find_references" -> known (references_summary output)
  | "web_fetch" -> known (web_fetch_summary output)
  | _ -> extension output

(* Match [Result.to_model]'s durable ordering without lowering back through an
   LLM message: terminal detail first, then a known partial output's compact
   semantic summary. Unknown extension text stays in disclosure. Exact
   duplicates need only be shown once. *)
let terminal_summary message = function
  | None -> message
  | Some summary ->
      if String.equal message summary then summary
      else message ^ "\n\n" ^ summary

let settled ~verb ~argument ~tool result =
  let make ~dot ~summary ?(facts = []) ?detail () =
    Tool_block.make verb ~argument ~dot ~summary ~facts ?detail ()
  in
  let output = Mentat_tool.Result.output result in
  match (Mentat_tool.Result.status result, output) with
  | Mentat_tool.Result.Completed, Some output ->
      let presentation = completed_presentation tool output in
      make ~dot:Tool_block.Succeeded
        ~summary:(Option.value ~default:"done" presentation.summary)
        ~facts:(facts [ output_fact ~partial:false output ])
        ?detail:presentation.detail ()
  | Mentat_tool.Result.Completed, None ->
      (* The Result constructors make this arm unrepresentable. Keeping the
         renderer total at the abstract observer boundary is still preferable
         to turning a future owner regression into a transcript crash. *)
      make ~dot:Tool_block.Succeeded ~summary:"done" ()
  | Mentat_tool.Result.Failed { kind; message; metadata = _ }, output ->
      let truncated = Option.bind output (output_fact ~partial:true) in
      let presentation = Option.map (completed_presentation tool) output in
      make ~dot:Tool_block.Failed
        ~summary:
          (terminal_summary message
             (Option.bind presentation (fun p -> p.summary)))
        ~facts:(facts [ failure_fact kind; truncated ])
        ?detail:(Option.bind presentation (fun p -> p.detail))
        ()
  | Mentat_tool.Result.Interrupted { reason; cancelled }, output ->
      let interrupted = if cancelled then "cancelled" else "interrupted" in
      let truncated = Option.bind output (output_fact ~partial:true) in
      let presentation = Option.map (completed_presentation tool) output in
      make ~dot:Tool_block.Warned
        ~summary:
          (terminal_summary reason
             (Option.bind presentation (fun p -> p.summary)))
        ~facts:(facts [ Some interrupted; truncated ])
        ?detail:(Option.bind presentation (fun p -> p.detail))
        ()

let returned claim result =
  let tool = name claim in
  settled ~verb:(verb_of_name tool) ~argument:(argument claim) ~tool result

let local_shell ~command result =
  settled ~verb:Tool_block.Shell ~argument:command ~tool:"shell" result

let ambiguous claim =
  make claim ~dot:Tool_block.Ambiguous
    ~summary:"outcome unknown; the tool may have run" ()
