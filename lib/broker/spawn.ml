(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The child's stdio log, one per session under the configured log directory,
   named by the same path-safe leaf its socket directory uses. Unrotated: a
   child is spawned per delegation and appends only its own boot and crash
   lines, so the file is bounded by re-spawn frequency, not by the spawning
   process's lifetime. *)
let log_path ~log_dir ~leaf =
  Filename.concat log_dir (Printf.sprintf "child-%s.log" leaf)

let ensure_log_dir log_dir =
  try Unix.mkdir log_dir 0o700
  with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let spawn ~resolve_bin ~log_dir ~leaf ~environment ~session ~interrupted ~cwd =
  match resolve_bin () with
  | Error _ as e -> e
  | Ok bin ->
      ensure_log_dir log_dir;
      let session = Mentat_session.Id.to_string session in
      let argv =
        [
          "mentat";
          "serve-session";
          "--session";
          session;
          "--cwd";
          Lpath.Abs.to_string cwd;
          "--spawned";
        ]
        @ (if interrupted then [ "--interrupted" ] else [])
      in
      let argv = Array.of_list argv in
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
            Unix.openfile (log_path ~log_dir ~leaf)
              [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
              0o600
          in
          Fun.protect
            ~finally:(fun () -> close log)
            (fun () -> Ok (Unix.create_process_env bin argv env devnull log log)))
