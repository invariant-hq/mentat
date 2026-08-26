(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Unattended = struct
  type t = Deny | Block

  let to_string = function Deny -> "deny" | Block -> "block"
end

module Gate = struct
  type t = {
    base : string list option;
    drafts : bool;
    associations : string list option;
  }

  let permissive = { base = None; drafts = false; associations = None }
end

module Trigger = struct
  module Webhook = struct
    type t = { events : string list; gate : Gate.t }
  end

  type t = Github_webhook of Webhook.t | Cli
end

module Run = struct
  type t = {
    model : string option;
    reasoning : string option;
    max_steps : int;
    prompt : string;
    output_schema : string;
    project_instructions : bool option;
  }
end

module Budget = struct
  type t = {
    wall_clock : float;
    usd_per_day : float option;
    runs_per_hour : int option;
  }
end

module Notify = struct
  type t = { on : Receipt.Transition.t list; command : string list }
end

type t = {
  name : string;
  enabled : bool;
  repo : string;
  triggers : Trigger.t list;
  permission_unattended : Unattended.t option;
  run : Run.t;
  budget : Budget.t;
  notify : Notify.t option;
  suppress_clean_run : bool;
  keep_failed_worktrees : int option;
}

module Error = Decode.Error

let ( let* ) = Result.bind
let error ~context reason = Error (Decode.Error.make ~context reason)

(* The charter-name grammar must stay identical to the token the run
   surface's --triggered flag admits for charter names. *)
let name_char c =
  (c >= 'A' && c <= 'Z')
  || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || Char.equal c '.' || Char.equal c '_' || Char.equal c '-'

let route ~context ~names mems =
  let slots = List.map (fun name -> (name, ref None)) names in
  let* () = Decode.route_members ~context ~slots mems in
  Ok slots

let required ~context slots name =
  Decode.require ~context name (List.assoc name slots)

let optional slots name = !(List.assoc name slots)

let string_list ~context json =
  match json with
  | Jsont.Array ([], _) -> error ~context "must be a non-empty array"
  | Jsont.Array (elements, _) ->
      let* _, reversed =
        List.fold_left
          (fun acc element ->
            let* index, reversed = acc in
            let* value =
              Decode.as_non_empty_string
                ~context:(Printf.sprintf "%s[%d]" context index)
                element
            in
            Ok (index + 1, value :: reversed))
          (Ok (0, []))
          elements
      in
      Ok (List.rev reversed)
  | _ -> error ~context "must be an array"

let distinct ~context values =
  let rec go seen = function
    | [] -> Ok ()
    | value :: rest ->
        if List.mem value seen then
          error ~context (Printf.sprintf "duplicate entry %S" value)
        else go (value :: seen) rest
  in
  go [] values

let duration ~context s =
  let malformed () =
    error ~context "must be a duration of digits then s, m, or h, like \"15m\""
  in
  let n = String.length s in
  if n < 2 || n > 10 then malformed ()
  else
    let digits = String.sub s 0 (n - 1) in
    if not (String.for_all (fun c -> c >= '0' && c <= '9') digits) then
      malformed ()
    else
      let value = int_of_string digits in
      if value < 1 then malformed ()
      else
        match s.[n - 1] with
        | 's' -> Ok (float_of_int value)
        | 'm' -> Ok (float_of_int value *. 60.0)
        | 'h' -> Ok (float_of_int value *. 3600.0)
        | _ -> malformed ()

let relative_file ~context json =
  let* s = Decode.as_non_empty_string ~context json in
  if Char.equal s.[0] '/' then
    error ~context "must be a relative path inside the charter directory"
  else
    let components = String.split_on_char '/' s in
    if
      List.exists
        (fun c ->
          String.equal c "" || String.equal c "." || String.equal c "..")
        components
    then error ~context "must not traverse outside the charter directory"
    else if String.equal (List.hd components) "secrets" then
      error ~context "must not live under secrets/"
    else if String.equal s "charter.json" || String.equal s "ingress.id" then
      error ~context "must not name a reserved charter file"
    else Ok s

let association_vocabulary =
  [
    "OWNER";
    "MEMBER";
    "COLLABORATOR";
    "CONTRIBUTOR";
    "FIRST_TIME_CONTRIBUTOR";
    "FIRST_TIMER";
    "MANNEQUIN";
    "NONE";
  ]

let reasoning_vocabulary =
  [ "none"; "minimal"; "low"; "medium"; "high"; "xhigh"; "max" ]

(* GitHub's documented pull_request webhook actions. Closed like every other
   vocabulary in this envelope: a typo'd action must be a load error, never a
   charter that silently fires on nothing; a new GitHub action becomes
   admissible by a build update. *)
let action_vocabulary =
  [
    "assigned";
    "auto_merge_disabled";
    "auto_merge_enabled";
    "closed";
    "converted_to_draft";
    "demilestoned";
    "dequeued";
    "edited";
    "enqueued";
    "labeled";
    "locked";
    "milestoned";
    "opened";
    "ready_for_review";
    "reopened";
    "review_request_removed";
    "review_requested";
    "synchronize";
    "unassigned";
    "unlabeled";
    "unlocked";
  ]

let event_name ~context s =
  let prefix = "pull_request." in
  let plen = String.length prefix in
  if
    String.length s <= plen || not (String.equal (String.sub s 0 plen) prefix)
  then
    error ~context "must name a pull_request event like \"pull_request.opened\""
  else
    let action = String.sub s plen (String.length s - plen) in
    if List.mem action action_vocabulary then Ok s
    else
      error ~context (Printf.sprintf "unknown pull_request action %S" action)

let decode_gate ~context json =
  match json with
  | Jsont.Object (mems, _) ->
      let* slots = route ~context ~names:[ "base"; "drafts"; "associations" ] mems in
      let* base =
        match optional slots "base" with
        | None -> Ok None
        | Some json ->
            let context = context ^ ".base" in
            let* branches = string_list ~context json in
            let* () = distinct ~context branches in
            Ok (Some branches)
      in
      let* drafts =
        match optional slots "drafts" with
        | None -> Ok false
        | Some json -> Decode.as_bool ~context:(context ^ ".drafts") json
      in
      let* associations =
        match optional slots "associations" with
        | None -> Ok None
        | Some json ->
            let context = context ^ ".associations" in
            let* values = string_list ~context json in
            let* () = distinct ~context values in
            let* () =
              List.fold_left
                (fun acc value ->
                  let* () = acc in
                  if List.mem value association_vocabulary then Ok ()
                  else
                    error ~context
                      (Printf.sprintf "unknown author association %S" value))
                (Ok ()) values
            in
            Ok (Some values)
      in
      Ok { Gate.base; drafts; associations }
  | _ -> error ~context "must be a JSON object"

let decode_trigger ~index json =
  let context = Printf.sprintf "trigger[%d]" index in
  match json with
  | Jsont.Object (mems, _) -> (
      let* kind =
        match Jsont.Json.find_mem "kind" mems with
        | Some (_, Jsont.String (s, _)) -> Ok s
        | Some _ -> error ~context:(context ^ ".kind") "must be a string"
        | None -> error ~context "missing member \"kind\""
      in
      match kind with
      | "github_webhook" ->
          let* slots = route ~context ~names:[ "kind"; "events"; "gate" ] mems in
          let* events =
            let events_context = context ^ ".events" in
            let* json = required ~context slots "events" in
            let* events = string_list ~context:events_context json in
            let* () = distinct ~context:events_context events in
            let* _, reversed =
              List.fold_left
                (fun acc event ->
                  let* index, reversed = acc in
                  let* event =
                    event_name
                      ~context:(Printf.sprintf "%s[%d]" events_context index)
                      event
                  in
                  Ok (index + 1, event :: reversed))
                (Ok (0, []))
                events
            in
            Ok (List.rev reversed)
          in
          let* gate =
            match optional slots "gate" with
            | None -> Ok Gate.permissive
            | Some json -> decode_gate ~context:(context ^ ".gate") json
          in
          Ok (Trigger.Github_webhook { Trigger.Webhook.events; gate })
      | "cli" ->
          let* _slots = route ~context ~names:[ "kind" ] mems in
          Ok Trigger.Cli
      | ("schedule" | "agent_message" | "self_schedule") as kind ->
          error ~context:(context ^ ".kind")
            (Printf.sprintf "%S parses but is refused as unimplemented" kind)
      | other ->
          error ~context:(context ^ ".kind")
            (Printf.sprintf "unknown trigger kind %S" other))
  | _ -> error ~context "must be a JSON object"

let decode_triggers json =
  match json with
  | Jsont.Array ([], _) -> error ~context:"trigger" "must be a non-empty array"
  | Jsont.Array (elements, _) ->
      let* _, reversed =
        List.fold_left
          (fun acc element ->
            let* index, reversed = acc in
            let* trigger = decode_trigger ~index element in
            Ok (index + 1, trigger :: reversed))
          (Ok (0, []))
          elements
      in
      let triggers = List.rev reversed in
      let tag = function
        | Trigger.Github_webhook _ -> "github_webhook"
        | Trigger.Cli -> "cli"
      in
      let* () =
        let rec check seen = function
          | [] -> Ok ()
          | trigger :: rest ->
              let kind = tag trigger in
              if List.mem kind seen then
                error ~context:"trigger"
                  (Printf.sprintf "duplicate trigger kind %S" kind)
              else check (kind :: seen) rest
        in
        check [] triggers
      in
      Ok triggers
  | _ -> error ~context:"trigger" "must be an array"

let decode_run json =
  let context = "run" in
  match json with
  | Jsont.Object (mems, _) ->
      let* slots =
        route ~context
          ~names:
            [
              "mode";
              "model";
              "reasoning";
              "max_steps";
              "prompt";
              "output_schema";
              "skills";
              "project_instructions";
            ]
          mems
      in
      let* () =
        let* json = required ~context slots "mode" in
        let* mode = Decode.as_string ~context:"run.mode" json in
        if String.equal mode "review" then Ok ()
        else error ~context:"run.mode" "v1 admits only \"review\""
      in
      let* model =
        match optional slots "model" with
        | None -> Ok None
        | Some json ->
            Result.map Option.some
              (Decode.as_non_empty_string ~context:"run.model" json)
      in
      let* reasoning =
        match optional slots "reasoning" with
        | None -> Ok None
        | Some json ->
            let* value = Decode.as_string ~context:"run.reasoning" json in
            if List.mem value reasoning_vocabulary then Ok (Some value)
            else
              error ~context:"run.reasoning"
                "must be one of none, minimal, low, medium, high, xhigh, or max"
      in
      let* max_steps =
        match optional slots "max_steps" with
        | None -> Ok 60
        | Some json -> Decode.positive_int ~context:"run.max_steps" json
      in
      let* prompt =
        let* json = required ~context slots "prompt" in
        relative_file ~context:"run.prompt" json
      in
      let* output_schema =
        let* json = required ~context slots "output_schema" in
        relative_file ~context:"run.output_schema" json
      in
      let* () =
        match optional slots "skills" with
        | None -> Ok ()
        | Some (Jsont.Array ([], _)) -> Ok ()
        | Some (Jsont.Array (_, _)) ->
            error ~context:"run.skills" "v1 admits only an empty list"
        | Some _ -> error ~context:"run.skills" "must be an array"
      in
      let* project_instructions =
        match optional slots "project_instructions" with
        | None -> Ok None
        | Some json ->
            Result.map Option.some
              (Decode.as_bool ~context:"run.project_instructions" json)
      in
      Ok
        {
          Run.model;
          reasoning;
          max_steps;
          prompt;
          output_schema;
          project_instructions;
        }
  | _ -> error ~context "must be a JSON object"

let decode_budget json =
  let context = "budget" in
  match json with
  | Jsont.Object (mems, _) ->
      let* slots = route ~context ~names:[ "per_run"; "per_charter" ] mems in
      let* wall_clock =
        let* json = required ~context slots "per_run" in
        match json with
        | Jsont.Object (mems, _) ->
            let context = "budget.per_run" in
            let* slots = route ~context ~names:[ "wall_clock" ] mems in
            let* json = required ~context slots "wall_clock" in
            let* value =
              Decode.as_string ~context:"budget.per_run.wall_clock" json
            in
            duration ~context:"budget.per_run.wall_clock" value
        | _ -> error ~context:"budget.per_run" "must be a JSON object"
      in
      let* usd_per_day, runs_per_hour =
        match optional slots "per_charter" with
        | None -> Ok (None, None)
        | Some (Jsont.Object (mems, _)) ->
            let context = "budget.per_charter" in
            let* slots =
              route ~context ~names:[ "usd_per_day"; "runs_per_hour" ] mems
            in
            let* usd_per_day =
              match optional slots "usd_per_day" with
              | None -> Ok None
              | Some json ->
                  Result.map Option.some
                    (Decode.positive_number
                       ~context:"budget.per_charter.usd_per_day" json)
            in
            let* runs_per_hour =
              match optional slots "runs_per_hour" with
              | None -> Ok None
              | Some json ->
                  Result.map Option.some
                    (Decode.positive_int
                       ~context:"budget.per_charter.runs_per_hour" json)
            in
            Ok (usd_per_day, runs_per_hour)
        | Some _ -> error ~context:"budget.per_charter" "must be a JSON object"
      in
      Ok { Budget.wall_clock; usd_per_day; runs_per_hour }
  | _ -> error ~context "must be a JSON object"

let decode_publish json =
  let context = "publish" in
  match json with
  | Jsont.Object (mems, _) ->
      let* slots = route ~context ~names:[ "github" ] mems in
      let* json = required ~context slots "github" in
      let* value = Decode.as_string ~context:"publish.github" json in
      if String.equal value "review-threads" then Ok ()
      else error ~context:"publish.github" "v1 admits only \"review-threads\""
  | _ -> error ~context "must be a JSON object"

let decode_notify json =
  let context = "notify" in
  match json with
  | Jsont.Object (mems, _) ->
      let* slots = route ~context ~names:[ "on"; "command" ] mems in
      let* on =
        let on_context = "notify.on" in
        let* json = required ~context slots "on" in
        let* names = string_list ~context:on_context json in
        let* () = distinct ~context:on_context names in
        let* _, reversed =
          List.fold_left
            (fun acc name ->
              let* index, reversed = acc in
              match Receipt.Transition.of_string name with
              | Some transition -> Ok (index + 1, transition :: reversed)
              | None ->
                  error ~context:(Printf.sprintf "%s[%d]" on_context index)
                    "must be \"failed\", \"parked\", or \"fenced\"")
            (Ok (0, []))
            names
        in
        Ok (List.rev reversed)
      in
      let* command =
        let command_context = "notify.command" in
        let* json = required ~context slots "command" in
        match json with
        | Jsont.Array ([], _) ->
            error ~context:command_context "must be a non-empty array"
        | Jsont.Array (elements, _) ->
            let* _, reversed =
              List.fold_left
                (fun acc element ->
                  let* index, reversed = acc in
                  let* value =
                    Decode.as_string
                      ~context:(Printf.sprintf "%s[%d]" command_context index)
                      element
                  in
                  Ok (index + 1, value :: reversed))
                (Ok (0, []))
                elements
            in
            let command = List.rev reversed in
            if String.equal (List.hd command) "" then
              error ~context:command_context
                "first element must be a non-empty program"
            else Ok command
        | _ -> error ~context:command_context "must be an array"
      in
      Ok { Notify.on; command }
  | _ -> error ~context "must be a JSON object"

let decode bytes =
  match Jsont_bytesrw.decode_string Jsont.json bytes with
  | Error reason -> error ~context:"" reason
  | Ok (Jsont.Object (mems, _)) ->
      let* slots =
        route ~context:""
          ~names:
            [
              "charter";
              "name";
              "enabled";
              "workspace";
              "trigger";
              "run";
              "budget";
              "publish";
              "notify";
              "suppress";
              "retention";
              "sandbox";
              "permission_unattended";
            ]
          mems
      in
      let* () =
        let* json = required ~context:"" slots "charter" in
        let* version = Decode.positive_int ~context:"charter" json in
        if version = 1 then Ok ()
        else
          error ~context:"charter"
            (Printf.sprintf "unsupported version %d; this build reads version 1"
               version)
      in
      let* name =
        let* json = required ~context:"" slots "name" in
        let* name = Decode.as_non_empty_string ~context:"name" json in
        if String.for_all name_char name then Ok name
        else
          error ~context:"name"
            "must contain only letters, digits, '.', '_', or '-'"
      in
      let* enabled =
        match optional slots "enabled" with
        | None -> Ok true
        | Some json -> Decode.as_bool ~context:"enabled" json
      in
      let* repo =
        let* json = required ~context:"" slots "workspace" in
        match json with
        | Jsont.Object (mems, _) ->
            let* slots = route ~context:"workspace" ~names:[ "repo" ] mems in
            let* json = required ~context:"workspace" slots "repo" in
            let* repo = Decode.as_string ~context:"workspace.repo" json in
            Decode.repo_full_name ~context:"workspace.repo" repo
        | _ -> error ~context:"workspace" "must be a JSON object"
      in
      let* triggers =
        let* json = required ~context:"" slots "trigger" in
        decode_triggers json
      in
      let* run =
        let* json = required ~context:"" slots "run" in
        decode_run json
      in
      let* budget =
        let* json = required ~context:"" slots "budget" in
        decode_budget json
      in
      let* () =
        let* json = required ~context:"" slots "publish" in
        decode_publish json
      in
      let* notify =
        match optional slots "notify" with
        | None -> Ok None
        | Some json -> Result.map Option.some (decode_notify json)
      in
      let* suppress_clean_run =
        match optional slots "suppress" with
        | None -> Ok false
        | Some (Jsont.Object (mems, _)) ->
            let context = "suppress" in
            let* slots = route ~context ~names:[ "clean_run" ] mems in
            let* json = required ~context slots "clean_run" in
            let* value = Decode.as_string ~context:"suppress.clean_run" json in
            if String.equal value "silent" then Ok true
            else error ~context:"suppress.clean_run" "v1 admits only \"silent\""
        | Some _ -> error ~context:"suppress" "must be a JSON object"
      in
      let* keep_failed_worktrees =
        match optional slots "retention" with
        | None -> Ok None
        | Some (Jsont.Object (mems, _)) ->
            let context = "retention" in
            let* slots =
              route ~context ~names:[ "keep_failed_worktrees" ] mems
            in
            (match optional slots "keep_failed_worktrees" with
            | None -> Ok None
            | Some json ->
                Result.map Option.some
                  (Decode.non_negative_int
                     ~context:"retention.keep_failed_worktrees" json))
        | Some _ -> error ~context:"retention" "must be a JSON object"
      in
      let* () =
        match optional slots "sandbox" with
        | None -> Ok ()
        | Some json ->
            let* value = Decode.as_string ~context:"sandbox" json in
            if String.equal value "read-only" then Ok ()
            else error ~context:"sandbox" "v1 admits only \"read-only\""
      in
      let* permission_unattended =
        match optional slots "permission_unattended" with
        | None -> Ok None
        | Some json -> (
            let* value =
              Decode.as_string ~context:"permission_unattended" json
            in
            match value with
            | "deny" -> Ok (Some Unattended.Deny)
            | "block" -> Ok (Some Unattended.Block)
            | _ ->
                error ~context:"permission_unattended"
                  "must be \"deny\" or \"block\"")
      in
      Ok
        {
          name;
          enabled;
          repo;
          triggers;
          permission_unattended;
          run;
          budget;
          notify;
          suppress_clean_run;
          keep_failed_worktrees;
        }
  | Ok _ -> error ~context:"" "charter must be a JSON object"

let policy_digest ~charter_json ~prompt ~output_schema =
  Mentat_digest.key ~length:16 ~domain:"mentat.charter.policy.v1"
    [ charter_json; prompt; output_schema ]
