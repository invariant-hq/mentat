(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Reconcile = Reconcile

(* The socket layout beneath the configured base is this library's own
   vocabulary: the [s/] tree, and one leaf per session. A session id is
   admitted verbatim as the leaf only when it is short and filename-plain;
   anything else is keyed. Both forms are pure functions of the id, and both
   keep the socket path inside the [sun_path] budget. *)
let socket_leaf ~session =
  let plain c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || Char.equal c '-' || Char.equal c '_' || Char.equal c '.'
  in
  if
    String.length session > 0
    && String.length session <= 40
    && String.for_all plain session
    && not (Char.equal session.[0] '.')
  then session
  else Mentat_digest.key ~length:16 ~domain:"mentat.child-socket.v1" [ session ]

let socket_dir ~base ~session =
  Filename.concat (Filename.concat base "s") (socket_leaf ~session)

(* The serving label is shared vocabulary, not configuration: the per-session
   server acquires its fence under it, and the probe below reads it back to
   tell a preemptable child server from a holder it must never signal. *)
let serve_owner_label = "serve-session"

(* Transitional (dies at the eviction rung, with the in-process drivers it
   labels): the serving label an in-process driver host — an interactive
   process or a daemon-hosted engine — holds its fences under while its
   serve-mount bridge serves the derived socket beside the driver. Dialable
   like the child-server label, but never preemptable: the holder is a live
   host the escalation ladder must not signal. *)
let serve_mount_owner_label = "serve-mount"

(* The custodial label a send acquires the target's fence under while it
   appends mail to a dormant session's journal. A custodial hold is a brief
   labeled hold that releases on its own — never a driver — so every probe
   classifies it as transient: re-probed shortly, never preempted, never
   failed over. The store's session removal guards its rmtree the same way
   under its own exported label. *)
let send_owner_label = "send"

let custodial_label label =
  String.equal label send_owner_label
  || String.equal label Mentat_store.Run_lock.remove_owner_label

(* The one fence-owner classification: a custodial label is a transient the
   observer re-probes; the serving label on a same-host owner is a dialable
   per-session child server; the mount label on a same-host owner is a
   dialable in-process host the ladder must never signal; anything else — an
   unlabeled interactive driver, an unreadable label, a foreign host — is a
   holder no loop here may reach. [probe_fence] maps it onto the decision
   table's vocabulary and the send loop matches it directly, so the two can
   never drift on the host conjunction. *)
let classify_owner owner =
  let same_host () =
    String.equal (Mentat_store.Run_lock.Owner.host owner) (Unix.gethostname ())
  in
  match Mentat_store.Run_lock.Owner.label owner with
  | Some label when custodial_label label -> `Custodial
  | Some label when String.equal label serve_owner_label && same_host () ->
      `Server (Mentat_store.Run_lock.Owner.pid owner)
  | Some label when String.equal label serve_mount_owner_label && same_host ()
    ->
      `Mount
  | Some _ | None -> `Other

type failure_sink = reason:string -> unit

module Engine = struct
  type t = {
    root : Lpath.Abs.t;
    environment : (string * string) list;
    adopt_session :
      Mentat_session.Id.t -> (unit, Mentat_protocol.Error.t) result;
    integrate_child :
      child:Mentat_session.Id.t -> [ `Integrated | `Not_settled | `Unbound ];
    fail_child : child:Mentat_session.Id.t -> message:string -> unit;
  }
end

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

(* The two shapes a supervised session takes. A delegation reports through
   the hosting engine's seam — integration folds the child's result into the
   parent, failure settles the parent's wait. A root answers its caller
   directly: [settled] and [failed] are the supervising caller's sinks,
   once-guarded as a pair at construction so exactly one outcome ever
   crosses, however many observation passes re-derive it. *)
type shape =
  | Delegated of Engine.t
  | Root of {
      root : Lpath.Abs.t;
      environment : (string * string) list;
      settled : unit -> unit;
      failed : reason:string -> unit;
    }

(* One materialized or observed child. [pid] is [Some] only for a process this
   broker spawned — the reaper's set; a foreign child (a previous node life's
   server) is watched through its endpoint and fence instead. [respawns]
   counts spawns beyond the first — construction-fixed, because each
   re-materialization installs a fresh record — and [budget] bounds them:
   the delegated default, or the count a root supervision was given. [resume]
   is the last committed feed position an observation pass delivered, so a
   reconnect replays nothing; [head_cache] keys the last decoded journal head
   on the document stamp, so the polls that watch a parked child decode only
   on change — a successor entry shares the cell, same session, same
   journal. *)
type entry = {
  child : Mentat_session.Id.t;
  shape : shape;
  socket_dir : string;
  mutable pid : int option;
  respawns : int;
  budget : int;
  mutable cancelled : bool;
  mutable resume : Mentat_protocol.Position.t option;
  head_cache : (string * Reconcile.head) option ref;
}

type broker = {
  sw : Eio.Switch.t;
  stdenv : Eio_unix.Stdenv.base;
  store : Mentat_store.t;
  resolve_bin : unit -> (string, string) result;
  socket_base : string;
  log_dir : string;
  now : unit -> Mentat_session.Time.t;
  entries : (string, entry) Hashtbl.t;
  stop_signal : unit Eio.Promise.t;
  stop_resolver : unit Eio.Promise.u;
  send_locks : (string, Eio.Mutex.t) Hashtbl.t;
  mutable stopped : bool;
  mutable reaping : bool;
}

let key child = Mentat_session.Id.to_string child

(* The per-target ordering lock a send serializes on, created on demand and
   kept for the broker's life. [Eio.Mutex] queues its waiters in FIFO order,
   so contending senders are serviced in arrival order — the ordering is the
   primitive's contract, never a discipline each caller must keep. *)
let lock_for locks key =
  match Hashtbl.find_opt locks key with
  | Some lock -> lock
  | None ->
      let lock = Eio.Mutex.create () in
      Hashtbl.replace locks key lock;
      lock
let clock t = Eio.Stdenv.clock t.stdenv
let net t = Eio.Stdenv.net t.stdenv
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

(* Map the fence probe onto the table's vocabulary. This process's own hold
   (an in-process driver) is its own arm; every other holder is
   [classify_owner]'s: [`Held (Some pid)] only for a dialable child server —
   the only holder the escalation ladder may signal — and [`Held None] for a
   holder the table refuses to preempt. *)
let probe_fence t ~session () : Reconcile.fence =
  match Mentat_store.Run_lock.holder t.store ~session with
  | `Free -> `Free
  | `Io io -> `Io (Format.asprintf "%a" Mentat_store.Io.pp io)
  | `Held None -> `Held None
  | `Held (Some owner) -> (
      if Mentat_store.Run_lock.Owner.pid owner = Unix.getpid () then `Held_self
      else
        match classify_owner owner with
        | `Custodial -> `Custodial
        | `Server pid -> `Held (Some pid)
        | `Mount | `Other -> `Held None)

(* Supervision's fence view has no self arm — the send loop's posture:
   labels judge holders, whoever they are. The one exception is that this
   process's own pid is never a ladder target, so an own-pid child-server
   label degrades to the unpreemptable arm instead of [`Held (Some pid)]. *)
let probe_root_fence t ~session () : Reconcile.fence =
  match Mentat_store.Run_lock.holder t.store ~session with
  | `Free -> `Free
  | `Io io -> `Io (Format.asprintf "%a" Mentat_store.Io.pp io)
  | `Held None -> `Held None
  | `Held (Some owner) -> (
      match classify_owner owner with
      | `Custodial -> `Custodial
      | `Server pid when pid <> Unix.getpid () -> `Held (Some pid)
      | `Server _ | `Mount | `Other -> `Held None)

(* The holder's owner line, re-read for a failure message: the table's fence
   vocabulary deliberately collapses identity, so naming the holder is its
   own probe at the failure edge. *)
let holder_name t ~session =
  match Mentat_store.Run_lock.holder t.store ~session with
  | `Held (Some owner) ->
      Format.asprintf "%a" Mentat_store.Run_lock.Owner.pp owner
  | `Held None -> "an unreadable owner"
  | `Free -> "a holder that has since released"
  | `Io io -> Format.asprintf "an unprobeable fence (%a)" Mentat_store.Io.pp io

let entry_root entry =
  match entry.shape with
  | Delegated engine -> engine.Engine.root
  | Root { root; _ } -> root

let entry_environment entry =
  match entry.shape with
  | Delegated engine -> engine.Engine.environment
  | Root { environment; _ } -> environment

let root_string entry = Lpath.Abs.to_string (entry_root entry)

(* The unfinished-work judgment is the state's own: a settled head with
   unconsumed mail is not finished — the mail buys the session another turn,
   so a free fence over it spawns rather than disposes. *)
let head_of session : Reconcile.head =
  if Mentat_session.State.finished (Mentat_session.state session) then
    `Terminal
  else `Unfinished

(* A fence-free head read, elided by the document stamp: the polls that watch
   a parked session decode its journal only when the persisted bytes change.
   A missing document is [`Absent]; any other read failure presumes
   outstanding work. *)
let cached_head t ~session cache : Reconcile.head =
  let read () : Reconcile.head =
    match Mentat_store.Session.load t.store session with
    | Error (Mentat_store.Session.Error.Not_found _) -> `Absent
    | Error _ -> `Unfinished
    | Ok document -> head_of (Mentat_store.Session.Document.session document)
  in
  match Mentat_store.Session.stamp t.store session with
  | None -> read ()
  | Some stamp -> (
      match !cache with
      | Some (cached, head) when String.equal cached stamp -> head
      | Some _ | None ->
          let head = read () in
          cache := Some (stamp, head);
          head)

(* The delegated presumption over the same read: an unreadable or missing
   journal keeps the child observed rather than abandoned — the broker never
   disposes of a child it cannot judge. *)
let child_head t entry : Reconcile.head =
  match cached_head t ~session:entry.child entry.head_cache with
  | `Absent -> `Unfinished
  | (`Unfinished | `Terminal) as head -> head

let connect_child t entry ~sw =
  Mentat_server.connect ~sw ~net:(net t) ~clock:(clock t)
    ~workspace:(root_string entry)
    (Mentat_server.Bind.unix ~dir:(Lpath.Abs.of_string_exn entry.socket_dir))

(* A scoped reachability probe: one throwaway handshake, resources torn down
   with the scope. This is the decide table's probe — once per launch; the
   boot-wait poll below must not use it. *)
let endpoint_reachable t entry () =
  match
    Eio.Switch.run @@ fun sw ->
    match connect_child t entry ~sw with Ok _ -> true | Error _ -> false
  with
  | reachable -> reachable
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> false

(* A raw connect probe: readiness without a protocol handshake. The boot-wait
   poll fires this every 50ms, and each real handshake would register
   connection state — the child server's own idle accounting included — on
   the very server being probed, so readiness only asks the OS whether the
   listener accepts; the follow that comes next performs the real handshake.
   A stale socket file a killed predecessor left refuses the connect, so it
   never answers ready. *)
let endpoint_connectable entry () =
  let socket =
    Mentat_server.Bind.socket_path
      ~dir:(Lpath.Abs.of_string_exn entry.socket_dir)
  in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      match Unix.connect fd (Unix.ADDR_UNIX socket) with
      | () -> true
      | exception Unix.Unix_error _ -> false)

let remove_endpoint entry =
  Mentat_server.Bind.remove_endpoint
    ~dir:(Lpath.Abs.of_string_exn entry.socket_dir)

(* Kill and reap an abandoned entry's process. The pid is this fiber's alone
   to wait on — the entry has left the table, so the reaper's sweep no longer
   sees it — and each signal is guarded by the reap probe in the same
   non-suspending step, so nothing is ever signalled after the exit has been
   observed (and the pid possibly recycled). SIGKILL is not refusable, so the
   final wait polls until the exit is observed rather than giving a wedged
   process a deadline it cannot miss. *)
let destroy t pid =
  let reaped () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> false
    | _, _ -> true
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> false
    | exception Unix.Unix_error _ -> true
  in
  let rec await_reaped elapsed =
    if reaped () then true
    else if elapsed >= grace_s then false
    else begin
      sleep t 0.1;
      await_reaped (elapsed +. 0.1)
    end
  in
  if not (reaped ()) then begin
    send_signal pid Sys.sigterm;
    if not (await_reaped 0.) then begin
      send_signal pid Sys.sigkill;
      let rec drain () =
        if not (reaped ()) then begin
          sleep t 0.1;
          drain ()
        end
      in
      drain ()
    end
  end

(* The one settlement judgment behind every observation: a delegation
   integrates through its engine's seam; a root's settlement is the
   head-and-queue read itself, answered to the caller's settled sink — never
   an exit code. Both are harmless to repeat. *)
let integrate t entry =
  match entry.shape with
  | Delegated engine -> engine.Engine.integrate_child ~child:entry.child
  | Root root -> (
      match child_head t entry with
      | `Terminal ->
          root.settled ();
          `Integrated
      | `Unfinished | `Absent -> `Not_settled)

let fail_shape entry ~message =
  match entry.shape with
  | Delegated engine -> engine.Engine.fail_child ~child:entry.child ~message
  | Root root -> root.failed ~reason:message

let trace_abandoned entry message =
  match entry.shape with
  | Delegated _ ->
      Eio.traceln "broker: delegation to %s abandoned: %s" (key entry.child)
        message
  | Root _ ->
      Eio.traceln "broker: supervision of %s abandoned: %s" (key entry.child)
        message

(* Abandonment: the loud floor for an entry the broker cannot govern. Silent
   only when a fresh entry has superseded this one — that entry's fibers now
   own the delegation's fate. A detached entry (the exit funnel removes its
   binding before working) still fails loudly: swallowing a raise there would
   park the delegation forever. A still-live spawned process is escalated and
   reaped before the failure is reported, so no zombie survives and a child
   left running could never later contradict the failure the parent was
   handed. *)
let give_up t entry message =
  let superseded =
    match Hashtbl.find_opt t.entries (key entry.child) with
    | Some registered -> not (registered == entry)
    | None -> false
  in
  if not superseded then begin
    Hashtbl.remove t.entries (key entry.child);
    (match entry.pid with
    | None -> ()
    | Some pid ->
        entry.pid <- None;
        destroy t pid;
        remove_endpoint entry);
    trace_abandoned entry message;
    fail_shape entry ~message
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
   the holder is alive and the owner line's pid is its self-report at acquire.
   Every rung re-probes the fence and fires in the same non-suspending step as
   the probe's answer, and only while the same pid still holds, so a signal
   can never chase a recycled pid or a holder that changed mid-ladder. Returns
   whether the fence came free. *)
let ladder_foreign t entry pid =
  let fire signal =
    match probe_fence t ~session:entry.child () with
    | `Held (Some current_pid) when current_pid = pid ->
        send_signal pid signal
    | `Free | `Held_self | `Held _ | `Custodial | `Io _ -> ()
  in
  let rec await_free elapsed =
    match probe_fence t ~session:entry.child () with
    | `Free -> true
    | _ when elapsed >= grace_s -> false
    | _ ->
        sleep t 0.25;
        await_free (elapsed +. 0.25)
  in
  fire Sys.sigterm;
  if await_free 0. then true
  else begin
    fire Sys.sigkill;
    await_free 0.
  end

(* One bounded, short-lived wire submission over the child's endpoint: its own
   switch, one connect, one submit, everything torn down before returning — a
   delivery must never pin the child's connection count. [`Unreachable] is a
   transport that never answered: a refused connect, or the whole exchange
   outrunning the grace bound — a frozen child must not park the calling fiber
   (the escalation ladder's signals, not a longer wait, are the remedy there). *)
let submit_wire t entry command =
  match
    Eio.Time.with_timeout (clock t) grace_s @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    match connect_child t entry ~sw with
    | Error _ -> Ok `Unreachable
    | Ok driver -> (
        match
          driver.Mentat_client.Driver.session.Mentat_client.Driver.Session
            .submit command
        with
        | Ok () -> Ok `Submitted
        | Error _ -> Ok `Refused)
  with
  | Ok outcome -> outcome
  | Error `Timeout -> `Unreachable
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> `Unreachable

(* Best-effort semantic interrupt over the child's endpoint. *)
let wire_interrupt t entry =
  match
    Mentat_protocol.Command.interrupt ~session:entry.child
      ~reason:"parent interrupted" ()
  with
  | Error _ -> ()
  | Ok command -> ignore (submit_wire t entry command)

(* One connect-and-follow pass over the child's feed, ending — connection and
   all — as soon as one settlement has integrated: the child's server lingers
   only while no connection is open, so an observer that kept following would
   pin the child alive forever. What settles after the feed closes is
   re-derived at the child's exit by the same integration, so nothing is lost
   to the early close. Each pass resumes after the last committed position the
   previous pass delivered, so a reconnect replays nothing; a resume the feed
   refuses ([Invalid_position]) is forgotten, and the next pass replays whole. *)
let follow_feed t entry =
  match
    (* Integrate from the journal before any connection: a pass that attaches
       after the settlement was already delivered would resume past it and
       tail a feed that will never speak again — pinning the lingering child
       alive on a connection nothing closes. *)
    match integrate t entry with
    | `Integrated | `Unbound -> ()
    | `Not_settled -> (
        Eio.Switch.run @@ fun sw ->
        match connect_child t entry ~sw with
        | Error _ -> ()
        | Ok driver -> (
            if entry.cancelled then wire_interrupt t entry;
            let from =
              match entry.resume with
              | Some position -> `After position
              | None -> `Beginning
            in
            match
              driver.Mentat_client.Driver.session
                .Mentat_client.Driver.Session
                .follow entry.child ~from
            with
            | Error (Mentat_protocol.Error.Invalid_position _) ->
                entry.resume <- None
            | Error _ -> ()
            | Ok seam ->
                let rec pull () =
                  match seam.Mentat_client.Feed.next () with
                  | Ok
                      (Mentat_client.Feed.Item
                         (Mentat_protocol.Update.Committed { position; fact }))
                    -> (
                      entry.resume <- Some position;
                      match fact with
                      | Mentat_protocol.Fact.Turn_settled _ -> (
                          match integrate t entry with
                          | `Integrated | `Unbound -> ()
                          | `Not_settled -> pull ())
                      | _ -> pull ())
                  | Ok (Mentat_client.Feed.Item _) -> pull ()
                  | Error (Mentat_protocol.Error.Invalid_position _) ->
                      entry.resume <- None
                  | Ok Mentat_client.Feed.Closed | Error _ -> ()
                in
                (* The close releases the stream's fiber; without it the
                   scope's teardown would wait on a reader parked in the wire
                   feed. *)
                Fun.protect
                  ~finally:(fun () -> seam.Mentat_client.Feed.close ())
                  pull))
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception _ -> ()

(* The one un-owning observation loop the delegated foreign watch and the
   public watch ride: probe passes until one ends the loop. The rider owns
   every effect and places the cadence sleep ([pause], one second) inside its
   pass, so each rider keeps its own probe order; [`Keep] runs the next pass,
   [`Done] ends the loop. [alive] is re-judged before every pass, so a rider
   whose entry was superseded or claimed dies at its next beat. *)
let rec unowned_watch t ~alive ~pass =
  if alive () then
    match pass ~pause:(fun () -> sleep t 1.0) with
    | `Done -> ()
    | `Keep -> unowned_watch t ~alive ~pass

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

(* The exit settlement — the one funnel for "the child's process is gone": the
   reaper's reap of an own child, the fence coming free under a foreign one,
   and a materialization that found the fence free over a settled journal.
   Integration is re-derived from journals, so running it after an
   already-observed settlement is a harmless repeat; a child that died before
   settling is re-materialized under the bounded budget, and past it the
   delegation fails loudly. The entry is detached before any suspending work
   so a concurrent re-drive materializes against a clean slate; a raise
   anywhere in the funnel reaches [fork_entry]'s guard, whose [give_up] fails
   the detached entry loudly rather than parking it. *)
let rec settle_exit t entry =
  if current t entry then begin
    Hashtbl.remove t.entries (key entry.child);
    match integrate t entry with
    | `Integrated | `Unbound -> remove_endpoint entry
    | `Not_settled ->
        (* A cancelled delegation is respawned so its successor can mint the
           terminal interrupted fact; the interrupt carry is the delegated
           boot's alone — a root activation refuses the flag — so a cancelled
           root is abandoned loudly instead of resumed. *)
        let respawn_refused =
          match entry.shape with
          | Root _ -> entry.cancelled
          | Delegated _ -> false
        in
        if entry.respawns >= entry.budget || respawn_refused then begin
          remove_endpoint entry;
          let message =
            Printf.sprintf
              "the child process died before settling, %d times over"
              (entry.respawns + 1)
          in
          trace_abandoned entry message;
          fail_shape entry ~message
        end
        else begin
          (* A fresh record, honoring [current]'s discipline: the
             re-materialization installs a new physical entry, so the
             predecessor's still-running observer fibers fail their guards
             and die instead of racing a second observation against the
             successor. *)
          let successor =
            { entry with pid = None; respawns = entry.respawns + 1 }
          in
          Hashtbl.replace t.entries (key entry.child) successor;
          (* The predecessor's socket must go before the successor spawns: a
             stale file that refuses connections must never answer a
             readiness probe for a server that is still booting. *)
          remove_endpoint successor;
          spawn_child t successor
        end
  end

and spawn_child t entry =
  (* The interrupt carry belongs to the delegated shape: the root boot
     refuses the flag, and a cancelled root never reaches a respawn. *)
  let interrupted =
    match entry.shape with
    | Delegated _ -> entry.cancelled
    | Root _ -> false
  in
  match
    Spawn.spawn ~resolve_bin:t.resolve_bin ~log_dir:t.log_dir
      ~leaf:(socket_leaf ~session:(key entry.child))
      ~environment:(entry_environment entry) ~session:entry.child ~interrupted
      ~cwd:(entry_root entry)
  with
  | Error message -> give_up t entry message
  | Ok pid ->
      entry.pid <- Some pid;
      ensure_reaper t;
      observe t entry

(* The reaper: one fiber per broker sweeping the spawned-pid set with
   [WNOHANG] on a short cadence. It starts with the first spawned pid — a
   send-only broker (a CLI or TUI instance that materializes nothing) runs no
   fiber at all, so nothing sweeps, or pins the process switch, for a table
   that can never hold a process. The reaper never suspends: the sweep clears
   each [pid] in the same step that observes its exit, and every exit's
   settlement runs on its own forked fiber — so the reaper is never captive
   to a successor child's lifetime, and one entry's failure lands in
   [fork_entry]'s loud floor instead of parking its batch siblings. Detection
   latency is bounded by the cadence; settlement latency is not, because the
   live path is the feed observer. *)
and ensure_reaper t =
  if not (t.reaping || t.stopped) then begin
    t.reaping <- true;
    Eio.Fiber.fork ~sw:t.sw (fun () -> run_reaper t)
  end

and reap_sweep t =
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
  List.iter
    (fun entry -> fork_entry t entry (fun () -> settle_exit t entry))
    exited

and run_reaper t =
  if not t.stopped then begin
    (try reap_sweep t with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        Eio.traceln "broker: the reaper failed: %s" (Printexc.to_string exn));
    sleep t reap_interval_s;
    run_reaper t
  end

(* Observation: wait for the endpoint to answer a handshake, then follow the
   feed until the stream ends. Readiness is connectability, not the socket
   file's existence — a stale socket a SIGKILLed predecessor left refuses
   connections, and one refused connect must not end observation for a
   successor's whole life. An own child's exit is the reaper's to see; a
   foreign child's exit is the fence coming free. While the journal says work
   is outstanding, a broken or refused stream reconnects on a short backoff
   (a wedged holder that never settles is observed for as long as it holds
   the fence; stopping it is the cancel escalation's job, not a broker
   timeout); once the head is settled no new connection is made — a settled
   child is lingering toward its own exit, and a fresh connection would reset
   that linger. *)
and observe t entry =
  let rec await_endpoint elapsed =
    if not (current t entry) then `Gone
    else if endpoint_connectable entry () then `Ready
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
          Eio.traceln "broker: child %s never bound its endpoint; escalating"
            (key entry.child);
          ladder_own t entry pid
          (* The reaper observes the exit and runs the policy. *)
      | None -> foreign_watch t entry)
  | `Ready -> (
      follow_feed t entry;
      if current t entry then
        match entry.pid with
        | Some _ -> (
            (* The reaper owns an own child's exit; until it fires, keep
               observing while work is outstanding. *)
            match child_head t entry with
            | `Unfinished ->
                sleep t 1.0;
                observe t entry
            | `Terminal | `Absent -> ())
        | None -> foreign_watch t entry)

and foreign_watch t entry =
  unowned_watch t
    ~alive:(fun () -> current t entry)
    ~pass:(fun ~pause ->
      let held () =
        pause ();
        (* Reconnect only while work is outstanding: a settled child is
           lingering toward its own exit, and a fresh connection would reset
           that linger — the fence poll alone sees it out. *)
        match child_head t entry with
        | `Unfinished ->
            observe t entry;
            `Done
        | `Terminal | `Absent ->
            (* A root's sink must not wait out a holder's linger: the settled
               answer is the head-and-queue read, taken here; the fence poll
               still drains the entry once the holder exits. *)
            (match entry.shape with
            | Delegated _ -> ()
            | Root _ -> (
                match integrate t entry with
                | `Integrated | `Not_settled | `Unbound -> ()));
            `Keep
      in
      match probe_fence t ~session:entry.child () with
      | `Free ->
          settle_exit t entry;
          `Done
      | `Held_self -> (
          match entry.shape with
          | Delegated _ ->
              (* An in-process driver took the child over (a message delivery
                 attached it); its own hooks integrate from here. *)
              Hashtbl.remove t.entries (key entry.child);
              `Done
          | Root _ ->
              (* This process's own driver holds the session; the journal is
                 still the truth — observe it like any held fence. *)
              held ())
      | `Held _ | `Custodial | `Io _ -> held ())

(* Materialization: the pure table decides over live probes — the fence, the
   endpoint handshake, and the journal head, so the executed table is exactly
   the tested one. A custodial hold re-probes for as long as it lasts: the
   hold is bounded by its owner's brief work and owner death releases the
   fence, so the loop always makes progress — but a wedged custodial holder
   must not be polled at the initial cadence forever, so the reprobe interval
   doubles to a one-second ceiling. *)
let rec launch ?(reprobe_s = 0.05) t entry =
  match
    Reconcile.decide
      ~fence:(probe_fence t ~session:entry.child)
      ~reachable:(endpoint_reachable t entry)
      ~head:(fun () -> child_head t entry)
  with
  | Reconcile.Observe -> observe t entry
  | Reconcile.Preempt pid ->
      Eio.traceln
        "broker: child %s is fenced by pid %d with no endpoint; preempting"
        (key entry.child) pid;
      if ladder_foreign t entry pid then spawn_child t entry
      else
        give_up t entry
          (Printf.sprintf "pid %d holds the child's fence and would not yield"
             pid)
  | Reconcile.Respawn -> spawn_child t entry
  | Reconcile.Dispose ->
      (* The child settled between the engine's ruling and this probe: the
         exit funnel integrates from the journal and clears the residue — no
         process needed. *)
      settle_exit t entry
  | Reconcile.Stand_down -> Hashtbl.remove t.entries (key entry.child)
  | Reconcile.Reprobe ->
      sleep t reprobe_s;
      if current t entry then
        launch ~reprobe_s:(Float.min 1.0 (reprobe_s *. 2.)) t entry
  | Reconcile.Fail message -> give_up t entry message

(* Admission: register the session in the node table and fork its work. A
   session already registered — running or observed — is left to its own
   fibers. *)
let register t ~shape ~budget ~child work =
  if not t.stopped then
    match Hashtbl.find_opt t.entries (key child) with
    | Some _ -> ()
    | None ->
        let entry =
          {
            child;
            shape;
            socket_dir = socket_dir ~base:t.socket_base ~session:(key child);
            pid = None;
            respawns = 0;
            budget;
            cancelled = false;
            resume = None;
            head_cache = ref None;
          }
        in
        Hashtbl.replace t.entries (key child) entry;
        fork_entry t entry (fun () -> work entry)

let materialize t engine ~child =
  register t ~shape:(Delegated engine) ~budget:max_respawns ~child
    (fun entry -> launch t entry)

(* Watch an already-running child this broker did not spawn (a previous node
   life's server): register the entry and observe, deciding nothing else — on
   its exit the ordinary policy integrates, re-drives shadowed messages, or
   re-materializes. A child the ordinary materialize already registered is left
   to it. *)
let observe_running t engine ~child =
  register t ~shape:(Delegated engine) ~budget:max_respawns ~child
    (fun entry -> observe t entry)

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
                match probe_fence t ~session:entry.child () with
                | `Held (Some pid) -> ignore (ladder_foreign t entry pid)
                | `Free | `Held_self | `Held None | `Custodial | `Io _ -> ()))

