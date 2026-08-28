(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Server = Mentat_server
module Discovery = Server.Discovery

(* The identity the daemon records in its discovery file. A release version
   is shared by both binaries; a dev build falls back to the weak "dev"
   stamp — the wire handshake's protocol version is the enforcement. *)
let binary_version =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> "dev"

(* ---- Path policy ---- *)

let daemon_dir_abs dirs = Lpath.Abs.of_string_exn (User_dirs.daemon_dir dirs)

let daemon_log_path dirs =
  Filename.concat (User_dirs.daemon_dir dirs) "daemon.log"

let ensure_daemon_dir dirs =
  try Unix.mkdir (User_dirs.daemon_dir dirs) 0o700
  with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

(* ---- The daemon log ---- *)

(* [daemon.log] captures the daemon's whole standard output and error, not just
   its diagnostics records, so nothing inside the logging system bounds it. Left
   alone it grows for the life of the data home. The daemon's own boot is the
   moment to rotate — the one point every writer passes, a service manager's
   restart included; a spawn-site rotation would never run for a
   manager-started daemon, whose spawner is the manager itself. *)
let daemon_log_cap = 8 * 1024 * 1024
let daemon_logs_kept = 5

let rotate_daemon_log dirs log =
  match Unix.stat log with
  | stat when stat.Unix.st_size >= daemon_log_cap ->
      let stamp = Int64.of_float (Unix.gettimeofday () *. 1_000_000.) in
      let rotated =
        Filename.concat
          (User_dirs.daemon_dir dirs)
          (Printf.sprintf "daemon-%Ld.log" stamp)
      in
      (try Unix.rename log rotated with Unix.Unix_error _ -> ());
      Log_setup.retain_logs ~keep:daemon_logs_kept
        ~dir:(User_dirs.daemon_dir dirs)
        ~current:log
  | _ | (exception Unix.Unix_error _) -> ()

let stdout_is_daemon_log dirs =
  match (Unix.fstat Unix.stdout, Unix.stat (daemon_log_path dirs)) with
  | out, file ->
      out.Unix.st_dev = file.Unix.st_dev && out.Unix.st_ino = file.Unix.st_ino
  | exception Unix.Unix_error _ -> false

let rotate_owned_log dirs =
  if stdout_is_daemon_log dirs then (
    let log = daemon_log_path dirs in
    rotate_daemon_log dirs log;
    (* After a rename the inherited fds still point at the rotated file,
       so the path is reopened append-only and laid over stdout and
       stderr either way. *)
    match
      Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600
    with
    | fd ->
        Unix.dup2 fd Unix.stdout;
        Unix.dup2 fd Unix.stderr;
        if fd <> Unix.stdout && fd <> Unix.stderr then (
          try Unix.close fd with Unix.Unix_error _ -> ())
    | exception Unix.Unix_error _ -> ())

(* [mentat] and [mentatd] ship beside each other in every release artifact —
   so each spawns the other by resolving the sibling of the running
   executable. [Unix.create_process] cannot report a missing program (the exec
   fails in the child), so an absent sibling must be refused here, loudly,
   rather than surface as a spawn that never converges. [env] overrides the
   sibling resolution for layouts where the two binaries do not share a
   directory (a build tree, a test harness). *)
let resolve_sibling ~env ~name ~beside =
  (* [Sys.file_exists] alone would accept a directory — which a build tree has
     at exactly the daemon's path ([bin/mentatd/] holding the executable) —
     and an exec of a directory fails only in the forked child, invisibly. So
     would a present-but-non-executable file: [Unix.create_process] reports
     its exec failure only in the child too, so execute permission must be
     checked here, loudly, rather than surface as a spawn that never
     converges. *)
  let is_program path =
    Sys.file_exists path
    && (not (Sys.is_directory path))
    &&
    match Unix.access path [ Unix.X_OK ] with
    | () -> true
    | exception Unix.Unix_error _ -> false
  in
  match Sys.getenv_opt env with
  | Some bin when not (String.equal bin "") ->
      if is_program bin then Ok bin
      else Error (Printf.sprintf "%s names %s, which is not a program" env bin)
  | _ ->
      let sibling =
        Filename.concat (Filename.dirname Sys.executable_name) name
      in
      if is_program sibling then Ok sibling
      else
        Error
          (Printf.sprintf
             "the %s binary is missing: expected %s (every release installs \
              it beside %s); reinstall, or set %s to run one from elsewhere"
             name sibling beside env)

(* ---- Stop ---- *)

let stop () =
  match User_dirs.resolve ~getenv:Sys.getenv_opt with
  | Error message -> Exit_status.runtime message
  | Ok dirs -> (
      let ddir = daemon_dir_abs dirs in
      (* Poll the claim — the truth — for release, briefly. *)
      let released_within tenths =
        let rec loop budget =
          if budget <= 0 then false
          else
            match Discovery.Claim.try_acquire ~dir:ddir with
            | Ok claim ->
                Discovery.Claim.release claim;
                true
            | Error `Held ->
                Unix.sleepf 0.1;
                loop (budget - 1)
            | Error (`Io _) -> false
        in
        loop tenths
      in
      (* Signal the daemon holding the claim and wait for it to release. The
         discovery file may transiently name a dead predecessor while a live
         successor already holds the claim but has not yet rewritten the file (a
         reclaimed daemon claims first, then writes discovery), so each round
         re-reads the {b current} file and re-signals its pid — a stale pid can
         never leave a live successor running. Bounded (~10s across rounds); a
         claim still held after the budget is a wedged daemon. *)
      let stop_claim_holder ~first_pid =
        let signal pid =
          try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ()
        in
        let rec drive round =
          let named =
            match Discovery.read ~dir:ddir with
            | `Found current -> Some current.Discovery.pid
            | `Absent | `Foreign _ -> None
          in
          Option.iter signal named;
          if released_within 10 then Exit_status.Success
          else if round >= 9 then
            Exit_status.runtime
              (Printf.sprintf
                 "the mentat daemon (pid %d) did not stop; it may be wedged"
                 (Option.value named ~default:first_pid))
          else drive (round + 1)
        in
        signal first_pid;
        if released_within 10 then Exit_status.Success else drive 1
      in
      match Discovery.read ~dir:ddir with
      | `Absent -> Exit_status.Success
      | `Foreign _ -> (
          match Discovery.Claim.try_acquire ~dir:ddir with
          | Ok claim ->
              Discovery.Claim.release claim;
              Exit_status.Success
          | Error `Held ->
              Exit_status.runtime
                "an unrecognized mentat daemon file is present and its claim \
                 is held"
          | Error (`Io message) -> Exit_status.runtime message)
      | `Found record -> (
          match Discovery.Claim.try_acquire ~dir:ddir with
          | Ok claim ->
              (* Claim free: already dead — unlink the stale file. *)
              Discovery.Claim.release claim;
              Discovery.clear ~dir:ddir ~pid:record.Discovery.pid;
              Exit_status.Success
          | Error `Held -> stop_claim_holder ~first_pid:record.Discovery.pid
          | Error (`Io message) -> Exit_status.runtime message))
