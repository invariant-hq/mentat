(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Mentat_session.Origin" fn message

type t =
  | Agent of Id.t
  | Trigger of { charter : string; digest : string; key : string }

let agent sender = Agent sender

let trigger ~charter ~digest ~key =
  let reject field value =
    if String.is_empty value then invalid "trigger" (field ^ " must not be empty")
  in
  reject "charter" charter;
  reject "digest" digest;
  reject "key" key;
  Trigger { charter; digest; key }

let equal a b =
  match (a, b) with
  | Agent a, Agent b -> Id.equal a b
  | Trigger a, Trigger b ->
      String.equal a.charter b.charter
      && String.equal a.digest b.digest
      && String.equal a.key b.key
  | (Agent _ | Trigger _), _ -> false

let pp ppf = function
  | Agent sender -> Format.fprintf ppf "agent(%a)" Id.pp sender
  | Trigger { charter; digest; key } ->
      Format.fprintf ppf "trigger(%s@%s:%s)" charter digest key

let jsont =
  let agent_case =
    Jsont.Object.map ~kind:"agent origin" (fun sender -> Agent sender)
    |> Jsont.Object.mem "session" Id.jsont ~enc:(function
      | Agent sender -> sender
      | Trigger _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "agent" ~dec:Fun.id
  in
  let trigger_case =
    Jsont.Object.map ~kind:"trigger origin" (fun charter digest key ->
        decode_invalid_arg (fun () -> trigger ~charter ~digest ~key))
    |> Jsont.Object.mem "charter" Jsont.string ~enc:(function
      | Trigger { charter; _ } -> charter
      | Agent _ -> assert false)
    |> Jsont.Object.mem "digest" Jsont.string ~enc:(function
      | Trigger { digest; _ } -> digest
      | Agent _ -> assert false)
    |> Jsont.Object.mem "key" Jsont.string ~enc:(function
      | Trigger { key; _ } -> key
      | Agent _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "trigger" ~dec:Fun.id
  in
  let cases = List.map Jsont.Object.Case.make [ agent_case; trigger_case ] in
  let enc_case = function
    | Agent _ as origin -> Jsont.Object.Case.value agent_case origin
    | Trigger _ as origin -> Jsont.Object.Case.value trigger_case origin
  in
  Jsont.Object.map ~kind:"message origin" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
