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

(* The machine's own states. The observer's view is composed in at
   projection time ({!health}), never stored: an attached connection is
   ground truth wherever the machine believes itself to be. *)
type state =
  | Idle
  | No_dune
  | Probing
  | Foreign
  | Starting
  | Live_ours
  | Restarting of string
  | No_server
  | Gave_up

type net = Net : _ Eio.Net.t -> net
type clock = Clock : _ Eio.Time.clock -> clock
type mono = Mono : _ Eio.Time.Mono.t -> mono

type t = {
  net : net;
  clock : clock;
  mono : mono;
  capability : Mentat_workspace_io.t;
  root : Lpath.Abs.t;
  run_id : string;
  mode : Mode.t;
  program : string list option;
  targets : string list;
  env : string -> string option;
  observed : unit -> Health.t;
  mutable state : state;
  mutable engaged : bool;
  mutable sw : Eio.Switch.t option;
  mutable session : Command.Session.t option;
  mutable mirror : Mentat_ocaml_dune_rpc.Mirror.t option;
}

(* The spawn-to-respawn pause, and the cadence at which a foreign watch's
   continued existence and a supervised child's fate are re-checked. Both are
   derived comfort constants, not knobs. *)
let restart_pause_s = 1.0
let poll_s = 0.25
let foreign_recheck_s = 2.0

let make ~net ~clock ~mono ~capability ~root ~run_id ~mode ~program ~targets
    ~env ~observed () =
  {
    net = Net net;
    clock = Clock clock;
    mono = Mono mono;
    capability;
    root;
    run_id;
    mode;
    program;
    targets;
    env;
    observed;
    state = Idle;
    engaged = false;
    sw = None;
    session = None;
    mirror = None;
  }

let sleep t seconds =
  let (Mono mono) = t.mono in
  Eio.Time.Mono.sleep mono seconds

let set_state t state =
  if t.state != state then begin
    t.state <- state;
    Log.info (fun m ->
        m "dune watch supervisor: %s"
          (match state with
          | Idle -> "idle"
          | No_dune -> "no dune"
          | Probing -> "probing"
          | Foreign -> "foreign"
          | Starting -> "starting"
          | Live_ours -> "live (ours)"
          | Restarting cause -> "restarting (" ^ cause ^ ")"
          | No_server -> "no server"
          | Gave_up -> "gave up"))
  end

let socket_path t =
  Filename.concat (Lpath.Abs.to_string t.root)
    (Filename.concat "_build" (Filename.concat ".rpc" "dune"))

let private_dir t =
  Filename.concat (Lpath.Abs.to_string t.root)
    (Filename.concat ".mentat" (Filename.concat "run" t.run_id))

let observed_live t =
  match t.observed () with Health.Live _ -> true | _ -> false

let probe t =
  let (Net net) = t.net in
  let (Clock clock) = t.clock in
  Mentat_ocaml_dune_rpc.Probe.socket ~net ~clock
    ~root:(Lpath.Abs.to_string t.root)
    ~path:(socket_path t) ()

(* The host side is unconfined; directory creation is plain Unix. The run
   directory ignores itself so a project that tracks [.mentat] never sees
   transient registry state in its status. *)
let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdir_p parent;
    try Unix.mkdir dir 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

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

let prepare_private_dir t =
  match
    let dir = private_dir t in
    mkdir_p dir;
    write_self_ignore (Filename.dirname dir);
    dir
  with
  | dir -> Ok dir
  | exception Unix.Unix_error (error, _, _) ->
      Error (Unix.error_message error)

let private_entry_registered t =
  let registry =
    Filename.concat (private_dir t) (Filename.concat "dune" "rpc")
  in
  match Sys.readdir registry with
  | entries -> Array.length entries > 0
  | exception Sys_error _ -> false

let write_mirror t session =
  match
    Mentat_ocaml_dune_rpc.Mirror.write ~env:t.env
      ~root:(Lpath.Abs.to_string t.root)
      ~pid:(Command.Session.pid session)
      ~socket:(socket_path t)
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

let session_running session =
  match Command.Session.status session with
  | Command.Session.Running -> true
  | Command.Session.Exited _ | Command.Session.Terminated -> false

