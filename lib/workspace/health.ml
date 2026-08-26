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

  let equal (a : t) (b : t) =
    match (a, b) with
    | Building, Building -> true
    | Settled a, Settled b ->
        Verdict.equal a.build b.build && Option.equal Int.equal a.lint b.lint
    | (Building | Settled _), _ -> false

  let pp ppf (t : t) =
    match t with
    | Building -> Format.pp_print_string ppf "building"
    | Settled { build; lint } ->
        Format.fprintf ppf "settled(%a%a)" Verdict.pp build
          (fun ppf -> function
            | None -> ()
            | Some lint -> Format.fprintf ppf ", %d lint" lint)
          lint
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

(* Why an owned watch is being respawned. *)
module Restart = struct
  type t = Exited of string | Hung

  let equal (a : t) (b : t) =
    match (a, b) with
    | Exited a, Exited b -> String.equal a b
    | Hung, Hung -> true
    | (Exited _ | Hung), _ -> false

  let pp ppf (t : t) =
    match t with
    | Exited description -> Format.fprintf ppf "exited(%s)" description
    | Hung -> Format.pp_print_string ppf "hung"
end

type t =
  | Off of Off.t
  | Probing
  | Starting
  | Live of { owner : Owner.t; phase : Phase.t }
  | Restarting of Restart.t

let equal (a : t) (b : t) =
  match (a, b) with
  | Off a, Off b -> Off.equal a b
  | Probing, Probing | Starting, Starting -> true
  | Live a, Live b -> Owner.equal a.owner b.owner && Phase.equal a.phase b.phase
  | Restarting a, Restarting b -> Restart.equal a b
  | (Off _ | Probing | Starting | Live _ | Restarting _), _ -> false

let pp ppf (t : t) =
  match t with
  | Off off -> Format.fprintf ppf "off(%a)" Off.pp off
  | Probing -> Format.pp_print_string ppf "probing"
  | Starting -> Format.pp_print_string ppf "starting"
  | Live { owner; phase } ->
      Format.fprintf ppf "live(%a, %a)" Owner.pp owner Phase.pp phase
  | Restarting cause -> Format.fprintf ppf "restarting(%a)" Restart.pp cause

(* The status crosses the wire as a tagged case object: every member present
   is meaningful for its case, so a consumer can never read an invented fact —
   a phase off an off watch, a pid off an owned one — and a hand-written
   client speaks only the members its case has. *)
