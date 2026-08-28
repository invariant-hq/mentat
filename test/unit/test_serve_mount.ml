(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit pins for [Serve_mount.confined]'s refusals — the one confinement
   door. The whole-cone refusal has no product client left to send it (the
   frontends answer those cones locally), so its byte text is pinned here:
   every non-session cone answers the same refusal, while the two
   session-scoped settings writes pass the membership guard through to the
   underlying driver. The member-guarded session cone and the foreign-id
   refusal live in the blackbox subagent suite, over a real endpoint. *)

open Windtrap
module Store = Mentat_store
module Session = Mentat_session
module Driver = Mentat_client.Driver

let sid = Session.Id.of_string
let unavailable message = Error (Mentat_protocol.Error.unavailable message)

(* A driver of markers: any field the confinement passes through answers
   [Ok]/its own marker; the refusal must therefore come from the wrapper,
   never from here. *)
let stub_driver () : Driver.t =
  let reached () = unavailable "reached the underlying driver" in
  {
    Driver.session =
      {
        Driver.Session.submit = (fun _ -> reached ());
        follow = (fun _ ~from:_ -> reached ());
        answer_unattended = (fun ~session:_ ~decision:_ -> reached ());
        possibly_mutating = (fun ~session:_ -> false);
        faulted = (fun ~session:_ -> None);
        fork = (fun ~session:_ ~into:_ -> reached ());
        rewind = (fun ~session:_ ~into:_ ~anchor:_ -> reached ());
        compact = (fun ~session:_ ~turn:_ -> reached ());
        pending_decision = (fun _ -> reached ());
        running_processes = (fun _ -> reached ());
        change_diff = (fun ~session:_ ~change:_ -> reached ());
        tail = (fun ?n:_ _ -> reached ());
        page = (fun ?n:_ _ ~before:_ -> reached ());
        revert = (fun ~session:_ ~scope:_ -> reached ());
        undo = (fun ~session:_ ~op:_ -> reached ());
        export = (fun ~session:_ -> reached ());
      };
    accounts =
      {
        Driver.Accounts.login = (fun ~provider:_ ~method_:_ -> reached ());
        save_api_key = (fun ~provider:_ ~key:_ -> reached ());
        logout = (fun ?revoke:_ _ -> reached ());
        account_readiness = (fun () -> reached ());
        model_readiness = (fun ?refresh:_ () -> reached ());
      };
    settings =
      {
        Driver.Settings.set_model =
          (fun ~session:_ ?reasoning_effort:_ _ -> Ok ());
        set_permission_review = (fun ~session:_ _ -> Ok ());
        configuration = (fun () -> reached ());
        set_default_model = (fun ?reasoning_effort:_ _ -> reached ());
        set_ui_theme = (fun ~theme:_ -> reached ());
      };
    lifecycle =
      {
        Driver.Lifecycle.create = (fun ~id:_ ~title:_ -> reached ());
        rename = (fun ~session:_ ~title:_ -> reached ());
        archive = (fun ~session:_ -> reached ());
        restore = (fun ~session:_ -> reached ());
        delete = (fun ~session:_ -> reached ());
        sessions = (fun ~listing:_ -> reached ());
        session = (fun _ -> reached ());
      };
    review =
      {
        Driver.Review.apply = (fun _ -> reached ());
        state = (fun ~scope:_ -> reached ());
        diff = (fun ~path:_ -> reached ());
        crs = (fun () -> reached ());
        compose = (fun _ -> reached ());
      };
    workspace =
      {
        Driver.Workspace.glance = (fun () -> reached ());
        dune = (fun () -> reached ());
        dune_control = (fun ~op:_ -> reached ());
      };
  }

let with_confined name fn =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let base = Unix.realpath (temp_dir ~prefix:("sm-" ^ name) ()) in
  Eio.Switch.run @@ fun sw ->
  let store =
    match Store.open_ ~sw (Eio.Path.( / ) fs base) with
    | Ok store -> store
    | Error error -> failf "open store: %a" Store.Error.pp error
  in
  let served = sid "served" in
  (match
     Store.Session.create store
       (Session.create ~id:served
          ~cwd:(Lpath.Abs.of_string_exn "/tmp")
          ~created_at:(Session.Time.of_unix_ms 1_000L) ())
   with
  | Ok (_ : Store.Session.Document.t) -> ()
  | Error error -> failf "create session: %a" Store.Session.Error.pp error);
  let cache = Serve_mount.Heads.create () in
  fn ~served (Serve_mount.confined ~store ~cache ~served (stub_driver ()))

let cone_refused_text =
  "this server serves one session; accounts, settings, lifecycle, review, \
   and workspace operations belong to its owner"

let refused ~msg = function
  | Ok _ -> failf "%s: the cone must be refused whole" msg
  | Error (Mentat_protocol.Error.Unavailable text) ->
      equal Testable.string ~msg cone_refused_text
        (Mentat_diagnostic.message text)
  | Error other ->
      failf "%s: expected the whole-cone refusal, got %a" msg
        Mentat_protocol.Error.pp other

let every_foreign_cone_answers_the_one_refusal () =
  with_confined "cones" @@ fun ~served:_ confined ->
  refused ~msg:"accounts"
    (confined.Driver.accounts.Driver.Accounts.account_readiness ());
  refused ~msg:"sessionless settings"
    (confined.Driver.settings.Driver.Settings.configuration ());
  refused ~msg:"lifecycle"
    (confined.Driver.lifecycle.Driver.Lifecycle.sessions
       ~listing:
         {
           Session.Listing.scope = `All;
           lifecycles = [ Session.Metadata.Status.Active ];
           search = None;
           limit = None;
         });
  refused ~msg:"review" (confined.Driver.review.Driver.Review.crs ());
  refused ~msg:"workspace"
    (confined.Driver.workspace.Driver.Workspace.glance ())

let the_two_settings_writes_pass_the_member_guard () =
  with_confined "door" @@ fun ~served confined ->
  (match
     confined.Driver.settings.Driver.Settings.set_permission_review
       ~session:served Mentat_permission.Review_behavior.Enforce
   with
  | Ok () -> ()
  | Error e ->
      failf "the served session's write must pass: %a" Mentat_protocol.Error.pp
        e);
  let selector =
    match Mentat_provider.Selector.of_string "openai/gpt-5" with
    | Ok selector -> selector
    | Error _ -> fail "the fixture selector must parse"
  in
  match confined.Driver.settings.Driver.Settings.set_default_model selector with
  | Ok () -> fail "the sessionless write must be refused"
  | Error (Mentat_protocol.Error.Unavailable text) ->
      equal Testable.string ~msg:"the sessionless settings refusal"
        cone_refused_text
        (Mentat_diagnostic.message text)
  | Error other ->
      failf "expected the whole-cone refusal, got %a" Mentat_protocol.Error.pp
        other

let () =
  run "mentat.serve-mount"
    [
      group "the confinement door"
        [
          test "every foreign cone answers the one refusal"
            every_foreign_cone_answers_the_one_refusal;
          test "the two settings writes pass the member guard"
            the_two_settings_writes_pass_the_member_guard;
        ];
    ]
