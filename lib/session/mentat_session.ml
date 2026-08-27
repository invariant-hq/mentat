(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Id = Id
module Time = Time
module Metadata = Metadata
module Principal = Principal
module Contract = Contract
module Turn = Turn
module Provider_request = Provider_request
module Tool_claim = Tool_claim
module Question = Question
module Plan = Plan
module Decision = Decision
module Task = Task
module Delegation = Delegation
module Origin = Origin
module Queue = Queue
module Compaction = Compaction
module Notice = Notice
module Undo = Undo
module Event = Event
module State = State
module Anchor = Anchor

module Error = struct
  type t =
    | State of State.Error.t
    | Replay of State.Replay_error.t
    | Archived
    | Deleted
    | Active_turn of Turn.Id.t
    | Unknown_turn of Turn.Id.t
    | Turn_not_finished of Turn.Id.t
    | Delegated_session of Delegation.Id.t
    | Branch_copy_out_of_range of { copied_events : int; event_count : int }
    | Branch_reset_mismatch of {
        index : int;
        expected : Event.t;
        found : Event.t option;
      }
    | Unexpected_delegation_detachment of { index : int }
    | Unsupported_version of { found : int; supported : int }

  let message = function
    | State error -> State.Error.message error
    | Replay error -> State.Replay_error.message error
    | Archived -> "session is archived"
    | Deleted -> "session has been deleted"
    | Active_turn turn ->
        Format.asprintf "turn is still active: %a" Turn.Id.pp turn
    | Unknown_turn turn ->
        Format.asprintf "turn is not in the session: %a" Turn.Id.pp turn
    | Turn_not_finished turn ->
        Format.asprintf "turn has not finished: %a" Turn.Id.pp turn
    | Delegated_session delegation ->
        Format.asprintf "session belongs to delegation %a" Delegation.Id.pp
          delegation
    | Branch_copy_out_of_range { copied_events; event_count } ->
        Printf.sprintf "branch copied-event count %d exceeds its event count %d"
          copied_events event_count
    | Branch_reset_mismatch { index; expected; found } -> (
        match found with
        | None ->
            Format.asprintf "branch reset is missing %a at event %d" Event.pp
              expected index
        | Some found ->
            Format.asprintf "branch reset has %a at event %d, expected %a"
              Event.pp found index Event.pp expected)
    | Unexpected_delegation_detachment { index } ->
        Printf.sprintf
          "delegation detachment is not valid at event %d for this session"
          index
    | Unsupported_version { found; supported } ->
        Printf.sprintf "unsupported session version %d (supported: %d)" found
          supported

  let pp ppf t = Format.pp_print_string ppf (message t)
end

type t = {
  id : Id.t;
  metadata : Metadata.t;
  events_rev : Event.t list;
  state : State.t;
}

(* The branch reset suffix: clear inherited pending work and detach child
   ownership, so a branch dangles neither. Derived from the copied prefix's own
   projection, and appended after it. *)
let reset_suffix prefix =
  match State.of_events prefix with
  | Error _ as error -> error
  | Ok state ->
      let queue_suffix =
        match State.pending_queue state with
        | [] -> []
        | _ :: _ -> [ Event.queue_updated Queue.Update.cleared ]
      in
      let delegation_suffix =
        match State.delegations state with
        | [] -> []
        | _ :: _ -> [ Event.delegations_detached ]
      in
      Ok (queue_suffix @ delegation_suffix)

let copied_events metadata =
  match Metadata.fork metadata with
  | None -> 0
  | Some lineage -> Metadata.Forked_from.copied_events lineage

let validate_branch_copy metadata events =
  let copied_events = copied_events metadata in
  let event_count = List.length events in
  if copied_events <= event_count then Ok ()
  else Error (Error.Branch_copy_out_of_range { copied_events; event_count })

let validate_branch_reset metadata events =
  let copied = copied_events metadata in
  let prefix = List.take copied events in
  let current = List.drop copied events in
  let rec require_suffix index expected current =
    match (expected, current) with
    | [], current -> Ok (index, current)
    | expected :: _, [] ->
        Error (Error.Branch_reset_mismatch { index; expected; found = None })
    | expected :: expected_rest, found :: current_rest ->
        if Event.equal expected found then
          require_suffix (index + 1) expected_rest current_rest
        else
          Error
            (Error.Branch_reset_mismatch { index; expected; found = Some found })
  in
  let rec reject_later_detachment index = function
    | [] -> Ok ()
    | Event.Delegations_detached :: _ ->
        Error (Error.Unexpected_delegation_detachment { index })
    | _ :: rest -> reject_later_detachment (index + 1) rest
  in
  match reset_suffix prefix with
  | Error error -> Error (Error.Replay error)
  | Ok expected -> (
      match require_suffix copied expected current with
      | Error _ as error -> error
      | Ok (index, current) -> reject_later_detachment index current)

let make ~id ~metadata ~events =
  match validate_branch_copy metadata events with
  | Error _ as error -> error
  | Ok () -> (
      match State.of_events events with
      | Error error -> Error (Error.Replay error)
      | Ok state -> (
          match validate_branch_reset metadata events with
          | Error _ as error -> error
          | Ok () -> Ok { id; metadata; events_rev = List.rev events; state }))

let create ~id ?title ?delegated_from ~cwd ~created_at () =
  {
    id;
    metadata =
      Metadata.make ?title ?delegated_from ~cwd ~created_at
        ~updated_at:created_at ();
    events_rev = [];
    state = State.empty;
  }

let id t = t.id
let metadata t = t.metadata
let events t = List.rev t.events_rev
let state t = t.state

(* The admit judgment over the target's own recorded facts — the honest floor
   while only delegation kin and the owner send. One home, consumed by every
   queue admission (a live driver's, and a fence-held append on a dormant
   journal), so the arms cannot drift. The backlog cap counts unconsumed
   entries only — consumption frees the sender's slots — and never counts the
   owner: backpressure bounds agents, not the human whose account this is. *)
let mail_backlog_cap = 8

let admits_mail ~origin t =
  match origin with
  | None -> `Admitted
  | Some (Origin.Trigger _) -> `Refused_sender
  | Some (Origin.Agent sender as sender_origin) ->
      let is_parent =
        match Metadata.delegated_from t.metadata with
        | None -> false
        | Some lineage ->
            Id.equal (Metadata.Delegated_from.parent lineage) sender
      in
      let is_kin =
        is_parent
        || List.exists
             (fun edge -> Id.equal (Delegation.child edge) sender)
             (State.delegations t.state)
      in
      if not is_kin then `Refused_sender
      else
        let backlog =
          List.length
            (List.filter
               (fun entry ->
                 match Queue.Entry.origin entry with
                 | Some o -> Origin.equal o sender_origin
                 | None -> false)
               (State.pending_queue t.state))
        in
        if backlog >= mail_backlog_cap then `Refused_backlog else `Admitted

let require_not_deleted t =
  if Metadata.is_deleted t.metadata then Error Error.Deleted else Ok ()

let require_active_status t =
  match Metadata.status t.metadata with
  | Metadata.Status.Active -> Ok ()
  | Metadata.Status.Archived -> Error Error.Archived
  | Metadata.Status.Deleted -> Error Error.Deleted

let require_no_active_turn t =
  match State.active_turn_id t.state with
  | None -> Ok ()
  | Some turn -> Error (Error.Active_turn turn)

let require_not_delegated t =
  match Metadata.delegated_from t.metadata with
  | None -> Ok ()
  | Some lineage ->
      Error
        (Error.Delegated_session (Metadata.Delegated_from.delegation lineage))

let appended_detach_error t offset =
  let current = events t in
  Error
    (Error.Unexpected_delegation_detachment
       { index = List.length current + offset })

let rec first_detach offset = function
  | [] -> None
  | Event.Delegations_detached :: _ -> Some offset
  | _ :: rest -> first_detach (offset + 1) rest

let append event t =
  match require_active_status t with
  | Error _ as error -> error
  | Ok () -> (
      match event with
      | Event.Delegations_detached -> appended_detach_error t 0
      | _ -> (
          match State.apply event t.state with
          | Error error -> Error (Error.State error)
          | Ok state -> Ok { t with events_rev = event :: t.events_rev; state })
      )

let append_all events t =
  match events with
  | [] -> Ok t
  | _ -> (
      match require_active_status t with
      | Error _ as error -> error
      | Ok () -> (
          match first_detach 0 events with
          | Some offset -> appended_detach_error t offset
          | None -> (
              match State.apply_all events t.state with
              | Error error ->
                  let by = List.length t.events_rev in
                  Error (Error.Replay (State.Replay_error.shift ~by error))
              | Ok state ->
                  Ok
                    {
                      t with
                      events_rev = List.rev_append events t.events_rev;
                      state;
                    })))

let set_title title t =
  { t with metadata = Metadata.with_title title t.metadata }

let touch time t = { t with metadata = Metadata.touch time t.metadata }

let archive t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () ->
          Ok
            {
              t with
              metadata =
                Metadata.with_status Metadata.Status.Archived t.metadata;
            })

let restore t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () ->
      Ok
        {
          t with
          metadata = Metadata.with_status Metadata.Status.Active t.metadata;
        }

let delete t =
  if Metadata.is_deleted t.metadata then Ok t
  else
    match require_no_active_turn t with
    | Error _ as error -> error
    | Ok () ->
        Ok
          {
            t with
            metadata = Metadata.with_status Metadata.Status.Deleted t.metadata;
          }

let branch ~id ?title ~cwd ~created_at ~prefix t =
  match reset_suffix prefix with
  | Error error -> Error (Error.Replay error)
  | Ok suffix ->
      let events = prefix @ suffix in
      let forked_from =
        Metadata.Forked_from.make ~parent:t.id
          ~copied_events:(List.length prefix)
      in
      let metadata =
        Metadata.make ?title ~forked_from ~cwd ~created_at
          ~updated_at:created_at ()
      in
      make ~id ~metadata ~events

let fork ~id ?title ~cwd ~created_at t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () -> (
          match require_not_delegated t with
          | Error _ as error -> error
          | Ok () -> branch ~id ?title ~cwd ~created_at ~prefix:(events t) t))

let turn_started_index events turn_id =
  let rec loop i = function
    | [] -> None
    | Event.Turn_started turn :: _ when Turn.Id.equal (Turn.id turn) turn_id ->
        Some i
    | _ :: events -> loop (i + 1) events
  in
  loop 0 events

let turn_finished_index events turn_id =
  let rec loop i = function
    | [] -> None
    | Event.Turn_finished { turn; _ } :: _ when Turn.Id.equal turn turn_id ->
        Some i
    | _ :: events -> loop (i + 1) events
  in
  loop 0 events

let resolve_anchor_in events anchor t =
  let turn_id = Anchor.turn anchor in
  match Anchor.edge anchor with
  | Anchor.Before -> (
      match turn_started_index events turn_id with
      | Some index -> Ok index
      | None -> Error (Error.Unknown_turn turn_id))
  | Anchor.After -> (
      match State.turn turn_id t.state with
      | None -> Error (Error.Unknown_turn turn_id)
      | Some _ -> (
          match turn_finished_index events turn_id with
          | Some index -> Ok (index + 1)
          | None -> Error (Error.Turn_not_finished turn_id)))

let resolve_anchor anchor t = resolve_anchor_in (events t) anchor t

let dropped_turns anchor t =
  let events = events t in
  match resolve_anchor_in events anchor t with
  | Error _ as error -> error
  | Ok cut ->
      let rec loop i acc = function
        | [] -> List.rev acc
        | Event.Turn_started turn :: events ->
            let acc = if i >= cut then Turn.id turn :: acc else acc in
            loop (i + 1) acc events
        | _ :: events -> loop (i + 1) acc events
      in
      Ok (loop 0 [] events)

let rewind ~id ?title ~cwd ~created_at anchor t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () -> (
          match require_not_delegated t with
          | Error _ as error -> error
          | Ok () -> (
              let events = events t in
              match resolve_anchor_in events anchor t with
              | Error _ as error -> error
              | Ok copied_events ->
                  let prefix = List.take copied_events events in
                  branch ~id ?title ~cwd ~created_at ~prefix t)))

(* The document version. [base_version] is the original surface; a sealed
   contract carrying a structured-output tool raises the document to
   [output_schema_version] so a reader that predates [--output-schema] refuses at
   the version gate ({!Error.Unsupported_version}) rather than erroring on the
   unfamiliar [output_tool] member deep inside a [Turn_started] contract. A
   document whose contracts carry no output tool encodes at [base_version] —
   byte-identical to a pre-feature document — so it stays readable by such a
   reader. New readers accept the whole [\[base_version, max_version\]] range.

   A durable [Workspace_notice] event raises the document to
   [workspace_notice_version] on the same principle: a reader that predates
   durable workspace notices refuses at the version gate rather than erroring on
   the unfamiliar [workspace_notice] event tag. A document with no notice stays
   at the lower version it would otherwise take, byte-identical for old readers.

   A [Decision_resolved] whose permission answer carries a reviewer guidance
   [message] raises the document to [deny_guidance_version] on the same
   principle: a reader that predates deny-with-guidance would hit the unknown
   ["message"] member deep inside the answer codec (which uses [error_unknown])
   and error there; the version gate makes it refuse cleanly instead. A document
   with no guided deny stays at the lower version it would otherwise take,
   byte-identical for old readers — a bare deny records no [message] member.

   An [Undo_updated] event raises the document to [undo_version] on the same
   principle: a reader that predates undo refuses at the version gate rather than
   erroring on the unfamiliar [undo_updated] event tag. Undo is the newest
   feature and takes the highest version, so the cascade tests it first; a
   committed session has had its boundary events truncated away and takes the
   lower version again. A document with no undo event stays byte-identical for
   old readers. *)
let base_version = 1
let output_schema_version = 2
let workspace_notice_version = 3
let deny_guidance_version = 4
let undo_version = 5
let max_version = undo_version

(* The model-visible content lists a document event carries, in document order.
   The four media carriers — the prompt's [Turn_started], queued inputs, injected
   [Message_appended] messages, and a returned tool output — plus the rule that a
   future media-bearing arm must join this walk: the match is exhaustive, so a
   new event arm carrying [Content.t] is a compile error here rather than a
   silently unwalked [`Ref] at fork/export or an unversioned document. *)
