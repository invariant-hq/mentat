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

(* Shared vocabulary again: how long a settled session's server lingers
   before its clean exit, so a follow-up delivery landing just after
   settlement still finds a live server. Spelled here because both sides
   lean on it — the serve process pays it as its default linger, and an
   offline command's bounded fence patience is derived from it; a drifted
   copy would silently reopen the run-then-offline-command Busy that
   patience exists to kill. *)
let serve_linger_s = 3.0

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

(* The typed supervision failure: the arm is the contract a caller
   classifies on, the prose is diagnostic. [failure_message] is the one
   wording home — the broker's own traces and every narrating caller render
   through it, so a reword can never silently reclassify an outcome. *)
type failure = Deadline of float | Gave_up of string

type failure_sink = failure -> unit

let failure_message = function
  | Deadline deadline ->
      Printf.sprintf "the supervision deadline (%gs) elapsed" deadline
  | Gave_up reason -> reason

module Engine = struct
  type t = {
    root : Lpath.Abs.t;
    environment : (string * string) list;
    integrate_child :
      child:Mentat_session.Id.t -> [ `Integrated | `Not_settled | `Unbound ];
    fail_child : child:Mentat_session.Id.t -> message:string -> unit;
  }
end

(* Every timing constant in one place. The boot wait bounds only how long a
   spawned child may take to bind its endpoint before the ladder treats it as
   wedged (a cold serve boot stages a full composition; tens of
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
      environment : (string * string) list;
      settled : unit -> unit;
      failed : failure -> unit;
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
  orphan_pids : (int, unit) Hashtbl.t;
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

(* An entry's workspace identity — the spawned activation's cwd and the
   handshake identity of every dial. A delegation carries its engine's root;
   a root supervision reads the session's recorded cwd from the document,
   fence-free, at each use — exactly as the send's wire arm reads it — so
   the store, never the supervising caller, owns the fact. *)
let entry_workspace t entry =
  match entry.shape with
  | Delegated engine -> Ok engine.Engine.root
  | Root _ -> (
      match Mentat_store.Session.load t.store entry.child with
      | Error e ->
          Error
            (Printf.sprintf "the session document could not be read: %s"
               (Mentat_store.Session.Error.message e))
      | Ok document ->
          Ok
            (Mentat_session.Metadata.cwd
               (Mentat_session.metadata
                  (Mentat_store.Session.Document.session document))))

let entry_environment entry =
  match entry.shape with
  | Delegated engine -> engine.Engine.environment
  | Root { environment; _ } -> environment

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
  match entry_workspace t entry with
  | Error message -> Error (`Workspace message)
  | Ok workspace -> (
      match
        Mentat_server.connect ~sw ~net:(net t) ~clock:(clock t)
          ~workspace:(Lpath.Abs.to_string workspace)
          (Mentat_server.Bind.unix
             ~dir:(Lpath.Abs.of_string_exn entry.socket_dir))
      with
      | Ok _ as ok -> ok
      | Error error -> Error (`Connect error))

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
let dir_connectable dir () =
  let socket = Mentat_server.Bind.socket_path ~dir:(Lpath.Abs.of_string_exn dir) in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      match Unix.connect fd (Unix.ADDR_UNIX socket) with
      | () -> true
      | exception Unix.Unix_error _ -> false)

let endpoint_connectable entry () = dir_connectable entry.socket_dir ()

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

let fail_shape entry failure =
  match entry.shape with
  | Delegated engine ->
      engine.Engine.fail_child ~child:entry.child
        ~message:(failure_message failure)
  | Root root -> root.failed failure

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
        (* The dead child's own lock died with it, so a fence still held
           here names another process's live agent behind the socket — a
           removal would sever it. Remove only the free-fence residue. *)
        (match probe_fence t ~session:entry.child () with
        | `Free | `Io _ -> remove_endpoint entry
        | `Held _ | `Held_self | `Custodial -> ()));
    trace_abandoned entry message;
    fail_shape entry (Gave_up message)
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
    | `Integrated | `Unbound -> (
        (* Remove the endpoint only under a free fence: an exit funnels here
           for boot-race losers too, and a held fence means the session's
           winner — possibly another process's agent — is live behind the
           socket this would unlink by path. The stale-socket residue the
           removal exists for always presents as free, because a dead
           holder's lock died with it. *)
        match probe_fence t ~session:entry.child () with
        | `Free | `Io _ -> remove_endpoint entry
        | `Held _ | `Held_self | `Custodial -> ())
    | `Not_settled -> (
        (* The exit alone does not prove the endpoint or the session were
           this entry's own: a boot-race loser dies unsettled while the
           winner holds the fence and serves. Probe the fence before any
           removal or spawn — a held fence installs an uncharged successor
           and re-enters the decision loop, which adopts the reachable
           winner or rides the foreign watch; only a free fence charges the
           respawn budget. *)
        match probe_fence t ~session:entry.child () with
        | `Held _ | `Held_self | `Custodial | `Io _ ->
            let successor = { entry with pid = None } in
            Hashtbl.replace t.entries (key entry.child) successor;
            (match successor.shape with
            | Delegated _ -> launch t successor
            | Root _ -> launch_root t successor)
        | `Free ->
            (* A cancelled delegation is respawned so its successor can mint
               the terminal interrupted fact; the interrupt carry is the
               delegated boot's alone — a root activation refuses the flag —
               so a cancelled root is abandoned loudly instead of resumed. *)
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
              fail_shape entry (Gave_up message)
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
              (* The predecessor's socket must go before the successor spawns:
                 a stale file that refuses connections must never answer a
                 readiness probe for a server that is still booting. *)
              remove_endpoint successor;
              spawn_child t successor
            end)
  end

and spawn_child t entry =
  (* The interrupt carry belongs to the delegated shape: the root boot
     refuses the flag, and a cancelled root never reaches a respawn. *)
  let interrupted =
    match entry.shape with
    | Delegated _ -> entry.cancelled
    | Root _ -> false
  in
  match entry_workspace t entry with
  | Error message -> give_up t entry message
  | Ok cwd -> (
      match
        Spawn.spawn ~resolve_bin:t.resolve_bin ~log_dir:t.log_dir
          ~leaf:(socket_leaf ~session:(key entry.child))
          ~environment:(entry_environment entry) ~session:entry.child
          ~interrupted ~cwd
      with
      | Error message -> give_up t entry message
      | Ok pid ->
          entry.pid <- Some pid;
          ensure_reaper t;
          observe t entry)

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
  (* Frontend-started activations first: their lifecycle is the session's own
     — no observation, no respawn — only the zombie is this broker's to
     reap. *)
  Hashtbl.iter
    (fun pid () ->
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> ()
      | _, _ -> Hashtbl.remove t.orphan_pids pid
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
      | exception Unix.Unix_error _ -> Hashtbl.remove t.orphan_pids pid)
    (Hashtbl.copy t.orphan_pids);
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
   doubles to a one-second ceiling. A preemptable holder gets the boot wait
   first: held-without-endpoint is also every booting server between its
   fence-taking attach and its bind, so the ladder fires only on a holder
   that stays unbound past the bound — the table stays pure; the patience is
   this loop's. *)
and launch ?(reprobe_s = 0.05) ?(preempt_s = 0.) t entry =
  match
    Reconcile.decide
      ~fence:(probe_fence t ~session:entry.child)
      ~reachable:(endpoint_reachable t entry)
      ~head:(fun () -> child_head t entry)
  with
  | Reconcile.Observe -> observe t entry
  | Reconcile.Preempt pid ->
      if preempt_s >= boot_wait_s then begin
        Eio.traceln
          "broker: child %s is fenced by pid %d with no endpoint; preempting"
          (key entry.child) pid;
        if ladder_foreign t entry pid then spawn_child t entry
        else
          give_up t entry
            (Printf.sprintf
               "pid %d holds the child's fence and would not yield" pid)
      end
      else begin
        sleep t reprobe_s;
        if current t entry then
          launch
            ~reprobe_s:(Float.min 1.0 (reprobe_s *. 2.))
            ~preempt_s:(preempt_s +. reprobe_s) t entry
      end
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

(* Root supervision: the pure table decides over live probes, exactly as the
   delegated launch does, differing on the arms the two verbs rule
   differently. A holder the supervisor may neither adopt nor preempt is
   observed for a bounded patience — an interactive driver may settle the
   work under the watch, and the head read ends the wait early — and past the
   bound the supervision fails loudly naming the holder. A preemptable holder
   shares the same patience before its ladder: held-without-endpoint is also
   every booting agent between its attach and its bind. Both reuse the boot
   wait — the same "how long may an opaque state stand before it is wedged"
   judgment — and the reprobe backs off exactly as a custodial hold's does. *)
and launch_root ?(reprobe_s = 0.05) ?(held_s = 0.) t entry =
  match
    Reconcile.supervise_action
      ~fence:(probe_root_fence t ~session:entry.child)
      ~reachable:(endpoint_reachable t entry)
      ~head:(fun () -> cached_head t ~session:entry.child entry.head_cache)
  with
  | Reconcile.Adopt -> observe t entry
  | Reconcile.Preempt_stale pid ->
      if held_s >= boot_wait_s then begin
        Eio.traceln
          "broker: session %s is fenced by pid %d with no endpoint; preempting"
          (key entry.child) pid;
        if ladder_foreign t entry pid then spawn_child t entry
        else
          give_up t entry
            (Printf.sprintf
               "pid %d holds the session's fence and would not yield" pid)
      end
      else begin
        sleep t reprobe_s;
        if current t entry then
          launch_root
            ~reprobe_s:(Float.min 1.0 (reprobe_s *. 2.))
            ~held_s:(held_s +. reprobe_s) t entry
      end
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

(* Deadline enforcement: the supervisor's one clock. The clock has fired, so
   each pass first marks the session's current binding cancelled — before
   any suspending probe, so an exit settling in the probe window cannot
   install and spawn a successor the ruling would miss ([respawn_refused]
   blocks a cancelled root) — and then claims the binding by identity: the
   re-find and the remove share one non-suspending step, and a binding the
   probe window replaced is re-ruled by the loop instead of signalled
   through a stale entry. A head already terminal at the firing settles
   instead: the work beat the clock, and the ordinary funnel drains the
   entry. The ladder here signals only what the delegated ladder may — an
   own pid, or a same-host child server — never an unlabeled holder; one
   that survives the deadline is named in the trace instead. *)
let enforce_deadline t ~session deadline =
  let rec enforce () =
    match Hashtbl.find_opt t.entries (key session) with
    | None -> ()
    | Some entry -> (
        entry.cancelled <- true;
        match child_head t entry with
        | `Terminal -> (
            match integrate t entry with
            | `Integrated | `Not_settled | `Unbound -> ())
        | `Unfinished | `Absent -> (
            match Hashtbl.find_opt t.entries (key session) with
            | Some current when current == entry ->
                Hashtbl.remove t.entries (key session);
                wire_interrupt t entry;
                wind_down t entry;
                (match entry.pid with
                | Some pid ->
                    entry.pid <- None;
                    destroy t pid
                | None -> (
                    match probe_root_fence t ~session () with
                    | `Held (Some pid) -> ignore (ladder_foreign t entry pid)
                    | `Free | `Held_self | `Held None | `Custodial | `Io _ ->
                        ()));
                let failure = Deadline deadline in
                let message =
                  match probe_root_fence t ~session () with
                  | `Held _ | `Held_self ->
                      Printf.sprintf
                        "%s; the session's fence is still held by %s"
                        (failure_message failure)
                        (holder_name t ~session)
                  | `Free | `Custodial | `Io _ -> failure_message failure
                in
                remove_endpoint entry;
                trace_abandoned entry message;
                fail_shape entry failure;
                enforce ()
            | Some _ | None -> enforce ()))
  in
  enforce ()

(* Root supervision's admission. Idempotent per session: while any entry —
   delegated or root — governs the session, the standing supervision owns
   the outcome; the answer names the arm, so a caller never awaits sinks
   that cannot fire. *)
let supervise t ~session ~environment ?deadline_s ?(respawns = max_respawns)
    ~on_settled ~on_failure () =
  if t.stopped then `Stopped
  else if Hashtbl.mem t.entries (key session) then `Already_governed
  else begin
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
          environment;
          settled = (fun () -> once on_settled);
          failed = (fun failure -> once (fun () -> on_failure failure));
        }
    in
    register t ~shape ~budget:respawns ~child:session (fun entry ->
        launch_root t entry);
    (match deadline_s with
    | None -> ()
    | Some deadline ->
        Eio.Fiber.fork ~sw:t.sw (fun () ->
            Eio.Fiber.first
              (fun () -> Eio.Promise.await t.stop_signal)
              (fun () ->
                sleep t deadline;
                try enforce_deadline t ~session deadline with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn -> (
                    let message =
                      Printf.sprintf "the deadline enforcement failed: %s"
                        (Printexc.to_string exn)
                    in
                    match Hashtbl.find_opt t.entries (key session) with
                    | Some entry -> give_up t entry message
                    | None ->
                        Eio.traceln "broker: %s: %s" (key session) message))));
    `Supervising
  end

(* The frontend's activation verb: make an agent serve the session so the
   caller can dial its socket, owning nothing beyond the spawned pid's
   zombie. Unlike supervision it spawns for a {e settled} session too — a
   resume needs a socket regardless of the head — and it observes nothing:
   the caller's own connection is the lease, and the agent idles out on its
   own. The refusal is not authoritative under concurrent starts: a loser of
   the boot-attach race may be reported exited while the winner is still
   binding, and the caller's next probe finds the winner. *)
let serve t ~session ~environment () =
  if t.stopped then `Refused "the broker is stopped"
  else
    let dir = socket_dir ~base:t.socket_base ~session:(key session) in
    let recorded_cwd () =
      match Mentat_store.Session.load t.store session with
      | Error e ->
          Error
            (Printf.sprintf "the session document could not be read: %s"
               (Mentat_store.Session.Error.message e))
      | Ok document ->
          Ok
            (Mentat_session.Metadata.cwd
               (Mentat_session.metadata
                  (Mentat_store.Session.Document.session document)))
    in
    (* WNOHANG doubles as the reap: an exited child observed here never
       reaches the orphan set. *)
    let child_exited pid =
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> false
      | _, _ -> true
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> false
      | exception Unix.Unix_error _ -> true
    in
    let leaf = socket_leaf ~session:(key session) in
    let rec loop ~pid ~held_other_s elapsed =
      if dir_connectable dir () then begin
        (match pid with
        | Some pid ->
            Hashtbl.replace t.orphan_pids pid ();
            ensure_reaper t
        | None -> ());
        `Serving
      end
      else if elapsed >= boot_wait_s then
        `Refused
          (Printf.sprintf
             "the session's agent did not bind its endpoint within %gs"
             boot_wait_s)
      else
        let wait ~pid ~held_other_s =
          sleep t 0.05;
          loop ~pid ~held_other_s (elapsed +. 0.05)
        in
        match pid with
        | Some p when child_exited p ->
            `Refused
              (Printf.sprintf "the agent exited during boot; see %s"
                 (Spawn.log_path ~log_dir:t.log_dir ~leaf))
        | _ -> (
            match probe_root_fence t ~session () with
            | `Free when pid = None -> (
                match recorded_cwd () with
                | Error message -> `Refused message
                | Ok cwd -> (
                    match
                      Spawn.spawn ~resolve_bin:t.resolve_bin
                        ~log_dir:t.log_dir ~leaf ~environment ~session
                        ~interrupted:false ~cwd
                    with
                    | Error message -> `Refused message
                    | Ok p -> loop ~pid:(Some p) ~held_other_s elapsed))
            | `Free | `Custodial | `Held (Some _) ->
                (* Our own child staging before its fence, a brief custodial
                   hold, or a serving holder whose listener is not yet up. *)
                wait ~pid ~held_other_s
            | `Held_self | `Held None ->
                (* A holder no start may reach — an interactive driver, an
                   unreadable owner line, a foreign host. A brief patience
                   covers the offline twins' sub-second fenced commits. *)
                if held_other_s >= 2.0 then
                  `Refused
                    (Printf.sprintf "the session is driven by %s"
                       (holder_name t ~session))
                else wait ~pid ~held_other_s:(held_other_s +. 0.05)
            | `Io message -> `Refused message)
    in
    loop ~pid:None ~held_other_s:0. 0.

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
    orphan_pids = Hashtbl.create 4;
    stop_signal;
    stop_resolver;
    send_locks = Hashtbl.create 8;
    stopped = false;
    reaping = false;
  }

