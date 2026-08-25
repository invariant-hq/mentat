(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The transport-bound half: the network edge (tokens, origins, the sole listener
   constructor), the [serve] dispatcher over the shared descriptor table with its
   SSE feed and login streams, and the [connect] remote driver that refills a
   [Mentat_client.Driver.t] from a socket. The pure halves are [Codecs] (the wire
   vocabulary), [Endpoint] (the descriptor table), and [Wire] (the envelope and
   SSE framing). *)

(* Foundations. *)

let to_hex s =
  let buffer = Buffer.create (String.length s * 2) in
  String.iter
    (fun c -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code c)))
    s;
  Buffer.contents buffer

(* Constant-time string equality: the running time depends only on the lengths,
   never on where the first differing byte lies, so a comparison cannot leak a
   token by timing. Hand-written because [eqaf] is not in the
   lock and this campaign adds no lock entries; the length-checked byte-wise
   [lxor]/[lor] fold is the standard constant-time idiom, unit-tested against the
   equal, unequal-same-length, and unequal-length cases. Token length is fixed
   (a hex CSPRNG value) and not itself secret, so folding to the longer length is
   sound. *)
let constant_time_equal a b =
  let la = String.length a and lb = String.length b in
  let n = if la > lb then la else lb in
  let acc = ref (la lxor lb) in
  for i = 0 to n - 1 do
    let ca = if i < la then Char.code a.[i] else 0 in
    let cb = if i < lb then Char.code b.[i] else 0 in
    acc := !acc lor (ca lxor cb)
  done;
  Int.equal !acc 0

(* CSPRNG helpers shared by the connection token and the browser session cookie:
   a hex value from [Mirage_crypto_rng], seeded once. stdlib
   [Random] is forbidden for any security value. *)
let rng_seeded = ref false

let ensure_rng () =
  if not !rng_seeded then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_seeded := true
  end

let csprng_hex bytes =
  ensure_rng ();
  to_hex (Mirage_crypto_rng.generate bytes)

module Token = struct
  type t = string

  (* 32 bytes = 256 bits, well above the 128-bit floor. *)
  let generate () = csprng_hex 32
  let of_string s = s
  let to_string t = t
  let equal = constant_time_equal
end

module Origin = struct
  type t = string

  let of_string s = s
  let to_string t = t
  let equal = String.equal
end

(* Binds. *)

type bind =
  | Unix of { dir : Lpath.Abs.t }
  | Loopback of { port : int option; token : Token.t }
  | Public of {
      host : string;
      port : int;
      tls : Tls.Config.server;
      token : Token.t;
      origins : Origin.t list;
    }

module Bind = struct
  type t = bind

  let unix ~dir = Unix { dir }
  let loopback ~port ~token = Loopback { port; token }

  let public ~host ~port ~tls ~token ~origins =
    Public { host; port; tls; token; origins }
end

exception Unsupported of string

let socket_name = "mentat.sock"

(* The [sockaddr_un.sun_path] buffer is 104 bytes on macOS (108 on Linux); the
   smaller bound is the portable limit, and a path needs room for its NUL. A path
   at or past this length would fail at [bind] with an opaque [ENAMETOOLONG]/
   [EINVAL], so we refuse it up front with a message naming the limit and the
   escape (the whole reason the default socket lives under a short [/tmp] key). *)
let sun_path_max = 104
let unix_socket_path dir = Filename.concat (Lpath.Abs.to_string dir) socket_name

type listener = {
  bind : bind;
  addr : Eio.Net.Sockaddr.stream option;
      (* The address the socket bound to, captured for a loopback/public
         listener so the daemon can name the browser URL and a test can dial an
         ephemeral port; [None] for a unix socket, which carries no TCP port. *)
  run_server :
    stop:unit Eio.Promise.t ->
    on_error:(exn -> unit) ->
    Cohttp_eio.Server.t ->
    unit;
}

(* The sole hardened directory authority. The chain is
   [mkdir]-atomic → lstat-verify → sticky-parent premise → bind:

   1. A fresh [mkdir(0700)] we own outright.
   2. On EEXIST we [lstat] the path — which does NOT follow a symlink — and refuse
      a symlink, a non-directory, a directory owned by another uid, or one that is
      not 0700. [lstat] is the C-free stand-in for A3's [O_NOFOLLOW|O_DIRECTORY] +
      fstat: OCaml's [Unix] exposes neither open flag and this campaign adds no C
      stub (the same deferral precedent as the [SO_PEERCRED] peer-uid check).
   3. The lstat→bind window is closed cross-uid only if the parent is {e sticky}:
      under a sticky directory a non-owner cannot unlink, rename, or replace the
      entry we verified, so no other uid can swap a symlink in beneath us between
      the [lstat] and the [bind]. That premise is load-bearing, so we check it: we
      [lstat] the parent and refuse loudly (naming [--socket]) when it is
      world-writable {b without} the sticky bit. The default [/tmp] parent always
      passes; a [--socket] override into an unsafe location is caught here.

   The residual is the same-uid boundary the RFC concedes: a process running as
   the same user is trusted. Uses [Unix] directly; the library takes no filesystem
   capability. *)
let ensure_private_dir dir =
  let path = Lpath.Abs.to_string dir in
  let refuse reason =
    invalid_arg (Printf.sprintf "mentat_server: %s: %s" path reason)
  in
  (match Unix.mkdir path 0o700 with
  | () -> ()
  | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
      let stat = Unix.lstat path in
      if stat.Unix.st_kind = Unix.S_LNK then refuse "is a symlink, refusing";
      if stat.Unix.st_kind <> Unix.S_DIR then refuse "is not a directory";
      if stat.Unix.st_uid <> Unix.geteuid () then
        refuse "is not owned by this user, refusing";
      if stat.Unix.st_perm land 0o077 <> 0 then
        refuse "is not private (0700 required)"
  | exception Unix.Unix_error (error, fn, _) ->
      refuse (Printf.sprintf "%s: %s" fn (Unix.error_message error)));
  (* The sticky-parent premise the lstat→bind soundness rests on. *)
  let parent = Filename.dirname path in
  match Unix.lstat parent with
  | exception Unix.Unix_error (error, fn, _) ->
      refuse
        (Printf.sprintf "parent %s: %s: %s" parent fn (Unix.error_message error))
  | pstat ->
      let world_writable = pstat.Unix.st_perm land 0o002 <> 0 in
      let sticky = pstat.Unix.st_perm land 0o1000 <> 0 in
      if world_writable && not sticky then
        invalid_arg
          (Printf.sprintf
             "mentat_server: parent directory %s is world-writable without the \
              sticky bit; refusing to bind a socket there (use --socket to \
              choose a private directory)"
             parent)

