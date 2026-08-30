(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

exception Io_error of Io.t

let src = Logs.Src.create "mentat.store" ~doc:"Store disk primitives"

module Log = (val Logs.src_log src : Logs.LOG)

(* An [Io.Message] must hold one line: every error surface lowers it through
   [Mentat_diagnostic.make], whose message contract is single-line, and the
   pretty-printed exception renderings below may wrap. *)
let one_line s = String.map (function '\n' | '\r' -> ' ' | c -> c) s

let cause_of_exn = function
  | Unix.Unix_error (code, _, _) -> Io.Unix_error code
  | Eio.Io _ as exn ->
      Io.Message (one_line (Format.asprintf "%a" Eio.Exn.pp exn))
  | exn -> Io.Message (one_line (Printexc.to_string exn))

(* The raise context of the most recent exception converted to a fact. The
   typed fact keeps the message; the trace is a diagnostic, and it exists only
   here, at the catch — logging can be disabled (the CLI default), so a crash
   report written after the fact still needs somewhere to read it from. *)
let last_diagnostic = Atomic.make None
let last_exn_diagnostic () = Atomic.get last_diagnostic

let observe ~what ~path exn =
  let diagnostic =
    Printf.sprintf "%s %s: %s\n%s" what path (Printexc.to_string exn)
      (Printexc.get_backtrace ())
  in
  Atomic.set last_diagnostic (Some diagnostic);
  Log.err (fun m -> m "%s" diagnostic)

let raise_io ~op ~path exn =
  match exn with
  | Eio.Cancel.Cancelled _ | Io_error _ -> raise exn
  | exn ->
      observe ~what:(Io.op_label op) ~path exn;
      raise (Io_error { Io.op; path; cause = cause_of_exn exn })

(* Neutral IO guards over the primitives below: each store domain injects its
   own [Io] error arm with [Result.map_error]. *)

let guard ~op ~path f =
  match f () with
  | value -> Ok value
  | exception Io_error payload -> Error payload
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
      observe ~what:(Io.op_label op) ~path exn;
      Error
        { Io.op; path; cause = Io.Message (one_line (Printexc.to_string exn)) }

let path_kind ~path cap =
  match Eio.Path.kind ~follow:true cap with
  | `Not_found -> Ok `Missing
  | `Regular_file -> Ok `File
  | `Directory -> Ok `Directory
  | _ -> Ok `Other
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
      Error
        {
          Io.op = Io.Read;
          path;
          cause = Io.Message (one_line (Printexc.to_string exn));
        }

(* Percent-escaped path components. *)

let hex = "0123456789ABCDEF"

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let escaped_component text =
  let buffer = Buffer.create (String.length text) in
  String.iter
    (fun c ->
      if is_unreserved c then Buffer.add_char buffer c
      else
        let code = Char.code c in
        Buffer.add_char buffer '%';
        Buffer.add_char buffer hex.[code lsr 4];
        Buffer.add_char buffer hex.[code land 0x0f])
    text;
  Buffer.contents buffer

let hex_value c =
  if Char.Ascii.is_hex_digit c then Some (Char.Ascii.hex_digit_to_int c)
  else None

let unescaped_component name =
  let len = String.length name in
  let buffer = Buffer.create len in
  let rec loop index =
    if index >= len then Some (Buffer.contents buffer)
    else
      match name.[index] with
      | '%' when index + 2 < len -> (
          match (hex_value name.[index + 1], hex_value name.[index + 2]) with
          | Some high, Some low ->
              Buffer.add_char buffer (Char.chr ((high lsl 4) lor low));
              loop (index + 3)
          | _ -> None)
      | '%' -> None
      | c ->
          Buffer.add_char buffer c;
          loop (index + 1)
  in
  loop 0

(* Descriptor-level primitives, callable from a systhread against the raw
   [Unix.file_descr] a capability's {!Eio_unix.Fd.t} lends. *)

let rec fsync_fd ~path fd =
  match Unix.fsync fd with
  | () -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> fsync_fd ~path fd
  | exception exn -> raise_io ~op:Io.Sync ~path exn

(* Whether a write's failure changed the caller's target depends on the caller's
   seam — a temporary file's write leaves the target untouched until the
   following rename, a ledger append writes the target in place. A caller that
   requires coherence past its own linearization point reloads. *)
let rec write_at fd ~path text offset =
  if offset < String.length text then
    match Unix.write_substring fd text offset (String.length text - offset) with
    | 0 ->
        raise
          (Io_error
             { Io.op = Io.Write; path; cause = Io.Message "no bytes written" })
    | written -> write_at fd ~path text (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        write_at fd ~path text offset
    | exception exn -> raise_io ~op:Io.Write ~path exn

let write_all ~path fd text = write_at fd ~path text 0

(* Capability-level primitives. Every operation goes through the opened-root
   directory capability ([openat]-based), never a native path string: a native
   path resolves through the filesystem namespace and can name a different tree
   after a rename, splitting one logical op across two physical trees. The
   capability names the inode. *)

let fd_of resource =
  match Eio_unix.Resource.fd_opt resource with
  | Some fd -> fd
  | None -> invalid_arg "Mentat_store.Disk: opened capability has no fd"

let fsync_dir ~path dir =
  Eio.Switch.run @@ fun sw ->
  (* [dir / "."], never the bare capability: an opened directory's relative
     path is empty, and openat2 rejects an empty path with ENOENT (the
     io_uring backend); "." names the directory on every backend. *)
  let resource =
    match Eio.Path.open_in ~sw (Eio.Path.( / ) dir ".") with
    | resource -> resource
    | exception exn -> raise_io ~op:Io.Open ~path exn
  in
  Eio_unix.Fd.use_exn "store dir sync" (fd_of resource) (fun ufd ->
      Eio_unix.run_in_systhread ~label:"store dir sync" (fun () ->
          fsync_fd ~path ufd))

let mkdir ~path dir =
  match Eio.Path.mkdir ~perm:0o700 dir with
  | () -> true
  | exception Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) -> false
  | exception exn -> raise_io ~op:Io.Write ~path exn

(* Locking. *)

let with_flock ~path lock f =
  Eio.Switch.run @@ fun sw ->
  let resource =
    match Eio.Path.open_out ~sw ~create:(`If_missing 0o600) lock with
    | resource -> resource
    | exception exn -> raise_io ~op:Io.Open ~path exn
  in
  Eio_unix.Fd.use_exn "store flock" (fd_of resource) (fun fd ->
      (* Acquire the cross-process advisory lock without an uncancellable
         wait. [F_TLOCK] is non-blocking, so the [lockf] itself never parks the
         domain: the sleep between tries is the only wait, and it is an Eio
         cancellation point. A blocked [F_LOCK] would ignore cancellation until
         the peer released the lock. *)
      let rec acquire backoff =
        match Unix.lockf fd Unix.F_TLOCK 0 with
        | () -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> acquire backoff
        | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
            Eio_unix.sleep backoff;
            acquire (Float.min (backoff *. 2.) 0.1)
        | exception exn -> raise_io ~op:Io.Lock ~path exn
      in
      acquire 0.001;
      let unlock () =
        let rec go () =
          match Unix.lockf fd Unix.F_ULOCK 0 with
          | () -> ()
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
          (* Closing the descriptor drops the lock regardless. *)
          | exception Unix.Unix_error _ -> ()
        in
        go ()
      in
      Fun.protect ~finally:unlock f)

