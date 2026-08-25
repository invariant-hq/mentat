(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The parity harness for [mentat_server] (the Stage-1 milestone).
   [serve] runs over a unix socket in a temp dir against a fake, fully-scripted
   {!Mentat_client.Driver.t} — the O14 fixture pattern the client suite uses to
   pin every law without an engine — and [connect] refills a driver from that
   socket. A wire-filled [Client.t] must behave identically to the in-process
   one: the feed frames are byte-identical, reads return equal values,
   [Last-Event-ID] resume skips nothing, the request-id ledger dedups a
   [Requires_request_id] replay, a [By_value] retry surfaces its state error, the
   handshake refuses a stale [v_max] with 409, [/health] is pre-auth, the unix
   directory is 0700, and a public bind is unconstructable without the triple.

   Committed facts are synthesised from one genuine projected fact reused across
   distinct positions (seq 0..2): [Update.jsont] round-trips shape, not feed
   membership, so this is the exact byte-comparison the parity contract asks
   for. *)

open Windtrap
module Server = Mentat_server
module Client = Mentat_client
module Driver = Client.Driver
module Feed = Client.Feed
module Protocol = Mentat_protocol
module Update = Protocol.Update
module Position = Protocol.Position
module Error = Protocol.Error
module Session = Mentat_session
module Mutation = Mentat_mutation
module Llm = Mentat_llm
module Permission = Mentat_permission
module Sandbox = Mentat_sandbox
module Provider = Mentat_provider
module Workspace = Mentat_workspace

let ok = function
  | Ok v -> v
  | Error e -> failf "unexpected error: %a" Error.pp e

(* Custom /commands are not exercised here; these responders are inert no-ops,
   present only to satisfy [Client.make]'s required arguments. *)
let no_user_commands () = Ok []
let no_expand_command ~name:_ ~arguments:_ = Ok []

let no_attach ~session:_ _source =
  Error
    (Mentat_protocol.Attach.Error.Unavailable
       (Mentat_diagnostic.of_text "attach not wired in this test"))

let make_client driver =
  Client.make ~user_commands:no_user_commands ~expand_command:no_expand_command
    ~attach:no_attach driver

let sid s = Session.Id.of_string s
let tid s = Session.Turn.Id.of_string s
let error_t = Testable.make ~pp:Error.pp ~equal:Error.equal

let contains_substring needle haystack =
  let ln = String.length needle and lh = String.length haystack in
  let rec at i =
    i + ln <= lh
    && (String.equal (String.sub haystack i ln) needle || at (i + 1))
  in
  ln = 0 || at 0

let enc : type a. a Jsont.t -> a -> string =
 fun codec value ->
  match Jsont_bytesrw.encode_string codec value with
  | Ok text -> text
  | Error message -> failf "encode: %s" message

(* One genuine committed fact, harvested from a one-turn projection (the client
   suite's technique), reused across three positions. *)
let base_fact =
  let model =
    Llm.Model.make
      ~provider:(Llm.Provider.make "openai")
      ~api:(Llm.Model.Api.make "responses")
      ~id:"gpt-5"
  in
  let contract =
    Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
      ~declarations:[] ~policy:Permission.Policy.default
      ~review:Permission.Review_behavior.Enforce
      ~sandbox:(Sandbox.identity Sandbox.direct)
      ()
  in
  let turn =
    Session.Turn.make ~id:(tid "turn-1") ~origin:Session.Turn.Origin.User
      ~input:(Session.Turn.Input.user_text "hello")
      ~max_steps:8 ~contract ()
  in
  let metadata =
    Session.Metadata.make
      ~cwd:(Lpath.Abs.of_string_exn "/workspace")
      ~created_at:(Session.Time.of_unix_ms 1L)
      ~updated_at:(Session.Time.of_unix_ms 2L)
      ()
  in
  let session =
    match
      Session.make ~id:(sid "session-1") ~metadata
        ~events:[ Session.Event.turn_started turn ]
    with
    | Ok s -> s
    | Error e -> failf "session build: %a" Session.Error.pp e
  in
  let mutation =
    match Mutation.State.of_events [] with
    | Ok m -> m
    | Error _ -> fail "mutation build"
  in
  match Protocol.Projection.all ~session ~mutation with
  | (_, fact) :: _ -> fact
  | [] -> fail "projection produced no facts"

let session_id = sid "session-1"

let updates =
  List.init 3 (fun seq ->
      Update.Committed
        { position = Position.make ~session:session_id ~seq; fact = base_fact })

(* A committed update whose JSON exceeds 8KB — the exact class the transport
   rewrite fixed (the old hand-rolled chunk writer scrambled >8KB frames
   nondeterministically: same length, valid JSON, wrong bytes). *)
let large_update =
  let model =
    Llm.Model.make
      ~provider:(Llm.Provider.make "openai")
      ~api:(Llm.Model.Api.make "responses")
      ~id:"gpt-5"
  in
  let contract =
    Session.Contract.make ~mode:Session.Contract.Mode.Build ~model
      ~declarations:[] ~policy:Permission.Policy.default
      ~review:Permission.Review_behavior.Enforce
      ~sandbox:(Sandbox.identity Sandbox.direct)
      ()
  in
  let turn =
    Session.Turn.make ~id:(tid "big") ~origin:Session.Turn.Origin.User
      ~input:(Session.Turn.Input.user_text (String.make 12000 'x'))
      ~max_steps:8 ~contract ()
  in
  Update.Committed
    {
      position = Position.make ~session:session_id ~seq:0;
      fact = Protocol.Fact.Turn_started turn;
    }

(* A synchronous seam popping scripted updates, then parking until [close]. *)
let scripted_seam results : Feed.seam =
  let queue = Queue.create () in
  List.iter (fun r -> Queue.push r queue) results;
  let condition = Eio.Condition.create () in
  let closed = ref false in
  let next () =
    Eio.Condition.loop_no_mutex condition (fun () ->
        match Queue.take_opt queue with
        | Some update -> Some (Ok (Feed.Item update))
        | None -> if !closed then Some (Ok Feed.Closed) else None)
  in
  let close () =
    closed := true;
    Eio.Condition.broadcast condition
  in
  { Feed.next; close }

(* [from]-honouring follow: deliver only the committed suffix a resume asks for,
   so a [Last-Event-ID] resume can be shown to skip nothing and re-drop nothing. *)
let follow_suffix _id ~from =
  let start =
    match from with
    | `Beginning -> 0
    | `Now -> List.length updates
    | `After position -> Position.seq position + 1
  in
  let suffix = List.filteri (fun i _ -> i >= start) updates in
  Ok (scripted_seam suffix)

let unavailable () =
  Error (Error.Unavailable (Mentat_diagnostic.of_text "not scripted"))

let default_session : Driver.Session.t =
  {
    Driver.Session.submit = (fun _ -> unavailable ());
    follow = follow_suffix;
    answer_unattended = (fun ~session:_ ~decision:_ -> unavailable ());
    possibly_mutating = (fun ~session:_ -> false);
    faulted = (fun ~session:_ -> None);
    fork = (fun ~session:_ ~into:_ -> unavailable ());
    rewind = (fun ~session:_ ~into:_ ~anchor:_ -> unavailable ());
    compact = (fun ~session:_ ~turn:_ -> unavailable ());
    pending_decision = (fun _ -> Ok None);
    change_diff = (fun ~session:_ ~change:_ -> Ok []);
    tail = (fun ?n:_ _ -> unavailable ());
    page = (fun ?n:_ _ ~before:_ -> unavailable ());
    running_processes = (fun _ -> unavailable ());
    revert = (fun ~session:_ ~scope:_ -> unavailable ());
    undo = (fun ~session:_ ~op:_ -> unavailable ());
    export = (fun ~session:_ -> unavailable ());
  }

let discovery =
  Provider.Account.Discovery.Known
    (Provider.Account.missing ~provider:(Llm.Provider.make "openai"))

let default_accounts : Driver.Accounts.t =
  {
    Driver.Accounts.login = (fun ~provider:_ ~method_:_ -> unavailable ());
    save_api_key = (fun ~provider:_ ~key:_ -> unavailable ());
    logout = (fun ?revoke:_ _ -> unavailable ());
    account_readiness = (fun () -> Ok [ discovery ]);
    model_readiness = (fun ?refresh:_ () -> unavailable ());
  }

let default_settings : Driver.Settings.t =
  {
    Driver.Settings.set_model =
      (fun ~session:_ ?reasoning_effort:_ _ -> unavailable ());
    set_permission_review = (fun ~session:_ _ -> unavailable ());
    configuration = (fun () -> unavailable ());
    set_default_model = (fun ?reasoning_effort:_ _ -> unavailable ());
    set_ui_theme = (fun ~theme:_ -> unavailable ());
  }

let a_diagnostic = Mentat_diagnostic.make ~context:"sessions/bad" "bad entry"

let default_lifecycle : Driver.Lifecycle.t =
  {
    Driver.Lifecycle.create = (fun ~id:_ ~title:_ -> Ok ());
    rename = (fun ~session:_ ~title:_ -> Ok ());
    archive = (fun ~session:_ -> Ok ());
    restore = (fun ~session:_ -> Ok ());
    delete = (fun ~session:_ -> Ok ());
    sessions = (fun ~listing:_ -> Ok ([], [ a_diagnostic ]));
    session = (fun _ -> unavailable ());
  }

let default_review : Driver.Review.t =
  {
    Driver.Review.apply = (fun _ -> Ok ());
    state = (fun ~scope:_ -> unavailable ());
    diff = (fun ~path:_ -> Ok None);
    crs = (fun () -> Ok []);
    compose = (fun _ -> Ok ());
  }

let default_workspace : Driver.Workspace.t =
  {
    Driver.Workspace.glance = (fun () -> Ok (None, Workspace.Health.Off Workspace.Health.Off.Disabled));
    dune = (fun () -> Ok (Workspace.Health.Off Workspace.Health.Off.Disabled));
  }

let make_driver ?(session = default_session) ?(accounts = default_accounts)
    ?(settings = default_settings) ?(lifecycle = default_lifecycle)
    ?(review = default_review) ?(workspace = default_workspace) () : Driver.t =
  { Driver.session; accounts; settings; lifecycle; review; workspace }

(* Socket harness: [serve] a driver over a unix socket in a fresh temp dir and
   run [f] with a connected remote [Client.t], the raw socket dir, and the caps. *)
let socket_dir () =
  let path =
    Printf.sprintf "/tmp/mtsrv-%d-%06x" (Unix.getpid ()) (Random.int 0xFFFFFF)
  in
  Lpath.Abs.of_string_exn path

(* A constant [driver_for] binding one scripted driver to the fixed workspace,
   the mechanical Stage-1 wrapper (the single-driver harness): it echoes the
   bound root so [connect ~workspace:"/workspace"]'s echo-verify passes, and its
   [on_close] is inert. *)
let const_driver_for ?(on_close = fun () -> ()) driver ~workspace:_
    ~environment:_ =
  Ok { Server.workspace = Some "/workspace"; driver; on_close }

let with_server ?ledger_cap ?heartbeat_s ~driver f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let dir = socket_dir () in
  let bind = Server.Bind.unix ~dir in
  let listener = Server.listen ~sw ~net bind in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try
         Server.serve ~sw ~clock ?ledger_cap ?heartbeat_s
           ~driver_for:(const_driver_for driver) listener
       with Eio.Cancel.Cancelled _ -> ());
      `Stop_daemon);
  let body () =
    let remote =
      match Server.connect ~sw ~net ~clock ~workspace:"/workspace" bind with
      | Ok driver -> make_client driver
      | Error error -> failf "connect: %a" Server.Error.pp error
    in
    f ~env ~net ~sw ~dir ~bind ~remote;
    Ok ()
  in
  match Eio.Time.with_timeout clock 30.0 body with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: the harness exceeded 30s"

(* Raw HTTP over the unix socket, for the pre-handshake and idempotency paths a
   typed [connect] cannot express. *)
let raw_client ~net ~dir =
  let path = Filename.concat (Lpath.Abs.to_string dir) "mentat.sock" in
  Cohttp_eio.Client.make_generic (fun ~sw _uri ->
      (Eio.Net.connect ~sw net (`Unix path)
        :> [ `Close | Eio.Flow.two_way_ty ] Eio.Resource.t))

let raw_read body =
  Eio.Buf_read.take_all (Eio.Buf_read.of_flow body ~max_size:1_000_000)

let raw_post client ~sw path body =
  let response, rbody =
    Cohttp_eio.Client.post client ~sw
      ~headers:(Cohttp.Header.of_list [ ("content-type", "application/json") ])
      ~body:(Cohttp_eio.Body.of_string body)
      (Uri.of_string ("http://mentat" ^ path))
  in
  (Cohttp.Code.code_of_status (Cohttp.Response.status response), raw_read rbody)

let raw_get client ~sw path =
  let response, rbody =
    Cohttp_eio.Client.get client ~sw (Uri.of_string ("http://mentat" ^ path))
  in
  (Cohttp.Code.code_of_status (Cohttp.Response.status response), raw_read rbody)

(* Under the per-connection handshake, a non-handshake request must ride a
   connection already handshaked. [pinned] dials one socket and routes cohttp
   through it, so a handshake and the request that follows share the connection. *)
let pinned ~net ~dir ~sw =
  let path = Filename.concat (Lpath.Abs.to_string dir) "mentat.sock" in
  let socket =
    (Eio.Net.connect ~sw net (`Unix path)
      :> [ `Close | Eio.Flow.two_way_ty ] Eio.Resource.t)
  in
  Cohttp_eio.Client.make_generic (fun ~sw:_ _uri -> socket)

let handshake_body ?(workspace = "/workspace") () =
  Printf.sprintf {|{"v_max":1,"workspace":%S}|} workspace

(* A raw single-shot POST that first handshakes on its own fresh connection — the
   raw analogue of the product single-shot. The ledger is daemon-global, so
   a lost-ack replay reuses the same request-id across distinct attached
   connections. *)
let attached_post ~net ~dir path body =
  Eio.Switch.run @@ fun conn_sw ->
  let client = pinned ~net ~dir ~sw:conn_sw in
  let hstatus, _ =
    raw_post client ~sw:conn_sw "/handshake" (handshake_body ())
  in
  if hstatus <> 200 then failf "attached handshake failed with %d" hstatus;
  raw_post client ~sw:conn_sw path body

(* A raw SSE GET that handshakes first on the same connection, returning the live
   body flow (kept open under [sw]). *)
let attached_feed ~net ~dir ~sw path =
  let client = pinned ~net ~dir ~sw in
  let hstatus, _ = raw_post client ~sw "/handshake" (handshake_body ()) in
  if hstatus <> 200 then failf "attached feed handshake failed with %d" hstatus;
  let _response, body =
    Cohttp_eio.Client.get client ~sw (Uri.of_string ("http://mentat" ^ path))
  in
  body

(* Browser-edge harness ({!Server.Web}). A loopback listener over an ephemeral
   port serves a stub rendering surface; [f] gets the port and the daemon token,
   and dials raw HTTP over TCP so the cookie exchange, the Origin/Host checks, the
   CSP header, and the SSE framing can be observed directly. *)
let stub_handler : Server.Web.handler =
  {
    Server.Web.respond =
      (fun ~meth:_ ~path:_ ~query:_ ~body:_ ->
        {
          Server.Web.status = 200;
          headers = [ ("content-type", "text/html; charset=utf-8") ];
          body = "<!doctype html><html><body>ok</body></html>";
        });
    stream =
      (fun ~sw:_ ~session:_ ~from:_ ~emit ->
        (* One committed frame (carries its [id:]) then one droppable live-region
           morph (no [id:]), then the producer ends. *)
        emit
          {
            Server.Web.id = Some 0;
            html = "<div data-swap=\"append\">fact</div>";
          };
        emit { Server.Web.id = None; html = "<div id=\"live\"></div>" };
        Ok ());
  }

let with_web_server ?(handler = stub_handler) ?heartbeat_s
    ?(on_rotate = fun (_ : Server.Token.t) -> ()) f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let token = Server.Token.generate () in
  let listener =
    Server.listen ~sw ~net (Server.Bind.loopback ~port:None ~token)
  in
  let port =
    match Server.port listener with Some p -> p | None -> fail "no bound port"
  in
  let origins =
    List.map Server.Origin.of_string
      [
        Printf.sprintf "http://127.0.0.1:%d" port;
        Printf.sprintf "http://localhost:%d" port;
      ]
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try
         Server.Web.serve ~sw ~clock ?heartbeat_s ~token ~on_rotate ~origins
           handler listener
       with Eio.Cancel.Cancelled _ -> ());
      `Stop_daemon);
  let body () =
    f ~net ~sw ~port ~token;
    Ok ()
  in
  match Eio.Time.with_timeout clock 30.0 body with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: the web harness exceeded 30s"

(* A fresh TCP connection to the loopback port. The URI host is irrelevant to the
   connection (used only to populate the request's [Host] line), so a foreign
   [host] simulates the DNS-rebinding case while still dialing the real port. *)
let web_client ~net ~port =
  Cohttp_eio.Client.make_generic (fun ~sw _uri ->
      (Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
        :> [ `Close | Eio.Flow.two_way_ty ] Eio.Resource.t))