let stop t =
  t.stopped <- true;
  ignore (Eio.Promise.try_resolve t.stop_resolver ())

(* The boot residue sweep. A per-session endpoint directory whose session no
   longer exists in the store is residue of a removed session — nothing will
   ever rebind or clean it — so a boot removes it. The claim set is every
   stored session, never a lineage subset: a routine run or a served root
   binds a leaf in the same tree with no delegation backlink, and the sweep
   must not sever a live root's endpoint. A digest leaf cannot be inverted,
   so leaves resolve against the store's session index. Nothing running is
   touched: a live agent holds its own fence and endpoint, a parent agent's
   recovery re-drives its unfinished delegations, and a frontend's next dial
   starts whatever is dormant. *)
let sweep_endpoints t =
  let leaf_root = Filename.concat t.socket_base "s" in
  let leaves =
    match Sys.readdir leaf_root with
    | entries -> Array.to_list entries
    | exception Sys_error _ -> []
  in
  if leaves <> [] then
    match Mentat_store.Session.scan t.store with
    | Error error ->
        Eio.traceln "broker: endpoint residue sweep skipped: %s"
          (Mentat_store.Session.Error.message error)
    | Ok (documents, corrupt) ->
        let claimed = Hashtbl.create 16 in
        List.iter
          (fun document ->
            let session = Mentat_store.Session.Document.session document in
            Hashtbl.replace claimed
              (socket_leaf
                 ~session:
                   (Mentat_session.Id.to_string (Mentat_session.id session)))
              ())
          documents;
        (* Existence claims a leaf, not decodability: a session this binary
           cannot decode — an older sweeper meeting newer documents across an
           upgrade — still exists, and its agent may be live behind the leaf.
           The corrupt facts carry the id parsed from the store path, which
           is all a claim needs. *)
        List.iter
          (fun (fact : Mentat_store.Session.Corrupt.t) ->
            match fact.Mentat_store.Session.Corrupt.id with
            | Some id ->
                Hashtbl.replace claimed
                  (socket_leaf ~session:(Mentat_session.Id.to_string id))
                  ()
            | None -> ())
          corrupt;
        List.iter
          (fun leaf ->
            if not (Hashtbl.mem claimed leaf) then
              Mentat_server.Bind.remove_endpoint
                ~dir:(Lpath.Abs.of_string_exn (Filename.concat leaf_root leaf)))
          leaves

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
  environment:(string * string) list ->
  deadline_s:float option ->
  respawns:int ->
  [ `Settled | `Failed of failure ]

