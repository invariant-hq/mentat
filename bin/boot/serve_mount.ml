(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Server = Mentat_server
module Store = Mentat_store
module Session = Mentat_session
module Driver = Mentat_client.Driver

let log_src =
  Logs.Src.create "mentat.serve-mount" ~doc:"The per-session serve mount"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* One cached, stamp-elided, fence-free read of a session's durable head:
   whether it is settled with an empty queue, and its recorded delegation
   children. [None] when the stamp or the journal cannot be read —
   outstanding work is presumed. The stamp elision means the polls built on
   this decode a journal only when its persisted bytes have changed. *)
module Heads = struct
  type t = (string, string * bool * Session.Id.t list) Hashtbl.t

  let create () : t = Hashtbl.create 8

  let summary ~store (cache : t) child =
    let id = Session.Id.to_string child in
    match Store.Session.stamp store child with
    | None -> None
    | Some stamp -> (
        match Hashtbl.find_opt cache id with
        | Some (cached, settled, children) when String.equal cached stamp ->
            Some (settled, children)
        | Some _ | None -> (
            match Store.Session.load store child with
            | Error _ -> None
            | Ok doc ->
                let state =
                  Session.state (Store.Session.Document.session doc)
                in
                let settled = Session.State.finished state in
                let children =
                  List.map Session.Delegation.child
                    (Session.State.delegations state)
                in
                Hashtbl.replace cache id (stamp, settled, children);
                Some (settled, children)))
end

(* Whether [target] lies in the served session's delegation subtree: [root]
   itself, or a session reachable from it through recorded delegation edges.
   Journal truth decides — an edge not yet durable is not yet served, and the
   caller retries once it is. The [seen] set bounds the walk: ids are
   parent-minted, so an uncorrupted tree is finite, and a corrupt journal
   naming an ancestor edge must not recurse forever. *)
let member ~store cache ~root target =
  let rec go seen id =
    Session.Id.equal id target
    || (not (Hashtbl.mem seen (Session.Id.to_string id))
       && begin
            Hashtbl.replace seen (Session.Id.to_string id) ();
            match Heads.summary ~store cache id with
            | None -> false
            | Some (_, children) -> List.exists (go seen) children
          end)
  in
  go (Hashtbl.create 8) root

(* The one-session confinement, making the man page's claim a code fact. The
   session cone answers only for the served session's own delegation
   subtree — the only sessions this endpoint can speak for; a foreign session
   id is refused, never resolved against the shared store. Every other cone —
   accounts, settings, lifecycle, review, workspace — is refused whole: a
   per-session endpoint exists to drive one session, not to reach the user's
   accounts, configuration, or session index. *)
let confined ~store ~cache ~served (driver : Driver.t) : Driver.t =
  let foreign session =
    Mentat_protocol.Error.unavailable
      (Printf.sprintf
         "this server serves session %s and its delegation subtree, not %s"
         (Session.Id.to_string served)
         (Session.Id.to_string session))
  in
  let admit session k =
    if member ~store cache ~root:served session then k ()
    else Error (foreign session)
  in
  let cone_refused () =
    Error
      (Mentat_protocol.Error.unavailable
         "this server serves one session; accounts, settings, lifecycle, \
          review, and workspace operations belong to its owner")
  in
  let s = driver.Driver.session in
  let session : Driver.Session.t =
    {
      Driver.Session.submit =
        (fun command ->
          let session = Mentat_protocol.Command.session command in
          admit session (fun () -> s.Driver.Session.submit command));
      follow =
        (fun session ~from ->
          admit session (fun () -> s.Driver.Session.follow session ~from));
      answer_unattended =
        (fun ~session ~decision ->
          admit session (fun () ->
              s.Driver.Session.answer_unattended ~session ~decision));
      possibly_mutating =
        (fun ~session ->
          member ~store cache ~root:served session
          && s.Driver.Session.possibly_mutating ~session);
      faulted =
        (fun ~session ->
          if member ~store cache ~root:served session then
            s.Driver.Session.faulted ~session
          else None);
      fork =
        (fun ~session ~into ->
          admit session (fun () -> s.Driver.Session.fork ~session ~into));
      rewind =
        (fun ~session ~into ~anchor ->
          admit session (fun () ->
              s.Driver.Session.rewind ~session ~into ~anchor));
      compact =
        (fun ~session ~turn ->
          admit session (fun () -> s.Driver.Session.compact ~session ~turn));
      pending_decision =
        (fun session ->
          admit session (fun () -> s.Driver.Session.pending_decision session));
      running_processes =
        (fun session ->
          admit session (fun () -> s.Driver.Session.running_processes session));
      change_diff =
        (fun ~session ~change ->
          admit session (fun () ->
              s.Driver.Session.change_diff ~session ~change));
      tail =
        (fun ?n session ->
          admit session (fun () -> s.Driver.Session.tail ?n session));
      page =
        (fun ?n session ~before ->
          admit session (fun () -> s.Driver.Session.page ?n session ~before));
      revert =
        (fun ~session ~scope ->
          admit session (fun () -> s.Driver.Session.revert ~session ~scope));
      undo =
        (fun ~session ~op ->
          admit session (fun () -> s.Driver.Session.undo ~session ~op));
      export =
        (fun ~session ->
          admit session (fun () -> s.Driver.Session.export ~session));
    }
  in
  let accounts : Driver.Accounts.t =
    {
      Driver.Accounts.login = (fun ~provider:_ ~method_:_ -> cone_refused ());
      save_api_key = (fun ~provider:_ ~key:_ -> cone_refused ());
      logout = (fun ?revoke:_ _ -> cone_refused ());
      account_readiness = (fun () -> cone_refused ());
      model_readiness = (fun ?refresh:_ () -> cone_refused ());
    }
  in
  let settings : Driver.Settings.t =
    {
      Driver.Settings.set_model =
        (fun ~session:_ ?reasoning_effort:_ _ -> cone_refused ());
      set_permission_review = (fun ~session:_ _ -> cone_refused ());
      configuration = (fun () -> cone_refused ());
      set_default_model = (fun ?reasoning_effort:_ _ -> cone_refused ());
      set_ui_theme = (fun ~theme:_ -> cone_refused ());
    }
  in
  let lifecycle : Driver.Lifecycle.t =
    {
      Driver.Lifecycle.create = (fun ~id:_ ~title:_ -> cone_refused ());
      rename = (fun ~session:_ ~title:_ -> cone_refused ());
      archive = (fun ~session:_ -> cone_refused ());
      restore = (fun ~session:_ -> cone_refused ());
      delete = (fun ~session:_ -> cone_refused ());
      sessions = (fun ~listing:_ -> cone_refused ());
      session = (fun _ -> cone_refused ());
    }
  in
  let review : Driver.Review.t =
    {
      Driver.Review.apply = (fun _ -> cone_refused ());
      state = (fun ~scope:_ -> cone_refused ());
      diff = (fun ~path:_ -> cone_refused ());
      crs = (fun () -> cone_refused ());
      compose = (fun _ -> cone_refused ());
    }
  in
  let workspace : Driver.Workspace.t =
    { Driver.Workspace.glance = (fun () -> cone_refused ()) }
  in
  { Driver.session; accounts; settings; lifecycle; review; workspace }

