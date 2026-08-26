(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Server = Mentat_server
module Client = Mentat_client
module Store = Mentat_store
module Session = Mentat_session
module Command = Mentat_protocol.Command

(* Every timing constant in one place. The boot wait bounds only how long a
   spawned child may take to bind its endpoint before the ladder treats it as
   wedged (a cold serve-session boot stages a full composition; tens of
   seconds is generous without deferring a real wedge forever). The grace is
   the pause between escalation rungs. Re-materialization is bounded at two
   respawns beyond the first spawn — enough to ride out one unlucky crash plus
   one, where an unbounded retry would grind a deterministic boot failure
   forever and a bound of zero would fail the whole delegation on a single
   stray SIGKILL. *)
let boot_wait_s = 30.0
let grace_s = 5.0
let max_respawns = 2
let reap_interval_s = 0.05

module Reconcile = struct
  type fence = [ `Free | `Held_self | `Held of int option | `Io of string ]
  type head = [ `Unfinished | `Terminal | `Absent ]

  type action =
    | Observe
    | Preempt of int
    | Respawn
    | Dispose
    | Stand_down
    | Fail of string

  let decide ~fence ~reachable ~head =
    match fence () with
    | `Io message -> Fail ("the run fence could not be probed: " ^ message)
    | `Held_self -> Stand_down
    | `Held holder -> (
        if reachable () then Observe
        else
          match holder with
          | Some pid -> Preempt pid
          | None ->
              Fail
                "the run fence is held by a process this node can neither \
                 reach nor signal")
    | `Free -> (
        match head () with
        | `Unfinished -> Respawn
        | `Terminal | `Absent -> Dispose)

  type boot =
    [ `Adopt
    | `Adopt_and_watch
    | `Watch
    | `Adopt_and_dispose
    | `Dispose
    | `Skip of string ]

  let boot_action ~fence ~head ~parent =
    match (fence, head, parent) with
    | `Io, _, _ -> `Skip "the run fence could not be probed"
    | _, _, `Absent -> (
        match fence with
        | `Free -> `Dispose
        | `Held | `Io -> `Skip "an orphan with no parent integrates nowhere")
    | `Held, _, `Waiting -> `Adopt_and_watch
    | `Held, _, `Idle -> `Watch
    | `Free, `Unfinished, _ -> `Adopt
    | `Free, (`Terminal | `Absent), `Waiting -> `Adopt_and_dispose
    | `Free, (`Terminal | `Absent), `Idle -> `Dispose
end

(* One materialized or observed child. [pid] is [Some] only for a process this
   broker spawned — the reaper's set; a foreign child (a previous node life's
   server) is watched through its endpoint and fence instead. [respawns]
   counts spawns beyond the first. *)
type entry = {
  child : Session.Id.t;
  instance : Composition.t;
  socket_dir : string;
  mutable pid : int option;
  mutable respawns : int;
  mutable cancelled : bool;
}

type t = {
  sw : Eio.Switch.t;
  shared : Composition.shared;
  entries : (string, entry) Hashtbl.t;
  stop_signal : unit Eio.Promise.t;
  stop_resolver : unit Eio.Promise.u;
  mutable stopped : bool;
}

let key child = Session.Id.to_string child
let clock t = Eio.Stdenv.clock t.shared.Composition.stdenv
let net t = Eio.Stdenv.net t.shared.Composition.stdenv
let sleep t seconds = Eio.Time.sleep (clock t) seconds

(* An entry is current while it is the table's binding for its child. A
   re-materialization installs a fresh entry, so a stale fiber's guard fails by
   physical identity, not by name. *)
let current t entry =
  match Hashtbl.find_opt t.entries (key entry.child) with
  | Some registered -> registered == entry
  | None -> false

let send_signal pid signal =
  try Unix.kill pid signal with Unix.Unix_error _ -> ()

(* Map the fence probe onto the table's vocabulary. Identity mapping lives
   here, not in the table: [`Held (Some pid)] only for a same-host holder that
   is not this process — the only pid a signal from here can meaningfully
   reach — and this process's own hold (an in-process driver) is its own arm. *)
