(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* A hermetic fake of Dune's RPC server, for the notices blackbox suites.

   mentat's observer is registry-first: it reads Dune's XDG RPC registry to
   find an already-running [dune build --watch], connects to its socket, and
   holds the watch's [diagnostic] and [progress] long-polls. This fake stands
   in for that watch WITHOUT any dune or compiler: it writes a registry entry
   pointing at its own Unix socket and answers the real dune-rpc client
   handshake (initialize / version_menu) and the poll protocol with canned
   state, using dune-rpc's own wire types so the exchange stays faithful to
   the protocol mentat's client speaks. It exercises the fixed client
   end-to-end; it is not a general Dune server (it only implements what the
   observer calls).

   Two modes:

   - [--scenario failing|clean]: static. The first poll of each stream answers
     with the scenario's state; every later poll parks unanswered — a server
     with no further change.
   - [--state-file PATH]: dynamic. PATH holds one word — [clean], [failing],
     or [error2] — re-read on a short tick; a change answers the parked polls
     with dune's own delta shape (Remove the advertised diagnostics, Add the
     new ones under fresh ids, a progress value when it differs). A cram's
     tool command can therefore flip the build state mid-turn, exactly as a
     rebuild would.

   Usage: mentat_fake_dune_rpc_server --root DIR
            (--scenario failing|clean | --state-file PATH) --ready FILE
            [--socket-at-root]
   Discovery shares the process XDG environment, so the caller must run it
   under the same HOME/XDG_* as the mentat it should be visible to.
   [--socket-at-root] binds the socket at DIR/_build/.rpc/dune — where a real
   watch serves — so a supervisor probing that pinned path finds it.

   The binary doubles as a fake [dune] executable: invoked as
   [dune build ...] (symlink it to a PATH entry named [dune]) it appends its
   argv to [fake-dune-argv] in the cwd — the spawn marker a cram asserts —
   consults [fake-dune-mode] in the cwd ([exit:N] dies at once, [exit-once:N]
   dies once and rewrites itself to [serve]; [hang] serves but answers only
   its first flush_file_watcher and makes forwarders sleep forever — the
   whole hung-watch scenario; [slow] answers every flush but still makes
   forwarders sleep forever — a slow build, not a hang, so verification
   clears; [hang-flush] parks every flush, the blocked-file-watcher
   scenario; [serve] is the default), then
   serves the watch protocol: registry entry under its own XDG_RUNTIME_DIR
   (the private directory a supervisor hands it), socket at
   [_build/.rpc/dune], dynamic state from [dune-state] in the cwd. A shim
   spawned while that socket already answers prints one line and exits 0,
   exactly as dune forwards one build to a lock holder and exits. *)

module Drpc = Dune_rpc.Private
module Conv = Drpc.Conv

type mode = Static of string | Dynamic of string

(* The negotiated dune version, learned from the client's initialize request and
   used for every subsequent Conv en/decode. dune-rpc.3.24 advertises (3, 24);
   reading it rather than pinning keeps the fake correct if the client changes
   what it sends. *)
let session_version = ref (3, 24)

(* Progress values are per-state constants, so physical equality is the
   cheap "same progress as last sent" test the long-poll park rides on. *)
let progress_equal = Option.equal (fun a b -> a == b)

let message_for_state = function
  | "failing" ->
      Some
        "This expression has type string but an expression was expected of \
         type int"
  | "error2" -> Some "Unbound value restock"
  (* A lint-shaped head on the watch stream: everything the stream carries
     is a build finding whoever owns the watch — the state exists to pin
     exactly that. *)
  | "marker" ->
      Some
        "comparison through List.length is a needless emptiness test \
         [needless-list-length]"
  | _ -> None

let progress_for_state = function
  | "clean" -> Drpc.Progress.Success
  | _ -> Drpc.Progress.Failed

let next_diag_id = ref 0

let make_diag ~id ~message =
  {
    Drpc.Diagnostic.targets = [];
    id = Drpc.Diagnostic.Id.create id;
    message = Pp.verbatim message;
    loc = None;
    severity = Some Drpc.Diagnostic.Error;
    promotion = [];
    directory = None;
    related = [];
  }

let diags_for_state state =
  match message_for_state state with
  | None -> []
  | Some message ->
      incr next_diag_id;
      [ (!next_diag_id, message) ]

