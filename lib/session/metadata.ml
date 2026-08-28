(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Mentat_session.Metadata" fn message

module Status = struct
  type t = Active | Archived | Deleted

  let is_active = function Active -> true | Archived | Deleted -> false
  let is_archived = function Archived -> true | Active | Deleted -> false
  let is_deleted = function Deleted -> true | Active | Archived -> false
  let equal a b = a = b

  let to_string = function
    | Active -> "active"
    | Archived -> "archived"
    | Deleted -> "deleted"

  let pp ppf t = Format.pp_print_string ppf (to_string t)

  let jsont =
    Jsont.enum ~kind:"session status"
      [ ("active", Active); ("archived", Archived); ("deleted", Deleted) ]
end

module Forked_from = struct
  type t = { parent : Id.t; copied_events : int }

  let make ~parent ~copied_events =
    if copied_events < 0 then
      invalid "Forked_from.make" "copied_events must not be negative";
    { parent; copied_events }

  let parent t = t.parent
  let copied_events t = t.copied_events

  let equal a b =
    Id.equal a.parent b.parent && Int.equal a.copied_events b.copied_events

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ parent = %a; copied_events = %d }@]" Id.pp
      t.parent t.copied_events

  let jsont =
    Jsont.Object.map ~kind:"session fork lineage" (fun parent copied_events ->
        decode_invalid_arg (fun () -> make ~parent ~copied_events))
    |> Jsont.Object.mem "parent" Id.jsont ~enc:parent
    |> Jsont.Object.mem "copied_events" Jsont.int ~enc:copied_events
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Delegated_from = struct
  type t = { parent : Id.t; delegation : Delegation.Id.t }

  let make ~parent ~delegation = { parent; delegation }
  let parent t = t.parent
  let delegation t = t.delegation

  let equal a b =
    Id.equal a.parent b.parent && Delegation.Id.equal a.delegation b.delegation

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ parent = %a; delegation = %a }@]" Id.pp
      t.parent Delegation.Id.pp t.delegation

  let jsont =
    let of_members parent delegation = make ~parent ~delegation in
    Jsont.Object.map ~kind:"session delegation lineage" of_members
    |> Jsont.Object.mem "parent" Id.jsont ~enc:parent
    |> Jsont.Object.mem "delegation" Delegation.Id.jsont ~enc:delegation
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Triggered_from = struct
  type t = { source : string; digest : string; key : string }

  let make ~source ~digest ~key =
    let reject field value =
      if String.is_empty value then
        invalid "Triggered_from.make" (field ^ " must not be empty")
    in
    reject "source" source;
    reject "digest" digest;
    reject "key" key;
    { source; digest; key }

  let source t = t.source
  let digest t = t.digest
  let key t = t.key

  let equal a b =
    String.equal a.source b.source
    && String.equal a.digest b.digest
    && String.equal a.key b.key

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ source = %s; digest = %s; key = %s }@]"
      t.source t.digest t.key

  let jsont =
    Jsont.Object.map ~kind:"session trigger provenance"
      (fun source digest key ->
        decode_invalid_arg (fun () -> make ~source ~digest ~key))
    |> Jsont.Object.mem "source" Jsont.string ~enc:source
    |> Jsont.Object.mem "digest" Jsont.string ~enc:digest
    |> Jsont.Object.mem "key" Jsont.string ~enc:key
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Run_policy = struct
  type t = {
    mode : Contract.Mode.t option;
    output_schema : Jsont.json option;
    max_steps : int option;
    sandbox : string option;
    require_sandbox : bool;
    model : string option;
    reasoning : string option;
    unattended : string option;
    project_instructions : bool option;
  }

  let make ?mode ?output_schema ?max_steps ?sandbox ?(require_sandbox = false)
      ?model ?reasoning ?unattended ?project_instructions () =
    (match max_steps with
    | Some n when n <= 0 ->
        invalid "Run_policy.make" "max_steps must be positive"
    | Some _ | None -> ());
    let reject field = function
      | Some value when String.is_empty value ->
          invalid "Run_policy.make" (field ^ " must not be empty")
      | Some _ | None -> ()
    in
    reject "sandbox" sandbox;
    reject "model" model;
    reject "reasoning" reasoning;
    reject "unattended" unattended;
    {
      mode;
      output_schema;
      max_steps;
      sandbox;
      require_sandbox;
      model;
      reasoning;
      unattended;
      project_instructions;
    }

  let mode t = t.mode
  let output_schema t = t.output_schema
  let max_steps t = t.max_steps
  let sandbox t = t.sandbox
  let require_sandbox t = t.require_sandbox
  let model t = t.model
  let reasoning t = t.reasoning
  let unattended t = t.unattended
  let project_instructions t = t.project_instructions

  let equal a b =
    Option.equal Contract.Mode.equal a.mode b.mode
    && Option.equal Jsont.Json.equal a.output_schema b.output_schema
    && Option.equal Int.equal a.max_steps b.max_steps
    && Option.equal String.equal a.sandbox b.sandbox
    && Bool.equal a.require_sandbox b.require_sandbox
    && Option.equal String.equal a.model b.model
    && Option.equal String.equal a.reasoning b.reasoning
    && Option.equal String.equal a.unattended b.unattended
    && Option.equal Bool.equal a.project_instructions b.project_instructions

  let pp ppf t =
    let text = Format.pp_print_option Format.pp_print_string in
    Format.fprintf ppf
      "@[<hov>{ mode = %a; max_steps = %a; sandbox = %a; require_sandbox = \
       %b; model = %a; reasoning = %a; unattended = %a }@]"
      (Format.pp_print_option Contract.Mode.pp)
      t.mode
      (Format.pp_print_option Format.pp_print_int)
      t.max_steps text t.sandbox t.require_sandbox text t.model text
      t.reasoning text t.unattended

  let jsont =
    Jsont.Object.map ~kind:"session run policy"
      (fun mode output_schema max_steps sandbox require_sandbox model reasoning
           unattended project_instructions ->
        decode_invalid_arg (fun () ->
            make ?mode ?output_schema ?max_steps ?sandbox ~require_sandbox
              ?model ?reasoning ?unattended ?project_instructions ()))
    |> Jsont.Object.opt_mem "mode" Contract.Mode.jsont ~enc:mode
    |> Jsont.Object.opt_mem "output_schema" Jsont.json ~enc:output_schema
    |> Jsont.Object.opt_mem "max_steps" Jsont.int ~enc:max_steps
    |> Jsont.Object.opt_mem "sandbox" Jsont.string ~enc:sandbox
    |> Jsont.Object.mem "require_sandbox" Jsont.bool ~enc:require_sandbox
         ~dec_absent:false ~enc_omit:(fun required -> not required)
    |> Jsont.Object.opt_mem "model" Jsont.string ~enc:model
    |> Jsont.Object.opt_mem "reasoning" Jsont.string ~enc:reasoning
    |> Jsont.Object.opt_mem "unattended" Jsont.string ~enc:unattended
    |> Jsont.Object.opt_mem "project_instructions" Jsont.bool
         ~enc:project_instructions
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Goal = struct
  type t = {
    objective : string;
    max_turns : int option;
    budget : float option;
  }

  let make ~objective ?max_turns ?budget () =
    if String.is_empty objective then
      invalid "Goal.make" "objective must not be empty";
    (match max_turns with
    | Some n when n <= 0 -> invalid "Goal.make" "max_turns must be positive"
    | Some _ | None -> ());
    (match budget with
    | Some b when not (b > 0.) -> invalid "Goal.make" "budget must be positive"
    | Some _ | None -> ());
    { objective; max_turns; budget }

  let objective t = t.objective
  let max_turns t = t.max_turns
  let budget t = t.budget

  let equal a b =
    String.equal a.objective b.objective
    && Option.equal Int.equal a.max_turns b.max_turns
    && Option.equal Float.equal a.budget b.budget

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ objective = %s; max_turns = %a; budget = %a }@]" t.objective
      (Format.pp_print_option Format.pp_print_int)
      t.max_turns
      (Format.pp_print_option Format.pp_print_float)
      t.budget

  let jsont =
    Jsont.Object.map ~kind:"session goal intent"
      (fun objective max_turns budget ->
        decode_invalid_arg (fun () -> make ~objective ?max_turns ?budget ()))
    |> Jsont.Object.mem "objective" Jsont.string ~enc:objective
    |> Jsont.Object.opt_mem "max_turns" Jsont.int ~enc:max_turns
    |> Jsont.Object.opt_mem "budget" Jsont.number ~enc:budget
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  title : string option;
  status : Status.t;
  forked_from : Forked_from.t option;
  delegated_from : Delegated_from.t option;
  triggered_from : Triggered_from.t option;
  run_policy : Run_policy.t option;
  goal : Goal.t option;
  root : Mentat_workspace.Root.t;
  created_at : Time.t;
  updated_at : Time.t;
}

