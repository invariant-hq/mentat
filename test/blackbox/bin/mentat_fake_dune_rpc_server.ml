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
   Discovery shares the process XDG environment, so the caller must run it
   under the same HOME/XDG_* as the mentat it should be visible to. *)

module Drpc = Dune_rpc.Private
module Conv = Drpc.Conv

type mode = Static of string | Dynamic of string

(* The negotiated dune version, learned from the client's initialize request and
   used for every subsequent Conv en/decode. dune-rpc.3.24 advertises (3, 24);
   reading it rather than pinning keeps the fake correct if the client changes
   what it sends. *)
let session_version = ref (3, 24)

let message_for_state = function
  | "failing" ->
      Some
        "This expression has type string but an expression was expected of \
         type int"
  | "error2" -> Some "Unbound value restock"
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
                  (match (conn.diag_parked, conn.diag_sent) with
                  | Some id, sent
                    when not (Option.equal String.equal sent (Some state)) ->
                      conn.diag_parked <- None;
                      answer_diag conn id
                  | _ -> ());
                  match (conn.prog_parked, conn.prog_sent) with
                  | Some id, sent
                    when not
                           (Option.equal
                              (fun a b -> a == b)
                              sent
                              (Some (progress_for_state state))) ->
                      conn.prog_parked <- None;
                      answer_progress conn id
                  | _ -> ()
                end)
              !dyn_conns));
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
              if
                Option.equal
                  (fun a b -> a == b)
                  conn.prog_sent (Some progress)
              then conn.prog_parked <- Some id
              else answer_progress conn id)
      | Dynamic _, None -> assert false
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

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let root = ref "" and scenario = ref "failing" in
  let state_file = ref "" and ready = ref "" in
  let spec =
    [
      ("--root", Arg.Set_string root, "workspace root the endpoint advertises");
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
  (match mode with
  | Dynamic path ->
      (match read_state_file path with
      | Some state -> current_state := state
      | None -> current_state := "clean");
      ignore (Thread.create ticker path)
  | Static _ -> ());
  (* A short socket path under [/tmp]: a Unix socket cannot bind a long path (the
     ~104-byte sun_path limit), which rules out both the cram's deep [$PWD] and
     macOS's [/var/folders/...] [$TMPDIR]. The client discovers the path from the
     registry regardless of where it lives. *)
  let socket = Filename.temp_file ~temp_dir:"/tmp" "mentat-fake-rpc-" ".sock" in
  Unix.unlink socket;
  let registry_file = advertise ~root ~socket in
  let listen = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listen (Unix.ADDR_UNIX socket);
  Unix.listen listen 8;
  let cleanup () =
    (try Unix.unlink socket with Unix.Unix_error _ -> ());
    try Unix.unlink registry_file with Unix.Unix_error _ -> ()
  in
  at_exit cleanup;
  List.iter
    (fun signal -> Sys.set_signal signal (Sys.Signal_handle (fun _ -> exit 0)))
    [ Sys.sigterm; Sys.sigint ];
  if not (String.equal !ready "") then write_file !ready "ready\n";
  let rec accept_loop () =
    let fd, _ = Unix.accept listen in
    serve mode fd;
    (try Unix.close fd with Unix.Unix_error _ -> ());
    accept_loop ()
  in
  accept_loop ()
