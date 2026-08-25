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
  command : string list;
  mutable engaged : bool;
  (* The activity count of the last run's trigger: a fresh Clean settle is
     one whose stream moved past it — dune mints fresh diagnostic ids per
     build, so any build produces events and advances the count. *)
  mutable ran_at : int;
}

(* The trigger poll is a memory read; the run itself is bounded generously —
   a linter over fresh build artifacts is quick work, and a cold first run
   on a large tree is real work worth waiting for once. *)
let poll_s = 0.5
let run_timeout_s = 600.0

let make ~rpc ~capability ~mono ~sw ~workspace ~command =
  if command = [] then invalid_arg "lint command must not be empty";
  {
    rpc;
    capability;
    mono = Mono mono;
    sw;
    workspace;
    command;
    engaged = false;
    ran_at = -1;
  }

let sleep t seconds =
  let (Mono mono) = t.mono in
  Eio.Time.Mono.sleep mono seconds

(* A Clean settle whose stream activity moved past the last run: the moment
   the linter's build-artifact inputs are fresh and unread. *)
let due t =
  let snapshot = Mentat_ocaml_dune_rpc.Instance.snapshot t.rpc in
  match snapshot.Mentat_ocaml_dune_rpc.Instance.Snapshot.reading with
  | Some reading
    when Mentat_workspace.Health.Verdict.equal
           (Mentat_ocaml.Build_change.Reading.verdict reading)
           Mentat_workspace.Health.Verdict.Clean ->
      let at = Mentat_ocaml_dune_rpc.Instance.activity t.rpc in
      if at > t.ran_at then Some at else None
  | Some _ | None -> None

let captured_text outcome =
  Command.Captured.render outcome.Command.stdout
  ^ "\n"
  ^ Command.Captured.render outcome.Command.stderr

let run_once t at =
  let cwd =
    Mentat_workspace.Path.root_of (Mentat_workspace_io.cwd t.capability)
  in
  let (Mono mono) = t.mono in
  let timeout = Eio.Time.Timeout.seconds mono run_timeout_s in
  match
    Command.run t.capability ~cwd ~capture:Command.All ~timeout t.command
  with
  | Error error ->
      t.ran_at <- at;
      Log.warn (fun m ->
          m "lint run failed to spawn: %a" Command.Error.pp error)
  | Ok outcome -> (
      t.ran_at <- at;
      match outcome.Command.termination with
      | Command.Timed_out | Command.Stopped | Command.Output_limit _
      | Command.Supervision_failed _ ->
          Log.warn (fun m -> m "lint run did not complete; findings kept")
      | Command.Exited status -> (
          let findings =
            Mentat_ocaml_dune_rpc.Lint_output.findings
              ~workspace:t.workspace (captured_text outcome)
          in
          match (status, findings) with
          (* A linter exits non-zero *because* it found something; non-zero
             with nothing parsed is a crash — a crashed linter must never
             state Lint clean, so the lane keeps its last word. *)
          | `Exited 0, findings | _, (_ :: _ as findings) ->
              Log.info (fun m ->
                  m "lint run settled: %d finding(s)" (List.length findings));
              Mentat_ocaml_dune_rpc.Instance.set_lint t.rpc (Some findings)
          | (`Exited _ | `Signaled _), [] ->
              Log.warn (fun m ->
                  m "lint command failed without findings; findings kept")))

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