let check_title fn = function
  | None -> ()
  | Some title ->
      if String.is_empty title then invalid fn "title must not be empty"

let check_times fn ~created_at ~updated_at =
  if Time.compare updated_at created_at < 0 then
    invalid fn "updated_at must not be before created_at"

(* A delegation edge owns its child's contract, and a trigger-born run
   already has a steward — the fire. Standing goal intent on either would
   hand the loop a second master. Shared by [make] and [with_goal], the two
   writers. *)
let check_goal fn ~goal ~delegated_from ~triggered_from =
  match (goal, delegated_from, triggered_from) with
  | Some _, Some _, _ ->
      invalid fn "a delegated session cannot carry a goal"
  | Some _, _, Some _ ->
      invalid fn "a trigger-born session cannot carry a goal"
  | _ -> ()

let make ?title ?(status = Status.Active) ?forked_from ?delegated_from
    ?triggered_from ?run_policy ?goal ~cwd ~created_at ~updated_at () =
  check_title "make" title;
  check_times "make" ~created_at ~updated_at;
  (match (forked_from, delegated_from, triggered_from) with
  | Some _, Some _, _ | Some _, _, Some _ | _, Some _, Some _ ->
      invalid "make"
        "fork, delegation, and trigger lineage are mutually exclusive"
  | _ -> ());
  (match (run_policy, delegated_from) with
  | Some _, Some _ ->
      (* A delegated child's contract is its parent edge's; a recorded run
         policy beside the backlink would silently override what the edge
         granted. *)
      invalid "make" "a delegated session cannot carry a run policy"
  | _ -> ());
  check_goal "make" ~goal ~delegated_from ~triggered_from;
  let root = Mentat_workspace.Root.of_dir cwd in
  {
    title;
    status;
    forked_from;
    delegated_from;
    triggered_from;
    run_policy;
    goal;
    root;
    created_at;
    updated_at;
  }