let exit_cause session =
  match Command.Session.status session with
  | Command.Session.Running -> `Terminated (* unreachable by construction *)
  | Command.Session.Terminated -> `Terminated
  | Command.Session.Exited (`Exited code) ->
      `Exited (Printf.sprintf "exit %d" code)
  | Command.Session.Exited (`Signaled signal) ->
      `Exited (Printf.sprintf "signal %d" signal)

let start t =
  match t.program with
  | None -> Error "dune does not resolve on the command PATH"
  | Some program -> (
      match t.sw with
      | None -> Error "supervisor is not engaged"
      | Some sw -> (
          match prepare_private_dir t with
          | Error message ->
              Error ("private runtime directory: " ^ message)
          | Ok dir -> (
              let argv =
                program
                @ [ "build"; "--root"; "."; "--watch" ]
                @ t.targets
              in
              let cwd =
                Mentat_workspace.Path.root_of
                  (Mentat_workspace_io.cwd t.capability)
              in
              match
                Command.start_session t.capability ~sw ~cwd
                  ~env_override:[ ("XDG_RUNTIME_DIR", dir) ]
                  argv
              with
              | Ok session -> Ok session
              | Error error ->
                  Error (Format.asprintf "%a" Command.Error.pp error))))

(* One supervised life: poll the child until it settles, mirroring the
   registry entry once the child has registered privately and marking Live
   when the shared observer attaches. Returns whether this life reached Live
   and how it ended. *)
let live_once t session =
  let reached = ref false in
  let rec loop () =
    if session_running session then begin
      if Option.is_none t.mirror && private_entry_registered t then
        write_mirror t session;
      if (not !reached) && observed_live t then begin
        reached := true;
        set_state t Live_ours
      end;
      sleep t poll_s;
      loop ()
    end
  in
  loop ();
  remove_mirror t;
  (!reached, exit_cause session)

(* A foreign watch is observed, never signalled: stay while the observer
   holds a connection (or, between its reconnects, while the socket still
   answers), and hand control back when both are gone. *)
let rec wait_while_foreign t =
  sleep t foreign_recheck_s;
  if observed_live t then wait_while_foreign t
  else if probe t then wait_while_foreign t
  else ()

(* The machine. [deaths] counts consecutive lives that died before reaching
   Live; a life that reached Live resets it, and two in a row give up. A
   spawn that exits while the socket answers forwarded its build to a lock
   holder — that is a foreign watch discovered the only way dune reports it,
   never a death. *)
let rec cycle t deaths =
  set_state t Probing;
  if observed_live t || probe t then begin
    set_state t Foreign;
    wait_while_foreign t;
    cycle t 0
  end
  else spawn t deaths

and spawn t deaths =
  set_state t Starting;
  match start t with
  | Error message ->
      Log.warn (fun m -> m "dune watch spawn failed: %s" message);
      death t deaths ~reached:false ~cause:"spawn failed"
  | Ok session -> (
      Log.info (fun m ->
          m "dune watch spawned pid %d" (Command.Session.pid session));
      t.session <- Some session;
      let reached, cause = live_once t session in
      t.session <- None;
      match cause with
      | `Terminated -> ()
      | `Exited cause ->
          if probe t then begin
            set_state t Foreign;
            wait_while_foreign t;
            cycle t 0
          end
          else death t deaths ~reached ~cause)

and death t deaths ~reached ~cause =
  let deaths = if reached then 1 else deaths + 1 in
  if deaths >= 2 then set_state t Gave_up
  else begin
    set_state t (Restarting cause);
    sleep t restart_pause_s;
    cycle t deaths
  end

let shutdown t =
  (match t.session with
  | Some session ->
      t.session <- None;
      Command.Session.signal session
  | None -> ());
  remove_mirror t

let engage t ~sw =
  if not t.engaged then begin
    t.engaged <- true;
    t.sw <- Some sw;
    Eio.Switch.on_release sw (fun () -> shutdown t);
    Eio.Fiber.fork_daemon ~sw (fun () ->
        (match t.mode with
        | Mode.Observe -> set_state t No_server
        | Mode.Auto -> (
            match t.program with
            | None -> set_state t No_dune
            | Some _ -> cycle t 0));
        `Stop_daemon)
  end

let health t =
  let observed = t.observed () in
  match (t.state, observed) with
  | Live_ours, Health.Live { owner = _; phase } ->
      Health.Live { owner = Health.Owner.Ours; phase }
  | Live_ours, _ ->
      (* The child lives; the observer is between reconnects. *)
      Health.Starting
  | _, (Health.Live _ as live) -> live
  | (Idle | Foreign), _ -> observed
  | No_dune, _ -> Health.Off Health.Off.No_dune
  | Probing, _ -> Health.Probing
  | Starting, _ -> Health.Starting
  (* The supervisor restarts only on a death in this slice, so the cause is
     always an exit description. *)
  | Restarting cause, _ -> Health.Restarting (Health.Restart.Exited cause)
  | No_server, _ -> Health.Off Health.Off.No_server
  | Gave_up, _ -> Health.Off Health.Off.Gave_up

let owns_lock t =
  match t.state with
  | Starting | Live_ours -> true
  | Idle | No_dune | Probing | Foreign | Restarting _ | No_server | Gave_up ->
      false