let off_reason_jsont =
  Jsont.enum ~kind:"workspace watch off reason"
    [
      ("disabled", `Disabled);
      ("no-dune", `No_dune);
      ("no-server", `No_server);
      ("blocked", `Blocked);
      ("gave-up", `Gave_up);
    ]

let off_case =
  Jsont.Object.map ~kind:"off watch" (fun reason detail ->
      match reason with
      | `Disabled -> Off Off.Disabled
      | `No_dune -> Off Off.No_dune
      | `No_server -> Off Off.No_server
      | `Blocked -> Off (Off.Blocked (Option.value detail ~default:""))
      | `Gave_up -> Off Off.Gave_up)
  |> Jsont.Object.mem "reason" off_reason_jsont ~enc:(function
    | Off Off.Disabled -> `Disabled
    | Off Off.No_dune -> `No_dune
    | Off Off.No_server -> `No_server
    | Off (Off.Blocked _) -> `Blocked
    | Off Off.Gave_up -> `Gave_up
    | Probing | Starting | Live _ | Restarting _ -> assert false)
  |> Jsont.Object.opt_mem "detail" Jsont.string ~enc:(function
    | Off (Off.Blocked detail) -> Some detail
    | Off _ -> None
    | Probing | Starting | Live _ | Restarting _ -> assert false)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
  |> Jsont.Object.Case.map "off" ~dec:Fun.id

let probing_case =
  Jsont.Object.map ~kind:"probing watch" Probing
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
  |> Jsont.Object.Case.map "probing" ~dec:Fun.id

let starting_case =
  Jsont.Object.map ~kind:"starting watch" Starting
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
  |> Jsont.Object.Case.map "starting" ~dec:Fun.id

let restart_cause_jsont =
  Jsont.enum ~kind:"workspace watch restart cause"
    [ ("exited", `Exited); ("hung", `Hung) ]

let restarting_case =
  Jsont.Object.map ~kind:"restarting watch" (fun cause detail ->
      match cause with
      | `Exited -> Restarting (Restart.Exited (Option.value detail ~default:""))
      | `Hung -> Restarting Restart.Hung)
  |> Jsont.Object.mem "cause" restart_cause_jsont ~enc:(function
    | Restarting (Restart.Exited _) -> `Exited
    | Restarting Restart.Hung -> `Hung
    | Off _ | Probing | Starting | Live _ -> assert false)
  |> Jsont.Object.opt_mem "detail" Jsont.string ~enc:(function
    | Restarting (Restart.Exited detail) -> Some detail
    | Restarting Restart.Hung -> None
    | Off _ | Probing | Starting | Live _ -> assert false)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
  |> Jsont.Object.Case.map "restarting" ~dec:Fun.id

let phase_tag_jsont =
  Jsont.enum ~kind:"workspace watch phase"
    [ ("building", `Building); ("settled", `Settled) ]

let live_owner = function
  | Live { owner; _ } -> owner
  | Off _ | Probing | Starting | Restarting _ -> assert false

let live_phase = function
  | Live { phase; _ } -> phase
  | Off _ | Probing | Starting | Restarting _ -> assert false

let live_case =
  Jsont.Object.map ~kind:"live watch"
    (fun ours pid phase errors warnings lint ->
      let owner =
        if ours then Owner.Ours
        else Owner.Theirs (Option.value pid ~default:0)
      in
      let phase =
        match phase with
        | `Building -> Phase.Building
        | `Settled ->
            let errors = Option.value errors ~default:0 in
            let warnings = Option.value warnings ~default:0 in
            let build =
              if errors = 0 && warnings = 0 then Verdict.Clean
              else Verdict.Failing { errors; warnings }
            in
            Phase.Settled { build; lint }
      in
      Live { owner; phase })
  |> Jsont.Object.mem "ours" Jsont.bool ~enc:(fun t ->
         match live_owner t with Owner.Ours -> true | Owner.Theirs _ -> false)
  |> Jsont.Object.opt_mem "pid" Jsont.int ~enc:(fun t ->
         match live_owner t with
         | Owner.Theirs pid -> Some pid
         | Owner.Ours -> None)
  |> Jsont.Object.mem "phase" phase_tag_jsont ~enc:(fun t ->
         match live_phase t with
         | Phase.Building -> `Building
         | Phase.Settled _ -> `Settled)
  |> Jsont.Object.opt_mem "errors" Jsont.int ~enc:(fun t ->
         match live_phase t with
         | Phase.Settled { build = Verdict.Failing { errors; _ }; _ } ->
             Some errors
         | Phase.Settled { build = Verdict.Clean; _ } | Phase.Building ->
             None)
  |> Jsont.Object.opt_mem "warnings" Jsont.int ~enc:(fun t ->
         match live_phase t with
         | Phase.Settled { build = Verdict.Failing { warnings; _ }; _ } ->
             Some warnings
         | Phase.Settled { build = Verdict.Clean; _ } | Phase.Building ->
             None)
  |> Jsont.Object.opt_mem "lint" Jsont.int ~enc:(fun t ->
         match live_phase t with
         | Phase.Settled { lint; _ } -> lint
         | Phase.Building -> None)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
  |> Jsont.Object.Case.map "live" ~dec:Fun.id

let jsont =
  let cases =
    List.map Jsont.Object.Case.make
      [ off_case; probing_case; starting_case; restarting_case; live_case ]
  in
  let enc_case = function
    | Off _ as t -> Jsont.Object.Case.value off_case t
    | Probing as t -> Jsont.Object.Case.value probing_case t
    | Starting as t -> Jsont.Object.Case.value starting_case t
    | Restarting _ as t -> Jsont.Object.Case.value restarting_case t
    | Live _ as t -> Jsont.Object.Case.value live_case t
  in
  Jsont.Object.map ~kind:"workspace watch status" Fun.id
  |> Jsont.Object.case_mem "state" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