let title t = t.title
let status t = t.status
let fork t = t.forked_from
let delegated_from t = t.delegated_from
let triggered_from t = t.triggered_from
let run_policy t = t.run_policy
let goal t = t.goal
let root t = t.root
let cwd t = Mentat_workspace.Root.dir t.root
let created_at t = t.created_at
let updated_at t = t.updated_at

let with_title title t =
  check_title "with_title" title;
  { t with title }

let with_goal goal t =
  check_goal "with_goal" ~goal ~delegated_from:t.delegated_from
    ~triggered_from:t.triggered_from;
  { t with goal }

let with_status status t = { t with status }

let touch updated_at t =
  check_times "touch" ~created_at:t.created_at ~updated_at;
  { t with updated_at }

let is_active t = Status.is_active t.status
let is_archived t = Status.is_archived t.status
let is_deleted t = Status.is_deleted t.status

(* Field-wise, not [( = )]: a decoded run policy's schema JSON carries parse
   metadata a constructed one lacks, and [Run_policy.equal] compares it
   semantically. *)
let equal a b =
  Option.equal String.equal a.title b.title
  && Status.equal a.status b.status
  && Option.equal Forked_from.equal a.forked_from b.forked_from
  && Option.equal Delegated_from.equal a.delegated_from b.delegated_from
  && Option.equal Triggered_from.equal a.triggered_from b.triggered_from
  && Option.equal Run_policy.equal a.run_policy b.run_policy
  && Option.equal Goal.equal a.goal b.goal
  && Mentat_workspace.Root.equal a.root b.root
  && Time.equal a.created_at b.created_at
  && Time.equal a.updated_at b.updated_at

let pp ppf t =
  Format.fprintf ppf
    "@[<hov>{ title = %a; status = %a; forked_from = %a; delegated_from = %a; \
     triggered_from = %a; run_policy = %a; goal = %a; cwd = %a; created_at = \
     %a; updated_at = %a }@]"
    (Format.pp_print_option Format.pp_print_string)
    t.title Status.pp t.status
    (Format.pp_print_option Forked_from.pp)
    t.forked_from
    (Format.pp_print_option Delegated_from.pp)
    t.delegated_from
    (Format.pp_print_option Triggered_from.pp)
    t.triggered_from
    (Format.pp_print_option Run_policy.pp)
    t.run_policy
    (Format.pp_print_option Goal.pp)
    t.goal Mentat_workspace.Root.pp t.root Time.pp t.created_at Time.pp
    t.updated_at

let absolute_path_jsont =
  Jsont.map ~kind:"absolute path"
    ~dec:(fun raw ->
      match Lpath.Abs.of_string raw with
      | Ok path -> path
      | Error error -> decode_error (Lpath.Error.message error))
    ~enc:Lpath.Abs.to_string Jsont.string

let jsont =
  Jsont.Object.map ~kind:"session metadata"
    (fun title status forked_from delegated_from triggered_from run_policy
         goal cwd created_at updated_at ->
      decode_invalid_arg (fun () ->
          make ?title ~status ?forked_from ?delegated_from ?triggered_from
            ?run_policy ?goal ~cwd ~created_at ~updated_at ()))
  |> Jsont.Object.opt_mem "title" Jsont.string ~enc:title
  |> Jsont.Object.mem "status" Status.jsont ~enc:status
  |> Jsont.Object.opt_mem "forked_from" Forked_from.jsont ~enc:fork
  |> Jsont.Object.opt_mem "delegated_from" Delegated_from.jsont
       ~enc:delegated_from
  |> Jsont.Object.opt_mem "triggered_from" Triggered_from.jsont
       ~enc:triggered_from
  |> Jsont.Object.opt_mem "run_policy" Run_policy.jsont ~enc:run_policy
  |> Jsont.Object.opt_mem "goal" Goal.jsont ~enc:goal
  |> Jsont.Object.mem "cwd" absolute_path_jsont ~enc:cwd
  |> Jsont.Object.mem "created_at" Time.jsont ~enc:created_at
  |> Jsont.Object.mem "updated_at" Time.jsont ~enc:updated_at
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