let probe_fence t entry () : Reconcile.fence =
  match
    Store.Run_lock.holder t.shared.Composition.store ~session:entry.child
  with
  | `Free -> `Free
  | `Io io -> `Io (Format.asprintf "%a" Store.Io.pp io)
  | `Held None -> `Held None
  | `Held (Some owner) ->
      let pid = Store.Run_lock.Owner.pid owner in
      if pid = Unix.getpid () then `Held_self
      else if String.equal (Store.Run_lock.Owner.host owner) (Unix.gethostname ())
      then `Held (Some pid)
      else `Held None

let root_string entry = Lpath.Abs.to_string (Composition.root entry.instance)

let head_of session : Reconcile.head =
  let state = Session.state session in
  match Session.State.turns state with
  | [] -> `Unfinished
  | _ ->
      if Option.is_some (Session.State.active_turn state) then `Unfinished
      else `Terminal

(* A fence-free head read; an unreadable journal presumes outstanding work, so
   the caller keeps watching rather than abandoning a child it cannot judge. *)
let child_head t entry : Reconcile.head =
  match Store.Session.load t.shared.Composition.store entry.child with
  | Error _ -> `Unfinished
  | Ok document -> head_of (Store.Session.Document.session document)

let connect_child t entry ~sw =
  Server.connect ~sw ~net:(net t) ~clock:(clock t)
    ~workspace:(root_string entry)
    (Server.Bind.unix ~dir:(Lpath.Abs.of_string_exn entry.socket_dir))

(* A scoped reachability probe: one throwaway handshake, resources torn down
   with the scope. *)
let endpoint_reachable t entry () =
  match
    Eio.Switch.run @@ fun sw ->
    match connect_child t entry ~sw with Ok _ -> true | Error _ -> false
  with
  | reachable -> reachable
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> false

let remove_endpoint entry =
  (* Best-effort residue removal, mirroring the child's own clean-exit
     removal; a directory that resists stays as diagnosable residue. *)
  (try Unix.unlink (Filename.concat entry.socket_dir "mentat.sock")
   with Unix.Unix_error _ -> ());
  try Unix.rmdir entry.socket_dir with Unix.Unix_error _ -> ()

let give_up t entry message =
  if current t entry then begin
    Hashtbl.remove t.entries (key entry.child);
    Eio.traceln "mentatd: delegation to %s abandoned: %s" (key entry.child)
      message;
    Composition.fail_child entry.instance ~child:entry.child ~message
  end

(* The escalation ladder for a child this broker spawned. Each signal is sent
   in the same non-suspending step as its liveness check, and the reaper
   clears [pid] in the same non-suspending step that observes an exit, so a
   signal can never chase a reaped — possibly recycled — pid. *)
let ladder_own t entry pid =
  let alive () = current t entry && entry.pid = Some pid in
  let rec await_dead elapsed =
    if not (alive ()) then true
    else if elapsed >= grace_s then false
    else begin
      sleep t 0.1;
      await_dead (elapsed +. 0.1)
    end
  in
  if alive () then send_signal pid Sys.sigterm;
  if not (await_dead 0.) then if alive () then send_signal pid Sys.sigkill

(* The ladder for a foreign holder: liveness is the fence itself — held means
   the holder is alive and the owner line's pid is its self-report at acquire,
   so a re-probe immediately before each rung keeps the signal off a recycled
   pid. Returns whether the fence came free. *)
let ladder_foreign t entry pid =
  let rec await_free elapsed =
    match probe_fence t entry () with
    | `Free -> true
    | _ when elapsed >= grace_s -> false
    | _ ->
        sleep t 0.25;
        await_free (elapsed +. 0.25)
  in
  send_signal pid Sys.sigterm;
  if await_free 0. then true
  else begin
    (match probe_fence t entry () with
    | `Held (Some current_pid) when current_pid = pid ->
        send_signal pid Sys.sigkill
    | _ -> ());
    await_free 0.
  end

