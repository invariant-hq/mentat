(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Workspace = Mentat_workspace

let ( let* ) = Result.bind

module Drpc = Dune_rpc.Private

let log_src =
  Logs.Src.create "mentat.ocaml.dune.rpc" ~doc:"Dune RPC connection lifecycle"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* A [Dune_rpc.Fiber_intf.S] instance over direct-style Eio.

   The fiber type is a suspended computation ([unit -> 'a]), not the bare
   value ['a]. This deferral is load-bearing: [Dune_rpc.Private.Client] stores
   an unforced [Ivar.read] of its still-empty handler ivar in the client
   record and only forces it after version negotiation fills the ivar (see the
   [handler : _ Fiber.t] field). With the identity representation ['a t = 'a]
   that read is forced eagerly at client-creation time, [Eio.Promise.await]
   blocks the connecting fiber before the handshake fibers are even forked,
   and the whole connection deadlocks. Representing a fiber as a thunk keeps
   [Ivar.read] on an empty ivar a value, forced (and awaited) only when the
   library binds it. A fiber is forced with {!run}. *)
module Dune_rpc_fiber = struct
  type 'a t = unit -> 'a

  let run (t : 'a t) : 'a = t ()
  let return x () = x

  let fork_and_join_unit f g () =
    let result = ref None in
    Eio.Fiber.both
      (fun () -> run (f ()))
      (fun () -> result := Some (run (g ())));
    match !result with
    | Some value -> value
    | None -> invalid_arg "second fiber did not return"

  let parallel_iter next ~f () =
    let rec loop () =
      match run (next ()) with
      | None -> ()
      | Some value ->
          run (f value);
          loop ()
    in
    loop ()

  let finalize f ~finally () =
    match run (f ()) with
    | value ->
        run (finally ());
        value
    | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        run (finally ());
        Printexc.raise_with_backtrace exn backtrace

  let collect_errors f () =
    try Ok (run (f ())) with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | exn -> Error [ exn ]

  module O = struct
    let ( let* ) value f () = run (f (run value))
    let ( let+ ) value f () = f (run value)
  end

  module Ivar = struct
    type 'a t = 'a Eio.Promise.t * 'a Eio.Promise.u

    let create () = Eio.Promise.create ()
    let read (promise, _resolver) () = Eio.Promise.await promise
    let fill (_promise, resolver) value () = Eio.Promise.resolve resolver value
  end
end

module Dune_rpc_chan = struct
  (* Dune's RPC client drives the transport as two joined fibers: a reader
     loop and the request/notification driver (see [Client.connect_raw]). The
     driver ends a session by calling {!close}, and the reader loop only stops
     once a {!read} yields [None]. Closing the underlying Eio flow does not
     wake a fiber already blocked in a socket read, so a bare [Eio.Flow.close]
     leaves the reader parked forever and the joining [fork_and_join_unit]
     never returns. [close] therefore also resolves a [closed] promise that
     every [read] races against, delivering the [None] the client's contract
     expects when the connection is closed locally. *)
  type t =
    | Chan : {
        flow : _ Eio.Net.stream_socket;
        reader : Eio.Buf_read.t;
        closed : unit Eio.Promise.t;
        resolve_closed : unit Eio.Promise.u;
        mutable is_closed : bool;
      }
        -> t

  let of_flow flow =
    let closed, resolve_closed = Eio.Promise.create () in
    Chan
      {
        flow;
        reader = Eio.Buf_read.of_flow ~max_size:16_777_216 flow;
        closed;
        resolve_closed;
        is_closed = false;
      }

  let write (Chan { flow; _ }) sexps () =
    List.iter
      (fun sexp -> Eio.Flow.copy_string (Csexp.to_string sexp) flow)
      sexps

  let close (Chan c) () =
    if not c.is_closed then begin
      c.is_closed <- true;
      Eio.Promise.resolve c.resolve_closed ();
      Eio.Flow.close c.flow
    end

  (* One csexp, consumed incrementally from the shared buffered reader with
     Csexp's streaming lexer. Csexp is length-prefixed, so an atom body is
     taken in a single bulk read; the message costs O(size) rather than the
     quadratic re-parse of the whole accumulated buffer per byte, and each
     [Buf_read] refill is a scheduler yield, so a large message (e.g. a big
     Dune diagnostic set) never stalls the domain nor outruns a wrapping
     timeout. Only this sexp's bytes are consumed; any trailing bytes stay
     buffered for the next call. [End_of_file] (peer closed) yields [None]. *)
  let read_one reader =
    let module Parser = Csexp.Parser in
    let lexer = Parser.Lexer.create () in
    let rec loop stack =
      match Parser.Lexer.feed lexer (Eio.Buf_read.any_char reader) with
      | Parser.Lexer.Atom length ->
          let atom = Eio.Buf_read.take length reader in
          settle (Parser.Stack.add_atom atom stack)
      | (Parser.Lexer.Await | Parser.Lexer.Lparen | Parser.Lexer.Rparen) as
        token ->
          settle (Parser.Stack.add_token token stack)
    and settle stack =
      match stack with
      | Parser.Stack.Sexp (sexp, Parser.Stack.Empty) -> Some sexp
      | stack -> loop stack
    in
    try loop Parser.Stack.Empty with End_of_file -> None

  let read (Chan { reader; closed; is_closed; _ }) () =
    if is_closed then None
    else
      (* Race the next message against a local close: whichever settles first
         wins, and the loser (a parked read, or the close waiter) is
         cancelled. A local close thus surfaces as [None], exactly as a peer
         EOF does. *)
      Eio.Fiber.first
        (fun () ->
          Eio.Promise.await closed;
          None)
        (fun () -> read_one reader)
end

module Dune_rpc_client = Drpc.Client.Make (Dune_rpc_fiber) (Dune_rpc_chan)

let csexp_text sexp = Csexp.to_string sexp

let protocol_error ?payload message =
  Error
    (Error.Protocol_error { message; payload = Option.map csexp_text payload })

let response_error error =
  Error
    (Error.Protocol_error
       {
         message = Drpc.Response.Error.message error;
         payload = Option.map csexp_text (Drpc.Response.Error.payload error);
       })

let version_error error =
  Error
    (Error.Protocol_error
       {
         message = Drpc.Version_error.message error;
         payload = Option.map csexp_text (Drpc.Version_error.payload error);
       })

module Endpoint = struct
  type address = Unix of string | Tcp of { host : string; port : int }
  type t = { root : string; address : address }

  let make ~root address =
    if String.equal root "" then invalid_arg "root must not be empty";
    { root; address }

  let root t = t.root
  let address t = t.address

  let to_string t =
    match t.address with
    | Unix path -> t.root ^ " unix://" ^ path
    | Tcp { host; port } -> t.root ^ " tcp://" ^ host ^ ":" ^ string_of_int port

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Registry = struct
  module Dune_registry = Drpc.Registry

  type t = {
    config : Dune_registry.Config.t;
    mutable registry : Dune_registry.t;
  }

  exception Missing_registry_dir

  module Registry_fiber = struct
    include Dune_rpc_fiber

    let parallel_map xs ~f () = List.map (fun x -> run (f x)) xs
  end

  let create ~env () =
    let config = Dune_registry.Config.create (Xdg.create ~env ()) in
    { config; registry = Dune_registry.create config }

  let reset t = t.registry <- Dune_registry.create t.config
  let current t = Dune_registry.current t.registry
  let root = Dune_registry.Dune.root
  let pid = Dune_registry.Dune.pid

  let endpoint entry =
    let address =
      match Dune_registry.Dune.where entry with
      | `Unix path -> Endpoint.Unix path
      | `Ip (`Host host, `Port port) -> Endpoint.Tcp { host; port }
    in
    Endpoint.make ~root:(root entry) address

  let poll ~fs t =
    let module Poll =
      Dune_registry.Poll
        (Registry_fiber)
        (struct
          let with_error f =
            try Ok (f ()) with
            | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
            | exn -> Error exn
          let path raw = Eio.Path.( / ) fs raw

          let scandir raw =
            Dune_rpc_fiber.return
              (match Eio.Path.kind ~follow:true (path raw) with
              | `Not_found -> Ok []
              | _ -> with_error (fun () -> Eio.Path.read_dir (path raw)))

          let stat raw =
            Dune_rpc_fiber.return
              (match Eio.Path.kind ~follow:true (path raw) with
              | `Not_found -> Error Missing_registry_dir
              | _ ->
                  with_error (fun () ->
                      `Mtime
                        (Eio.Path.stat ~follow:true (path raw))
                          .Eio.File.Stat.mtime))

          let read_file raw =
            Dune_rpc_fiber.return
              (with_error (fun () -> Eio.Path.load (path raw)))
        end) in
    reset t;
    match Dune_rpc_fiber.run (Poll.poll t.registry) with
    | Ok refresh -> (
        match Dune_registry.Refresh.errored refresh with
        | [] -> Ok (current t)
        | (path, exn) :: remaining ->
            Error
              (Error.Connection_failed
                 {
                   endpoint = path;
                   message =
                     Printexc.to_string exn ^ " ("
                     ^ string_of_int (List.length remaining + 1)
                     ^ " registry error(s))";
                 }))
    | Error Missing_registry_dir -> Ok (current t)
    | Error exn ->
        Error
          (Error.Connection_failed
             {
               endpoint = "dune rpc registry";
               message = Printexc.to_string exn;
             })
end

module Connection = struct
  type t = { workspace : Workspace.t option; client : Dune_rpc_client.t }

  let make ~client ?workspace () = { workspace; client }

  let init_request =
    Drpc.Initialize.Request.create
      ~id:
        (Drpc.Id.make
           (Csexp.List [ Csexp.Atom "mentat"; Csexp.Atom "ocaml-dune" ]))

  let unix_socket_path_limit = 100

  let is_dir path =
    match Sys.is_directory path with
    | true -> true
    | false -> false
    | exception Sys_error _ -> false

  let temp_dir () =
    if is_dir "/tmp" then "/tmp" else Filename.get_temp_dir_name ()

  let realpath path =
    match Unix.realpath path with
    | path -> Some path
    | exception Unix.Unix_error _ -> None

  let normalize_dir path =
    match Filename.chop_suffix_opt ~suffix:Filename.dir_sep path with
    | Some path -> path
    | None -> path

  let drop_root ~root path =
    let root = normalize_dir root in
    if String.equal path root then Some ""
    else
      let prefix = root ^ Filename.dir_sep in
      if String.starts_with ~prefix path then
        Some (String.drop_first (String.length prefix) path)
      else None

  let realpath_with_basename path =
    let dir = Filename.dirname path in
    let base = Filename.basename path in
    Option.map (fun dir -> Filename.concat dir base) (realpath dir)

  let workspace_relative_socket endpoint path =
    let roots =
      Endpoint.root endpoint
      :: Option.to_list (realpath (Endpoint.root endpoint))
    in
    let paths = path :: Option.to_list (realpath_with_basename path) in
    List.find_map
      (fun root ->
        List.find_map
          (fun path ->
            Option.map (fun rel -> (root, rel)) (drop_root ~root path))
          paths)
      roots

  let with_short_workspace_socket endpoint path f =
    match workspace_relative_socket endpoint path with
    | None -> f path
    | Some (root, rel) -> (
        let link =
          Filename.temp_file ~temp_dir:(temp_dir ()) "mentat-dune-rpc-" ""
        in
        match
          Unix.unlink link;
          Unix.symlink root link
        with
        | () ->
            Fun.protect
              ~finally:(fun () ->
                match Unix.unlink link with
                | () -> ()
                | exception Unix.Unix_error _ -> ())
              (fun () -> f (Filename.concat link rel))
        | exception Unix.Unix_error _ -> f path)

  let connect_unix ~sw net endpoint path f =
    if String.length path <= unix_socket_path_limit then
      let flow = Eio.Net.connect ~sw net (`Unix path) in
      f flow
    else
      with_short_workspace_socket endpoint path @@ fun path ->
      let flow = Eio.Net.connect ~sw net (`Unix path) in
      f flow

  let connect_flow ~sw ~net endpoint f =
    match Endpoint.address endpoint with
    | Endpoint.Unix path -> connect_unix ~sw net endpoint path f
    | Endpoint.Tcp { host; port } ->
        Eio.Net.with_tcp_connect ~host ~service:(string_of_int port) net f

  let with_connection ~sw ~net ?workspace endpoint ~f =
    let endpoint_text = Endpoint.to_string endpoint in
    try
      connect_flow ~sw ~net endpoint @@ fun flow ->
      let chan = Dune_rpc_chan.of_flow flow in
      Dune_rpc_fiber.run
        (Dune_rpc_client.connect chan init_request ~f:(fun client ->
             let t = make ~client ?workspace () in
             Dune_rpc_fiber.return (f t)))
    with
    | Drpc.Response.Error.E error -> response_error error
    | Drpc.Version_error.E error -> version_error error
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | exn ->
        Error
          (Error.Connection_failed
             { endpoint = endpoint_text; message = Printexc.to_string exn })

  let pp_text pp = String.trim (Format.asprintf "%a@." Drpc.Pp.to_fmt pp)

  let severity diagnostic =
    match Drpc.Diagnostic.severity diagnostic with
    | Some Drpc.Diagnostic.Error -> Mentat_ocaml.Diagnostic.Severity.Error
    | Some Drpc.Diagnostic.Warning -> Mentat_ocaml.Diagnostic.Severity.Warning
    | None -> Mentat_ocaml.Diagnostic.Severity.Information

  let diagnostic_payload_error message =
    protocol_error ("invalid Dune RPC diagnostic payload: " ^ message)

  let construct_diagnostic f =
    try Ok (f ())
    with Invalid_argument message -> diagnostic_payload_error message

  let position (position : Lexing.position) =
    let column = max 0 (position.Lexing.pos_cnum - position.Lexing.pos_bol) in
    Mentat_ocaml.Position.make ~line:(max 1 position.Lexing.pos_lnum) ~column

  let location_of_dune t loc =
    let path = loc.Drpc.Loc.start.Lexing.pos_fname in
    match t.workspace with
    | None -> Ok None
    | Some workspace -> (
        match Workspace.resolve_string workspace path with
        | Ok path ->
            let start = position (Drpc.Loc.start loc) in
            let end_ = position (Drpc.Loc.stop loc) in
            construct_diagnostic (fun () ->
                Some
                  (Mentat_ocaml.Location.make ~path
                     ~range:(Mentat_ocaml.Range.make ~start ~end_)))
        | Error _ -> Ok None)

  let related_of_dune t related =
    let* location = location_of_dune t (Drpc.Diagnostic.Related.loc related) in
    construct_diagnostic (fun () ->
        Mentat_ocaml.Diagnostic.Related.make ?location
          (pp_text (Drpc.Diagnostic.Related.message related)))

  let diagnostic_of_dune t diagnostic =
    let message = pp_text (Drpc.Diagnostic.message diagnostic) in
    let rec related_loop acc = function
      | [] -> Ok (List.rev acc)
      | related :: rest -> (
          match related_of_dune t related with
          | Ok related -> related_loop (related :: acc) rest
          | Error _ as error -> error)
    in
    let* related = related_loop [] (Drpc.Diagnostic.related diagnostic) in
    let* location =
      match Drpc.Diagnostic.loc diagnostic with
      | None -> Ok None
      | Some location -> location_of_dune t location
    in
    construct_diagnostic (fun () ->
        Mentat_ocaml.Diagnostic.make ?location ~related
          ~source:Mentat_ocaml.Diagnostic.Source.dune
          ~severity:(severity diagnostic) message)

  (* The store key: the watch's own diagnostic identifier, rendered
     injectively — a hash would let a collision remove the wrong finding and
     silently corrupt the build witness. *)
  let diagnostic_id diagnostic =
    Csexp.to_string
      (Drpc.Conv.to_sexp Drpc.Diagnostic.Id.sexp
         (Drpc.Diagnostic.id diagnostic))

end

module Instance = struct
  type fs = Fs : _ Eio.Path.t -> fs
  type net = Net : _ Eio.Net.t -> net
  type mono = Mono : _ Eio.Time.Mono.t -> mono

  module Status = struct
    type t = Absent | Connecting | Attached of { pid : int; ours : bool }

    let equal (a : t) (b : t) =
      match (a, b) with
      | Absent, Absent | Connecting, Connecting -> true
      | Attached a, Attached b ->
          Int.equal a.pid b.pid && Bool.equal a.ours b.ours
      | (Absent | Connecting | Attached _), _ -> false

    let pp ppf (t : t) =
      match t with
      | Absent -> Format.pp_print_string ppf "absent"
      | Connecting -> Format.pp_print_string ppf "connecting"
      | Attached { pid; ours } ->
          Format.fprintf ppf "attached(pid %d%s)" pid
            (if ours then ", ours" else "")
  end

  module Snapshot = struct
    type t = {
      status : Status.t;
      building : bool;
      reading : Mentat_ocaml.Build_change.Reading.t option;
    }

    let health t =
      match t.status with
      | Status.Absent ->
          Mentat_workspace.Health.Off Mentat_workspace.Health.Off.No_server
      | Status.Connecting -> Mentat_workspace.Health.Probing
      | Status.Attached { pid; ours } ->
          let phase =
            match t.reading with
            | Some reading when not t.building ->
                Mentat_workspace.Health.Phase.Settled
                  {
                    build = Mentat_ocaml.Build_change.Reading.verdict reading;
                    lint = Mentat_ocaml.Build_change.Reading.lint reading;
                  }
            | Some _ | None -> Mentat_workspace.Health.Phase.Building
          in
          let owner =
            if ours then Mentat_workspace.Health.Owner.Ours
            else Mentat_workspace.Health.Owner.Theirs pid
          in
          Mentat_workspace.Health.Live { owner; phase }
  end

  (* A supervisor's claim on its own watch: the endpoint the attach loop uses
     instead of the registry, the child's host pid, and whether the requested
     targets make the lint lane live. *)
  type pin = { pin_endpoint : Endpoint.t; pin_pid : int; pin_lint : bool }

  (* Single-domain writes: every mutable field is assigned whole values with
     no suspension between a read and its dependent write, so snapshots are
     torn-proof without a lock and the drain path can never wait on the attach
     fiber's IO. *)
  type t = {
    fs : fs;
    net : net;
    mono : mono;
    workspace : Workspace.t;
    env : string -> string option;
    registry : Registry.t;
    mutable pinned : pin option;
    mutable endpoint : Endpoint.t option;
    mutable endpoint_pid : int;
    mutable status : Status.t;
    (* The lane fact of the attached watch, captured when the connection
       opened: a pinned watch's supervisor states it (the targets are known),
       a foreign watch's targets are unknown so the marker alone decides. *)
    mutable attached_lint : bool;
    mutable events : int;
    mutable store : Store.t;
  }

  let create ~fs ~net ~mono ~workspace ?(env = Sys.getenv_opt) () =
    {
      fs = Fs fs;
      net = Net net;
      mono = Mono mono;
      workspace;
      env;
      registry = Registry.create ~env ();
      pinned = None;
      endpoint = None;
      endpoint_pid = 0;
      status = Status.Absent;
      attached_lint = true;
      events = 0;
      store = Store.initial;
    }

  let now t =
    let (Mono mono) = t.mono in
    Eio.Time.Mono.now mono

  let workspace_root_strings workspace =
    List.map
      (fun root -> Lpath.Abs.to_string (Workspace.Root.dir root))
      (Workspace.roots workspace)

  let primary_root t =
    match workspace_root_strings t.workspace with
    | root :: _ -> root
    | [] -> invalid_arg "workspace admits no root"

  (* Where dune's server binds for a workspace, by dune's own convention. *)
  let socket_path t =
    Filename.concat (primary_root t)
      (Filename.concat "_build" (Filename.concat ".rpc" "dune"))

  let pin t ~pid ~lint =
    let endpoint =
      Endpoint.make ~root:(primary_root t) (Endpoint.Unix (socket_path t))
    in
    Log.info (fun m -> m "dune rpc endpoint pinned (pid %d)" pid);
    t.pinned <- Some { pin_endpoint = endpoint; pin_pid = pid; pin_lint = lint }

  let unpin t =
    if Option.is_some t.pinned then
      Log.info (fun m -> m "dune rpc endpoint unpinned");
    t.pinned <- None

  let probe_timeout_s = 1.0

  let probe t =
    let (Net net) = t.net in
    let (Mono mono) = t.mono in
    let endpoint =
      Endpoint.make ~root:(primary_root t) (Endpoint.Unix (socket_path t))
    in
    Eio.Fiber.first
      (fun () ->
        let result =
          Eio.Switch.run @@ fun sw ->
          Connection.with_connection ~sw ~net endpoint ~f:(fun _ -> Ok ())
        in
        match result with Ok () -> true | Error _ -> false)
      (fun () ->
        Eio.Time.Mono.sleep mono probe_timeout_s;
        false)

  let mirror t ~pid =
    Mirror.write ~env:t.env ~root:(primary_root t) ~pid
      ~socket:(socket_path t)

  (* Test-only scaling, like the reading windows below: a hermetic fake
     answers or parks a flush in microseconds. Production never sets it. *)
  let env_float name default =
    match Sys.getenv_opt name with
    | None | Some "" -> default
    | Some value -> ( try float_of_string value with Failure _ -> default)

  let flush_timeout_s = env_float "MENTAT_DUNE_WATCH_FLUSH_S" 10.0

  let flush t =
    let (Net net) = t.net in
    let (Mono mono) = t.mono in
    let endpoint =
      Endpoint.make ~root:(primary_root t) (Endpoint.Unix (socket_path t))
    in
    Eio.Fiber.first
      (fun () ->
        let result =
          Eio.Switch.run @@ fun sw ->
          Connection.with_connection ~sw ~net endpoint ~f:(fun connection ->
              let witness =
                Drpc.Decl.Request.witness
                  Drpc.Procedures.Public.flush_file_watcher
              in
              let client = connection.Connection.client in
              match
                Dune_rpc_fiber.run
                  (Dune_rpc_client.Versioned.prepare_request client witness)
              with
              (* A server without the method still answered the version
                 negotiation: its event loop is alive, which is all the
                 verification asks. *)
              | Error _ -> Ok `Answered
              | Ok staged -> (
                  match
                    Dune_rpc_fiber.run
                      (Dune_rpc_client.request client staged ())
                  with
                  | Ok (`Ok | `Not_in_watch_mode) -> Ok `Answered
                  (* An error response is a response: the loop answered. *)
                  | Error _ -> Ok `Answered))
        in
        match result with Ok verdict -> verdict | Error _ -> `No_server)
      (fun () ->
        Eio.Time.Mono.sleep mono flush_timeout_s;
        `Timed_out)

  let normalize_abs path =
    match Lpath.Abs.of_string path with
    | Ok abs ->
        let path = Lpath.Abs.to_string abs in
        Some
          (match Unix.realpath path with
          | path -> path
          | exception Unix.Unix_error _ -> path)
    | Error _ -> None

  let same_root a b =
    String.equal a b
    ||
    match (normalize_abs a, normalize_abs b) with
    | Some a, Some b -> String.equal a b
    | Some _, None | None, Some _ | None, None -> false

  let process_alive pid =
    if pid <= 0 then false
    else
      match Unix.kill pid 0 with
      | () -> true
      | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
      | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
      | exception Unix.Unix_error _ -> false

  let choose_registry_entry ~workspace entries =
    let roots = workspace_root_strings workspace in
    List.find_opt
      (fun entry ->
        process_alive (Registry.pid entry)
        && List.exists (same_root (Registry.root entry)) roots)
      entries

  (* Registry IO runs on the attach fiber alone; only the resulting endpoint
     assignment is shared state. *)
  let refresh_registry t =
    let (Fs fs) = t.fs in
    let previous = t.endpoint in
    let note_lost () =
      if Option.is_some previous then
        Log.info (fun m -> m "dune rpc endpoint lost")
    in
    let* entries = Registry.poll ~fs t.registry in
    match choose_registry_entry ~workspace:t.workspace entries with
    | None ->
        note_lost ();
        t.endpoint <- None;
        Ok None
    | Some entry ->
        let endpoint = Registry.endpoint entry in
        (match previous with
        | Some prev
          when String.equal (Endpoint.to_string prev)
                 (Endpoint.to_string endpoint) ->
            ()
        | _ ->
            Log.info (fun m ->
                m "dune rpc endpoint found endpoint=%a" Endpoint.pp endpoint));
        t.endpoint <- Some endpoint;
        t.endpoint_pid <- Registry.pid entry;
        Ok (Some endpoint)

  (* A pinned endpoint bypasses the registry entirely: the supervisor knows
     its own watch's socket and pid, so our own readings never ride the
     user's global registry — a broken or unwritable registry costs editor
     discovery, never the agent's build visibility. Registry discovery
     survives for foreign attach only. *)
  let refresh t =
    match t.pinned with
    | Some pin ->
        t.endpoint <- Some pin.pin_endpoint;
        t.endpoint_pid <- pin.pin_pid;
        Ok (Some pin.pin_endpoint)
    | None -> refresh_registry t

  (* Test-only scaling for the reading windows, like the flush bound above:
     a hermetic cram's whole exchange completes in microseconds, so it
     shrinks the windows rather than sleeping the suite through them. *)
  let quiet_s = env_float "MENTAT_DUNE_RPC_QUIET_S" 0.25
  let quiet_fallback_s = env_float "MENTAT_DUNE_RPC_QUIET_FALLBACK_S" 2.0
  let reconnect_pause_s = env_float "MENTAT_DUNE_RPC_RECONNECT_S" 1.0

  let snapshot t =
    {
      Snapshot.status = t.status;
      building =
        (match t.status with
        | Status.Attached _ -> Store.building t.store
        | Status.Absent | Status.Connecting -> false);
      reading =
        (match t.status with
        | Status.Attached _ ->
            Store.reading t.store ~now:(now t) ~quiet_s
              ~fallback_s:quiet_fallback_s
        | Status.Absent | Status.Connecting -> None);
    }

  let set_status t status =
    if not (Status.equal t.status status) then
      Log.info (fun m -> m "dune watch %a" Status.pp status);
    t.status <- status

  let fold_event t event =
    t.events <- t.events + 1;
    t.store <- Store.apply ~at:(now t) event t.store

  let activity t = t.events

  let first_line text =
    match String.index_opt text '\n' with
    | Some i -> String.sub text 0 i
    | None -> text

  let finding_of_diagnostic t diagnostic =
    let severity =
      match Mentat_ocaml.Diagnostic.severity diagnostic with
      | Mentat_ocaml.Diagnostic.Severity.Error ->
          Mentat_ocaml.Finding.Severity.Error
      | Mentat_ocaml.Diagnostic.Severity.Warning
      | Mentat_ocaml.Diagnostic.Severity.Hint ->
          Mentat_ocaml.Finding.Severity.Warning
      (* An exception-shaped diagnostic has no severity on the wire; it is a
         failure. *)
      | Mentat_ocaml.Diagnostic.Severity.Information ->
          Mentat_ocaml.Finding.Severity.Error
    in
    let head =
      let head = first_line (Mentat_ocaml.Diagnostic.message diagnostic) in
      if String.is_empty head then "(no message)" else head
    in
    let path, location =
      match Mentat_ocaml.Diagnostic.location diagnostic with
      | None -> (None, None)
      | Some location ->
          ( Some (Workspace.Path.display (Mentat_ocaml.Location.path location)),
            Some (Format.asprintf "%a" Mentat_ocaml.Location.pp location) )
    in
    (* The lane is a fact about the attached watch, captured when the
       connection opened: a foreign watch's targets are unknown so the
       marker alone decides; a supervised watch's supervisor stated whether
       its requested targets make the lint lane live. *)
    Mentat_ocaml.Finding.classify ~lint:t.attached_lint ~severity ?path
      ?location ~head ()

  let diagnostic_events t connection events =
    let events =
      List.filter_map
        (fun (event : Drpc.Diagnostic.Event.t) ->
          match event with
          | Drpc.Diagnostic.Event.Add diagnostic -> (
              match Connection.diagnostic_of_dune connection diagnostic with
              | Ok converted ->
                  Some
                    (`Add
                       ( Connection.diagnostic_id diagnostic,
                         finding_of_diagnostic t converted ))
              | Error _ ->
                  (* A malformed diagnostic is dropped rather than faulting
                     the stream; the set self-corrects at the next build. *)
                  None)
          | Drpc.Diagnostic.Event.Remove diagnostic ->
              Some (`Remove (Connection.diagnostic_id diagnostic)))
        events
    in
    (* The answer itself synchronises the set, an empty one included. *)
    fold_event t (Store.Diagnostics events)

  let progress_event t (progress : Drpc.Progress.t) =
    match progress with
    | Drpc.Progress.Success | Drpc.Progress.Failed ->
        fold_event t (Store.Progress `Settle)
    | Drpc.Progress.Waiting | Drpc.Progress.In_progress _
    | Drpc.Progress.Interrupted ->
        fold_event t (Store.Progress `Busy)

  let stream_loop stream ~on_value =
    let rec loop () =
      match Dune_rpc_fiber.run (Dune_rpc_client.Stream.next stream) with
      | None -> ()
      | Some value ->
          on_value value;
          loop ()
    in
    loop ()

  let subscribe connection procedure =
    match
      Dune_rpc_fiber.run
        (Dune_rpc_client.poll connection.Connection.client
           (Drpc.Sub.of_procedure procedure))
    with
    | Ok stream -> Ok stream
    | Error error -> version_error error

  let hold_subscriptions t connection =
    let* diagnostics = subscribe connection Drpc.Procedures.Poll.diagnostic in
    let* progress = subscribe connection Drpc.Procedures.Poll.progress in
    (* The attachment's identity is captured here, once: a connection that
       opened through the pin is the supervised watch — its owner and lane
       fact hold for the connection's whole life, even past a later unpin. *)
    let pinned = t.pinned in
    t.attached_lint <-
      (match pinned with Some pin -> pin.pin_lint | None -> true);
    fold_event t Store.Connected;
    set_status t
      (Status.Attached
         { pid = t.endpoint_pid; ours = Option.is_some pinned });
    Eio.Fiber.both
      (fun () ->
        stream_loop diagnostics ~on_value:(diagnostic_events t connection))
      (fun () -> stream_loop progress ~on_value:(progress_event t));
    Ok ()

  let attach_once t endpoint =
    let (Net net) = t.net in
    set_status t Status.Connecting;
    let result =
      Eio.Switch.run @@ fun sw ->
      Connection.with_connection ~sw ~net ~workspace:t.workspace endpoint
        ~f:(fun connection -> hold_subscriptions t connection)
    in
    (match result with
    | Ok () -> ()
    | Error error ->
        let message =
          match (error : Error.t) with
          | Error.Connection_failed { message; _ }
          | Error.Protocol_error { message; _ } ->
              message
        in
        Log.debug (fun m -> m "dune watch connection ended: %s" message));
    (* Hold [Connecting] across a transient EOF: the next registry poll — one
       pause away — settles whether the endpoint is gone ([Absent]) or worth
       reconnecting, and the row is spared a sub-second off/on flap. *)
    set_status t Status.Connecting

  let attach t =
    let (Mono mono) = t.mono in
    let rec loop () =
      (match refresh t with
      | Ok (Some endpoint) -> attach_once t endpoint
      | Ok None | Error _ -> set_status t Status.Absent);
      Eio.Time.Mono.sleep mono reconnect_pause_s;
      loop ()
    in
    loop ()
end