(* --- Registry advertisement ------------------------------------------------ *)

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdir_p parent;
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let advertise ~root ~socket =
  let xdg = Xdg.create ~env:Sys.getenv_opt () in
  let config = Drpc.Registry.Config.create xdg in
  let entry =
    Drpc.Registry.Dune.create ~where:(`Unix socket) ~root ~pid:(Unix.getpid ())
  in
  let (`Caller_should_write file) =
    Drpc.Registry.Config.register config entry
  in
  write_file file.Drpc.Registry.File.path file.Drpc.Registry.File.contents;
  file.Drpc.Registry.File.path

(* --- Responses ------------------------------------------------------------- *)

(* One writer mutex: in dynamic mode the reader thread and the ticker both
   respond on the same channel. *)
let out_mutex = Mutex.create ()

let respond oc id result =
  Mutex.lock out_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock out_mutex)
    (fun () ->
      Csexp.to_channel oc
        (Conv.to_sexp Drpc.Packet.sexp (Drpc.Packet.Response (id, result)));
      flush oc)

let error ~message =
  Error
    (Drpc.Response.Error.create ~kind:Drpc.Response.Error.Invalid_request
       ~message ())

let diag_events_payload events =
  Conv.to_sexp
    (Conv.option (Conv.list Drpc.Diagnostic.Event.sexp))
    (Some events)

let progress_payload progress =
  Conv.to_sexp (Conv.option Drpc.Progress.sexp) (Some progress)

