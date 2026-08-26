(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Event = Mentat_session.Event
module Turn = Mentat_session.Turn
module Contract = Mentat_session.Contract
module Provider_request = Mentat_session.Provider_request
module Tool_claim = Mentat_session.Tool_claim
module Response = Mentat_llm.Response
module Message = Mentat_llm.Message
module Usage = Mentat_llm.Usage
module Tool = Mentat_llm.Tool
module Model = Mentat_llm.Model
module Options = Mentat_llm.Request.Options
module Json = Jsont.Json

(* Rendering helpers *)

let json_compact json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error _ -> ""

let elide max_bytes text =
  let length = String.length text in
  if length <= max_bytes || max_bytes <= 1 then text
  else
    let head = (max_bytes - 1) / 2 in
    let tail = max_bytes - 1 - head in
    String.sub text 0 head ^ "\xe2\x80\xa6"
    ^ String.sub text (length - tail) tail

module Call = struct
  type status = Ok | Failed | Rejected

  type t = {
    tool_call_id : string;
    name : string;
    arguments : Jsont.json;
    result_text : string;
    result_bytes : int;
    status : status;
    duration_s : float option;
    step_index : int;
  }

  let make ~tool_call_id ~name ~arguments ~result_text ~result_bytes ~status
      ~duration_s ~step_index =
    {
      tool_call_id;
      name;
      arguments;
      result_text;
      result_bytes;
      status;
      duration_s;
      step_index;
    }

  let tool_call_id t = t.tool_call_id
  let name t = t.name
  let arguments t = t.arguments
  let result_text t = t.result_text
  let status t = t.status
  let result_bytes t = t.result_bytes
  let duration_s t = t.duration_s
  let step_index t = t.step_index

  let string_field field t =
    match t.arguments with
    | Jsont.Object (members, _) -> (
        match Json.find_mem field members with
        | Some (_, Jsont.String (value, _)) -> Some value
        | Some _ | None -> None)
    | _ -> None

  let read_path t = if t.name = "read_file" then string_field "path" t else None

  let shell_command t =
    if t.name = "shell" then string_field "command" t else None

  let arguments_digest ?(max_bytes = 80) t =
    elide max_bytes (json_compact t.arguments)

  let result_digest ?(max_bytes = 80) t = elide max_bytes t.result_text

  let status_to_string : status -> string = function
    | Ok -> "ok"
    | Failed -> "failed"
    | Rejected -> "rejected"

  let pp_status ppf status =
    Format.pp_print_string ppf (status_to_string status)
end

module Step = struct
  type t = {
    index : int;
    segment_index : int;
    usage : Usage.t option;
    calls : Call.t list;
    duration_s : float option;
  }

  let make ~index ~segment_index ~usage ~calls ~duration_s =
    { index; segment_index; usage; calls; duration_s }

  let index t = t.index
  let segment_index t = t.segment_index
  let usage t = t.usage
  let calls t = t.calls
  let duration_s t = t.duration_s
end

type t = {
  steps : Step.t list;
  calls : Call.t list;
  segment_count : int;
  declared_tools : string list;
  model : Model.t option;
  reasoning_effort : Options.Reasoning_effort.t option;
}

(* Reconstruction *)

let result_text result = String.concat "\n" (Tool.Result.texts result)

let result_bytes result =
  List.fold_left
    (fun total text -> total + String.length text)
    0 (Tool.Result.texts result)

let unique_model models =
  match List.sort_uniq Model.compare models with
  | [ model ] -> Some model
  | _ -> None

let effort_key = function
  | None -> ""
  | Some effort -> Options.Reasoning_effort.to_string effort

let unique_effort efforts =
  match
    List.sort_uniq
      (fun a b -> String.compare (effort_key a) (effort_key b))
      efforts
  with
  | [ Some effort ] -> Some effort
  | _ -> None

let of_session ?(timing = Timing.empty) session =
  let events = Mentat_session.events session in
  (* A response tool call is answered exactly once: an executed call by a
     [Tool_settled] whose claim named it (keyed by the call id), a rejected
     call by a tool result appended without a claim — a permission denial or a
     directly appended error result. A tool claim carries its model call; its
     settlement carries only the claim id, so the two are joined on claim id and
     the settled tool-domain result is lowered to the model-visible answer the
     transcript would carry. *)
  let executed : (string, Tool.Result.t) Hashtbl.t = Hashtbl.create 64 in
  let rejected : (string, Tool.Result.t) Hashtbl.t = Hashtbl.create 16 in
  let claim_call : (string, Tool.Call.t) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun event ->
      match event with
      | Event.Tool_claimed started ->
          Hashtbl.replace claim_call
            (Tool_claim.Id.to_string (Tool_claim.Started.id started))
            (Tool_claim.Started.call started)
      | Event.Tool_settled settled -> (
          match Tool_claim.Settled.outcome settled with
          | Tool_claim.Settled.Returned result -> (
              let claim_id =
                Tool_claim.Id.to_string (Tool_claim.Settled.id settled)
              in
              match Hashtbl.find_opt claim_call claim_id with
              | None -> ()
              | Some call ->
                  let answer = Mentat_tool.Result.to_model ~call result in
                  Hashtbl.replace executed (Tool.Result.call_id answer) answer)
          | Tool_claim.Settled.Prepared _ | Tool_claim.Settled.Ambiguous -> ())
      | Event.Message_appended (Message.Tool_result result) ->
          Hashtbl.replace rejected (Tool.Result.call_id result) result
      (* Interrupted prose answers no tool call and carries no provider step
         metadata, so it contributes to neither result correlation nor the
         response-step trace below. *)
      | Event.Turn_started _ | Event.Message_appended _
      | Event.Provider_requested _ | Event.Provider_settled _
      | Event.Compaction_installed _ | Event.Decision_requested _
      | Event.Decision_resolved _ | Event.Interrupt_requested _
      | Event.Tasks_replaced _
      | Event.Delegation_recorded _ | Event.Delegations_detached
      | Event.Queue_updated _ | Event.Turn_finished _ | Event.Workspace_notice _
      | Event.Undo_updated _ ->
          ())
    events;
  (* A model-visible {e host} tool call is never claimed and never appended as a
     tool result, so it correlates to neither table and drops out here — the
     trace surfaces only executable calls. *)
  let call_of ~step_index call =
    let name = Tool.Call.name call in
    let build status result =
      let tool_call_id = Tool.Call.id call in
      let duration_s =
        match Timing.call_interval timing ~tool_call_id with
        | Some (started, finished) -> Some ((finished -. started) /. 1000.)
        | None -> None
      in
      Some
        (Call.make ~tool_call_id ~name ~arguments:(Tool.Call.input call)
           ~result_text:(result_text result) ~result_bytes:(result_bytes result)
           ~status ~duration_s ~step_index)
    in
    match Hashtbl.find_opt executed (Tool.Call.id call) with
    | Some result ->
        build
          (if Tool.Result.is_error result then Call.Failed else Call.Ok)
          result
    | None -> (
        match Hashtbl.find_opt rejected (Tool.Call.id call) with
        | Some result -> build Call.Rejected result
        | None -> None)
  in
  let step_duration calls =
    let intervals =
      List.filter_map
        (fun call ->
          Timing.call_interval timing ~tool_call_id:(Call.tool_call_id call))
        calls
    in
    match intervals with
    | [] -> None
    | first :: _ ->
        let started =
          List.fold_left
            (fun acc (s, _) -> Float.min acc s)
            (fst first) intervals
        in
        let finished =
          List.fold_left
            (fun acc (_, f) -> Float.max acc f)
            (snd first) intervals
        in
        Some ((finished -. started) /. 1000.)
  in
  let steps = ref [] in
  let step_index = ref 0 in
  let segment_index = ref 0 in
  let declared = ref [] in
  let models = ref [] in
  let efforts = ref [] in
  List.iter
    (fun event ->
      match event with
      | Event.Turn_started turn ->
          let contract = Turn.contract turn in
          declared :=
            List.rev_append
              (List.map Tool.name (Contract.declarations contract))
              !declared;
          models := Contract.model contract :: !models;
          efforts :=
            Options.reasoning_effort (Contract.options contract) :: !efforts
      | Event.Compaction_installed _ -> incr segment_index
      | Event.Provider_settled settled -> (
          match Provider_request.Settled.outcome settled with
          | Provider_request.Settled.Responded response ->
              let index = !step_index in
              incr step_index;
              let calls =
                List.filter_map
                  (call_of ~step_index:index)
                  (Response.tool_calls response)
              in
              steps :=
                Step.make ~index ~segment_index:!segment_index
                  ~usage:(Response.usage response) ~calls
                  ~duration_s:(step_duration calls)
                :: !steps
          (* A trace step is a completed provider response with optional usage
             and tool calls. An interrupted, failed, or crash-ambiguous
             settlement appends no response and is not a step. *)
          | Provider_request.Settled.Interrupted _
          | Provider_request.Settled.Failed _
          | Provider_request.Settled.Ambiguous ->
              ())
      | Event.Message_appended _ | Event.Provider_requested _
      | Event.Decision_requested _ | Event.Decision_resolved _
      | Event.Interrupt_requested _ | Event.Tool_claimed _
      | Event.Tool_settled _ | Event.Tasks_replaced _
      | Event.Delegation_recorded _ | Event.Delegations_detached
      | Event.Queue_updated _ | Event.Turn_finished _ | Event.Workspace_notice _
      | Event.Undo_updated _ ->
          ())
    events;
  let steps = List.rev !steps in
  {
    steps;
    calls = List.concat_map Step.calls steps;
    segment_count = !segment_index + 1;
    declared_tools = List.sort_uniq String.compare !declared;
    model = unique_model !models;
    reasoning_effort = unique_effort !efforts;
  }