let web_get ~net ~port ~sw ?(headers = []) ?(host = "127.0.0.1") path =
  let client = web_client ~net ~port in
  let uri = Uri.of_string (Printf.sprintf "http://%s:%d%s" host port path) in
  let response, rbody =
    Cohttp_eio.Client.get client ~sw
      ~headers:(Cohttp.Header.of_list headers)
      uri
  in
  ( Cohttp.Code.code_of_status (Cohttp.Response.status response),
    Cohttp.Response.headers response,
    raw_read rbody )

let web_post ~net ~port ~sw ?(headers = []) ?(host = "127.0.0.1") ?(body = "")
    path =
  let client = web_client ~net ~port in
  let uri = Uri.of_string (Printf.sprintf "http://%s:%d%s" host port path) in
  let response, rbody =
    Cohttp_eio.Client.post client ~sw
      ~headers:(Cohttp.Header.of_list headers)
      ~body:(Cohttp_eio.Body.of_string body)
      uri
  in
  ( Cohttp.Code.code_of_status (Cohttp.Response.status response),
    Cohttp.Response.headers response,
    raw_read rbody )

(* Run the token→cookie exchange and return the [mentat_session] cookie value the
   daemon minted, for the authenticated requests that follow. *)
let cookie_of_set_cookie set_cookie =
  match String.index_opt set_cookie '=' with
  | None -> fail "malformed set-cookie"
  | Some i -> (
      let rest =
        String.sub set_cookie (i + 1) (String.length set_cookie - i - 1)
      in
      match String.index_opt rest ';' with
      | Some j -> String.sub rest 0 j
      | None -> rest)

let exchange ~net ~port ~sw ~token =
  let status, headers, _ =
    web_get ~net ~port ~sw
      (Printf.sprintf "/?t=%s" (Server.Token.to_string token))
  in
  if status <> 303 then failf "exchange expected 303, got %d" status;
  match Cohttp.Header.get headers "set-cookie" with
  | Some sc -> cookie_of_set_cookie sc
  | None -> fail "exchange did not set a cookie"

let cookie_header cookie = [ ("cookie", "mentat_session=" ^ cookie) ]

(* Tests. *)

let read_item feed =
  match Feed.next feed with
  | Ok (Feed.Item update) -> update
  | Ok Feed.Closed -> fail "expected an item, got Closed"
  | Error e -> failf "expected an item, got %a" Error.pp e

let feed_group =
  group "feed parity"
    [
      test "the wire feed frames are byte-identical to the in-process fill"
        (fun () ->
          with_server ~driver:(make_driver ())
            (fun ~env:_ ~net:_ ~sw ~dir:_ ~bind:_ ~remote ->
              let in_process = make_client (make_driver ()) in
              let follow client =
                ok
                  (Client.follow_session ~sw client session_id ~from:`Beginning)
              in
              let local = follow in_process and wire = follow remote in
              List.iter
                (fun expected ->
                  let l = read_item local and w = read_item wire in
                  equal string
                    ~msg:"in-process and wire feed frames match byte-for-byte"
                    (enc Update.jsont l) (enc Update.jsont w);
                  equal string ~msg:"and both are the scripted committed fact"
                    (enc Update.jsont expected)
                    (enc Update.jsont w))
                updates;
              Feed.close local;
              Feed.close wire));
      test
        "Last-Event-ID resume delivers the exact committed suffix (property 4)"
        (fun () ->
          with_server ~driver:(make_driver ())
            (fun ~env:_ ~net:_ ~sw ~dir:_ ~bind:_ ~remote ->
              (* Resume strictly after seq 0: the suffix is seq 1..2, no gap and
                 no re-delivery of seq 0. *)
              let resume_after = Position.make ~session:session_id ~seq:0 in
              let feed =
                ok
                  (Client.follow_session ~sw remote session_id
                     ~from:(`After resume_after))
              in
              let first = read_item feed in
              equal string ~msg:"resume skips seq 0, delivers seq 1 first"
                (enc Update.jsont (List.nth updates 1))
                (enc Update.jsont first);
              let second = read_item feed in
              equal string ~msg:"then seq 2, no gap"
                (enc Update.jsont (List.nth updates 2))
                (enc Update.jsont second);
              Feed.close feed));
    ]

