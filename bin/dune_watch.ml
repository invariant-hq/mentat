(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Health = Mentat_workspace.Health
module Command = Mentat_workspace_io.Command

let log_src =
  Logs.Src.create "mentat.dune.watch" ~doc:"Build watch supervision"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Mode = struct
  type t = Auto | Observe
end

type mono = Mono : _ Eio.Time.Mono.t -> mono

type t = {
  rpc : Mentat_ocaml_dune_rpc.Instance.t;
  capability : Mentat_workspace_io.t;
  mono : mono;
  sw : Eio.Switch.t;
  root : Lpath.Abs.t;
  run_id : string;
  mode : Mode.t;
  program : string list option;
  targets : string list;
  mutable word : Mentat_ocaml_dune_rpc.Watch.word;
  mutable engaged : bool;
  mutable stopped : bool;
  mutable session : Command.Session.t option;
  mutable mirror : Mentat_ocaml_dune_rpc.Mirror.t option;
}

(* The spawn-to-respawn pause, and the cadence at which a foreign watch's
   continued existence and a supervised child's fate are re-checked. Both are
   derived comfort constants, not knobs. *)
let restart_pause_s = 1.0
let poll_s = 0.25
let foreign_recheck_s = 2.0

(* A build daemon's SIGTERM work is real — cancel the running build, unlink
   socket and registry entry in its exit handlers — so its grace is scaled to
   a daemon, not to the 0.2 s a tool child gets: a SIGKILL that beats the
   exit handlers recreates the stale endpoint state supervision exists to
   avoid. This path runs once per life. *)
let stop_grace_s = 2.0

let make ~rpc ~capability ~mono ~sw ~root ~run_id ~mode ~program ~targets =
  {
    rpc;
    capability;
    mono = Mono mono;
    sw;
    root;
    run_id;
    mode;
    program;
    targets;
    word = Mentat_ocaml_dune_rpc.Watch.Defer;
    engaged = false;
    stopped = false;
    session = None;
    mirror = None;
  }

let sleep t seconds =
  let (Mono mono) = t.mono in
  Eio.Time.Mono.sleep mono seconds

let observed t =
  Mentat_ocaml_dune_rpc.Instance.Snapshot.health
    (Mentat_ocaml_dune_rpc.Instance.snapshot t.rpc)

let health t = Mentat_ocaml_dune_rpc.Watch.compose t.word ~observed:(observed t)

let word_equal a b =
  match (a, b) with
  | Mentat_ocaml_dune_rpc.Watch.Defer, Mentat_ocaml_dune_rpc.Watch.Defer ->
      true
  | Mentat_ocaml_dune_rpc.Watch.Announce a, Mentat_ocaml_dune_rpc.Watch.Announce b
    ->
      Health.equal a b
  | ( ( Mentat_ocaml_dune_rpc.Watch.Defer
      | Mentat_ocaml_dune_rpc.Watch.Announce _ ),
      _ ) ->
      false

let set_word t word =
  if not (word_equal t.word word) then begin
    t.word <- word;
    Log.info (fun m ->
        m "dune watch supervisor: %s"
          (match word with
          | Mentat_ocaml_dune_rpc.Watch.Defer -> "deferring to the observer"
          | Mentat_ocaml_dune_rpc.Watch.Announce health ->
              Format.asprintf "%a" Health.pp health))
  end

let observed_live t =
  match observed t with Health.Live _ -> true | _ -> false

let probe t = Mentat_ocaml_dune_rpc.Instance.probe t.rpc

let private_dir t =
  Filename.concat (Lpath.Abs.to_string t.root)
    (Filename.concat ".mentat" (Filename.concat "run" t.run_id))

(* The host side is unconfined; directory maintenance is plain Unix, lexical,
   and never traverses a symlink it did not create. *)
let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdir_p parent;
    try Unix.mkdir dir 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      (match Sys.readdir path with
      | entries ->
          Array.iter
            (fun entry -> remove_tree (Filename.concat path entry))
            entries
      | exception Sys_error _ -> ());
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> ( try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()

let write_self_ignore run_parent =
  let path = Filename.concat run_parent ".gitignore" in
  if not (Sys.file_exists path) then begin
    match open_out_bin path with
    | out ->
        Fun.protect
          ~finally:(fun () -> close_out_noerr out)
          (fun () -> output_string out "*\n")
    | exception Sys_error _ -> ()
  end

let pid_alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception Unix.Unix_error _ -> true

(* A SIGKILLed host cannot clean its own run directory, so each supervisor
   sweeps its dead siblings: any [watch-<pid>] whose pid no longer lives is
   debris, and without the sweep one directory per mentat process would
   accumulate under [.mentat/run] forever. *)
let sweep_stale_run_dirs t =
  let parent = Filename.dirname (private_dir t) in
  match Sys.readdir parent with
  | entries ->
      Array.iter
        (fun entry ->
          let prefix = "watch-" in
          if
            (not (String.equal entry t.run_id))
            && String.starts_with ~prefix entry
          then
            match
              int_of_string_opt
                (String.drop_first (String.length prefix) entry)
            with
            | Some pid when not (pid_alive pid) ->
                remove_tree (Filename.concat parent entry)
            | Some _ | None -> ())
        entries
  | exception Sys_error _ -> ()

let private_registry_dir t =
  Filename.concat (private_dir t) (Filename.concat "dune" "rpc")

(* A fresh life must find an empty private registry: an entry a crashed life
   left behind would flip {!private_entry_registered} before the new child
   serves, and the mirror would advertise a socket that does not answer
   yet. *)
let clear_private_registry t =
  let registry = private_registry_dir t in
  match Sys.readdir registry with
  | entries ->
      Array.iter
        (fun entry -> remove_tree (Filename.concat registry entry))
        entries
  | exception Sys_error _ -> ()

let prepare_private_dir t =
  match
    let dir = private_dir t in
    mkdir_p dir;
    write_self_ignore (Filename.dirname dir);
    clear_private_registry t;
    dir
  with
  | dir -> Ok dir
  | exception Unix.Unix_error (error, _, _) ->
      Error (Unix.error_message error)

let private_entry_registered t =
  match Sys.readdir (private_registry_dir t) with
  | entries -> Array.length entries > 0
  | exception Sys_error _ -> false

let write_mirror t session =
  match
    Mentat_ocaml_dune_rpc.Instance.mirror t.rpc
      ~pid:(Command.Session.pid session)
  with
  | Ok mirror ->
      Log.info (fun m ->
          m "dune watch registry mirror written at %s"
            (Mentat_ocaml_dune_rpc.Mirror.path mirror));
      t.mirror <- Some mirror
  | Error message ->
      Log.warn (fun m -> m "dune watch registry mirror failed: %s" message)

let remove_mirror t =
  match t.mirror with
  | None -> ()
  | Some mirror ->
      Mentat_ocaml_dune_rpc.Mirror.remove mirror;
      t.mirror <- None

(* What dune's own exit handlers would have unlinked, done host-side when
   they could not run: on Linux the sealed route's [bwrap --new-session]
   detaches the child from the signalled group, so SIGTERM never reaches
   dune and its socket and private registry entry survive every shutdown.
   Guarded by a probe so a foreign watch that bound the socket since our
   child died is never broken. *)
let remove_endpoint_debris t =
  if not (probe t) then begin
    (try Unix.unlink (Mentat_ocaml_dune_rpc.Instance.socket_path t.rpc)
     with Unix.Unix_error _ -> ());
    clear_private_registry t
  end

(* The dying words: dune's actual complaint from the captured stderr tail —
   the lock message, a seatbelt EPERM, a broken workspace — is worth more in
   a restart cause than a bare wait status. *)
let dying_words tail =
  let lines =
    List.filter
      (fun line -> not (String.is_empty line))
      (List.map String.trim (String.split_on_char '\n' tail))
  in
  let chosen =
    match
      List.find_opt (fun line -> String.starts_with ~prefix:"Error" line) lines
    with
    | Some line -> Some line
    | None -> ( match List.rev lines with line :: _ -> Some line | [] -> None)
  in
  Option.map
    (fun line ->
      if String.length line <= 80 then line else String.sub line 0 77 ^ "...")
    chosen

let retained_tail_bytes = 4096

let retain_tail previous appended =
  if String.is_empty appended then previous
  else
    let combined = previous ^ appended in
    let length = String.length combined in
    if length <= retained_tail_bytes then combined
    else
      String.sub combined (length - retained_tail_bytes) retained_tail_bytes

let exit_cause session tail =
  match Command.Session.status session with
  | Command.Session.Running -> `Terminated (* unreachable by construction *)
  | Command.Session.Terminated -> `Terminated
  | Command.Session.Exited status ->
      let base =
        match status with
        | `Exited code -> Printf.sprintf "exit %d" code
        | `Signaled signal -> Printf.sprintf "signal %d" signal
      in
      `Exited
        (match dying_words tail with
        | Some words -> base ^ ": " ^ words
        | None -> base)

let start t =
  match t.program with
  | None -> Error "dune does not resolve on the command PATH"
  | Some program -> (
      match prepare_private_dir t with
      | Error message -> Error ("private runtime directory: " ^ message)
      | Ok dir -> (
          let argv =
            program @ [ "build"; "--root"; "."; "--watch" ] @ t.targets
          in
          let cwd =
            Mentat_workspace.Path.root_of
              (Mentat_workspace_io.cwd t.capability)
          in
          match
            Command.start_session t.capability ~sw:t.sw ~cwd ~runtime_dir:dir
              argv
          with
          | Ok session ->
              (* Registered after the session's own teardown resources, so on
                 a release that skipped the explicit {!stop} this hook still
                 runs first (release hooks are LIFO) and the child dies on
                 SIGTERM — its own exit handlers unlinking socket and private
                 registry entry — never on the switch's SIGKILL backstop. The
                 hook reads the shared slot rather than closing over this
                 life's session, so an ended life retains nothing: signalling
                 whatever session is live is correct from every hook, and a
                 settled session is a no-op. *)
              Eio.Switch.on_release t.sw (fun () ->
                  match t.session with
                  | Some session ->
                      Command.Session.signal ~grace:stop_grace_s session
                  | None -> ());
              Ok session
          | Error error ->
              Error (Format.asprintf "%a" Command.Error.pp error)))

(* One supervised life: follow the child's output until it settles — the
   wait doubles as the poll cadence for the private registry entry, the
   mirror, and the observer's attachment — and keep the stderr tail as the
   life's dying words. Returns whether this life reached Live and how it
   ended. *)
let live_once t session =
  let reached = ref false in
  let tail = ref "" in
  let rec loop cursor =
    let chunk =
      Command.Session.await session ~from:cursor
        ~cancelled:(fun () -> t.stopped)
        ~seconds:poll_s
    in
    tail := retain_tail !tail chunk.Command.Session.stderr;
    match chunk.Command.Session.status with
    | Command.Session.Running ->
        if not t.stopped then begin
          if Option.is_none t.mirror && private_entry_registered t then
            write_mirror t session;
          if (not !reached) && observed_live t then reached := true;
          loop chunk.Command.Session.next
        end
    | Command.Session.Exited _ | Command.Session.Terminated -> ()
  in
  loop Command.Session.Cursor.zero;
  remove_mirror t;
  (!reached, exit_cause session !tail)

(* A foreign watch is observed, never signalled: stay while the observer
   holds a connection (or, between its reconnects, while the socket still
   answers), and hand control back when both are gone. The machine keeps
   announcing [Probing] here so a watch the registry cannot see still
   renders honestly — an observed attachment wins in the composition
   either way. *)
let rec wait_while_foreign t =
  sleep t foreign_recheck_s;
  if t.stopped then ()
  else if observed_live t || probe t then wait_while_foreign t

(* The machine. [deaths] counts consecutive lives that died before reaching
   Live; the give-up rule is {!Mentat_ocaml_dune_rpc.Watch.after_death}. A
   spawn that exits while the socket answers forwarded its build to a lock
   holder — that is a foreign watch discovered the only way dune reports it,
   never a death. *)
let rec cycle t deaths =
  if not t.stopped then begin
    set_word t
      (Mentat_ocaml_dune_rpc.Watch.Announce Mentat_workspace.Health.Probing);
    if observed_live t || probe t then begin
      wait_while_foreign t;
      cycle t 0
    end
    else spawn t deaths
  end

and spawn t deaths =
  if not t.stopped then begin
    set_word t
      (Mentat_ocaml_dune_rpc.Watch.Announce Mentat_workspace.Health.Starting);
    match start t with
    | Error message ->
        Log.warn (fun m -> m "dune watch spawn failed: %s" message);
        death t deaths ~reached:false ~cause:("spawn failed: " ^ message)
    | Ok session -> (
        Log.info (fun m ->
            m "dune watch spawned pid %d" (Command.Session.pid session));
        t.session <- Some session;
        Mentat_ocaml_dune_rpc.Instance.pin t.rpc
          ~pid:(Command.Session.pid session)
          (* The requested targets are known and carry no lint alias until
             the lint lane's ownership slice threads [dune.lint_alias]
             here. *)
          ~lint:false;
        let reached, cause = live_once t session in
        Mentat_ocaml_dune_rpc.Instance.unpin t.rpc;
        t.session <- None;
        remove_endpoint_debris t;
        if not t.stopped then
          match cause with
          | `Terminated -> ()
          | `Exited cause ->
              if probe t then begin
                wait_while_foreign t;
                cycle t 0
              end
              else death t deaths ~reached ~cause)
  end

and death t deaths ~reached ~cause =
  if not t.stopped then
    match Mentat_ocaml_dune_rpc.Watch.after_death ~reached ~deaths with
    | `Give_up ->
        set_word t
          (Mentat_ocaml_dune_rpc.Watch.Announce
             (Health.Off Health.Off.Gave_up))
    | `Retry deaths ->
        set_word t
          (Mentat_ocaml_dune_rpc.Watch.Announce
             (Health.Restarting (Health.Restart.Exited cause)));
        sleep t restart_pause_s;
        cycle t deaths

let stop t =
  if not t.stopped then begin
    t.stopped <- true;
    (match t.session with
    | Some session ->
        t.session <- None;
        Command.Session.signal ~grace:stop_grace_s session
    | None -> ());
    Mentat_ocaml_dune_rpc.Instance.unpin t.rpc;
    remove_mirror t;
    (* The private directory exists exactly when this supervisor spawned, so
       a foreign-only or observe session neither probes the socket nor
       touches anything at shutdown. *)
    if Sys.file_exists (private_dir t) then begin
      remove_endpoint_debris t;
      remove_tree (private_dir t)
    end;
    set_word t Mentat_ocaml_dune_rpc.Watch.Defer
  end

let engage t =
  if not t.engaged then begin
    t.engaged <- true;
    Eio.Switch.on_release t.sw (fun () -> stop t);
    match t.mode with
    | Mode.Observe -> ()
    | Mode.Auto -> (
        match t.program with
        | None ->
            set_word t
              (Mentat_ocaml_dune_rpc.Watch.Announce
                 (Health.Off Health.Off.No_dune))
        | Some _ ->
            Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
                sweep_stale_run_dirs t;
                cycle t 0;
                `Stop_daemon))
  end
