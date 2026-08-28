(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Goal = Mentat_session.Metadata.Goal

module Claim = struct
  type t = Done of string option | Continuing of string option

  (* Tolerant by law: a claim the steward cannot read is an absent claim
     (continue), never a fault — so the read walks the raw JSON instead of a
     strict codec whose decode error would need swallowing anyway. *)
  let of_json json =
    match json with
    | Jsont.Object (members, _) ->
        let member name =
          List.find_map
            (fun ((n, _), value) ->
              if String.equal n name then Some value else None)
            members
        in
        let note =
          match member "note" with
          | Some (Jsont.String (note, _)) when String.length note > 0 ->
              Some note
          | Some _ | None -> None
        in
        (match member "status" with
        | Some (Jsont.String ("done", _)) -> Some (Done note)
        | Some (Jsont.String ("continuing", _)) -> Some (Continuing note)
        | Some _ | None -> None)
    | _ -> None

  let schema =
    let obj fields =
      Jsont.Json.object'
        (List.map
           (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
           fields)
    in
    obj
      [
        ("type", Jsont.Json.string "object");
        ( "properties",
          obj
            [
              ( "status",
                obj
                  [
                    ("type", Jsont.Json.string "string");
                    ( "enum",
                      Jsont.Json.list
                        [
                          Jsont.Json.string "done";
                          Jsont.Json.string "continuing";
                        ] );
                  ] );
              ( "note",
                obj
                  [
                    ("type", Jsont.Json.string "string");
                    ( "description",
                      Jsont.Json.string
                        "One line: how the goal concluded, or what is next."
                    );
                  ] );
            ] );
        ("required", Jsont.Json.list [ Jsont.Json.string "status" ]);
        ("additionalProperties", Jsont.Json.bool false);
      ]

  let equal a b =
    match (a, b) with
    | Done a, Done b | Continuing a, Continuing b ->
        Option.equal String.equal a b
    | Done _, Continuing _ | Continuing _, Done _ -> false

  let pp ppf t =
    let note = Format.pp_print_option Format.pp_print_string in
    match t with
    | Done n -> Format.fprintf ppf "done (%a)" note n
    | Continuing n -> Format.fprintf ppf "continuing (%a)" note n
end

module Verdict = struct
  type t = Continue | Done of string option | Bound_reached | Budget_spent

  let equal a b =
    match (a, b) with
    | Continue, Continue | Bound_reached, Bound_reached
    | Budget_spent, Budget_spent ->
        true
    | Done a, Done b -> Option.equal String.equal a b
    | (Continue | Done _ | Bound_reached | Budget_spent), _ -> false

  let pp ppf = function
    | Continue -> Format.pp_print_string ppf "continue"
    | Done _ -> Format.pp_print_string ppf "done"
    | Bound_reached -> Format.pp_print_string ppf "bound reached"
    | Budget_spent -> Format.pp_print_string ppf "budget spent"
end

(* The framing's first line, newline-terminated so one objective is never a
   prefix of another's count. *)
let framing_prefix ~objective = "Continuing toward the goal: " ^ objective ^ "\n"

let continuation ~objective =
  framing_prefix ~objective
  ^ "\n\
     Keep working toward it. End this turn by declaring goal_status: status \
     \"done\" only when the goal is genuinely reached, otherwise \
     \"continuing\" with a one-line note on what remains."

let continuations ~objective session =
  let prefix = framing_prefix ~objective in
  List.fold_left
    (fun count turn ->
      match
        Mentat_session.Turn.Input.text (Mentat_session.Turn.input turn)
      with
      | Some text when String.starts_with ~prefix text -> count + 1
      | Some _ | None -> count)
    0
    (Mentat_session.State.turns (Mentat_session.state session))

let decide ~goal ~finished ~claim ~continuations ~spent =
  if not finished then None
  else
    let claim = Option.bind claim Claim.of_json in
    match claim with
    | Some (Claim.Done note) -> Some (Verdict.Done note)
    | Some (Claim.Continuing _) | None ->
        let bound_reached =
          match Goal.max_turns goal with
          | Some bound -> continuations >= bound
          | None -> false
        in
        let budget_spent =
          match (Goal.budget goal, spent) with
          | Some budget, Some spent -> spent >= budget
          | Some _, None | None, _ -> false
        in
        if bound_reached then Some Verdict.Bound_reached
        else if budget_spent then Some Verdict.Budget_spent
        else Some Verdict.Continue