let event_content_lists (event : Event.t) =
  match event with
  | Event.Turn_started turn -> (
      match Turn.input turn with
      | Turn.Input.User content -> [ content ]
      | Turn.Input.Continue | Turn.Input.Plan_build _ -> [])
  | Event.Queue_updated update -> (
      match update with
      | Queue.Update.Enqueued entry -> [ entry.Queue.Entry.input ]
      | Queue.Update.Replaced entries ->
          List.map (fun entry -> entry.Queue.Entry.input) entries
      | Queue.Update.Cleared -> [])
  | Event.Message_appended message -> (
      match message with
      | Mentat_llm.Message.User content -> [ content ]
      | Mentat_llm.Message.Tool_result result ->
          [ Mentat_llm.Tool.Result.content result ]
      | Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
      | Mentat_llm.Message.Assistant _ ->
          [])
  | Event.Tool_settled settled -> (
      (* A returned tool output's media (the read path). Its content refs are the
         Output's media blocks; a prepared or ambiguous settlement carries none. *)
      match Tool_claim.Settled.outcome settled with
      | Tool_claim.Settled.Returned result -> (
          match Mentat_tool.Result.output result with
          | Some output -> [ Mentat_tool.Output.media output ]
          | None -> [])
      | Tool_claim.Settled.Prepared _ | Tool_claim.Settled.Ambiguous -> [])
  | Event.Interrupt_requested _ | Event.Turn_finished _
  | Event.Provider_requested _ | Event.Provider_settled _ | Event.Tool_claimed _
  | Event.Decision_requested _ | Event.Decision_resolved _
  | Event.Compaction_installed _ | Event.Tasks_replaced _
  | Event.Delegation_recorded _ | Event.Delegations_detached
  | Event.Workspace_notice _ | Event.Undo_updated _ ->
      []

let content_media_refs content =
  List.filter_map
    (function
      | Mentat_llm.Content.Media { source = `Ref reference; _ } ->
          Some reference
      | Mentat_llm.Content.Text _ | Mentat_llm.Content.Media _ -> None)
    content

let media_refs session =
  let seen = Hashtbl.create 16 in
  List.concat_map
    (fun event ->
      List.concat_map content_media_refs (event_content_lists event))
    (events session)
  |> List.filter (fun reference ->
      let token = Mentat_digest.Content_ref.to_token reference in
      if Hashtbl.mem seen token then false
      else (
        Hashtbl.add seen token ();
        true))

let document_has_media session =
  List.exists
    (fun event ->
      List.exists
        (fun content ->
          List.exists
            (function
              | Mentat_llm.Content.Media _ -> true
              | Mentat_llm.Content.Text _ -> false)
            content)
        (event_content_lists event))
    (events session)

let document_version session =
  let carries_output_tool event =
    match (event : Event.t) with
    | Event.Turn_started turn ->
        Option.is_some (Contract.output_tool (Turn.contract turn))
    | _ -> false
  in
  let is_workspace_notice event =
    match (event : Event.t) with Event.Workspace_notice _ -> true | _ -> false
  in
  let carries_deny_guidance event =
    match (event : Event.t) with
    | Event.Decision_resolved resolved -> (
        match Decision.Resolved.answer resolved with
        | Decision.Answer.Permission { message = Some _; _ } -> true
        | Decision.Answer.Permission { message = None; _ }
        | Decision.Answer.Question _ | Decision.Answer.Plan _ ->
            false)
    | _ -> false
  in
  let is_undo event =
    match (event : Event.t) with Event.Undo_updated _ -> true | _ -> false
  in
  let events = events session in
  if List.exists is_undo events then undo_version
  else if List.exists carries_deny_guidance events then deny_guidance_version
  else if List.exists is_workspace_notice events then workspace_notice_version
  else if List.exists carries_output_tool events || document_has_media session
  then output_schema_version
  else base_version

(* [Jsont.int] accepts truncating floats ([1.9]) and numeric strings (["1"]), so
   the version gate reads the member as raw JSON and requires an exact integer.
   An unsupported version is the structured {!Error.Unsupported_version}. *)
let version_of_json = function
  | Jsont.Number (f, _) when Float.is_integer f -> int_of_float f
  | Jsont.Number _ | Jsont.Null _ | Jsont.Bool _ | Jsont.String _
  | Jsont.Array _ | Jsont.Object _ ->
      decode_error "session version must be an integer"

(* The typed document decode. It accepts the [version] member as raw JSON and
   re-emits it on encode; {!jsont} runs the version gate before this decoder ever
   sees a member, so the version is ignored here. *)
let document_jsont =
  let make _version id metadata events =
    match make ~id ~metadata ~events with
    | Ok session -> session
    | Error error -> decode_error (Error.message error)
  in
  Jsont.Object.map ~kind:"session" make
  |> Jsont.Object.mem "version" Jsont.json ~enc:(fun session ->
      Jsont.Json.number (float_of_int (document_version session)))
  |> Jsont.Object.mem "id" Id.jsont ~enc:id
  |> Jsont.Object.mem "metadata" Metadata.jsont ~enc:metadata
  |> Jsont.Object.mem "events" (Jsont.list Event.jsont) ~enc:events
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

(* The version gate runs before any member is decoded. A missing member or a
   non-object document defers to the typed decode, which reports the precise
   structural error. *)
let check_version = function
  | Jsont.Object (members, _) -> (
      match Jsont.Json.find_mem "version" members with
      | None -> ()
      | Some (_, version_json) ->
          let found = version_of_json version_json in
          if found < base_version || found > max_version then
            decode_error
              (Error.message
                 (Error.Unsupported_version { found; supported = max_version }))
      )
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      ()

(* A genuine two-step decode: the raw document is parsed first — which fails only
   on JSON syntax — then the version is checked before any typed member is
   decoded, so a future-version document carrying unfamiliar member shapes
   reports {!Error.Unsupported_version} rather than the first member's decode
   error. *)
let jsont =
  Jsont.map ~kind:"session"
    ~dec:(fun raw ->
      check_version raw;
      match Jsont.Json.decode' document_jsont raw with
      | Ok session -> session
      | Error error -> raise (Jsont.Error error))
    ~enc:(fun session ->
      match Jsont.Json.encode' document_jsont session with
      | Ok raw -> raw
      | Error error -> raise (Jsont.Error error))
    Jsont.json

(* A manual-compaction turn is an internal mechanism, not conversational work: it
   is transparent to every session projection. Its turn-boundary facts are
   suppressed on the feed, and it does not count as a round or contribute its
   outcome/mode/usage-as-a-turn to the summary and view projections below. *)
let is_compaction_turn turn =
  Turn.Origin.equal (Turn.origin turn) Turn.Origin.Compaction

let work_turns state =
  List.filter (fun t -> not (is_compaction_turn t)) (State.turns state)

module Metrics = struct
  module Tool_name_map = Map.Make (String)

  type t = {
    usage : Mentat_llm.Usage.t;
    responses : int;
    turns : int;
    tool_calls : int;
    tool_failures : int;
    tool_rejections : int;
    tool_calls_by_name : (string * int) list;
    permission_denials : int;
  }

  let invalid fn message = invalid_arg' "Mentat_session.Metrics" fn message

  let check_non_negative fn field value =
    if value < 0 then invalid fn (field ^ " must be non-negative")

  let check_tool_calls_by_name fn entries =
    let rec loop previous = function
      | [] -> ()
      | (name, count) :: rest ->
          if String.is_empty name then
            invalid fn "tool call names must not be empty";
          if count <= 0 then
            invalid fn "tool call counts by name must be positive";
          (match previous with
          | None -> ()
          | Some previous ->
              if String.compare previous name >= 0 then
                invalid fn "tool call counts by name must be sorted and unique");
          loop (Some name) rest
    in
    loop None entries

  let make ~usage ~responses ~turns ~tool_calls ~tool_failures ~tool_rejections
      ~tool_calls_by_name ~permission_denials =
    check_non_negative "make" "responses" responses;
    check_non_negative "make" "turns" turns;
    check_non_negative "make" "tool_calls" tool_calls;
    check_non_negative "make" "tool_failures" tool_failures;
    check_non_negative "make" "tool_rejections" tool_rejections;
    check_non_negative "make" "permission_denials" permission_denials;
    if tool_failures > tool_calls then
      invalid "make" "tool_failures must not exceed tool_calls";
    check_tool_calls_by_name "make" tool_calls_by_name;
    {
      usage;
      responses;
      turns;
      tool_calls;
      tool_failures;
      tool_rejections;
      tool_calls_by_name;
      permission_denials;
    }

  let equal a b = a = b

  let pp_by_name ppf entries =
    Format.pp_print_list
      ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
      (fun ppf (name, count) -> Format.fprintf ppf "%s=%d" name count)
      ppf entries

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ usage = %a; responses = %d; turns = %d; tool_calls = %d; \
       tool_failures = %d; tool_rejections = %d; tool_calls_by_name = [%a]; \
       permission_denials = %d }@]"
      Mentat_llm.Usage.pp t.usage t.responses t.turns t.tool_calls
      t.tool_failures t.tool_rejections pp_by_name t.tool_calls_by_name
      t.permission_denials

  let tool_call_count_jsont : (string * int) Jsont.t =
    Jsont.Object.map ~kind:"tool-call count" (fun name count -> (name, count))
    |> Jsont.Object.mem "name" Jsont.string ~enc:fst
    |> Jsont.Object.mem "count" Jsont.int ~enc:snd
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont =
    let make usage responses turns tool_calls tool_failures tool_rejections
        tool_calls_by_name permission_denials =
      decode_invalid_arg (fun () ->
          make ~usage ~responses ~turns ~tool_calls ~tool_failures
            ~tool_rejections ~tool_calls_by_name ~permission_denials)
    in
    Jsont.Object.map ~kind:"session metrics" make
    |> Jsont.Object.mem "usage" Mentat_llm.Usage.jsont ~enc:(fun t -> t.usage)
    |> Jsont.Object.mem "responses" Jsont.int ~enc:(fun t -> t.responses)
    |> Jsont.Object.mem "turns" Jsont.int ~enc:(fun t -> t.turns)
    |> Jsont.Object.mem "tool_calls" Jsont.int ~enc:(fun t -> t.tool_calls)
    |> Jsont.Object.mem "tool_failures" Jsont.int ~enc:(fun t ->
        t.tool_failures)
    |> Jsont.Object.mem "tool_rejections" Jsont.int ~enc:(fun t ->
        t.tool_rejections)
    |> Jsont.Object.mem "tool_calls_by_name" (Jsont.list tool_call_count_jsont)
         ~enc:(fun t -> t.tool_calls_by_name)
    |> Jsont.Object.mem "permission_denials" Jsont.int ~enc:(fun t ->
        t.permission_denials)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let metrics session =
  let add_checked a b =
    if a > max_int - b then
      invalid_arg' "Mentat_session.Metrics" "metrics" "overflow"
    else a + b
  in
  let events = events session in
  (* A manual-compaction turn is transparent to the round count (its summarizer
     usage still folds in via [Compaction_installed]): remember its id at
     [Turn_started] so its [Turn_finished] does not increment [turns]. *)
  let usage, responses, turns, tool_rejections, permission_denials, _compaction
      =
    List.fold_left
      (fun (usage, responses, turns, rejections, denials, compaction_ids) event
         ->
        match event with
        | Event.Provider_settled settled -> (
            match Provider_request.Settled.outcome settled with
            | Provider_request.Settled.Responded response ->
                let usage =
                  Mentat_llm.Usage.add usage
                    (Option.value
                       (Mentat_llm.Response.usage response)
                       ~default:Mentat_llm.Usage.zero)
                in
                ( usage,
                  add_checked responses 1,
                  turns,
                  rejections,
                  denials,
                  compaction_ids )
            | Provider_request.Settled.Interrupted { usage = retained; _ } ->
                (* Interrupted spend is provider-reported and was billed; it
                   folds into usage without counting as a response. *)
                let usage =
                  Mentat_llm.Usage.add usage
                    (Option.value retained ~default:Mentat_llm.Usage.zero)
                in
                (usage, responses, turns, rejections, denials, compaction_ids)
            | Provider_request.Settled.Failed _
            | Provider_request.Settled.Ambiguous ->
                (usage, responses, turns, rejections, denials, compaction_ids))
        | Event.Turn_started turn when is_compaction_turn turn ->
            ( usage,
              responses,
              turns,
              rejections,
              denials,
              Turn.id turn :: compaction_ids )
        | Event.Turn_finished { turn; _ } ->
            if List.exists (Turn.Id.equal turn) compaction_ids then
              (usage, responses, turns, rejections, denials, compaction_ids)
            else
              ( usage,
                responses,
                add_checked turns 1,
                rejections,
                denials,
                compaction_ids )
        | Event.Compaction_installed compaction ->
            (* The compaction is the summary call's closer; its summarizer usage
               reaches metrics only here (there is no Provider_settled for it). *)
            let usage =
              Mentat_llm.Usage.add usage
                (Option.value
                   (Compaction.usage compaction)
                   ~default:Mentat_llm.Usage.zero)
            in
            (usage, responses, turns, rejections, denials, compaction_ids)
        | Event.Message_appended (Mentat_llm.Message.Tool_result result)
          when Mentat_llm.Tool.Result.is_error result ->
            ( usage,
              responses,
              turns,
              add_checked rejections 1,
              denials,
              compaction_ids )
        | Event.Decision_resolved resolved -> (
            match Decision.Resolved.answer resolved with
            | Decision.Answer.Permission
                { answer = Mentat_permission.Answer.Deny; _ } ->
                ( usage,
                  responses,
                  turns,
                  rejections,
                  add_checked denials 1,
                  compaction_ids )
            | Decision.Answer.Permission
                { answer = Mentat_permission.Answer.Allow _; _ }
            | Decision.Answer.Question _ | Decision.Answer.Plan _ ->
                (usage, responses, turns, rejections, denials, compaction_ids))
        | Event.Turn_started _ | Event.Interrupt_requested _
        | Event.Message_appended _ | Event.Provider_requested _
        | Event.Tool_claimed _ | Event.Tool_settled _
        | Event.Decision_requested _ | Event.Tasks_replaced _
        | Event.Delegation_recorded _
        | Event.Delegations_detached | Event.Queue_updated _
        | Event.Workspace_notice _ | Event.Undo_updated _ ->
            (usage, responses, turns, rejections, denials, compaction_ids))
      (Mentat_llm.Usage.zero, 0, 0, 0, 0, [])
      events
  in
  let tool_calls, tool_failures, by_name =
    List.fold_left
      (fun (calls, failures, by_name) (started, settled) ->
        match settled with
        | Some settled -> (
            match Tool_claim.Settled.outcome settled with
            | Tool_claim.Settled.Returned result ->
                let failed =
                  match Mentat_tool.Result.status result with
                  | Mentat_tool.Result.Failed _ -> true
                  | Mentat_tool.Result.Completed
                  | Mentat_tool.Result.Interrupted _ ->
                      false
                in
                let by_name =
                  Metrics.Tool_name_map.update
                    (Mentat_llm.Tool.Call.name
                       (Tool_claim.Started.call started))
                    (function
                      | None -> Some 1 | Some n -> Some (add_checked n 1))
                    by_name
                in
                ( add_checked calls 1,
                  (if failed then add_checked failures 1 else failures),
                  by_name )
            | Tool_claim.Settled.Prepared _ | Tool_claim.Settled.Ambiguous ->
                (calls, failures, by_name))
        | None -> (calls, failures, by_name))
      (0, 0, Metrics.Tool_name_map.empty)
      (State.tool_claims (state session))
  in
  Metrics.make ~usage ~responses ~turns ~tool_calls ~tool_failures
    ~tool_rejections
    ~tool_calls_by_name:(Metrics.Tool_name_map.bindings by_name)
    ~permission_denials

module Summary = struct
  type source = t

  module Phase = struct
    type t = Idle | Working | Waiting

    let to_string = function
      | Idle -> "idle"
      | Working -> "working"
      | Waiting -> "waiting"

    let equal a b = a = b
    let pp ppf t = Format.pp_print_string ppf (to_string t)

    let jsont =
      Jsont.enum ~kind:"summary phase"
        [ ("idle", Idle); ("working", Working); ("waiting", Waiting) ]
  end

  type t = {
    id : Id.t;
    title : string option;
    preview : string option;
    lifecycle : Metadata.Status.t;
    phase : Phase.t;
    root : Mentat_workspace.Root.t;
    turns : int;
    forked_from : Metadata.Forked_from.t option;
    delegated_from : Metadata.Delegated_from.t option;
    created_at : Time.t;
    updated_at : Time.t;
  }

  (* One-line preview normalization: collapse whitespace runs to one space and
     cap the byte length on a UTF-8 boundary with an ellipsis. Reads no more of
     the transcript than the first user prompt's text. *)
  let is_space = function
    | ' ' | '\n' | '\r' | '\t' | '\012' -> true
    | _ -> false

  let collapse_whitespace text =
    let len = String.length text in
    let buffer = Buffer.create len in
    let rec skip_spaces index =
      if index < len && is_space text.[index] then skip_spaces (index + 1)
      else index
    in
    let rec loop index pending_space =
      if index >= len then ()
      else if is_space text.[index] then loop (skip_spaces index) true
      else begin
        if pending_space && Buffer.length buffer > 0 then
          Buffer.add_char buffer ' ';
        Buffer.add_char buffer text.[index];
        loop (index + 1) false
      end
    in
    loop (skip_spaces 0) false;
    Buffer.contents buffer

  let utf8_boundary text index =
    let rec loop index =
      if index <= 0 then 0
      else
        let code = Char.code text.[index] in
        if code land 0b1100_0000 = 0b1000_0000 then loop (index - 1) else index
    in
    loop (min index (String.length text))

  let truncate_preview text =
    let max_bytes = 80 in
    if String.length text <= max_bytes then text
    else String.sub text 0 (utf8_boundary text max_bytes) ^ "\226\128\166"

  let preview_of_state state =
    work_turns state
    |> List.find_map (fun turn ->
        match
          Turn.input turn |> Turn.Input.text |> Option.map collapse_whitespace
        with
        | None | Some "" -> None
        | Some text -> Some (truncate_preview text))

  (* Phase is derived, not read: [next]'s [State] exposes no phase. A session at
     rest is [Idle]; [Working]/[Waiting] appear only for a document persisted
     mid-turn (e.g. after a crash). *)
  let phase_of_state state =
    match State.active_turn state with
    | None -> Phase.Idle
    | Some _ -> (
        match State.suspension state with
        | Some _ -> Phase.Waiting
        | None -> Phase.Working)

  let of_session (session : source) : t =
    let metadata = metadata session in
    let state = state session in
    {
      id = id session;
      title = Metadata.title metadata;
      preview = preview_of_state state;
      lifecycle = Metadata.status metadata;
      phase = phase_of_state state;
      root = Metadata.root metadata;
      turns = List.length (work_turns state);
      forked_from = Metadata.fork metadata;
      delegated_from = Metadata.delegated_from metadata;
      created_at = Metadata.created_at metadata;
      updated_at = Metadata.updated_at metadata;
    }

  (* [Summary]'s fields share labels with the session [t], [Metadata], and
     [Metrics] records in this same compilation unit, so each field read is
     annotated to the local [t]. *)
  let id (t : t) = t.id
  let title (t : t) = t.title
  let preview (t : t) = t.preview
  let lifecycle (t : t) = t.lifecycle
  let phase (t : t) = t.phase
  let root (t : t) = t.root
  let cwd (t : t) = Mentat_workspace.Root.dir t.root
  let turns (t : t) = t.turns
  let forked_from (t : t) = t.forked_from
  let delegated_from (t : t) = t.delegated_from
  let created_at (t : t) = t.created_at
  let updated_at (t : t) = t.updated_at

  let display_title (t : t) =
    match t.title with Some title -> title | None -> Id.to_string t.id

  (* Case-insensitive (ASCII) substring over the identifying fields only — id,
     title, preview, cwd — so search costs no more than a plain list. *)
  let matches ~query (t : t) =
    let needle = String.lowercase_ascii query in
    let key =
      [
        Some (Id.to_string t.id);
        t.title;
        t.preview;
        Some (Lpath.Abs.to_string (Mentat_workspace.Root.dir t.root));
      ]
      |> List.filter_map Fun.id |> String.concat " " |> String.lowercase_ascii
    in
    String.includes ~affix:needle key

  let compare_recency (a : t) (b : t) =
    let by_time = Time.compare b.updated_at a.updated_at in
    if by_time <> 0 then by_time else Id.compare a.id b.id

  let equal (a : t) (b : t) =
    Id.equal a.id b.id
    && Option.equal String.equal a.title b.title
    && Option.equal String.equal a.preview b.preview
    && Metadata.Status.equal a.lifecycle b.lifecycle
    && Phase.equal a.phase b.phase
    && Mentat_workspace.Root.equal a.root b.root
    && Int.equal a.turns b.turns
    && Option.equal Metadata.Forked_from.equal a.forked_from b.forked_from
    && Option.equal Metadata.Delegated_from.equal a.delegated_from
         b.delegated_from
    && Time.equal a.created_at b.created_at
    && Time.equal a.updated_at b.updated_at

  let pp ppf (t : t) =
    Format.fprintf ppf
      "@[<hov>{ id = %a; title = %a; lifecycle = %a; phase = %a; turns = %d; \
       cwd = %a }@]"
      Id.pp t.id
      (Format.pp_print_option Format.pp_print_string)
      t.title Metadata.Status.pp t.lifecycle Phase.pp t.phase t.turns
      Mentat_workspace.Root.pp t.root

  let jsont =
    Jsont.Object.map ~kind:"session summary"
      (fun
        id
        title
        preview
        lifecycle
        phase
        cwd
        turns
        forked_from
        delegated_from
        created_at
        updated_at
        :
        t
      ->
        {
          id;
          title;
          preview;
          lifecycle;
          phase;
          root = Mentat_workspace.Root.of_dir cwd;
          turns;
          forked_from;
          delegated_from;
          created_at;
          updated_at;
        })
    |> Jsont.Object.mem "id" Id.jsont ~enc:(fun (t : t) -> t.id)
    |> Jsont.Object.opt_mem "title" Jsont.string ~enc:(fun (t : t) -> t.title)
    |> Jsont.Object.opt_mem "preview" Jsont.string ~enc:(fun (t : t) ->
        t.preview)
    |> Jsont.Object.mem "lifecycle" Metadata.Status.jsont ~enc:(fun (t : t) ->
        t.lifecycle)
    |> Jsont.Object.mem "phase" Phase.jsont ~enc:(fun (t : t) -> t.phase)
    |> Jsont.Object.mem "cwd" Metadata.absolute_path_jsont ~enc:(fun (t : t) ->
        Mentat_workspace.Root.dir t.root)
    |> Jsont.Object.mem "turns" Jsont.int ~enc:(fun (t : t) -> t.turns)
    |> Jsont.Object.opt_mem "forked_from" Metadata.Forked_from.jsont
         ~enc:(fun (t : t) -> t.forked_from)
    |> Jsont.Object.opt_mem "delegated_from" Metadata.Delegated_from.jsont
         ~enc:(fun (t : t) -> t.delegated_from)
    |> Jsont.Object.mem "created_at" Time.jsont ~enc:(fun (t : t) ->
        t.created_at)
    |> Jsont.Object.mem "updated_at" Time.jsont ~enc:(fun (t : t) ->
        t.updated_at)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Session_view = struct
  type source = t

  module Waiting = struct
    type t = Awaiting_provider | Awaiting_tool | Awaiting_decision

    let to_string = function
      | Awaiting_provider -> "awaiting_provider"
      | Awaiting_tool -> "awaiting_tool"
      | Awaiting_decision -> "awaiting_decision"

    let equal a b = a = b
    let pp ppf t = Format.pp_print_string ppf (to_string t)

    let jsont =
      Jsont.enum ~kind:"session waiting kind"
        [
          ("awaiting_provider", Awaiting_provider);
          ("awaiting_tool", Awaiting_tool);
          ("awaiting_decision", Awaiting_decision);
        ]
  end

  type t = {
    summary : Summary.t;
    active_model : Mentat_llm.Model.t option;
    last_outcome : Turn.Outcome.t option;
    waiting : Waiting.t option;
    workflow_mode : Contract.Mode.t option;
    last_text : string option;
    metrics : Metrics.t;
  }

  let waiting_of_state state =
    match State.suspension state with
    | None -> None
    | Some (State.Provider _) -> Some Waiting.Awaiting_provider
    | Some (State.Tool _) -> Some Waiting.Awaiting_tool
    | Some (State.Decision _) -> Some Waiting.Awaiting_decision

  (* The last finished turn's outcome: turns fold in start order, so the final
     [Some] is the most recent settlement. *)
  let last_outcome_of_state state =
    List.fold_left
      (fun acc turn ->
        match State.turn_outcome (Turn.id turn) state with
        | Some outcome -> Some outcome
        | None -> acc)
      None (work_turns state)

  (* The active turn's mode, or the most recently started turn's when idle. *)
  let workflow_mode_of_state state =
    let turn =
      match State.active_turn state with
      | Some turn -> Some turn
      | None -> (
          match List.rev (work_turns state) with t :: _ -> Some t | [] -> None)
    in
    Option.map (fun turn -> Contract.mode (Turn.contract turn)) turn

  let of_session (session : source) : t =
    let state = state session in
    {
      summary = Summary.of_session session;
      active_model = State.latest_model state;
      last_outcome = last_outcome_of_state state;
      waiting = waiting_of_state state;
      workflow_mode = workflow_mode_of_state state;
      last_text = State.final_text state;
      metrics = metrics session;
    }

  let summary t = t.summary
  let active_model t = t.active_model
  let last_outcome t = t.last_outcome
  let waiting t = t.waiting
  let workflow_mode t = t.workflow_mode
  let last_text t = t.last_text
  let metrics t = t.metrics

  let equal a b =
    Summary.equal a.summary b.summary
    && Option.equal Mentat_llm.Model.equal a.active_model b.active_model
    && Option.equal Turn.Outcome.equal a.last_outcome b.last_outcome
    && Option.equal Waiting.equal a.waiting b.waiting
    && Option.equal Contract.Mode.equal a.workflow_mode b.workflow_mode
    && Option.equal String.equal a.last_text b.last_text
    && Metrics.equal a.metrics b.metrics

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ summary = %a; active_model = %a; workflow_mode = %a; metrics = \
       %a }@]"
      Summary.pp t.summary
      (Format.pp_print_option Mentat_llm.Model.pp)
      t.active_model
      (Format.pp_print_option Contract.Mode.pp)
      t.workflow_mode Metrics.pp t.metrics

  let jsont =
    Jsont.Object.map ~kind:"session view"
      (fun
        summary
        active_model
        last_outcome
        waiting
        workflow_mode
        last_text
        metrics
      ->
        {
          summary;
          active_model;
          last_outcome;
          waiting;
          workflow_mode;
          last_text;
          metrics;
        })
    |> Jsont.Object.mem "summary" Summary.jsont ~enc:(fun t -> t.summary)
    |> Jsont.Object.opt_mem "active_model" Mentat_llm.Model.jsont ~enc:(fun t ->
        t.active_model)
    |> Jsont.Object.opt_mem "last_outcome" Turn.Outcome.jsont ~enc:(fun t ->
        t.last_outcome)
    |> Jsont.Object.opt_mem "waiting" Waiting.jsont ~enc:(fun t -> t.waiting)
    |> Jsont.Object.opt_mem "workflow_mode" Contract.Mode.jsont ~enc:(fun t ->
        t.workflow_mode)
    |> Jsont.Object.opt_mem "last_text" Jsont.string ~enc:(fun t -> t.last_text)
    |> Jsont.Object.mem "metrics" Metrics.jsont ~enc:(fun t -> t.metrics)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Listing = struct
  type t = {
    scope : [ `Cwd | `All ];
    lifecycles : Metadata.Status.t list;
    search : string option;
    limit : int option;
  }

  let select ~cwd listing summaries =
    let lifecycle_requested summary =
      List.exists
        (Metadata.Status.equal (Summary.lifecycle summary))
        listing.lifecycles
    in
    let in_scope summary =
      match listing.scope with
      | `All -> true
      | `Cwd ->
          Mentat_workspace.Root.same_key
            (Mentat_workspace.Root.of_dir cwd)
            (Summary.root summary)
    in
    let matches summary =
      match listing.search with
      | None -> true
      | Some query -> Summary.matches ~query summary
    in
    (* A delegated child is a subagent's own transcript, not a conversation the
       user opened; it is addressable only through its parent's threads surface,
       so it never appears in a session listing. *)
    let is_conversation summary =
      Option.is_none (Summary.delegated_from summary)
    in
    let selected =
      summaries
      |> List.filter is_conversation
      |> List.filter lifecycle_requested
      |> List.filter in_scope |> List.filter matches
      |> List.sort Summary.compare_recency
    in
    match listing.limit with
    | None -> selected
    | Some limit -> List.filteri (fun index _ -> index < limit) selected
end
