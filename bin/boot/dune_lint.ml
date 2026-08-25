(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Command = Mentat_workspace_io.Command

let log_src = Logs.Src.create "mentat.dune.lint" ~doc:"Lint runner"

module Log = (val Logs.src_log log_src : Logs.LOG)

type mono = Mono : _ Eio.Time.Mono.t -> mono

type t = {
  rpc : Mentat_ocaml_dune_rpc.Instance.t;
  capability : Mentat_workspace_io.t;
  mono : mono;
  sw : Eio.Switch.t;
  workspace : Mentat_workspace.t;
  resolve : unit -> string list option;
  mutable engaged : bool;
  (* The activity count of the last run's trigger: a fresh Clean settle is
     one whose stream moved past it. A build that touches an error, or that
     outlasts dune's 0.2 s progress sample, produces events and advances
     the count; a sub-sample clean-to-clean rebuild can escape it, and a
     stale lint word from that blind spot heals at the next observed
     build. No dune runs in the lint path, so a run never advances the
     count itself. *)
  mutable ran_at : int;
  (* Whether the last settle found a runnable command — a log-noise latch
     only: the transition into unreachable is said once, not per settle. *)
  mutable resolved : bool;
}

(* The trigger poll is a memory read; the run itself is bounded generously —
   a linter over fresh build artifacts is quick work, and a cold first run
   on a large tree is real work worth waiting for once. The capture bound
   is diagnostic-scale, not unbounded: a linter caught in a log-spew loop
   hits the limit, is terminated, and lands in the incomplete-run arm. *)
let poll_s = 0.5
let run_timeout_s = 600.0
let capture_bytes = 8 * 1024 * 1024

let make ~rpc ~capability ~mono ~sw ~workspace ~resolve =
  {
    rpc;
    capability;
    mono = Mono mono;
    sw;
    workspace;
    resolve;
    engaged = false;
    ran_at = -1;
    resolved = true;
  }

let sleep t seconds =
  let (Mono mono) = t.mono in
  Eio.Time.Mono.sleep mono seconds

(* A Clean settle whose stream activity moved past the last run: the moment
   the linter's build-artifact inputs are fresh and unread. The generation
   is read before the snapshot it judges, so a fold racing the two reads
   can only make the stamp conservative — one redundant, idempotent run,
   never a skipped settle. The stamp is also judged before the snapshot is
   built: the poll runs at 2 Hz for the session, and its steady state must
   cost two reads, not a composed reading. *)
let due t =
  let at = Mentat_ocaml_dune_rpc.Instance.activity t.rpc in
  if at <= t.ran_at then None
  else
    let snapshot = Mentat_ocaml_dune_rpc.Instance.snapshot t.rpc in
    match snapshot.Mentat_ocaml_dune_rpc.Instance.Snapshot.reading with
    | Some reading
      when Mentat_workspace.Health.Verdict.equal
             (Mentat_ocaml.Build_change.Reading.verdict reading)
             Mentat_workspace.Health.Verdict.Clean ->
        Some at
    | Some _ | None -> None

let captured_text outcome =
  Command.Captured.render outcome.Command.stdout
  ^ "\n"
  ^ Command.Captured.render outcome.Command.stderr

(* The command is resolved at every due settle, never once for the
   session: a linter that is not there yet — a lock universe still
   building, a PATH entry installed mid-session — simply skips settles
   until it appears, and one that vanishes skips until it returns. The
   lane has no death; only [dune.lint_command = []] means no runner. *)
let run_once t at =
  match t.resolve () with
  | None ->
      t.ran_at <- at;
      if t.resolved then begin
        t.resolved <- false;
        Log.info (fun m ->
            m
              "lint target not reachable; settles are skipped until it \
               appears")
      end
  | Some command -> (
      if not t.resolved then begin
        t.resolved <- true;
        Log.info (fun m -> m "lint target reachable again")
      end;
      (* The run's cwd is the primary root of the same workspace the
         findings resolve against — never the session cwd's root, which in
         a multi-root session may be an auxiliary one and would skew every
         relative path the linter prints. *)
      let cwd =
        Mentat_workspace.Path.make
          ~root_key:
            (Mentat_workspace.Root.key (Mentat_workspace.primary t.workspace))
          Lpath.Rel.root
      in
      let (Mono mono) = t.mono in
      let timeout = Eio.Time.Timeout.seconds mono run_timeout_s in
      match
        Command.run t.capability ~cwd ~capture:(Command.Limit capture_bytes)
          ~timeout command
      with
      | Error error ->
          (* A launch failure — a binary gone between the probe and the
             spawn included — forfeits this settle, never the lane: the
             next settle resolves afresh. *)
          t.ran_at <- at;
          Log.warn (fun m ->
              m "lint run failed to launch; findings kept: %a"
                Command.Error.pp error)
      | Ok outcome -> (
      t.ran_at <- at;
      match outcome.Command.termination with
      | Command.Timed_out | Command.Stopped | Command.Output_limit _
      | Command.Supervision_failed _ ->
          Log.warn (fun m -> m "lint run did not complete; findings kept")
      | Command.Exited status -> (
          let text = captured_text outcome in
          (* Any raise out of the parse — hostile output overflowing the
             lexer included — is the crashed-run case, never the daemon
             fiber's death; cancellation alone passes through. *)
          match
            Mentat_ocaml_dune_rpc.Lint_output.findings ~workspace:t.workspace
              text
          with
          | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
          | exception exn ->
              Log.warn (fun m ->
                  m "lint output did not parse; findings kept: %s"
                    (Printexc.to_string exn))
          | findings -> (
              match (status, findings) with
              (* A completed linter's word: exit 0 is a clean or full
                 report; non-zero with findings is the found-something
                 exit. A signal death is the one termination whose report
                 is knowably incomplete — publishing its partial set would
                 fabricate resolutions — so it keeps the last word beside
                 the other incomplete runs, whatever it printed. *)
              | `Exited 0, findings | `Exited _, (_ :: _ as findings) ->
                  Log.info (fun m ->
                      m "lint run settled: %d finding(s)"
                        (List.length findings));
                  Mentat_ocaml_dune_rpc.Instance.set_lint t.rpc
                    (Some findings)
              | `Exited _, [] ->
                  Log.warn (fun m ->
                      m "lint command failed without findings; findings kept")
              | `Signaled _, _ ->
                  Log.warn (fun m ->
                      m "lint run died mid-report; findings kept")))))

let engage t =
  if not t.engaged then begin
    t.engaged <- true;
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
        let rec loop () =
          (match due t with Some at -> run_once t at | None -> ());
          sleep t poll_s;
          loop ()
        in
        loop ())
  end
