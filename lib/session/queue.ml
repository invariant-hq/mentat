(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Mentat_session.Queue" fn message

module Id =
  String_id.Make
    (struct
      let module_path = "Mentat_session.Queue.Id"
      let kind = "queue entry id"
    end)
    ()

module Entry = struct
  type t = {
    id : Id.t;
    input : Mentat_llm.Content.t list;
    origin : Origin.t option;
  }

  let make ?origin ~id ~input () =
    if List.is_empty input then invalid "Entry.make" "input must not be empty";
    { id; input; origin }

  let id t = t.id
  let input t = t.input
  let origin t = t.origin

  (* Content blocks carry no JSON and no functions, so structural equality is
     exact here (see {!Mentat_llm.Content}). *)
  let equal a b =
    Id.equal a.id b.id && a.input = b.input
    && Option.equal Origin.equal a.origin b.origin

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ id = %a; input = [%d block(s)]%a }@]" Id.pp
      t.id
      (List.length t.input)
      (fun ppf -> function
        | None -> ()
        | Some origin -> Format.fprintf ppf "; origin = %a" Origin.pp origin)
      t.origin

  let jsont =
    Jsont.Object.map ~kind:"queue entry" (fun id input origin ->
        decode_invalid_arg (fun () -> make ?origin ~id ~input ()))
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.mem "input" (Jsont.list Mentat_llm.Content.jsont) ~enc:input
    |> Jsont.Object.opt_mem "origin" Origin.jsont ~enc:origin
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Update = struct
  type t = Enqueued of Entry.t | Replaced of Entry.t list | Cleared

  let check_unique_ids fn entries =
    let rec loop seen = function
      | [] -> ()
      | entry :: rest ->
          let id = Entry.id entry in
          if List.exists (Id.equal id) seen then
            invalid fn ("duplicate queue entry id: " ^ Id.to_string id)
          else loop (id :: seen) rest
    in
    loop [] entries

  let enqueued entry = Enqueued entry

  let replaced entries =
    check_unique_ids "Update.replaced" entries;
    Replaced entries

  let cleared = Cleared

  let equal a b =
    match (a, b) with
    | Enqueued a, Enqueued b -> Entry.equal a b
    | Replaced a, Replaced b -> List.equal Entry.equal a b
    | Cleared, Cleared -> true
    | (Enqueued _ | Replaced _ | Cleared), _ -> false

  let pp ppf = function
    | Enqueued entry -> Format.fprintf ppf "enqueued(%a)" Entry.pp entry
    | Replaced entries ->
        Format.fprintf ppf "replaced[%d]" (List.length entries)
    | Cleared -> Format.pp_print_string ppf "cleared"

  let jsont =
    let enqueued_case =
      Jsont.Object.map ~kind:"queue enqueued" (fun entry -> Enqueued entry)
      |> Jsont.Object.mem "entry" Entry.jsont ~enc:(function
        | Enqueued entry -> entry
        | Replaced _ | Cleared -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "enqueued" ~dec:Fun.id
    in
    let replaced_case =
      Jsont.Object.map ~kind:"queue replaced" (fun entries ->
          decode_invalid_arg (fun () -> replaced entries))
      |> Jsont.Object.mem "entries" (Jsont.list Entry.jsont) ~enc:(function
        | Replaced entries -> entries
        | Enqueued _ | Cleared -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "replaced" ~dec:Fun.id
    in
    let cleared_case =
      Jsont.Object.map ~kind:"queue cleared" Cleared
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "cleared" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ enqueued_case; replaced_case; cleared_case ]
    in
    let enc_case = function
      | Enqueued _ as update -> Jsont.Object.Case.value enqueued_case update
      | Replaced _ as update -> Jsont.Object.Case.value replaced_case update
      | Cleared as update -> Jsont.Object.Case.value cleared_case update
    in
    Jsont.Object.map ~kind:"queue update" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end
