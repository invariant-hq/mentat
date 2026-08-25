(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Feed = Feed
module Login = Login
module Driver = Driver

type t = {
  driver : Driver.t;
  user_commands :
    unit ->
    (Mentat_protocol.User_command.t list, Mentat_protocol.Error.t) result;
  expand_command :
    name:string ->
    arguments:string ->
    (Mentat_llm.Content.t list, Mentat_protocol.Error.t) result;
  attach :
    session:Mentat_session.Id.t ->
    Mentat_protocol.Attach.source ->
    (Mentat_llm.Content.t, Mentat_protocol.Attach.Error.t) result;
}

type compaction_result = Driver.compaction_result = Installed | Skipped

let make ~user_commands ~expand_command ~attach driver =
  { driver; user_commands; expand_command; attach }

(* Field labels are qualified with their defining module so record access does
   not rely on type-directed disambiguation (warnings 40/42). *)

let session_cone t = t.driver.Driver.session
let accounts_cone t = t.driver.Driver.accounts
let settings_cone t = t.driver.Driver.settings
let lifecycle_cone t = t.driver.Driver.lifecycle
let review_cone t = t.driver.Driver.review
let workspace_cone t = t.driver.Driver.workspace

let protect operation invoke =
  match invoke () with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception _ ->
      Error
        (Mentat_protocol.Error.unavailable (operation ^ " failed unexpectedly"))

(* Feeds and submission. *)

let follow_session ~sw t id ~from =
  match
    protect "follow_session" (fun () ->
        (session_cone t).Driver.Session.follow id ~from)
  with
  | Error error -> Error error
  | Ok seam -> Ok (Feed.subscribe ~sw seam)

let submit t command =
  protect "submit" (fun () -> (session_cone t).Driver.Session.submit command)

(* Read-only snapshots. Each forwards to the field its owning cone fills, the
   same one-line idiom as the write operations. *)

let pending_decision t id =
  protect "pending_decision" (fun () ->
      (session_cone t).Driver.Session.pending_decision id)

let running_processes t id =
  protect "running_processes" (fun () ->
      (session_cone t).Driver.Session.running_processes id)

let change_diff t ~session:id ~change =
  protect "change_diff" (fun () ->
      (session_cone t).Driver.Session.change_diff ~session:id ~change)

let tail t ?n id =
  protect "tail" (fun () -> (session_cone t).Driver.Session.tail ?n id)

let page t ?n id ~before =
  protect "page" (fun () -> (session_cone t).Driver.Session.page ?n id ~before)

let undo t ~session:id ~op =
  protect "undo" (fun () ->
      (session_cone t).Driver.Session.undo ~session:id ~op)

let revert t ~session:id ~scope =
  protect "revert" (fun () ->
      (session_cone t).Driver.Session.revert ~session:id ~scope)

let export t ~session:id =
  protect "export" (fun () ->
      (session_cone t).Driver.Session.export ~session:id)

let account_readiness t =
  protect "account_readiness" (fun () ->
      (accounts_cone t).Driver.Accounts.account_readiness ())

let model_readiness ?refresh t =
  protect "model_readiness" (fun () ->
      (accounts_cone t).Driver.Accounts.model_readiness ?refresh ())

let configuration t =
  protect "configuration" (fun () ->
      (settings_cone t).Driver.Settings.configuration ())

let sessions t listing =
  protect "sessions" (fun () ->
      (lifecycle_cone t).Driver.Lifecycle.sessions ~listing)

let session t id =
  protect "session" (fun () -> (lifecycle_cone t).Driver.Lifecycle.session id)

let review_state t ~scope =
  protect "review_state" (fun () -> (review_cone t).Driver.Review.state ~scope)

let review_diff t ~path =
  protect "review_diff" (fun () -> (review_cone t).Driver.Review.diff ~path)

let review_crs t =
  protect "review_crs" (fun () -> (review_cone t).Driver.Review.crs ())

let workspace_glance t =
  protect "workspace_glance" (fun () ->
      (workspace_cone t).Driver.Workspace.glance ())

let workspace_dune t =
  protect "workspace_dune" (fun () ->
      (workspace_cone t).Driver.Workspace.dune ())

let workspace_dune_control t ~op =
  protect "workspace_dune_control" (fun () ->
      (workspace_cone t).Driver.Workspace.dune_control ~op)

(* User commands. The responders are required injection points into [make],
   parallel to the [Driver.t] cones, rather than [Driver.t] fields — a backend
   that builds a driver without a client-side command cone (the daemon, until it
   wires discovery) still constructs, but must consciously supply responders; a
   backend that declines passes ones returning the typed error, a visible
   decision rather than a silent gap. *)

let user_commands t = protect "user_commands" t.user_commands

let expand_command t ~name ~arguments =
  protect "expand_command" (fun () -> t.expand_command ~name ~arguments)

(* Attach has its own typed error, so it does not fold through [protect]'s
   [Mentat_protocol.Error]; an unexpected exception becomes [Unavailable]. *)
let attach t ~session source =
  match t.attach ~session source with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception _ ->
      Error
        (Mentat_protocol.Attach.Error.Unavailable
           (Mentat_diagnostic.make "attach failed unexpectedly"))

let answer_unattended t ~session:id ~decision =
  protect "answer_unattended" (fun () ->
      (session_cone t).Driver.Session.answer_unattended ~session:id ~decision)

let possibly_mutating t ~session:id =
  (session_cone t).Driver.Session.possibly_mutating ~session:id

let faulted t ~session:id = (session_cone t).Driver.Session.faulted ~session:id

(* Accounts. *)

let login ~sw t ~provider ~method_ =
  match
    protect "login" (fun () ->
        (accounts_cone t).Driver.Accounts.login ~provider ~method_)
  with
  | Error error -> Error error
  | Ok steps -> Ok (Login.attach ~sw steps)

let save_api_key t ~provider ~key =
  if String.is_empty key then Error Mentat_protocol.Error.Invalid_api_key
  else
    protect "save_api_key" (fun () ->
        (accounts_cone t).Driver.Accounts.save_api_key ~provider ~key)

let logout t ?(revoke = false) provider =
  protect "logout" (fun () ->
      (accounts_cone t).Driver.Accounts.logout ~revoke provider)

(* Settings. *)

let set_model t ~session:id ?reasoning_effort selector =
  protect "set_model" (fun () ->
      (settings_cone t).Driver.Settings.set_model ~session:id ?reasoning_effort
        selector)

let set_permission_review t ~session:id review =
  protect "set_permission_review" (fun () ->
      (settings_cone t).Driver.Settings.set_permission_review ~session:id review)

let set_default_model t ?reasoning_effort selector =
  protect "set_default_model" (fun () ->
      (settings_cone t).Driver.Settings.set_default_model ?reasoning_effort
        selector)

let set_ui_theme t theme =
  protect "set_ui_theme" (fun () ->
      (settings_cone t).Driver.Settings.set_ui_theme ~theme)

(* Session lifecycle. *)

let create t ~id ?title () =
  match title with
  | Some title when String.is_empty title ->
      Error Mentat_protocol.Error.Invalid_title
  | Some _ | None ->
      protect "create" (fun () ->
          (lifecycle_cone t).Driver.Lifecycle.create ~id ~title)

let rename t ~session:id ~title =
  if String.is_empty title then Error Mentat_protocol.Error.Invalid_title
  else
    protect "rename" (fun () ->
        (lifecycle_cone t).Driver.Lifecycle.rename ~session:id ~title)

let archive t ~session:id =
  protect "archive" (fun () ->
      (lifecycle_cone t).Driver.Lifecycle.archive ~session:id)

let restore t ~session:id =
  protect "restore" (fun () ->
      (lifecycle_cone t).Driver.Lifecycle.restore ~session:id)

let delete t ~session:id =
  protect "delete" (fun () ->
      (lifecycle_cone t).Driver.Lifecycle.delete ~session:id)

let fork t ~session:id ~into () =
  protect "fork" (fun () ->
      (session_cone t).Driver.Session.fork ~session:id ~into)

let rewind t ~session:id ~into ~anchor =
  protect "rewind" (fun () ->
      (session_cone t).Driver.Session.rewind ~session:id ~into ~anchor)

(* Manual compaction. *)

let compact t ~session:id ~turn =
  protect "compact" (fun () ->
      (session_cone t).Driver.Session.compact ~session:id ~turn)

(* Review. *)

let review t command =
  protect "review" (fun () -> (review_cone t).Driver.Review.apply command)

let review_compose t edit =
  protect "review_compose" (fun () ->
      (review_cone t).Driver.Review.compose edit)