let reads_group =
  group "read parity"
    [
      test "each read returns the value the in-process fill returns" (fun () ->
          with_server ~driver:(make_driver ())
            (fun ~env:_ ~net:_ ~sw:_ ~dir:_ ~bind:_ ~remote ->
              let in_process = make_client (make_driver ()) in
              (* possibly_mutating (plain bool). *)
              is_false ~msg:"possibly_mutating crosses as false"
                (Client.possibly_mutating remote ~session:session_id);
              (* pending_decision. *)
              (match Client.pending_decision remote session_id with
              | Ok None -> ()
              | _ -> fail "pending_decision should be Ok None");
              (* account_readiness — compare the two fills byte-for-byte. *)
              let readiness client = ok (Client.account_readiness client) in
              equal string ~msg:"account_readiness matches the in-process fill"
                (enc
                   (Jsont.list Provider.Account.Discovery.jsont)
                   (readiness in_process))
                (enc
                   (Jsont.list Provider.Account.Discovery.jsont)
                   (readiness remote));
              (* workspace_glance. *)
              (match Client.workspace_glance remote with
              | Ok (None, Workspace.Health.Off Workspace.Health.Off.Disabled) -> ()
              | _ -> fail "workspace_glance should be (None, Off Disabled)");
              (* sessions — the partial-diagnostics list crosses whole. *)
              match
                Client.sessions remote
                  {
                    Session.Listing.scope = `All;
                    lifecycles = [ Session.Metadata.Status.Active ];
                    search = Some "needle";
                    limit = Some 5;
                  }
              with
              | Ok ([], [ served ]) ->
                  is_true ~msg:"the corrupt-entry diagnostic crosses whole"
                    (Mentat_diagnostic.equal a_diagnostic served)
              | _ -> fail "sessions should carry the scripted diagnostic"));
      test "a read error crosses the wire unmapped" (fun () ->
          let session =
            {
              default_session with
              Driver.Session.pending_decision =
                (fun _ -> Error (Error.Session_not_found (sid "missing")));
            }
          in
          with_server ~driver:(make_driver ~session ())
            (fun ~env:_ ~net:_ ~sw:_ ~dir:_ ~bind:_ ~remote ->
              match Client.pending_decision remote session_id with
              | Error e ->
                  equal error_t ~msg:"the driver error crosses unchanged"
                    (Error.Session_not_found (sid "missing"))
                    e
              | Ok _ -> fail "expected the scripted error"));
    ]

let commands_group =
  group "commands and idempotency"
    [
      test "submit forwards the exact command" (fun () ->
          let seen = ref None in
          let session =
            {
              default_session with
              Driver.Session.submit =
                (fun command ->
                  seen := Some command;
                  Ok ());
            }
          in
          with_server ~driver:(make_driver ~session ())
            (fun ~env:_ ~net:_ ~sw:_ ~dir:_ ~bind:_ ~remote ->
              ok
                (Client.submit remote
                   (Protocol.Command.clear_queued ~session:session_id));
              match !seen with
              | Some command ->
                  is_true ~msg:"the command reached the serve-side driver"
                    (Session.Id.equal session_id
                       (Protocol.Command.session command))
              | None -> fail "submit never reached the driver"));
      test "a By_value retry surfaces its state error, effect exactly once"
        (fun () ->
          (* Answer_decision guarded: the second answer loses to the first and
             returns Already_resolved. *)
          let calls = ref 0 in
          let decision = Session.Decision.Id.of_string "d1" in
          let session =
            {
              default_session with
              Driver.Session.submit =
                (fun _ ->
                  incr calls;
                  if !calls = 1 then Ok ()
                  else Error (Error.Already_resolved decision));
            }
          in
          with_server ~driver:(make_driver ~session ())
            (fun ~env:_ ~net:_ ~sw:_ ~dir:_ ~bind:_ ~remote ->
              let answer =
                Protocol.Command.answer_decision ~session:session_id ~decision
                  ~answer:
                    (Session.Decision.Answer.Permission
                       { answer = Permission.Answer.deny; message = None })
              in
              ok (Client.submit remote answer);
              match Client.submit remote answer with
              | Error (Error.Already_resolved _) ->
                  equal int ~msg:"the effect ran exactly once" 2 !calls
              | _ -> fail "the retry should surface Already_resolved"));
      test
        "a Queue_next replay dedups with a request-id, duplicates without (the \
         class falsifier)" (fun () ->
          let calls = ref 0 in
          let session =
            {
              default_session with
              Driver.Session.submit =
                (fun _ ->
                  incr calls;
                  Ok ());
            }
          in
          with_server ~driver:(make_driver ~session ())
            (fun ~env:_ ~net ~sw:_ ~dir ~bind:_ ~remote:_ ->
              let command =
                match
                  Protocol.Command.queue_next ~session:session_id
                    ~input:[ Llm.Content.text "again" ]
                with
                | Ok c -> c
                | Error _ -> fail "queue_next build"
              in
              let payload = enc Protocol.Command.jsont command in
              let envelope ?request_id () =
                let id =
                  match request_id with
                  | Some r -> Printf.sprintf {|,"request_id":%S|} r
                  | None -> ""
                in
                Printf.sprintf
                  {|{"v":1%s,"endpoint":"session.submit","payload":%s}|} id
                  payload
              in
              (* With a stable request-id, the second POST is served from the
                 daemon-global ledger — the effect runs once, even though each
                 attached POST rides its own handshaked connection. *)
              let status1, _ =
                attached_post ~net ~dir "/wire" (envelope ~request_id:"r1" ())
              in
              let status2, _ =
                attached_post ~net ~dir "/wire" (envelope ~request_id:"r1" ())
              in
              equal int ~msg:"both id-keyed POSTs return 200" 200 status1;
              equal int ~msg:"both id-keyed POSTs return 200" 200 status2;
              equal int ~msg:"the request-id dedups the replay to one effect" 1
                !calls;
              (* Without a request-id there is no backstop: two effects. *)
              ignore (attached_post ~net ~dir "/wire" (envelope ()));
              ignore (attached_post ~net ~dir "/wire" (envelope ()));
              equal int ~msg:"two id-less replays append two effects" 3 !calls));
    ]

let edge_group =
  group "network edge"
    [
      test "GET /health is pre-auth and content-free" (fun () ->
          with_server ~driver:(make_driver ())
            (fun ~env:_ ~net ~sw ~dir ~bind:_ ~remote:_ ->
              let client = raw_client ~net ~dir in
              let status, body = raw_get client ~sw "/health" in
              equal int ~msg:"health is reachable pre-auth" 200 status;
              equal string ~msg:"health is content-free" "ok" body));
      test "a stale v_max is refused with 409" (fun () ->
          with_server ~driver:(make_driver ())
            (fun ~env:_ ~net ~sw ~dir ~bind:_ ~remote:_ ->
              let client = raw_client ~net ~dir in
              let status, _ =
                raw_post client ~sw "/handshake" {|{"v_max":0}|}
              in
              equal int ~msg:"a below-floor v_max is a 409" 409 status));
      test "the unix directory is created 0700" (fun () ->
          with_server ~driver:(make_driver ())
            (fun ~env:_ ~net:_ ~sw:_ ~dir ~bind:_ ~remote:_ ->
              let stat = Unix.stat (Lpath.Abs.to_string dir) in
              equal int ~msg:"the account-home directory is private 0700" 0o700
                (stat.Unix.st_perm land 0o777)));
      test "a fresh token is 256-bit and constant-time-compared" (fun () ->
          let a = Server.Token.generate () in
          let b = Server.Token.generate () in
          equal int ~msg:"a token is 32 bytes hex-encoded = 64 chars" 64
            (String.length (Server.Token.to_string a));
          is_false ~msg:"two fresh tokens differ" (Server.Token.equal a b);
          is_true ~msg:"a token equals its own re-parse"
            (Server.Token.equal a
               (Server.Token.of_string (Server.Token.to_string a)));
          (* The hand-written constant-time compare over the three cases the
             ruling names (eqaf is not in the lock). *)
          let tok = Server.Token.of_string in
          is_true ~msg:"equal: identical strings compare equal"
            (Server.Token.equal (tok "abcdef") (tok "abcdef"));
          is_false
            ~msg:"unequal, same length: differing content compares unequal"
            (Server.Token.equal (tok "abcdef") (tok "abcxef"));
          is_false ~msg:"unequal length: a prefix never matches its extension"
            (Server.Token.equal (tok "abc") (tok "abcdef")));
      test "a socket path over the sun_path limit is refused up front (#6)"
        (fun () ->
          Eio_main.run @@ fun env ->
          let net = Eio.Stdenv.net env in
          Eio.Switch.run @@ fun sw ->
          let long = "/tmp/" ^ String.make 120 'x' in
          let dir = Lpath.Abs.of_string_exn long in
          match Server.listen ~sw ~net (Server.Bind.unix ~dir) with
          | exception Invalid_argument message ->
              is_true ~msg:"the refusal names the unix-socket limit"
                (contains_substring "unix-socket limit" message)
          | _ -> fail "a too-long socket path must be refused before bind");
    ]

(* [Bind.public] is the sole constructor accepting a non-loopback host, and it
   cannot be built without the TLS × token × origin triple (property 7); that
   guarantee is a compile fact of the type, not a runtime check, and [listen]
   raises {!Server.Unsupported} on it in Stage 1. Both are exercised by the type
   checker admitting this module, not by a runtime test that would need a real
   TLS server configuration. *)

let introspection_group =
  group "descriptor table"
    [
      test
        "the single-shot table covers exactly the landed non-streaming fields"
        (fun () ->
          (* 34 rows: Session 12 (15 fields minus streaming [follow],
             [running_processes], and the in-process-only [undo]), Accounts 4 (5
             minus [login]), Settings 5 (+set_default_model, +set_ui_theme),
             Lifecycle 7, Review 5, Workspace 1. The two streaming endpoints are
             absent. *)
          equal int ~msg:"row count matches the landed cones" 35
            (List.length Server.endpoint_names);
          is_false ~msg:"the feed is not a descriptor row"
            (List.mem "session.follow" Server.endpoint_names);
          is_false ~msg:"login is not a descriptor row"
            (List.mem "accounts.login" Server.endpoint_names));
    ]

(* The wire golden corpus for the two flow codecs. These land in
   [mentat.server], not [mentat.protocol], so they are pinned here — the same
   mechanism as the protocol corpus (canonical indented bytes checked in under
   [wire-corpus/], byte-compared so any drift fails) in the shared directory.
   Regenerate with [WIRE_CORPUS_UPDATE=1] and [WIRE_CORPUS_DIR] set. *)

let corpus_dir =
  (* [WIRE_CORPUS_DIR] overrides for regeneration — it must point at the source
     tree, never [_build]. Unset, default beside the executable: dune
     materializes [wire-corpus/*.json] there as a build dep, so the goldens are
     found under a bare [dune exec] and under the runtest sandbox alike. *)
  match Sys.getenv_opt "WIRE_CORPUS_DIR" with
  | Some dir -> dir
  | None -> Filename.concat (Filename.dirname Sys.executable_name) "wire-corpus"

let corpus_updating =
  match Sys.getenv_opt "WIRE_CORPUS_UPDATE" with
  | Some ("1" | "true") -> true
  | _ -> false

let canonical codec value =
  match Jsont_bytesrw.encode_string ~format:Jsont.Indent codec value with
  | Ok bytes -> bytes ^ "\n"
  | Error message -> failf "canonical encode: %s" message

let corpus_file name = Filename.concat corpus_dir (name ^ ".json")

let write_corpus name contents =
  Out_channel.with_open_bin (corpus_file name) (fun oc ->
      Out_channel.output_string oc contents)

let read_corpus name =
  let path = corpus_file name in
  if Sys.file_exists path then
    In_channel.with_open_bin path In_channel.input_all
  else
    failf
      "wire corpus file %s is missing — regenerate with WIRE_CORPUS_UPDATE=1 \
       and WIRE_CORPUS_DIR=test/unit/wire-corpus"
      path

let login_browser =
  Client.Login.Progress
    (Provider.Auth.Login.Progress.Browser_url
       (Uri.of_string "https://issuer/authorize"))

let login_saved =
  Client.Login.Saved
    (Provider.Account.missing ~provider:(Llm.Provider.make "openai"))

let flow_shapes =
  [
    ( "server.compaction_result.installed",
      canonical Server.Flow_codec.compaction_result Client.Installed );
    ( "server.compaction_result.skipped",
      canonical Server.Flow_codec.compaction_result Client.Skipped );
    ( "server.login_step.progress_browser",
      canonical Server.Flow_codec.login_step login_browser );
    ( "server.login_step.saved",
      canonical Server.Flow_codec.login_step login_saved );
    ( "server.login_step.cancelled",
      canonical Server.Flow_codec.login_step Client.Login.Cancelled );
  ]

(* A round-trip that also pins decode: the canonical bytes decode back to the
   value and re-encode identically. *)
let round_trips codec value =
  match Jsont_bytesrw.decode_string codec (canonical codec value) with
  | Ok decoded -> String.equal (canonical codec decoded) (canonical codec value)
  | Error message -> failf "decode: %s" message

let corpus_group =
  group "wire golden corpus (flow codecs)"
    [
      test "every flow shape encodes byte-for-byte to its stored golden"
        (fun () ->
          if corpus_updating then
            List.iter (fun (name, json) -> write_corpus name json) flow_shapes;
          List.iter
            (fun (name, json) ->
              equal string
                ~msg:(name ^ " drifted; regenerate with WIRE_CORPUS_UPDATE=1")
                (read_corpus name) json)
            flow_shapes);
      test "each flow codec round-trips through decode then encode" (fun () ->
          is_true ~msg:"compaction_result Installed round-trips"
            (round_trips Server.Flow_codec.compaction_result Client.Installed);
          is_true ~msg:"compaction_result Skipped round-trips"
            (round_trips Server.Flow_codec.compaction_result Client.Skipped);
          is_true ~msg:"login_step Progress round-trips"
            (round_trips Server.Flow_codec.login_step login_browser);
          is_true ~msg:"login_step Saved round-trips"
            (round_trips Server.Flow_codec.login_step login_saved);
          is_true ~msg:"login_step Cancelled round-trips"
            (round_trips Server.Flow_codec.login_step Client.Login.Cancelled));
    ]

(* The revert wire vocabulary: [Revert.Scope] (the request
   scope) and [Revert.Outcome] (the response), both mutation-public, pinned here
   because they enter the wire through [session.revert]. [Outcome.Applied]'s
   nested settlement is a mutation type round-tripped in test_mutation, and its
   [applied] tag rides the endpoint parity replay; [set_default_model]'s request
   codec is [mentat.server]-private, so it too is covered e2e by the parity
   harness rather than a standalone golden. *)
let revert_scope_path text =
  Mutation.Revert.Scope.Path
    (Workspace.Path.make
       ~root_key:(Workspace.Root.Key.of_string_exn "root")
       (Lpath.Rel.of_string_exn text))

let revert_vocab_shapes =
  [
    ( "server.revert_scope.latest",
      canonical Mutation.Revert.Scope.jsont Mutation.Revert.Scope.Latest );
    ( "server.revert_scope.change",
      canonical Mutation.Revert.Scope.jsont
        (Mutation.Revert.Scope.Change (Mutation.Change.Id.of_string "chg-1")) );
    ( "server.revert_scope.path",
      canonical Mutation.Revert.Scope.jsont (revert_scope_path "src/a.ml") );
    ( "server.revert_outcome.nothing",
      canonical Mutation.Revert.Outcome.jsont
        Mutation.Revert.Outcome.Nothing_to_revert );
    ( "server.revert_outcome.refused",
      canonical Mutation.Revert.Outcome.jsont
        (Mutation.Revert.Outcome.Refused
           [ "a stale change"; "an unrecorded write" ]) );
  ]

let revert_vocab_group =
  group "wire golden corpus (revert vocabulary)"
    [
      test "every revert wire shape encodes byte-for-byte to its stored golden"
        (fun () ->
          if corpus_updating then
            List.iter
              (fun (name, json) -> write_corpus name json)
              revert_vocab_shapes;
          List.iter
            (fun (name, json) ->
              equal string
                ~msg:(name ^ " drifted; regenerate with WIRE_CORPUS_UPDATE=1")
                (read_corpus name) json)
            revert_vocab_shapes);
    ]

(* The per-row endpoint corpus (dune's sexp_for_digest principle in golden-bytes
   form): every endpoint row's request and response codec byte-pinned, so a shape
   drift in a row's codec — which the parity round-trips and name coverage do not
   catch — trips here. A representative JSON is decoded through the row's own
   codec and re-encoded canonically by {!Server.endpoint_shapes}; owner-type
   shapes reuse an already-pinned owner golden as their representative. *)

(* Rows whose request or response is a complex owner type without a ready
   representative yet; each is named so the coverage check stays exact — a new
   row is a covered representative or an explicit deferral, never a silent gap.
   Their shapes are covered behaviorally by the parity round-trips for now. *)
let endpoint_deferred =
  [
    ("settings.configuration", "response is the full resolved config view");
    ("lifecycle.session", "response is the session view");
    ("workspace.glance", "response carries the workspace health tree");
    ("accounts.save_api_key", "provider request and account response");
    ("accounts.logout", "provider request and logout response");
    ("review.apply", "request is a review command");
    ("review.state", "scope request and review-view response");
    ("review.compose", "request is a CR edit");
  ]

(* A thunk, not an eager binding: the [read_corpus] calls below would otherwise
   run at module init, so a single missing golden would abort the whole
   executable before any test ran. Forced inside the two test bodies, a missing
   file fails only the endpoint-corpus group. *)
let endpoint_reps () =
  let session_only = {|{"session":"s1"}|} in
  let ok_unit = {|{}|} in
  [
    ("session.submit", read_corpus "command.interrupt", ok_unit);
    ("session.answer_unattended", {|{"session":"s1","decision":"d1"}|}, ok_unit);
    ("session.possibly_mutating", session_only, {|true|});
    ("session.fork", {|{"session":"s1","into":"s2"}|}, ok_unit);
    ( "session.rewind",
      {|{"session":"s1","into":"s2","anchor":{"turn":"t1","edge":"before"}}|},
      ok_unit );
    ( "session.compact",
      {|{"session":"s1","turn":"t1"}|},
      read_corpus "server.compaction_result.installed" );
    ("session.pending_decision", session_only, {|null|});
    ("session.change_diff", {|{"session":"s1","change":"c1"}|}, {|[]|});
    ("session.tail", session_only, read_corpus "transcript.tail");
    ( "session.page",
      {|{"session":"s1","before":null}|},
      read_corpus "transcript.page" );
    ( "session.revert",
      {|{"session":"s1","scope":{"type":"latest"}}|},
      {|{"type":"nothing_to_revert"}|} );
    ("session.export", session_only, {|"mentat.session bundle bytes"|});
    ("accounts.account_readiness", {|{}|}, {|[]|});
    (* A hand-written route — one provider, one Known discovery, one model — so
       the golden pins the nested provider, discovery, and model wire shapes; the
       readiness fields are derived from those on decode and never encoded. *)
    ( "accounts.model_readiness",
      {|{}|},
      {|{"providers":[{"provider":"openai","display_name":"OpenAI","auth_required":true,"discovery":{"type":"known","account":{"provider":"openai","status":"missing"}},"models":[{"model":{"provider":"openai","api":"openai","id":"gpt-5"},"status":"stable"}]}]}|}
    );
    ( "settings.set_model",
      {|{"session":"s1","selector":"openai/gpt-5"}|},
      ok_unit );
    ( "settings.set_permission_review",
      {|{"session":"s1","review":"enforce"}|},
      ok_unit );
    ("settings.set_default_model", {|{"selector":"openai/gpt-5"}|}, ok_unit);
    ("settings.set_ui_theme", {|{"theme":"mentat-dark"}|}, ok_unit);
    ("lifecycle.create", {|{"id":"s1"}|}, ok_unit);
    ("lifecycle.rename", {|{"session":"s1","title":"renamed"}|}, ok_unit);
    ("lifecycle.archive", session_only, ok_unit);
    ("lifecycle.restore", session_only, ok_unit);
    ("lifecycle.delete", session_only, ok_unit);
    ( "lifecycle.sessions",
      {|{"scope":"cwd","lifecycles":[]}|},
      {|{"summaries":[],"diagnostics":[]}|} );
    ("review.crs", {|{}|}, {|[]|});
    (* A Live/Theirs/Settled failing value, so the live case's every member
       is pinned; the other case tags are covered by the codec's own suite. *)
    ( "workspace.dune",
      {|{}|},
      {|{"state":"live","ours":false,"pid":4242,"phase":"settled","errors":2,"warnings":1,"lint":3}|}
    );
    ("review.diff", {|"lib/a.ml"|}, {|null|});
  ]

let endpoint_corpus_group =
  group "wire golden corpus (endpoint rows)"
    [
      test
        "every endpoint row is a pinned representative or an explicit deferral"
        (fun () ->
          let endpoint_reps = endpoint_reps () in
          List.iter
            (fun (name, _, _) ->
              if
                (not
                   (List.exists
                      (fun (n, _, _) -> String.equal n name)
                      endpoint_reps))
                && not
                     (List.exists
                        (fun (n, _) -> String.equal n name)
                        endpoint_deferred)
              then
                failf
                  "endpoint row %s has neither a corpus representative nor a \
                   deferral"
                  name)
            Server.endpoint_shapes);
      test
        "every covered endpoint row's request and response codec pins its shape"
        (fun () ->
          let endpoint_reps = endpoint_reps () in
          List.iter
            (fun (name, req_json, resp_json) ->
              match
                List.find_opt
                  (fun (n, _, _) -> String.equal n name)
                  Server.endpoint_shapes
              with
              | None -> failf "no such endpoint row: %s" name
              | Some (_, canon_req, canon_resp) ->
                  let req =
                    match canon_req req_json with
                    | Ok b -> b
                    | Error e -> failf "%s request does not decode: %s" name e
                  in
                  let resp =
                    match canon_resp resp_json with
                    | Ok b -> b
                    | Error e -> failf "%s response does not decode: %s" name e
                  in
                  if corpus_updating then begin
                    write_corpus ("endpoint." ^ name ^ ".req") req;
                    write_corpus ("endpoint." ^ name ^ ".resp") resp
                  end;
                  equal string
                    ~msg:
                      (name
                     ^ ".req drifted; regenerate with WIRE_CORPUS_UPDATE=1")
                    (read_corpus ("endpoint." ^ name ^ ".req"))
                    req;
                  equal string
                    ~msg:
                      (name
                     ^ ".resp drifted; regenerate with WIRE_CORPUS_UPDATE=1")
                    (read_corpus ("endpoint." ^ name ^ ".resp"))
                    resp)
            endpoint_reps);
    ]

(* ---- Live-engine integration harness ----

   The scripted harness above is the exact filler-swap proof. This one
   is the integration proof: serve a driver whose Session cone is a REAL engine
   over a REAL hub, driven by a scripted fake provider, and prove the properties
   a scripted seam cannot — a full turn streaming over the wire, Last-Event-ID
   resume against the live hub, tail/page over real journal state, heartbeats
   during a provider stall, and a slow reader losing nothing.

   The engine runs over test_agent's proven in-memory [Ports.STORE] fixture (the
   only lib-level way to a [Ports.STORE]; [bin/store_adapter] is executable-
   private and not linkable). The store backend is orthogonal to every property
   here — the engine, the hub, turns, tail/page, and positioned resume behave
   identically over an in-memory or a disk journal; only durable persistence
   differs, which none of these properties exercise. *)

module Agent = Mentat_agent
module Ports = Mentat_agent.Ports
module Catalog = Mentat_agent_step.Catalog

let all_verbs =
  Catalog.Verb.
    [
      Todo_write;
      Update_goal;
      Ask_user;
      Propose_plan;
      Spawn;
      Wait;
      Send_message;
      Follow_up;
    ]

let engine_model =
  Llm.Model.make
    ~provider:(Llm.Provider.make "openai")
    ~api:(Llm.Model.Api.make "responses")
    ~id:"gpt-5"

let engine_cwd = Lpath.Abs.of_string_exn "/workspace"

let plain_response text =
  Llm.Response.make ~model:engine_model ~stop:Llm.Response.Stop.end_turn
    (Llm.Message.Assistant.text text)

(* An in-memory Ports.STORE (test_agent's fixture, minus its fault hooks). *)
type store_state = {
  sessions : (string, Session.t) Hashtbl.t;
  muts : (string, Mutation.Event.t list) Hashtbl.t;
  held : (string, string) Hashtbl.t;
}

let fresh_store () =
  {
    sessions = Hashtbl.create 8;
    muts = Hashtbl.create 8;
    held = Hashtbl.create 8;
  }

let seed_session st ~id =
  let s =
    Session.create ~id:(sid id) ~cwd:engine_cwd
      ~created_at:(Session.Time.of_unix_ms 1L)
      ()
  in
  Hashtbl.replace st.sessions id s;
  Hashtbl.replace st.muts id []

let store_of st : (module Ports.STORE) =
  (module struct
    type guard = string
    type loaded = Session.t

    let session_of l = l

    let try_acquire id =
      let k = Session.Id.to_string id in
      match Hashtbl.find_opt st.held k with
      | Some owner -> `Held (Some owner)
      | None ->
          Hashtbl.replace st.held k "fake-owner";
          `Acquired k

    let release g = Hashtbl.remove st.held g

    let create session =
      let k = Session.Id.to_string (Session.id session) in
      if Hashtbl.mem st.sessions k then Error Ports.Store_error.Conflict
      else begin
        Hashtbl.replace st.sessions k session;
        Hashtbl.replace st.muts k [];
        Ok session
      end

    let fork ~from:_ ~events session =
      let k = Session.Id.to_string (Session.id session) in
      if Hashtbl.mem st.sessions k then Error Ports.Store_error.Conflict
      else begin
        Hashtbl.replace st.sessions k session;
        Hashtbl.replace st.muts k events;
        Ok session
      end

    let load g =
      match Hashtbl.find_opt st.sessions g with
      | Some s -> Ok s
      | None -> Error Ports.Store_error.Not_found

    let view id =
      match Hashtbl.find_opt st.sessions (Session.Id.to_string id) with
      | Some s -> Ok s
      | None -> Error Ports.Store_error.Not_found

    let commit g loaded events =
      match Session.append_all events loaded with
      | Error e -> Error (Ports.Store_error.Rejected e)
      | Ok s ->
          Hashtbl.replace st.sessions g s;
          Ok s

    let commit_metadata g _loaded session =
      Hashtbl.replace st.sessions g session;
      Ok session

    let of_events_or_corrupt updated =
      match Mutation.State.of_events updated with
      | Ok state -> Ok state
      | Error _ ->
          Error
            (Ports.Store_error.Corrupt
               (Mentat_diagnostic.of_text "fake mutation ledger inconsistent"))

    let append_edit g _loaded ~entries:_ event =
      let updated =
        Option.value (Hashtbl.find_opt st.muts g) ~default:[] @ [ event ]
      in
      Hashtbl.replace st.muts g updated;
      of_events_or_corrupt updated

    let append_mutation g _loaded events =
      let updated =
        Option.value (Hashtbl.find_opt st.muts g) ~default:[] @ events
      in
      Hashtbl.replace st.muts g updated;
      of_events_or_corrupt updated

    let mutation_events loaded =
      let id = Session.id loaded in
      Ok
        (Option.value
           (Hashtbl.find_opt st.muts (Session.Id.to_string id))
           ~default:[])

    let blob _id _ref = Ok None

    (* A small in-memory attachment namespace, content-addressed like the real
       store, so the engine's media passes round-trip if a test exercises them. *)
    let attachments : (string, string) Hashtbl.t = Hashtbl.create 8

    let attachment_key id reference =
      Session.Id.to_string id ^ "\x00"
      ^ Mentat_digest.Content_ref.to_token reference

    let put_attachment id bytes =
      let reference = Mentat_digest.Content_ref.of_contents bytes in
      Hashtbl.replace attachments (attachment_key id reference) bytes;
      Ok reference

    let attachment id reference =
      Ok (Hashtbl.find_opt attachments (attachment_key id reference))

    (* The fake has no revert/export backend; the online cones are proven against
       the real store elsewhere, so these decline honestly. *)
    let revert _g _loaded ~scope:_ =
      Error
        (Ports.Store_error.Io
           (Mentat_diagnostic.of_text "fake store: revert not implemented"))

    let revert_selection _g _loaded ~selection:_ =
      Error
        (Ports.Store_error.Io
           (Mentat_diagnostic.of_text
              "fake store: revert_selection not implemented"))

    let truncate _g _loaded ~keep:_ _session =
      Error
        (Ports.Store_error.Io
           (Mentat_diagnostic.of_text "fake store: truncate not implemented"))

    let export _g =
      Error
        (Ports.Store_error.Io
           (Mentat_diagnostic.of_text "fake store: export not implemented"))
  end)

let ports_workspace : Ports.workspace =
  let checkpoint ~boundary =
    Mutation.Checkpoint.make ~boundary
      ~capture:
        (Mutation.Checkpoint.Capture.Available
           {
             snapshot =
               Mutation.Checkpoint.Snapshot.make ~backend:"fake"
                 ~reference:"ref";
             excluded = 0;
           })
  in
  {
    Ports.identity = Sandbox.identity Sandbox.direct;
    checkpoint;
    open_scope =
      (fun _claim () ->
        { Mentat_edit.Apply_evidence.applies = []; observed = [] });
    drain_notices = (fun () -> []);
  }

let engine_catalog =
  match Catalog.make ~verbs:all_verbs [] with
  | Ok c -> c
  | Error e -> failf "catalog: %a" Catalog.Error.pp e

let engine_config _id ~latest_model:_ =
  Ok (Agent.Config.make ~model:engine_model ~continuation_turn_limit:None ())

let make_engine ~sw ~store ~script =
  let now =
    let r = ref 1000L in
    fun () ->
      let v = !r in
      r := Int64.add v 1L;
      Session.Time.of_unix_ms v
  in
  let as_execution (catalog, workspace, policy) =
    Agent.Execution.make ~catalog ~workspace ~policy
      ~prelude:Mentat_llm.Request.Prelude.empty
  in
  let execution_for_mode ~background:_ =
    let select ~configured ~model:_ ~sealed_declarations:_ _mode =
      as_execution
        (engine_catalog, ports_workspace, configured.Agent.Config.policy)
    in
    (* No background processes run in this fixture; the running-set view is
       empty. *)
    (select, fun () -> [])
  in
  let delegated_execution ~role:_ ~background:_ =
    let select ~configured:_ ~model:_ ~sealed_declarations:_ _mode =
      as_execution (engine_catalog, ports_workspace, Permission.Policy.default)
    in
    (select, fun () -> [])
  in
  Agent.create ~sw ~store:(store_of store) ~provider:script
    ~config:engine_config ~now ~execution_for_mode ~delegated_execution ()

let live_driver engine : Driver.t =
  {
    Driver.session = Agent.driver engine;
    accounts = default_accounts;
    settings = default_settings;
    lifecycle = default_lifecycle;
    review = default_review;
    workspace = default_workspace;
  }

let live_session = sid "root"
let default_script = Ports.script @@ fun _request -> Ok (plain_response "Done.")

(* Spin a real engine over the in-memory store, serve its driver over a unix
   socket, connect a remote client, and hand [f] both the wire client and an
   in-process client over the SAME engine. [make_script] receives the clock so a
   test can stall the provider. *)
let with_live_server ?(make_script = fun _clock -> default_script)
    ?(heartbeat_s = 15.0) f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let store = fresh_store () in
  seed_session store ~id:"root";
  let engine = make_engine ~sw ~store ~script:(make_script clock) in
  let driver = live_driver engine in
  let dir = socket_dir () in
  let bind = Server.Bind.unix ~dir in
  let listener = Server.listen ~sw ~net bind in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try
         Server.serve ~sw ~clock ~heartbeat_s
           ~driver_for:(const_driver_for driver) listener
       with Eio.Cancel.Cancelled _ -> ());
      `Stop_daemon);
  let body () =
    let remote =
      match Server.connect ~sw ~net ~clock ~workspace:"/workspace" bind with
      | Ok d -> make_client d
      | Error error -> failf "connect: %a" Server.Error.pp error
    in
    let in_process = make_client driver in
    f ~net ~sw ~clock ~dir ~remote ~in_process;
    Agent.shutdown engine;
    Ok ()
  in
  match Eio.Time.with_timeout clock 30.0 body with
  | Ok () -> ()
  | Error `Timeout -> fail "live harness deadlock guard: exceeded 30s"

let submit_live client command =
  match Client.submit client command with
  | Ok () -> ()
  | Error e -> failf "submit refused: %a" Error.pp e

let mk_prompt ~turn text =
  match
    Protocol.Command.prompt ~session:live_session ~turn
      ~input:[ Llm.Content.text text ]
      ()
  with
  | Ok c -> c
  | Error e -> failf "prompt: %s" (Protocol.Command.Invalid.message e)

let follow_live ~sw client ~from =
  match Client.follow_session ~sw client live_session ~from with
  | Ok feed -> feed
  | Error e -> failf "follow refused: %a" Error.pp e

let is_settled = function Protocol.Fact.Turn_settled _ -> true | _ -> false

(* Read committed facts until a settlement, skipping progress; close the feed. *)
let drain_committed ?(stop = is_settled) feed =
  let rec loop acc =
    match Feed.next feed with
    | Error e -> failf "feed next: %a" Error.pp e
    | Ok Feed.Closed -> List.rev acc
    | Ok (Feed.Item (Update.Progress _)) -> loop acc
    | Ok (Feed.Item (Update.Committed { position; fact })) ->
        let acc = (position, fact) :: acc in
        if stop fact then List.rev acc else loop acc
  in
  let pairs = loop [] in
  Feed.close feed;
  pairs

(* Drain until the [n]-th settlement (inclusive). *)
let drain_n_settled n feed =
  let seen = ref 0 in
  drain_committed
    ~stop:(fun f ->
      if is_settled f then incr seen;
      !seen >= n)
    feed

let enc_pairs pairs =
  List.map
    (fun (position, fact) ->
      enc Update.jsont (Update.Committed { position; fact }))
    pairs

let has_settled pairs = List.exists (fun (_, f) -> is_settled f) pairs

(* Run two prompt turns and return the full ordered journal of committed facts
   (four facts: two Turn_started/Turn_settled pairs). *)
let two_turns ~sw client =
  submit_live client (mk_prompt ~turn:(tid "t1") "one");
  ignore (drain_committed (follow_live ~sw client ~from:`Beginning));
  submit_live client (mk_prompt ~turn:(tid "t2") "two");
  drain_n_settled 2 (follow_live ~sw client ~from:`Beginning)

let live_stream_group =
  group "live engine: streaming a real turn"
    [
      test "a full prompt turn streams over the wire == in-process replay"
        (fun () ->
          with_live_server
            (fun ~net:_ ~sw ~clock:_ ~dir:_ ~remote ~in_process ->
              submit_live remote (mk_prompt ~turn:(tid "t1") "hello");
              (* The wire client drains the live turn to settlement. *)
              let wire =
                drain_committed (follow_live ~sw remote ~from:`Beginning)
              in
              is_true ~msg:"the wire turn reaches a settlement"
                (has_settled wire);
              (* The in-process client replays the same committed journal. *)
              let local =
                drain_committed (follow_live ~sw in_process ~from:`Beginning)
              in
              equal (list string)
                ~msg:"wire and in-process drains are byte-identical"
                (enc_pairs local) (enc_pairs wire)));
      test "a slow reader loses no committed fact after catching up" (fun () ->
          (* The provider stalls, so the turn spans real time; a consumer that
             sleeps before draining still receives every committed fact — the
             reader fiber enqueues them, and the bounded queue never drops a
             committed fact. *)
          let make_script clock =
            Ports.script @@ fun _request ->
            Eio.Time.sleep clock 0.15;
            Ok (plain_response "Done.")
          in
          with_live_server ~make_script
            (fun ~net:_ ~sw ~clock ~dir:_ ~remote ~in_process:_ ->
              let feed = follow_live ~sw remote ~from:`Beginning in
              submit_live remote (mk_prompt ~turn:(tid "t1") "hello");
              (* Do not pull while the turn runs and settles. *)
              Eio.Time.sleep clock 0.35;
              let slow = drain_committed feed in
              is_true ~msg:"the delayed reader still saw the settlement"
                (has_settled slow);
              let fresh =
                drain_committed (follow_live ~sw remote ~from:`Beginning)
              in
              equal (list string)
                ~msg:"the slow drain equals a fresh replay, nothing dropped"
                (enc_pairs fresh) (enc_pairs slow)));
    ]

let live_resume_group =
  group "live engine: Last-Event-ID resume against the real hub"
    [
      test
        "resume After a committed position skips nothing and duplicates nothing"
        (fun () ->
          with_live_server
            (fun ~net:_ ~sw ~clock:_ ~dir:_ ~remote ~in_process:_ ->
              let full = two_turns ~sw remote in
              is_true ~msg:"the journal has more than one committed fact"
                (List.length full > 1);
              (* Disconnect after the first fact, reconnect strictly after it. *)
              let p0 = fst (List.hd full) in
              let resumed =
                drain_n_settled 2 (follow_live ~sw remote ~from:(`After p0))
              in
              equal (list string)
                ~msg:
                  "resume delivers exactly the suffix after p0, no gap/no dup"
                (enc_pairs (List.tl full))
                (enc_pairs resumed)));
    ]