let listen ~sw ~net bind =
  match bind with
  | Unix { dir } ->
      let path = unix_socket_path dir in
      if String.length path >= sun_path_max then
        invalid_arg
          (Printf.sprintf
             "mentat_server: socket path %S is %d bytes, at or over the \
              %d-byte unix-socket limit; choose a shorter directory (the \
              --socket flag, or a shallower data home)"
             path (String.length path) sun_path_max);
      ensure_private_dir dir;
      (try Unix.unlink path with Unix.Unix_error _ -> ());
      let socket = Eio.Net.listen net ~sw ~backlog:16 (`Unix path) in
      (* The socket file is created by [bind]; tighten it to 0600 so only the
         owning uid can connect (defense in depth beneath the 0700 dir). *)
      (try Unix.chmod path 0o600 with Unix.Unix_error _ -> ());
      {
        bind;
        addr = None;
        run_server =
          (fun ~stop ~on_error server ->
            Cohttp_eio.Server.run ~stop ~on_error socket server);
      }
  | Loopback { port; _ } ->
      let port = Option.value port ~default:0 in
      let socket =
        Eio.Net.listen net ~sw ~backlog:16 ~reuse_addr:true
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      {
        bind;
        addr = Some (Eio.Net.listening_addr socket);
        run_server =
          (fun ~stop ~on_error server ->
            Cohttp_eio.Server.run ~stop ~on_error socket server);
      }
  | Public _ ->
      (* The type-level guarantee (a public bind needs the TLS × token × origin
         triple) holds now; its listener lands in Stage 3. *)
      raise
        (Unsupported
           "mentat_server: a public (non-loopback) listener lands in Stage 3")

let port listener =
  match listener.addr with
  | Some (`Tcp (_ip, port)) -> Some port
  | Some (`Unix _) | None -> None

(* HTTP responses (server side). cohttp owns body framing: [reply] a fixed
   string, [reply_stream] an SSE body cohttp reads from a flow source and
   chunk-encodes itself. Hand-rolled chunking in expert mode corrupted large
   frames (an Eio.Buf_write per-chunk-flush interaction), so the flow source is
   the correct path. Its one cost is that a mid-stream client disconnect has no
   handler-scope finalizer: the stream's [pull] closes the resource on the
   stream's own end and on cancellation (switch teardown), so the seam/flow is
   released at connection teardown rather than the instant the socket drops. *)

let unavailable message = Mentat_protocol.Error.unavailable message

let reply ?(content_type = "application/json") ~status ~body () =
  Cohttp_eio.Server.respond_string
    ~headers:(Cohttp.Header.of_list [ ("content-type", content_type) ])
    ~status ~body ()

module Sse_source = struct
  type t = {
    mutable buf : string;
    mutable pos : int;
    pull : unit -> string option;
  }

  let read_methods = []

  let rec single_read t dst =
    if t.pos < String.length t.buf then begin
      let len = min (Cstruct.length dst) (String.length t.buf - t.pos) in
      Cstruct.blit_from_string t.buf t.pos dst 0 len;
      t.pos <- t.pos + len;
      len
    end
    else
      match t.pull () with
      | None -> raise End_of_file
      | Some frame ->
          t.buf <- frame;
          t.pos <- 0;
          single_read t dst
end

let sse_source pull =
  Eio.Resource.T
    ( { Sse_source.buf = ""; pos = 0; pull },
      Eio.Flow.Pi.source (module Sse_source) )

let reply_stream pull =
  Cohttp_eio.Server.respond ~status:`OK
    ~headers:
      (Cohttp.Header.of_list
         [
           ("content-type", "text/event-stream"); ("cache-control", "no-cache");
         ])
    ~body:(sse_source pull) ()

(* Request-body reading (server side). *)

let read_body body =
  let reader = Eio.Buf_read.of_flow body ~max_size:(16 * 1024 * 1024) in
  Eio.Buf_read.take_all reader

(* Auth. /health is pre-auth; every other route passes here first. *)
let authorize bind request =
  match bind with
  | Unix _ -> Ok ()
  | Loopback { token; _ } | Public { token; _ } -> (
      let headers = Cohttp.Request.headers request in
      match Cohttp.Header.get headers "authorization" with
      | Some value
        when String.length value > 7
             && String.equal (String.sub value 0 7) "Bearer " ->
          let presented = String.sub value 7 (String.length value - 7) in
          if Token.equal presented token then Ok () else Error `Unauthorized
      | Some _ | None -> Error `Unauthorized)

(* Whether a request needs the request-id backstop, derived from the resolved
   descriptor's [idempotency] field — the one source both the dispatcher and the
   remote driver read (the one-table claim). The sole per-variant
   case, [session.submit], defers to {!Endpoint.submit_variant_requires_request_id}
   — the single named exception. *)
let requires_request_id endpoint payload =
  match Endpoint.find endpoint with
  | None -> false
  | Some (Endpoint.Any descriptor) -> (
      match descriptor.Endpoint.idempotency with
      | Endpoint.Requires_request_id -> true
      | Endpoint.By_domain_id | Endpoint.By_value -> (
          String.equal endpoint Endpoint.submit.Endpoint.name
          &&
          match Wire.decode_json Mentat_protocol.Command.jsont payload with
          | Ok command -> Endpoint.submit_variant_requires_request_id command
          | Error _ -> false))

(* The request-id find-or-create ledger: a daemon-global,
   bounded backstop over the reconnect window. A lost-ack retry that reuses its
   id hits the cached outcome, so the effect runs once. It is bounded — the
   oldest outcome is evicted past [cap] — so it cannot grow for the daemon's
   lifetime; it is a backstop over the reconnect window, not an unbounded
   guarantee. The key is the client-minted request-id alone; collision safety
   rests on the client minting a >=128-bit random id ({!connect} does; a raw
   caller carries that obligation).

   [find_or_run] is not atomic across the driver field's own yield: two in-flight
   requests carrying the same id could both miss the cache and run the effect.
   This is exactly the disclosed [Admission_unknown] residual, accepted for
   the single-user daemon where a client's retries are sequential ({!connect}
   retries in-order on one connection), not a concurrent same-id race; a finer
   atomic find-or-create lands with the durable-admission wave. *)
module Ledger = struct
  type t = {
    outcomes : (string, (Jsont.json, Mentat_protocol.Error.t) result) Hashtbl.t;
    order : string Queue.t;
    cap : int;
  }

  let create cap =
    { outcomes = Hashtbl.create 256; order = Queue.create (); cap }

  let find_or_run t rid run =
    match Hashtbl.find_opt t.outcomes rid with
    | Some outcome -> outcome
    | None ->
        let outcome = run () in
        Hashtbl.replace t.outcomes rid outcome;
        Queue.add rid t.order;
        if Hashtbl.length t.outcomes > t.cap then
          Hashtbl.remove t.outcomes (Queue.take t.order);
        outcome
end

(* Feed [from] resolution: a [Last-Event-ID] header (native [EventSource]
   reconnect) or an [after] query names a committed position; else the [from]
   query. Progress is id-less, so a resume id always names a committed fact. *)
