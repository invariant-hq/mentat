(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Server = Mentat_server
module Discovery = Server.Discovery

(* A release carries its version; a dev build does not, and "dev" == "dev"
   would attach a fresh client to any stale daemon from an older build —
   whose wire may have moved — leaving surfaces silently empty. The
   executable's own identity (device, inode, mtime, size — a rebuild mints
   a fresh inode) makes the gate mean what it says for dev builds too. *)
let binary_version =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> (
      match Unix.stat Sys.executable_name with
      | { Unix.st_dev; st_ino; st_mtime; st_size; _ } ->
          Printf.sprintf "dev-%d:%d:%.0f:%d" st_dev st_ino st_mtime st_size
      | exception Unix.Unix_error _ -> "dev")

(* ---- Path policy ---- *)

let daemon_dir_abs dirs = Lpath.Abs.of_string_exn (User_dirs.daemon_dir dirs)

let daemon_log_path dirs =
  Filename.concat (User_dirs.daemon_dir dirs) "daemon.log"

let ensure_daemon_dir dirs =
  try Unix.mkdir (User_dirs.daemon_dir dirs) 0o700
  with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

(* ---- Client attach: find-or-spawn ---- *)

(* [daemon.log] captures the daemon's whole standard output and error, not just
   its diagnostics records, so nothing inside the logging system bounds it. Left
   alone it grows for the life of the data home. Spawn is the moment to rotate:
   the successor is about to start writing, and daemons are spawned per need and
   idle out, so restarts are frequent enough for this to bound growth in
   practice. A single daemon living for weeks still grows between spawns. *)
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

let spawn dirs =
  ensure_daemon_dir dirs;
  let log = daemon_log_path dirs in
  rotate_daemon_log dirs log;
  let fd =
    Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      (* Detached fork+exec (never an Eio-managed spawn, whose switch would kill
         the daemon with the CLI); the child [setsid]s under [--spawned]. The
         current environment is inherited, so the daemon opens the same store.

         Single fork, not a double-fork: the spawning CLI stays the daemon's
         parent, so a daemon that dies while this long-lived CLI still runs stays
         a zombie until the CLI reaps it or exits. The worst case is one
         process-table entry after a daemon crash — not worth the double-fork
         re-parent-to-init machinery for a single-user Stage 2. *)
      ignore
        (Unix.create_process Sys.executable_name
           [| "mentat"; "serve"; "--spawned" |]
           Unix.stdin fd fd))

(* Whether a per-user daemon is live for these dirs (a discovery file present
   and its claim held) — the signal the offline Busy hint keys on (4e). A free
   claim under a present file is a dead daemon (a stale file), so not running. *)
let is_running dirs =
  let ddir = daemon_dir_abs dirs in
  match Discovery.read ~dir:ddir with
  | `Found _ | `Foreign _ -> (
      match Discovery.Claim.try_acquire ~dir:ddir with
      | Ok claim ->
          Discovery.Claim.release claim;
          false
      | Error `Held -> true
      | Error (`Io _) -> false)
  | `Absent -> false

let connect_to t ~socket =
  let net = Eio.Stdenv.net (Composition.stdenv t) in
  let clock = Eio.Stdenv.clock (Composition.stdenv t) in
  let sw = Composition.sw t in
  let root = Lpath.Abs.to_string (Composition.root t) in
  let dir = Lpath.Abs.of_string_exn (Filename.dirname socket) in
  match
    Server.connect ~sw ~net ~clock ~workspace:root
      ~environment:(Composition.environment t)
      (Server.Bind.unix ~dir)
  with
  | Ok driver -> Some driver
  | Error _ -> None

let find_or_spawn t =
  let dirs = Composition.dirs t in
  let ddir = daemon_dir_abs dirs in
  let clock = Eio.Stdenv.clock (Composition.stdenv t) in
  (* The real effects behind the library's convergence state machine. *)
  let read () = Discovery.read ~dir:ddir in
  let claim_free () =
    match Discovery.Claim.try_acquire ~dir:ddir with
    | Ok claim ->
        Discovery.Claim.release claim;
        true
    | Error `Held -> false
    | Error (`Io _) -> false
  in
  let probe record = connect_to t ~socket:record.Discovery.socket in
  let identity_ok record =
    String.equal record.Discovery.binary binary_version
    && String.equal record.Discovery.config_home (User_dirs.config_home dirs)
  in
  let spawn () = spawn dirs in
  let sleep () = Eio.Time.sleep clock 0.05 in
  (* MENTAT_DAEMON_SOCKET beats discovery: connect straight to the named socket
     (its [mentat.sock] path), no daemon.json read and no spawn. A named socket
     that does not answer is a definite failure, not a fallback that spawns. *)
  let socket_override () =
    match Sys.getenv_opt "MENTAT_DAEMON_SOCKET" with
    | None | Some "" -> `Unset
    | Some socket -> (
        match connect_to t ~socket with
        | Some driver -> `Reached driver
        | None -> `Set_unreachable)
  in
  match
    Discovery.locate_with_override ~socket_override ~read ~claim_free ~probe
      ~identity_ok ~spawn ~sleep ~poll_budget:100
  with
  | `Attached driver -> Ok driver
  | `Mismatch _ ->
      Error
        (Exit_status.runtime
           "the running mentat daemon was built from a different binary or \
            config home; run `mentat serve --stop` to replace it")
  | `Foreign_held ->
      Error
        (Exit_status.runtime
           "an unrecognized mentat daemon file is present and its claim is \
            held; run `mentat serve --stop`")
  | `Timeout ->
      Error
        (Exit_status.runtime
           (match Sys.getenv_opt "MENTAT_DAEMON_SOCKET" with
           | Some socket when not (String.equal socket "") ->
               Printf.sprintf
                 "the mentat daemon named by MENTAT_DAEMON_SOCKET (%s) did not \
                  answer"
                 socket
           | _ ->
               Printf.sprintf "the mentat daemon did not come up; see %s"
                 (daemon_log_path dirs)))

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