(* Best-effort semantic interrupt over the child's endpoint. *)
let wire_interrupt t entry =
  match
    Command.interrupt ~session:entry.child ~reason:"parent interrupted" ()
  with
  | Error _ -> ()
  | Ok command -> (
      match
        Eio.Switch.run @@ fun sw ->
        match connect_child t entry ~sw with
        | Error _ -> ()
        | Ok driver ->
            ignore
              (driver.Client.Driver.session.Client.Driver.Session.submit
                 command)
      with
      | () -> ()
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception _ -> ())

(* One connect-and-follow pass over the child's feed, ending — connection and
   all — as soon as one settlement has integrated: the child's server lingers
   only while no connection is open, so an observer that kept following would
   pin the child alive forever. What settles after the feed closes is
   re-derived at the child's exit by the same integration, so nothing is lost
   to the early close. *)
let follow_feed t entry =
  match
    Eio.Switch.run @@ fun sw ->
    match connect_child t entry ~sw with
    | Error _ -> ()
    | Ok driver -> (
        if entry.cancelled then wire_interrupt t entry;
        match
          driver.Client.Driver.session.Client.Driver.Session.follow entry.child
            ~from:`Beginning
        with
        | Error _ -> ()
        | Ok seam ->
            let rec pull () =
              match seam.Client.Feed.next () with
              | Ok
                  (Client.Feed.Item
                     (Mentat_protocol.Update.Committed
                        { fact = Mentat_protocol.Fact.Turn_settled _; _ })) -> (
                  match
                    Composition.integrate_child entry.instance
                      ~child:entry.child
                  with
                  | `Integrated | `Unbound -> ()
                  | `Not_settled -> pull ())
              | Ok (Client.Feed.Item _) -> pull ()
              | Ok Client.Feed.Closed | Error _ -> ()
            in
            (* The close releases the stream's fiber; without it the scope's
               teardown would wait on a reader parked in the wire feed. *)
            Fun.protect
              ~finally:(fun () -> seam.Client.Feed.close ())
              pull)
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> ()

(* The exit policy — the one funnel for "the child's process is gone": the
   reaper's reap of an own child, and the fence coming free under a foreign
   one. Integration is re-derived from journals, so running it after an
   already-observed settlement is a harmless repeat; a child that died before
   settling is re-materialized under the bounded budget, and past it the
   delegation fails loudly. The entry is detached before any suspending work
   so a concurrent re-drive materializes against a clean slate. *)
