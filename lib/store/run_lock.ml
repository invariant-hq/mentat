(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = Import.invalid_arg' "Mentat_store.Run_lock" fn message

module Owner = Owner

(* The custodial label a session removal holds the fence under while it
   deletes the session's tree. Spelled once and exported: an observer that
   classifies fence owners must read this hold as a transient that releases
   on its own, and a drifted copy would silently demote it to an untouchable
   foreign driver. *)
let remove_owner_label = "remove"

type guard = Handle.guard
type acquire_error = [ `Held of Owner.t option | `Io of Io.t ]

let session (guard : guard) = guard.Handle.session
let owner (guard : guard) = guard.Handle.owner

(* Close before removing the reservation: while the descriptor is open, a
   same-process contender turned away by the reservation must never open a second
   descriptor to the locked inode ([F_TLOCK] would succeed within one process and
   closing that descriptor would drop the fence). The check-and-set makes release
   exactly-once: two racing releases must never both close the descriptor. *)
let release (guard : guard) =
  if Atomic.compare_and_set guard.Handle.released false true then begin
    Eio_unix.Fd.close guard.Handle.fd;
    Handle.Registry.cancel guard.Handle.root_registry guard.Handle.key
      guard.Handle.token
  end

let owner_line owner =
  match Jsont_bytesrw.encode_string Owner.jsont owner with
  | Ok text -> text ^ "\n"
  | Error message -> invalid "try_acquire" ("owner does not encode: " ^ message)

(* Best-effort holder display from the descriptor this process already has open;
   a torn or undecodable line is [None] — the exclusion never depends on it. *)
let read_holder fd =
  match
    let (_ : int) = Unix.lseek fd 0 Unix.SEEK_SET in
    let buffer = Bytes.create 4096 in
    let length = Unix.read fd buffer 0 (Bytes.length buffer) in
    Bytes.sub_string buffer 0 length
  with
  | exception Unix.Unix_error _ -> None
  | text -> (
      match String.index_opt text '\n' with
      | None -> None
      | Some newline -> (
          match
            Jsont_bytesrw.decode_string Owner.jsont (String.sub text 0 newline)
          with
          | Ok owner -> Some owner
          | Error _ -> None))

(* The registry admits the probe before any descriptor opens: the OS probe
   below cannot see same-process locks (POSIX record locks never conflict
   within one process), and a probe descriptor opened onto an inode this
   process holds locked would drop the lock at close. [Registry.probe] makes
   the premise true by construction, not merely at the moment of a check: an
   existing reservation answers [`Held] with no descriptor touched, and while
   the probe descriptor is open no same-process acquisition is admitted — an
   acquire racing the probe sees a transient [`Held] instead of landing a
   fence the probe's close would silently drop. [F_TEST] then observes
   other-process locks only — exactly the cross-process contract. *)
let holder root ~session =
  let registry = Handle.registry root in
  let key = Mentat_session.Id.to_string session in
  let path = Layout.run_lock session in
  let cap = Handle.path root path in
  let probe () =
    Eio.Path.with_open_in cap @@ fun resource ->
    Eio_unix.Fd.use_exn "run-lock holder" (Disk.fd_of resource)
      (fun ufd ->
        let rec test () =
          match Unix.lockf ufd Unix.F_TEST 0 with
          | () -> `Free
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> test ()
          | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
              `Held (read_holder ufd)
          | exception Unix.Unix_error (code, _, _) ->
              `Io
                {
                  Io.op = Io.Lock;
                  path;
                  cause = Io.Message (Unix.error_message code);
                }
        in
        test ())
  in
  let contained () =
    match probe () with
    | outcome -> outcome
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> `Free
    | exception exn -> (
        try Disk.raise_io ~op:Io.Open ~path exn
        with Disk.Io_error payload -> `Io payload)
  in
  match Handle.Registry.probe registry key contained with
  | Error owner -> `Held (Some owner)
  | Ok outcome -> outcome

let try_acquire ~sw root ~session ~owner =
  let registry = Handle.registry root in
  let key = Mentat_session.Id.to_string session in
  (* Reserve before open: at most one same-process contender ever reaches the
     descriptor, so no two descriptors to a candidate run.lock exist in this
     process. A fence probe in flight also turns the reservation away —
     [`Held None], transient for the probe descriptor's lifetime — because a
     lock taken while the probe's descriptor is open would be dropped at its
     close. *)
  match Handle.Registry.try_reserve registry key owner with
  | Error (`Reserved holder) -> Error (`Held (Some holder))
  | Error `Probing -> Error (`Held None)
  | Ok token -> (
      let path = Layout.run_lock session in
      let cap = Handle.path root path in
      let cancel () = Handle.Registry.cancel registry key token in
      match Eio.Path.open_out ~sw ~create:(`If_missing 0o600) cap with
      | exception (Eio.Cancel.Cancelled _ as exn) ->
          cancel ();
          raise exn
      | exception exn -> (
          cancel ();
          try Disk.raise_io ~op:Io.Open ~path exn
          with Disk.Io_error payload -> Error (`Io payload))
      | resource -> (
          let fd = Disk.fd_of resource in
          let abandon () =
            Eio_unix.Fd.close fd;
            cancel ()
          in
          (* The lock, holder read, and owner-line write all borrow the raw
             descriptor once. [F_TLOCK] is non-blocking, so this never parks the
             domain, and the short post-acquisition write runs under cancellation
             protection while the lock poll itself does not. *)
          let outcome =
            Eio_unix.Fd.use_exn "run-lock acquire" fd (fun ufd ->
                let rec tlock () =
                  match Unix.lockf ufd Unix.F_TLOCK 0 with
                  | () -> `Locked
                  | exception Unix.Unix_error (Unix.EINTR, _, _) -> tlock ()
                  | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _)
                    ->
                      `Held
                  | exception Unix.Unix_error (code, _, _) ->
                      `Error (Unix.error_message code)
                in
                match tlock () with
                | `Held -> `Held (read_holder ufd)
                | `Error message -> `Error message
                | `Locked ->
                    Eio.Cancel.protect (fun () ->
                        match
                          Unix.ftruncate ufd 0;
                          Disk.write_all ~path ufd (owner_line owner)
                        with
                        | () -> `Written
                        | exception Disk.Io_error payload ->
                            `Write_failed payload
                        | exception Unix.Unix_error (code, _, _) ->
                            `Write_failed
                              {
                                Io.op = Io.Write;
                                path;
                                cause = Io.Unix_error code;
                              }))
          in
          match outcome with
          | `Held holder ->
              abandon ();
              Error (`Held holder)
          | `Error message ->
              abandon ();
              Error (`Io { Io.op = Io.Lock; path; cause = Io.Message message })
          | `Write_failed payload ->
              abandon ();
              Error (`Io payload)
          | `Written -> (
              Handle.Registry.confirm registry token;
              let guard =
                {
                  Handle.session;
                  owner;
                  fd;
                  root_registry = registry;
                  key;
                  token;
                  anchor = ref None;
                  released = Atomic.make false;
                }
              in
              match Eio.Switch.on_release sw (fun () -> release guard) with
              | () -> Ok guard
              | exception exn ->
                  (* The switch is already finished: undo the acquisition rather
                     than leak the fence. *)
                  release guard;
                  raise exn)))
