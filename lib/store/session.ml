(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

let invalid fn message = Import.invalid_arg' "Mentat_store.Session" fn message

module Document = struct
  type t = { session : Mentat_session.t; revision : Mentat_digest.t }

  let make ~session ~revision = { session; revision }
  let id t = Mentat_session.id t.session
  let session t = t.session
  let revision t = t.revision
end

module Corrupt = struct
  type t = { id : Mentat_session.Id.t option; path : string; message : string }

  let make ?id ~path ~message () = { id; path; message }
  let id t = t.id
  let path t = t.path
  let message t = t.message

  let diagnostic t =
    let subject =
      match t.id with
      | None -> "session document is invalid"
      | Some id ->
          Format.asprintf "session %a is invalid" Mentat_session.Id.pp id
    in
    Mentat_diagnostic.make ~context:(t.path ^ "\n" ^ t.message) subject
end

module Error = struct
  type t =
    | Not_found of Mentat_session.Id.t
    | Already_exists of Mentat_session.Id.t
    | Conflict of {
        id : Mentat_session.Id.t;
        expected : Mentat_digest.t;
        actual : Mentat_digest.t;
      }
    | Locked of { id : Mentat_session.Id.t; holder : Owner.t option }
    | Corrupt of Corrupt.t
    | Io of Io.t

  let message (error : t) =
    match error with
    | Not_found id ->
        Format.asprintf "session not found: %a" Mentat_session.Id.pp id
    | Already_exists id ->
        Format.asprintf "session already exists: %a" Mentat_session.Id.pp id
    | Conflict { id; expected; actual } ->
        Format.asprintf
          "session conflict for %a: expected revision %a but found %a"
          Mentat_session.Id.pp id Mentat_digest.pp expected Mentat_digest.pp
          actual
    | Locked { id; holder } ->
        let who =
          match holder with
          | None -> "another driver"
          | Some owner -> Format.asprintf "%a" Owner.pp owner
        in
        Format.asprintf "session %a is held by %s" Mentat_session.Id.pp id who
    | Corrupt fact -> Corrupt.path fact ^ ": " ^ Corrupt.message fact
    | Io io -> Io.message io

  let pp ppf t = Format.pp_print_string ppf (message t)

  let diagnostic = function
    | Corrupt fact -> Corrupt.diagnostic fact
    | error -> Mentat_diagnostic.make (message error)
end

let io ~op ~path f =
  Result.map_error (fun payload -> Error.Io payload) (Disk.guard ~op ~path f)

let path_kind t rel =
  Result.map_error
    (fun payload -> Error.Io payload)
    (Disk.path_kind ~path:rel (Handle.path t rel))

let non_file_document ?id path =
  Error
    (Error.Corrupt (Corrupt.make ?id ~path ~message:"is not a regular file" ()))

(* Writers for one session serialize across fibers on the registry's keyed mutex
   and across processes on the sibling advisory lock, so the CAS comparison below
   never races a same-session writer. *)
let locked t id f =
  match Session_lock.with_ t id f with
  | result -> result
  | exception Disk.Io_error payload -> Error (Error.Io payload)

let encode_document session =
  match Jsont_bytesrw.encode_string Mentat_session.jsont session with
  | Ok text -> text ^ "\n"
  | Error message -> invalid "encode" ("session does not encode: " ^ message)

let load_bytes t rel =
  io ~op:Io.Read ~path:rel (fun () -> Eio.Path.load (Handle.path t rel))

let decode_document ?id path text =
  match Jsont_bytesrw.decode_string Mentat_session.jsont text with
  | Ok session ->
      Ok (Document.make ~session ~revision:(Mentat_digest.string text))
  | Error message -> Error (Error.Corrupt (Corrupt.make ?id ~path ~message ()))

let load_document ?id t rel =
  let* text = load_bytes t rel in
  decode_document ?id rel text

let write_document t id text =
  let dir = Layout.session_dir id in
  io ~op:Io.Write ~path:(Layout.document id) (fun () ->
      Disk.replace ~dir:(Handle.path t dir) ~dir_path:dir ~name:"session.json"
        text)

let create_seeded t session ~seed =
  let id = Mentat_session.id session in
  locked t id (fun () ->
      let path = Layout.document id in
      match path_kind t path with
      | Error _ as error -> error
      | Ok `File -> Error (Error.Already_exists id)
      | Ok (`Directory | `Other) -> non_file_document ~id path
      | Ok `Missing ->
          let text = encode_document session in
          let dir = Layout.session_dir id in
          let* () =
            match path_kind t dir with
            | Error _ as error -> error
            | Ok `Missing ->
                io ~op:Io.Write ~path:dir (fun () ->
                    let (_ : bool) = Disk.mkdir ~path:dir (Handle.path t dir) in
                    ())
            | Ok `Directory -> (
                (* A document-less directory that holds anything is damaged or
                   foreign state — a crashed remove's residue, an aborted import
                   — and adopting it would launder that state into a fresh
                   session. An empty directory is a crashed create's own residue
                   and is reused. This same check gates a branch's seed: a prior
                   branch that crashed after seeding but before its document
                   lands leaves the sibling ledger and blobs here, so the retry
                   refuses rather than laundering that partial residue. *)
                let* entries =
                  io ~op:Io.Read ~path:dir (fun () ->
                      Eio.Path.read_dir (Handle.path t dir))
                in
                match entries with
                | [] -> Ok ()
                | _ :: _ ->
                    Error
                      (Error.Corrupt
                         (Corrupt.make ~id ~path:dir
                            ~message:
                              "non-empty session directory has no session \
                               document"
                            ())))
            | Ok (`File | `Other) ->
                Error
                  (Error.Corrupt
                     (Corrupt.make ~id ~path:dir ~message:"is not a directory"
                        ()))
          in
          (* Unconditional: a [sessions/] entry inherited unsynced from a crashed
             predecessor becomes durable before the document lands. *)
          let* () =
            io ~op:Io.Sync ~path:Layout.sessions_dir (fun () ->
                Disk.fsync_dir ~path:Layout.sessions_dir
                  (Handle.path t Layout.sessions_dir))
          in
          (* The seed populates the session's sibling durable state (its mutation
             ledger and blobs) after the empty directory is ensured and before
             the document — the commit point that references those facts — is
             written. A seed failure writes no document, so the session never
             exists holding a settlement whose fact is missing. *)
          let* () = seed () in
          let* () = write_document t id text in
          Ok (Document.make ~session ~revision:(Mentat_digest.string text)))