(* Root supervision: the pure table decides over live probes, exactly as the
   delegated launch does, differing on the arms the two verbs rule
   differently. A holder the supervisor may neither adopt nor preempt is
   observed for a bounded patience — an interactive driver may settle the
   work under the watch, and the head read ends the wait early — and past the
   bound the supervision fails loudly naming the holder. The patience reuses
   the boot wait: the same "how long may an opaque state stand before it is
   wedged" judgment, and the reprobe backs off exactly as a custodial hold's
   does. *)
let rec launch_root ?(reprobe_s = 0.05) ?(held_s = 0.) t entry =
  match
    Reconcile.supervise_action
      ~fence:(probe_root_fence t ~session:entry.child)
      ~reachable:(endpoint_reachable t entry)
      ~head:(fun () -> cached_head t ~session:entry.child entry.head_cache)
  with
  | Reconcile.Adopt -> observe t entry
  | Reconcile.Preempt_stale pid ->
      Eio.traceln
        "broker: session %s is fenced by pid %d with no endpoint; preempting"
        (key entry.child) pid;
      if ladder_foreign t entry pid then spawn_child t entry
      else
        give_up t entry
          (Printf.sprintf "pid %d holds the session's fence and would not yield"
             pid)
  | Reconcile.Spawn -> spawn_child t entry
  | Reconcile.Settle -> settle_exit t entry
  | Reconcile.Refuse message -> give_up t entry message
  | Reconcile.Reprobe_hold | Reconcile.Hold -> (
      if held_s >= boot_wait_s then
        give_up t entry
          (Printf.sprintf "the session's fence stayed held by %s"
             (holder_name t ~session:entry.child))
      else
        match child_head t entry with
        | `Terminal -> settle_exit t entry
        | `Unfinished | `Absent ->
            sleep t reprobe_s;
            if current t entry then
              launch_root
                ~reprobe_s:(Float.min 1.0 (reprobe_s *. 2.))
                ~held_s:(held_s +. reprobe_s) t entry)

(* The interrupt's grace at the deadline: exit releases the fence, so a
   child that heard the interrupt gets one bounded window to wind down
   cleanly before any signal. *)
let wind_down t entry =
  let rec await elapsed =
    match probe_root_fence t ~session:entry.child () with
    | `Free -> ()
    | `Held_self | `Held _ | `Custodial | `Io _ ->
        if elapsed < grace_s then begin
          sleep t 0.25;
          await (elapsed +. 0.25)
        end
  in
  await 0.

(* Deadline enforcement: the supervisor's one clock. Each pass claims the
   session's current entry out of the table before signalling anything, so no
   concurrent settlement can race the ruling and no respawn can outlive the
   clock; the loop re-checks for a successor a racing exit installed in the
   claim window. A head already terminal at the firing settles instead: the
   work beat the clock, and the ordinary funnel drains the entry. The ladder
   here signals only what the delegated ladder may — an own pid, or a
   same-host child server — never an unlabeled holder; one that survives the
   deadline is named in the failure instead. *)
let enforce_deadline t ~session reason =
  let rec enforce () =
    match Hashtbl.find_opt t.entries (key session) with
    | None -> ()
    | Some entry -> (
        match child_head t entry with
        | `Terminal -> (
            match integrate t entry with
            | `Integrated | `Not_settled | `Unbound -> ())
        | `Unfinished | `Absent ->
            Hashtbl.remove t.entries (key session);
            entry.cancelled <- true;
            wire_interrupt t entry;
            wind_down t entry;
            (match entry.pid with
            | Some pid ->
                entry.pid <- None;
                destroy t pid
            | None -> (
                match probe_root_fence t ~session () with
                | `Held (Some pid) -> ignore (ladder_foreign t entry pid)
                | `Free | `Held_self | `Held None | `Custodial | `Io _ -> ()));
            let message =
              match probe_root_fence t ~session () with
              | `Held _ | `Held_self ->
                  Printf.sprintf "%s; the session's fence is still held by %s"
                    reason
                    (holder_name t ~session)
              | `Free | `Custodial | `Io _ -> reason
            in
            remove_endpoint entry;
            trace_abandoned entry message;
            fail_shape entry ~message;
            enforce ())
  in
  enforce ()

(* Root supervision's admission. Idempotent per session: while any entry —
   delegated or root — governs the session, a second call is a no-op whose
   sinks never fire; the standing supervision owns the outcome. *)
let supervise t ~session ~cwd ~environment ?deadline_s
    ?(respawns = max_respawns) ~on_settled ~on_failure () =
  if (not t.stopped) && not (Hashtbl.mem t.entries (key session)) then begin
    (* Exactly one outcome crosses to the caller, however many observation
       passes re-derive it: the sink pair shares one guard, carried by every
       successor entry through the shared shape record. *)
    let fired = ref false in
    let once f =
      if not !fired then begin
        fired := true;
        f ()
      end
    in
    let shape =
      Root
        {
          root = cwd;
          environment;
          settled = (fun () -> once on_settled);
          failed = (fun ~reason -> once (fun () -> on_failure ~reason));
        }
    in
    register t ~shape ~budget:respawns ~child:session (fun entry ->
        launch_root t entry);
    match deadline_s with
    | None -> ()
    | Some deadline ->
        let reason =
          Printf.sprintf "the supervision deadline (%gs) elapsed" deadline
        in
        Eio.Fiber.fork ~sw:t.sw (fun () ->
            Eio.Fiber.first
              (fun () -> Eio.Promise.await t.stop_signal)
              (fun () ->
                sleep t deadline;
                try enforce_deadline t ~session reason with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn -> (
                    let message =
                      Printf.sprintf "the deadline enforcement failed: %s"
                        (Printexc.to_string exn)
                    in
                    match Hashtbl.find_opt t.entries (key session) with
                    | Some entry -> give_up t entry message
                    | None -> Eio.traceln "broker: %s: %s" (key session) message)))
  end

(* Observation without ownership: fence and head until the head is terminal,
   through the same loop the delegated foreign watch rides. The watch holds
   nothing — no table entry, no fence, no connection — so it collides with no
   supervision of the same session, and it never signals and never spawns. *)
let watch t ~session ~on_terminal =
  if not t.stopped then
    Eio.Fiber.fork ~sw:t.sw (fun () ->
        Eio.Fiber.first
          (fun () -> Eio.Promise.await t.stop_signal)
          (fun () ->
            let cache = ref None in
            try
              unowned_watch t
                ~alive:(fun () -> not t.stopped)
                ~pass:(fun ~pause ->
                  match cached_head t ~session cache with
                  | `Absent ->
                      on_terminal `Gone;
                      `Done
                  | `Terminal ->
                      on_terminal `Settled;
                      `Done
                  | `Unfinished -> (
                      match probe_fence t ~session () with
                      | `Free ->
                          on_terminal `Holder_died;
                          `Done
                      | `Held_self | `Held _ | `Custodial | `Io _ ->
                          pause ();
                          `Keep))
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                Eio.traceln "broker: watch of %s ended unexpectedly: %s"
                  (key session) (Printexc.to_string exn)))