(* flush_file_watcher: the supervisor's liveness verification. A healthy fake
   answers [`Ok]; a fake playing a wedged event loop parks the request
   forever. [flush_answer_limit]: [None] answers every flush, [Some n]
   answers the first [n] of this process's life and parks the rest — so a
   watch can pass its first-flush self-test and then hang verification.
   Plain refs on purpose: connection threads share one runtime lock (OCaml
   threads, single domain), so the increment cannot tear — do not "fix"
   this with a mutex unless the fake ever moves to domains. The same holds
   for [session_version]. *)
let flush_answer_limit : int option ref = ref None
let flush_seen = ref 0

let flush_payload =
  let ok = Conv.constr "ok" Conv.unit (fun () -> `Ok) in
  let not_in_watch_mode =
    Conv.constr "not_in_watch_mode" Conv.unit (fun () -> `Not_in_watch_mode)
  in
  let conv =
    Conv.sum
      [ Conv.econstr ok; Conv.econstr not_in_watch_mode ]
      (function
        | `Ok -> Conv.case () ok
        | `Not_in_watch_mode -> Conv.case () not_in_watch_mode)
  in
  Conv.to_sexp conv `Ok

let adds diags =
  List.map
    (fun (id, message) -> Drpc.Diagnostic.Event.Add (make_diag ~id ~message))
    diags

let removes diags =
  List.map
    (fun (id, message) -> Drpc.Diagnostic.Event.Remove (make_diag ~id ~message))
    diags

(* --- Dynamic-mode state ---------------------------------------------------- *)

(* One logical watch, one connection at a time in practice; the bookkeeping
   still supports several (mentat reconnects with a fresh stream after EOF).
   All of it is guarded by [dyn_mutex]; the ticker owns transitions. *)
type dyn_conn = {
  oc : out_channel;
  mutable diag_sent : string option;  (* the state whose set was last sent *)
  mutable advertised : (int * string) list;  (* ids the client holds *)
  mutable diag_parked : Drpc.Id.t option;
  mutable prog_sent : Drpc.Progress.t option;
  mutable prog_parked : Drpc.Id.t option;
  mutable closed : bool;
}

let dyn_mutex = Mutex.create ()
let dyn_conns : dyn_conn list ref = ref []
let current_state = ref "clean"

let with_dyn f =
  Mutex.lock dyn_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock dyn_mutex) f

let read_state_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> (
      match String.split_on_char '\n' (String.trim contents) with
      | first :: _ when not (String.equal first "") -> Some first
      | _ -> None)
  | exception Sys_error _ -> None

let answer_diag conn id =
  let state = !current_state in
  let previous = conn.advertised in
  let next = diags_for_state state in
  conn.diag_sent <- Some state;
  conn.advertised <- next;
  respond conn.oc id (Ok (diag_events_payload (removes previous @ adds next)))

let answer_progress conn id =
  let progress = progress_for_state !current_state in
  conn.prog_sent <- Some progress;
  respond conn.oc id (Ok (progress_payload progress))

(* The ticker: re-read the state file; on change, answer whichever parked
   polls now have news. A progress poll whose value is unchanged stays parked —
   dune's own long-poll coalesces equal states the same way. *)
let ticker state_file =
  let rec loop () =
    Thread.delay 0.05;
    (match read_state_file state_file with
    | None -> ()
    | Some state ->
        with_dyn (fun () ->
            if not (String.equal state !current_state) then
              current_state := state;
            List.iter
              (fun conn ->
                if not conn.closed then begin
                  (* A peer can vanish between the reader noticing EOF and
                     this write; with SIGPIPE ignored that raises, and a dead
                     ticker would starve every later flip. Contain it. *)
                  (match (conn.diag_parked, conn.diag_sent) with
                  | Some id, sent
                    when not (Option.equal String.equal sent (Some state)) ->
                      conn.diag_parked <- None;
                      (try answer_diag conn id
                       with Sys_error _ -> conn.closed <- true)
                  | _ -> ());
                  match (conn.prog_parked, conn.prog_sent) with
                  | Some id, sent
                    when not
                           (progress_equal sent
                              (Some (progress_for_state state))) ->
                      conn.prog_parked <- None;
                      (try answer_progress conn id
                       with Sys_error _ -> conn.closed <- true)
                  | _ -> ()
                end)
              !dyn_conns;
            dyn_conns := List.filter (fun conn -> not conn.closed) !dyn_conns));
    loop ()
  in
  loop ()

(* --- Request handling ------------------------------------------------------ *)

(* The handshake half every mode shares. *)
let handle_handshake oc id (call : Drpc.Call.t) =
  let method_ = Drpc.Method.Name.to_string call.Drpc.Call.method_ in
  if String.equal method_ "initialize" then begin
    (match Drpc.Initialize.Request.of_call call ~version:!session_version with
    | Ok req -> session_version := Drpc.Initialize.Request.dune_version req
    | Error _ -> ());
    respond oc id
      (Ok
         (Drpc.Initialize.Response.to_response
            (Drpc.Initialize.Response.create ())))
  end
  else if String.equal method_ "version_menu" then
    match
      Drpc.Version_negotiation.Request.of_call call ~version:!session_version
    with
    | Ok (Drpc.Version_negotiation.Request.Menu offered) ->
        (* Select the highest version the client offered for each method: the
           client offered them, so it supports them, and this keeps every
           method at its current generation. *)
        let selected =
          List.map
            (fun (name, versions) -> (name, List.fold_left max 0 versions))
            offered
        in
        respond oc id
          (Ok
             (Drpc.Version_negotiation.Response.to_response
                (Drpc.Version_negotiation.Response.create selected)))
    | Error _ -> respond oc id (error ~message:"malformed version_menu request")
  else respond oc id (error ~message:("unsupported method: " ^ method_))

(* One connection: [ic]/[oc] share [fd], so the caller owns closing [fd] once;
   here we only read requests, answer them, and flush. *)
let serve mode fd =
  let ic = Unix.in_channel_of_descr fd in
  let oc = Unix.out_channel_of_descr fd in
  let dyn =
    match mode with
    | Static _ -> None
    | Dynamic _ ->
        let conn =
          {
            oc;
            diag_sent = None;
            advertised = [];
            diag_parked = None;
            prog_sent = None;
            prog_parked = None;
            closed = false;
          }
        in
        with_dyn (fun () -> dyn_conns := conn :: !dyn_conns);
        Some conn
  in
  let answered_diag = ref false and answered_prog = ref false in
  let handle id (call : Drpc.Call.t) =
    let method_ = Drpc.Method.Name.to_string call.Drpc.Call.method_ in
    if String.equal method_ "poll/diagnostic" then
      match (mode, dyn) with
      | Static scenario, _ ->
          (* Static long-poll: the first poll answers the scenario's set,
             every later one parks — a server with no further change. *)
          if !answered_diag then ()
          else begin
            answered_diag := true;
            respond oc id
              (Ok (diag_events_payload (adds (diags_for_state scenario))))
          end
      | Dynamic _, Some conn ->
          with_dyn (fun () ->
              if
                Option.equal String.equal conn.diag_sent (Some !current_state)
              then conn.diag_parked <- Some id
              else answer_diag conn id)
      | Dynamic _, None -> assert false
    else if String.equal method_ "poll/progress" then
      match (mode, dyn) with
      | Static scenario, _ ->
          if !answered_prog then ()
          else begin
            answered_prog := true;
            respond oc id (Ok (progress_payload (progress_for_state scenario)))
          end
      | Dynamic _, Some conn ->
          with_dyn (fun () ->
              let progress = progress_for_state !current_state in
              if progress_equal conn.prog_sent (Some progress) then
                conn.prog_parked <- Some id
              else answer_progress conn id)
      | Dynamic _, None -> assert false
    else if String.equal method_ "flush-file-watcher" then begin
      incr flush_seen;
      match !flush_answer_limit with
      | Some limit when !flush_seen > limit -> () (* parked: a wedged loop *)
      | Some _ | None -> respond oc id (Ok flush_payload)
    end
    else handle_handshake oc id call
  in
  let rec loop () =
    match Csexp.input ic with
    | Error _ -> () (* client closed the connection *)
    | Ok sexp -> (
        match Conv.of_sexp Drpc.Packet.sexp ~version:!session_version sexp with
        | Ok (Drpc.Packet.Request (id, call)) ->
            handle id call;
            loop ()
        | Ok (Drpc.Packet.Notification _) | Ok (Drpc.Packet.Response _) ->
            loop ()
        | Error _ -> ())
  in
  loop ();
  (match dyn with
  | Some conn -> with_dyn (fun () -> conn.closed <- true)
  | None -> ());
  try flush oc with Sys_error _ -> ()

(* --- Entry point ----------------------------------------------------------- *)

let realpath path =
  match Unix.realpath path with p -> p | exception Unix.Unix_error _ -> path

(* Serve [mode] forever: register [socket] (an absolute path) in the registry
   this process's own XDG environment designates, bind it -- via [bind_in]
   when the absolute path would overflow sun_path: chdir there and bind the
   basename -- and answer one connection at a time. mentat holds one
   long-poll connection; probes connect, handshake, and close. *)
let serve_forever ~mode ~root ~socket ~bind_in ~steal ~ready =
  (* [bind_in] chdirs below, so a relative ready path is pinned to the
     caller's directory first. *)
  let ready =
    if String.equal ready "" || Filename.is_relative ready = false then ready
    else Filename.concat (Unix.getcwd ()) ready
  in
  (match mode with
  | Dynamic path ->
      (match read_state_file path with
      | Some state -> current_state := state
      | None -> current_state := "clean");
      ignore (Thread.create ticker path)
  | Static _ -> ());
  let listen = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let bind_path =
    match bind_in with
    | None -> socket
    | Some dir ->
        Unix.chdir dir;
        Filename.basename socket
  in
  (* A standalone server steals a stale socket; the shim must not — between
     its occupied-probe and its bind another shim (the supervised watch, or
     a racing forwarder) may have bound, and unlink-then-bind would steal a
     socket that is very much alive. [EADDRINUSE] is the shim's cue to be a
     forwarder instead, and it propagates to the caller. Advertising and the
     exit cleanup come after the bind for the same reason: a loser must
     neither register nor, at exit, unlink the winner's socket. *)
  if steal then (try Unix.unlink bind_path with Unix.Unix_error _ -> ());
  Unix.bind listen (Unix.ADDR_UNIX bind_path);
  Unix.listen listen 8;
  let registry_file = advertise ~root ~socket in
  let cleanup () =
    (try Unix.unlink bind_path with Unix.Unix_error _ -> ());
    try Unix.unlink registry_file with Unix.Unix_error _ -> ()
  in
  at_exit cleanup;
  List.iter
    (fun signal -> Sys.set_signal signal (Sys.Signal_handle (fun _ -> exit 0)))
    [ Sys.sigterm; Sys.sigint ];
  if not (String.equal ready "") then write_file ready "ready\n";
  (* Concurrent accept, as dune's own server: the observer holds its
     long-poll connection for the whole session, and a probe or a
     verification flush must still be answered beside it — a
     one-at-a-time loop would park them in the backlog. A probe torn down
     between connect and close — a supervisor cancelled mid-handshake —
     vanishes mid-write; the disconnection must never kill the fake. *)
  let rec accept_loop () =
    let fd, _ = Unix.accept listen in
    ignore
      (Thread.create
         (fun fd ->
           (try serve mode fd with Sys_error _ -> ());
           try Unix.close fd with Unix.Unix_error _ -> ())
         fd
        : Thread.t);
    accept_loop ()
  in
  accept_loop ()

let append_line path line =
  let out = open_out_gen [ Open_append; Open_creat; Open_binary ] 0o644 path in
  output_string out (line ^ "\n");
  close_out out

(* The fake-dune shim: see the module comment. cwd is the workspace root --
   exactly how a supervisor spawns [dune build --root . --watch]. *)
let run_as_dune () =
  let root = Unix.getcwd () in
  append_line
    (Filename.concat root "fake-dune-argv")
    (String.concat " " (List.tl (Array.to_list Sys.argv)));
  let mode_file = Filename.concat root "fake-dune-mode" in
  let directive =
    match read_state_file mode_file with Some line -> line | None -> "serve"
  in
  match String.split_on_char ':' directive with
  | [ "exit"; code ] -> exit (int_of_string code)
  | [ "exit-once"; code ] ->
      write_file mode_file "serve\n";
      exit (int_of_string code)
  | directive_tokens ->
      (* [hang]: the whole hang scenario in one directive — a forwarder
         (socket occupied) sleeps forever, as a build forwarded into a
         wedged watch would, and a server answers its first flush (the
         self-test) then parks the rest (the verification). [hang-flush]:
         a server parks every flush, so the self-test itself fails — the
         blocked-file-watcher scenario. *)
      (match directive_tokens with
      | [ "hang" ] -> flush_answer_limit := Some 1
      | [ "hang-flush" ] -> flush_answer_limit := Some 0
      | _ -> ());
      let occupied_behavior () =
        if String.equal directive "hang" || String.equal directive "slow"
        then
          (* A build forwarded into this scenario's watch never returns. *)
          while true do
            Unix.sleep 3600
          done;
        print_string "forwarded one build to the running server\n";
        exit 0
      in
      let sock_dir = Filename.concat root "_build/.rpc" in
      let socket = Filename.concat sock_dir "dune" in
      mkdir_p sock_dir;
      let occupied =
        let probe = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
        Fun.protect
          ~finally:(fun () ->
            try Unix.close probe with Unix.Unix_error _ -> ())
          (fun () ->
            Unix.chdir sock_dir;
            match Unix.connect probe (Unix.ADDR_UNIX "dune") with
            | () -> true
            | exception Unix.Unix_error _ -> false)
      in
      if occupied then occupied_behavior ();
      let state_file = Filename.concat root "dune-state" in
      if not (Sys.file_exists state_file) then write_file state_file "clean\n";
      match
        serve_forever ~mode:(Dynamic state_file) ~root ~socket
          ~bind_in:(Some sock_dir) ~steal:false ~ready:""
      with
      | () -> ()
      | exception Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
          (* Lost the bind race to another shim: be the forwarder the
             occupied-probe would have made us. *)
          occupied_behavior ()

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "build" then
    run_as_dune ()
  else begin
    let root = ref "" and scenario = ref "failing" in
    let state_file = ref "" and ready = ref "" in
    let socket_at_root = ref false in
    let spec =
      [
        ( "--root",
          Arg.Set_string root,
          "workspace root the endpoint advertises" );
        ( "--scenario",
          Arg.String
            (function
            | ("failing" | "clean") as s -> scenario := s
            | other -> raise (Arg.Bad ("unknown scenario: " ^ other))),
          "failing|clean" );
        ( "--state-file",
          Arg.Set_string state_file,
          "dynamic state file (clean|failing|error2), re-read on a tick" );
        ("--ready", Arg.Set_string ready, "file to touch once listening");
        ( "--socket-at-root",
          Arg.Set socket_at_root,
          "bind the socket at ROOT/_build/.rpc/dune, where a real watch \
           serves" );
      ]
    in
    Arg.parse spec
      (fun a -> raise (Arg.Bad ("unexpected argument: " ^ a)))
      "mentat_fake_dune_rpc_server";
    if String.equal !root "" then failwith "--root is required";
    let root = realpath !root in
    let mode =
      if String.equal !state_file "" then Static !scenario
      else Dynamic (realpath !state_file)
    in
    if !socket_at_root then begin
      let sock_dir = Filename.concat root "_build/.rpc" in
      mkdir_p sock_dir;
      serve_forever ~mode ~root
        ~socket:(Filename.concat sock_dir "dune")
        ~bind_in:(Some sock_dir) ~steal:true ~ready:!ready
    end
    else begin
      (* A short socket path under [/tmp]: a Unix socket cannot bind a long
         path (the ~104-byte sun_path limit), which rules out both the cram's
         deep [$PWD] and macOS's [/var/folders/...] [$TMPDIR]. The client
         discovers the path from the registry regardless of where it lives. *)
      let socket =
        Filename.temp_file ~temp_dir:"/tmp" "mentat-fake-rpc-" ".sock"
      in
      Unix.unlink socket;
      serve_forever ~mode ~root ~socket ~bind_in:None ~steal:true
        ~ready:!ready
    end
  end