let live_tail_group =
  group "live engine: tail and page over real journal state"
    [
      test "tail's page is the last-N and pages tile the journal" (fun () ->
          with_live_server
            (fun ~net:_ ~sw ~clock:_ ~dir:_ ~remote ~in_process:_ ->
              let full = two_turns ~sw remote in
              let n = List.length full in
              (* A default tail carries the whole journal as its page, oldest
                 first, and its head is the last fact's position. *)
              let tail = ok (Client.tail remote live_session) in
              equal (list string) ~msg:"tail's page is the full journal"
                (enc_pairs full)
                (enc_pairs
                   tail.Protocol.Transcript.Tail.page
                     .Protocol.Transcript.Page.facts);
              (match tail.Protocol.Transcript.Tail.head with
              | Some head ->
                  is_true ~msg:"the head is the last committed position"
                    (Position.equal head (fst (List.nth full (n - 1))))
              | None -> fail "a settled session has a head");
              (* A tail of n=1 is exactly the last committed fact. *)
              let tail1 = ok (Client.tail remote ~n:1 live_session) in
              equal (list string) ~msg:"tail n=1 is the last fact"
                (enc_pairs [ List.nth full (n - 1) ])
                (enc_pairs
                   tail1.Protocol.Transcript.Tail.page
                     .Protocol.Transcript.Page.facts);
              (* Backward pages of size 1 tile the whole journal, oldest first. *)
              let rec tile before acc =
                let page = ok (Client.page remote ~n:1 live_session ~before) in
                let acc = page.Protocol.Transcript.Page.facts :: acc in
                match page.Protocol.Transcript.Page.before with
                | Some _ as b -> tile b acc
                | None -> acc
              in
              let tiled = List.concat (tile None []) in
              equal (list string)
                ~msg:"chained before=p pages reconstruct the journal in order"
                (enc_pairs full) (enc_pairs tiled);
              (* A forged position is a structured Invalid_position, never a
                 silently truncated page. *)
              match
                Client.page remote ~n:1 live_session
                  ~before:(Some (Position.make ~session:live_session ~seq:9999))
              with
              | Error (Error.Invalid_position _) -> ()
              | Error e -> failf "expected Invalid_position, got %a" Error.pp e
              | Ok _ -> fail "a forged before-position must not return a page"));
    ]

let live_heartbeat_group =
  group "live engine: SSE heartbeat during a provider stall"
    [
      test "heartbeat comments appear during a stall without disturbing frames"
        (fun () ->
          let make_script clock =
            Ports.script @@ fun _request ->
            Eio.Time.sleep clock 0.3;
            Ok (plain_response "Done.")
          in
          with_live_server ~make_script ~heartbeat_s:0.05
            (fun ~net ~sw ~clock ~dir ~remote ~in_process:_ ->
              (* Admit the turn (Turn_started commits); the provider then stalls
                 0.3s, during which the feed is idle and heartbeats fire. *)
              submit_live remote (mk_prompt ~turn:(tid "t1") "hello");
              let body =
                attached_feed ~net ~dir ~sw "/feed?session=root&from=beginning"
              in
              let reader = Eio.Buf_read.of_flow body ~max_size:1_000_000 in
              let lines = ref [] in
              (try
                 Eio.Fiber.first
                   (fun () ->
                     let rec loop () =
                       match Eio.Buf_read.line reader with
                       | line ->
                           lines := line :: !lines;
                           loop ()
                       | exception End_of_file -> ()
                     in
                     loop ())
                   (fun () -> Eio.Time.sleep clock 0.6)
               with Eio.Cancel.Cancelled _ -> ());
              let seen = !lines in
              is_true ~msg:"an idle heartbeat comment appeared"
                (List.exists (fun l -> String.equal l ": hb") seen);
              let data_frames =
                List.filter (fun l -> String.starts_with ~prefix:"data:" l) seen
              in
              is_true
                ~msg:"the committed turn frames still arrived (started+settled)"
                (List.length data_frames >= 2)));
    ]

(* ---- Fix-list coverage (gate PASS-WITH-FIXLIST) ---- *)

(* Extract a request-id from a raw wire request body (the custom H1 server and the
   H2 ledger test read it without the private Wire codec). *)
let request_id_of body =
  match Jsont_bytesrw.decode_string Jsont.json body with
  | Ok (Jsont.Object (members, _)) ->
      List.find_map
        (fun ((name, _), value) ->
          if String.equal name "request_id" then
            match value with Jsont.String (s, _) -> Some s | _ -> None
          else None)
        members
  | _ -> None

let queue_next command_session =
  match
    Protocol.Command.queue_next ~session:command_session
      ~input:[ Llm.Content.text "again" ]
  with
  | Ok c -> c
  | Error _ -> fail "queue_next build"

let m4_group =
  group "one-table idempotency"
    [
      test "the request-id backstop surface is exactly the descriptor field"
        (fun () ->
          (* The dispatcher and connect both derive the backstop from the
             descriptor's idempotency field; the row-level Requires_request_id
             endpoints are session.revert (a worktree-mutating revert) and
             review.compose, in table order (submit's two variants are
             per-variant, not a row). Field ↔ behavior cannot drift because there
             is no parallel hardcoded list. *)
          equal (list string)
            ~msg:
              "row-level Requires_request_id is session.revert then \
               review.compose"
            [ "session.revert"; "review.compose" ]
            Server.requires_request_id_rows);
    ]

let idempotency_group =
  group "request-id backstop (H1, H2)"
    [
      test "a Requires_request_id retry reuses its id; the effect applies once"
        (fun () ->
          Eio_main.run @@ fun env ->
          let net = Eio.Stdenv.net env in
          let clock = Eio.Stdenv.clock env in
          Eio.Switch.run @@ fun sw ->
          let dir = socket_dir () in
          let path = Filename.concat (Lpath.Abs.to_string dir) "mentat.sock" in
          (try Unix.mkdir (Lpath.Abs.to_string dir) 0o700
           with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          (try Unix.unlink path with Unix.Unix_error _ -> ());
          let socket = Eio.Net.listen net ~sw ~backlog:8 (`Unix path) in
          (* A server that applies the effect once (keyed by rid), drops the
             connection before responding on the first attempt, then serves the
             cached outcome — the lost-ack scenario the request-id defends. *)
          let seen_rids = ref [] in
          let effects = ref 0 in
          let applied = Hashtbl.create 8 in
          let attempts = ref 0 in
          let ok_body rid =
            Printf.sprintf {|{"v":1,"request_id":"%s","result":{}}|} rid
          in
          let server =
            Cohttp_eio.Server.make
              ~callback:(fun _conn request rbody ->
                let path = Uri.path (Cohttp.Request.uri request) in
                match (Cohttp.Request.meth request, path) with
                | `POST, "/handshake" ->
                    (* Drain the request body: on the now-shared keep-alive
                       connection an unconsumed body misframes the next
                       request. *)
                    ignore
                      (Eio.Buf_read.take_all
                         (Eio.Buf_read.of_flow rbody ~max_size:1_000_000));
                    Cohttp_eio.Server.respond_string ~status:`OK
                      ~body:{|{"v":1,"workspace":"/workspace"}|} ()
                | `POST, "/wire" -> (
                    let text =
                      Eio.Buf_read.take_all
                        (Eio.Buf_read.of_flow rbody ~max_size:1_000_000)
                    in
                    match request_id_of text with
                    | None -> fail "the submit carried no request-id"
                    | Some rid ->
                        seen_rids := rid :: !seen_rids;
                        if not (Hashtbl.mem applied rid) then begin
                          Hashtbl.replace applied rid ();
                          incr effects
                        end;
                        incr attempts;
                        if !attempts = 1 then
                          (* Drop the connection before responding. *)
                          raise (Failure "lost ack")
                        else
                          Cohttp_eio.Server.respond_string ~status:`OK
                            ~body:(ok_body rid) ())
                | _ ->
                    Cohttp_eio.Server.respond_string ~status:`Not_found ~body:""
                      ())
              ()
          in
          Eio.Fiber.fork_daemon ~sw (fun () ->
              (try Cohttp_eio.Server.run ~on_error:(fun _ -> ()) socket server
               with _ -> ());
              `Stop_daemon);
          let body () =
            let remote =
              match Server.connect ~sw ~net ~clock (Server.Bind.unix ~dir) with
              | Ok d -> make_client d
              | Error e -> failf "connect: %a" Server.Error.pp e
            in
            (match Client.submit remote (queue_next session_id) with
            | Ok () -> ()
            | Error e -> failf "submit after retry: %a" Error.pp e);
            equal int ~msg:"the effect applied exactly once despite the retry" 1
              !effects;
            (match !seen_rids with
            | [ b; a ] ->
                is_true ~msg:"the retry reused the same request-id"
                  (String.equal a b)
            | rids -> failf "expected two attempts, saw %d" (List.length rids));
            Ok ()
          in
          match Eio.Time.with_timeout clock 30.0 body with
          | Ok () -> ()
          | Error `Timeout -> fail "deadlock guard: H1 exceeded 30s");
      test
        "a row-level Requires_request_id op (session.revert) self-mints its \
         id, and a retry reuses it; the effect applies once (H1, row path)"
        (fun () ->
          (* The standing residual from the Stage-1 delta review: the row-level
             self-mint path — connect minting the rid from the descriptor's
             [Requires_request_id] field, not from a supplied command-variant id
             like Queue_next above — was never exercised end-to-end.
             session.revert is the second such row (review.compose the first) and
             the easier to script; both share the one mint path, so this closes
             the gap for both. *)
          Eio_main.run @@ fun env ->
          let net = Eio.Stdenv.net env in
          let clock = Eio.Stdenv.clock env in
          Eio.Switch.run @@ fun sw ->
          let dir = socket_dir () in
          let path = Filename.concat (Lpath.Abs.to_string dir) "mentat.sock" in
          (try Unix.mkdir (Lpath.Abs.to_string dir) 0o700
           with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          (try Unix.unlink path with Unix.Unix_error _ -> ());
          let socket = Eio.Net.listen net ~sw ~backlog:8 (`Unix path) in
          let seen_rids = ref [] in
          let effects = ref 0 in
          let applied = Hashtbl.create 8 in
          let attempts = ref 0 in
          let ok_body rid =
            Printf.sprintf
              {|{"v":1,"request_id":"%s","result":{"type":"nothing_to_revert"}}|}
              rid
          in
          let server =
            Cohttp_eio.Server.make
              ~callback:(fun _conn request rbody ->
                let path = Uri.path (Cohttp.Request.uri request) in
                match (Cohttp.Request.meth request, path) with
                | `POST, "/handshake" ->
                    ignore
                      (Eio.Buf_read.take_all
                         (Eio.Buf_read.of_flow rbody ~max_size:1_000_000));
                    Cohttp_eio.Server.respond_string ~status:`OK
                      ~body:{|{"v":1,"workspace":"/workspace"}|} ()
                | `POST, "/wire" -> (
                    let text =
                      Eio.Buf_read.take_all
                        (Eio.Buf_read.of_flow rbody ~max_size:1_000_000)
                    in
                    match request_id_of text with
                    | None ->
                        fail "the revert carried no self-minted request-id"
                    | Some rid ->
                        seen_rids := rid :: !seen_rids;
                        if not (Hashtbl.mem applied rid) then begin
                          Hashtbl.replace applied rid ();
                          incr effects
                        end;
                        incr attempts;
                        if !attempts = 1 then raise (Failure "lost ack")
                        else
                          Cohttp_eio.Server.respond_string ~status:`OK
                            ~body:(ok_body rid) ())
                | _ ->
                    Cohttp_eio.Server.respond_string ~status:`Not_found ~body:""
                      ())
              ()
          in
          Eio.Fiber.fork_daemon ~sw (fun () ->
              (try Cohttp_eio.Server.run ~on_error:(fun _ -> ()) socket server
               with _ -> ());
              `Stop_daemon);
          let body () =
            let remote =
              match Server.connect ~sw ~net ~clock (Server.Bind.unix ~dir) with
              | Ok d -> make_client d
              | Error e -> failf "connect: %a" Server.Error.pp e
            in
            (match
               Client.revert remote ~session:(sid "root")
                 ~scope:Mutation.Revert.Scope.Latest
             with
            | Ok Mutation.Revert.Outcome.Nothing_to_revert -> ()
            | Ok _ -> fail "the server returned Nothing_to_revert"
            | Error e -> failf "revert after retry: %a" Error.pp e);
            equal int ~msg:"the revert applied exactly once despite the retry" 1
              !effects;
            (match !seen_rids with
            | [ b; a ] ->
                is_true ~msg:"the retry reused the self-minted request-id"
                  (String.equal a b)
            | rids -> failf "expected two attempts, saw %d" (List.length rids));
            Ok ()
          in
          match Eio.Time.with_timeout clock 30.0 body with
          | Ok () -> ()
          | Error `Timeout -> fail "deadlock guard: revert H1 exceeded 30s");
      test "the ledger is bounded: past the cap the oldest id is evicted"
        (fun () ->
          let calls = ref 0 in
          let session =
            {
              default_session with
              Driver.Session.submit =
                (fun _ ->
                  incr calls;
                  Ok ());
            }
          in
          with_server ~ledger_cap:2 ~driver:(make_driver ~session ())
            (fun ~env:_ ~net ~sw:_ ~dir ~bind:_ ~remote:_ ->
              let envelope ~rid =
                Printf.sprintf
                  {|{"v":1,"request_id":%S,"endpoint":"session.submit","payload":%s}|}
                  rid
                  (enc Protocol.Command.jsont (queue_next session_id))
              in
              let post rid =
                ignore (attached_post ~net ~dir "/wire" (envelope ~rid))
              in
              (* Three distinct ids at cap 2: the ledger holds {r2,r3}, r1 evicted. *)
              post "r1";
              post "r2";
              post "r3";
              equal int ~msg:"three distinct ids apply three effects" 3 !calls;
              (* r3 is still cached — a replay dedups. *)
              post "r3";
              equal int ~msg:"a retained id still dedups" 3 !calls;
              (* r1 was evicted — its replay is no longer deduped. *)
              post "r1";
              equal int ~msg:"the evicted id's replay re-applies" 4 !calls));
    ]

(* A feed seam whose [close] records that it ran, so a client-side close can be
   shown to release the server-side seam promptly. *)
let recording_seam ~on_close updates : Feed.seam =
  let queue = Queue.create () in
  List.iter (fun u -> Queue.push u queue) updates;
  let condition = Eio.Condition.create () in
  let closed = ref false in
  let next () =
    Eio.Condition.loop_no_mutex condition (fun () ->
        match Queue.take_opt queue with
        | Some u -> Some (Ok (Feed.Item u))
        | None -> if !closed then Some (Ok Feed.Closed) else None)
  in
  let close () =
    if not !closed then on_close ();
    closed := true;
    Eio.Condition.broadcast condition
  in
  { Feed.next; close }

let teardown_group =
  group "prompt teardown on disconnect"
    [
      test "a client feed close releases the server seam promptly" (fun () ->
          let server_closes = ref 0 in
          let session =
            {
              default_session with
              Driver.Session.follow =
                (fun _ ~from:_ ->
                  Ok
                    (recording_seam
                       ~on_close:(fun () -> incr server_closes)
                       updates));
            }
          in
          (* A short heartbeat: after the client aborts, the daemon's next
             heartbeat write fails, and [Fun.protect] closes the seam. *)
          with_server ~heartbeat_s:0.05 ~driver:(make_driver ~session ())
            (fun ~env ~net:_ ~sw ~dir:_ ~bind:_ ~remote ->
              let feed =
                ok
                  (Client.follow_session ~sw remote session_id ~from:`Beginning)
              in
              ignore (read_item feed);
              Feed.close feed;
              Eio.Time.sleep (Eio.Stdenv.clock env) 0.3;
              is_true ~msg:"the server seam was closed by the disconnect"
                (!server_closes >= 1)));
      test "a client login cancel releases the server flow promptly" (fun () ->
          let server_cancels = ref 0 in
          let redirect_uri = Uri.of_string "http://127.0.0.1/callback" in
          let steps () : Client.Login.steps =
            let condition = Eio.Condition.create () in
            let emitted = ref false in
            let cancelled = ref false in
            {
              Client.Login.next =
                (fun () ->
                  (* One progress step, then park until the flow is cancelled. *)
                  if not !emitted then begin
                    emitted := true;
                    Ok
                      (Client.Login.Progress
                         (Provider.Auth.Login.Progress.Listening
                            { redirect_uri }))
                  end
                  else
                    Eio.Condition.loop_no_mutex condition (fun () ->
                        if !cancelled then Some (Ok Client.Login.Cancelled)
                        else None));
              cancel =
                (fun () ->
                  incr server_cancels;
                  cancelled := true;
                  Eio.Condition.broadcast condition);
            }
          in
          let accounts =
            {
              default_accounts with
              Driver.Accounts.login =
                (fun ~provider:_ ~method_:_ -> Ok (steps ()));
            }
          in
          with_server ~heartbeat_s:0.05 ~driver:(make_driver ~accounts ())
            (fun ~env ~net:_ ~sw ~dir:_ ~bind:_ ~remote ->
              let login =
                ok
                  (Client.login ~sw remote
                     ~provider:(Llm.Provider.make "openai")
                     ~method_:(Provider.Auth.Login.Id.make "browser"))
              in
              (match Client.Login.next login with
              | Ok (Client.Login.Progress _) -> ()
              | _ -> fail "expected the first progress step");
              Client.Login.cancel login;
              Eio.Time.sleep (Eio.Stdenv.clock env) 0.3;
              is_true
                ~msg:"the server login flow was cancelled by the disconnect"
                (!server_cancels >= 1)));
      test "a feed close before the first pull leaks no server seam" (fun () ->
          (* The abort-ref race: a close issued before the reader fiber runs must
             still abort the stream. Assert the invariant that survives either
             scheduling — every seam the daemon opened, it closed. *)
          let opens = ref 0 and closes = ref 0 in
          let session =
            {
              default_session with
              Driver.Session.follow =
                (fun _ ~from:_ ->
                  incr opens;
                  Ok (recording_seam ~on_close:(fun () -> incr closes) updates));
            }
          in
          with_server ~heartbeat_s:0.05 ~driver:(make_driver ~session ())
            (fun ~env ~net:_ ~sw ~dir:_ ~bind:_ ~remote ->
              let feed =
                ok
                  (Client.follow_session ~sw remote session_id ~from:`Beginning)
              in
              (* Close immediately — no [next], no yield. *)
              Feed.close feed;
              Eio.Time.sleep (Eio.Stdenv.clock env) 0.3;
              equal int ~msg:"no server seam is leaked by an immediate close"
                !opens !closes));
    ]

let progress_update =
  Update.Progress
    (Protocol.Progress.Model
       {
         turn = tid "turn-1";
         update = Protocol.Progress.Model.Assistant_delta { text = "hi" };
       })

let coverage_group =
  group "feed coverage (property 5; Now/close)"
    [
      test "a committed frame carries an id: and a progress frame does not"
        (fun () ->
          (* Every SSE id: names a committed position; progress is
             id-less. Read the raw SSE and inspect the id: lines directly. *)
          let session =
            {
              default_session with
              Driver.Session.follow =
                (fun _ ~from:_ ->
                  Ok (scripted_seam [ List.hd updates; progress_update ]));
            }
          in
          with_server ~driver:(make_driver ~session ())
            (fun ~env ~net ~sw ~dir ~bind:_ ~remote:_ ->
              let rbody =
                attached_feed ~net ~dir ~sw
                  "/feed?session=session-1&from=beginning"
              in
              let reader = Eio.Buf_read.of_flow rbody ~max_size:1_000_000 in
              (* Collect frames as (has_id, is_progress) until we have both. *)
              let committed_has_id = ref None in
              let progress_has_id = ref None in
              let cur_id = ref false in
              let cur_kind = ref `Unknown in
              (try
                 Eio.Fiber.first
                   (fun () ->
                     let rec loop () =
                       let line = Eio.Buf_read.line reader in
                       if String.equal line "" then begin
                         (match !cur_kind with
                         | `Committed -> committed_has_id := Some !cur_id
                         | `Progress -> progress_has_id := Some !cur_id
                         | `Unknown -> ());
                         cur_id := false;
                         cur_kind := `Unknown
                       end
                       else if
                         String.length line >= 3
                         && String.equal (String.sub line 0 3) "id:"
                       then cur_id := true
                       else if
                         String.length line >= 5
                         && String.equal (String.sub line 0 5) "data:"
                       then begin
                         (* a committed fact carries "type":"committed" *)
                         let contains sub s =
                           let ls = String.length s
                           and lsub = String.length sub in
                           let rec go i =
                             i + lsub <= ls
                             && (String.equal (String.sub s i lsub) sub
                                || go (i + 1))
                           in
                           go 0
                         in
                         if contains "\"committed\"" line then
                           cur_kind := `Committed
                         else cur_kind := `Progress
                       end;
                       if !committed_has_id <> None && !progress_has_id <> None
                       then ()
                       else loop ()
                     in
                     loop ())
                   (fun () -> Eio.Time.sleep (Eio.Stdenv.clock env) 2.0)
               with Eio.Cancel.Cancelled _ -> ());
              (match !committed_has_id with
              | Some true -> ()
              | _ -> fail "the committed frame must carry an id:");
              match !progress_has_id with
              | Some false -> ()
              | _ -> fail "the progress frame must not carry an id:"));
      test "a Now follow parks; a client close then wakes it with Closed"
        (fun () ->
          with_server ~driver:(make_driver ())
            (fun ~env ~net:_ ~sw ~dir:_ ~bind:_ ~remote ->
              let clock = Eio.Stdenv.clock env in
              let feed =
                ok (Client.follow_session ~sw remote session_id ~from:`Now)
              in
              let observed = ref `Parked in
              Eio.Fiber.fork ~sw (fun () ->
                  observed :=
                    match Feed.next feed with
                    | Ok Feed.Closed -> `Closed
                    | Ok (Feed.Item _) -> `Item
                    | Error _ -> `Error);
              Eio.Time.sleep clock 0.1;
              is_true ~msg:"a Now attach leaves next parked, not Closed"
                (!observed = `Parked);
              Feed.close feed;
              Eio.Time.sleep clock 0.1;
              is_true ~msg:"close wakes the parked next with Closed"
                (!observed = `Closed)));
      test
        "a >8KB committed frame crosses the socket byte-identical (transport \
         regression, R3)" (fun () ->
          let expected = enc Update.jsont large_update in
          is_true ~msg:"the fixture frame exceeds 8KB"
            (String.length expected > 8192);
          let session =
            {
              default_session with
              Driver.Session.follow =
                (fun _ ~from:_ -> Ok (scripted_seam [ large_update ]));
            }
          in
          with_server ~driver:(make_driver ~session ())
            (fun ~env:_ ~net:_ ~sw ~dir:_ ~bind:_ ~remote ->
              let feed =
                ok
                  (Client.follow_session ~sw remote session_id ~from:`Beginning)
              in
              let item = read_item feed in
              equal string ~msg:"the large frame is not scrambled in transit"
                expected (enc Update.jsont item);
              Feed.close feed));
    ]

(* ---- W2: daemon discovery ---- *)

let a_discovery ?web_url ~socket ~pid () =
  {
    Server.Discovery.socket;
    pid;
    protocol = 1;
    binary = "0.1.0-test";
    config_home = "/home/u/.config/mentat";
    started_at = 1_753_000_000_000;
    web_url;
  }

(* A guaranteed-fresh 0700 directory. The discovery file has no sun_path limit
   (unlike the socket dir), so a long temp-dir path is fine. *)
let fresh_daemon_dir () =
  Lpath.Abs.of_string_exn (temp_dir ~prefix:"mtdaemon" ())

let discovery_group =
  group "daemon discovery"
    [
      test "the discovery record round-trips through its codec" (fun () ->
          let d = a_discovery ~socket:"/tmp/mtsrv/mentat.sock" ~pid:4242 () in
          match
            Jsont_bytesrw.decode_string Server.Discovery.jsont
              (enc Server.Discovery.jsont d)
          with
          | Ok d' ->
              equal string ~msg:"socket" d.Server.Discovery.socket
                d'.Server.Discovery.socket;
              equal int ~msg:"pid" d.Server.Discovery.pid
                d'.Server.Discovery.pid;
              equal int ~msg:"protocol" d.Server.Discovery.protocol
                d'.Server.Discovery.protocol;
              is_true ~msg:"an absent web_url decodes to None"
                (Option.is_none d'.Server.Discovery.web_url)
          | Error message -> failf "decode: %s" message);
      test "the optional web_url round-trips when present (additive field)"
        (fun () ->
          let url = "http://127.0.0.1:8080/?t=deadbeef" in
          let d = a_discovery ~web_url:url ~socket:"/s" ~pid:7 () in
          match
            Jsont_bytesrw.decode_string Server.Discovery.jsont
              (enc Server.Discovery.jsont d)
          with
          | Ok d' -> (
              match d'.Server.Discovery.web_url with
              | Some u ->
                  equal string ~msg:"web_url survives the round-trip" url u
              | None -> fail "web_url was dropped on the round-trip")
          | Error message -> failf "decode: %s" message);
      test "an unknown file-format version is rejected on decode" (fun () ->
          match
            Jsont_bytesrw.decode_string Server.Discovery.jsont
              {|{"v":99,"socket":"/x","pid":1,"protocol":1,"binary":"b","config_home":"/c","started_at":0}|}
          with
          | Error _ -> ()
          | Ok _ -> fail "an unknown v must not decode");
      test "write is atomic: 0600 file under a 0700 dir, no tmp residue"
        (fun () ->
          let dir = fresh_daemon_dir () in
          let dir_s = Lpath.Abs.to_string dir in
          let d = a_discovery ~socket:(dir_s ^ "/mentat.sock") ~pid:777 () in
          (match Server.Discovery.write ~dir d with
          | Ok () -> ()
          | Error message -> failf "write: %s" message);
          equal int ~msg:"the daemon dir is 0700" 0o700
            ((Unix.stat dir_s).Unix.st_perm land 0o777);
          equal int ~msg:"the discovery file is 0600" 0o600
            ((Unix.stat (Filename.concat dir_s "daemon.json")).Unix.st_perm
           land 0o777);
          is_false ~msg:"no temp residue is left behind"
            (Array.exists
               (fun name -> String.starts_with ~prefix:".daemon.json." name)
               (Sys.readdir dir_s));
          match Server.Discovery.read ~dir with
          | `Found d' ->
              equal int ~msg:"read observes the written record" 777
                d'.Server.Discovery.pid
          | `Absent | `Foreign _ -> fail "expected the written record");
      test "read classifies Absent, Found, and Foreign" (fun () ->
          let dir = fresh_daemon_dir () in
          let dir_s = Lpath.Abs.to_string dir in
          (match Server.Discovery.read ~dir with
          | `Absent -> ()
          | _ -> fail "a directory with no discovery file is Absent");
          Out_channel.with_open_bin (Filename.concat dir_s "daemon.json")
            (fun oc -> Out_channel.output_string oc "{ not json");
          (match Server.Discovery.read ~dir with
          | `Foreign _ -> ()
          | _ -> fail "undecodable bytes are Foreign");
          ignore
            (Server.Discovery.write ~dir (a_discovery ~socket:"/s" ~pid:9 ()));
          match Server.Discovery.read ~dir with
          | `Found _ -> ()
          | _ -> fail "a valid file is Found");
      test
        "the claim excludes a same-process contender, re-acquires after release"
        (fun () ->
          let dir = fresh_daemon_dir () in
          let g =
            match Server.Discovery.Claim.try_acquire ~dir with
            | Ok g -> g
            | Error _ -> fail "first acquire should succeed"
          in
          (match Server.Discovery.Claim.try_acquire ~dir with
          | Error `Held -> ()
          | Ok _ -> fail "a same-process second acquire must be Held"
          | Error (`Io message) -> failf "unexpected io error: %s" message);
          Server.Discovery.Claim.release g;
          match Server.Discovery.Claim.try_acquire ~dir with
          | Ok g2 -> Server.Discovery.Claim.release g2
          | Error _ -> fail "the claim should re-acquire after release");
    ]

(* A server whose per-connection binding is resolved by an arbitrary [driver_for],
   for the A4 handshake-routing and A9 refusal tests. *)
let with_driver_for_server ~driver_for f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let dir = socket_dir () in
  let bind = Server.Bind.unix ~dir in
  let listener = Server.listen ~sw ~net bind in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try Server.serve ~sw ~clock ~driver_for listener
       with Eio.Cancel.Cancelled _ -> ());
      `Stop_daemon);
  let body () =
    f ~env ~net ~sw ~clock ~dir ~bind;
    Ok ()
  in
  match Eio.Time.with_timeout clock 30.0 body with
  | Ok () -> ()
  | Error `Timeout -> fail "deadlock guard: the harness exceeded 30s"

(* A driver whose workspace glance records that this instance served, so a routed
   call can be shown to reach the right bound driver. *)
let glance_recording_driver served label =
  let workspace : Driver.Workspace.t =
    {
      Driver.Workspace.glance =
        (fun () ->
          served := label :: !served;
          Ok (None, Workspace.Health.Off Workspace.Health.Off.Disabled));
      dune = (fun () -> Ok (Workspace.Health.Off Workspace.Health.Off.Disabled));
    }
  in
  make_driver ~workspace ()

let driver_for_group =
  group "per-connection binding"
    [
      test
        "the handshake binds the requested workspace and routes to its driver"
        (fun () ->
          let served = ref [] in
          let driver_for ~workspace ~environment:_ =
            match workspace with
            | Some "/ws/a" ->
                Ok
                  {
                    Server.workspace = Some "/ws/a";
                    driver = glance_recording_driver served "A";
                    on_close = (fun () -> ());
                  }
            | Some "/ws/b" ->
                Ok
                  {
                    Server.workspace = Some "/ws/b";
                    driver = glance_recording_driver served "B";
                    on_close = (fun () -> ());
                  }
            | Some _ | None ->
                Error
                  (Error.Unavailable
                     (Mentat_diagnostic.of_text "no such workspace"))
          in
          with_driver_for_server ~driver_for
            (fun ~env:_ ~net ~sw ~clock ~dir:_ ~bind ->
              let connect ws =
                match Server.connect ~sw ~net ~clock ~workspace:ws bind with
                | Ok d -> make_client d
                | Error e -> failf "connect %s: %a" ws Server.Error.pp e
              in
              ignore (ok (Client.workspace_glance (connect "/ws/a")));
              ignore (ok (Client.workspace_glance (connect "/ws/b")));
              (* Each glance reached the driver its connection bound. *)
              equal (list string) ~msg:"the bound workspace's driver served"
                [ "B"; "A" ] !served));
      test "a driver_for error surfaces as a structured handshake refusal"
        (fun () ->
          let driver_for ~workspace:_ ~environment:_ =
            Error
              (Error.Unavailable (Mentat_diagnostic.of_text "no such workspace"))
          in
          with_driver_for_server ~driver_for
            (fun ~env:_ ~net ~sw ~clock ~dir:_ ~bind ->
              match Server.connect ~sw ~net ~clock ~workspace:"/ws/x" bind with
              | Ok _ -> fail "a driver_for error must refuse the handshake"
              | Error (Server.Error.Transport message) ->
                  is_true ~msg:"the refusal carries the driver_for error text"
                    (contains_substring "no such workspace" message)
              | Error e ->
                  failf "expected a Transport refusal, got %a" Server.Error.pp e));
      test "an absent handshake workspace is refused" (fun () ->
          (* The Stage-2 daemon's driver_for refuses [None]; the wire optional
             stays but no unbound connection is bound. *)
          let driver_for ~workspace ~environment:_ =
            match workspace with
            | None ->
                Error
                  (Error.Unavailable
                     (Mentat_diagnostic.of_text "bind a workspace"))
            | Some ws ->
                Ok
                  {
                    Server.workspace = Some ws;
                    driver = make_driver ();
                    on_close = (fun () -> ());
                  }
          in
          with_driver_for_server ~driver_for
            (fun ~env:_ ~net ~sw ~clock ~dir:_ ~bind ->
              match Server.connect ~sw ~net ~clock bind with
              | Ok _ -> fail "an unbound handshake must be refused"
              | Error (Server.Error.Transport message) ->
                  is_true ~msg:"the refusal names the missing binding"
                    (contains_substring "bind a workspace" message)
              | Error e ->
                  failf "expected a Transport refusal, got %a" Server.Error.pp e));
      test "on_close fires exactly once per connection" (fun () ->
          let opens = ref 0 and closes = ref 0 in
          let driver_for ~workspace:_ ~environment:_ =
            incr opens;
            Ok
              {
                Server.workspace = Some "/ws";
                driver = make_driver ();
                on_close = (fun () -> incr closes);
              }
          in
          with_driver_for_server ~driver_for
            (fun ~env:_ ~net ~sw ~clock ~dir:_ ~bind ->
              let remote =
                match Server.connect ~sw ~net ~clock ~workspace:"/ws" bind with
                | Ok d -> make_client d
                | Error e -> failf "connect: %a" Server.Error.pp e
              in
              (* A single-shot (its own connection) and a feed opened then closed
                 (another). Each binds and later closes exactly once. *)
              ignore (ok (Client.workspace_glance remote));
              let feed =
                ok
                  (Client.follow_session ~sw remote session_id ~from:`Beginning)
              in
              Feed.close feed;
              (* Let the server drain the closed connections. *)
              Eio.Time.sleep clock 0.1;
              is_true ~msg:"at least one connection was bound and closed"
                (!opens >= 2);
              equal int ~msg:"every bound connection closed exactly once" !opens
                !closes));
      test "on_close fires when the server is cancelled" (fun () ->
          Eio_main.run @@ fun env ->
          let net = Eio.Stdenv.net env in
          let clock = Eio.Stdenv.clock env in
          Eio.Switch.run @@ fun sw ->
          let dir = socket_dir () in
          let bind = Server.Bind.unix ~dir in
          let listener = Server.listen ~sw ~net bind in
          let opens = ref 0 and closes = ref 0 in
          let driver_for ~workspace:_ ~environment:_ =
            incr opens;
            Ok
              {
                Server.workspace = Some "/ws";
                driver = make_driver ();
                on_close = (fun () -> incr closes);
              }
          in
          ignore
            (Eio.Fiber.first
               (fun () ->
                 (try Server.serve ~sw ~clock ~driver_for listener
                  with Eio.Cancel.Cancelled _ -> ());
                 `Served)
               (fun () ->
                 (match
                    Server.connect ~sw ~net ~clock ~workspace:"/ws" bind
                  with
                 | Ok d -> (
                     match
                       Client.follow_session ~sw (make_client d) session_id
                         ~from:`Beginning
                     with
                     | Ok _feed -> () (* left open across the cancellation *)
                     | Error e -> failf "follow: %a" Error.pp e)
                 | Error e -> failf "connect: %a" Server.Error.pp e);
                 Eio.Time.sleep clock 0.05;
                 `Client));
          (* Cancelling the serve branch tore down the still-open feed connection
             via its on_release, so on_close ran for every bound connection. *)
          is_true ~msg:"cancellation bound at least the feed connection"
            (!opens >= 1);
          equal int ~msg:"cancellation closed every bound connection once"
            !opens !closes);
      test "a duplicate handshake on one connection takes no second lease"
        (fun () ->
          let opens = ref 0 and closes = ref 0 in
          let driver_for ~workspace:_ ~environment:_ =
            incr opens;
            Ok
              {
                Server.workspace = Some "/ws";
                driver = make_driver ();
                on_close = (fun () -> incr closes);
              }
          in
          with_driver_for_server ~driver_for
            (fun ~env:_ ~net ~sw:_ ~clock ~dir ~bind:_ ->
              Eio.Switch.run (fun conn_sw ->
                  let client = pinned ~net ~dir ~sw:conn_sw in
                  let s1, _ =
                    raw_post client ~sw:conn_sw "/handshake" (handshake_body ())
                  in
                  let s2, _ =
                    raw_post client ~sw:conn_sw "/handshake" (handshake_body ())
                  in
                  equal int ~msg:"the first handshake binds (200)" 200 s1;
                  equal int ~msg:"the duplicate is a no-op echo (200)" 200 s2;
                  equal int
                    ~msg:
                      "driver_for ran once — the duplicate took no second lease"
                    1 !opens);
              (* Once the connection closes, the single binding closes exactly
                 once: no leaked lease pins the instance. *)
              Eio.Time.sleep clock 0.1;
              equal int ~msg:"the one binding closed exactly once" 1 !closes));
    ]

(* A composite driver in the shape the daemon's registry hands back: its
   session-cone fields route by the payload's session id (session→instance),
   independent of the connection's bound workspace. Here [possibly_mutating]
   stands in for that routing probe. *)
let session_routing_group =
  group "session→instance routing"
    [
      test "a session-cone call routes by session id, not the bound workspace"
        (fun () ->
          let a_hits = ref 0 and b_hits = ref 0 in
          (* The registry's session→instance resolution, as a map. *)
          let route session =
            match Session.Id.to_string session with "s-in-b" -> `B | _ -> `A
          in
          let composite : Driver.t =
            let session =
              {
                default_session with
                Driver.Session.possibly_mutating =
                  (fun ~session ->
                    match route session with
                    | `A ->
                        incr a_hits;
                        true
                    | `B ->
                        incr b_hits;
                        false);
              }
            in
            make_driver ~session ()
          in
          (* driver_for binds workspace A, but hands back the composite whose
             session cone routes independently. *)
          let driver_for ~workspace:_ ~environment:_ =
            Ok
              {
                Server.workspace = Some "/ws/a";
                driver = composite;
                on_close = (fun () -> ());
              }
          in
          with_driver_for_server ~driver_for
            (fun ~env:_ ~net ~sw ~clock ~dir:_ ~bind ->
              let remote =
                match
                  Server.connect ~sw ~net ~clock ~workspace:"/ws/a" bind
                with
                | Ok d -> make_client d
                | Error e -> failf "connect: %a" Server.Error.pp e
              in
              (* Bound to A, but a call naming a session that resolves to B must
                 reach B's instance. *)
              is_false ~msg:"the B-routed session reached B's driver"
                (Client.possibly_mutating remote ~session:(sid "s-in-b"));
              is_true ~msg:"an A-routed session reached A's driver"
                (Client.possibly_mutating remote ~session:(sid "s-in-a"));
              equal int ~msg:"the B session routed to B exactly once" 1 !b_hits;
              equal int ~msg:"the A session routed to A exactly once" 1 !a_hits));
      test
        "a lifecycle write routes by the session's owner, not the bound \
         workspace (4a gate catch)" (fun () ->
          let a_renames = ref 0 and b_renames = ref 0 in
          let route session =
            match Session.Id.to_string session with "s-in-b" -> `B | _ -> `A
          in
          let composite : Driver.t =
            let lifecycle =
              {
                default_lifecycle with
                Driver.Lifecycle.rename =
                  (fun ~session ~title:_ ->
                    match route session with
                    | `A ->
                        incr a_renames;
                        Ok ()
                    | `B ->
                        incr b_renames;
                        Ok ());
              }
            in
            make_driver ~lifecycle ()
          in
          let driver_for ~workspace:_ ~environment:_ =
            Ok
              {
                Server.workspace = Some "/ws/a";
                driver = composite;
                on_close = (fun () -> ());
              }
          in
          with_driver_for_server ~driver_for
            (fun ~env:_ ~net ~sw ~clock ~dir:_ ~bind ->
              let remote =
                match
                  Server.connect ~sw ~net ~clock ~workspace:"/ws/a" bind
                with
                | Ok d -> make_client d
                | Error e -> failf "connect: %a" Server.Error.pp e
              in
              ok (Client.rename remote ~session:(sid "s-in-b") ~title:"x");
              ok (Client.rename remote ~session:(sid "s-in-a") ~title:"y");
              equal int ~msg:"the B-owned session's rename reached B" 1
                !b_renames;
              equal int ~msg:"the A-owned session's rename reached A" 1
                !a_renames));
    ]

(* [Discovery.locate] is the find-or-spawn convergence state machine over injected
   effects; each branch of the race is pinned deterministically here, the
   real two-process end-to-end path in [serve.t]. The connection type is a fake
   token string. *)
let find_or_spawn_group =
  group "find-or-spawn convergence"
    [
      test "a live, identity-matched daemon attaches without spawning"
        (fun () ->
          let spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () -> `Found (a_discovery ~socket:"/s" ~pid:1 ()))
              ~claim_free:(fun () -> false)
              ~probe:(fun _ -> Some "driver")
              ~identity_ok:(fun _ -> true)
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Attached "driver" ->
              equal int ~msg:"a reachable daemon is never respawned" 0 !spawned
          | _ -> fail "a live matched daemon must attach");
      test
        "a MENTAT_DAEMON_SOCKET override attaches to the named socket without \
         reading the file, checking identity, or spawning" (fun () ->
          let spawned = ref 0 and reads = ref 0 in
          match
            Server.Discovery.locate_with_override
              ~socket_override:(fun () -> `Reached "override-driver")
              ~read:(fun () ->
                incr reads;
                `Absent)
              ~claim_free:(fun () -> fail "the claim must not be consulted")
              ~probe:(fun _ -> fail "the discovery probe must not run")
              ~identity_ok:(fun _ ->
                fail "no identity check beyond the handshake")
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Attached "override-driver" ->
              equal int ~msg:"the override never spawns" 0 !spawned;
              equal int ~msg:"the override never reads the discovery file" 0
                !reads
          | _ -> fail "the override must attach straight to the named socket");
      test
        "a MENTAT_DAEMON_SOCKET override naming an unreachable socket is a \
         definite failure, never a spawn or file read" (fun () ->
          let spawned = ref 0 and reads = ref 0 in
          match
            Server.Discovery.locate_with_override
              ~socket_override:(fun () -> `Set_unreachable)
              ~read:(fun () ->
                incr reads;
                `Absent)
              ~claim_free:(fun () -> fail "the claim must not be consulted")
              ~probe:(fun _ -> fail "the discovery probe must not run")
              ~identity_ok:(fun _ -> fail "no identity check")
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Timeout ->
              equal int ~msg:"a dead override never spawns" 0 !spawned;
              equal int ~msg:"a dead override never reads the discovery file" 0
                !reads
          | _ -> fail "an unreachable override must not fall back to discovery");
      test "a stale file with a free claim is reclaimed by one spawn" (fun () ->
          let up = ref false and spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () -> `Found (a_discovery ~socket:"/s" ~pid:1 ()))
              ~claim_free:(fun () -> not !up)
              ~probe:(fun _ -> if !up then Some "driver" else None)
              ~identity_ok:(fun _ -> true)
              ~spawn:(fun () ->
                incr spawned;
                up := true)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Attached "driver" ->
              equal int ~msg:"the stale file is reclaimed by exactly one spawn"
                1 !spawned
          | _ -> fail "a stale daemon file must be reclaimed");
      test
        "a starting daemon (held claim, no socket yet) is polled, not spawned"
        (fun () ->
          let spawned = ref 0 and probes = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () -> `Found (a_discovery ~socket:"/s" ~pid:1 ()))
              ~claim_free:(fun () -> false)
              ~probe:(fun _ ->
                incr probes;
                if !probes >= 3 then Some "driver" else None)
              ~identity_ok:(fun _ -> true)
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Attached "driver" ->
              equal int ~msg:"a starting daemon is never spawned over" 0
                !spawned
          | _ -> fail "a starting daemon must be polled to readiness");
      test "an absent file spawns and converges" (fun () ->
          let up = ref false and spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () ->
                if !up then `Found (a_discovery ~socket:"/s" ~pid:1 ())
                else `Absent)
              ~claim_free:(fun () -> true)
              ~probe:(fun _ -> Some "driver")
              ~identity_ok:(fun _ -> true)
              ~spawn:(fun () ->
                incr spawned;
                up := true)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Attached "driver" ->
              equal int ~msg:"an absent file spawns once" 1 !spawned
          | _ -> fail "an absent file must spawn a daemon");
      test "a live daemon with a mismatched identity is refused, not spawned"
        (fun () ->
          let spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () -> `Found (a_discovery ~socket:"/s" ~pid:1 ()))
              ~claim_free:(fun () -> false)
              ~probe:(fun _ -> Some "driver")
              ~identity_ok:(fun _ -> false)
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Mismatch _ ->
              equal int ~msg:"a mismatched live daemon is never auto-killed" 0
                !spawned
          | _ -> fail "a mismatched live daemon must be refused");
      test "a foreign file whose claim is held is refused" (fun () ->
          let spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () -> `Foreign "unknown v")
              ~claim_free:(fun () -> false)
              ~probe:(fun _ -> Some "driver")
              ~identity_ok:(fun _ -> true)
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Foreign_held ->
              equal int ~msg:"a held foreign daemon is never clobbered" 0
                !spawned
          | _ -> fail "a foreign file with a held claim must be refused");
      test
        "a mismatched daemon that answers during the poll is refused, not \
         attached" (fun () ->
          (* After we spawn, a different-identity daemon can win the claim and
             answer first; the poll must refuse it, not attach silently. *)
          let up = ref false and spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () ->
                if !up then `Found (a_discovery ~socket:"/s" ~pid:1 ())
                else `Absent)
              ~claim_free:(fun () -> true)
              ~probe:(fun _ -> if !up then Some "driver" else None)
              ~identity_ok:(fun _ -> false)
              ~spawn:(fun () ->
                incr spawned;
                up := true)
              ~sleep:(fun () -> ())
              ~poll_budget:10
          with
          | `Mismatch _ ->
              equal int ~msg:"spawned once, then refused the foreign winner" 1
                !spawned
          | _ ->
              fail
                "a mismatched daemon answering during the poll must be refused");
      test "the outer retry recovers a winner that died before writing the file"
        (fun () ->
          (* First attempt: the recorded daemon never answers within the budget
             (claim held, socket dead); the whole attempt is retried once and the
             reclaimed daemon is up by then — no spawn (the claim was never free). *)
          let probes = ref 0 and spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () -> `Found (a_discovery ~socket:"/s" ~pid:1 ()))
              ~claim_free:(fun () -> false)
              ~probe:(fun _ ->
                incr probes;
                if !probes > 3 then Some "driver" else None)
              ~identity_ok:(fun _ -> true)
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:2
          with
          | `Attached "driver" ->
              equal int ~msg:"the retry never spawned (claim held)" 0 !spawned
          | _ -> fail "the outer retry must recover the reclaimed daemon");
      test "an unreachable daemon exhausts both attempts and reports Timeout"
        (fun () ->
          let spawned = ref 0 in
          match
            Server.Discovery.locate
              ~read:(fun () -> `Absent)
              ~claim_free:(fun () -> true)
              ~probe:(fun _ -> None)
              ~identity_ok:(fun _ -> true)
              ~spawn:(fun () -> incr spawned)
              ~sleep:(fun () -> ())
              ~poll_budget:3
          with
          | `Timeout ->
              equal int ~msg:"both attempts spawned before giving up" 2 !spawned
          | _ -> fail "an unreachable spawned daemon must time out");
    ]

let web_edge_group =
  group "browser edge"
    [
      test "GET /health is pre-auth and content-free on the browser edge"
        (fun () ->
          with_web_server (fun ~net ~sw ~port ~token:_ ->
              let status, _, body = web_get ~net ~port ~sw "/health" in
              equal int ~msg:"health is reachable pre-auth" 200 status;
              equal string ~msg:"health is content-free" "ok" body));
      test "a valid token is exchanged for a SameSite=Strict HttpOnly cookie"
        (fun () ->
          with_web_server (fun ~net ~sw ~port ~token ->
              let status, headers, _ =
                web_get ~net ~port ~sw
                  (Printf.sprintf "/?t=%s" (Server.Token.to_string token))
              in
              equal int ~msg:"the exchange is a 303 redirect" 303 status;
              (match Cohttp.Header.get headers "set-cookie" with
              | None -> fail "the exchange sets no cookie"
              | Some sc ->
                  is_true ~msg:"the cookie is HttpOnly"
                    (contains_substring "HttpOnly" sc);
                  is_true ~msg:"the cookie is SameSite=Strict"
                    (contains_substring "SameSite=Strict" sc));
              match Cohttp.Header.get headers "location" with
              | None -> fail "the exchange does not redirect"
              | Some loc ->
                  is_false ~msg:"the redirect drops the token from the URL"
                    (contains_substring "t=" loc)));
      test "the minted cookie authenticates and every response carries the CSP"
        (fun () ->
          with_web_server (fun ~net ~sw ~port ~token ->
              let cookie = exchange ~net ~port ~sw ~token in
              let status, headers, body =
                web_get ~net ~port ~sw ~headers:(cookie_header cookie) "/"
              in
              equal int ~msg:"a cookie'd request is served" 200 status;
              is_true ~msg:"the surface body is returned"
                (contains_substring "<body>ok</body>" body);
              match Cohttp.Header.get headers "content-security-policy" with
              | None -> fail "no CSP header on an HTML response"
              | Some csp ->
                  is_true ~msg:"CSP denies every default source class"
                    (contains_substring "default-src 'none'" csp);
                  is_true ~msg:"CSP forbids framing"
                    (contains_substring "frame-ancestors 'none'" csp)));
      test "no credential is unauthorized" (fun () ->
          with_web_server (fun ~net ~sw ~port ~token:_ ->
              let status, _, _ = web_get ~net ~port ~sw "/" in
              equal int ~msg:"no cookie and no token is a 401" 401 status));
      test "a wrong token is unauthorized (constant-time compare)" (fun () ->
          with_web_server (fun ~net ~sw ~port ~token:_ ->
              let status, _, _ = web_get ~net ~port ~sw "/?t=deadbeef" in
              equal int ~msg:"a non-matching token never exchanges" 401 status));
      test "a foreign Host is refused — the DNS-rebinding case" (fun () ->
          with_web_server (fun ~net ~sw ~port ~token ->
              let cookie = exchange ~net ~port ~sw ~token in
              let status, _, _ =
                web_get ~net ~port ~sw ~host:"evil.example.com"
                  ~headers:(cookie_header cookie) "/"
              in
              equal int
                ~msg:"a valid cookie under a foreign Host is still refused" 403
                status));
      test "a foreign Origin is refused on a state-changing POST — CSRF"
        (fun () ->
          with_web_server (fun ~net ~sw ~port ~token ->
              let cookie = exchange ~net ~port ~sw ~token in
              let headers =
                ("origin", "http://evil.example.com") :: cookie_header cookie
              in
              let status, _, _ =
                web_post ~net ~port ~sw ~headers ~body:"prompt=hi"
                  "/session/s/prompt"
              in
              equal int
                ~msg:"a forged cross-origin POST cannot reach the client" 403
                status));
      test "the SSE feed frames a committed id and the live region" (fun () ->
          with_web_server ~heartbeat_s:60.0 (fun ~net ~sw ~port ~token ->
              let cookie = exchange ~net ~port ~sw ~token in
              let status, headers, body =
                web_get ~net ~port ~sw ~headers:(cookie_header cookie)
                  "/session/abc/feed?from=beginning"
              in
              equal int ~msg:"the feed is a 200 stream" 200 status;
              (match Cohttp.Header.get headers "content-type" with
              | Some ct ->
                  is_true ~msg:"the feed is text/event-stream"
                    (contains_substring "text/event-stream" ct)
              | None -> fail "no content-type on the feed");
              is_true ~msg:"the committed frame carries its position as id:"
                (contains_substring "id: 0" body);
              is_true ~msg:"the committed frame's html rides a data: line"
                (contains_substring "data: <div data-swap=\"append\">fact</div>"
                   body);
              is_true ~msg:"the live-region morph is a bare data: frame (no id)"
                (contains_substring "data: <div id=\"live\"></div>" body)));
      test "the bootstrap token is single-use — a second exchange fails"
        (fun () ->
          with_web_server (fun ~net ~sw ~port ~token ->
              let url =
                Printf.sprintf "/?t=%s" (Server.Token.to_string token)
              in
              let first, _, _ = web_get ~net ~port ~sw url in
              equal int ~msg:"the first exchange succeeds" 303 first;
              let second, _, _ = web_get ~net ~port ~sw url in
              equal int
                ~msg:
                  "a second exchange of the invalidated token is unauthorized"
                401 second));
      test
        "the exchange consumes and rotates — the republished successor is live"
        (fun () ->
          let rotated = ref None in
          with_web_server
            ~on_rotate:(fun t -> rotated := Some t)
            (fun ~net ~sw ~port ~token ->
              let first, _, _ =
                web_get ~net ~port ~sw
                  (Printf.sprintf "/?t=%s" (Server.Token.to_string token))
              in
              equal int ~msg:"the bootstrap token exchanges" 303 first;
              match !rotated with
              | None -> fail "the exchange handed no successor to on_rotate"
              | Some successor ->
                  let second, headers, _ =
                    web_get ~net ~port ~sw
                      (Printf.sprintf "/?t=%s"
                         (Server.Token.to_string successor))
                  in
                  equal int ~msg:"the successor token exchanges in turn" 303
                    second;
                  is_true ~msg:"the second exchange mints its own cookie"
                    (Option.is_some (Cohttp.Header.get headers "set-cookie"))));
      test "an exchanged cookie survives later rotations (a second entry)"
        (fun () ->
          let rotated = ref None in
          with_web_server
            ~on_rotate:(fun t -> rotated := Some t)
            (fun ~net ~sw ~port ~token ->
              let cookie = exchange ~net ~port ~sw ~token in
              (match !rotated with
              | None -> fail "the exchange handed no successor to on_rotate"
              | Some successor ->
                  let second, _, _ =
                    web_get ~net ~port ~sw
                      (Printf.sprintf "/?t=%s"
                         (Server.Token.to_string successor))
                  in
                  equal int ~msg:"a second entry rides the successor" 303 second);
              let status, _, _ =
                web_get ~net ~port ~sw ~headers:(cookie_header cookie) "/"
              in
              equal int ~msg:"the first cookie still authenticates" 200 status));
      test "the exchange redirect cannot leave the origin (open redirect)"
        (fun () ->
          with_web_server (fun ~net ~sw ~port ~token ->
              let status, headers, _ =
                web_get ~net ~port ~sw
                  (Printf.sprintf "//evil.example.com/?t=%s"
                     (Server.Token.to_string token))
              in
              equal int ~msg:"the exchange itself succeeds" 303 status;
              match Cohttp.Header.get headers "location" with
              | None -> fail "the exchange does not redirect"
              | Some loc ->
                  equal string
                    ~msg:"a protocol-relative target is pinned to the root" "/"
                    loc));
      test "an attach fault surfaces as a terminal SSE error event" (fun () ->
          let faulting : Server.Web.handler =
            {
              Server.Web.respond = stub_handler.Server.Web.respond;
              stream =
                (fun ~sw:_ ~session:_ ~from:_ ~emit:_ -> Error "attach failed");
            }
          in
          with_web_server ~handler:faulting ~heartbeat_s:60.0
            (fun ~net ~sw ~port ~token ->
              let cookie = exchange ~net ~port ~sw ~token in
              let _status, _headers, body =
                web_get ~net ~port ~sw ~headers:(cookie_header cookie)
                  "/session/abc/feed?from=beginning"
              in
              is_true ~msg:"the fault rides a terminal event: error frame"
                (contains_substring "event: error" body);
              is_true ~msg:"the error message is the SSE data"
                (contains_substring "data: attach failed" body)));
    ]

let () =
  Random.self_init ();
  run "mentat.server"
    [
      web_edge_group;
      discovery_group;
      driver_for_group;
      session_routing_group;
      find_or_spawn_group;
      feed_group;
      reads_group;
      commands_group;
      edge_group;
      introspection_group;
      m4_group;
      idempotency_group;
      teardown_group;
      coverage_group;
      corpus_group;
      revert_vocab_group;
      endpoint_corpus_group;
      live_stream_group;
      live_resume_group;
      live_tail_group;
      live_heartbeat_group;
    ]