let parse_from ~session request uri =
  let after_seq seq = `After (Mentat_protocol.Position.make ~session ~seq) in
  let headers = Cohttp.Request.headers request in
  match Cohttp.Header.get headers "last-event-id" with
  | Some s -> (
      match int_of_string_opt s with Some seq -> after_seq seq | None -> `Now)
  | None -> (
      match Uri.get_query_param uri "after" with
      | Some s -> (
          match int_of_string_opt s with
          | Some seq -> after_seq seq
          | None -> `Now)
      | None -> (
          match Uri.get_query_param uri "from" with
          | Some "beginning" -> `Beginning
          | Some "now" | Some _ | None -> `Now))

(* SSE frame encoders. *)
let default_heartbeat = 15.0

let update_frame update =
  match update with
  | Mentat_protocol.Update.Committed { position; _ } ->
      let id = string_of_int (Mentat_protocol.Position.seq position) in
      Sse.Writer.frame ~id
        ~data:(Wire.encode Mentat_protocol.Update.jsont update)
        ()
  | Mentat_protocol.Update.Progress _ ->
      Sse.Writer.frame
        ~data:(Wire.encode Mentat_protocol.Update.jsont update)
        ()

let error_frame error =
  Sse.Writer.frame ~event:"error"
    ~data:(Wire.encode Mentat_protocol.Error.jsont error)
    ()

(* A once-off puller: one frame, then end (a follow/login that refused). *)
let one_frame_puller frame =
  let state = ref (`Send frame) in
  fun () ->
    match !state with
    | `Send frame ->
        state := `Done;
        Some frame
    | `Done -> None

(* Release a stream's resource on any exit of the (cohttp-driven) body write —
   normal end, a mid-stream client disconnect (cohttp's write raises through this
   wrapper), or cancellation at teardown. This is the handler-scope finalizer the
   flow-source model otherwise lacks, restored at the [response] level. *)
let with_release ~finally base_response writer =
  Fun.protect ~finally (fun () -> base_response writer)

(* The feed puller cohttp reads: one SSE frame per call, racing the next
   committed/progress pull against the idle heartbeat. Committed facts carry their
   [id:]; progress is id-less, so a resume id always names a committed position. *)
let feed_puller ~clock ~heartbeat (seam : Mentat_client.Feed.seam) =
  let state = ref `Live in
  fun () ->
    match !state with
    | `Done -> None
    | `Live -> (
        match
          Eio.Fiber.first
            (fun () -> `Item (seam.Mentat_client.Feed.next ()))
            (fun () ->
              Eio.Time.sleep clock heartbeat;
              `Beat)
        with
        | `Beat -> Some Sse.Writer.heartbeat
        | `Item (Ok (Mentat_client.Feed.Item update)) ->
            Some (update_frame update)
        | `Item (Ok Mentat_client.Feed.Closed) ->
            state := `Done;
            None
        | `Item (Error error) ->
            state := `Done;
            Some (error_frame error))

let handle_feed ~clock ~heartbeat ~driver request uri =
  match Uri.get_query_param uri "session" with
  | None -> reply ~status:`Bad_request ~body:"missing session" ()
  | Some raw -> (
      let session = Mentat_session.Id.of_string raw in
      let from = parse_from ~session request uri in
      match
        driver.Mentat_client.Driver.session.Mentat_client.Driver.Session.follow
          session ~from
      with
      | Error error -> reply_stream (one_frame_puller (error_frame error))
      | Ok seam ->
          with_release
            ~finally:(fun () -> seam.Mentat_client.Feed.close ())
            (reply_stream (feed_puller ~clock ~heartbeat seam)))

(* The login puller: one [login_step] frame per call, racing the next step
   against the idle heartbeat (device-code waits are long, mirroring the feed); no
   resume id (steps are not positioned). *)
let login_puller ~clock ~heartbeat (steps : Mentat_client.Login.steps) =
  let state = ref `Live in
  fun () ->
    match !state with
    | `Done -> None
    | `Live -> (
        match
          Eio.Fiber.first
            (fun () -> `Step (steps.Mentat_client.Login.next ()))
            (fun () ->
              Eio.Time.sleep clock heartbeat;
              `Beat)
        with
        | `Beat -> Some Sse.Writer.heartbeat
        | `Step (Ok step) ->
            (match step with
            | Mentat_client.Login.Progress _ -> ()
            | Mentat_client.Login.Saved _ | Mentat_client.Login.Cancelled ->
                state := `Done);
            Some
              (Sse.Writer.frame
                 ~data:(Wire.encode Flow_codec.login_step step)
                 ())
        | `Step (Error error) ->
            state := `Done;
            Some (error_frame error))

let handle_login ~clock ~heartbeat ~driver body =
  match Wire.decode Codecs.login body with
  | Error message -> reply ~status:`Bad_request ~body:message ()
  | Ok { Codecs.login_provider; method_ } -> (
      match
        driver.Mentat_client.Driver.accounts.Mentat_client.Driver.Accounts.login
          ~provider:login_provider ~method_
      with
      | Error error -> reply_stream (one_frame_puller (error_frame error))
      | Ok steps ->
          with_release
            ~finally:(fun () -> steps.Mentat_client.Login.cancel ())
            (reply_stream (login_puller ~clock ~heartbeat steps)))

(* Single-shot wire dispatch (server side). *)
let handle_wire ~driver ~ledger body =
  match Wire.decode Wire.request_jsont body with
  | Error message -> reply ~status:`Bad_request ~body:message ()
  | Ok { Wire.request_id; endpoint; payload } -> (
      match Endpoint.find endpoint with
      | None ->
          reply ~status:`Not_found
            ~body:(Printf.sprintf "unknown endpoint %s" endpoint)
            ()
      | Some (Endpoint.Any descriptor) -> (
          match Wire.decode_json descriptor.Endpoint.request payload with
          | Error message -> reply ~status:`Bad_request ~body:message ()
          | Ok request ->
              let invoke () =
                match descriptor.Endpoint.invoke driver request with
                | Ok resp ->
                    Ok (Wire.encode_json descriptor.Endpoint.response resp)
                | Error error -> Error error
              in
              let outcome =
                if requires_request_id endpoint payload then
                  match request_id with
                  | Some rid -> Ledger.find_or_run ledger rid invoke
                  | None -> invoke ()
                else invoke ()
              in
              let envelope = { Wire.resp_request_id = request_id; outcome } in
              reply ~status:`OK
                ~body:(Wire.encode Wire.response_jsont envelope)
                ()))

(* A driver bound to one connection at handshake, plus how to tear it down.
   The bound [workspace] is echoed back so the client can refuse a wrong-checkout
   attach; [on_close] fires exactly once when the connection ends. *)
type target = {
  workspace : string option;
  driver : Mentat_client.Driver.t;
  on_close : unit -> unit;
}

(* The per-connection binding: the resolved [target] plus a fired-guard so
   [on_close] runs exactly once. Keyed in the dispatcher's binding table by
   the cohttp connection identity, which is stable across every request on one
   TCP connection and distinct between connections. *)
type binding = { target : target; mutable closed : bool }

(* cohttp mints one [Connection.t] per accepted TCP connection, stable across its
   keep-alive requests and distinct between connections — exactly the binding-map
   key A4 needs. cohttp deprecates the type as "useless" for its own routing, but
   its monotonic identity is precisely what we key on. *)
let conn_key ((_flow, id) : Cohttp_eio.Server.conn) =
  (Cohttp.Connection.to_string [@alert "-deprecated"]) id

(* Fire a connection's [on_close] once, remove its binding. Registered on the
   connection's own switch so it runs on normal end, error, and server
   cancellation alike (cohttp's [conn_closed] fires only on a read-EOF); a raised
   [on_close] must never fell the switch teardown. *)
let close_binding bindings key =
  match Hashtbl.find_opt bindings key with
  | Some b when not b.closed -> (
      b.closed <- true;
      Hashtbl.remove bindings key;
      try b.target.on_close ()
      with exn ->
        Eio.traceln "mentat_server: on_close raised: %s"
          (Printexc.to_string exn))
  | Some _ | None -> ()

(* The handshake establishes the connection's binding by asking [driver_for]
   for the requested workspace's target. A [v_max] below the daemon floor is a 409
   version refusal; a [driver_for] error (a wrong workspace, or A9's absent
   workspace) is a structured refusal carrying the protocol error and leaves the
   connection unbound. On success the binding is recorded under the connection key
   and [on_close] is armed on the connection switch. *)
let handle_handshake ~driver_for ~bindings conn body =
  let (conn_sw, _peer), _id = conn in
  let key = conn_key conn in
  match Wire.decode Wire.handshake_request_jsont body with
  | Error message -> reply ~status:`Bad_request ~body:message ()
  | Ok { Wire.v_max; requested_workspace; environment } -> (
      if v_max < Wire.version then
        (* The client's floor is below the daemon's; refuse with 409 and name the
           server version. *)
        reply ~status:`Conflict
          ~body:
            (Wire.encode Wire.handshake_response_jsont
               { Wire.negotiated = Wire.version; Wire.workspace = None })
          ()
      else
        match Hashtbl.find_opt bindings key with
        | Some { target; _ } ->
            (* A duplicate handshake on an already-bound connection (a client bug):
               echo the existing binding {b without} calling [driver_for] again, so
               no second instance lease is taken and leaked — the leaked lease would
               never be released ([on_close] fires once per connection) and would
               pin the instance and disarm the idle watchdog (F1). *)
            reply ~status:`OK
              ~body:
                (Wire.encode Wire.handshake_response_jsont
                   {
                     Wire.negotiated = Wire.version;
                     Wire.workspace = target.workspace;
                   })
              ()
        | None -> (
            match driver_for ~workspace:requested_workspace ~environment with
            | Error error ->
                (* A9 / wrong-checkout refusal: a structured protocol error, the
                   connection left unbound (the client treats it as definite and
                   closes). *)
                reply ~status:(`Code 422)
                  ~body:(Wire.encode Mentat_protocol.Error.jsont error)
                  ()
            | Ok target ->
                Hashtbl.replace bindings key { target; closed = false };
                Eio.Switch.on_release conn_sw (fun () ->
                    close_binding bindings key);
                reply ~status:`OK
                  ~body:
                    (Wire.encode Wire.handshake_response_jsont
                       {
                         Wire.negotiated = Wire.version;
                         Wire.workspace = target.workspace;
                       })
                  ()))

(* A non-handshake request on a connection with no binding (a raw client that
   skipped the handshake): a structured "not bound" error in the shape the path
   expects. The typed [connect] never reaches here — it handshakes first on
   every connection. *)
let reply_unbound meth path =
  let error =
    unavailable "connection is not bound to a workspace; send a handshake first"
  in
  match (meth, path) with
  | `POST, "/wire" ->
      reply ~status:`OK
        ~body:
          (Wire.encode Wire.response_jsont
             { Wire.resp_request_id = None; outcome = Error error })
        ()
  | `GET, "/feed" | `POST, "/login" ->
      reply_stream (one_frame_puller (error_frame error))
  | _ -> reply ~status:`Not_found ~body:"not found" ()

let handle ~clock ~heartbeat ~driver_for ~bindings ~bind ~ledger conn request
    body =
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  match (meth, path) with
  | `GET, "/health" ->
      (* Pre-auth and content-free. *)
      reply ~content_type:"text/plain; charset=utf-8" ~status:`OK ~body:"ok" ()
  | _ -> (
      match authorize bind request with
      | Error `Unauthorized ->
          reply ~status:`Unauthorized ~body:"unauthorized" ()
      | Ok () -> (
          let body_text = read_body body in
          match (meth, path) with
          | `POST, "/handshake" ->
              handle_handshake ~driver_for ~bindings conn body_text
          | _ -> (
              match Hashtbl.find_opt bindings (conn_key conn) with
              | None -> reply_unbound meth path
              | Some { target; _ } -> (
                  let driver = target.driver in
                  match (meth, path) with
                  | `GET, "/feed" ->
                      handle_feed ~clock ~heartbeat ~driver request uri
                  | `POST, "/login" ->
                      handle_login ~clock ~heartbeat ~driver body_text
                  | `POST, "/wire" -> handle_wire ~driver ~ledger body_text
                  | _ -> reply ~status:`Not_found ~body:"not found" ()))))

let default_ledger_cap = 1024

(* Exceptions a mid-stream client disconnect raises through the per-connection
   fiber; these are expected and swallowed. Anything else is surfaced (never
   silently), so a real server fault is not lost. *)
let is_disconnect = function
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _)
  | End_of_file
  | Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) ->
      true
  | _ -> false

let serve ~sw ~clock ?(heartbeat_s = default_heartbeat)
    ?(ledger_cap = default_ledger_cap) ~driver_for listener =
  let stop, resolve_stop = Eio.Promise.create () in
  Eio.Switch.on_release sw (fun () ->
      ignore (Eio.Promise.try_resolve resolve_stop ()));
  let ledger = Ledger.create ledger_cap in
  (* Per-connection bindings, keyed by connection identity. All connection
     fibers share this table; [serve] runs cohttp in a single domain (no
     [additional_domains]), so the cooperative Hashtbl access never races. *)
  let bindings : (string, binding) Hashtbl.t = Hashtbl.create 16 in
  let server =
    Cohttp_eio.Server.make
      ~callback:
        (handle ~clock ~heartbeat:heartbeat_s ~driver_for ~bindings
           ~bind:listener.bind ~ledger)
      ()
  in
  listener.run_server ~stop
    ~on_error:(fun exn ->
      (* A mid-stream client disconnect never fells the accept loop; a genuine
         fault is surfaced rather than swallowed. *)
      if not (is_disconnect exn) then
        Eio.traceln "mentat_server: connection error: %s"
          (Printexc.to_string exn))
    server

(* ---- The browser edge: a rendering surface mounted behind the shared edge ---- *)

(* [Web] is [mentat.server]'s one browser edge: the single-use-token → cookie
   exchange, the unconditional Origin/Host allow-listing, the strict CSP on every
   response, URI-redacted logging, and the push→pull SSE bridge — applied to a
   rendering surface this library does not link. The surface's routes and its live
   feed cross as [handler] callbacks; the daemon binary backs them with
   [mentat.web], so the HTML is rendered frontend-side and never here. It reuses
   the same [listener], [sse_source], [read_body], [Wire] framing, and
   [is_disconnect] the JSON wire uses; only the auth and header policy differ. *)
module Web = struct
  let cookie_name = "mentat_session"

  (* The one authoritative policy the edge sets on every response. It is
     byte-identical to [mentat.web]'s in-page [<meta>] copy (page.ml), which
     documents the contract at the point the page is served; this header is the
     enforced one and adds [frame-ancestors] (header-only, the clickjacking
     defense). [default-src 'none'] denies every source class, then re-grants only
     same-origin script/style, same-origin [connect] (the [EventSource]), and
     same-origin form posts — no inline, no [eval], no cross-origin. *)
  let content_security_policy =
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' \
     data:; connect-src 'self'; form-action 'self'; base-uri 'none'; \
     frame-ancestors 'none'"

  module Cookie_jar = struct
    (* Ephemeral browser-session secrets: minted on the token→cookie
       exchange, held in memory only (never durable), bounded so a long-lived
       daemon cannot grow. Each is compared in constant time; membership across
       the — typically one-entry — set is not itself a defended secret under the
       single-user posture (over-loopback cleartext is conceded). *)
    type t = {
      secrets : (string, unit) Hashtbl.t;
      order : string Queue.t;
      cap : int;
    }

    let create cap =
      { secrets = Hashtbl.create 16; order = Queue.create (); cap }

    let mint jar =
      let secret = csprng_hex 32 in
      Hashtbl.replace jar.secrets secret ();
      Queue.add secret jar.order;
      if Hashtbl.length jar.secrets > jar.cap then
        Hashtbl.remove jar.secrets (Queue.take jar.order);
      secret

    let valid jar presented =
      Hashtbl.fold
        (fun secret () found -> found || constant_time_equal presented secret)
        jar.secrets false
  end

  (* Request-part decoding, matching [Mentat_web.Routes.handle]'s expected shapes
     exactly (the edge owns HTTP parsing; the surface receives clean parts). *)
  let split_path p =
    String.split_on_char '/' p |> List.filter (fun s -> s <> "")

  let parse_form body =
    (* [routes] reads a key to its {e last} value; flattening then reversing makes
       the surface's [List.assoc_opt] (first match) resolve to the last one,
       regardless of how [Uri] groups repeated keys. *)
    Uri.query_of_encoded body
    |> List.concat_map (fun (k, vs) -> List.map (fun v -> (k, v)) vs)
    |> List.rev

  let cookie_value headers =
    match Cohttp.Header.get headers "cookie" with
    | None -> None
    | Some raw ->
        String.split_on_char ';' raw
        |> List.find_map (fun kv ->
            match String.index_opt kv '=' with
            | None -> None
            | Some i ->
                let key = String.trim (String.sub kv 0 i) in
                if String.equal key cookie_name then
                  Some
                    (String.trim
                       (String.sub kv (i + 1) (String.length kv - i - 1)))
                else None)

  (* The host:port an Origin allowlist entry ("http://127.0.0.1:P") matches on
     the [Host] line ("127.0.0.1:P"); a bare host is returned unchanged. *)
  let host_of_origin o =
    match String.split_on_char '/' o with
    | _scheme :: "" :: host :: _ -> host
    | _ -> o

  (* A valid cookie is not enough against a confused-deputy browser or DNS
     rebinding, so every authenticated request is checked against the daemon's own
     [Origin]/[Host] allowlist. A foreign [Host] (the rebinding case) is refused;
     a present foreign [Origin] (the CSRF case) is refused; an absent [Origin] (a
     top-level navigation) rides the [Host] check and [SameSite=Strict]. HTTP/1.1
     requires [Host], so its absence is refused. *)
  let origin_host_ok ~origins headers =
    let allowed_hosts = List.map host_of_origin origins in
    let host_ok =
      match Cohttp.Header.get headers "host" with
      | Some h -> List.exists (String.equal h) allowed_hosts
      | None -> false
    in
    let origin_ok =
      match Cohttp.Header.get headers "origin" with
      | Some o ->
          List.exists (fun a -> Origin.equal (Origin.of_string o) a) origins
      | None -> true
    in
    host_ok && origin_ok

  (* The live feed's resume point: native [EventSource] resends [Last-Event-ID] on
     reconnect; first paint carries [?from=<seq>] (the server-rendered tail head)
     or [?from=beginning]. Either names a committed position, so a resume never
     lands mid-progress. A malformed value degrades to [`Beginning]. *)
  let parse_from ~session headers uri =
    let after seq = `After (Mentat_protocol.Position.make ~session ~seq) in
    match Cohttp.Header.get headers "last-event-id" with
    | Some s -> (
        match int_of_string_opt s with
        | Some seq -> after seq
        | None -> `Beginning)
    | None -> (
        match Uri.get_query_param uri "from" with
        | None | Some "beginning" -> `Beginning
        | Some s -> (
            match int_of_string_opt s with
            | Some seq -> after seq
            | None -> `Beginning))

  (* The single-use bootstrap token crosses in a query string exactly once;
     a logged URI would persist it in cleartext, so any query is redacted before
     it can reach a log. *)
  let redact_uri s =
    match String.index_opt s '?' with
    | Some i -> String.sub s 0 i ^ "?<redacted>"
    | None -> s

  let set_cookie secret =
    (* [HttpOnly] (unreadable to script — the XSS-exfiltration defense), [SameSite=
       Strict] (never sent cross-site — the CSRF defense), [Path=/]. No [Secure]:
       the Stage-3 loopback path carries no TLS. *)
    Printf.sprintf "%s=%s; Path=/; HttpOnly; SameSite=Strict" cookie_name secret

  (* The exchange redirect target derives from the request path, so it is pinned
     to a single-leading-slash absolute path: a crafted [//host] (or its
     backslash variant, which browsers normalise) would otherwise turn the 303
     into a protocol-relative open redirect. *)
  let redirect_target uri =
    let stripped = Uri.remove_query_param uri "t" in
    match Uri.path_and_query stripped with
    | "" -> "/"
    | s when not (Char.equal s.[0] '/') -> "/"
    | s
      when String.length s > 1 && (Char.equal s.[1] '/' || Char.equal s.[1] '\\')
      ->
        "/"
    | s -> s

  type http = { status : int; headers : (string * string) list; body : string }
  (** The transport-ready shape of one rendered response the surface produced
      ([Mentat_web.Routes.Http.t], adapted at the daemon). The surface owns the
      status, content type, and body; the edge layers the CSP and the cookie. *)

  type frame = { id : int option; html : string }
  (** One rendered live fragment ([Mentat_web.Routes.Frame.t], adapted). [id] is
      the committed sequence written as the SSE [id:] so a native [EventSource]
      resumes from it; [None] is a droppable live-region morph, carrying no
      [id:]. The edge frames it as SSE. *)

  type from = [ `Beginning | `After of Mentat_protocol.Position.t ]
  (** A feed resume point, resolved from the request by the edge. *)

  type handler = {
    respond :
      meth:string ->
      path:string list ->
      query:(string * string list) list ->
      body:(string * string) list ->
      http;
    stream :
      sw:Eio.Switch.t ->
      session:Mentat_session.Id.t ->
      from:from ->
      emit:(frame -> unit) ->
      (unit, string) result;
        (** [Ok ()] ends the stream (a normal close, or a logged internal
            abort); [Error message] emits one terminal SSE [event: error] frame
            carrying [message], then ends — the surface's honest attach/render
            fault. *)
  }
  (** The rendering surface, supplied by the daemon and backed by [mentat.web].
      [respond] routes one non-streaming request to a rendered response;
      [stream] follows a session's live render, pushing each frame to [emit]
      until the feed closes or faults (a fault is the surface's to render or log
      — [mentat.web] owns the projection; the edge only frames and paces). *)

  let reply ~status ~headers ~body =
    Cohttp_eio.Server.respond_string
      ~headers:
        (Cohttp.Header.of_list
           (("content-security-policy", content_security_policy) :: headers))
      ~status ~body ()

  let reply_stream pull =
    Cohttp_eio.Server.respond ~status:`OK
      ~headers:
        (Cohttp.Header.of_list
           [
             ("content-type", "text/event-stream");
             ("cache-control", "no-cache");
             ("content-security-policy", content_security_policy);
           ])
      ~body:(sse_source pull) ()

  (* The push→pull bridge. [handler.stream] is a blocking producer that
     pushes frames to [emit]; cohttp drives a pull [sse_source]. A producer fiber
     forked on the {b connection} switch feeds a bounded queue, and the pull races
     the queue against the idle heartbeat; a mid-stream disconnect closes the
     connection, cancels the producer, and so releases the surface's feed (the
     hub becomes evictable) — the same release-at-connection-teardown model the
     JSON wire feed has. Progress-drop backpressure is the queue bound. *)
  let feed_response ~conn_sw ~clock ~heartbeat ~session ~from handler =
    let queue = Eio.Stream.create 64 in
    Eio.Fiber.fork ~sw:conn_sw (fun () ->
        (match
           handler.stream ~sw:conn_sw ~session ~from
             ~emit:(fun (frame : frame) ->
               let sse =
                 Sse.Writer.frame
                   ?id:(Option.map string_of_int frame.id)
                   ~data:frame.html ()
               in
               Eio.Stream.add queue (`Frame sse))
         with
        | Ok () -> ()
        | Error message ->
            (* A terminal SSE error event: the browser's [EventSource.onerror]
               fires and it re-attaches from its last committed [id:]. *)
            Eio.Stream.add queue
              (`Frame (Sse.Writer.frame ~event:"error" ~data:message ())));
        Eio.Stream.add queue `End);
    let state = ref `Live in
    let pull () =
      match !state with
      | `Done -> None
      | `Live -> (
          match
            Eio.Fiber.first
              (fun () -> `Item (Eio.Stream.take queue))
              (fun () ->
                Eio.Time.sleep clock heartbeat;
                `Beat)
          with
          | `Beat -> Some Sse.Writer.heartbeat
          | `Item (`Frame s) -> Some s
          | `Item `End ->
              state := `Done;
              None)
    in
    reply_stream pull

  type auth = Cookie_ok | Exchange of string * string | Reject

  let authenticate ~current ~jar ~on_rotate headers uri =
    match cookie_value headers with
    | Some c when Cookie_jar.valid jar c -> Cookie_ok
    | _ -> (
        match Uri.get_query_param uri "t" with
        | Some presented when Token.equal presented !current ->
            (* Consume-and-rotate. A valid presentation is exchanged for a
               session cookie and the token is replaced by a freshly minted
               successor, so no token ever works twice (a leaked history URL
               cannot be replayed) while the daemon always holds one live entry
               URL — [on_rotate] hands the successor to the owner to republish.
               The redirect drops the consumed token from the address bar.
               A browser that already holds the cookie takes the
               [Cookie_ok] branch above, so a reload after the exchange still
               works. *)
            let next = Token.generate () in
            current := next;
            on_rotate next;
            Exchange (set_cookie (Cookie_jar.mint jar), redirect_target uri)
        | _ -> Reject)

  let plain = [ ("content-type", "text/plain; charset=utf-8") ]

  let callback ~clock ~heartbeat ~current ~origins ~jar ~on_rotate handler
      (((conn_sw, _peer), _id) : Cohttp_eio.Server.conn) request body =
    let uri = Cohttp.Request.uri request in
    let meth = Cohttp.Request.meth request in
    let headers = Cohttp.Request.headers request in
    let path = split_path (Uri.path uri) in
    match (meth, path) with
    | `GET, [ "health" ] ->
        (* Pre-auth and content-free, like the wire's. *)
        reply ~status:`OK ~headers:plain ~body:"ok"
    | _ -> (
        if not (origin_host_ok ~origins headers) then
          reply ~status:`Forbidden ~headers:plain ~body:"forbidden"
        else
          match authenticate ~current ~jar ~on_rotate headers uri with
          | Reject ->
              reply ~status:`Unauthorized ~headers:plain ~body:"unauthorized"
          | Exchange (cookie, target) ->
              reply ~status:(`Code 303)
                ~headers:[ ("location", target); ("set-cookie", cookie) ]
                ~body:""
          | Cookie_ok -> (
              match (meth, path) with
              | `GET, [ "session"; id; "feed" ] ->
                  let session = Mentat_session.Id.of_string id in
                  let from = parse_from ~session headers uri in
                  feed_response ~conn_sw ~clock ~heartbeat ~session ~from
                    handler
              | _ ->
                  let form =
                    if meth = `POST then parse_form (read_body body) else []
                  in
                  let response : http =
                    handler.respond
                      ~meth:(Cohttp.Code.string_of_method meth)
                      ~path ~query:(Uri.query uri) ~body:form
                  in
                  reply ~status:(`Code response.status)
                    ~headers:response.headers ~body:response.body))

  let serve ~sw ~clock ?(heartbeat_s = default_heartbeat) ~token ~on_rotate
      ~origins handler listener =
    let stop, resolve_stop = Eio.Promise.create () in
    Eio.Switch.on_release sw (fun () ->
        ignore (Eio.Promise.try_resolve resolve_stop ()));
    let jar = Cookie_jar.create 64 in
    (* The one live entry token, daemon-wide: [token] bootstraps it, and each
       exchange swaps in a freshly minted successor (consume-and-rotate). *)
    let current = ref token in
    let server =
      Cohttp_eio.Server.make
        ~callback:
          (callback ~clock ~heartbeat:heartbeat_s ~current ~origins ~jar
             ~on_rotate handler)
        ()
    in
    listener.run_server ~stop
      ~on_error:(fun exn ->
        if not (is_disconnect exn) then
          Eio.traceln "mentat_server.web: connection error: %s"
            (redact_uri (Printexc.to_string exn)))
      server
end

(* ---- connect: the remote driver ---- *)

module Error = struct
  type t = Unsupported_version of { server_v : int } | Transport of string

  let pp ppf = function
    | Unsupported_version { server_v } ->
        Format.fprintf ppf
          "daemon envelope version %d is below the client floor" server_v
    | Transport message -> Format.fprintf ppf "transport failure: %s" message
end

let mint_request_id () =
  (* 16 bytes = 128 bits, the collision-safety floor the ledger key relies on. *)
  csprng_hex 16

(* A per-request abort, distinct from cancellation: [close]/[cancel] fails a
   stream's sub-switch with this, aborting the connection so the daemon sees the
   disconnect and releases its seam/flow. *)
exception Aborted

(* A handshake that failed while opening a stream connection, carrying the
   protocol error to surface as the stream's terminal fault. *)
exception Stream_handshake_failed of Mentat_protocol.Error.t

(* The dial context for one logical [connect]. A connection is short-lived and
   per-operation: each single-shot call and each stream dials a {b fresh}
   socket via [dial], speaks a handshake on it, then makes its one request on the
   {b same} socket. [workspace] is sent in every handshake so the daemon binds and
   echoes it; [sw] owns the streams' sub-switches. There is no long-lived pooled
   client — the daemon's binding map already supports connection reuse unchanged,
   so opportunistic client-side reuse is a later pure-client optimization. *)
type ctx = {
  dial : sw:Eio.Switch.t -> [ `Close | Eio.Flow.two_way_ty ] Eio.Resource.t;
  base : string;
  token : Token.t option;
  workspace : string option;
  environment : (string * string) list option;
  sw : Eio.Switch.t;
}