let children t =
  Hashtbl.fold
    (fun _ entry acc ->
      let state =
        if entry.cancelled then `Laddering
        else
          match entry.pid with
          | Some pid -> `Spawned pid
          | None -> `Observed
      in
      (entry.child, state) :: acc)
    t.entries []

(* The send — mail as a queue entry in the target's journal.

   Delivery is one bounded fence-first loop decided by the fence owner's
   label. [`Delivered] means exactly one thing: the enqueued fact is durable
   in the target's journal — either committed here under a custodial hold, or
   durably admitted by the driver serving the target's socket. There is no
   weaker success, and an exhausted budget is a loud [`Undelivered] against
   the sender's own durable record. *)

(* The append twin of the driver's queue admission, for a dormant target:
   acquire the fence under the custodial send label — acquisition is the
   liveness probe, there is no read-then-act race — then perform the
   admission the driver would: the recorded-enqueue dedup (a consumed entry's
   fact still proves delivery), the accept judgment, and the enqueued fact
   committed through the store's ordinary path. [`Held] hands the owner line
   back to the loop for label classification. *)
let append_under_fence t ?origin ~target ~id ~input () =
  Eio.Switch.run @@ fun sw ->
  match
    Mentat_store.Run_lock.try_acquire ~sw t.store ~session:target
      ~owner:(Mentat_store.Run_lock.Owner.make ~label:send_owner_label ())
  with
  | Error (`Held owner) -> `Held owner
  | Error (`Io io) ->
      `Undelivered
        (Printf.sprintf "the target's fence could not be probed: %s"
           (Mentat_store.Io.message io))
  | Ok guard -> (
      match Mentat_store.Session.load t.store target with
      | Error e -> `Undelivered (Mentat_store.Session.Error.message e)
      | Ok document -> (
          let session = Mentat_store.Session.Document.session document in
          let state = Mentat_session.state session in
          if Mentat_session.State.enqueue_recorded id state then `Delivered
          else
            match Mentat_session.admits_mail ~origin session with
            | `Refused_sender ->
                `Undelivered
                  (Printf.sprintf
                     "session %s does not accept this sender's mail"
                     (Mentat_session.Id.to_string target))
            | `Refused_backlog ->
                `Undelivered
                  (Printf.sprintf
                     "session %s's mailbox is full for this sender (backlog \
                      cap %d)"
                     (Mentat_session.Id.to_string target)
                     Mentat_session.mail_backlog_cap)
            | `Admitted -> (
                let entry =
                  Mentat_session.Queue.Entry.make ?origin ~id ~input ()
                in
                match
                  Mentat_session.append_all
                    [
                      Mentat_session.Event.queue_updated
                        (Mentat_session.Queue.Update.enqueued entry);
                    ]
                    session
                with
                | Error e -> `Undelivered (Mentat_session.Error.message e)
                | Ok appended -> (
                    let stamped = Mentat_session.touch (t.now ()) appended in
                    match
                      Mentat_store.Session.commit t.store ~fence:guard document
                        stamped
                    with
                    | Ok (_ : Mentat_store.Session.Document.t) -> `Delivered
                    | Error e ->
                        `Undelivered (Mentat_store.Session.Error.message e)))))