type materialize_stub = Engine.t -> child:Mentat_session.Id.t -> unit

(* The stub keeps the real send's per-target serialization — its own lock
   registry — so an ordering-sensitive engine test observes the primitive's
   contract, not a mock's looser one. It has no clock, so the lock wait is
   unbounded; a stub that never returns is a test bug, not a case to serve.
   The optional supervise script answers each supervision request with its
   outcome; the stub fires exactly one of the caller's sinks per call — the
   real verb's contract — and holds no table, so it never dedups a
   re-supervision, exactly as the real broker re-governs a session whose
   previous supervision has drained. The optional materialize script
   receives the full request — the engine record and the child — and,
   table-less again, sees every re-materialization; the real verb's
   per-child idempotence and its forked, non-blocking observation are the
   script's to model. *)
type stub = {
  send : send_stub;
  supervise : supervise_stub option;
  materialize : materialize_stub option;
  locks : (string, Eio.Mutex.t) Hashtbl.t;
}

type t = Real of broker | Stub of stub

let no_processes op =
  invalid_arg
    (Printf.sprintf "Mentat_broker.%s: a test stub performs no process work" op)

let create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now =
  Real (create ~sw ~stdenv ~store ~resolve_bin ~socket_base ~log_dir ~now)

let for_tests ?supervise ?materialize ~send () =
  Stub { send; supervise; materialize; locks = Hashtbl.create 4 }

let materialize t engine ~child =
  match t with
  | Real b -> materialize b engine ~child
  | Stub { materialize = None; _ } -> no_processes "materialize"
  | Stub { materialize = Some script; _ } -> script engine ~child

let supervise t ~session ~environment ?deadline_s ?respawns ~on_settled
    ~on_failure () =
  match t with
  | Real b ->
      supervise b ~session ~environment ?deadline_s ?respawns ~on_settled
        ~on_failure ()
  | Stub { supervise = None; _ } -> no_processes "supervise"
  | Stub { supervise = Some script; _ } ->
      (match
         script ~session ~environment ~deadline_s
           ~respawns:(Option.value respawns ~default:max_respawns)
       with
      | `Settled -> on_settled ()
      | `Failed failure -> on_failure failure);
      `Supervising

let serve t ~session ~environment () =
  match t with
  | Real b -> serve b ~session ~environment ()
  | Stub _ -> no_processes "serve"

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

let sweep_endpoints t =
  match t with
  | Real b -> sweep_endpoints b
  | Stub _ -> no_processes "sweep_endpoints"

let stop t = match t with Real b -> stop b | Stub _ -> ()
