(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module String_set = Set.Make (String)

(* Deduplicate by key, first occurrence wins, order preserved. *)
let distinct findings =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | finding :: rest ->
        let key = Finding.key finding in
        if String_set.mem key seen then loop seen acc rest
        else loop (String_set.add key seen) (finding :: acc) rest
  in
  loop String_set.empty [] findings

let in_lane lane findings =
  distinct
    (List.filter (fun f -> Finding.Lane.equal (Finding.lane f) lane) findings)

let severity_counts findings =
  List.fold_left
    (fun (errors, warnings) finding ->
      match Finding.severity finding with
      | Finding.Severity.Error -> (errors + 1, warnings)
      | Finding.Severity.Warning -> (errors, warnings + 1))
    (0, 0) findings

module Reading = struct
  (* Findings arrive as one list and are partitioned here, once: laneness is
     the finding's own fact, so a reading cannot hold a build lane full of
     lint findings. The lint lane exists iff it was declared live or a lint
     finding is present — a watch whose lint targets are unknown reads
     lint-absent, never lint-clean. [empty_confirmed] is one producer-level
     fact: whether the settle that emptied the store was witnessed. *)
  type t = {
    build : Finding.t list;
    lint : Finding.t list option;
    empty_confirmed : bool;
  }

  let make ?(lint_live = false) ?(empty_confirmed = true) findings =
    let build = in_lane Finding.Lane.Build findings in
    let lints = in_lane Finding.Lane.Lint findings in
    let lint =
      match (lint_live, lints) with
      | false, [] -> None
      | (true | false), _ -> Some lints
    in
    { build; lint; empty_confirmed }

  let verdict t =
    let errors, warnings = severity_counts t.build in
    if errors = 0 && warnings = 0 then Mentat_workspace.Health.Verdict.Clean
    else Mentat_workspace.Health.Verdict.Failing { errors; warnings }

  let lint t = Option.map List.length t.lint
end

module State = struct
  (* Per lane, the finding set last stated to the model, as keys. The findings
     themselves are not kept: identity is the key, and every rendering need is
     served by the reading that advances the baseline. *)
  type t = { build : String_set.t; lint : String_set.t }

  let initial = { build = String_set.empty; lint = String_set.empty }
end

type t =
  | Failing of {
      lane : Finding.Lane.t;
      current : Finding.t list;
      fresh : Finding.t list;
      resolved : int;
    }
  | Recovered of Finding.Lane.t

let key_set findings =
  List.fold_left
    (fun keys finding -> String_set.add (Finding.key finding) keys)
    String_set.empty findings

let step_lane lane stated ~empty_confirmed (findings : Finding.t list option)
    =
  match findings with
  | None -> (None, stated)
  | Some findings -> (
      let keys = key_set findings in
      match findings with
      | [] ->
          if String_set.is_empty stated then (None, stated)
          else if empty_confirmed then (Some (Recovered lane), keys)
          else (None, stated)
      | _ when String_set.equal keys stated -> (None, stated)
      | _ ->
          let fresh =
            List.filter
              (fun f -> not (String_set.mem (Finding.key f) stated))
              findings
          in
          let resolved = String_set.cardinal (String_set.diff stated keys) in
          (Some (Failing { lane; current = findings; fresh; resolved }), keys))

let step (state : State.t) reading =
  match reading with
  | None -> ([], state)
  | Some { Reading.build; lint; empty_confirmed } ->
      let build_change, build_stated =
        step_lane Finding.Lane.Build state.State.build ~empty_confirmed
          (Some build)
      in
      let lint_change, lint_stated =
        (* The lint lane borrows the build stream's settle-witness gate:
           runner-attested emptiness needs no witness, so the borrowing can
           only delay a Lint clean by the fallback window — deliberate, and
           cheaper than a second confirmation vocabulary. *)
        step_lane Finding.Lane.Lint state.State.lint ~empty_confirmed lint
      in
      ( List.filter_map Fun.id [ build_change; lint_change ],
        { State.build = build_stated; lint = lint_stated } )

(* Rendering. *)

let max_body_findings = 20

let plural n word = if n = 1 then word else word ^ "s"

let counted n word = string_of_int n ^ " " ^ plural n word

let delta_clause ~fresh ~resolved =
  if resolved = 0 then string_of_int fresh ^ " new"
  else
    string_of_int fresh ^ " new, " ^ string_of_int resolved ^ " resolved"

let failing_title lane ~errors ~warnings ~fresh ~resolved =
  let delta = delta_clause ~fresh ~resolved in
  match (lane : Finding.Lane.t) with
  | Finding.Lane.Build ->
      let counts =
        match (errors, warnings) with
        | 0, warnings -> counted warnings "warning"
        | errors, 0 -> counted errors "error"
        | errors, warnings ->
            counted errors "error" ^ ", " ^ counted warnings "warning"
      in
      "Build failing (" ^ counts ^ ": " ^ delta ^ ")"
  | Finding.Lane.Lint ->
      counted (errors + warnings) "finding" ^ " (" ^ delta ^ ")"

let failing_body ~fresh ~unchanged =
  let shown, elided =
    if List.length fresh <= max_body_findings then (fresh, 0)
    else
      ( List.filteri (fun i _ -> i < max_body_findings) fresh,
        List.length fresh - max_body_findings )
  in
  let lines = List.map Finding.body_line shown in
  let lines =
    if elided = 0 then lines
    else lines @ [ "… and " ^ string_of_int elided ^ " more" ]
  in
  let lines =
    if unchanged = 0 then lines
    else
      lines
      @ [ string_of_int unchanged ^ " unchanged since the last notice" ]
  in
  String.concat "\n" lines

let source_of = function
  | Finding.Lane.Build -> "dune"
  | Finding.Lane.Lint -> "lint"

let key_of = function
  | Finding.Lane.Build -> "dune.build"
  | Finding.Lane.Lint -> "dune.lint"

let notice = function
  | Recovered Finding.Lane.Build ->
      Mentat_workspace.Notice.make ~source:"dune" ~severity:Mentat_workspace.Notice.Severity.Info
        ~title:"Build recovered" ~key:"dune.build" ()
  | Recovered Finding.Lane.Lint ->
      Mentat_workspace.Notice.make ~source:"lint" ~severity:Mentat_workspace.Notice.Severity.Info
        ~title:"Lint clean" ~key:"dune.lint" ()
  | Failing { lane; current; fresh; resolved } ->
      let errors, warnings = severity_counts current in
      let severity =
        if errors > 0 then Mentat_workspace.Notice.Severity.Error else Mentat_workspace.Notice.Severity.Warning
      in
      let title =
        failing_title lane ~errors ~warnings ~fresh:(List.length fresh)
          ~resolved
      in
      let unchanged = List.length current - List.length fresh in
      let body = failing_body ~fresh ~unchanged in
      if String.is_empty body then
        Mentat_workspace.Notice.make ~source:(source_of lane) ~severity ~title ~key:(key_of lane)
          ()
      else
        Mentat_workspace.Notice.make ~source:(source_of lane) ~severity ~title ~body
          ~key:(key_of lane) ()