(* The wire arm, for a target a per-session server drives: dial the derived
   socket and submit the entry as a [Queue_next] on one short-lived
   connection bounded at [timeout_s] — the driver's recorded-enqueue dedup
   makes redelivery idempotent. The handshake's workspace identity is the
   target's recorded cwd, read fence-free. *)
let wire_send t ?origin ~timeout_s ~target ~id ~input () =
  match Mentat_store.Session.load t.store target with
  | Error _ -> `Unreachable
  | Ok document -> (
      let workspace =
        Lpath.Abs.to_string
          (Mentat_session.Metadata.cwd
             (Mentat_session.metadata
                (Mentat_store.Session.Document.session document)))
      in
      match
        Mentat_protocol.Command.queue_next ~id ?origin ~session:target ~input
          ()
      with
      | Error invalid ->
          `Invalid (Mentat_protocol.Command.Invalid.message invalid)
      | Ok command -> (
          let dir =
            socket_dir ~base:t.socket_base
              ~session:(Mentat_session.Id.to_string target)
          in
          match
            Eio.Time.with_timeout (clock t) timeout_s @@ fun () ->
            Eio.Switch.run @@ fun sw ->
            match
              Mentat_server.connect ~sw ~net:(net t) ~clock:(clock t)
                ~workspace
                (Mentat_server.Bind.unix ~dir:(Lpath.Abs.of_string_exn dir))
            with
            | Error _ -> Ok `Unreachable
            | Ok driver -> (
                match
                  driver.Mentat_client.Driver.session
                    .Mentat_client.Driver.Session
                    .submit command
                with
                | Ok () -> Ok `Submitted
                | Error _ -> Ok `Refused)
          with
          | Ok outcome -> outcome
          | Error `Timeout -> `Unreachable
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception _ -> `Unreachable))

