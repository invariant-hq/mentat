(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type status = Unknown | Trusted | Untrusted

let status_to_string = function
  | Unknown -> "unknown"
  | Trusted -> "trusted"
  | Untrusted -> "untrusted"

module Error = struct
  type t = { operation : string; path : string; reason : string }

  let make ~operation ~path reason = { operation; path; reason }
  let message e = Printf.sprintf "%s: %s" e.path e.reason
  let pp ppf e = Format.pp_print_string ppf (message e)
end

let ( let* ) = Result.bind

(* Decode the store bytes to a version-checked [(root, status-string)] map. All
   failures are rendered strings (the caller wraps them into a structured
   {!Error.t} with the operation and path). *)
let decode_entries _path bytes : ((string * string) list, string) result =
  let* json = Jsont_bytesrw.decode_string Jsont.json bytes in
  let member name fields = Option.map snd (Jsont.Json.find_mem name fields) in
  match json with
  | Jsont.Object (fields, _) -> (
      let* () =
        match member "version" fields with
        | Some (Jsont.Number (v, _)) when Float.is_integer v ->
            if Int.equal (int_of_float v) 2 then Ok ()
            else
              Error
                (Printf.sprintf "unsupported version %d; expected 2"
                   (int_of_float v))
        | _ -> Error "version must be the integer 2"
      in
      match member "workspaces" fields with
      | None -> Ok []
      | Some (Jsont.Object (entries, _)) ->
          List.fold_left
            (fun acc mem ->
              let* acc = acc in
              let key = fst (fst mem) in
              match snd mem with
              | Jsont.String ((("trusted" | "untrusted") as s), _) ->
                  Ok ((key, s) :: acc)
              | _ ->
                  Error
                    (Printf.sprintf "status of %s must be trusted or untrusted"
                       key))
            (Ok []) entries
      | Some _ -> Error "workspaces must be an object")
  | _ -> Error "trust store must be a JSON object"

let load_entries path : ((string * string) list, string) result =
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Error reason -> Error reason
  | Ok None -> Ok []
  | Ok (Some bytes) -> decode_entries path bytes

let status ~path ~root =
  match load_entries path with
  | Error reason -> Error (Error.make ~operation:"read" ~path reason)
  | Ok entries -> (
      match List.assoc_opt root entries with
      | Some "trusted" -> Ok Trusted
      | Some "untrusted" -> Ok Untrusted
      | Some _ | None -> Ok Unknown)

let is_trusted ~path ~root =
  match status ~path ~root with Ok Trusted -> true | _ -> false

let encode entries =
  let workspaces =
    Jsont.Json.object'
      (List.map
         (fun (root, status) ->
           Jsont.Json.mem (Jsont.Json.name root) (Jsont.Json.string status))
         (List.sort (fun (a, _) (b, _) -> String.compare a b) entries))
  in
  let json =
    Jsont.Json.object'
      [
        Jsont.Json.mem (Jsont.Json.name "version") (Jsont.Json.int 2);
        Jsont.Json.mem (Jsont.Json.name "workspaces") workspaces;
      ]
  in
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text ^ "\n"
  | Error message -> failwith message

let set ~path ~root status =
  let value =
    match status with
    | Trusted -> "trusted"
    | Untrusted -> "untrusted"
    | Unknown -> invalid_arg "Trust_store.set: cannot persist Unknown"
  in
  (* Serialize the reload-modify-write against a concurrent [trust]/[untrust]
     with the two-level cancellable lock, and write the [0600] file
     atomically. *)
  match
    Fs.with_lock (path ^ ".lock") (fun () ->
        match load_entries path with
        | Error _ as e -> e
        | Ok entries ->
            let entries = (root, value) :: List.remove_assoc root entries in
            Fs.atomic_write ~perms:0o600 path (encode entries))
  with
  | Ok () -> Ok ()
  | Error reason -> Error (Error.make ~operation:"trust update" ~path reason)
