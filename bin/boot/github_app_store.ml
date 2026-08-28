(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

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

let app_json_name = "app.json"
let key_name = "private-key.pem"
let webhook_secret_name = "webhook-secret"
let ingress_id_name = "ingress.id"
let public_url_name = "public-url"

type t = {
  dir : string;
  app_id : int;
  slug : string;
  name : string;
  client_id : string;
  html_url : string;
  api_base : string;
  created_at : string;
}

(* CSPRNG hex; stdlib [Random] is forbidden for any security value. Seeded
   once, on first mint. *)
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

let fresh_token () = csprng_hex 16
let fresh_webhook_secret () = csprng_hex 32

(* app.json codec: strict both ways — an unknown member is refused, so the
   home can never silently carry identity this build does not understand. *)

let decode_app ~dir bytes =
  let* json =
    Result.map_error
      (fun reason -> Printf.sprintf "not JSON: %s" reason)
      (Jsont_bytesrw.decode_string Jsont.json bytes)
  in
  match json with
  | Jsont.Object (fields, _) ->
      let known =
        [
          "github_app"; "id"; "slug"; "name"; "client_id"; "html_url";
          "api_base"; "created_at";
        ]
      in
      let* () =
        List.fold_left
          (fun acc ((name, _), _) ->
            let* () = acc in
            if List.mem name known then Ok ()
            else Error (Printf.sprintf "unknown member %S" name))
          (Ok ()) fields
      in
      let member name = Option.map snd (Jsont.Json.find_mem name fields) in
      let string_member name =
        match member name with
        | Some (Jsont.String (s, _)) when String.length s > 0 -> Ok s
        | Some _ -> Error (Printf.sprintf "%s must be a non-empty string" name)
        | None -> Error (Printf.sprintf "missing member %s" name)
      in
      let* () =
        match member "github_app" with
        | Some (Jsont.Number (v, _))
          when Float.is_integer v && Int.equal (int_of_float v) 1 ->
            Ok ()
        | Some _ | None -> Error "github_app must be the integer 1"
      in
      let* app_id =
        match member "id" with
        | Some (Jsont.Number (v, _)) when Float.is_integer v && v > 0.0 ->
            Ok (int_of_float v)
        | Some _ | None -> Error "id must be a positive integer"
      in
      let* slug = string_member "slug" in
      let* name = string_member "name" in
      let* client_id = string_member "client_id" in
      let* html_url = string_member "html_url" in
      let* api_base = string_member "api_base" in
      let* created_at = string_member "created_at" in
      Ok { dir; app_id; slug; name; client_id; html_url; api_base; created_at }
  | _ -> Error "app.json must be a JSON object"

let encode_app t =
  let json =
    Jsont.Json.object'
      [
        Jsont.Json.mem (Jsont.Json.name "github_app") (Jsont.Json.int 1);
        Jsont.Json.mem (Jsont.Json.name "id") (Jsont.Json.int t.app_id);
        Jsont.Json.mem (Jsont.Json.name "slug") (Jsont.Json.string t.slug);
        Jsont.Json.mem (Jsont.Json.name "name") (Jsont.Json.string t.name);
        Jsont.Json.mem
          (Jsont.Json.name "client_id")
          (Jsont.Json.string t.client_id);
        Jsont.Json.mem
          (Jsont.Json.name "html_url")
          (Jsont.Json.string t.html_url);
        Jsont.Json.mem
          (Jsont.Json.name "api_base")
          (Jsont.Json.string t.api_base);
        Jsont.Json.mem
          (Jsont.Json.name "created_at")
          (Jsont.Json.string t.created_at);
      ]
  in
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text ^ "\n"
  | Error message -> failwith message

let require_private ~operation path =
  match Fs.require_private path with
  | Ok () -> Ok ()
  | Error reason -> error ~operation ~path (strip_path ~path reason)

let read_required ~operation path =
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Ok (Some bytes) -> Ok bytes
  | Ok None -> error ~operation ~path "no such file"
  | Error reason -> error ~operation ~path (strip_path ~path reason)

(* The trimmed content of a small identity file; a present-but-blank file is
   an error, never an empty token. *)
let read_trimmed ~operation path =
  let* bytes = read_required ~operation path in
  match String.trim bytes with
  | "" -> error ~operation ~path "file is empty"
  | token -> Ok token

let load dirs =
  let operation = "github app load" in
  let dir = User_dirs.github_app_dir dirs in
  if not (Sys.file_exists dir) then Ok None
  else
    let* () = require_private ~operation dir in
    (* A6: setup writes the home whole, so a directory missing any required
       file is tampering or a torn copy — refused whole, never partially
       served. *)
    let* () =
      List.fold_left
        (fun acc name ->
          let* () = acc in
          let path = Filename.concat dir name in
          if Sys.file_exists path then require_private ~operation path
          else
            error ~operation ~path
              "the credential home is incomplete; re-run `mentatd github \
               setup` (setup writes it atomically, so this indicates \
               tampering or a torn copy)")
        (Ok ())
        [ app_json_name; key_name; webhook_secret_name; ingress_id_name ]
    in
    let* () =
      let path = Filename.concat dir public_url_name in
      if Sys.file_exists path then require_private ~operation path else Ok ()
    in
    let json_path = Filename.concat dir app_json_name in
    let* bytes = read_required ~operation json_path in
    let* app =
      Result.map_error
        (fun reason -> { Error.operation; path = json_path; reason })
        (decode_app ~dir bytes)
    in
    Ok (Some app)

let posting_login t = t.slug ^ "[bot]"
let install_url t = t.html_url ^ "/installations/new"

let read_key_pem t =
  let operation = "github app key read" in
  let path = Filename.concat t.dir key_name in
  let* () = require_private ~operation path in
  read_required ~operation path

let webhook_secret t =
  read_trimmed ~operation:"github app secret read"
    (Filename.concat t.dir webhook_secret_name)

let ingress_id t =
  read_trimmed ~operation:"github app ingress read"
    (Filename.concat t.dir ingress_id_name)

let public_url t =
  let operation = "github app url read" in
  let path = Filename.concat t.dir public_url_name in
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Ok None -> Ok None
  | Error reason -> error ~operation ~path (strip_path ~path reason)
  | Ok (Some bytes) -> (
      match String.trim bytes with
      | "" -> error ~operation ~path "file is empty"
      | url -> Ok (Some url))

(* A6: conversion or nothing. The home is staged complete in a sibling
   temporary directory and renamed into place; an existing home is moved
   aside first and removed after, so no observer ever reads a half-written
   mixture of old and new. *)
let write dirs ~app ~key_pem ~webhook_secret ~ingress_id ~public_url =
  let operation = "github app write" in
  let final = User_dirs.github_app_dir dirs in
  let* () =
    match Fs.mkdir_p (User_dirs.config_home dirs) with
    | Ok () -> Ok ()
    | Error reason ->
        error ~operation
          ~path:(User_dirs.config_home dirs)
          (strip_path ~path:(User_dirs.config_home dirs) reason)
  in
  let staging = Printf.sprintf "%s.tmp-%d" final (Unix.getpid ()) in
  Fs.remove_tree staging;
  let* () =
    match Fs.mkdir_p staging with
    | Ok () -> Ok ()
    | Error reason -> error ~operation ~path:staging (strip_path ~path:staging reason)
  in
  let app = { app with dir = final } in
  let stage name bytes =
    let path = Filename.concat staging name in
    match Fs.atomic_write ~perms:0o600 path bytes with
    | Ok () -> Ok ()
    | Error reason -> error ~operation ~path (strip_path ~path reason)
  in
  let staged =
    let* () = stage app_json_name (encode_app app) in
    let* () = stage key_name key_pem in
    let* () = stage webhook_secret_name (webhook_secret ^ "\n") in
    let* () = stage ingress_id_name (ingress_id ^ "\n") in
    let* () =
      match public_url with
      | None -> Ok ()
      | Some url -> stage public_url_name (url ^ "\n")
    in
    let displaced = Printf.sprintf "%s.old-%d" final (Unix.getpid ()) in
    Fs.remove_tree displaced;
    let* had_old =
      if Sys.file_exists final then
        match Unix.rename final displaced with
        | () -> Ok true
        | exception Unix.Unix_error (e, _, _) ->
            error ~operation ~path:final (Unix.error_message e)
      else Ok false
    in
    match Unix.rename staging final with
    | () ->
        if had_old then Fs.remove_tree displaced;
        Ok app
    | exception Unix.Unix_error (e, _, _) ->
        (* Restore the displaced home so a failed replace never leaves the
           owner with nothing. *)
        (if had_old then
           match Unix.rename displaced final with
           | () -> ()
           | exception Unix.Unix_error _ -> ());
        error ~operation ~path:final (Unix.error_message e)
  in
  (match staged with Ok _ -> () | Error _ -> Fs.remove_tree staging);
  staged

let rotate_webhook_secret t =
  let operation = "github app secret rotate" in
  let path = Filename.concat t.dir webhook_secret_name in
  let fresh = fresh_webhook_secret () in
  match Fs.atomic_write ~perms:0o600 path (fresh ^ "\n") with
  | Ok () -> Ok fresh
  | Error reason -> error ~operation ~path (strip_path ~path reason)

let write_public_url t url =
  let operation = "github app url write" in
  let path = Filename.concat t.dir public_url_name in
  match Fs.atomic_write ~perms:0o600 path (url ^ "\n") with
  | Ok () -> Ok ()
  | Error reason -> error ~operation ~path (strip_path ~path reason)
