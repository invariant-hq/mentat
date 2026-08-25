(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Verdict = struct
  type t = Clean | Failing of { errors : int; warnings : int }

  let equal (a : t) (b : t) =
    match (a, b) with
    | Clean, Clean -> true
    | Failing a, Failing b ->
        Int.equal a.errors b.errors && Int.equal a.warnings b.warnings
    | (Clean | Failing _), _ -> false

  let pp ppf (t : t) =
    match t with
    | Clean -> Format.pp_print_string ppf "clean"
    | Failing { errors; warnings } ->
        Format.fprintf ppf "failing(%d errors, %d warnings)" errors warnings
end

module Owner = struct
  type t = Ours | Theirs of int

  let equal (a : t) (b : t) =
    match (a, b) with
    | Ours, Ours -> true
    | Theirs a, Theirs b -> Int.equal a b
    | (Ours | Theirs _), _ -> false

  let pp ppf (t : t) =
    match t with
    | Ours -> Format.pp_print_string ppf "ours"
    | Theirs pid -> Format.fprintf ppf "theirs(pid %d)" pid
end

module Phase = struct
  type t =
    | Building
    | Settled of { build : Verdict.t; lint : int option }
    | Unresponsive

  let equal (a : t) (b : t) =
    match (a, b) with
    | Building, Building | Unresponsive, Unresponsive -> true
    | Settled a, Settled b ->
        Verdict.equal a.build b.build && Option.equal Int.equal a.lint b.lint
    | (Building | Settled _ | Unresponsive), _ -> false

  let pp ppf (t : t) =
    match t with
    | Building -> Format.pp_print_string ppf "building"
    | Settled { build; lint } ->
        Format.fprintf ppf "settled(%a%a)" Verdict.pp build
          (fun ppf -> function
            | None -> ()
            | Some lint -> Format.fprintf ppf ", %d lint" lint)
          lint
    | Unresponsive -> Format.pp_print_string ppf "unresponsive"
end

module Off = struct
  type t = Disabled | No_dune | No_server | Blocked of string | Gave_up

  let equal (a : t) (b : t) =
    match (a, b) with
    | Disabled, Disabled
    | No_dune, No_dune
    | No_server, No_server
    | Gave_up, Gave_up ->
        true
    | Blocked a, Blocked b -> String.equal a b
    | (Disabled | No_dune | No_server | Blocked _ | Gave_up), _ -> false

  let pp ppf (t : t) =
    match t with
    | Disabled -> Format.pp_print_string ppf "disabled"
    | No_dune -> Format.pp_print_string ppf "no dune"
    | No_server -> Format.pp_print_string ppf "no server"
    | Blocked reason -> Format.fprintf ppf "blocked(%s)" reason
    | Gave_up -> Format.pp_print_string ppf "gave up"
end

type t =
  | Off of Off.t
  | Probing
  | Starting
  | Live of { owner : Owner.t; phase : Phase.t }
  | Restarting of { cause : string }

let equal (a : t) (b : t) =
  match (a, b) with
  | Off a, Off b -> Off.equal a b
  | Probing, Probing | Starting, Starting -> true
  | Live a, Live b -> Owner.equal a.owner b.owner && Phase.equal a.phase b.phase
  | Restarting a, Restarting b -> String.equal a.cause b.cause
  | (Off _ | Probing | Starting | Live _ | Restarting _), _ -> false

let pp ppf (t : t) =
  match t with
  | Off off -> Format.fprintf ppf "off(%a)" Off.pp off
  | Probing -> Format.pp_print_string ppf "probing"
  | Starting -> Format.pp_print_string ppf "starting"
  | Live { owner; phase } ->
      Format.fprintf ppf "live(%a, %a)" Owner.pp owner Phase.pp phase
  | Restarting { cause } -> Format.fprintf ppf "restarting(%s)" cause

(* The status crosses the wire as one flat object: a closed [state] tag and
   the payload members every state defaults except its own. The tag enum
   rejects an unknown state loudly, so reconstruction is total; a [Failing]
   verdict is any settled state whose severity counts are not both zero. *)
let state_jsont =
  Jsont.enum ~kind:"workspace watch state"
    [
      ("off-disabled", `Off_disabled);
      ("off-no-dune", `Off_no_dune);
      ("off-no-server", `Off_no_server);
      ("off-blocked", `Off_blocked);
      ("off-gave-up", `Off_gave_up);
      ("probing", `Probing);
      ("starting", `Starting);
      ("live", `Live);
      ("restarting", `Restarting);
    ]

let phase_jsont =
  Jsont.enum ~kind:"workspace watch phase"
    [
      ("building", `Building); ("settled", `Settled);
      ("unresponsive", `Unresponsive);
    ]

let state_of = function
  | Off Off.Disabled -> `Off_disabled
  | Off Off.No_dune -> `Off_no_dune
  | Off Off.No_server -> `Off_no_server
  | Off (Off.Blocked _) -> `Off_blocked
  | Off Off.Gave_up -> `Off_gave_up
  | Probing -> `Probing
  | Starting -> `Starting
  | Live _ -> `Live
  | Restarting _ -> `Restarting

let reason_of = function
  | Off (Off.Blocked reason) -> reason
  | Restarting { cause } -> cause
  | Off _ | Probing | Starting | Live _ -> ""

let pid_of = function
  | Live { owner = Owner.Theirs pid; _ } -> pid
  | Live { owner = Owner.Ours; _ } | Off _ | Probing | Starting | Restarting _
    ->
      0

let ours_of = function
  | Live { owner = Owner.Ours; _ } -> true
  | Live _ | Off _ | Probing | Starting | Restarting _ -> false

let phase_of = function
  | Live { phase = Phase.Building; _ } -> `Building
  | Live { phase = Phase.Settled _; _ } -> `Settled
  | Live { phase = Phase.Unresponsive; _ } -> `Unresponsive
  | Off _ | Probing | Starting | Restarting _ -> `Building

let errors_of = function
  | Live { phase = Phase.Settled { build = Verdict.Failing { errors; _ }; _ }; _ }
    ->
      errors
  | _ -> 0

let warnings_of = function
  | Live
      {
        phase = Phase.Settled { build = Verdict.Failing { warnings; _ }; _ };
        _;
      } ->
      warnings
  | _ -> 0

let lint_of = function
  | Live { phase = Phase.Settled { lint; _ }; _ } -> lint
  | _ -> None

let jsont =
  Jsont.Object.map ~kind:"workspace watch status"
    (fun state reason pid ours phase errors warnings lint ->
      match state with
      | `Off_disabled -> Off Off.Disabled
      | `Off_no_dune -> Off Off.No_dune
      | `Off_no_server -> Off Off.No_server
      | `Off_blocked -> Off (Off.Blocked reason)
      | `Off_gave_up -> Off Off.Gave_up
      | `Probing -> Probing
      | `Starting -> Starting
      | `Restarting -> Restarting { cause = reason }
      | `Live ->
          let owner =
            if ours then Owner.Ours else Owner.Theirs pid
          in
          let phase =
            match phase with
            | `Building -> Phase.Building
            | `Unresponsive -> Phase.Unresponsive
            | `Settled ->
                let build =
                  if errors = 0 && warnings = 0 then Verdict.Clean
                  else Verdict.Failing { errors; warnings }
                in
                Phase.Settled { build; lint }
          in
          Live { owner; phase })
  |> Jsont.Object.mem "state" state_jsont ~enc:state_of
  |> Jsont.Object.mem "reason" Jsont.string ~enc:reason_of
  |> Jsont.Object.mem "pid" Jsont.int ~enc:pid_of
  |> Jsont.Object.mem "ours" Jsont.bool ~enc:ours_of
  |> Jsont.Object.mem "phase" phase_jsont ~enc:phase_of
  |> Jsont.Object.mem "errors" Jsont.int ~enc:errors_of
  |> Jsont.Object.mem "warnings" Jsont.int ~enc:warnings_of
  |> Jsont.Object.mem "lint" (Jsont.option Jsont.int) ~enc:lint_of
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
