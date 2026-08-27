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

(* The custodial label a send acquires the target's fence under while it
   appends mail to a dormant session's journal. A custodial hold is a brief
   labeled hold that releases on its own — never a driver — so every probe
   classifies it as transient: re-probed shortly, never preempted, never
   failed over. The store's session removal guards its rmtree the same way
   under its own "remove" label. *)
let send_owner_label = "send"

let custodial_label label =
  String.equal label send_owner_label || String.equal label "remove"

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

(* One materialized or observed child. [pid] is [Some] only for a process this
   broker spawned — the reaper's set; a foreign child (a previous node life's
   server) is watched through its endpoint and fence instead. [respawns]
   counts spawns beyond the first — construction-fixed, because each
   re-materialization installs a fresh record. [resume] is the last committed
   feed position an observation pass delivered, so a reconnect replays
   nothing; [head_cache] keys the last decoded journal head on the document
   stamp, so the polls that watch a parked child decode only on change. *)
type entry = {
  child : Mentat_session.Id.t;
  engine : Engine.t;
  socket_dir : string;
  mutable pid : int option;
  respawns : int;
  mutable cancelled : bool;
  mutable resume : Mentat_protocol.Position.t option;
  mutable head_cache : (string * Reconcile.head) option;
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
  mutable stopped : bool;
}

let key child = Mentat_session.Id.to_string child
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

(* Map the fence probe onto the table's vocabulary. Identity mapping lives
   here, not in the table: [`Held (Some pid)] only for a same-host holder
   whose owner line carries the child-server label — the only holder the
   escalation ladder may signal. This process's own hold (an in-process
   driver) is its own arm, a custodial label (a send's append, the store's
   removal) is a transient the table re-probes, and every other holder — an
   interactive CLI that resumed the child, an unreadable owner line, a
   foreign host — is [`Held None], which the table refuses to preempt. *)
