(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* [mentat] lives beside [mentatd] in every release artifact, so the spawn
   resolves the sibling of the running executable. [Unix.create_process] cannot
   report a missing program (the exec fails in the child), so an absent sibling
   is refused here, loudly. [MENTAT_BIN] overrides the sibling resolution for
   layouts where the two binaries do not share a directory (a build tree, a
   test harness). *)
let resolve_mentat () =
  let is_program path = Sys.file_exists path && not (Sys.is_directory path) in
  match Sys.getenv_opt "MENTAT_BIN" with
  | Some bin when not (String.equal bin "") ->
      if is_program bin then Ok bin
      else
        Error (Printf.sprintf "MENTAT_BIN names %s, which is not a program" bin)
  | _ ->
      let sibling =
        Filename.concat (Filename.dirname Sys.executable_name) "mentat"
      in
      if is_program sibling then Ok sibling
      else
        Error
          (Printf.sprintf
             "the mentat binary is missing: expected %s (every release \
              installs it beside mentatd); reinstall, or set MENTAT_BIN to \
              run one from elsewhere"
             sibling)

(* The child's stdio log, one per session under the daemon home, named by the
   same path-safe leaf its socket directory uses. Unrotated: a child is spawned
   per delegation and appends only its own boot and crash lines, so the file is
   bounded by re-spawn frequency, not by daemon lifetime. *)
let log_path dirs ~session =
  Filename.concat (User_dirs.daemon_dir dirs)
    (Printf.sprintf "child-%s.log"
       (Filename.basename (User_dirs.child_socket_dir dirs ~session)))

let spawn dirs ~environment ~session ~cwd =
  match resolve_mentat () with
  | Error _ as e -> e
  | Ok bin ->
      Daemon.ensure_daemon_dir dirs;
      let session = Mentat_session.Id.to_string session in
      let argv =
        [|
          "mentat";
          "serve-session";
          "--session";
          session;
          "--cwd";
          Lpath.Abs.to_string cwd;
          "--spawned";
        |]
      in
      (* Identity only crosses the spawn: the child re-reads its task and role
         from the durable delegation edge. The environment is the instance's
         snapshot — the shell that asked for the run — rendered whole, so the
         child's own composition re-resolves everything else from it.

         Detached fork+exec (never an Eio-managed spawn, whose switch teardown
         would kill a child that must outlive it); the child [setsid]s under
         [--spawned], so no signal to this process's group reaches it. The
         returned pid is the caller's to reap. *)
      let env =
        Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) environment)
      in
      let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
      let close fd = try Unix.close fd with Unix.Unix_error _ -> () in
      Fun.protect
        ~finally:(fun () -> close devnull)
        (fun () ->
          let log =
            Unix.openfile (log_path dirs ~session)
              [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
              0o600
          in
          Fun.protect
            ~finally:(fun () -> close log)
            (fun () -> Ok (Unix.create_process_env bin argv env devnull log log)))