let steps t = t.steps
let calls t = t.calls

let segments t =
  List.init t.segment_count (fun segment ->
      List.filter (fun step -> Step.segment_index step = segment) t.steps)

let declared_tools t = t.declared_tools
let model t = t.model
let reasoning_effort t = t.reasoning_effort

(* Shared derivations *)

let read_only_tools =
  [
    "read_file";
    "search_text";
    "glob";
    "ocaml_docs";
    "ocaml_dune_describe";
    "ocaml_dune_diagnostics";
    "ocaml_eval";
    "ocaml_find_definitions";
    "ocaml_find_references";
    "ocaml_search_expressions";
    "ocaml_type_at";
    "web_fetch";
    "web_search";
  ]

type mutation = No_mutation | Paths of string list | All

(* Codex patch headers name every file a patch touches. *)
let apply_patch_paths patch =
  let markers =
    [
      "*** Add File: ";
      "*** Update File: ";
      "*** Delete File: ";
      "*** Move to: ";
    ]
  in
  String.split_on_char '\n' patch
  |> List.filter_map (fun line ->
      List.find_map
        (fun marker ->
          if String.starts_with ~prefix:marker line then
            Some
              (String.trim
                 (String.sub line (String.length marker)
                    (String.length line - String.length marker)))
          else None)
        markers)
  |> List.filter (fun path -> path <> "")

