(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The product name used in the [mentat: <message>] error prefix. *)
let tool = "mentat"

type t =
  | Success
  | Failed
  | Runtime_error of string
  | Usage_error of string
  | Blocked of string
  | Interrupted
  | Internal of string

let code = function
  | Success -> 0
  | Failed -> 1
  | Runtime_error _ -> 1
  | Usage_error _ -> 2
  | Blocked _ -> 3
  | Interrupted -> 130
  | Internal _ -> 125

let emit = function
  | Success | Failed | Interrupted -> ()
  | Runtime_error message | Usage_error message | Blocked message ->
      Output.stderr_printf "%s: %s\n" tool message
  | Internal message ->
      Output.stderr_printf "%s: internal error: %s\n" tool message

let to_process_code t =
  emit t;
  code t

let term u = Cmdliner.Term.(const to_process_code $ u)

let exits =
  Cmdliner.Cmd.Exit.
    [
      info 0 ~doc:"on success.";
      info 1 ~doc:"if a runtime error happened.";
      info 2 ~doc:"if command input is invalid.";
      info 3 ~doc:"if the session is blocked on user action.";
      info 124 ~doc:"if command-line parsing fails.";
      info 125 ~doc:"if an unexpected internal error happens.";
      info 130 ~doc:"if the user interrupts the run (Ctrl-C).";
    ]

let of_diagnostic d = Runtime_error (Mentat_diagnostic.to_string d)
let runtime message = Runtime_error message
let usage message = Usage_error message
let of_result = function Ok t -> t | Error t -> t

let of_exn = function
  | Unix.Unix_error (e, _, _) -> Runtime_error (Unix.error_message e)
  | Sys_error message -> Runtime_error message
  | Eio.Io _ as exn -> Runtime_error (Printexc.to_string exn)
  | exn -> Internal (Printexc.to_string exn)

let daemon_busy_hint =
  "the mentat daemon drives this session; re-run with --attach"

let of_protocol_error ?(daemon_live = fun () -> false) e =
  let module E = Mentat_protocol.Error in
  let rendered = Mentat_diagnostic.to_string (E.diagnostic e) in
  match (e : E.t) with
  | E.Invalid_position _ | E.Turn_id_reused _ | E.No_active_turn _
  | E.Active_turn_exists _ | E.Decision_not_pending _ | E.Already_resolved _
  | E.Invalid_title | E.Invalid_api_key ->
      Usage_error rendered
  | E.Busy _ ->
      (* A Busy against a live daemon: the daemon holds the fence, so point the
         user at --attach rather than let them fight it (4e). Rendering only —
         with no daemon [daemon_live] is false and the message is unchanged, so
         offline goldens do not move. *)
      if daemon_live () then Runtime_error (rendered ^ "\n" ^ daemon_busy_hint)
      else Runtime_error rendered
  (* [Unknown_command] reaches here only on the expansion race where a known
     command file vanished between catalog and expansion — a missing entity in
     [Session_not_found]'s class, not caller misuse. [File_unresolved] is the
     sibling expansion failure: a command's [@file] reference did not resolve. *)
  | E.Session_not_found _ | E.Archived _ | E.Deleted _ | E.Unknown_command _
  | E.File_unresolved _ | E.Unavailable _ ->
      Runtime_error rendered
