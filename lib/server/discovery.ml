(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  socket : string;
  pid : int;
  protocol : int;
  binary : string;
  config_home : string;
  started_at : int;
  web_url : string option;
  ingress : string option;
}

(* The file-format version, distinct from the [protocol] member (the wire
   version). An unknown [v] is treated as foreign, never mis-read. *)
let file_version = 1

let jsont =
  Jsont.Object.map ~kind:"daemon discovery"
    (fun v socket pid protocol binary config_home started_at web_url ingress ->
      if not (Int.equal v file_version) then
        Jsont.Error.msg Jsont.Meta.none
          (Printf.sprintf "unsupported discovery file version %d (expected %d)"
             v file_version);
      { socket; pid; protocol; binary; config_home; started_at; web_url; ingress })
  |> Jsont.Object.mem "v" Jsont.int ~enc:(fun _ -> file_version)
  |> Jsont.Object.mem "socket" Jsont.string ~enc:(fun t -> t.socket)
  |> Jsont.Object.mem "pid" Jsont.int ~enc:(fun t -> t.pid)
  |> Jsont.Object.mem "protocol" Jsont.int ~enc:(fun t -> t.protocol)
  |> Jsont.Object.mem "binary" Jsont.string ~enc:(fun t -> t.binary)
  |> Jsont.Object.mem "config_home" Jsont.string ~enc:(fun t -> t.config_home)
  |> Jsont.Object.mem "started_at" Jsont.int ~enc:(fun t -> t.started_at)
  (* Optional and additive: the browser-frontend URL (with its single-use
     bootstrap token) when the daemon runs [--web], absent otherwise. A reader
     that does not know the field is the same binary that wrote it (the identity
     gate), so no [v] bump is owed. *)
  |> Jsont.Object.opt_mem "web_url" Jsont.string ~enc:(fun t -> t.web_url)
  (* Optional and additive for the same reason: the webhook ingress
     listener's bound loopback address, when the daemon runs one. *)
  |> Jsont.Object.opt_mem "ingress" Jsont.string ~enc:(fun t -> t.ingress)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let daemon_json = "daemon.json"
let write_counter = ref 0

let write ~dir t =
  let dir_s = Lpath.Abs.to_string dir in
  try
    (* The daemon binary's hardened [ensure_private_dir] is the perm authority;
       here we only ensure the directory exists before the atomic write. *)
    (try Unix.mkdir dir_s 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let text =
      match Jsont_bytesrw.encode_string jsont t with
      | Ok s -> s ^ "\n"
      | Error message -> failwith message
    in
    incr write_counter;
    let tmp =
      Filename.concat dir_s
        (Printf.sprintf ".daemon.json.%d.%d.tmp" (Unix.getpid ()) !write_counter)
    in
    let fd =
      Unix.openfile tmp
        [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY; Unix.O_CLOEXEC ]
        0o600
    in
    Fun.protect
      ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
      (fun () ->
        let bytes = Bytes.of_string text in
        let written = Unix.write fd bytes 0 (Bytes.length bytes) in
        if written <> Bytes.length bytes then failwith "short write");
    (try Unix.rename tmp (Filename.concat dir_s daemon_json)
     with exn ->
       (try Unix.unlink tmp with Unix.Unix_error _ -> ());
       raise exn);
    Ok ()
  with
  | Failure message -> Error message
  | Unix.Unix_error (error, fn, _) ->
      Error (Printf.sprintf "%s: %s" fn (Unix.error_message error))

let read ~dir =
  let path = Filename.concat (Lpath.Abs.to_string dir) daemon_json in
  if not (Sys.file_exists path) then `Absent
  else
    match In_channel.with_open_bin path In_channel.input_all with
    | text -> (
        match Jsont_bytesrw.decode_string jsont text with
        | Ok t -> `Found t
        | Error message -> `Foreign message)
    | exception Sys_error message -> `Foreign message

module Claim = struct
  type guard = { fd : Unix.file_descr; path : string }

  (* The in-process claimed-set: a second [try_acquire] in this process is
     [`Held], so same-process contention is honest even before the kernel lock
     (the run-lock registry idiom). *)
  let held : (string, unit) Hashtbl.t = Hashtbl.create 8

  let try_acquire ~dir =
    let path = Filename.concat (Lpath.Abs.to_string dir) "daemon.lock" in
    if Hashtbl.mem held path then Error `Held
    else
      match
        Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600
      with
      | exception Unix.Unix_error (error, fn, _) ->
          Error (`Io (Printf.sprintf "%s: %s" fn (Unix.error_message error)))
      | fd -> (
          match Unix.lockf fd Unix.F_TLOCK 0 with
          | () ->
              Hashtbl.replace held path ();
              Ok { fd; path }
          | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
              (try Unix.close fd with Unix.Unix_error _ -> ());
              Error `Held
          | exception Unix.Unix_error (error, fn, _) ->
              (try Unix.close fd with Unix.Unix_error _ -> ());
              Error
                (`Io (Printf.sprintf "%s: %s" fn (Unix.error_message error))))

  let release guard =
    Hashtbl.remove held guard.path;
    (try Unix.lockf guard.fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
    try Unix.close guard.fd with Unix.Unix_error _ -> ()
end

let clear ~dir ~pid =
  match read ~dir with
  | `Found t when Int.equal t.pid pid -> (
      try Unix.unlink (Filename.concat (Lpath.Abs.to_string dir) daemon_json)
      with Unix.Unix_error _ -> ())
  | `Found _ | `Absent | `Foreign _ -> ()