let mutation call =
  match Call.name call with
  | "write_file" | "edit_file" | "edit_lines" -> (
      match Call.string_field "path" call with
      | Some path -> Paths [ path ]
      | None -> All)
  | "apply_patch" -> (
      match Call.string_field "patch" call with
      | Some patch -> (
          match apply_patch_paths patch with [] -> All | paths -> Paths paths)
      | None -> All)
  | name when List.mem name read_only_tools -> No_mutation
  | _ -> All

let rereads t =
  let last_read : (string, Call.t) Hashtbl.t = Hashtbl.create 32 in
  let acc = ref [] in
  List.iter
    (fun call ->
      (match Call.read_path call with
      | Some path ->
          (match Hashtbl.find_opt last_read path with
          | Some original -> acc := (original, call) :: !acc
          | None -> ());
          Hashtbl.replace last_read path call
      | None -> ());
      match mutation call with
      | No_mutation -> ()
      | All -> Hashtbl.reset last_read
      | Paths paths -> List.iter (Hashtbl.remove last_read) paths)
    t.calls;
  List.rev !acc

let same_call a b =
  String.equal (Call.name a) (Call.name b)
  && Json.equal (Call.arguments a) (Call.arguments b)

let repeated_groups t =
  let groups = ref [] in
  List.iter
    (fun call ->
      match
        List.find_opt
          (fun (representative, _) -> same_call representative call)
          !groups
      with
      | Some (_, members) -> members := call :: !members
      | None -> groups := (call, ref [ call ]) :: !groups)
    t.calls;
  List.rev_map (fun (_, members) -> List.rev !members) !groups
  |> List.filter (fun group -> List.length group >= 2)