let send t ?origin ?(budget_s = grace_s) ~target ~id ~input () =
  let carries_media =
    List.exists
      (function
        | Mentat_llm.Content.Media { source = `Base64 _ | `Ref _; _ } -> true
        | Mentat_llm.Content.Media { source = `Uri _; _ }
        | Mentat_llm.Content.Text _ ->
            false)
      input
  in
  if carries_media then
    (* Inline base64 would enter the journal unexternalized and a content
       reference names the sender's namespace, not the target's; both are
       refused rather than committed broken. *)
    `Undelivered "mail cannot carry inline or referenced media"
  else
    let backoff_s = 0.05 in
    (* The budget bounds the loop in wall time — read from the broker clock,
       never accumulated from the sleeps alone, or a frozen server's dials
       would stretch one send to passes times the grace. Waiting for the
       target's ordering lock spends the same budget: a sender queued behind
       earlier sends is still one bounded call. *)
    let started = Eio.Time.now (clock t) in
    let elapsed () = Eio.Time.now (clock t) -. started in
    let rec attempt () =
      let retry held =
        if elapsed () >= budget_s then
          `Undelivered
            (match held with
            | Some owner ->
                Format.asprintf "the target's fence is held by %a"
                  Mentat_store.Run_lock.Owner.pp owner
            | None -> "the target's fence stayed held by an unreadable owner")
        else begin
          sleep t backoff_s;
          attempt ()
        end
      in
      match append_under_fence t ?origin ~target ~id ~input () with
      | (`Delivered | `Undelivered _) as outcome -> outcome
      | `Held None -> retry None
      | `Held (Some owner) -> (
          match classify_owner owner with
          | `Custodial ->
              (* Another brief hold is in flight; never dial, never
                 preempt. *)
              retry (Some owner)
          | `Server _ | `Mount -> (
              (* One dial may not outrun what remains of the budget. *)
              let timeout_s =
                Float.min grace_s (Float.max 0. (budget_s -. elapsed ()))
              in
              match wire_send t ?origin ~timeout_s ~target ~id ~input () with
              | `Submitted -> `Delivered
              | `Invalid message -> `Undelivered message
              | `Refused | `Unreachable ->
                  (* The server may still be binding its listener or already
                     tearing down; either way the next pass re-observes the
                     fence — a holder that exits mid-loop is caught by the
                     acquire. *)
                  retry (Some owner))
          | `Other ->
              (* An unlabeled or foreign holder is a driver this loop cannot
                 reach; within the budget it may release. *)
              retry (Some owner))
    in
    (* One send to a target at a time, in arrival order: the delivery loop
       runs under the target's ordering lock, so a second sender's entry can
       never overtake a first still contending for the fence or the wire —
       per-sender FIFO is this primitive's contract. The lock wait is
       cancelled at the budget: a lane that stays busy answers the same loud
       [`Undelivered] as a fence that stays held. *)
    let lane = lock_for t.send_locks (key target) in
    match
      Eio.Time.with_timeout (clock t) budget_s @@ fun () ->
      Eio.Mutex.lock lane;
      Ok ()
    with
    | Error `Timeout ->
        `Undelivered
          "earlier sends to the target did not clear within the budget"
    | Ok () ->
        Fun.protect ~finally:(fun () -> Eio.Mutex.unlock lane) attempt