let create t session = create_seeded t session ~seed:(fun () -> Ok ())
let on_disk_dir t id = Handle.native t (Layout.session_dir id)

(* One stat, no read: every commit replaces the document onto a fresh inode,
   so the (device, inode, size, mtime) tuple changes with the bytes in
   practice. *)
let stamp t id =
  match
    Eio.Path.stat ~follow:true (Handle.path t (Layout.document id))
  with
  | stat ->
      Some
        (Printf.sprintf "%Lx-%Lx-%s-%h" stat.Eio.File.Stat.dev
           stat.Eio.File.Stat.ino
           (Optint.Int63.to_string stat.Eio.File.Stat.size)
           stat.Eio.File.Stat.mtime)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> None

let load t id =
  let path = Layout.document id in
  match path_kind t path with
  | Error _ as error -> error
  | Ok `Missing -> Error (Error.Not_found id)
  | Ok (`Directory | `Other) -> non_file_document ~id path
  | Ok `File ->
      let* document = load_document ~id t path in
      let actual = Mentat_session.id (Document.session document) in
      if Mentat_session.Id.equal id actual then Ok document
      else
        Error
          (Error.Corrupt
             (Corrupt.make ~id ~path
                ~message:
                  (Format.asprintf
                     "document id %a does not match requested id %a"
                     Mentat_session.Id.pp actual Mentat_session.Id.pp id)
                ()))

(* The CAS comparison needs only the byte identity of what is on disk, not a
   decode: equal digests mean the exact bytes the caller loaded are still
   current, and differing digests mean another writer landed — [Conflict] even
   if the replacement happens to be damaged. *)
let current_revision t id =
  let path = Layout.document id in
  let* text = load_bytes t path in
  Ok (Mentat_digest.string text)

(* Existing-session commit runs under the run fence: the fence for [id] is a
   typed precondition, so the coherence Export documents — no driver commits
   underneath a fenced capture — is enforced by the compiler, not prose. *)
let commit t ~fence document session =
  let id = Mentat_session.id session in
  if not (Mentat_session.Id.equal id (Document.id document)) then
    invalid "commit"
      (Format.asprintf "session id %a does not match document id %a"
         Mentat_session.Id.pp id Mentat_session.Id.pp (Document.id document));
  Handle.check_live t fence;
  if not (Mentat_session.Id.equal id fence.Handle.session) then
    invalid "commit"
      (Format.asprintf "fence is for session %a, not %a" Mentat_session.Id.pp
         fence.Handle.session Mentat_session.Id.pp id);
  locked t id (fun () ->
      let path = Layout.document id in
      match path_kind t path with
      | Error _ as error -> error
      | Ok `Missing -> Error (Error.Not_found id)
      | Ok (`Directory | `Other) -> non_file_document ~id path
      | Ok `File ->
          let* actual = current_revision t id in
          let expected = Document.revision document in
          if not (Mentat_digest.equal expected actual) then
            Error (Error.Conflict { id; expected; actual })
          else
            let text = encode_document session in
            (* The comparison succeeded: the replace runs to completion so a
               cancelled writer never leaves a half-observed commit. *)
            let* () = Eio.Cancel.protect (fun () -> write_document t id text) in
            Ok (Document.make ~session ~revision:(Mentat_digest.string text)))