let failure_streaks t =
  let flush current acc =
    match current with [] -> acc | _ -> List.rev current :: acc
  in
  let rec loop acc current = function
    | [] -> List.rev (flush current acc)
    | call :: rest -> (
        match (Call.status call, current) with
        | Call.Failed, previous :: _
          when String.equal (Call.name previous) (Call.name call) ->
            loop acc (call :: current) rest
        | Call.Failed, _ -> loop (flush current acc) [ call ] rest
        | (Call.Ok | Call.Rejected), _ -> loop (flush current acc) [] rest)
  in
  loop [] [] t.calls

(* A shell command's family is its argv0, sharpened with the subcommand for the
   multiplexer tools whose bare name says little. Compound commands degrade to
   their first word; this histogram is a diagnostic, not a parse. *)
let shell_family call =
  match Call.shell_command call with
  | None -> None
  | Some command -> (
      match
        String.split_on_char ' ' command
        |> List.concat_map (String.split_on_char '\t')
        |> List.filter (fun token -> token <> "")
      with
      | [] -> None
      | argv0 :: rest -> (
          let argv0 = Filename.basename argv0 in
          match (argv0, rest) with
          | ("git" | "dune" | "opam"), subcommand :: _
            when not (String.starts_with ~prefix:"-" subcommand) ->
              Some (argv0 ^ " " ^ subcommand)
          | _ -> Some argv0))

let shell_families t =
  let table = Hashtbl.create 16 in
  List.iter
    (fun call ->
      match shell_family call with
      | None -> ()
      | Some family ->
          Hashtbl.replace table family
            (1 + Option.value (Hashtbl.find_opt table family) ~default:0))
    t.calls;
  Hashtbl.fold (fun family count acc -> (family, count) :: acc) table []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* Rendering *)

let pp_usage ppf = function
  | None -> Format.pp_print_string ppf "usage=?"
  | Some usage ->
      Format.fprintf ppf "in=%d out=%d reason=%d cache_r=%d cache_w=%d"
        usage.Usage.input usage.Usage.output usage.Usage.reasoning
        usage.Usage.cache_read usage.Usage.cache_write

let pp_digest ?(arg_bytes = 80) ?(result_bytes = 80) ppf t =
  (match declared_tools t with
  | [] -> ()
  | tools -> Format.fprintf ppf "tools: %s@." (String.concat ", " tools));
  List.iteri
    (fun segment steps ->
      if segment > 0 then Format.fprintf ppf "-- compaction --@.";
      Format.fprintf ppf "segment %d@." segment;
      List.iter
        (fun step ->
          Format.fprintf ppf "  step %d  %a@." (Step.index step) pp_usage
            (Step.usage step);
          List.iter
            (fun call ->
              let result = Call.result_digest ~max_bytes:result_bytes call in
              Format.fprintf ppf "    %s %s -> %s %db%s@." (Call.name call)
                (Call.arguments_digest ~max_bytes:arg_bytes call)
                (Call.status_to_string (Call.status call))
                (Call.result_bytes call)
                (if result = "" then "" else " " ^ result))
            (Step.calls step))
        steps)
    (segments t)