let auth_headers token =
  match token with
  | None -> []
  | Some token -> [ ("authorization", "Bearer " ^ Token.to_string token) ]

let make_ctx ~sw ~net ?workspace ?environment bind =
  (* The wire is JSON: a binding either side cannot spell in UTF-8 is dropped
     rather than fatal, matching the child environment's own total
     construction. *)
  let environment =
    Option.map
      (List.filter (fun (name, value) ->
           String.is_valid_utf_8 name && String.is_valid_utf_8 value))
      environment
  in
  match bind with
  | Unix { dir } ->
      let path = unix_socket_path dir in
      let dial ~sw =
        (Eio.Net.connect ~sw net (`Unix path)
          :> [ `Close | Eio.Flow.two_way_ty ] Eio.Resource.t)
      in
      Ok
        {
          dial;
          base = "http://mentat";
          token = None;
          workspace;
          environment;
          sw;
        }
  | Loopback { port; token } -> (
      match port with
      | None ->
          Error
            (Error.Transport
               "connect to an ephemeral loopback port needs the resolved port")
      | Some port ->
          let dial ~sw =
            (Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
              :> [ `Close | Eio.Flow.two_way_ty ] Eio.Resource.t)
          in
          Ok
            {
              dial;
              base = Printf.sprintf "http://127.0.0.1:%d" port;
              token = Some token;
              workspace;
              environment;
              sw;
            })
  | Public _ ->
      Error (Error.Transport "connect to a public daemon lands in Stage 3")

(* A client pinned to one already-dialed socket, so a handshake and the request
   that follows it ride the same TCP connection. cohttp's own client dials a
   fresh socket per call; pinning routes every call through this one. Two serial
   request/response exchanges on one socket are sound: the request is only written
   after the prior response is fully read, so the socket never carries overlapping
   frames. *)
let pinned_client socket =
  Cohttp_eio.Client.make_generic (fun ~sw:_ _uri -> socket)

let http_post ~base ~token client ~sw path body =
  let uri = Uri.of_string (base ^ path) in
  let headers =
    Cohttp.Header.of_list
      (("content-type", "application/json") :: auth_headers token)
  in
  match
    Cohttp_eio.Client.post client ~sw ~headers
      ~body:(Cohttp_eio.Body.of_string body)
      uri
  with
  | response, response_body ->
      let reader =
        Eio.Buf_read.of_flow response_body ~max_size:(16 * 1024 * 1024)
      in
      let text = Eio.Buf_read.take_all reader in
      Ok (Cohttp.Code.code_of_status (Cohttp.Response.status response), text)
  | exception (Eio.Cancel.Cancelled _ as raised) -> raise raised
  | exception exn -> Error (Printexc.to_string exn)

(* The connect-side handshake, spoken on [client]'s pinned socket before its one
   request. Returns the transport outcome so the caller can retry a bare
   [`Transport] failure but never a [`Definite] refusal (a 409 version mismatch,
   an A9 absent-workspace refusal, or a wrong-checkout echo). *)
let client_handshake ~base ~token ~workspace ~environment client ~sw =
  let body =
    Wire.encode Wire.handshake_request_jsont
      {
        Wire.v_max = Wire.version;
        requested_workspace = workspace;
        environment;
      }
  in
  match http_post ~base ~token client ~sw "/handshake" body with
  | Error message -> Error (`Transport message)
  | Ok (200, text) -> (
      match Wire.decode Wire.handshake_response_jsont text with
      | Error message -> Error (`Transport message)
      | Ok { Wire.workspace = echoed; _ } -> (
          (* Refuse a wrong-checkout attach: the daemon must bind the workspace
             the client requested. *)
          match (workspace, echoed) with
          | Some requested, Some bound when not (String.equal requested bound)
            ->
              Error
                (`Definite
                   (Error.Transport
                      (Printf.sprintf
                         "daemon bound workspace %s, but %s was requested" bound
                         requested)))
          | Some requested, None ->
              Error
                (`Definite
                   (Error.Transport
                      (Printf.sprintf
                         "daemon did not bind requested workspace %s" requested)))
          | (Some _ | None), _ -> Ok ()))
  | Ok (409, text) ->
      let server_v =
        match Wire.decode Wire.handshake_response_jsont text with
        | Ok { Wire.negotiated; _ } -> negotiated
        | Error _ -> Wire.version
      in
      Error (`Definite (Error.Unsupported_version { server_v }))
  | Ok (status, text) ->
      (* A driver_for / A9 refusal: the body is a structured protocol error.
         A 400 whose body decodes as neither is the one other shape a
         handshake can meet: a running daemon older than this client cannot
         read the request it was sent, and the raw codec complaint would send
         the user nowhere — name the skew and the way out instead. *)
      let message =
        match Wire.decode Mentat_protocol.Error.jsont text with
        | Ok error -> Format.asprintf "%a" Mentat_protocol.Error.pp error
        | Error _ when status = 400 ->
            Printf.sprintf
              "daemon rejected the handshake (%s); a running daemon older than \
               this client cannot read it — restart it with `mentat serve \
               --stop`"
              (String.trim text)
        | Error _ -> String.trim text
      in
      Error (`Definite (Error.Transport message))

(* One typed wire call through a descriptor row (connect side of the shared
   table). Each attempt dials a fresh socket, handshakes on it, then POSTs
   the wire call on the same socket; the sub-switch closes the socket when the attempt
   ends. The request-id backstop and the bounded transport retry live here so the
   {!Mentat_client.Driver} signature stays id-free: a
   Requires_request_id row mints one stable id per logical invocation — unless the
   caller supplied one, which [session.submit] does for its duplicate variants
   ({!Endpoint.submit_variant_requires_request_id}, the one named exception) — and
   on a {b transport} failure ONLY (the dial, the handshake's transport, or the
   wire POST), retries reusing THAT id so the daemon ledger dedups. A handshake
   {b refusal} (409 / wrong-checkout) and a decoded error response are definite,
   never retried. Retries exhausted is honest ambiguity: the effect may have been
   applied. *)
let call : type req resp.
    ctx ->
    ?request_id:string ->
    (req, resp) Endpoint.t ->
    req ->
    (resp, Mentat_protocol.Error.t) result =
 fun ctx ?request_id descriptor request ->
  let request_id =
    match request_id with
    | Some _ as supplied -> supplied
    | None -> (
        match descriptor.Endpoint.idempotency with
        | Endpoint.Requires_request_id -> Some (mint_request_id ())
        | Endpoint.By_domain_id | Endpoint.By_value -> None)
  in
  let payload = Wire.encode_json descriptor.Endpoint.request request in
  let envelope =
    { Wire.request_id; endpoint = descriptor.Endpoint.name; payload }
  in
  let body = Wire.encode Wire.request_jsont envelope in
  let decode_response text =
    match Wire.decode Wire.response_jsont text with
    | Error message -> Error (unavailable message)
    | Ok { Wire.outcome; _ } -> (
        match outcome with
        | Error error -> Error error
        | Ok json -> (
            match Wire.decode_json descriptor.Endpoint.response json with
            | Ok value -> Ok value
            | Error message -> Error (unavailable message)))
  in
  (* One dial + handshake + wire call, under a sub-switch that closes the socket on
     return. [`Retry] carries a transport reason; [`Done] a definite outcome. *)
  let attempt () =
    Eio.Switch.run @@ fun sub ->
    match ctx.dial ~sw:sub with
    | exception (Eio.Cancel.Cancelled _ as raised) -> raise raised
    | exception exn -> `Retry (Printexc.to_string exn)
    | socket -> (
        let client = pinned_client socket in
        match
          client_handshake ~base:ctx.base ~token:ctx.token
            ~workspace:ctx.workspace ~environment:ctx.environment client ~sw:sub
        with
        | Error (`Transport message) -> `Retry message
        | Error (`Definite error) ->
            `Done (Error (unavailable (Format.asprintf "%a" Error.pp error)))
        | Ok () -> (
            match
              http_post ~base:ctx.base ~token:ctx.token client ~sw:sub "/wire"
                body
            with
            | Error transport -> `Retry transport
            | Ok (status, text) ->
                if status >= 200 && status < 300 then
                  `Done (decode_response text)
                else
                  (* A non-2xx is a definite answer: map its status. *)
                  `Done
                    (Error
                       (unavailable
                          (Printf.sprintf "daemon returned HTTP %d: %s" status
                             (String.trim text))))))
  in
  let attempts = match request_id with Some _ -> 3 | None -> 1 in
  let rec go n =
    match attempt () with
    | `Done result -> result
    | `Retry transport ->
        if n < attempts then go (n + 1)
        else
          Error
            (unavailable
               (Printf.sprintf
                  "transport failed after %d attempt(s) (%s); the operation \
                   may have been applied — re-follow to observe"
                  attempts transport))
  in
  go 1

type stream_call = {
  sw_ctx : Eio.Switch.t;
  issue : sw:Eio.Switch.t -> Cohttp_eio.Body.t;
}

(* A streaming request re-materialised into a pull handle. The request and its
   SSE reader run under a per-request sub-switch forked on the connection switch;
   [abort] fails that sub-switch, aborting the connection so the daemon releases
   the seam/flow. The reader parses each frame with [parse] and enqueues;
   the consumer's pull takes from the queue and, racing a wake promise, [abort]
   releases a blocked pull.

   The [aborted] flag closes the race where [close]/[cancel] fires before the
   forked fiber has run: the initial [abort] sets the flag, and the fiber
   checks it before issuing the request — so an immediate close never leaks the
   stream past the first pull. There is no true parallelism (single Eio domain)
   and no yield between the fiber's start and its real [abort] assignment, so once
   the fiber runs the flag and the switch-fail cover every window. *)
let stream_request ~request ~parse =
  let queue = Eio.Stream.create 256 in
  let woken, wake = Eio.Promise.create () in
  let aborted = ref false in
  let abort = ref (fun () -> aborted := true) in
  Eio.Fiber.fork ~sw:request.sw_ctx (fun () ->
      (try
         if !aborted then raise Aborted;
         Eio.Switch.run @@ fun sub ->
         (abort :=
            fun () ->
              aborted := true;
              (* The stream may already have finished; a failed switch is fine. *)
              try Eio.Switch.fail sub Aborted with Invalid_argument _ -> ());
         if !aborted then raise Aborted;
         let body = request.issue ~sw:sub in
         let reader = Eio.Buf_read.of_flow body ~max_size:(64 * 1024 * 1024) in
         let read_line () =
           match Eio.Buf_read.line reader with
           | line -> Some line
           | exception End_of_file -> None
         in
         let rec loop () =
           match Sse.Reader.next read_line with
           | None -> Eio.Stream.add queue `Eof
           | Some event -> (
               match parse event with
               | `Item item ->
                   Eio.Stream.add queue (`Item item);
                   loop ()
               | `Terminal item ->
                   Eio.Stream.add queue (`Item item);
                   Eio.Stream.add queue `Eof
               | `Fault fault ->
                   Eio.Stream.add queue (`Fault fault);
                   Eio.Stream.add queue `Eof)
         in
         loop ()
       with
      | Aborted | Eio.Cancel.Cancelled _ -> Eio.Stream.add queue `Eof
      | Stream_handshake_failed error ->
          Eio.Stream.add queue (`Fault error);
          Eio.Stream.add queue `Eof
      | exn ->
          Eio.Stream.add queue (`Fault (unavailable (Printexc.to_string exn)));
          Eio.Stream.add queue `Eof);
      ());
  (queue, woken, wake, abort)

(* Open a stream connection: dial a fresh socket under the stream's sub-switch,
   handshake on it, then hand the pinned client to [issue] for the GET/POST
   that stays open for the stream's life. A handshake failure raises
   {!Stream_handshake_failed}, surfaced by {!stream_request} as the stream's
   terminal fault. The socket dies when the sub-switch is aborted or ends. *)
let stream_issue ctx ~sw issue =
  let socket = ctx.dial ~sw in
  let client = pinned_client socket in
  (match
     client_handshake ~base:ctx.base ~token:ctx.token ~workspace:ctx.workspace
       ~environment:ctx.environment client ~sw
   with
  | Ok () -> ()
  | Error (`Transport message) ->
      raise (Stream_handshake_failed (unavailable message))
  | Error (`Definite error) ->
      raise
        (Stream_handshake_failed
           (unavailable (Format.asprintf "%a" Error.pp error))));
  issue client

(* connect's feed: a GET whose SSE body re-materialises into the pull seam
   {!Mentat_client} wraps. [close] aborts the GET (releasing the daemon seam) and
   wakes a blocked [next] with [Closed]. *)
let remote_feed ctx session ~from =
  let query =
    let base = [ ("session", [ Mentat_session.Id.to_string session ]) ] in
    match from with
    | `Beginning -> ("from", [ "beginning" ]) :: base
    | `Now -> ("from", [ "now" ]) :: base
    | `After position ->
        ("after", [ string_of_int (Mentat_protocol.Position.seq position) ])
        :: base
  in
  let uri = Uri.with_query (Uri.of_string (ctx.base ^ "/feed")) query in
  let headers = Cohttp.Header.of_list (auth_headers ctx.token) in
  let parse (event : Sse.Event.t) =
    match event with
    | { Sse.Event.name = "error"; data; _ } -> (
        match Wire.decode Mentat_protocol.Error.jsont data with
        | Ok error -> `Terminal (Error error)
        | Error _ -> `Fault (unavailable "malformed feed error frame"))
    | { Sse.Event.data; _ } -> (
        match Wire.decode Mentat_protocol.Update.jsont data with
        | Ok update -> `Item (Ok (Mentat_client.Feed.Item update))
        | Error _ -> `Fault (unavailable "malformed feed update frame"))
  in
  let queue, woken, wake, abort =
    stream_request
      ~request:
        {
          sw_ctx = ctx.sw;
          issue =
            (fun ~sw ->
              stream_issue ctx ~sw (fun client ->
                  let _response, body =
                    Cohttp_eio.Client.get client ~sw ~headers uri
                  in
                  body));
        }
      ~parse
  in
  let closed = ref false in
  let next () =
    if !closed then Ok Mentat_client.Feed.Closed
    else
      Eio.Fiber.first
        (fun () ->
          match Eio.Stream.take queue with
          | `Item outcome -> outcome
          | `Fault error -> Error error
          | `Eof -> Ok Mentat_client.Feed.Closed)
        (fun () ->
          Eio.Promise.await woken;
          Ok Mentat_client.Feed.Closed)
  in
  let close () =
    closed := true;
    ignore (Eio.Promise.try_resolve wake ());
    !abort ()
  in
  Ok { Mentat_client.Feed.next; close }

(* connect's login: the same re-materialisation for the [login_step] stream.
   [cancel] aborts the POST (so the daemon's flow — and any OAuth callback socket
   — is released) and wakes a blocked [next] with the terminal [Cancelled]. *)
let remote_login ctx ~provider ~method_ =
  let body =
    Wire.encode Codecs.login { Codecs.login_provider = provider; method_ }
  in
  let uri = Uri.of_string (ctx.base ^ "/login") in
  let headers =
    Cohttp.Header.of_list
      (("content-type", "application/json") :: auth_headers ctx.token)
  in
  let parse (event : Sse.Event.t) =
    match event with
    | { Sse.Event.name = "error"; data; _ } -> (
        match Wire.decode Mentat_protocol.Error.jsont data with
        | Ok error -> `Terminal (Error error)
        | Error _ -> `Fault (unavailable "malformed login error frame"))
    | { Sse.Event.data; _ } -> (
        match Wire.decode Flow_codec.login_step data with
        | Ok
            ((Mentat_client.Login.Saved _ | Mentat_client.Login.Cancelled) as
             step) ->
            `Terminal (Ok step)
        | Ok step -> `Item (Ok step)
        | Error _ -> `Fault (unavailable "malformed login step frame"))
  in
  let queue, woken, wake, abort =
    stream_request
      ~request:
        {
          sw_ctx = ctx.sw;
          issue =
            (fun ~sw ->
              stream_issue ctx ~sw (fun client ->
                  let _response, response_body =
                    Cohttp_eio.Client.post client ~sw ~headers
                      ~body:(Cohttp_eio.Body.of_string body)
                      uri
                  in
                  response_body));
        }
      ~parse
  in
  let terminal = ref None in
  let next () =
    match !terminal with
    | Some result -> result
    | None ->
        let result =
          Eio.Fiber.first
            (fun () ->
              match Eio.Stream.take queue with
              | `Item outcome -> outcome
              | `Fault error -> Error error
              | `Eof -> Ok Mentat_client.Login.Cancelled)
            (fun () ->
              Eio.Promise.await woken;
              Ok Mentat_client.Login.Cancelled)
        in
        (match result with
        | Ok (Mentat_client.Login.Saved _ | Mentat_client.Login.Cancelled)
        | Error _ ->
            terminal := Some result
        | Ok (Mentat_client.Login.Progress _) -> ());
        result
  in
  let cancel () =
    (match !terminal with
    | None -> terminal := Some (Ok Mentat_client.Login.Cancelled)
    | Some _ -> ());
    ignore (Eio.Promise.try_resolve wake ());
    !abort ()
  in
  Ok { Mentat_client.Login.next; cancel }

(* connect's up-front verification handshake, on a throwaway connection: it fails
   fast on a version mismatch or a wrong-checkout binding before returning the
   driver. Each subsequent driver-field call re-handshakes on its own
   connection, so this connection carries only the probe. *)
let verify_binding ctx =
  Eio.Switch.run @@ fun sub ->
  match ctx.dial ~sw:sub with
  | exception (Eio.Cancel.Cancelled _ as raised) -> raise raised
  | exception exn -> Error (Error.Transport (Printexc.to_string exn))
  | socket -> (
      let client = pinned_client socket in
      match
        client_handshake ~base:ctx.base ~token:ctx.token
          ~workspace:ctx.workspace ~environment:ctx.environment client ~sw:sub
      with
      | Ok () -> Ok ()
      | Error (`Transport message) -> Error (Error.Transport message)
      | Error (`Definite error) -> Error error)

let build_driver ctx : Mentat_client.Driver.t =
  let session : Mentat_client.Driver.Session.t =
    {
      Mentat_client.Driver.Session.submit =
        (fun command ->
          (* session.submit is By_value at the row level; only its two duplicate
             variants escalate — the single named exception, consulted here and by
             the dispatcher so they cannot drift. *)
          let request_id =
            if Endpoint.submit_variant_requires_request_id command then
              Some (mint_request_id ())
            else None
          in
          call ctx ?request_id Endpoint.submit command);
      follow = (fun session ~from -> remote_feed ctx session ~from);
      answer_unattended =
        (fun ~session ~decision ->
          call ctx Endpoint.answer_unattended
            { Codecs.au_session = session; au_decision = decision });
      possibly_mutating =
        (fun ~session ->
          match call ctx Endpoint.possibly_mutating { Codecs.session } with
          | Ok value -> value
          | Error _ -> false);
      (* Remote fault visibility has a settled endpoint shape: a
         [possibly_mutating] mirror — a session request, a
         [Jsont.option Mentat_diagnostic.jsont] response, and an [Error -> None]
         stub like the one above — adopted at the remote-attach milestone. It is
         its own endpoint, not a pull over the feed: a fault is a process-local
         phase, not a journal-derivable [Fact], so the pull-query ruling stands
         and a fault pulse was rejected. Until a remote client attaches, a remote
         cone reports no fault. *)
      faulted = (fun ~session:_ -> None);
      fork =
        (fun ~session ~into ->
          call ctx Endpoint.fork
            { Codecs.fork_session = session; fork_into = into });
      rewind =
        (fun ~session ~into ~anchor ->
          call ctx Endpoint.rewind
            { Codecs.rw_session = session; rw_into = into; rw_anchor = anchor });
      compact =
        (fun ~session ~turn ->
          call ctx Endpoint.compact
            { Codecs.compact_session = session; compact_turn = turn });
      pending_decision =
        (fun session -> call ctx Endpoint.pending_decision { Codecs.session });
      change_diff =
        (fun ~session ~change ->
          call ctx Endpoint.change_diff
            { Codecs.cd_session = session; cd_change = change });
      tail =
        (fun ?n session ->
          call ctx Endpoint.tail { Codecs.tail_session = session; tail_n = n });
      page =
        (fun ?n session ~before ->
          call ctx Endpoint.page
            { Codecs.page_session = session; page_n = n; page_before = before });
      (* [running_processes] (a sibling's background-process cone) has no
         descriptor row yet, so it stays unavailable over the wire until its
         feature settles. *)
      running_processes =
        (fun _ ->
          Error
            (unavailable
               "session.running_processes is not yet served over the wire"));
      revert =
        (fun ~session ~scope ->
          call ctx Endpoint.revert
            { Codecs.rv_session = session; rv_scope = scope });
      (* Undo is an in-process, reversible-until-submit orchestration; the wire
         undo command (a Selection-carrying endpoint) is a named future (RFC
         0017), so a remote client is told it is unavailable rather than served a
         half-orchestration. *)
      undo =
        (fun ~session:_ ~op:_ ->
          Error (unavailable "session.undo is only available in-process"));
      export = (fun ~session -> call ctx Endpoint.export { Codecs.session });
    }
  in
  let accounts : Mentat_client.Driver.Accounts.t =
    {
      Mentat_client.Driver.Accounts.login =
        (fun ~provider ~method_ -> remote_login ctx ~provider ~method_);
      save_api_key =
        (fun ~provider ~key ->
          call ctx Endpoint.save_api_key { Codecs.key_provider = provider; key });
      logout =
        (fun ?(revoke = false) provider ->
          call ctx Endpoint.logout { Codecs.logout_provider = provider; revoke });
      account_readiness = (fun () -> call ctx Endpoint.account_readiness ());
      model_readiness =
        (fun ?(refresh = false) () ->
          call ctx Endpoint.model_readiness { Codecs.refresh });
    }
  in
  let settings : Mentat_client.Driver.Settings.t =
    {
      Mentat_client.Driver.Settings.set_model =
        (fun ~session ?reasoning_effort selector ->
          call ctx Endpoint.set_model
            {
              Codecs.sm_session = session;
              sm_effort = reasoning_effort;
              sm_selector = selector;
            });
      set_permission_review =
        (fun ~session review ->
          call ctx Endpoint.set_permission_review
            { Codecs.spr_session = session; spr_review = review });
      configuration = (fun () -> call ctx Endpoint.configuration ());
      set_default_model =
        (fun ?reasoning_effort selector ->
          call ctx Endpoint.set_default_model
            { Codecs.sdm_effort = reasoning_effort; sdm_selector = selector });
      set_ui_theme =
        (fun ~theme ->
          call ctx Endpoint.set_ui_theme { Codecs.sut_theme = theme });
    }
  in
  let lifecycle : Mentat_client.Driver.Lifecycle.t =
    {
      Mentat_client.Driver.Lifecycle.create =
        (fun ~id ~title ->
          call ctx Endpoint.create { Codecs.create_id = id; title });
      rename =
        (fun ~session ~title ->
          call ctx Endpoint.rename
            { Codecs.rename_session = session; rename_title = title });
      archive = (fun ~session -> call ctx Endpoint.archive { Codecs.session });
      restore = (fun ~session -> call ctx Endpoint.restore { Codecs.session });
      delete = (fun ~session -> call ctx Endpoint.delete { Codecs.session });
      sessions = (fun ~listing -> call ctx Endpoint.sessions listing);
      session = (fun id -> call ctx Endpoint.session { Codecs.session = id });
    }
  in
  let review : Mentat_client.Driver.Review.t =
    {
      Mentat_client.Driver.Review.apply =
        (fun command -> call ctx Endpoint.review_apply command);
      state = (fun ~scope -> call ctx Endpoint.review_state scope);
      diff = (fun ~path -> call ctx Endpoint.review_diff path);
      crs = (fun () -> call ctx Endpoint.review_crs ());
      (* review.compose is Requires_request_id at the row level, so [call] mints
         and retries its id — no per-call minting here. *)
      compose = (fun edit -> call ctx Endpoint.review_compose edit);
    }
  in
  let workspace : Mentat_client.Driver.Workspace.t =
    {
      Mentat_client.Driver.Workspace.glance =
        (fun () -> call ctx Endpoint.glance ());
    }
  in
  {
    Mentat_client.Driver.session;
    accounts;
    settings;
    lifecycle;
    review;
    workspace;
  }

let connect ~sw ~net ~clock:_ ?workspace ?environment bind =
  match make_ctx ~sw ~net ?workspace ?environment bind with
  | Error error -> Error error
  | Ok ctx -> (
      match verify_binding ctx with
      | Error error -> Error error
      | Ok () -> Ok (build_driver ctx))

let endpoint_names = List.map Endpoint.name_of Endpoint.table

let requires_request_id_rows =
  List.filter_map
    (fun (Endpoint.Any descriptor) ->
      match descriptor.Endpoint.idempotency with
      | Endpoint.Requires_request_id -> Some descriptor.Endpoint.name
      | Endpoint.By_domain_id | Endpoint.By_value -> None)
    Endpoint.table

(* Per-row canonical encoders for the wire golden corpus: each decodes a
   representative JSON through the row's own request/response codec and re-encodes
   it canonically, so the corpus can byte-pin a row's request and response shape
   without the test naming or constructing the private [Codecs] value. *)
let endpoint_shapes :
    (string
    * (string -> (string, string) result)
    * (string -> (string, string) result))
    list =
  let canonical : type a. a Jsont.t -> string -> (string, string) result =
   fun codec json ->
    match Jsont_bytesrw.decode_string codec json with
    | Error message -> Error message
    | Ok value -> Jsont_bytesrw.encode_string ~format:Jsont.Indent codec value
  in
  List.map
    (fun (Endpoint.Any descriptor) ->
      ( descriptor.Endpoint.name,
        canonical descriptor.Endpoint.request,
        canonical descriptor.Endpoint.response ))
    Endpoint.table

module Flow_codec = Flow_codec
module Discovery = Discovery
