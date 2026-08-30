(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type t = { context : string; reason : string }

  let make ~context reason = { context; reason }

  let message e =
    if String.equal e.context "" then e.reason
    else Printf.sprintf "%s: %s" e.context e.reason

  let pp ppf e = Format.pp_print_string ppf (message e)
end

let error ~context reason = Error (Error.make ~context reason)

let as_string ~context = function
  | Jsont.String (s, _) -> Ok s
  | _ -> error ~context "must be a string"

let as_non_empty_string ~context json =
  Result.bind (as_string ~context json) (fun s ->
      if String.equal s "" then error ~context "must be a non-empty string"
      else Ok s)

let as_bool ~context = function
  | Jsont.Bool (b, _) -> Ok b
  | _ -> error ~context "must be a boolean"

(* [Jsont.Number] carries a float; accept only values that are an integer
   round-trip so an out-of-range magnitude cannot alias a valid value. *)
let int_at_least ~context floor = function
  | Jsont.Number (v, _)
    when Float.compare v (float_of_int floor) >= 0
         && Float.equal (float_of_int (int_of_float v)) v ->
      Ok (int_of_float v)
  | _ ->
      error ~context
        (if floor = 1 then "must be a positive integer"
         else "must be a non-negative integer")

let positive_int ~context json = int_at_least ~context 1 json
let non_negative_int ~context json = int_at_least ~context 0 json

let positive_number ~context = function
  | Jsont.Number (v, _) when Float.is_finite v && Float.compare v 0.0 > 0 ->
      Ok v
  | _ -> error ~context "must be a number greater than 0"

(* Route each member of [mems] into its slot exactly once; an unlisted or
   repeated member is the caller's strictness error. *)
let route_members ~context ~slots mems =
  List.fold_left
    (fun acc mem ->
      Result.bind acc (fun () ->
          let name = fst (fst mem) in
          match List.assoc_opt name slots with
          | None -> error ~context (Printf.sprintf "unknown member %S" name)
          | Some slot -> (
              match !slot with
              | Some _ ->
                  error ~context (Printf.sprintf "duplicate member %S" name)
              | None ->
                  slot := Some (snd mem);
                  Ok ())))
    (Ok ()) mems

let require ~context name slot =
  match !slot with
  | Some json -> Ok json
  | None -> error ~context (Printf.sprintf "missing member %S" name)

let repo_char c =
  (c >= 'A' && c <= 'Z')
  || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || Char.equal c '.' || Char.equal c '_' || Char.equal c '-'

let repo_full_name ~context s =
  match String.split_on_char '/' s with
  | [ owner; name ]
    when String.length owner > 0
         && String.length name > 0
         && String.for_all repo_char owner
         && String.for_all repo_char name ->
      Ok s
  | _ -> error ~context "must name a repository as owner/name"

module Lenient = struct
  let mem name = function
    | Jsont.Object (mems, _) ->
        Option.map snd (Jsont.Json.find_mem name mems)
    | _ -> None

  let decode bytes =
    match Jsont_bytesrw.decode_string Jsont.json bytes with
    | Ok json -> Some json
    | Error _ -> None
end
