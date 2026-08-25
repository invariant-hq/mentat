(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let default_max_bytes = 1 lsl 20
let render path e = Printf.sprintf "%s: %s" path (Unix.error_message e)

let mkdir_p path =
  let rec go dir =
    if Sys.file_exists dir then Ok ()
    else
      match go (Filename.dirname dir) with
      | Error _ as e -> e
      | Ok () -> (
          match Unix.mkdir dir 0o700 with
          | () -> Ok ()
          | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
          | exception Unix.Unix_error (e, _, _) -> Error (render dir e))
  in
  go path

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      (match Sys.readdir path with
      | entries ->
          Array.iter
            (fun entry -> remove_tree (Filename.concat path entry))
            entries
      | exception Sys_error _ -> ());
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> ( try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()

let read_capped ~max_bytes path =
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (e, _, _) -> Error (render path e)
  | stat -> (
      if stat.Unix.st_size > max_bytes then
        Error (Printf.sprintf "%s: file exceeds %d bytes" path max_bytes)
      else
        try Ok (Some (In_channel.with_open_bin path In_channel.input_all))
        with Sys_error message -> Error message)

let atomic_write ~perms path bytes =
  match mkdir_p (Filename.dirname path) with
  | Error _ as e -> e
  | Ok () -> (
      let tmp = path ^ ".tmp" in
      try
        let oc =
          open_out_gen [ Open_wronly; Open_creat; Open_trunc ] perms tmp
        in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () -> output_string oc bytes);
        (* [open_out_gen] applies the umask; force the requested mode so a
           [0o600] file is [0o600] regardless of the user's umask. *)
        (try Unix.chmod tmp perms with Unix.Unix_error _ -> ());
        Sys.rename tmp path;
        Ok ()
      with
      | Sys_error message ->
          (try Sys.remove tmp with Sys_error _ -> ());
          Error message
      | Unix.Unix_error (e, _, _) ->
          (try Sys.remove tmp with Sys_error _ -> ());
          Error (render path e))

let write_new ~perms path bytes =
  match mkdir_p (Filename.dirname path) with
  | Error _ as e -> e
  | Ok () -> (
      match
        Unix.openfile path
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
          perms
      with
      | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Ok `Exists
      | exception Unix.Unix_error (e, _, _) -> Error (render path e)
      | fd -> (
          let oc = Unix.out_channel_of_descr fd in
          match
            Fun.protect
              ~finally:(fun () -> close_out_noerr oc)
              (fun () -> output_string oc bytes);
            (* [openfile] applies the umask; force the requested mode. *)
            try Unix.chmod path perms with Unix.Unix_error _ -> ()
          with
          | () -> Ok `Written
          | exception Sys_error message ->
              (try Sys.remove path with Sys_error _ -> ());
              Error message))

(* In-process serialization: one [Eio.Mutex] per lock path, keyed through a
   registry the store's [Handle] pattern uses. The registry itself is guarded by
   a stdlib mutex so the find-or-create is atomic. *)
let registry_guard = Mutex.create ()
let registry : (string, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 8

let mutex_for lock_path =
  Mutex.protect registry_guard (fun () ->
      match Hashtbl.find_opt registry lock_path with
      | Some mutex -> mutex
      | None ->
          let mutex = Eio.Mutex.create () in
          Hashtbl.add registry lock_path mutex;
          mutex)

let with_lock lock_path f =
  match mkdir_p (Filename.dirname lock_path) with
  | Error _ as e -> e
  | Ok () -> (
      Eio.Mutex.use_ro (mutex_for lock_path) @@ fun () ->
      match
        Unix.openfile lock_path
          [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
          0o600
      with
      | exception Unix.Unix_error (e, _, _) -> Error (render lock_path e)
      | fd ->
          Fun.protect
            ~finally:(fun () ->
              try Unix.close fd with Unix.Unix_error _ -> ())
            (fun () ->
              (* [F_TLOCK] never parks the domain, so the only wait is the
                 cancellable sleep between tries; a blocking [F_LOCK] in a
                 systhread could not be interrupted by cancellation. *)
              let rec acquire backoff =
                match Unix.lockf fd Unix.F_TLOCK 0 with
                | () -> Ok ()
                | exception Unix.Unix_error (Unix.EINTR, _, _) ->
                    acquire backoff
                | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _)
                  ->
                    Eio_unix.sleep backoff;
                    acquire (Float.min (backoff *. 2.) 0.1)
                | exception Unix.Unix_error (e, _, _) ->
                    Error (render lock_path e)
              in
              match acquire 0.001 with
              | Error _ as e -> e
              | Ok () ->
                  Fun.protect
                    ~finally:(fun () ->
                      try ignore (Unix.lockf fd Unix.F_ULOCK 0)
                      with Unix.Unix_error _ -> ())
                    f))