let remove_locked t document =
  let id = Document.id document in
  locked t id (fun () ->
      let path = Layout.document id in
      match path_kind t path with
      | Error _ as error -> error
      | Ok `Missing -> Error (Error.Not_found id)
      | Ok (`Directory | `Other) -> non_file_document ~id path
      | Ok `File ->
          let* actual = current_revision t id in
          let expected = Document.revision document in
          if not (Mentat_digest.equal expected actual) then
            Error (Error.Conflict { id; expected; actual })
          else
            let dir = Layout.session_dir id in
            Eio.Cancel.protect (fun () ->
                io ~op:Io.Write ~path:dir (fun () ->
                    Eio.Path.rmtree ~missing_ok:true (Handle.path t dir);
                    (* Best-effort: the sibling doc lock is coordination residue,
                       not session state; this process holds it and unlinking a
                       held lock file is safe. A failure leaves an inert empty
                       file. *)
                    (try
                       Eio.Path.unlink ~missing_ok:true
                         (Handle.path t (Layout.doc_lock id))
                     with _ -> ());
                    Disk.fsync_dir ~path:Layout.sessions_dir
                      (Handle.path t Layout.sessions_dir))))

let remove t document =
  let id = Document.id document in
  (* The physical removal deletes [run.lock] with the rest of the tree, so it
     acquires the run fence first and holds it through the rmtree: no driver may
     hold the fence (else the rmtree would unlink a live lock and a successor
     could recreate it over a fresh inode), and none may acquire it during the
     removal. The fence and the doc lock take the same order commit does, so no
     writer deadlocks. *)
  Eio.Switch.run @@ fun sw ->
  match
    Run_lock.try_acquire ~sw t ~session:id
      ~owner:(Owner.make ~label:Run_lock.remove_owner_label ())
  with
  | Error (`Held holder) -> Error (Error.Locked { id; holder })
  | Error (`Io io) -> Error (Error.Io io)
  | Ok (_ : Run_lock.guard) -> remove_locked t document

let id_of_directory_name name =
  match Disk.unescaped_component name with
  | None -> None
  | Some text -> (
      match Mentat_session.Id.of_string text with
      | id -> Some id
      | exception Invalid_argument _ -> None)

(* An exact full scan: every document under [sessions/] is decoded; good
   documents are returned in directory-name order and corrupt ones as located
   facts that never hide the healthy rest. Lifecycle filtering, recency ordering,
   text search, and limits are query policy composed above this exact result. *)
let scan t =
  match path_kind t Layout.sessions_dir with
  | Error _ as error -> error
  | Ok `Missing -> Ok ([], [])
  | Ok (`File | `Other) ->
      Error
        (Error.Corrupt
           (Corrupt.make ~path:Layout.sessions_dir ~message:"is not a directory"
              ()))
  | Ok `Directory ->
      let* names =
        io ~op:Io.Read ~path:Layout.sessions_dir (fun () ->
            Eio.Path.read_dir (Handle.path t Layout.sessions_dir))
      in
      let rec collect documents corrupt = function
        | [] -> Ok (List.rev documents, List.rev corrupt)
        | name :: names -> (
            let child_dir = Layout.sessions_dir ^ "/" ^ name in
            let path = child_dir ^ "/session.json" in
            let path_id = id_of_directory_name name in
            match path_kind t child_dir with
            | Error _ as error -> error
            | Ok (`Missing | `File | `Other) ->
                (* A non-directory entry under [sessions/] is not a session; a
                   stat failure (EACCES/ENOTDIR) surfaced above, never a swallowed
                   skip. *)
                collect documents corrupt names
            | Ok `Directory -> (
                match path_kind t path with
                | Error error -> Error error
                | Ok `Missing -> (
                    (* A document-less session directory is invisible only when
                       empty (a crashed create's residue); one that holds
                       anything is damaged state and is surfaced, never silently
                       skipped. *)
                    let* entries =
                      io ~op:Io.Read ~path:child_dir (fun () ->
                          Eio.Path.read_dir (Handle.path t child_dir))
                    in
                    match entries with
                    | [] -> collect documents corrupt names
                    | _ :: _ ->
                        collect documents
                          (Corrupt.make ?id:path_id ~path:child_dir
                             ~message:
                               "non-empty session directory has no session \
                                document"
                             ()
                          :: corrupt)
                          names)
                | Ok (`Directory | `Other) ->
                    collect documents
                      (Corrupt.make ?id:path_id ~path
                         ~message:"is not a regular file" ()
                      :: corrupt)
                      names
                | Ok `File -> (
                    match path_id with
                    | None ->
                        collect documents
                          (Corrupt.make ~path
                             ~message:"store path is not a valid session id" ()
                          :: corrupt)
                          names
                    | Some expected -> (
                        match load_document ~id:expected t path with
                        | Error (Error.Corrupt fact) ->
                            collect documents (fact :: corrupt) names
                        | Error error -> Error error
                        | Ok document ->
                            let actual = Document.id document in
                            if not (Mentat_session.Id.equal expected actual)
                            then
                              let message =
                                Format.asprintf
                                  "document id %a does not match store path id \
                                   %a"
                                  Mentat_session.Id.pp actual
                                  Mentat_session.Id.pp expected
                              in
                              collect documents
                                (Corrupt.make ~id:expected ~path ~message ()
                                :: corrupt)
                                names
                            else collect (document :: documents) corrupt names))
                ))
      in
      collect [] [] (List.sort String.compare names)
