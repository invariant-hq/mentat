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
  mutable dead : bool;
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
    dead = false;
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

(* Availability is the first run's answer, in both worlds: a direct
   command that cannot spawn is a structural [Error]; a [dune exec]-reached
   one that does not exist is dune's own [Program "<name>" not found]. The
   name asked about is the command's target — past the [dune exec --]
   prefix when the gate added one. *)
let target t =
  match t.command with
  | "dune" :: "exec" :: "--" :: name :: _ -> name
  | name :: _ -> name
  | [] -> assert false (* refused at make *)

let says_not_found t output =
  let needle = Printf.sprintf "Program %S not found" (target t) in
  let length = String.length needle in
  let rec search from =
    if from + length > String.length output then false
    else
      String.equal (String.sub output from length) needle
      || search (from + 1)
  in
  search 0

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
      t.dead <- true;
      Log.info (fun m ->
          m "lint command cannot spawn; lint lane off: %a" Command.Error.pp
            error)
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
              if says_not_found t (captured_text outcome) then begin
                t.dead <- true;
                Log.info (fun m ->
                    m "lint target %s is not in the project; lint lane off"
                      (target t))
              end
              else
                Log.warn (fun m ->
                    m "lint command failed without findings; findings kept")))

let engage t =
  if not t.engaged then begin
    t.engaged <- true;
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
        let rec loop () =
          if t.dead then `Stop_daemon
          else begin
            (match due t with Some at -> run_once t at | None -> ());
            sleep t poll_s;
            loop ()
          end
        in
        loop ())
  end