let probe_fence t entry () : Reconcile.fence =
  match Mentat_store.Run_lock.holder t.store ~session:entry.child with
  | `Free -> `Free
  | `Io io -> `Io (Format.asprintf "%a" Mentat_store.Io.pp io)
  | `Held None -> `Held None
  | `Held (Some owner) -> (
      let pid = Mentat_store.Run_lock.Owner.pid owner in
      if pid = Unix.getpid () then `Held_self
      else
        match Mentat_store.Run_lock.Owner.label owner with
        | Some label when custodial_label label -> `Custodial
        | Some label
          when String.equal label serve_owner_label
               && String.equal
                    (Mentat_store.Run_lock.Owner.host owner)
                    (Unix.gethostname ()) ->
            `Held (Some pid)
        | Some _ | None -> `Held None)

let root_string entry = Lpath.Abs.to_string entry.engine.Engine.root

(* The unfinished-work judgment is head OR queue: a settled head with
   unconsumed mail is not finished — the mail buys the session another turn,
   so a free fence over it spawns rather than disposes. *)
let head_of session : Reconcile.head =
  let state = Mentat_session.state session in
  match Mentat_session.State.settled_head state with
  | Some _ when Mentat_session.State.pending_queue state = [] -> `Terminal
  | Some _ | None -> `Unfinished

(* A fence-free head read, elided by the document stamp: the polls that watch
   a parked child decode its journal only when the persisted bytes change. An
   unreadable journal presumes outstanding work, so the caller keeps watching
   rather than abandoning a child it cannot judge. *)
let child_head t entry : Reconcile.head =
  let store = t.store in
  let read () : Reconcile.head =
    match Mentat_store.Session.load store entry.child with
    | Error _ -> `Unfinished
    | Ok document -> head_of (Mentat_store.Session.Document.session document)
  in
  match Mentat_store.Session.stamp store entry.child with
  | None -> read ()
  | Some stamp -> (
      match entry.head_cache with
      | Some (cached, head) when String.equal cached stamp -> head
      | Some _ | None ->
          let head = read () in
          entry.head_cache <- Some (stamp, head);
          head)

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
    Eio.traceln "broker: delegation to %s abandoned: %s" (key entry.child)
      message;
    entry.engine.Engine.fail_child ~child:entry.child ~message
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
    match probe_fence t entry () with
    | `Held (Some current_pid) when current_pid = pid ->
        send_signal pid signal
    | `Free | `Held_self | `Held _ | `Custodial | `Io _ -> ()
  in
  let rec await_free elapsed =
    match probe_fence t entry () with
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
    match entry.engine.Engine.integrate_child ~child:entry.child with
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
                          match
                            entry.engine.Engine.integrate_child
                              ~child:entry.child
                          with
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
    match entry.engine.Engine.integrate_child ~child:entry.child with
    | `Integrated | `Unbound -> remove_endpoint entry
    | `Not_settled ->
        if entry.respawns >= max_respawns then begin
          remove_endpoint entry;
          let message =
            Printf.sprintf
              "the child process died before settling, %d times over"
              (entry.respawns + 1)
          in
          Eio.traceln "broker: delegation to %s abandoned: %s"
            (key entry.child) message;
          entry.engine.Engine.fail_child ~child:entry.child ~message
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
  match
    Spawn.spawn ~resolve_bin:t.resolve_bin ~log_dir:t.log_dir
      ~leaf:(socket_leaf ~session:(key entry.child))
      ~environment:entry.engine.Engine.environment ~session:entry.child
      ~interrupted:entry.cancelled ~cwd:entry.engine.Engine.root
  with
  | Error message -> give_up t entry message
  | Ok pid ->
      entry.pid <- Some pid;
      observe t entry

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
  if current t entry then
    match probe_fence t entry () with
    | `Free -> settle_exit t entry
    | `Held_self ->
        (* An in-process driver took the child over (a message delivery
           attached it); its own hooks integrate from here. *)
        Hashtbl.remove t.entries (key entry.child)
    | `Held _ | `Custodial | `Io _ -> (
        sleep t 1.0;
        (* Reconnect only while work is outstanding: a settled child is
           lingering toward its own exit, and a fresh connection would reset
           that linger — the fence poll alone sees it out. *)
        match child_head t entry with
        | `Unfinished -> observe t entry
        | `Terminal | `Absent -> foreign_watch t entry)

(* Materialization: the pure table decides over live probes — the fence, the
   endpoint handshake, and the journal head, so the executed table is exactly
   the tested one. A custodial hold re-probes on a short cadence for as long
   as it lasts: the hold is bounded by its owner's brief work and owner death
   releases the fence, so the loop always makes progress. *)
let rec launch t entry =
  match
    Reconcile.decide ~fence:(probe_fence t entry)
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
      sleep t 0.05;
      if current t entry then launch t entry
  | Reconcile.Fail message -> give_up t entry message

(* Admission: register the child in the node table and fork its work. A child
   already registered — running or observed — is left to its own fibers. *)
let register t engine ~child work =
  if not t.stopped then
    match Hashtbl.find_opt t.entries (key child) with
    | Some _ -> ()
    | None ->
        let entry =
          {
            child;
            engine;
            socket_dir = socket_dir ~base:t.socket_base ~session:(key child);
            pid = None;
            respawns = 0;
            cancelled = false;
            resume = None;
            head_cache = None;
          }
        in
        Hashtbl.replace t.entries (key child) entry;
        fork_entry t entry (fun () -> work entry)

let materialize t engine ~child =
  register t engine ~child (fun entry -> launch t entry)

(* Watch an already-running child this broker did not spawn (a previous node
   life's server): register the entry and observe, deciding nothing else — on
   its exit the ordinary policy integrates, re-drives shadowed messages, or
   re-materializes. A child the ordinary materialize already registered is left
   to it. *)
let watch t engine ~child =
  register t engine ~child (fun entry -> observe t entry)

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
                | `Free | `Held_self | `Held None | `Custodial | `Io _ -> ()))

(* The send — mail as a queue entry in the target's journal.

   Delivery is one bounded fence-first loop decided by the fence owner's
   label. [`Delivered] means exactly one thing: the enqueued fact is durable
   in the target's journal — either committed here under a custodial hold, or
   durably admitted by the driver serving the target's socket. There is no
   weaker success, and an exhausted budget is a loud [`Undelivered] against
   the sender's own durable record. *)

(* The accept judgment over the target's own recorded facts — the honest
   floor while only delegation kin and the owner send: mail from the owner
   (an absent origin), from the target's recorded parent, or from one of its
   own recorded children is admitted; anything else is refused loudly. The
   grant table grows here. *)
let accepted ~origin target_session =
  match origin with
  | None -> true
  | Some (Mentat_session.Origin.Trigger _) -> false
  | Some (Mentat_session.Origin.Agent sender) ->
      let is_parent =
        match
          Mentat_session.Metadata.delegated_from
            (Mentat_session.metadata target_session)
        with
        | None -> false
        | Some lineage ->
            Mentat_session.Id.equal
              (Mentat_session.Metadata.Delegated_from.parent lineage)
              sender
      in
      is_parent
      || List.exists
           (fun edge ->
             Mentat_session.Id.equal
               (Mentat_session.Delegation.child edge)
               sender)
           (Mentat_session.State.delegations
              (Mentat_session.state target_session))

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
          else if not (accepted ~origin session) then
            `Undelivered
              (Printf.sprintf "session %s does not accept this sender's mail"
                 (Mentat_session.Id.to_string target))
          else
            let entry = Mentat_session.Queue.Entry.make ?origin ~id ~input () in
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
                    `Undelivered (Mentat_store.Session.Error.message e))))