let create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now =
  let stop_signal, stop_resolver = Eio.Promise.create () in
  {
    sw;
    stdenv;
    store;
    resolve_bin;
    socket_base;
    log_dir;
    now;
    entries = Hashtbl.create 8;
    stop_signal;
    stop_resolver;
    send_locks = Hashtbl.create 8;
    stopped = false;
    reaping = false;
  }

let stop t =
  t.stopped <- true;
  ignore (Eio.Promise.try_resolve t.stop_resolver ())

(* Node-boot rediscovery. Candidate enumeration and disposal live here; every
   probe-and-spawn decision for a candidate that needs one is taken by the
   ordinary materialize path, reached through the adopted parent's recovery —
   one spawn path, probed once. *)

let rediscover t ~engine_for =
  let store = t.store in
  let leaf_root = Filename.concat t.socket_base "s" in
  let leaves =
    match Sys.readdir leaf_root with
    | entries -> Array.to_list entries
    | exception Sys_error _ -> []
  in
  match Mentat_store.Session.scan store with
  | Error error ->
      Eio.traceln "broker: orphan rediscovery skipped: %s"
        (Mentat_store.Session.Error.message error)
  | Ok (documents, _corrupt) ->
      let sessions = Hashtbl.create 16 in
      List.iter
        (fun document ->
          let session = Mentat_store.Session.Document.session document in
          Hashtbl.replace sessions
            (Mentat_session.Id.to_string (Mentat_session.id session))
            session)
        documents;
      (* Delegated children, keyed by their derived endpoint leaf so a digest
         leaf resolves without inversion. *)
      let children =
        Hashtbl.fold
          (fun id session acc ->
            match
              Mentat_session.Metadata.delegated_from
                (Mentat_session.metadata session)
            with
            | None -> acc
            | Some lineage -> (id, session, lineage) :: acc)
          sessions []
      in
      let leaf_of id = socket_leaf ~session:id in
      let remove_leaf leaf =
        Mentat_server.Bind.remove_endpoint
          ~dir:(Lpath.Abs.of_string_exn (Filename.concat leaf_root leaf))
      in
      let leaf_set = Hashtbl.create 8 in
      List.iter (fun leaf -> Hashtbl.replace leaf_set leaf ()) leaves;
      let candidates =
        List.filter
          (fun (id, _, _) ->
            Hashtbl.mem leaf_set (leaf_of id)
            ||
            match
              Mentat_store.Run_lock.holder store
                ~session:(Mentat_session.Id.of_string id)
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
          let child = Mentat_session.Id.of_string id in
          let fence =
            match Mentat_store.Run_lock.holder store ~session:child with
            | `Free -> `Free
            | `Held _ -> `Held
            | `Io _ -> `Io
          in
          let parent_id =
            Mentat_session.Metadata.Delegated_from.parent lineage
          in
          let parent =
            match
              Hashtbl.find_opt sessions (Mentat_session.Id.to_string parent_id)
            with
            | None -> `Absent
            | Some parent_session -> (
                match head_of parent_session with
                | `Unfinished when
                    Mentat_session.State.turns
                      (Mentat_session.state parent_session)
                    <> [] ->
                    `Waiting
                | `Unfinished | `Terminal | `Absent -> `Idle)
          in
          let dispose () = remove_leaf (leaf_of id) in
          (* [with_engine] stages the child's workspace, runs [act] on its
             engine, and returns the lease; [~adopt] additionally attaches the
             parent so recovery re-drives the edge and a settlement has a
             waker. *)
          let with_engine ~adopt act =
            let root =
              Lpath.Abs.to_string
                (Mentat_session.Metadata.cwd
                   (Mentat_session.metadata session))
            in
            match engine_for ~root with
            | Error message ->
                Eio.traceln
                  "broker: orphan %s: its workspace %s did not stage: %s" id
                  root message
            | Ok (engine, release) ->
                (if adopt then
                   match engine.Engine.adopt_session parent_id with
                   | Ok () -> ()
                   | Error error ->
                       Eio.traceln "broker: orphan %s: adopting its parent: %a"
                         id Mentat_protocol.Error.pp error);
                act engine;
                release ()
          in
          match
            Reconcile.boot_action ~fence ~head:(head_of session) ~parent
          with
          | `Adopt -> with_engine ~adopt:true (fun _ -> ())
          | `Adopt_and_watch ->
              with_engine ~adopt:true (fun engine ->
                  observe_running t engine ~child)
          | `Watch ->
              with_engine ~adopt:false (fun engine ->
                  observe_running t engine ~child)
          | `Adopt_and_dispose ->
              with_engine ~adopt:true (fun _ -> ());
              dispose ()
          | `Dispose -> dispose ()
          | `Skip reason ->
              Eio.traceln "broker: orphan %s left alone: %s" id reason)
        candidates

(* The public surface. A broker is the real process broker, or the stub
   [for_tests] builds — the one test seam the engine's delegation tests mock:
   the send's fence, append, and dial effects replaced by the given function,
   every process-facing operation refused loudly. The mock lives here, beside
   the one real implementation it mocks. *)

type send_stub =
  origin:Mentat_session.Origin.t option ->
  target:Mentat_session.Id.t ->
  id:Mentat_session.Queue.Id.t ->
  input:Mentat_llm.Content.t list ->
  [ `Delivered | `Undelivered of string ]

type supervise_stub =
  session:Mentat_session.Id.t ->
  cwd:Lpath.Abs.t ->
  environment:(string * string) list ->
  deadline_s:float option ->
  respawns:int ->
  [ `Settled | `Failed of string ]

(* The stub keeps the real send's per-target serialization — its own lock
   registry — so an ordering-sensitive engine test observes the primitive's
   contract, not a mock's looser one. It has no clock, so the lock wait is
   unbounded; a stub that never returns is a test bug, not a case to serve.
   The optional supervise script answers each supervision request with its
   outcome; the stub fires exactly one of the caller's sinks per call — the
   real verb's contract — and holds no table, so it never dedups a
   re-supervision, exactly as the real broker re-governs a session whose
   previous supervision has drained. *)
type stub = {
  send : send_stub;
  supervise : supervise_stub option;
  locks : (string, Eio.Mutex.t) Hashtbl.t;
}

type t = Real of broker | Stub of stub

let no_processes op =
  invalid_arg
    (Printf.sprintf "Mentat_broker.%s: a test stub performs no process work" op)

let create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now =
  Real (create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now)

let for_tests ?supervise ~send () =
  Stub { send; supervise; locks = Hashtbl.create 4 }

let materialize t engine ~child =
  match t with
  | Real b -> materialize b engine ~child
  | Stub _ -> no_processes "materialize"

let supervise t ~session ~cwd ~environment ?deadline_s ?respawns ~on_settled
    ~on_failure () =
  match t with
  | Real b ->
      supervise b ~session ~cwd ~environment ?deadline_s ?respawns ~on_settled
        ~on_failure ()
  | Stub { supervise = None; _ } -> no_processes "supervise"
  | Stub { supervise = Some script; _ } -> (
      match
        script ~session ~cwd ~environment ~deadline_s
          ~respawns:(Option.value respawns ~default:max_respawns)
      with
      | `Settled -> on_settled ()
      | `Failed reason -> on_failure ~reason)

let watch t ~session ~on_terminal =
  match t with
  | Real b -> watch b ~session ~on_terminal
  | Stub _ -> no_processes "watch"

let children t = match t with Real b -> children b | Stub _ -> []

let cancel t ~child =
  match t with Real b -> cancel b ~child | Stub _ -> no_processes "cancel"

let send t ?origin ?budget_s ~target ~id ~input () =
  match t with
  | Real b -> send b ?origin ?budget_s ~target ~id ~input ()
  | Stub stub ->
      Eio.Mutex.use_ro
        (lock_for stub.locks (Mentat_session.Id.to_string target))
        (fun () -> stub.send ~origin ~target ~id ~input)

let rediscover t ~engine_for =
  match t with
  | Real b -> rediscover b ~engine_for
  | Stub _ -> no_processes "rediscover"

let stop t = match t with Real b -> stop b | Stub _ -> ()