let rec exit_policy t entry =
  if current t entry then begin
    Hashtbl.remove t.entries (key entry.child);
    match Composition.integrate_child entry.instance ~child:entry.child with
    | `Integrated | `Unbound -> remove_endpoint entry
    | `Not_settled ->
        if entry.respawns >= max_respawns then begin
          remove_endpoint entry;
          let message =
            Printf.sprintf
              "the child process died before settling, %d times over"
              (entry.respawns + 1)
          in
          Eio.traceln "mentatd: delegation to %s abandoned: %s"
            (key entry.child) message;
          Composition.fail_child entry.instance ~child:entry.child ~message
        end
        else begin
          entry.pid <- None;
          entry.respawns <- entry.respawns + 1;
          Hashtbl.replace t.entries (key entry.child) entry;
          spawn_child t entry
        end
  end

and spawn_child t entry =
  match
    Child_spawn.spawn t.shared.Composition.dirs
      ~environment:(Composition.environment entry.instance)
      ~session:entry.child
      ~cwd:(Composition.root entry.instance)
  with
  | Error message -> give_up t entry message
  | Ok pid ->
      entry.pid <- Some pid;
      observe t entry

(* Observation: wait for the endpoint, then follow the feed until the stream
   ends. An own child's exit is the reaper's to see; a foreign child's exit is
   the fence coming free — while it stays held the holder is alive, so a
   broken stream reconnects on a short backoff (a wedged holder that never
   settles is observed for as long as it holds the fence; stopping it is the
   cancel escalation's job, not a broker timeout). *)
and observe t entry =
  let socket = Filename.concat entry.socket_dir "mentat.sock" in
  let rec await_endpoint elapsed =
    if not (current t entry) then `Gone
    else if Sys.file_exists socket then `Ready
    else if elapsed >= boot_wait_s then `Timeout
    else begin
      sleep t 0.05;
      await_endpoint (elapsed +. 0.05)
    end
  in
  match await_endpoint 0. with
  | `Gone -> ()
  | `Timeout -> (
      match entry.pid with
      | Some pid ->
          Eio.traceln "mentatd: child %s never bound its endpoint; escalating"
            (key entry.child);
          ladder_own t entry pid
          (* The reaper observes the exit and runs the policy. *)
      | None -> foreign_watch t entry)
  | `Ready -> (
      follow_feed t entry;
      if current t entry then
        match entry.pid with
        | Some _ -> () (* the reaper owns an own child's exit *)
        | None -> foreign_watch t entry)

and foreign_watch t entry =
  if current t entry then
    match probe_fence t entry () with
    | `Free -> exit_policy t entry
    | `Held_self ->
        (* An in-process driver took the child over (a message delivery
           attached it); its own hooks integrate from here. *)
        Hashtbl.remove t.entries (key entry.child)
    | `Held _ | `Io _ -> (
        sleep t 1.0;
        (* Reconnect only while work is outstanding: a settled child is
           lingering toward its own exit, and a fresh connection would reset
           that linger — the fence poll alone sees it out. *)
        match child_head t entry with
        | `Unfinished -> observe t entry
        | `Terminal | `Absent -> foreign_watch t entry)

(* Materialization: the pure table decides over live probes; the engine has
   already ruled the child unfinished, so the head probe is constant. *)
let launch t entry =
  match
    Reconcile.decide ~fence:(probe_fence t entry)
      ~reachable:(endpoint_reachable t entry)
      ~head:(fun () -> `Unfinished)
  with
  | Reconcile.Observe -> observe t entry
  | Reconcile.Preempt pid ->
      Eio.traceln
        "mentatd: child %s is fenced by pid %d with no endpoint; preempting"
        (key entry.child) pid;
      if ladder_foreign t entry pid then spawn_child t entry
      else
        give_up t entry
          (Printf.sprintf "pid %d holds the child's fence and would not yield"
             pid)
  | Reconcile.Respawn -> spawn_child t entry
  | Reconcile.Dispose | Reconcile.Stand_down ->
      Hashtbl.remove t.entries (key entry.child)
  | Reconcile.Fail message -> give_up t entry message

(* Fiber discipline: broker work runs under the node switch, races the stop
   signal so teardown never waits on a parked feed pull, and contains its own
   failures — an unexpected raise fails the one delegation loudly instead of
   tearing the node down or, worse, parking the parent silently. *)
let fork_entry t entry work =
  if not t.stopped then
    Eio.Fiber.fork ~sw:t.sw (fun () ->
        Eio.Fiber.first
          (fun () -> Eio.Promise.await t.stop_signal)
          (fun () ->
            try work () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                give_up t entry
                  ("the broker failed unexpectedly: " ^ Printexc.to_string exn)))

let materialize t instance ~child ~delegation:_ =
  if not t.stopped then
    match Hashtbl.find_opt t.entries (key child) with
    | Some _ -> ()
    | None ->
        let entry =
          {
            child;
            instance;
            socket_dir =
              User_dirs.child_socket_dir t.shared.Composition.dirs
                ~session:(key child);
            pid = None;
            respawns = 0;
            cancelled = false;
          }
        in
        Hashtbl.replace t.entries (key child) entry;
        fork_entry t entry (fun () -> launch t entry)

(* Watch an already-running child this broker did not spawn (a previous node
   life's server): register the entry and observe, deciding nothing else — on
   its exit the ordinary policy integrates, re-drives shadowed messages, or
   re-materializes. A child the ordinary materialize already registered is left
   to it. *)
let watch t instance ~child =
  if not t.stopped then
    match Hashtbl.find_opt t.entries (key child) with
    | Some _ -> ()
    | None ->
        let entry =
          {
            child;
            instance;
            socket_dir =
              User_dirs.child_socket_dir t.shared.Composition.dirs
                ~session:(key child);
            pid = None;
            respawns = 0;
            cancelled = false;
          }
        in
        Hashtbl.replace t.entries (key child) entry;
        fork_entry t entry (fun () -> observe t entry)

let cancel t ~child =
  match Hashtbl.find_opt t.entries (key child) with
  | None -> ()
  | Some entry ->
      entry.cancelled <- true;
      fork_entry t entry (fun () ->
          wire_interrupt t entry;
          let rec await_gone elapsed =
            if not (current t entry) then true
            else if elapsed >= grace_s then false
            else begin
              sleep t 0.25;
              await_gone (elapsed +. 0.25)
            end
          in
          if not (await_gone 0.) then
            match entry.pid with
            | Some pid -> ladder_own t entry pid
            | None -> (
                match probe_fence t entry () with
                | `Held (Some pid) -> ignore (ladder_foreign t entry pid)
                | `Free | `Held_self | `Held None | `Io _ -> ()))