(* The wire arm, for a target a per-session server drives: dial the derived
   socket and submit the entry as a [Queue_next] on one short-lived,
   grace-bounded connection — the driver's recorded-enqueue dedup makes
   redelivery idempotent. The handshake's workspace identity is the target's
   recorded cwd, read fence-free. *)
let wire_send t ?origin ~target ~id ~input () =
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
            Eio.Time.with_timeout (clock t) grace_s @@ fun () ->
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
    let rec attempt elapsed =
      let retry held =
        if elapsed >= budget_s then
          `Undelivered
            (match held with
            | Some owner ->
                Format.asprintf "the target's fence is held by %a"
                  Mentat_store.Run_lock.Owner.pp owner
            | None -> "the target's fence stayed held by an unreadable owner")
        else begin
          sleep t backoff_s;
          attempt (elapsed +. backoff_s)
        end
      in
      match append_under_fence t ?origin ~target ~id ~input () with
      | (`Delivered | `Undelivered _) as outcome -> outcome
      | `Held None -> retry None
      | `Held (Some owner) -> (
          match Mentat_store.Run_lock.Owner.label owner with
          | Some label when custodial_label label ->
              (* Another brief hold is in flight; never dial, never
                 preempt. *)
              retry (Some owner)
          | Some label
            when String.equal label serve_owner_label
                 && String.equal
                      (Mentat_store.Run_lock.Owner.host owner)
                      (Unix.gethostname ()) -> (
              match wire_send t ?origin ~target ~id ~input () with
              | `Submitted -> `Delivered
              | `Invalid message -> `Undelivered message
              | `Refused | `Unreachable ->
                  (* The server may still be binding its listener or already
                     tearing down; either way the next pass re-observes the
                     fence — a holder that exits mid-loop is caught by the
                     acquire. *)
                  retry (Some owner))
          | Some _ | None ->
              (* An unlabeled or foreign holder is a driver this loop cannot
                 reach; within the budget it may release. *)
              retry (Some owner))
    in
    attempt 0.

(* The reaper: one fiber per broker sweeping the spawned-pid set with
   [WNOHANG] on a short cadence. The reaper never suspends: the sweep clears
   each [pid] in the same step that observes its exit, and every exit's
   settlement runs on its own forked fiber — so the reaper is never captive
   to a successor child's lifetime, and one entry's failure lands in
   [fork_entry]'s loud floor instead of parking its batch siblings. Detection
   latency is bounded by the cadence; settlement latency is not, because the
   live path is the feed observer. *)
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
  List.iter
    (fun entry -> fork_entry t entry (fun () -> settle_exit t entry))
    exited

let run_reaper t =
  let rec loop () =
    if not t.stopped then begin
      (try reap_sweep t with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Eio.traceln "broker: the reaper failed: %s" (Printexc.to_string exn));
      sleep t reap_interval_s;
      loop ()
    end
  in
  loop ()

let create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now =
  let stop_signal, stop_resolver = Eio.Promise.create () in
  let t =
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
              with_engine ~adopt:true (fun engine -> watch t engine ~child)
          | `Watch ->
              with_engine ~adopt:false (fun engine -> watch t engine ~child)
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

type t = Real of broker | Stub of send_stub

let no_processes op =
  invalid_arg
    (Printf.sprintf "Mentat_broker.%s: a test stub performs no process work" op)

let create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now =
  Real (create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now)

let for_tests ~send = Stub send

let materialize t engine ~child =
  match t with
  | Real b -> materialize b engine ~child
  | Stub _ -> no_processes "materialize"

let cancel t ~child =
  match t with Real b -> cancel b ~child | Stub _ -> no_processes "cancel"

let send t ?origin ?budget_s ~target ~id ~input () =
  match t with
  | Real b -> send b ?origin ?budget_s ~target ~id ~input ()
  | Stub stub -> stub ~origin ~target ~id ~input

let rediscover t ~engine_for =
  match t with
  | Real b -> rediscover b ~engine_for
  | Stub _ -> no_processes "rediscover"

let stop t = match t with Real b -> stop b | Stub _ -> ()