(* Durable replace. *)

let tmp_counter = Atomic.make 0

let tmp_name name =
  let count = Atomic.fetch_and_add tmp_counter 1 + 1 in
  Printf.sprintf "%s.tmp.%d.%d" name (Unix.getpid ()) count

let replace ~dir ~dir_path ~name contents =
  Eio.Switch.run @@ fun sw ->
  let tmp = tmp_name name in
  let tmp_cap = Eio.Path.( / ) dir tmp in
  let tmp_path = dir_path ^ "/" ^ tmp in
  let target_cap = Eio.Path.( / ) dir name in
  let target_path = dir_path ^ "/" ^ name in
  let renamed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !renamed then
        try Eio.Path.unlink ~missing_ok:true tmp_cap with _ -> ())
    (fun () ->
      let resource =
        match Eio.Path.open_out ~sw ~create:(`Exclusive 0o600) tmp_cap with
        | resource -> resource
        | exception exn -> raise_io ~op:Io.Open ~path:tmp_path exn
      in
      Eio_unix.Fd.use_exn "store durable replace" (fd_of resource) (fun fd ->
          Eio_unix.run_in_systhread ~label:"store durable replace" (fun () ->
              write_all ~path:tmp_path fd contents;
              fsync_fd ~path:tmp_path fd));
      (match Eio.Path.rename tmp_cap target_cap with
      | () -> ()
      | exception exn -> raise_io ~op:Io.Rename ~path:target_path exn);
      renamed := true;
      (* After the rename the new bytes are published: a directory-sync failure
         now leaves durable state changed, so a caller that requires coherence
         reloads. The tmp write and fsync above precede the rename. *)
      fsync_dir ~path:dir_path dir)

(* Ledger append with torn-tail repair. *)

(* Truncate a torn final fragment at the last record boundary and return the
   repaired size. Scans backwards in chunks for the last [\n]; a log with none
   is truncated to empty. *)
let truncate_torn ~path fd =
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
            match Unix.read fd buffer offset (length - offset) with
            | 0 ->
                raise
                  (Io_error
                     { Io.op = Io.Read; path; cause = Io.Message "short read" })
            | read -> fill (offset + read)
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
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

let append ~ledger ~ledger_path ~dir ~dir_path lines =
  Eio.Switch.run @@ fun sw ->
  let resource =
    match Eio.Path.open_out ~sw ~create:(`If_missing 0o600) ledger with
    | resource -> resource
    | exception exn -> raise_io ~op:Io.Open ~path:ledger_path exn
  in
  Eio_unix.Fd.use_exn "store ledger append" (fd_of resource) (fun fd ->
      Eio_unix.run_in_systhread ~label:"store ledger append" (fun () ->
          let base =
            try truncate_torn ~path:ledger_path fd
            with exn -> raise_io ~op:Io.Write ~path:ledger_path exn
          in
          (match Unix.lseek fd 0 Unix.SEEK_END with
          | (_ : int) -> ()
          | exception exn -> raise_io ~op:Io.Read ~path:ledger_path exn);
          (* Once the write begins, any failure restores the pre-append
             boundary best-effort so a retry cannot duplicate events; the
             on-disk tail is nonetheless unknown, so the caller re-anchors from
             disk. *)
          try
            write_all ~path:ledger_path fd lines;
            fsync_fd ~path:ledger_path fd
          with exn ->
            (try Unix.ftruncate fd base with Unix.Unix_error _ -> ());
            raise exn));
  (* The directory sync sits inside the linearization window: the append landed,
     so a sync failure has changed durable state. *)
  fsync_dir ~path:dir_path dir
