(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Server = Mentat_server
module Driver = Mentat_client.Driver
module Session = Mentat_session
module Protocol_error = Mentat_protocol.Error

let socket_dir t session =
  User_dirs.child_socket_dir
    (Composition.dirs t)
    ~session:(Session.Id.to_string session)

(* A raw connect probe — no handshake, so the probe never registers
   connection state on the agent's own idle accounting. A stale socket file a
   killed agent left refuses the connect, so it never answers serving. *)
let serving t session =
  let socket =
    Server.Bind.socket_path ~dir:(Lpath.Abs.of_string_exn (socket_dir t session))
  in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      match Unix.connect fd (Unix.ADDR_UNIX socket) with
      | () -> true
      | exception Unix.Unix_error _ -> false)

(* The environment a started agent boots under: the composition's snapshot
   with the caller's overrides replacing same-named variables. *)
let spawn_environment t overrides =
  let base =
    List.filter
      (fun (name, _) -> not (List.mem_assoc name overrides))
      (Composition.environment t)
  in
  base @ overrides

let connect t session =
  Server.connect ~sw:(Composition.sw t)
    ~net:(Eio.Stdenv.net (Composition.stdenv t))
    ~clock:(Eio.Stdenv.clock (Composition.stdenv t))
    ~workspace:(Lpath.Abs.to_string (Composition.root t))
    ~environment:(Composition.environment t)
    (Server.Bind.unix ~dir:(Lpath.Abs.of_string_exn (socket_dir t session)))

(* The per-session attach-or-start router. One ensure at a time per session
   (concurrent frontend fibers collapse to one start); the connected wire
   driver is cached per session — each of its calls dials fresh, so a cached
   value stays valid across agent generations on the same socket path. *)
type router = {
  t : Composition.t;
  environment_overrides : (string * string) list;
  drivers : (string, Driver.t) Hashtbl.t;
  locks : (string, Eio.Mutex.t) Hashtbl.t;
}

let lock_for router session =
  let key = Session.Id.to_string session in
  match Hashtbl.find_opt router.locks key with
  | Some lock -> lock
  | None ->
      let lock = Eio.Mutex.create () in
      Hashtbl.replace router.locks key lock;
      lock

let connected router session =
  let key = Session.Id.to_string session in
  match Hashtbl.find_opt router.drivers key with
  | Some driver -> Ok driver
  | None -> (
      match connect router.t session with
      | Ok driver ->
          Hashtbl.replace router.drivers key driver;
          Ok driver
      | Error error ->
          Error
            (Protocol_error.unavailable
               (Format.asprintf "session %a: its agent did not answer: %a"
                  Session.Id.pp session Server.Error.pp error)))

(* Attach-or-start, then hand the session's wire driver to [f]. The probe
   before every call keeps the router honest about an agent that idled out
   between calls: the next call starts a fresh one. *)
let with_agent router session f =
  let ensure () =
    Eio.Mutex.use_rw ~protect:false (lock_for router session) (fun () ->
        if serving router.t session then Ok ()
        else
          match
            Mentat_broker.serve
              (Composition.broker router.t)
              ~session
              ~environment:
                (spawn_environment router.t router.environment_overrides)
              ()
          with
          | `Serving -> Ok ()
          | `Refused reason ->
              Error
                (Protocol_error.unavailable
                   (Format.asprintf "session %a: %s" Session.Id.pp session
                      reason)))
  in
  match ensure () with
  | Error e -> Error e
  | Ok () -> ( match connected router session with
    | Error e -> Error e
    | Ok driver -> f driver)

(* A read whose truthful dormant answer is already known dials only a live
   agent and never starts one: no agent means no driver-held state to ask
   about. *)
let with_live_agent router session ~dormant f =
  if not (serving router.t session) then dormant
  else match connected router session with Error _ -> dormant | Ok d -> f d

let session_cone router : Driver.Session.t =
  let route session f = with_agent router session f in
  {
    Driver.Session.submit =
      (fun command ->
        route (Mentat_protocol.Command.session command) (fun d ->
            d.Driver.session.Driver.Session.submit command));
    follow =
      (fun session ~from ->
        route session (fun d -> d.Driver.session.Driver.Session.follow session ~from));
    answer_unattended =
      (fun ~session ~decision ->
        route session (fun d ->
            d.Driver.session.Driver.Session.answer_unattended ~session ~decision));
    possibly_mutating =
      (fun ~session ->
        with_live_agent router session ~dormant:false (fun d ->
            d.Driver.session.Driver.Session.possibly_mutating ~session));
    faulted =
      (fun ~session ->
        with_live_agent router session ~dormant:None (fun d ->
            d.Driver.session.Driver.Session.faulted ~session));
    fork =
      (fun ~session ~into ->
        route session (fun d ->
            d.Driver.session.Driver.Session.fork ~session ~into));
    rewind =
      (fun ~session ~into ~anchor ->
        route session (fun d ->
            d.Driver.session.Driver.Session.rewind ~session ~into ~anchor));
    compact =
      (fun ~session ~turn ->
        route session (fun d ->
            d.Driver.session.Driver.Session.compact ~session ~turn));
    pending_decision =
      (fun session ->
        (* A parked decision is durable, so a dormant session answers from
           the journal without starting an agent — a reply against a live
           agent still asks it, and its recovery already reconstructed the
           park. *)
        with_live_agent router session
          ~dormant:
            (match
               Mentat_store.Session.load (Composition.store router.t) session
             with
            | Error e ->
                Error (Session_meta.session_store_error_to_protocol session e)
            | Ok doc -> (
                match
                  Session.State.suspension
                    (Session.state (Mentat_store.Session.Document.session doc))
                with
                | Some (Session.State.Decision requested) -> Ok (Some requested)
                | Some (Session.State.Provider _ | Session.State.Tool _)
                | None ->
                    Ok None))
          (fun d -> d.Driver.session.Driver.Session.pending_decision session));
    running_processes =
      (fun session ->
        with_live_agent router session ~dormant:(Ok []) (fun d ->
            d.Driver.session.Driver.Session.running_processes session));
    change_diff =
      (fun ~session ~change ->
        route session (fun d ->
            d.Driver.session.Driver.Session.change_diff ~session ~change));
    tail =
      (fun ?n session ->
        route session (fun d -> d.Driver.session.Driver.Session.tail ?n session));
    page =
      (fun ?n session ~before ->
        route session (fun d ->
            d.Driver.session.Driver.Session.page ?n session ~before));
    revert =
      (fun ~session ~scope ->
        route session (fun d ->
            d.Driver.session.Driver.Session.revert ~session ~scope));
    undo =
      (fun ~session ~op ->
        route session (fun d -> d.Driver.session.Driver.Session.undo ~session ~op));
    export =
      (fun ~session ->
        route session (fun d -> d.Driver.session.Driver.Session.export ~session));
  }

(* The two session-scoped settings writes ride the wire to the session's
   agent — the overlays they install are process-local to the driving
   process, and the agent's confined endpoint admits exactly these two. *)
let settings_cone router (cones : Composition.daemon_cones) : Driver.Settings.t =
  {
    cones.Composition.settings with
    Driver.Settings.set_model =
      (fun ~session ?reasoning_effort selector ->
        with_agent router session (fun d ->
            d.Driver.settings.Driver.Settings.set_model ~session
              ?reasoning_effort selector));
    set_permission_review =
      (fun ~session behavior ->
        with_agent router session (fun d ->
            d.Driver.settings.Driver.Settings.set_permission_review ~session
              behavior));
  }

let driver ?(environment_overrides = []) t =
  Result.map
    (fun (cones : Composition.daemon_cones) ->
      let router =
        {
          t;
          environment_overrides;
          drivers = Hashtbl.create 4;
          locks = Hashtbl.create 4;
        }
      in
      {
        Driver.session = session_cone router;
        accounts = cones.Composition.accounts;
        settings = settings_cone router cones;
        lifecycle = cones.Composition.lifecycle;
        review = cones.Composition.review;
        workspace = cones.Composition.workspace;
      })
    (Composition.daemon_cones t)

let client ?environment_overrides t =
  Result.map (Composition.attach_client t) (driver ?environment_overrides t)

let client_with_tui_capabilities t =
  match client t with
  | Error status -> Error status
  | Ok client -> (
      match Composition.tui_capabilities t with
      | Error status -> Error status
      | Ok (read_capability, shell) -> Ok (client, read_capability, shell))