let ops t instance =
  {
    Mentat_agent.Ports.materialize =
      (fun ~child ~delegation -> materialize t instance ~child ~delegation);
    cancel = (fun ~child -> cancel t ~child);
  }

(* The reaper: one fiber per broker sweeping the spawned-pid set with
   [WNOHANG] on a short cadence. The sweep itself never suspends — each exit
   clears [pid] in the same step that observes it — and the suspending exit
   policies run only after the sweep. Detection latency is bounded by the
   cadence; settlement latency is not, because the live path is the feed
   observer. *)
let reap_sweep t =
  let exited =
    Hashtbl.fold
      (fun _ entry acc ->
        match entry.pid with
        | None -> acc
        | Some pid -> (
            match Unix.waitpid [ Unix.WNOHANG ] pid with
            | 0, _ -> acc
            | _, _ ->
                entry.pid <- None;
                entry :: acc
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> acc
            | exception Unix.Unix_error _ ->
                entry.pid <- None;
                entry :: acc))
      t.entries []
  in
  List.iter (fun entry -> exit_policy t entry) exited

let run_reaper t =
  let rec loop () =
    if not t.stopped then begin
      (try reap_sweep t with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Eio.traceln "mentatd: the reaper failed: %s" (Printexc.to_string exn));
      sleep t reap_interval_s;
      loop ()
    end
  in
  loop ()

let create ~sw shared =
  let stop_signal, stop_resolver = Eio.Promise.create () in
  let t =
    {
      sw;
      shared;
      entries = Hashtbl.create 8;
      stop_signal;
      stop_resolver;
      stopped = false;
    }
  in
  Eio.Fiber.fork ~sw (fun () -> run_reaper t);
  t

let stop t =
  t.stopped <- true;
  ignore (Eio.Promise.try_resolve t.stop_resolver ())

(* Node-boot rediscovery. Candidate enumeration and disposal live here; every
   probe-and-spawn decision for a candidate that needs one is taken by the
   ordinary materialize path, reached through the adopted parent's recovery —
   one spawn path, probed once. *)

