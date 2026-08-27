(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_charter

module Error = struct
  type t = { operation : string; path : string; reason : string }

  let message e = Printf.sprintf "%s: %s: %s" e.operation e.path e.reason
  let pp ppf e = Format.pp_print_string ppf (message e)
end

let ( let* ) = Result.bind
let error ~operation ~path reason = Error { Error.operation; path; reason }

(* [Fs] reasons already open with the failing path; strip it so the structured
   error renders the path once. *)
let strip_path ~path reason =
  let prefix = path ^ ": " in
  if String.starts_with ~prefix reason then
    String.sub reason (String.length prefix)
      (String.length reason - String.length prefix)
  else reason

let charter_json_name = "charter.json"
let ingress_id_name = "ingress.id"
let secrets_dir_name = "secrets"
let webhook_secret_name = "webhook"

(* Policy files share the executable's small-document cap; the receipt log
   grows for the charter's life and gets a generous one. *)
let receipts_cap = 64 * 1024 * 1024

let read_required ~operation path =
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Ok (Some bytes) -> Ok bytes
  | Ok None -> error ~operation ~path "no such file"
  | Error reason -> error ~operation ~path (strip_path ~path reason)

let require_private ~operation path =
  match Fs.require_private path with
  | Ok () -> Ok ()
  | Error reason -> error ~operation ~path (strip_path ~path reason)

let decode_charter ~operation ~path bytes =
  match Charter.decode bytes with
  | Ok charter -> Ok charter
  | Error e -> error ~operation ~path (Charter.Error.message e)

module Loaded = struct
  type t = {
    name : string;
    dir : string;
    charter : Charter.t;
    digest : string;
    prompt : string;
    output_schema : string;
    ingress_id : string option;
  }
end

(* The trimmed content of a small identity file, [Ok None] when absent; a
   present-but-blank file is an error, never an empty token. *)
let read_token ~operation path =
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Error reason -> error ~operation ~path (strip_path ~path reason)
  | Ok None -> Ok None
  | Ok (Some bytes) -> (
      match String.trim bytes with
      | "" -> error ~operation ~path "file is empty"
      | token -> Ok (Some token))

let read_secret (loaded : Loaded.t) ~file =
  read_token ~operation:"secret read"
    (Filename.concat
       (Filename.concat loaded.Loaded.dir secrets_dir_name)
       file)

(* Every entry of [secrets/] must be owner-only, not just the ones this build
   reads: a loose unknown file under [secrets/] is a loose secret. *)
let check_secrets ~operation dir =
  let secrets = Filename.concat dir secrets_dir_name in
  if not (Sys.file_exists secrets) then Ok ()
  else
    let* () = require_private ~operation secrets in
    match Sys.readdir secrets with
    | exception Sys_error reason -> error ~operation ~path:secrets reason
    | entries ->
        Array.fold_left
          (fun acc entry ->
            let* () = acc in
            require_private ~operation (Filename.concat secrets entry))
          (Ok ()) entries

let load dirs ~name =
  let operation = "load" in
  let dir = User_dirs.charter_dir dirs name in
  let* () =
    if Sys.file_exists dir then Ok ()
    else error ~operation ~path:dir (Printf.sprintf "no charter named %s" name)
  in
  let* () = require_private ~operation dir in
  let json_path = Filename.concat dir charter_json_name in
  let* charter_json = read_required ~operation json_path in
  let* charter = decode_charter ~operation ~path:json_path charter_json in
  let* () =
    if String.equal charter.Charter.name name then Ok ()
    else
      error ~operation ~path:json_path
        (Printf.sprintf "charter is named %S but its directory is %S"
           charter.Charter.name name)
  in
  let* prompt =
    read_required ~operation (Filename.concat dir charter.Charter.run.Charter.Run.prompt)
  in
  let* output_schema =
    read_required ~operation
      (Filename.concat dir charter.Charter.run.Charter.Run.output_schema)
  in
  let* () = check_secrets ~operation dir in
  let* ingress_id =
    read_token ~operation (Filename.concat dir ingress_id_name)
  in
  let* () =
    if not (Option.is_some (Charter.webhook_arm charter)) then Ok ()
    else
      let secret_path =
        Filename.concat (Filename.concat dir secrets_dir_name)
          webhook_secret_name
      in
      match (ingress_id, Sys.file_exists secret_path) with
      | Some _, true -> Ok ()
      | None, _ ->
          error ~operation ~path:(Filename.concat dir ingress_id_name)
            "a webhook charter has no ingress id; run `mentatd charter add` \
             to mint one"
      | Some _, false ->
          error ~operation ~path:secret_path
            "a webhook charter has no webhook secret; run `mentatd charter \
             add` to mint one"
  in
  let digest = Charter.policy_digest ~charter_json ~prompt ~output_schema in
  Ok { Loaded.name; dir; charter; digest; prompt; output_schema; ingress_id }

let roster dirs =
  let root = User_dirs.charters_dir dirs in
  match Sys.readdir root with
  | exception Sys_error reason ->
      if Sys.file_exists root then error ~operation:"roster" ~path:root reason
      else Ok []
  | entries ->
      let names =
        Array.to_list entries
        |> List.filter (fun name ->
               String.length name > 0 && not (Char.equal name.[0] '.'))
        |> List.sort String.compare
      in
      Ok (List.map (fun name -> (name, load dirs ~name)) names)

module Binding = struct
  type t = { name : string; id : string; secret : string; enabled : bool }
end

let ingress_index dirs =
  let* entries = roster dirs in
  let bindings, failures =
    List.fold_left
      (fun (bindings, failures) (name, result) ->
        match result with
        | Error e -> (bindings, (name, e) :: failures)
        | Ok loaded ->
            if not (Option.is_some (Charter.webhook_arm loaded.Loaded.charter)) then
              (bindings, failures)
            else
              let secret_path =
                Filename.concat
                  (Filename.concat loaded.Loaded.dir secrets_dir_name)
                  webhook_secret_name
              in
              let binding =
                let* secret = read_token ~operation:"ingress" secret_path in
                match (loaded.Loaded.ingress_id, secret) with
                | Some id, Some secret ->
                    Ok
                      {
                        Binding.name;
                        id;
                        secret;
                        enabled = loaded.Loaded.charter.Charter.enabled;
                      }
                | None, _ | _, None ->
                    (* [load] refuses a webhook charter without either file,
                       so reaching here means it moved underneath us. *)
                    error ~operation:"ingress" ~path:secret_path
                      "webhook identity disappeared between load and read"
              in
              (match binding with
              | Ok binding -> (binding :: bindings, failures)
              | Error e -> (bindings, (name, e) :: failures)))
      ([], []) entries
  in
  Ok (List.rev bindings, List.rev failures)

let receipts_path dirs name =
  Filename.concat (User_dirs.charter_state_dir dirs name) "receipts.jsonl"

let claim_path dirs ~name ~digest identity =
  let key =
    Mentat_digest.key ~length:32 ~domain:"mentat.charter.event.v1"
      [ digest; Event.Identity.to_string identity ]
  in
  Filename.concat
    (Filename.concat (User_dirs.charter_state_dir dirs name) "events")
    key

let claim_identity dirs ~name ~digest identity =
  let path = claim_path dirs ~name ~digest identity in
  match
    Fs.write_new ~perms:0o600 path (Event.Identity.to_string identity ^ "\n")
  with
  | Ok `Written -> Ok `Claimed
  | Ok `Exists -> Ok `Dup
  | Error reason ->
      error ~operation:"identity claim" ~path (strip_path ~path reason)

let claim_held dirs ~name ~digest identity =
  Sys.file_exists (claim_path dirs ~name ~digest identity)

let append_receipt dirs ~name receipt =
  let path = receipts_path dirs name in
  match Fs.append path (Receipt.encode receipt) with
  | Ok () -> Ok ()
  | Error reason ->
      error ~operation:"receipt append" ~path (strip_path ~path reason)

let read_receipts dirs ~name =
  let path = receipts_path dirs name in
  match Fs.read_capped ~max_bytes:receipts_cap path with
  | Error reason ->
      error ~operation:"receipts read" ~path (strip_path ~path reason)
  | Ok None -> Ok []
  | Ok (Some bytes) ->
      (* Complete lines only: an unterminated final fragment is the crash
         artifact the appender's boundary repair truncates, never a record. *)
      let rec collect acc number start =
        match String.index_from_opt bytes start '\n' with
        | None -> Ok (List.rev acc)
        | Some newline -> (
            let line = String.sub bytes start (newline - start) in
            match Receipt.decode line with
            | Ok receipt -> collect (receipt :: acc) (number + 1) (newline + 1)
            | Error e ->
                error ~operation:"receipts read" ~path
                  (Printf.sprintf "line %d: %s" number
                     (Receipt.Error.message e)))
      in
      collect [] 1 0

module Installed = struct
  type webhook = { id : string; id_minted : bool; secret_minted : bool }
  type t = { loaded : Loaded.t; webhook : webhook option }
end

(* CSPRNG hex for the ingress token and the webhook secret; stdlib [Random]
   is forbidden for any security value. Seeded once, on first mint. *)
let rng_seeded = ref false

let csprng_hex bytes =
  if not !rng_seeded then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_seeded := true
  end;
  let raw = Mirage_crypto_rng.generate bytes in
  let buffer = Buffer.create (bytes * 2) in
  String.iter
    (fun c -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code c)))
    raw;
  Buffer.contents buffer

let atomic_write_wrapped ~operation path bytes =
  match Fs.atomic_write ~perms:0o600 path bytes with
  | Ok () -> Ok ()
  | Error reason -> error ~operation ~path (strip_path ~path reason)

(* Mint-if-absent under the creation barrier: a concurrent minter's win is
   kept, so two racing installs agree on one token. *)
let mint_token ~operation path fresh =
  let* existing = read_token ~operation path in
  match existing with
  | Some token -> Ok (token, false)
  | None -> (
      let fresh = fresh () in
      match Fs.write_new ~perms:0o600 path (fresh ^ "\n") with
      | Ok `Written -> Ok (fresh, true)
      | Ok `Exists -> (
          let* reread = read_token ~operation path in
          match reread with
          | Some token -> Ok (token, false)
          | None -> error ~operation ~path "file is empty")
      | Error reason -> error ~operation ~path (strip_path ~path reason))

let install dirs ~src =
  let operation = "install" in
  let* src_dir =
    match Sys.is_directory src with
    | true -> Ok src
    | false ->
        if String.equal (Filename.basename src) charter_json_name then
          Ok (Filename.dirname src)
        else
          error ~operation ~path:src
            "expected a charter directory or its charter.json"
    | exception Sys_error reason -> error ~operation ~path:src reason
  in
  let json_path = Filename.concat src_dir charter_json_name in
  let* charter_json = read_required ~operation json_path in
  let* charter = decode_charter ~operation ~path:json_path charter_json in
  let name = charter.Charter.name in
  let* () =
    if Char.equal name.[0] '.' then
      error ~operation ~path:json_path
        (Printf.sprintf "charter name %S must not open with a dot" name)
    else Ok ()
  in
  let* prompt =
    read_required ~operation
      (Filename.concat src_dir charter.Charter.run.Charter.Run.prompt)
  in
  let* output_schema =
    read_required ~operation
      (Filename.concat src_dir charter.Charter.run.Charter.Run.output_schema)
  in
  let dst = User_dirs.charter_dir dirs name in
  let in_place =
    match (Unix.realpath src_dir, Unix.realpath dst) with
    | a, b -> String.equal a b
    | exception Unix.Unix_error (_, _, _) -> false
  in
  let* () =
    if in_place then Ok ()
    else
      (* Secrets never ride a proposal, and a webhook identity is minted
         here, never imported. *)
      let foreign kind =
        error ~operation ~path:(Filename.concat src_dir kind)
          (Printf.sprintf
             "a charter proposal must not carry %s; it is created at install"
             kind)
      in
      let* () =
        if Sys.file_exists (Filename.concat src_dir secrets_dir_name) then
          foreign secrets_dir_name
        else Ok ()
      in
      let* () =
        if Sys.file_exists (Filename.concat src_dir ingress_id_name) then
          foreign ingress_id_name
        else Ok ()
      in
      let* () =
        match Fs.mkdir_p dst with
        | Ok () -> Ok ()
        | Error reason -> error ~operation ~path:dst (strip_path ~path:dst reason)
      in
      let* () =
        atomic_write_wrapped ~operation
          (Filename.concat dst charter_json_name)
          charter_json
      in
      let* () =
        atomic_write_wrapped ~operation
          (Filename.concat dst charter.Charter.run.Charter.Run.prompt)
          prompt
      in
      atomic_write_wrapped ~operation
        (Filename.concat dst charter.Charter.run.Charter.Run.output_schema)
        output_schema
  in
  let* webhook =
    if not (Option.is_some (Charter.webhook_arm charter)) then Ok None
    else
      let* id, id_minted =
        mint_token ~operation
          (Filename.concat dst ingress_id_name)
          (fun () -> csprng_hex 16)
      in
      let* _secret, secret_minted =
        mint_token ~operation
          (Filename.concat (Filename.concat dst secrets_dir_name)
             webhook_secret_name)
          (fun () -> csprng_hex 32)
      in
      Ok (Some { Installed.id; id_minted; secret_minted })
  in
  let* loaded = load dirs ~name in
  Ok { Installed.loaded; webhook }

let rotate_webhook_secret (loaded : Loaded.t) =
  let operation = "secret rotate" in
  let path =
    Filename.concat
      (Filename.concat loaded.Loaded.dir secrets_dir_name)
      webhook_secret_name
  in
  if not (Option.is_some (Charter.webhook_arm loaded.Loaded.charter)) then
    error ~operation ~path
      "the charter has no github_webhook trigger, so there is no webhook \
       secret to rotate"
  else
    let* () = atomic_write_wrapped ~operation path (csprng_hex 32 ^ "\n") in
    Ok path
