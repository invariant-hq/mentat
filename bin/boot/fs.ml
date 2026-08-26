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

(* Cross-process serialization on [fd]. [F_TLOCK] never parks the domain, so
   the only wait is the cancellable sleep between tries; a blocking [F_LOCK]
   in a systhread could not be interrupted by cancellation. The lock releases
   with the descriptor, so a crashed holder cannot wedge anything. *)
let acquire_lock ~path fd =
  let rec acquire backoff =
    match Unix.lockf fd Unix.F_TLOCK 0 with
    | () -> Ok ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> acquire backoff
    | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
        Eio_unix.sleep backoff;
        acquire (Float.min (backoff *. 2.) 0.1)
    | exception Unix.Unix_error (e, _, _) -> Error (render path e)
  in
  acquire 0.001

(* The ledger-append recipe, rewritten from the session store's over native
   [Unix]: repair any torn tail, write the framed record at the end, fsync the
   file, then the directory. *)

let rec read_retry fd buffer offset length =
  match Unix.read fd buffer offset length with
  | read -> read
  | exception Unix.Unix_error (Unix.EINTR, _, _) ->
      read_retry fd buffer offset length

(* Truncate a torn final fragment at the last record boundary and return the
   repaired size — the boundary a failed write restores. Scans backwards in
   chunks for the last ['\n']; a ledger holding none is truncated to empty. *)
let truncate_torn path fd =
  let size = (Unix.fstat fd).Unix.st_size in
  if size = 0 then 0
  else begin
    let chunk = 8192 in
    let buffer = Bytes.create chunk in
    let rec last_newline stop =
      if stop = 0 then None
      else begin
        let start = Stdlib.max 0 (stop - chunk) in
        let length = stop - start in
        let (_ : int) = Unix.lseek fd start Unix.SEEK_SET in
        let rec fill offset =
          if offset < length then
            match read_retry fd buffer offset (length - offset) with
            | 0 -> raise (Sys_error (path ^ ": short read"))
            | read -> fill (offset + read)
        in
        fill 0;
        let rec find index =
          if index < 0 then None
          else if Char.equal (Bytes.get buffer index) '\n' then
            Some (start + index)
          else find (index - 1)
        in
        match find (length - 1) with
        | Some absolute -> Some absolute
        | None -> last_newline start
      end
    in
    let keep =
      match last_newline size with None -> 0 | Some newline -> newline + 1
    in
    if keep <> size then Unix.ftruncate fd keep;
    keep
  end

let rec write_all fd text offset =
  if offset < String.length text then
    match Unix.write_substring fd text offset (String.length text - offset) with
    | 0 -> raise (Sys_error "no bytes written")
    | written -> write_all fd text (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd text offset

let rec fsync_retry fd =
  match Unix.fsync fd with
  | () -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> fsync_retry fd

(* The directory sync makes a first append's creation as durable as its bytes.
   It sits after the append landed, so a sync failure has changed durable
   state; the caller re-anchors from disk. *)
let fsync_dir dir =
  match Unix.openfile dir [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (e, _, _) -> Error (render dir e)
  | fd ->
      Fun.protect
        ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
        (fun () ->
          match fsync_retry fd with
          | () -> Ok ()
          | exception Unix.Unix_error (e, _, _) -> Error (render dir e))

(* Appenders are serialized at both levels — the per-path [Eio.Mutex] for
   fibers of this process (POSIX record locks are per-process and would not
   exclude them) and the ledger descriptor's advisory lock across
   processes — because the boundary repair reads the size before writing, so
   an unserialized second writer could truncate a record in flight. *)
let append path record =
  if String.contains record '\n' then
    Error (Printf.sprintf "%s: record must not contain a newline" path)
  else
    match mkdir_p (Filename.dirname path) with
    | Error _ as e -> e
    | Ok () -> (
        Eio.Mutex.use_ro (mutex_for path) @@ fun () ->
        match
          Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600
        with
        | exception Unix.Unix_error (e, _, _) -> Error (render path e)
        | fd -> (
            match
              Fun.protect
                ~finally:(fun () ->
                  try Unix.close fd with Unix.Unix_error _ -> ())
                (fun () ->
                  match acquire_lock ~path fd with
                  | Error _ as e -> e
                  | Ok () ->
                      let base = truncate_torn path fd in
                      let (_ : int) = Unix.lseek fd 0 Unix.SEEK_END in
                      (* Once the write begins, any failure restores the
                         pre-append boundary best-effort so a retry cannot
                         duplicate records. *)
                      (try
                         write_all fd (record ^ "\n") 0;
                         fsync_retry fd
                       with exn ->
                         (try Unix.ftruncate fd base
                          with Unix.Unix_error _ -> ());
                         raise exn);
                      Ok ())
            with
            | Ok () -> fsync_dir (Filename.dirname path)
            | Error _ as e -> e
            | exception Unix.Unix_error (e, _, _) -> Error (render path e)
            | exception Sys_error message -> Error message))

let require_private path =
  match Unix.stat path with
  | exception Unix.Unix_error (e, _, _) -> Error (render path e)
  | stat ->
      if stat.Unix.st_perm land 0o077 = 0 then Ok ()
      else
        Error
          (Printf.sprintf
             "%s: mode %03o grants group or world access; make it private \
              (chmod go-rwx)"
             path stat.Unix.st_perm)

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
              match acquire_lock ~path:lock_path fd with
              | Error _ as e -> e
              | Ok () ->
                  Fun.protect
                    ~finally:(fun () ->
                      try ignore (Unix.lockf fd Unix.F_ULOCK 0)
                      with Unix.Unix_error _ -> ())
                    f))