(* One session, one workspace: a handshake binds only this endpoint's root,
   and the offered environment is ignored — the serving instance keeps the
   environment it booted with, exactly as a live daemon instance does. *)
let driver_for ~root ~driver ~active ~workspace ~environment:_ =
  match workspace with
  | Some w when String.equal w root ->
      Atomic.incr active;
      Ok
        {
          Server.workspace = Some root;
          driver;
          on_close = (fun () -> Atomic.decr active);
        }
  | Some w ->
      Error
        (Mentat_protocol.Error.unavailable
           (Printf.sprintf "this server serves %s, not %s" root w))
  | None ->
      Error
        (Mentat_protocol.Error.unavailable
           "bind a workspace: this server serves one session's workspace")

(* The per-session socket home is two levels below the socket base; the
   server's listen hardens only its leaf, so the parents are created (0700)
   here. *)
let ensure_socket_parents dir =
  let mkdir path =
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  in
  let parent = Filename.dirname dir in
  mkdir (Filename.dirname parent);
  mkdir parent

let remove_socket dir =
  Server.Bind.remove_endpoint ~dir:(Lpath.Abs.of_string_exn dir)

(* Transitional (it dies with the in-process drivers it bridges): serve the
   driven session's derived socket beside its driver. The bind runs
   synchronously so a failure answers [None] here and now; the serve loop and
   its stop race ride one fiber under the caller's switch. The socket file
   itself is unlinked by the listener's teardown at switch close — removing
   the endpoint here would make that teardown fail on the missing entry — so
   an unmounted session may leave an empty endpoint leaf directory behind,
   which the broker's rediscovery sweep already tolerates and disposes. *)
let mount ~sw ~stdenv ~store ~dirs ~driver ~root ~session =
  let id = Session.Id.to_string session in
  let dir = User_dirs.child_socket_dir dirs ~session:id in
  match
    ensure_socket_parents dir;
    Server.listen ~sw
      ~net:(Eio.Stdenv.net stdenv)
      (Server.Bind.unix ~dir:(Lpath.Abs.of_string_exn dir))
  with
  | exception exn ->
      Log.warn (fun m ->
          m "serve-mount for session %s did not bind: %s" id
            (Printexc.to_string exn));
      None
  | listener ->
      let stop, resolve_stop = Eio.Promise.create () in
      let cache = Heads.create () in
      let confined = confined ~store ~cache ~served:session driver in
      let active = Atomic.make 0 in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Fiber.first
            (fun () ->
              (* The short keep-alive matches the per-session child server:
                 an idle stream notices its peer's disconnect only at the
                 next heartbeat write. *)
              Server.serve ~sw
                ~clock:(Eio.Stdenv.clock stdenv)
                ~heartbeat_s:1.0
                ~driver_for:
                  (driver_for
                     ~root:(Lpath.Abs.to_string root)
                     ~driver:confined ~active)
                listener)
            (fun () -> Eio.Promise.await stop));
      Some (fun () -> ignore (Eio.Promise.try_resolve resolve_stop ()))