let rediscover t ~instance_for ~release =
  let dirs = t.shared.Composition.dirs in
  let store = t.shared.Composition.store in
  let leaf_root = Filename.concat (User_dirs.daemon_socket_dir dirs) "s" in
  let leaves =
    match Sys.readdir leaf_root with
    | entries -> Array.to_list entries
    | exception Sys_error _ -> []
  in
  match Store.Session.scan store with
  | Error error ->
      Eio.traceln "mentatd: orphan rediscovery skipped: %s"
        (Store.Session.Error.message error)
  | Ok (documents, _corrupt) ->
      let sessions = Hashtbl.create 16 in
      List.iter
        (fun document ->
          let session = Store.Session.Document.session document in
          Hashtbl.replace sessions
            (Session.Id.to_string (Session.id session))
            session)
        documents;
      (* Delegated children, keyed by their derived endpoint leaf so a digest
         leaf resolves without inversion. *)
      let children =
        Hashtbl.fold
          (fun id session acc ->
            match
              Session.Metadata.delegated_from (Session.metadata session)
            with
            | None -> acc
            | Some lineage -> (id, session, lineage) :: acc)
          sessions []
      in
      let leaf_of id =
        Filename.basename (User_dirs.child_socket_dir dirs ~session:id)
      in
      let remove_leaf leaf =
        let dir = Filename.concat leaf_root leaf in
        (try Unix.unlink (Filename.concat dir "mentat.sock")
         with Unix.Unix_error _ -> ());
        try Unix.rmdir dir with Unix.Unix_error _ -> ()
      in
      let leaf_set = Hashtbl.create 8 in
      List.iter (fun leaf -> Hashtbl.replace leaf_set leaf ()) leaves;
      let candidates =
        List.filter
          (fun (id, _, _) ->
            Hashtbl.mem leaf_set (leaf_of id)
            ||
            match Store.Run_lock.holder store ~session:(Session.Id.of_string id)
            with
            | `Held _ -> true
            | `Free | `Io _ -> false)
          children
      in
      (* A leaf no delegated session answers to is residue of a removed
         session: remove it. *)
      let claimed = Hashtbl.create 8 in
      List.iter
        (fun (id, _, _) -> Hashtbl.replace claimed (leaf_of id) ())
        children;
      List.iter
        (fun leaf -> if not (Hashtbl.mem claimed leaf) then remove_leaf leaf)
        leaves;
      List.iter
        (fun (id, session, lineage) ->
          let child = Session.Id.of_string id in
          let fence =
            match Store.Run_lock.holder store ~session:child with
            | `Free -> `Free
            | `Held _ -> `Held
            | `Io _ -> `Io
          in
          let parent_id =
            Session.Metadata.Delegated_from.parent lineage
          in
          let parent =
            match
              Hashtbl.find_opt sessions (Session.Id.to_string parent_id)
            with
            | None -> `Absent
            | Some parent_session -> (
                match head_of parent_session with
                | `Unfinished when
                    Session.State.turns (Session.state parent_session) <> [] ->
                    `Waiting
                | `Unfinished | `Terminal | `Absent -> `Idle)
          in
          let dispose () = remove_leaf (leaf_of id) in
          (* [with_instance] stages the child's workspace, runs [act] on it,
             and returns the lease; [~adopt] additionally attaches the parent
             so recovery re-drives the edge and a settlement has a waker. *)
          let with_instance ~adopt act =
            let root =
              Lpath.Abs.to_string
                (Session.Metadata.cwd (Session.metadata session))
            in
            match instance_for ~root with
            | Error message ->
                Eio.traceln
                  "mentatd: orphan %s: its workspace %s did not stage: %s" id
                  root message
            | Ok instance ->
                (if adopt then
                   match Composition.adopt_session instance parent_id with
                   | Ok () -> ()
                   | Error error ->
                       Eio.traceln "mentatd: orphan %s: adopting its parent: %a"
                         id Mentat_protocol.Error.pp error);
                act instance;
                release instance
          in
          match
            Reconcile.boot_action ~fence ~head:(head_of session) ~parent
          with
          | `Adopt -> with_instance ~adopt:true (fun _ -> ())
          | `Adopt_and_watch ->
              with_instance ~adopt:true (fun instance ->
                  watch t instance ~child)
          | `Watch ->
              with_instance ~adopt:false (fun instance ->
                  watch t instance ~child)
          | `Adopt_and_dispose ->
              with_instance ~adopt:true (fun _ -> ());
              dispose ()
          | `Dispose -> dispose ()
          | `Skip reason ->
              Eio.traceln "mentatd: orphan %s left alone: %s" id reason)
        candidates
