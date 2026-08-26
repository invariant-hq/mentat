(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_store], durable persistence. The
   library is all effect: every test opens its handles over a fresh temp
   store root, does real filesystem IO and POSIX locking through the facade,
   and removes its root on the way out. Corruption is planted by editing the
   store tree directly (garbage bytes, directories where files belong,
   deleted blobs) — never through the API, which refuses to write it.

   The generated-input laws (document round-trip, blob store/read) run as
   seeded loops over one store, drawn from [WINDTRAP_SEED] so the stability
   loop varies them — the same technique as the workspace-io suite's elision
   law — with the interesting edges (hostile ids, empty and NUL-laden bytes)
   pinned deterministically on every run. *)

open Windtrap
module Store = Mentat_store
module Capture = Mentat_store.Capture
module Session = Mentat_session
module Mutation = Mentat_mutation
module Edit = Mentat_edit
module W = Mentat_workspace
module Review = Mentat_review
module Llm = Mentat_llm
module Tool = Mentat_tool
module Permission = Mentat_permission
module Sandbox = Mentat_sandbox
module Abs = Lpath.Abs
module Rel = Lpath.Rel

let doc_lock_holder_mode = "--store-doc-lock-holder"

(* POSIX record locks are per process.  This private executable mode gives the
   cancellation test a genuine cross-process holder without adding a seam to
   the store implementation.  The holder owns the lock until its stdin closes.
*)
let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) doc_lock_holder_mode
  then (
    let fd =
      Unix.openfile Sys.argv.(2)
        [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
        0o600
    in
    Unix.lockf fd Unix.F_LOCK 0;
    print_endline "ready";
    (match input_char stdin with _ -> () | exception End_of_file -> ());
    Unix.lockf fd Unix.F_ULOCK 0;
    Unix.close fd;
    exit 0)

(* {2 Helpers} *)

let abs = Abs.of_string_exn
let rel = Rel.of_string_exn
let sid = Session.Id.of_string
let time ms = Session.Time.of_unix_ms (Int64.of_int ms)
let session_id_value = Testable.make ~pp:Session.Id.pp ~equal:Session.Id.equal
let digest_value = Testable.make ~pp:Mentat_digest.pp ~equal:Mentat_digest.equal

let content_ref_value =
  Testable.make ~pp:Mentat_digest.Content_ref.pp
    ~equal:Mentat_digest.Content_ref.equal

let event_value =
  Testable.make ~pp:Mutation.Event.pp ~equal:Mutation.Event.equal

let owner_value =
  Testable.make ~pp:Store.Run_lock.Owner.pp ~equal:Store.Run_lock.Owner.equal

let claim_id_value =
  Testable.make ~pp:Session.Tool_claim.Id.pp ~equal:Session.Tool_claim.Id.equal

let ok_store msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Session.Error.pp error

let ok_mutation msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Mutation.Error.pp error

(* [append] and [append_edit] now return the advanced mutation-state anchor. At
   a statement-position site the returned state is deliberately dropped — matched
   explicitly against [Mutation.State.t], never ignored, so a later shape change
   surfaces here rather than passing silently. A site that needs the state binds
   it through {!ok_mutation}. *)
let ok_append msg = function
  | Ok (_ : Mutation.State.t) -> ()
  | Error error -> failf "%s: %a" msg Store.Mutation.Error.pp error

let ok_attachment msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Attachment.Error.pp error

let ok_review msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Review.Error.pp error

let ok_session msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Session.Error.pp error

let write_file path contents =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel contents)

let append_raw path bytes =
  let channel =
    Out_channel.open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path
  in
  Fun.protect
    ~finally:(fun () -> Out_channel.close channel)
    (fun () -> Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let windtrap_seed () =
  match Sys.getenv_opt "WINDTRAP_SEED" with
  | Some value -> ( try int_of_string (String.trim value) with _ -> 0x570125)
  | None -> 0x570125

(* {2 Worlds}

   Every test opens its own handles over a fresh temp root, removed even on
   failure. [with_store] provides the session and mutation handles over one
   root; [with_review] the review handle; the root-identity test opens its
   own pair of roots. *)

let ok_open msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Store.Error.pp error

(* One [open_] returns the single root every domain view operates over; the
   harness binds [session], [mutation], and [review] all to that one root. *)
let open_root ~sw ~fs base =
  ok_open "open store" (Store.open_ ~sw (Eio.Path.( / ) fs base))

let with_store name fn =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let base = Unix.realpath (temp_dir ~prefix:("mentat-store-" ^ name) ()) in
  Eio.Switch.run @@ fun sw ->
  let root = open_root ~sw ~fs base in
  fn ~sw ~base ~session:root ~mutation:root

let with_two_stores name fn =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let base = Unix.realpath (temp_dir ~prefix:("mentat-store-" ^ name) ()) in
  Eio.Switch.run @@ fun sw ->
  let first = open_root ~sw ~fs base in
  let second = open_root ~sw ~fs base in
  fn ~sw ~base ~session:first ~mutation:second

let rec waitpid_nointr pid =
  match Unix.waitpid [] pid with
  | waited, status -> (waited, status)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid

let with_doc_lock_holder path fn =
  let child_stdin, parent_stdin = Unix.pipe ~cloexec:true () in
  let parent_stdout, child_stdout = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; doc_lock_holder_mode; path |]
      child_stdin child_stdout Unix.stderr
  in
  Unix.close child_stdin;
  Unix.close child_stdout;
  let input = Unix.in_channel_of_descr parent_stdout in
  let output = Unix.out_channel_of_descr parent_stdin in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr output;
      close_in_noerr input;
      match waitpid_nointr pid with
      | waited, Unix.WEXITED 0 when waited = pid -> ()
      | waited, status ->
          failf "lock holder %d returned unexpected status for pid %d: %s"
            waited pid
            (match status with
            | Unix.WEXITED code -> Printf.sprintf "exit %d" code
            | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
            | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal))
    (fun () ->
      match input_line input with
      | "ready" -> fn ()
      | line -> failf "unexpected lock-holder greeting: %s" line
      | exception End_of_file -> fail "lock holder exited before readiness")

let with_review name fn =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let base = Unix.realpath (temp_dir ~prefix:("mentat-review-" ^ name) ()) in
  Eio.Switch.run @@ fun sw ->
  let root = open_root ~sw ~fs base in
  fn ~base ~review:root

(* {2 Session fixtures} *)

let cwd = abs "/workspace"

let user_event text =
  Session.Event.message_appended (Llm.Message.user_text text)

let session_fixture ?title ?(events = []) ~id ~at () =
  let session =
    Session.create ~id:(sid id) ?title ~cwd ~created_at:(time at) ()
  in
  List.fold_left
    (fun session event ->
      ok_session "append event" (Session.append event session))
    session events

let tool_turn = Session.Turn.Id.of_string "turn-1"
let tool_provider = Llm.Provider.make "test"
let tool_api = Llm.Model.Api.make "test"

let tool_model =
  Llm.Model.make ~provider:tool_provider ~api:tool_api ~id:"model"

let tool_declaration =
  Llm.Tool.make ~name:"edit" ~input_schema:Llm.Tool.no_input_schema ()

let tool_contract =
  Session.Contract.make ~mode:Session.Contract.Mode.Build ~model:tool_model
    ~declarations:[ tool_declaration ] ~policy:Permission.Policy.default
    ~review:Permission.Review_behavior.Enforce
    ~sandbox:(Sandbox.identity Sandbox.direct)
    ()

let tool_turn_started =
  Session.Turn.make ~id:tool_turn ~origin:Session.Turn.Origin.User
    ~input:(Session.Turn.Input.user_text "edit")
    ~max_steps:8 ~contract:tool_contract ()

(* A media-bearing turn: a user prompt whose content references an attachment
   blob by content reference, the document half of image input. *)
let attachment_image_bytes = "\x89PNG\r\n\x1a\nfake image bytes for a session"

let attachment_ref =
  Mentat_digest.Content_ref.of_contents attachment_image_bytes

let media_turn_started =
  Session.Turn.make
    ~id:(Session.Turn.Id.of_string "turn-media")
    ~origin:Session.Turn.Origin.User
    ~input:
      (Session.Turn.Input.user
         [
           Llm.Content.text "look at this";
           Llm.Content.media ~media_type:"image/png" (`Ref attachment_ref);
         ])
    ~max_steps:8 ~contract:tool_contract ()

let media_events = [ Session.Event.turn_started media_turn_started ]

let tool_call call_id =
  Llm.Tool.Call.make ~id:call_id ~name:"edit" ~input:(Jsont.Json.object' []) ()

let tool_claim_started source =
  Session.Tool_claim.Started.make ~turn:tool_turn ~stage:Tool.Stage.Direct
    ~call:source ~input:(Jsont.Json.object' []) ~requests:[]

let provider_response_events ~request_key sources =
  let provider =
    Session.Provider_request.Started.make ~turn:tool_turn
      ~request_digest:(Mentat_digest.string ("request:" ^ request_key))
  in
  let response =
    Llm.Response.make ~model:tool_model
      (Llm.Message.Assistant.make
         (List.map Llm.Message.Assistant.tool_call sources))
  in
  [
    Session.Event.turn_started tool_turn_started;
    Session.Event.provider_requested provider;
    Session.Event.provider_settled
      (Session.Provider_request.Settled.responded
         ~id:(Session.Provider_request.Started.id provider)
         response);
  ]

let open_claim_fixture ~call_id =
  let source = tool_call call_id in
  let claim = tool_claim_started source in
  ( provider_response_events ~request_key:call_id [ source ]
    @ [ Session.Event.tool_claimed claim ],
    claim )

let recovered_claim_fixture () =
  let first_source = tool_call "call-recovery-first" in
  let second_source = tool_call "call-recovery-second" in
  let first = tool_claim_started first_source in
  let second = tool_claim_started second_source in
  ( provider_response_events ~request_key:"recovery"
      [ first_source; second_source ]
    @ [
        Session.Event.tool_claimed first;
        Session.Event.tool_settled
          (Session.Tool_claim.Settled.ambiguous
             ~id:(Session.Tool_claim.Started.id first));
        Session.Event.tool_claimed second;
      ],
    first,
    second )

let standard_claim_events, tool_claim = open_claim_fixture ~call_id:"call-1"
let tool_claim_id = Session.Tool_claim.Started.id tool_claim
let open_claim_events () = standard_claim_events

let encode_session session =
  match Jsont_bytesrw.encode_string Session.jsont session with
  | Ok text -> text
  | Error message -> failf "session does not encode: %s" message

let document_path base id =
  Filename.concat base ("sessions/" ^ id ^ "/session.json")

let ledger_path base id =
  Filename.concat base ("sessions/" ^ id ^ "/ledger.jsonl")

(* {2 Edit and mutation fixtures}

   [Mentat_edit.Result.t] values are minted the only honest way — through
   [Mentat_edit.apply] over an in-memory IO — so [append_edit] receives the
   same authoritative value production hands it. *)

let ws_root = W.Root.of_dir cwd
let workspace = W.single ws_root
let wpath text = W.Path.make ~root_key:(W.Root.key ws_root) (rel text)

let fake_io fs =
  {
    Edit.Apply.with_write_lock = (fun _paths f -> f ());
    revalidate = (fun path -> Ok path);
    read =
      (fun path ->
        match List.find_opt (fun (p, _) -> W.Path.equal p path) fs with
        | Some (_, contents) -> Ok (Edit.Observed.Text contents)
        | None -> Ok Edit.Observed.Missing);
    commit = (fun ~path:_ ~before:_ ~after:_ -> Ok ());
  }

let apply_plan fs = function
  | Error error -> failf "plan construction failed: %a" Edit.Error.pp error
  | Ok plan -> (
      match Edit.apply ~io:(fake_io fs) ~workspace plan with
      | Ok result -> result
      | Error error -> failf "apply failed: %a" Edit.Apply_error.pp error)

let created_result ~path ~contents =
  apply_plan [] (Edit.create ~path:(wpath path) ~contents)

let rewritten_result ~path ~before ~after =
  apply_plan
    [ (wpath path, before) ]
    (Edit.rewrite ~path:(wpath path) ~before ~after)

let claim_id _ = tool_claim_id
let turn = tool_turn

let edit_event_for ?(ordinal = 0) ~turn ~claim result =
  Mutation.Event.of_edit ~turn ~claim ~ordinal ~checkpoint:None result

let edit_event ?ordinal ~claim result =
  edit_event_for ?ordinal ~turn ~claim:(claim_id claim) result

(* The blob-free arm the plain append admits — used wherever the event
   content is incidental to the store law under test. *)
let observed_event ~claim paths =
  Mutation.Event.tool_observed ~turn ~claim:(claim_id claim)
    (List.map wpath paths)

let checkpoint_fact ~boundary =
  let snapshot =
    Mutation.Checkpoint.Snapshot.make ~backend:"test" ~reference:"before-revert"
  in
  let capture =
    Mutation.Checkpoint.Capture.Available { snapshot; excluded = 0 }
  in
  Mutation.Checkpoint.make ~boundary ~capture

let checkpoint_event boundary =
  Mutation.Event.checkpoint (checkpoint_fact ~boundary)

let before_revert_event plan =
  let revert = (Mutation.Revert.Plan.started plan).Mutation.Revert.Started.id in
  checkpoint_event (Mutation.Checkpoint.Before_revert revert)

let path_value = Testable.make ~pp:W.Path.pp ~equal:W.Path.equal
let owner label = Store.Run_lock.Owner.make ~label ()

(* [read] returns the validated state; the tests compare the event projection. *)
let read_events mutation id =
  let document =
    ok_store "load for mutation read" (Store.Session.load mutation (sid id))
  in
  Mutation.State.events
    (ok_mutation "read" (Store.Mutation.read mutation document))

let acquire ~sw store id =
  match
    Store.Run_lock.try_acquire ~sw store ~session:(sid id)
      ~owner:(owner ("test-" ^ id))
  with
  | Ok guard -> guard
  | Error (`Held _) -> fail "the fence is unexpectedly held"
  | Error (`Io io) -> failf "fence acquisition failed: %a" Store.Io.pp io

(* The fenced world most mutation tests need: a created session plus its
   guard. *)
let with_fenced name fn =
  with_store name @@ fun ~sw ~base ~session ~mutation ->
  let id = "s-" ^ name in
  let document =
    ok_store "create"
      (Store.Session.create session
         (session_fixture ~id ~at:1_000 ~events:(open_claim_events ()) ()))
  in
  let guard = acquire ~sw session id in
  fn ~sw ~base ~session ~mutation ~id ~guard ~document

let blob_files base id =
  let dir = Filename.concat base ("sessions/" ^ id ^ "/blobs") in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun shard ->
        let shard_dir = Filename.concat dir shard in
        if Sys.is_directory shard_dir then
          Sys.readdir shard_dir |> Array.to_list |> List.sort String.compare
          |> List.map (Filename.concat shard_dir)
        else [])

let blob_file_with base id contents =
  List.find_opt
    (fun file -> String.equal (read_file file) contents)
    (blob_files base id)

(* {2 Review fixtures} *)

let review_root ?(root = "wsroot") () = W.Root.Key.of_string_exn root

let review_key ?(root = "wsroot") ?(base = "main") () =
  Store.Review.Key.make ~root:(W.Root.Key.of_string_exn root) ~base

(* The record's own base is authoritative — [create] derives the storage key
   from it (B7) — so the fixtures keep the record base and the lookup key base
   deliberately aligned, and misalign them only to probe the agreement check. *)
let persist_record ?(approve = true) ?(base = "main") () =
  let file =
    match
      Review.Feature.File.make ~path:(rel "lib/record.ml")
        ~before:(Some "let x = 1\n") ~after:(Some "let x = 2\n") ()
    with
    | Ok file -> file
    | Error error -> failf "review file: %a" Review.Error.pp error
  in
  let feature = Review.Feature.v ~base ~tip:"WORKTREE" [ file ] in
  let review = Review.v ~feature ~crs:[] in
  let review =
    match
      Review.mark_reviewed review (Review.Scope.File (rel "lib/record.ml"))
    with
    | Ok review -> if approve then Review.approve review else review
    | Error error -> failf "mark: %a" Review.Error.pp error
  in
  Review.Persist.of_review review

let persist_json record =
  match Jsont_bytesrw.encode_string Review.Persist.jsont record with
  | Ok text -> text
  | Error message -> failf "persist does not encode: %s" message

(* Session documents. *)

let create_load_round_trip_is_byte_exact () =
  with_store "roundtrip" @@ fun ~sw:_ ~base ~session:store ~mutation:_ ->
  let supplied =
    session_fixture ~id:"s-round" ~title:"Round trip" ~at:1_000
      ~events:[ user_event "Hello."; user_event "Again." ]
      ()
  in
  let created = ok_store "create" (Store.Session.create store supplied) in
  let encoded = encode_session supplied in
  equal string
    ~msg:"the on-disk document is the exact supplied encoding plus one newline"
    (encoded ^ "\n")
    (read_file (document_path base "s-round"));
  let loaded = ok_store "load" (Store.Session.load store (sid "s-round")) in
  equal string ~msg:"the loaded session re-encodes byte-identically" encoded
    (encode_session (Store.Session.Document.session loaded));
  equal digest_value ~msg:"created and loaded revisions agree"
    (Store.Session.Document.revision created)
    (Store.Session.Document.revision loaded);
  equal session_id_value ~msg:"the document carries the session's id"
    (sid "s-round")
    (Store.Session.Document.id loaded)

let commit_is_cas_with_both_digests () =
  with_store "cas" @@ fun ~sw ~base ~session:store ~mutation:_ ->
  let s0 = session_fixture ~id:"s-cas" ~at:1_000 () in
  let doc0 = ok_store "create" (Store.Session.create store s0) in
  (match Store.Session.create store s0 with
  | Error (Store.Session.Error.Already_exists id) ->
      equal session_id_value ~msg:"a second create names the existing id"
        (sid "s-cas") id
  | Ok _ -> fail "a second create must not replace the document"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error);
  (* An existing session is committed under its run fence. *)
  let guard = acquire ~sw store "s-cas" in
  let s1 = Session.touch (time 2_000) s0 in
  let doc1 =
    ok_store "commit" (Store.Session.commit store ~fence:guard doc0 s1)
  in
  equal string ~msg:"the commit landed the exact new encoding"
    (encode_session s1 ^ "\n")
    (read_file (document_path base "s-cas"));
  let s2 = Session.set_title (Some "Stale") s0 in
  (match Store.Session.commit store ~fence:guard doc0 s2 with
  | Error (Store.Session.Error.Conflict { id; expected; actual }) ->
      equal session_id_value ~msg:"the conflict names the session" (sid "s-cas")
        id;
      equal digest_value ~msg:"expected is the stale document's revision"
        (Store.Session.Document.revision doc0)
        expected;
      equal digest_value ~msg:"actual is the current on-disk revision"
        (Store.Session.Document.revision doc1)
        actual
  | Ok _ -> fail "a stale commit must conflict"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error);
  let reloaded = ok_store "reload" (Store.Session.load store (sid "s-cas")) in
  equal string ~msg:"the winner's bytes survive the losing commit"
    (encode_session s1)
    (encode_session (Store.Session.Document.session reloaded))

let corrupt_and_missing_documents_are_structured () =
  with_store "corrupt" @@ fun ~sw:_ ~base ~session:store ~mutation:_ ->
  (match Store.Session.load store (sid "s-absent") with
  | Error (Store.Session.Error.Not_found id) ->
      equal session_id_value ~msg:"a missing document is Not_found with its id"
        (sid "s-absent") id
  | Ok _ -> fail "an absent document must not load"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error);
  let (_ : Store.Session.Document.t) =
    ok_store "create"
      (Store.Session.create store (session_fixture ~id:"s-bad" ~at:1_000 ()))
  in
  write_file (document_path base "s-bad") "this is not a session document";
  (match Store.Session.load store (sid "s-bad") with
  | Error (Store.Session.Error.Corrupt fact) ->
      is_true ~msg:"the corruption is located at the document path"
        (String.ends_with ~suffix:"sessions/s-bad/session.json"
           (Store.Session.Corrupt.path fact));
      equal (option session_id_value)
        ~msg:"a load corruption carries the requested session id"
        (Some (sid "s-bad"))
        (Store.Session.Corrupt.id fact)
  | Ok _ -> fail "corrupt bytes must not decode"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error);
  Unix.mkdir (Filename.concat base "sessions/s-dir") 0o755;
  Unix.mkdir (document_path base "s-dir") 0o755;
  match Store.Session.load store (sid "s-dir") with
  | Error (Store.Session.Error.Corrupt fact) ->
      is_true ~msg:"a non-file target is Corrupt at its path"
        (String.ends_with ~suffix:"sessions/s-dir/session.json"
           (Store.Session.Corrupt.path fact));
      equal (option session_id_value)
        ~msg:"a non-file exact load retains the addressed id"
        (Some (sid "s-dir"))
        (Store.Session.Corrupt.id fact);
      equal string ~msg:"the non-file diagnosis is structural"
        "is not a regular file"
        (Store.Session.Corrupt.message fact)
  | Ok _ -> fail "a directory target must not load"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error

(* [scan] is exact: it returns every session, lifecycle notwithstanding — the
   lifecycle filtering, recency ordering, and limits the previous [list] carried
   are query policy that composes above this result. *)
let scan_returns_every_session_and_corrupt_facts () =
  with_store "scan" @@ fun ~sw:_ ~base ~session:store ~mutation:_ ->
  let create_with session =
    let (_ : Store.Session.Document.t) =
      ok_store "create" (Store.Session.create store session)
    in
    ()
  in
  let active id at = Session.touch (time at) (session_fixture ~id ~at:500 ()) in
  create_with (active "s-a" 3_000);
  create_with (active "s-b" 1_000);
  create_with (ok_session "archive" (Session.archive (active "s-c" 2_000)));
  create_with (ok_session "delete" (Session.delete (active "s-d" 4_000)));
  Unix.mkdir (Filename.concat base "sessions/ghost") 0o755;
  write_file (document_path base "ghost") "garbage bytes";
  let ids documents =
    List.sort String.compare
      (List.map
         (fun document ->
           Session.Id.to_string (Store.Session.Document.id document))
         documents)
  in
  let documents, corrupt = ok_store "scan" (Store.Session.scan store) in
  equal (list string)
    ~msg:"the exact scan returns every session, archived and deleted included"
    [ "s-a"; "s-b"; "s-c"; "s-d" ]
    (ids documents);
  match corrupt with
  | [ fact ] ->
      equal (option session_id_value)
        ~msg:"the corrupt fact parses the session id from the store path"
        (Some (sid "ghost"))
        (Store.Session.Corrupt.id fact);
      is_true ~msg:"the corrupt fact is located at the document path"
        (String.ends_with ~suffix:"sessions/ghost/session.json"
           (Store.Session.Corrupt.path fact))
  | facts -> failf "expected one corrupt fact, got %d" (List.length facts)

(* A non-empty [sessions/<id>/] with no [session.json] — a leftover ledger
   from a half-removed or damaged session — is never silently adopted by
   [create]. *)
let create_refuses_a_leftover_directory () =
  with_store "leftover" @@ fun ~sw:_ ~base ~session:store ~mutation:_ ->
  Unix.mkdir (Filename.concat base "sessions/leftover") 0o755;
  write_file
    (Filename.concat base "sessions/leftover/ledger.jsonl")
    "leftover ledger line\n";
  match
    Store.Session.create store (session_fixture ~id:"leftover" ~at:1_000 ())
  with
  | Error (Store.Session.Error.Corrupt fact) ->
      is_true ~msg:"the refusal locates the leftover directory"
        (String.includes ~affix:"sessions/leftover"
           (Store.Session.Corrupt.path fact))
  | Ok _ ->
      fail "create must refuse to adopt a non-empty leftover session directory"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error

(* [scan] surfaces a documentless non-empty session directory as a located
   corrupt fact, never a silent skip. *)
let scan_surfaces_leftover_directories () =
  with_store "leftover-scan" @@ fun ~sw:_ ~base ~session:store ~mutation:_ ->
  let (_ : Store.Session.Document.t) =
    ok_store "create"
      (Store.Session.create store (session_fixture ~id:"s-good" ~at:1_000 ()))
  in
  Unix.mkdir (Filename.concat base "sessions/leftover") 0o755;
  write_file
    (Filename.concat base "sessions/leftover/ledger.jsonl")
    "leftover ledger line\n";
  let documents, corrupt = ok_store "scan" (Store.Session.scan store) in
  equal int ~msg:"the healthy session still lists" 1 (List.length documents);
  match corrupt with
  | [ fact ] ->
      equal (option session_id_value)
        ~msg:"the leftover directory surfaces as a located corrupt fact"
        (Some (sid "leftover"))
        (Store.Session.Corrupt.id fact)
  | facts ->
      failf "expected the leftover directory as one corrupt fact, got %d"
        (List.length facts)

let remove_is_revision_checked_and_reclaims () =
  with_fenced "remove"
  @@ fun ~sw:_ ~base ~session:store ~mutation ~id ~guard ~document ->
  let result = created_result ~path:"a.ml" ~contents:"blob body\n" in
  ok_append "append_edit"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result)
       (edit_event ~claim:"claim-rm" result));
  is_true ~msg:"the session's blob landed before removal"
    (Option.is_some (blob_file_with base id "blob body\n"));
  let doc0 = ok_store "load" (Store.Session.load store (sid id)) in
  let s1 = Session.touch (time 2_000) (Store.Session.Document.session doc0) in
  let doc1 =
    ok_store "commit" (Store.Session.commit store ~fence:guard doc0 s1)
  in
  (* [remove] acquires the run fence itself, so the driver's guard must be
     released before it, or the removal is refused as {!Error.Locked}. *)
  Store.Run_lock.release guard;
  (match Store.Session.remove store doc0 with
  | Error (Store.Session.Error.Conflict _) -> ()
  | Ok _ -> fail "a stale remove must conflict"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error);
  ignore
    (require_ok ~msg:"a current remove succeeds"
       (Store.Session.remove store doc1));
  is_false ~msg:"the whole session directory is reclaimed, blobs included"
    (Sys.file_exists (Filename.concat base ("sessions/" ^ id)));
  match Store.Session.load store (sid id) with
  | Error (Store.Session.Error.Not_found _) -> ()
  | Ok _ -> fail "a removed session must not load"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error

(* [remove] fails loud while a driver holds the fence: it acquires the run fence
   before the rmtree so it can never unlink a live [run.lock] and admit a second
   driver over a recreated inode. *)
let remove_is_refused_while_the_fence_is_held () =
  with_fenced "remove-locked"
  @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ~id ~guard:_ ~document:_ ->
  let doc = ok_store "load" (Store.Session.load store (sid id)) in
  match Store.Session.remove store doc with
  | Error (Store.Session.Error.Locked { id = reported; holder }) ->
      equal session_id_value ~msg:"the refusal names the held session" (sid id)
        reported;
      is_true ~msg:"the driver holding the fence is named"
        (Option.is_some holder)
  | Ok _ -> fail "a remove under a held fence must be refused"
  | Error error -> failf "wrong error: %a" Store.Session.Error.pp error

(* Run lock. *)

let fence_excludes_and_names_the_holder () =
  with_store "fence" @@ fun ~sw ~base:_ ~session:store ~mutation ->
  let document =
    ok_store "create"
      (Store.Session.create store
         (session_fixture ~id:"s-fence" ~at:1_000 ~events:(open_claim_events ())
            ()))
  in
  let holder = owner "first-driver" in
  let guard =
    match
      Store.Run_lock.try_acquire ~sw store ~session:(sid "s-fence")
        ~owner:holder
    with
    | Ok guard -> guard
    | Error _ -> fail "first acquisition must succeed"
  in
  equal session_id_value ~msg:"the guard names its session" (sid "s-fence")
    (Store.Run_lock.session guard);
  equal owner_value ~msg:"the guard names its owner" holder
    (Store.Run_lock.owner guard);
  (match
     Store.Run_lock.try_acquire ~sw store ~session:(sid "s-fence")
       ~owner:(owner "second-driver")
   with
  | Error (`Held (Some reported)) ->
      equal owner_value
        ~msg:"the same-process loser is turned away with the holder's identity"
        holder reported
  | Ok _ -> fail "a second same-process acquisition must be excluded"
  | Error (`Held None) -> fail "the reservation must name the holder"
  | Error (`Io io) -> failf "fence io: %a" Store.Io.pp io);
  Store.Run_lock.release guard;
  Store.Run_lock.release guard;
  let successor = acquire ~sw store "s-fence" in
  ok_append "append under the successor guard (check_live positive)"
    (Store.Mutation.append mutation ~fence:successor ~document
       [ observed_event ~claim:"claim-succ" [ "a.ml" ] ]);
  Store.Run_lock.release successor

(* The read-only fence probe: it never creates run.lock, answers a
   same-process hold from the registry (POSIX record locks are invisible to a
   same-process OS probe), and reads the lock — not the file — as the truth.
   The cross-process Held arm needs a second process and is exercised by the
   daemon's blackbox suite. *)
let holder_probes_without_contending () =
  with_store "holder" @@ fun ~sw ~base ~session:store ~mutation:_ ->
  let _document =
    ok_store "create"
      (Store.Session.create store
         (session_fixture ~id:"s-holder" ~at:1_000
            ~events:(open_claim_events ()) ()))
  in
  let lock_path = Filename.concat base "sessions/s-holder/run.lock" in
  (match Store.Run_lock.holder store ~session:(sid "s-holder") with
  | `Free -> ()
  | `Held _ -> fail "an unfenced session must probe Free"
  | `Io io -> failf "holder io: %a" Store.Io.pp io);
  is_false ~msg:"the probe must not create run.lock"
    (Sys.file_exists lock_path);
  let holder_owner = owner "probe-holder" in
  let guard =
    match
      Store.Run_lock.try_acquire ~sw store ~session:(sid "s-holder")
        ~owner:holder_owner
    with
    | Ok guard -> guard
    | Error _ -> fail "acquisition must succeed"
  in
  (match Store.Run_lock.holder store ~session:(sid "s-holder") with
  | `Held (Some reported) ->
      equal owner_value ~msg:"the same-process probe names the holder"
        holder_owner reported
  | `Held None -> fail "the same-process probe must name the holder"
  | `Free -> fail "a held fence must probe Free"
  | `Io io -> failf "holder io: %a" Store.Io.pp io);
  Store.Run_lock.release guard;
  is_true ~msg:"release leaves the owner-line file behind"
    (Sys.file_exists lock_path);
  match Store.Run_lock.holder store ~session:(sid "s-holder") with
  | `Free -> ()
  | `Held _ -> fail "a released fence must probe Free"
  | `Io io -> failf "holder io: %a" Store.Io.pp io

(* The cheap document identity: one stat, no read — present iff the document
   is, stable while the bytes are, and changed by a commit (every replace
   lands on a fresh inode). *)
let stamp_is_cheap_document_identity () =
  with_fenced "stamp"
  @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ~id ~guard ~document ->
  is_true ~msg:"a missing document has no stamp"
    (Option.is_none (Store.Session.stamp store (sid "s-absent")));
  let first = Store.Session.stamp store (sid id) in
  is_true ~msg:"a present document has a stamp" (Option.is_some first);
  equal (option string) ~msg:"an unchanged document keeps its stamp" first
    (Store.Session.stamp store (sid id));
  let (_ : Store.Session.Document.t) =
    ok_store "commit"
      (Store.Session.commit store ~fence:guard document
         (Store.Session.Document.session document))
  in
  is_false ~msg:"a commit changes the stamp"
    (Option.equal String.equal first (Store.Session.stamp store (sid id)))

(* The probe/acquire mutual exclusion, raced under one Eio domain: a fence
   probe must never observe [`Free] while this process holds the fence, and an
   acquisition landing during a probe's descriptor window is turned away with
   a transient [`Held] rather than admitted — a lock taken then would be
   silently dropped when the probe descriptor closes (closing any descriptor
   to the inode drops every record lock this process holds on it), leaving the
   guard live with no fence: the two-writer hole. The acquire loop treats the
   transient [`Held] as the retry it is, so the assertions hold at every
   interleaving the scheduler produces. What this cannot pin in-process: the
   OS lock's cross-process retention after a probe (POSIX record locks are
   invisible within, and only droppable by, the owning process), which the
   daemon blackbox suite exercises with a real second process. *)
let holder_never_reads_a_held_fence_free () =
  with_store "probe-race" @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ->
  let _document =
    ok_store "create"
      (Store.Session.create store
         (session_fixture ~id:"s-race" ~at:1_000
            ~events:(open_claim_events ()) ()))
  in
  let held = Atomic.make false in
  let done_probing = ref false in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.both
    (fun () ->
      while not !done_probing do
        (match
           Store.Run_lock.try_acquire ~sw store ~session:(sid "s-race")
             ~owner:(owner "race-driver")
         with
        | Ok guard ->
            Atomic.set held true;
            Eio.Fiber.yield ();
            Atomic.set held false;
            Store.Run_lock.release guard
        | Error (`Held _) -> ()
        | Error (`Io io) -> failf "acquire io: %a" Store.Io.pp io);
        Eio.Fiber.yield ()
      done)
    (fun () ->
      for _ = 1 to 200 do
        let before = Atomic.get held in
        (match Store.Run_lock.holder store ~session:(sid "s-race") with
        | `Free ->
            is_false ~msg:"a probe must never read a held fence Free"
              (before || Atomic.get held)
        | `Held _ -> ()
        | `Io io -> failf "holder io: %a" Store.Io.pp io);
        Eio.Fiber.yield ()
      done;
      done_probing := true)

let released_guards_are_refused_by_appends () =
  with_fenced "released"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id:_ ~guard ~document ->
  let result = created_result ~path:"a.ml" ~contents:"a\n" in
  let event = edit_event ~claim:"claim-dead" result in
  Store.Run_lock.release guard;
  raises (Invalid_argument "Mentat_store.Handle.check_live: guard is released")
    (fun () ->
      Store.Mutation.append mutation ~fence:guard ~document
        [ observed_event ~claim:"claim-dead" [ "a.ml" ] ]);
  raises (Invalid_argument "Mentat_store.Handle.check_live: guard is released")
    (fun () ->
      Store.Mutation.append_edit mutation ~fence:guard ~document
        ~entries:(Edit.Result.entries result)
        event)

(* The witness-token law: a reservation is matched only by the acquisition
   that minted it, so a guard for one root can never pass another root's
   registry — even when both fences are held for the same session id by the
   very same [Owner.t]. *)
let guards_never_cross_root_registries () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let base_a = Unix.realpath (temp_dir ~prefix:"mentat-store-cross-a" ())
  and base_b = Unix.realpath (temp_dir ~prefix:"mentat-store-cross-b" ()) in
  Eio.Switch.run @@ fun sw ->
  let root_a = open_root ~sw ~fs base_a in
  let root_b = open_root ~sw ~fs base_b in
  let session_a = root_a and mutation_a = root_a in
  let session_b = root_b and mutation_b = root_b in
  let seed store =
    ok_store "create"
      (Store.Session.create store
         (session_fixture ~id:"s" ~at:1 ~events:(open_claim_events ()) ()))
  in
  let document_a = seed session_a in
  let document_b = seed session_b in
  let shared = owner "shared-owner" in
  let acquire_with store =
    match
      Store.Run_lock.try_acquire ~sw store ~session:(sid "s") ~owner:shared
    with
    | Ok guard -> guard
    | Error _ -> fail "distinct roots must fence independently"
  in
  let guard_a = acquire_with session_a in
  let guard_b = acquire_with session_b in
  let event_for claim = observed_event ~claim [ claim ^ ".ml" ] in
  ok_append "guard-A appends in root A"
    (Store.Mutation.append mutation_a ~fence:guard_a ~document:document_a
       [ event_for "claim-a" ]);
  ok_append "guard-B appends in root B"
    (Store.Mutation.append mutation_b ~fence:guard_b ~document:document_b
       [ event_for "claim-b" ]);
  raises
    (Invalid_argument
       "Mentat_store.Handle.check_live: guard is for a different store root")
    (fun () ->
      Store.Mutation.append mutation_b ~fence:guard_a ~document:document_b
        [ event_for "claim-x" ])

(* Target semantics of the token-addressed reservation: releasing a guard is
   idempotent and addressed to its own acquisition, so a stale release can
   never free a successor's fence. *)
let stale_release_never_frees_a_successor_fence () =
  with_store "stale-release" @@ fun ~sw ~base:_ ~session:store ~mutation ->
  let document =
    ok_store "create"
      (Store.Session.create store
         (session_fixture ~id:"s-stale" ~at:1_000 ~events:(open_claim_events ())
            ()))
  in
  let guard1 = acquire ~sw store "s-stale" in
  Store.Run_lock.release guard1;
  let guard2 = acquire ~sw store "s-stale" in
  Store.Run_lock.release guard1;
  (match
     Store.Run_lock.try_acquire ~sw store ~session:(sid "s-stale")
       ~owner:(owner "intruder")
   with
  | Error (`Held (Some _)) -> ()
  | Ok _ -> fail "a stale release must not free the successor's fence"
  | Error (`Held None) -> fail "the successor's reservation must stay named"
  | Error (`Io io) -> failf "fence io: %a" Store.Io.pp io);
  ok_append "the successor's guard still appends"
    (Store.Mutation.append mutation ~fence:guard2 ~document
       [ observed_event ~claim:"claim-stale" [ "a.ml" ] ])

(* Mutation appends. *)

(* Target semantics of the failed-append recovery: a batch whose write
   failed must not be double-applied by the retry — the anchor advances
   exactly once per persisted batch. The reachable injection point through
   the facade is an unopenable ledger. *)
let failed_appends_retry_without_duplication () =
  (* The only injection point through the facade is an unopenable ledger, and
     uid 0 opens a mode-000 file regardless of its mode bits, so the failure
     this test recovers from cannot be provoked as the superuser. *)
  if Unix.geteuid () = 0 then
    skip ~reason:"the superuser opens a mode-000 ledger" ();
  with_fenced "retry"
  @@ fun ~sw:_ ~base ~session:_ ~mutation ~id ~guard ~document ->
  let e1 = observed_event ~claim:"claim-1" [ "a.ml" ] in
  let e2 = observed_event ~claim:"claim-2" [ "b.ml" ] in
  ok_append "seed"
    (Store.Mutation.append mutation ~fence:guard ~document [ e1 ]);
  Unix.chmod (ledger_path base id) 0o000;
  (match Store.Mutation.append mutation ~fence:guard ~document [ e2 ] with
  | Error (Store.Mutation.Error.Io _) -> ()
  | Ok _ -> fail "an unopenable ledger must fail the append"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error);
  Unix.chmod (ledger_path base id) 0o600;
  ok_append "the retry lands the batch"
    (Store.Mutation.append mutation ~fence:guard ~document [ e2 ]);
  equal (list event_value)
    ~msg:"the failed batch appears exactly once after the retry" [ e1; e2 ]
    (read_events mutation id);
  (* Anchor coherence after the failure/retry cycle: the next edit lands at
     index 2 and its duplicate is rejected at index 3 — the whole persisted
     history, counted once. *)
  let result = created_result ~path:"c.ml" ~contents:"c\n" in
  ok_append "an edit lands after the retry"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result)
       (edit_event ~claim:"claim-3" result));
  let duplicate = created_result ~path:"d.ml" ~contents:"d\n" in
  match
    Store.Mutation.append_edit mutation ~fence:guard ~document
      ~entries:(Edit.Result.entries duplicate)
      (edit_event ~claim:"claim-3" duplicate)
  with
  | Error (Store.Mutation.Error.Invalid_history error) ->
      equal int ~msg:"the anchor counts the retried history exactly once" 3
        error.Mutation.State.Error.index
  | Ok _ -> fail "a duplicate claim after the retry must be rejected"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error

let fenced_appends_round_trip_in_order () =
  with_fenced "append"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let e1 = observed_event ~claim:"claim-1" [ "a.ml" ] in
  let e2 = observed_event ~claim:"claim-2" [ "b.ml"; "a.ml" ] in
  let e3 = observed_event ~claim:"claim-3" [ "c.ml" ] in
  ok_append "empty append is a no-op"
    (Store.Mutation.append mutation ~fence:guard ~document []);
  ok_append "first batch"
    (Store.Mutation.append mutation ~fence:guard ~document [ e1 ]);
  ok_append "second batch"
    (Store.Mutation.append mutation ~fence:guard ~document [ e2; e3 ]);
  equal (list event_value)
    ~msg:"read returns the validated events in append order" [ e1; e2; e3 ]
    (read_events mutation id)

(* The anchor-return law: the state an append hands back is the whole persisted
   history folded incrementally, so it equals a fresh read of the ledger from
   disk. This is what lets a driver adopt the returned state as its cache
   without re-reading. *)
let append_returns_the_read_anchor () =
  with_fenced "anchor-return"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let e1 = observed_event ~claim:"claim-1" [ "a.ml" ] in
  let e2 = observed_event ~claim:"claim-2" [ "b.ml" ] in
  let returned =
    ok_mutation "append returns the advanced anchor"
      (Store.Mutation.append mutation ~fence:guard ~document [ e1; e2 ])
  in
  equal (list event_value)
    ~msg:"the append return equals a fresh read of the ledger"
    (read_events mutation id)
    (Mutation.State.events returned)

let conflicting_batches_index_the_whole_history () =
  with_fenced "history"
  @@ fun ~sw ~base:_ ~session:store ~mutation ~id ~guard ~document ->
  let append_edit label ~claim ~ordinal result =
    ok_append label
      (Store.Mutation.append_edit mutation ~fence:guard ~document
         ~entries:(Edit.Result.entries result)
         (edit_event ~claim ~ordinal result))
  in
  let result_a = created_result ~path:"a.ml" ~contents:"a\n" in
  let e1 = edit_event ~claim:"claim-a" result_a in
  let result_b = created_result ~path:"b.ml" ~contents:"b\n" in
  let e2 = edit_event ~ordinal:1 ~claim:"claim-b" result_b in
  append_edit "batch one" ~claim:"claim-a" ~ordinal:0 result_a;
  append_edit "batch two" ~claim:"claim-b" ~ordinal:1 result_b;
  let duplicate ~fence path =
    let result = created_result ~path ~contents:"dup\n" in
    Store.Mutation.append_edit mutation ~fence ~document
      ~entries:(Edit.Result.entries result)
      (edit_event ~claim:"claim-a" result)
  in
  (match duplicate ~fence:guard "c.ml" with
  | Error (Store.Mutation.Error.Invalid_history error) -> (
      equal int ~msg:"the incremental rejection indexes over the whole history"
        2 error.Mutation.State.Error.index;
      match error.Mutation.State.Error.reason with
      | Mutation.State.Error.Invalid_ordinal { claim; ordinal; expected } ->
          equal claim_id_value ~msg:"the reason names the repeated claim"
            (claim_id "claim-a") claim;
          equal int ~msg:"repeated ordinal" 0 ordinal;
          equal int ~msg:"expected next ordinal" 2 expected
      | _ -> failf "wrong reason: %s" (Mutation.State.Error.message error))
  | Ok _ -> fail "a repeated-ordinal batch must be rejected"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error);
  equal (list event_value) ~msg:"the rejected batch wrote nothing" [ e1; e2 ]
    (read_events mutation id);
  (* A new tenure re-reads the ledger: the anchor is per-guard, so the
     successor's first append folds the full persisted history. *)
  Store.Run_lock.release guard;
  let successor = acquire ~sw store id in
  let e3 = observed_event ~claim:"claim-c" [ "d.ml" ] in
  ok_append "successor append"
    (Store.Mutation.append mutation ~fence:successor ~document [ e3 ]);
  equal (list event_value) ~msg:"the successor extends the persisted history"
    [ e1; e2; e3 ] (read_events mutation id);
  match duplicate ~fence:successor "e.ml" with
  | Error (Store.Mutation.Error.Invalid_history error) ->
      equal int
        ~msg:"the reopened anchor still counts the whole persisted history" 3
        error.Mutation.State.Error.index
  | Ok _ -> fail "the successor must also reject the duplicate claim"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error

let torn_tails_repair_and_damaged_lines_locate () =
  with_fenced "torn"
  @@ fun ~sw:_ ~base ~session:store ~mutation ~id ~guard ~document ->
  let e1 = observed_event ~claim:"claim-1" [ "a.ml" ] in
  let e2 = observed_event ~claim:"claim-2" [ "b.ml" ] in
  ok_append "seed"
    (Store.Mutation.append mutation ~fence:guard ~document [ e1; e2 ]);
  append_raw (ledger_path base id) {|{"torn":"no trailing newline|};
  equal (list event_value)
    ~msg:"a final newline-less fragment is dropped on read" [ e1; e2 ]
    (read_events mutation id);
  let e3 = observed_event ~claim:"claim-3" [ "c.ml" ] in
  ok_append "append truncates the torn tail first"
    (Store.Mutation.append mutation ~fence:guard ~document [ e3 ]);
  equal (list event_value)
    ~msg:"earlier events are intact and the new event follows them"
    [ e1; e2; e3 ] (read_events mutation id);
  append_raw (ledger_path base id) "this line is terminated but not an event\n";
  (match Store.Mutation.read mutation document with
  | Error (Store.Mutation.Error.Invalid_line { path; line; detail = _ }) ->
      equal int ~msg:"the damaged line is located" 4 line;
      is_true ~msg:"the damage names the ledger path"
        (String.ends_with ~suffix:"ledger.jsonl" path)
  | Ok _ -> fail "a terminated undecodable line must not be skipped"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error);
  (* A non-file ledger path is structural damage, not IO. *)
  let dead = "s-nrf" in
  let dead_document =
    ok_store "create non-regular-ledger session"
      (Store.Session.create store
         (session_fixture ~id:dead ~at:1_000 ~events:(open_claim_events ()) ()))
  in
  Unix.mkdir (ledger_path base dead) 0o755;
  match Store.Mutation.read mutation dead_document with
  | Error (Store.Mutation.Error.Non_regular_file path) ->
      equal string ~msg:"the structural damage names the ledger path"
        ("sessions/" ^ dead ^ "/ledger.jsonl")
        path
  | Ok _ -> fail "a directory ledger must not read"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error

(* Session commits and mutation appends share the same physical document lock.
   Racing both from one document therefore has only two serial histories: the
   mutation observes the old document and lands before the commit, or the commit
   lands first and the mutation rejects its now-stale document. *)
let document_lock_serializes_commit_and_mutation () =
  with_two_stores "document-race" @@ fun ~sw ~base:_ ~session:store ~mutation ->
  List.iter
    (fun index ->
      let id = Printf.sprintf "s-document-race-%d" index in
      let initial =
        session_fixture ~id ~at:1_000 ~events:(open_claim_events ()) ()
      in
      let document = ok_store "create" (Store.Session.create store initial) in
      let guard = acquire ~sw store id in
      let event = observed_event ~claim:"claim-race" [ "race.ml" ] in
      let next_session = Session.touch (time (2_000 + index)) initial in
      let start, start_resolver = Eio.Promise.create () in
      let append_result =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Promise.await start;
            Store.Mutation.append mutation ~fence:guard ~document [ event ])
      in
      let commit_result =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Promise.await start;
            Store.Session.commit store ~fence:guard document next_session)
      in
      Eio.Promise.resolve start_resolver ();
      let append_result = Eio.Promise.await_exn append_result in
      let committed =
        match Eio.Promise.await_exn commit_result with
        | Ok committed -> committed
        | Error error ->
            failf "the document commit lost to a non-document writer: %a"
              Store.Session.Error.pp error
      in
      let current =
        ok_store "load raced document" (Store.Session.load store (sid id))
      in
      equal digest_value ~msg:"the commit is the current document"
        (Store.Session.Document.revision committed)
        (Store.Session.Document.revision current);
      let events =
        Mutation.State.events
          (ok_mutation "read raced pair" (Store.Mutation.read mutation current))
      in
      match append_result with
      | Ok _ ->
          equal (list event_value)
            ~msg:"an append serialized before commit remains correlated"
            [ event ] events
      | Error
          (Store.Mutation.Error.Document
             (Store.Session.Error.Conflict
                { id = conflict_id; expected; actual })) ->
          equal session_id_value ~msg:"the stale append names its session"
            (sid id) conflict_id;
          equal digest_value ~msg:"the stale append expected its input document"
            (Store.Session.Document.revision document)
            expected;
          equal digest_value ~msg:"the stale append observed the committed head"
            (Store.Session.Document.revision committed)
            actual;
          equal (list event_value)
            ~msg:"an append serialized after commit writes no event" [] events
      | Error error ->
          failf "commit/append race produced a non-serial outcome: %a"
            Store.Mutation.Error.pp error)
    (List.init 12 Fun.id)

(* A waiter cancelled while another process owns the advisory half of the
   document lock must unwind the process-local keyed lock too.  The immediate
   successful retry is the observable proof that neither half was stranded. *)
let cancelled_document_lock_waiter_releases_the_lock () =
  with_fenced "cancelled-waiter"
  @@ fun ~sw:_ ~base ~session:_ ~mutation ~id ~guard ~document ->
  let event = observed_event ~claim:"claim-cancel" [ "cancel.ml" ] in
  let lock_path = Filename.concat base ("sessions/" ^ id ^ ".lock") in
  let cancelled =
    with_doc_lock_holder lock_path @@ fun () ->
    Eio.Fiber.first
      (fun () ->
        let result =
          Store.Mutation.append mutation ~fence:guard ~document [ event ]
        in
        `Completed result)
      (fun () ->
        (* The lock route reaches its cancellable retry sleep before yielding;
           two scheduler turns make the waiter observable without wall-clock
           timing in this unit harness. *)
        Eio.Fiber.yield ();
        Eio.Fiber.yield ();
        `Cancelled)
  in
  (match cancelled with
  | `Cancelled -> ()
  | `Completed (Ok _) -> fail "the waiter entered while the peer held the lock"
  | `Completed (Error error) ->
      failf "the blocked waiter failed instead of awaiting the lock: %a"
        Store.Mutation.Error.pp error);
  equal (list event_value) ~msg:"the cancelled waiter wrote no event" []
    (read_events mutation id);
  ok_append "append after cancelled waiter"
    (Store.Mutation.append mutation ~fence:guard ~document [ event ]);
  equal (list event_value) ~msg:"the released lock admits the next append"
    [ event ] (read_events mutation id)

(* Correlation is checked before blob persistence.  A foreign claim, a real
   claim paired with the wrong turn, and a stale document are three distinct
   ownership failures; none may leave mutation bytes behind. *)
let correlation_rejections_write_nothing () =
  with_store "correlation-rejections"
  @@ fun ~sw ~base ~session:store ~mutation ->
  let id = "s-correlation-rejections" in
  let events, local_claim = open_claim_fixture ~call_id:"call-local" in
  let document =
    ok_store "create"
      (Store.Session.create store (session_fixture ~id ~at:1_000 ~events ()))
  in
  let guard = acquire ~sw store id in
  let foreign = created_result ~path:"foreign.ml" ~contents:"foreign\n" in
  let foreign_event =
    edit_event_for ~turn:tool_turn ~claim:tool_claim_id foreign
  in
  (match
     Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries foreign)
       foreign_event
   with
  | Error
      (Store.Mutation.Error.Correlation
         (Store.Mutation.Error.Correlation.Unknown_claim claim)) ->
      equal claim_id_value ~msg:"the foreign claim is named" tool_claim_id claim
  | Ok _ -> fail "a claim from another session must not append"
  | Error error ->
      failf "wrong foreign-claim error: %a" Store.Mutation.Error.pp error);
  let local_claim_id = Session.Tool_claim.Started.id local_claim in
  let wrong_turn = Session.Turn.Id.of_string "turn-foreign" in
  let mismatched = created_result ~path:"mismatch.ml" ~contents:"mismatch\n" in
  let mismatched_event =
    edit_event_for ~turn:wrong_turn ~claim:local_claim_id mismatched
  in
  (match
     Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries mismatched)
       mismatched_event
   with
  | Error
      (Store.Mutation.Error.Correlation
         (Store.Mutation.Error.Correlation.Claim_turn_mismatch
            { claim; expected; actual })) ->
      equal claim_id_value ~msg:"the mismatched claim is named" local_claim_id
        claim;
      is_true ~msg:"the event's wrong turn is reported as expected"
        (Session.Turn.Id.equal wrong_turn expected);
      is_true ~msg:"the claim's owning turn is reported as actual"
        (Session.Turn.Id.equal tool_turn actual)
  | Ok _ -> fail "a real claim paired with another turn must not append"
  | Error error ->
      failf "wrong turn-mismatch error: %a" Store.Mutation.Error.pp error);
  let next_session =
    Session.touch (time 2_000) (Store.Session.Document.session document)
  in
  let current =
    ok_store "commit newer document"
      (Store.Session.commit store ~fence:guard document next_session)
  in
  let stale = created_result ~path:"stale.ml" ~contents:"stale\n" in
  let stale_event =
    edit_event_for ~turn:tool_turn ~claim:local_claim_id stale
  in
  (match
     Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries stale)
       stale_event
   with
  | Error
      (Store.Mutation.Error.Document
         (Store.Session.Error.Conflict { id = reported; expected; actual })) ->
      equal session_id_value
        ~msg:"the stale document conflict names the session" (sid id) reported;
      equal digest_value ~msg:"the conflict expected the supplied document"
        (Store.Session.Document.revision document)
        expected;
      equal digest_value ~msg:"the conflict observed the committed document"
        (Store.Session.Document.revision current)
        actual
  | Ok _ -> fail "a mutation against a stale document must not append"
  | Error error ->
      failf "wrong stale-document error: %a" Store.Mutation.Error.pp error);
  List.iter
    (fun contents ->
      let reference = Mentat_digest.Content_ref.of_contents contents in
      match Store.Mutation.blob mutation ~session:(sid id) reference with
      | Ok None -> ()
      | Ok (Some _) -> failf "rejected correlation wrote blob %S" contents
      | Error error ->
          failf "blob read failed: %a" Store.Mutation.Error.pp error)
    [ "foreign\n"; "mismatch\n"; "stale\n" ];
  equal (list event_value) ~msg:"all three rejected appends wrote no event" []
    (Mutation.State.events
       (ok_mutation "read empty correlated history"
          (Store.Mutation.read mutation current)));
  is_false ~msg:"the rejected appends never created a ledger"
    (Sys.file_exists (ledger_path base id))

(* A settled claim remains a valid owner of durable historical rows, but it is
   no longer a live suspension that can authorize another mutation append. *)
let settled_claim_is_history_not_live_authority () =
  with_store "settled-correlation" @@ fun ~sw ~base ~session:store ~mutation ->
  let id = "s-settled-correlation" in
  let document =
    ok_store "create settled-correlation session"
      (Store.Session.create store
         (session_fixture ~id ~at:1_000 ~events:(open_claim_events ()) ()))
  in
  let guard = acquire ~sw store id in
  let first = created_result ~path:"settled.ml" ~contents:"first\n" in
  let first_event = edit_event ~claim:"settled" first in
  ok_append "append while claim is open"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries first)
       first_event);
  let result =
    Tool.Result.completed ~output:(Tool.Output.make ~text:"done" ()) ()
  in
  let settled_event =
    Session.Event.tool_settled
      (Session.Tool_claim.Settled.returned ~id:tool_claim_id result)
  in
  let settled_session =
    ok_session "settle tool claim"
      (Session.append settled_event (Store.Session.Document.session document))
  in
  let settled_document =
    ok_store "commit settled claim"
      (Store.Session.commit store ~fence:guard document settled_session)
  in
  equal (list event_value)
    ~msg:"the row remains valid when read against its settled claim"
    [ first_event ]
    (Mutation.State.events
       (ok_mutation "read settled history"
          (Store.Mutation.read mutation settled_document)));
  let second = created_result ~path:"later.ml" ~contents:"later\n" in
  let second_event = edit_event ~ordinal:1 ~claim:"settled" second in
  (match
     Store.Mutation.append_edit mutation ~fence:guard ~document:settled_document
       ~entries:(Edit.Result.entries second)
       second_event
   with
  | Error
      (Store.Mutation.Error.Correlation
         (Store.Mutation.Error.Correlation.Claim_not_open claim)) ->
      equal claim_id_value ~msg:"the settled claim is named" tool_claim_id claim
  | Ok _ -> fail "a settled claim must not authorize another live append"
  | Error error ->
      failf "wrong settled-claim error: %a" Store.Mutation.Error.pp error);
  (match
     Store.Mutation.blob mutation ~session:(sid id)
       (Mentat_digest.Content_ref.of_contents "later\n")
   with
  | Ok None -> ()
  | Ok (Some _) -> fail "the rejected live append wrote its blob"
  | Error error -> failf "blob read failed: %a" Store.Mutation.Error.pp error);
  equal (option pass) None (blob_file_with base id "later\n");
  equal (list event_value)
    ~msg:"the rejected live append did not alter historical rows"
    [ first_event ]
    (Mutation.State.events
       (ok_mutation "reread settled history"
          (Store.Mutation.read mutation settled_document)))

let after_recovery_requires_prior_ambiguity () =
  with_store "recovery-correlation" @@ fun ~sw ~base ~session:store ~mutation ->
  let boundary =
    checkpoint_event (Mutation.Checkpoint.After_recovery tool_turn)
  in
  let missing_id = "s-recovery-missing" in
  let missing_document =
    ok_store "create non-ambiguous session"
      (Store.Session.create store
         (session_fixture ~id:missing_id ~at:1_000
            ~events:(open_claim_events ()) ()))
  in
  let missing_guard = acquire ~sw store missing_id in
  (match
     Store.Mutation.append mutation ~fence:missing_guard
       ~document:missing_document [ boundary ]
   with
  | Error
      (Store.Mutation.Error.Correlation
         (Store.Mutation.Error.Correlation.Recovery_without_ambiguity turn)) ->
      is_true ~msg:"the recovery refusal names the turn"
        (Session.Turn.Id.equal tool_turn turn)
  | Ok _ -> fail "After_recovery without Ambiguous must not append"
  | Error error ->
      failf "wrong recovery-causality error: %a" Store.Mutation.Error.pp error);
  equal (list event_value) ~msg:"the rejected boundary wrote no event" []
    (read_events mutation missing_id);
  is_false ~msg:"the rejected boundary never created a ledger"
    (Sys.file_exists (ledger_path base missing_id));
  let recovered_id = "s-recovery-accepted" in
  let recovered_events, first_claim, open_claim = recovered_claim_fixture () in
  let recovered_document =
    ok_store "create recovered session"
      (Store.Session.create store
         (session_fixture ~id:recovered_id ~at:1_000 ~events:recovered_events ()))
  in
  let recovered_guard = acquire ~sw store recovered_id in
  ok_append "append causal recovery boundary"
    (Store.Mutation.append mutation ~fence:recovered_guard
       ~document:recovered_document [ boundary ]);
  equal (list event_value)
    ~msg:"After_recovery lands after Ambiguous with a new open claim"
    [ boundary ]
    (read_events mutation recovered_id);
  is_false ~msg:"recovery advances to a distinct open claim"
    (Session.Tool_claim.Id.equal
       (Session.Tool_claim.Started.id first_claim)
       (Session.Tool_claim.Started.id open_claim))

let append_edit_validates_before_persisting_blobs () =
  with_fenced "edit"
  @@ fun ~sw:_ ~base ~session:_ ~mutation ~id ~guard ~document ->
  let first = created_result ~path:"a.ml" ~contents:"first body\n" in
  ok_append "append_edit"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries first)
       (edit_event ~claim:"claim-a" first));
  let reference = Mentat_digest.Content_ref.of_contents "first body\n" in
  (match Store.Mutation.blob mutation ~session:(sid id) reference with
  | Ok (Some bytes) ->
      equal string ~msg:"the stored blob round-trips its exact bytes"
        "first body\n" bytes
  | Ok None -> fail "the referenced blob must exist"
  | Error error -> failf "blob read failed: %a" Store.Mutation.Error.pp error);
  is_true ~msg:"the blob is a real file under the session's blob tree"
    (Option.is_some (blob_file_with base id "first body\n"));
  (* Semantic validation runs before writes: a rejected event leaves neither a
     ledger line nor an orphan content blob. *)
  let second = created_result ~path:"b.ml" ~contents:"second body\n" in
  (match
     Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries second)
       (edit_event ~claim:"claim-a" second)
   with
  | Error (Store.Mutation.Error.Invalid_history _) -> ()
  | Ok _ -> fail "a duplicate claim must reject the event append"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error);
  (match
     Store.Mutation.blob mutation ~session:(sid id)
       (Mentat_digest.Content_ref.of_contents "second body\n")
   with
  | Ok (Some _) -> fail "a semantically rejected append must not write a blob"
  | Ok None -> ()
  | Error error -> failf "blob read failed: %a" Store.Mutation.Error.pp error);
  equal (option pass) None (blob_file_with base id "second body\n");
  equal int ~msg:"the ledger still carries exactly the one appended event" 1
    (String.fold_left
       (fun count c -> if Char.equal c '\n' then count + 1 else count)
       0
       (read_file (ledger_path base id)));
  (* An event that does not derive from the entries is programmer error. *)
  raises
    (Invalid_argument
       "Mentat_store.Mutation.append_edit: event does not derive from entries")
    (fun () ->
      Store.Mutation.append_edit mutation ~fence:guard ~document
        ~entries:(Edit.Result.entries second)
        (edit_event ~claim:"claim-c"
           (created_result ~path:"c.ml" ~contents:"other\n")))

let blob_reads_verify_and_distinguish_absence () =
  with_fenced "blob"
  @@ fun ~sw:_ ~base ~session:_ ~mutation ~id ~guard ~document ->
  let result = created_result ~path:"a.ml" ~contents:"honest bytes\n" in
  ok_append "append_edit"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result)
       (edit_event ~claim:"claim-a" result));
  let reference = Mentat_digest.Content_ref.of_contents "honest bytes\n" in
  (match
     Store.Mutation.blob mutation ~session:(sid id)
       (Mentat_digest.Content_ref.of_contents "never stored")
   with
  | Ok None -> ()
  | Ok (Some _) -> fail "an absent blob must be None"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error);
  let file =
    match blob_file_with base id "honest bytes\n" with
    | Some file -> file
    | None -> fail "the stored blob file must exist"
  in
  write_file file "tampered bytes!";
  (match Store.Mutation.blob mutation ~session:(sid id) reference with
  | Error (Store.Mutation.Error.Blob_mismatch { expected; actual }) ->
      equal content_ref_value ~msg:"expected is the requested reference"
        reference expected;
      equal content_ref_value ~msg:"actual hashes the tampered bytes"
        (Mentat_digest.Content_ref.of_contents "tampered bytes!")
        actual
  | Ok _ -> fail "tampered bytes must never be returned"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error);
  Sys.remove file;
  Unix.mkdir file 0o755;
  match Store.Mutation.blob mutation ~session:(sid id) reference with
  | Error (Store.Mutation.Error.Non_regular_file path) ->
      is_true ~msg:"a directory blob path is structural damage"
        (String.includes ~affix:"/blobs/" path)
  | Ok _ -> fail "a directory blob must not read"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error

(* Blob store/read law over generated bytes: whatever valid-UTF-8 bytes an
   edit carries — empty, NUL-laden, large — store then read returns the
   exact bytes, and same-content writes converge write-once. *)
let blob_round_trip_over_generated_bytes () =
  with_fenced "blobgen"
  @@ fun ~sw:_ ~base ~session:_ ~mutation ~id ~guard ~document ->
  let seed = windtrap_seed () in
  let random = Random.State.make [| seed |] in
  let case index contents =
    let path = Printf.sprintf "gen-%d.txt" index in
    let claim = Printf.sprintf "claim-gen-%d" index in
    let result = created_result ~path ~contents in
    ok_append "append_edit"
      (Store.Mutation.append_edit mutation ~fence:guard ~document
         ~entries:(Edit.Result.entries result)
         (edit_event ~ordinal:index ~claim result));
    let reference = Mentat_digest.Content_ref.of_contents contents in
    match Store.Mutation.blob mutation ~session:(sid id) reference with
    | Ok (Some bytes) ->
        equal string
          ~msg:
            (Printf.sprintf "case %d (seed %d): %d blob bytes round-trip" index
               seed (String.length contents))
          contents bytes
    | Ok None -> failf "case %d: stored blob is missing" index
    | Error error ->
        failf "case %d: blob read failed: %a" index Store.Mutation.Error.pp
          error
  in
  let fixed =
    [
      "";
      "\000";
      "\000\001\002 nul laden \000 tail";
      String.init 256 (fun i -> Char.chr (i mod 128));
      String.make 100_000 'x' ^ "\000";
    ]
  in
  List.iteri case fixed;
  let offset = List.length fixed in
  for index = 0 to 19 do
    let length = Random.State.int random 513 in
    let contents =
      String.init length (fun _ -> Char.chr (Random.State.int random 128))
    in
    case (offset + index) contents
  done;
  (* Write-once convergence: the same bytes from a second claim land on the
     same content-addressed file, not a duplicate. *)
  let before_count = List.length (blob_files base id) in
  let repeat = created_result ~path:"converge.txt" ~contents:"" in
  ok_append "same-content write converges"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries repeat)
       (edit_event ~ordinal:(offset + 20) ~claim:"claim-converge" repeat));
  equal int ~msg:"no duplicate blob file appears for identical bytes"
    before_count
    (List.length (blob_files base id))

(* Revert lifecycle. *)

let ok_prepare label = function
  | Ok plan -> plan
  | Error problems ->
      failf "%s: prepare refused: %s" label
        (String.concat "; " (List.map Mutation.Revert.Problem.message problems))

let replay_state label events =
  match Mutation.State.of_events events with
  | Ok state -> state
  | Error error -> failf "%s: %s" label (Mutation.State.Error.message error)

(* The composite revert ops: started freezes the plan with its expected
   images durable, settlement re-derives from the frozen record and the
   apply evidence, and the plain append rejects every composite-op arm
   (closure symmetry — bytes cannot bypass their seam). *)
let revert_lifecycle_round_trips () =
  with_fenced "revert"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let before_text = "original\n" and after_text = "modified\n" in
  let created_text = "created\n" in
  let result_m =
    rewritten_result ~path:"m.ml" ~before:before_text ~after:after_text
  in
  let e_m = edit_event ~claim:"claim-m" result_m in
  ok_append "edit m"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_m)
       e_m);
  let result_c = created_result ~path:"c.ml" ~contents:created_text in
  let e_c = edit_event ~ordinal:1 ~claim:"claim-c" result_c in
  ok_append "edit c"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_c)
       e_c);
  let state = replay_state "replay" (read_events mutation id) in
  let current =
    [
      (wpath "m.ml", Edit.Observed.Text after_text);
      (wpath "c.ml", Edit.Observed.Text created_text);
    ]
  in
  let evidence =
    Mutation.Revert.Evidence.make ~current
      ~blobs:
        [ (Mentat_digest.Content_ref.of_contents before_text, before_text) ]
  in
  let plan =
    ok_prepare "revert-1"
      (Mutation.Revert.prepare
         ~id:(Mutation.Revert.Id.of_string "revert-1")
         ~evidence state Mutation.Revert.Selection.all)
  in
  let started = Mutation.Revert.Plan.started plan in
  let started_event = Mutation.Event.revert_started plan in
  let before_revert = before_revert_event plan in
  (* Closure symmetry: only the blob-free arms cross the plain append. *)
  raises
    (Invalid_argument
       "Mentat_store.Mutation.append: edit events append through append_edit")
    (fun () -> Store.Mutation.append mutation ~fence:guard ~document [ e_m ]);
  raises
    (Invalid_argument
       "Mentat_store.Mutation.append: revert started events append through \
        append_revert_started") (fun () ->
      Store.Mutation.append mutation ~fence:guard ~document [ started_event ]);
  raises
    (Invalid_argument
       "Mentat_store.Mutation.append: revert settled events append through \
        append_revert_settled") (fun () ->
      Store.Mutation.append mutation ~fence:guard ~document
        [
          Mutation.Event.revert_settled
            (Mutation.Revert.settle_ambiguous started);
        ]);
  ok_append "append before-revert checkpoint"
    (Store.Mutation.append mutation ~fence:guard ~document [ before_revert ]);
  ok_mutation "append_revert_started"
    (Store.Mutation.append_revert_started mutation ~fence:guard ~document ~plan
       ~current started_event);
  let outcome =
    match
      Edit.apply
        ~io:
          (fake_io [ (wpath "m.ml", after_text); (wpath "c.ml", created_text) ])
        ~workspace
        (Mutation.Revert.Plan.edit plan)
    with
    | Ok result -> Ok result
    | Error error -> failf "revert apply failed: %a" Edit.Apply_error.pp error
  in
  let settled = Mutation.Revert.settle started outcome in
  let settled_event = Mutation.Event.revert_settled settled in
  ok_mutation "append_revert_settled"
    (Store.Mutation.append_revert_settled mutation ~fence:guard ~document
       ~started ~outcome settled_event);
  equal (list event_value)
    ~msg:"the revert lifecycle reads back validated, in order"
    [ e_m; e_c; before_revert; started_event; settled_event ]
    (read_events mutation id)

(* Rung 2: a superseded selection cleanly merged mints a fresh
   restore image whose bytes are durable nowhere else, so append_revert_started
   puts them before the started event lands. *)
let merge_blob_is_durable () =
  with_fenced "revert-merge"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let cref = Mentat_digest.Content_ref.of_contents in
  let r1 =
    rewritten_result ~path:"m.ml" ~before:"A\nB\nC\nD\n" ~after:"A\nX\nC\nD\n"
  in
  ok_append "edit 1"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries r1)
       (edit_event ~claim:"claim-1" r1));
  let r2 =
    rewritten_result ~path:"m.ml" ~before:"A\nX\nC\nD\n" ~after:"A\nX\nC\nY\n"
  in
  ok_append "edit 2"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries r2)
       (edit_event ~ordinal:1 ~claim:"claim-2" r2));
  let state = replay_state "replay" (read_events mutation id) in
  (* Revert only the first change: the second recorded change supersedes it. *)
  let selection =
    match Mutation.State.changes state ~claim:tool_claim_id with
    | first :: _ ->
        Mutation.Revert.Selection.changes [ Mutation.Change.id first ]
    | [] -> fail "expected recorded changes"
  in
  let current = [ (wpath "m.ml", Edit.Observed.Text "A\nX\nC\nY\n") ] in
  let evidence =
    Mutation.Revert.Evidence.make ~current
      ~blobs:
        [
          (cref "A\nB\nC\nD\n", "A\nB\nC\nD\n");
          (cref "A\nX\nC\nD\n", "A\nX\nC\nD\n");
        ]
  in
  let plan =
    ok_prepare "merge"
      (Mutation.Revert.prepare
         ~id:(Mutation.Revert.Id.of_string "revert-merge")
         ~evidence state selection)
  in
  (match Mutation.Revert.Plan.merge_blobs plan with
  | [ (_, merged) ] ->
      equal string ~msg:"the plan carries the merged restore image"
        "A\nB\nC\nY\n" merged
  | _ -> fail "expected exactly one merge blob");
  ok_append "before-revert checkpoint"
    (Store.Mutation.append mutation ~fence:guard ~document
       [ before_revert_event plan ]);
  ok_mutation "append_revert_started"
    (Store.Mutation.append_revert_started mutation ~fence:guard ~document ~plan
       ~current
       (Mutation.Event.revert_started plan));
  match
    Store.Mutation.blob mutation ~session:(sid id) (cref "A\nB\nC\nY\n")
  with
  | Ok (Some bytes) ->
      equal string
        ~msg:"the merged restore image is durable after the started event"
        "A\nB\nC\nY\n" bytes
  | Ok None -> fail "the merge blob was not put before the started event"
  | Error error -> failf "blob read failed: %a" Store.Mutation.Error.pp error

(* Settlement is derive-and-compare against the frozen started record; the
   outcome-less arm is crash recovery's ambiguous settlement, the only one
   it may mint. *)
let revert_settlement_derivation_is_enforced () =
  with_fenced "revert-ambig"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let result_m = rewritten_result ~path:"m.ml" ~before:"one\n" ~after:"two\n" in
  let e_m = edit_event ~claim:"claim-m" result_m in
  ok_append "edit m"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_m)
       e_m);
  let state = replay_state "replay" (read_events mutation id) in
  let current = [ (wpath "m.ml", Edit.Observed.Text "two\n") ] in
  let evidence =
    Mutation.Revert.Evidence.make ~current
      ~blobs:[ (Mentat_digest.Content_ref.of_contents "one\n", "one\n") ]
  in
  let selection = Mutation.Revert.Selection.paths [ wpath "m.ml" ] in
  let plan =
    ok_prepare "revert-2"
      (Mutation.Revert.prepare
         ~id:(Mutation.Revert.Id.of_string "revert-2")
         ~evidence state selection)
  in
  let started = Mutation.Revert.Plan.started plan in
  let before_revert = before_revert_event plan in
  ok_append "append before-revert checkpoint"
    (Store.Mutation.append mutation ~fence:guard ~document [ before_revert ]);
  ok_mutation "append_revert_started"
    (Store.Mutation.append_revert_started mutation ~fence:guard ~document ~plan
       ~current
       (Mutation.Event.revert_started plan));
  let outcome =
    match
      Edit.apply
        ~io:(fake_io [ (wpath "m.ml", "two\n") ])
        ~workspace
        (Mutation.Revert.Plan.edit plan)
    with
    | Ok result -> Ok result
    | Error error -> failf "revert apply failed: %a" Edit.Apply_error.pp error
  in
  let ambiguous_event =
    Mutation.Event.revert_settled (Mutation.Revert.settle_ambiguous started)
  in
  raises
    (Invalid_argument
       "Mentat_store.Mutation.append_revert_settled: event does not derive \
        from outcome") (fun () ->
      Store.Mutation.append_revert_settled mutation ~fence:guard ~document
        ~started ~outcome ambiguous_event);
  ok_mutation "the crash-recovery settlement carries no outcome"
    (Store.Mutation.append_revert_settled mutation ~fence:guard ~document
       ~started ambiguous_event);
  match read_events mutation id with
  | [ _; _; _; last ] ->
      equal event_value ~msg:"the ambiguous settlement is the ledger head"
        ambiguous_event last
  | events -> failf "expected four events, got %d" (List.length events)

(* [revert_apply] drives the whole fenced lifecycle behind ports: it re-reads the
   fenced history, nets the selection, assembles the plan evidence through the
   [observe] port and the blob store, captures a checkpoint, and appends
   checkpoint -> started -> settled around the [apply] port. *)
let revert_apply_runs_the_fenced_lifecycle () =
  with_fenced "revert-apply"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let before_text = "original\n" and after_text = "modified\n" in
  let created_text = "created\n" in
  let result_m =
    rewritten_result ~path:"m.ml" ~before:before_text ~after:after_text
  in
  ok_append "edit m"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_m)
       (edit_event ~claim:"claim-m" result_m));
  let result_c = created_result ~path:"c.ml" ~contents:created_text in
  ok_append "edit c"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_c)
       (edit_event ~ordinal:1 ~claim:"claim-c" result_c));
  (* The workspace after the edits: the after-images the ports read and revert. *)
  let fs = [ (wpath "m.ml", after_text); (wpath "c.ml", created_text) ] in
  let observe path =
    match List.find_opt (fun (p, _) -> W.Path.equal p path) fs with
    | Some (_, contents) -> Edit.Observed.Text contents
    | None -> Edit.Observed.Missing
  in
  let new_id () = Mutation.Revert.Id.of_string "revert-apply" in
  let outcome =
    match
      Store.Mutation.revert_apply mutation ~fence:guard ~document
        ~selection:(Some Mutation.Revert.Selection.all) ~observe
        ~checkpoint:checkpoint_fact
        ~apply:(fun plan -> Edit.apply ~io:(fake_io fs) ~workspace plan)
        ~new_id
    with
    | Ok outcome -> outcome
    | Error e ->
        failf "revert_apply failed: %s" (Store.Mutation.Error.message e)
  in
  (match outcome with
  | Store.Mutation.Applied settled ->
      equal int ~msg:"both files settled" 2
        (List.length settled.Mutation.Revert.Settled.outcomes);
      is_true ~msg:"every target confirmed"
        (List.for_all
           (fun (_, o) ->
             match o with
             | Mutation.Revert.Settled.Confirmed _ -> true
             | _ -> false)
           settled.Mutation.Revert.Settled.outcomes)
  | Store.Mutation.Nothing_to_revert ->
      fail "expected an applied revert, not nothing-to-revert"
  | Store.Mutation.Refused problems ->
      failf "revert refused: %s"
        (String.concat "; " (List.map Mutation.Revert.Problem.message problems)));
  match read_events mutation id with
  | [ _; _; checkpoint_ev; started_ev; settled_ev ] ->
      is_true ~msg:"the before-revert checkpoint precedes the start"
        (match checkpoint_ev with
        | Mutation.Event.Checkpoint _ -> true
        | _ -> false);
      is_true ~msg:"the started fact precedes the settlement"
        (match started_ev with
        | Mutation.Event.Revert_started _ -> true
        | _ -> false);
      is_true ~msg:"the settlement is the ledger head"
        (match settled_ev with
        | Mutation.Event.Revert_settled _ -> true
        | _ -> false)
  | events -> failf "expected five events, got %d" (List.length events)

(* revert_apply threads ?override to prepare: a non-contiguous
   path refuses without one, and applies with the path-specific override. *)
let revert_apply_override_applies_non_contiguous () =
  with_fenced "revert-apply-override"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id:_ ~guard ~document ->
  let result_1 = created_result ~path:"o.ml" ~contents:"recorded a\n" in
  ok_append "edit one"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_1)
       (edit_event ~claim:"claim-1" result_1));
  (* A second recorded change whose before is not the first's after: the path's
     history is non-contiguous. *)
  let result_2 =
    rewritten_result ~path:"o.ml" ~before:"unrecorded before\n"
      ~after:"recorded after\n"
  in
  ok_append "edit two"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_2)
       (edit_event ~ordinal:1 ~claim:"claim-2" result_2));
  let observe path =
    if W.Path.equal path (wpath "o.ml") then
      Edit.Observed.Text "unrecorded current\n"
    else Edit.Observed.Missing
  in
  let new_id () = Mutation.Revert.Id.of_string "revert-override" in
  let selection = Some (Mutation.Revert.Selection.paths [ wpath "o.ml" ]) in
  let apply plan =
    Edit.apply
      ~io:(fake_io [ (wpath "o.ml", "unrecorded current\n") ])
      ~workspace plan
  in
  (match
     Store.Mutation.revert_apply mutation ~fence:guard ~document ~selection
       ~observe ~checkpoint:checkpoint_fact ~apply ~new_id
   with
  | Ok (Store.Mutation.Refused problems) ->
      is_true ~msg:"a non-contiguous revert refuses without an override"
        (List.exists
           (function
             | Mutation.Revert.Problem.Needs_override _ -> true | _ -> false)
           problems)
  | Ok _ -> fail "a non-contiguous revert must refuse without an override"
  | Error e -> failf "revert_apply: %s" (Store.Mutation.Error.message e));
  let override =
    Mutation.Revert.Override.accept_unrecorded_loss [ wpath "o.ml" ]
  in
  match
    Store.Mutation.revert_apply ~override mutation ~fence:guard ~document
      ~selection ~observe ~checkpoint:checkpoint_fact ~apply ~new_id
  with
  | Ok (Store.Mutation.Applied _) -> ()
  | Ok (Store.Mutation.Refused problems) ->
      failf "the override revert refused: %s"
        (String.concat "; " (List.map Mutation.Revert.Problem.message problems))
  | Ok Store.Mutation.Nothing_to_revert ->
      fail "expected an applied override revert"
  | Error e ->
      failf "revert_apply override: %s" (Store.Mutation.Error.message e)

(* A [None] selection is [Nothing_to_revert]: the flags named nothing, so no read
   or write happens and the ledger stays untouched. *)
let revert_apply_reports_nothing_to_revert () =
  with_fenced "revert-none"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let observe _ = Edit.Observed.Missing in
  let new_id () = Mutation.Revert.Id.of_string "revert-none" in
  (match
     Store.Mutation.revert_apply mutation ~fence:guard ~document ~selection:None
       ~observe ~checkpoint:checkpoint_fact
       ~apply:(fun _ -> fail "nothing-to-revert must not apply")
       ~new_id
   with
  | Ok Store.Mutation.Nothing_to_revert -> ()
  | Ok _ -> fail "expected nothing-to-revert for a None selection"
  | Error e -> failf "revert_apply errored: %s" (Store.Mutation.Error.message e));
  equal int ~msg:"a None selection mints no fact" 0
    (List.length (read_events mutation id))

(* A selection whose current read has drifted from the recorded net-after refuses
   at preparation ([Stale]): the ports capture no checkpoint and apply nothing,
   and no fact is minted beyond the original edit. *)
let revert_apply_refuses_a_stale_selection () =
  with_fenced "revert-stale"
  @@ fun ~sw:_ ~base:_ ~session:_ ~mutation ~id ~guard ~document ->
  let result_m = rewritten_result ~path:"m.ml" ~before:"one\n" ~after:"two\n" in
  ok_append "edit m"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_m)
       (edit_event ~claim:"claim-m" result_m));
  let observe _ = Edit.Observed.Text "drifted\n" in
  let new_id () = Mutation.Revert.Id.of_string "revert-stale" in
  (match
     Store.Mutation.revert_apply mutation ~fence:guard ~document
       ~selection:(Some Mutation.Revert.Selection.all) ~observe
       ~checkpoint:checkpoint_fact
       ~apply:(fun _ -> fail "a refused revert must not apply")
       ~new_id
   with
  | Ok (Store.Mutation.Refused problems) ->
      is_true ~msg:"the refusal names the stale target"
        (List.exists
           (function Mutation.Revert.Problem.Stale _ -> true | _ -> false)
           problems)
  | Ok _ -> fail "expected a stale refusal"
  | Error e -> failf "revert_apply errored: %s" (Store.Mutation.Error.message e));
  equal int ~msg:"a refusal mints no fact beyond the edit" 1
    (List.length (read_events mutation id))

(* Review. *)

let review_round_trips_and_missing_is_none () =
  with_review "roundtrip" @@ fun ~base:_ ~review:store ->
  let key = review_key () in
  let record = persist_record () in
  let created =
    ok_review "create" (Store.Review.create store ~root:(review_root ()) record)
  in
  is_true ~msg:"the created document is keyed by the record's own base"
    (Store.Review.Key.equal key (Store.Review.Document.key created));
  (match Store.Review.load store key with
  | Ok (Some loaded) ->
      equal string ~msg:"the loaded record re-encodes byte-identically"
        (persist_json record)
        (persist_json (Store.Review.Document.value loaded));
      equal digest_value ~msg:"created and loaded revisions agree"
        (Store.Review.Document.revision created)
        (Store.Review.Document.revision loaded)
  | Ok None -> fail "the created record must load"
  | Error error -> failf "load failed: %a" Store.Review.Error.pp error);
  (match Store.Review.load store (review_key ~base:"absent" ()) with
  | Ok None -> ()
  | Ok (Some _) -> fail "a missing record must be Ok None"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error);
  (match Store.Review.create store ~root:(review_root ()) record with
  | Error (Store.Review.Error.Already_exists reported) ->
      is_true ~msg:"a second create names the existing key"
        (Store.Review.Key.equal key reported)
  | Ok _ -> fail "a second create must not replace the record"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error);
  (* Hostile root and base text are the store's to encode: they must round-trip,
     not leak into path structure. The record carries the hostile base, so the
     derived key does too. *)
  let hostile_record = persist_record ~base:"feature/x..y" () in
  let hostile = review_key ~root:"work/space one" ~base:"feature/x..y" () in
  let (_ : Store.Review.Document.t) =
    ok_review "hostile create"
      (Store.Review.create store
         ~root:(review_root ~root:"work/space one" ())
         hostile_record)
  in
  match Store.Review.load store hostile with
  | Ok (Some loaded) ->
      is_true ~msg:"a hostile key loads its own record"
        (Store.Review.Key.equal hostile (Store.Review.Document.key loaded))
  | Ok None -> fail "the hostile-keyed record must load"
  | Error error -> failf "load failed: %a" Store.Review.Error.pp error

let review_corruption_is_loud_and_replacement_is_cas () =
  with_review "cas" @@ fun ~base ~review:store ->
  let key = review_key () in
  let record = persist_record () in
  let doc0 =
    ok_review "create" (Store.Review.create store ~root:(review_root ()) record)
  in
  let replacement = persist_record ~approve:false () in
  let doc1 = ok_review "commit" (Store.Review.commit store doc0 replacement) in
  (match Store.Review.load store key with
  | Ok (Some loaded) ->
      equal string ~msg:"the replacement is what loads"
        (persist_json replacement)
        (persist_json (Store.Review.Document.value loaded))
  | Ok None -> fail "the replaced record must load"
  | Error error -> failf "load failed: %a" Store.Review.Error.pp error);
  (match Store.Review.commit store doc0 record with
  | Error (Store.Review.Error.Conflict { key = reported; expected; actual }) ->
      is_true ~msg:"the conflict names the key"
        (Store.Review.Key.equal key reported);
      equal digest_value ~msg:"expected is the stale revision"
        (Store.Review.Document.revision doc0)
        expected;
      equal digest_value ~msg:"actual is the current revision"
        (Store.Review.Document.revision doc1)
        actual
  | Ok _ -> fail "a concurrent reviewer must conflict, never lose marks"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error);
  let record_path = Filename.concat base "reviews/wsroot/main.json" in
  write_file record_path "damaged review bytes";
  (match Store.Review.load store key with
  | Error (Store.Review.Error.Invalid_record { path; detail = _ }) ->
      is_true
        ~msg:
          "damaged durable bytes are Invalid_record, never laundered to Ok None"
        (String.ends_with ~suffix:"reviews/wsroot/main.json" path)
  | Ok None -> fail "corrupt is never missing (the fail-loud law)"
  | Ok (Some _) -> fail "damaged bytes must not decode"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error);
  Sys.remove record_path;
  Unix.mkdir record_path 0o755;
  match Store.Review.load store key with
  | Error (Store.Review.Error.Non_regular_file path) ->
      is_true ~msg:"a directory target is Non_regular_file"
        (String.ends_with ~suffix:"reviews/wsroot/main.json" path)
  | Ok _ -> fail "a directory target must not load"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error

(* A record's decoded base must agree with the lookup key even when its bytes
   are otherwise valid. External interference can move a valid record to a
   different base-derived path; loading it as that path must fail loudly rather
   than minting a document whose key and value disagree. *)
let review_load_refuses_a_base_mismatch () =
  with_review "load-basemismatch" @@ fun ~base ~review:store ->
  let wrong_key = review_key ~base:"develop" () in
  let (_ : Store.Review.Document.t) =
    ok_review "create develop record"
      (Store.Review.create store ~root:(review_root ())
         (persist_record ~base:"develop" ()))
  in
  let wrong_path = Filename.concat base "reviews/wsroot/develop.json" in
  write_file wrong_path (persist_json (persist_record ~base:"main" ()) ^ "\n");
  match Store.Review.load store wrong_key with
  | Error (Store.Review.Error.Base_mismatch { key; base }) ->
      is_true ~msg:"the mismatch names the lookup key"
        (Store.Review.Key.equal wrong_key key);
      equal string ~msg:"the mismatch names the decoded record base" "main" base
  | Ok None -> fail "a valid record under the wrong key is not missing"
  | Ok (Some _) -> fail "a base-mismatched record must not load"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error

(* No store op removes review records, so a target missing at commit time is
   external interference — loud, never absence. *)
let commit_on_an_externally_deleted_record_vanishes () =
  with_review "vanished" @@ fun ~base ~review:store ->
  let key = review_key () in
  let doc =
    ok_review "create"
      (Store.Review.create store ~root:(review_root ()) (persist_record ()))
  in
  Sys.remove (Filename.concat base "reviews/wsroot/main.json");
  match Store.Review.commit store doc (persist_record ~approve:false ()) with
  | Error (Store.Review.Error.Vanished reported) ->
      is_true ~msg:"the vanished record names its key"
        (Store.Review.Key.equal key reported)
  | Ok _ -> fail "a vanished record must not silently reappear through commit"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error

(* A commit can never change the base a record is stored under: a [develop]
   record committed over a [main] document is a programmer error, not a silent
   overwrite that later restores nothing. *)
let commit_refuses_a_base_mismatch () =
  with_review "basemismatch" @@ fun ~base:_ ~review:store ->
  let doc =
    ok_review "create"
      (Store.Review.create store ~root:(review_root ())
         (persist_record ~base:"main" ()))
  in
  match Store.Review.commit store doc (persist_record ~base:"develop" ()) with
  | Error (Store.Review.Error.Base_mismatch { key; base }) ->
      is_true ~msg:"the mismatch names the document's key"
        (Store.Review.Key.equal (review_key ~base:"main" ()) key);
      equal string ~msg:"the mismatch names the offending record base" "develop"
        base
  | Ok _ ->
      fail "a base-mismatched commit must be refused, not silently accepted"
  | Error error -> failf "wrong error: %a" Store.Review.Error.pp error

(* Export and the bundle decoder. *)

let export_bundle ~session ~mutation:_ ~guard =
  let buffer = Buffer.create 4096 in
  match
    Store.Export.write ~root:session ~fence:guard
      ~write:(Buffer.add_string buffer)
  with
  | Ok _ -> Buffer.contents buffer
  | Error (`Session error) ->
      failf "export failed: %a" Store.Session.Error.pp error
  | Error (`Mutation error) ->
      failf "export failed: %a" Store.Mutation.Error.pp error

let populate_for_export ~mutation ~guard ~document =
  let first = created_result ~path:"a.ml" ~contents:"alpha\n" in
  let e1 = edit_event ~claim:"claim-1" first in
  ok_append "append_edit one"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries first)
       e1);
  let second =
    rewritten_result ~path:"a.ml" ~before:"alpha\n" ~after:"beta\n"
  in
  let e2 = edit_event ~ordinal:1 ~claim:"claim-2" second in
  ok_append "append_edit two"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries second)
       e2);
  [ e1; e2 ]

let export_round_trips_the_complete_session () =
  with_fenced "export"
  @@ fun ~sw:_ ~base:_ ~session ~mutation ~id ~guard ~document ->
  let events = populate_for_export ~mutation ~guard ~document in
  let bundle_text = export_bundle ~session ~mutation ~guard in
  match Store.Bundle.decode bundle_text with
  | Error error -> failf "decode failed: %a" Store.Bundle.Error.pp error
  | Ok bundle ->
      equal session_id_value ~msg:"the decoded document is the fenced session"
        (sid id)
        (Session.id bundle.Store.Bundle.session);
      let supplied =
        Store.Session.Document.session
          (ok_store "load" (Store.Session.load session (sid id)))
      in
      equal string ~msg:"the decoded document re-encodes byte-identically"
        (encode_session supplied)
        (encode_session bundle.Store.Bundle.session);
      equal (list event_value)
        ~msg:"the decoded events are the ledger in append order" events
        bundle.Store.Bundle.events;
      let blob_of contents =
        List.find_opt
          (fun (reference, _) ->
            Mentat_digest.Content_ref.equal reference
              (Mentat_digest.Content_ref.of_contents contents))
          bundle.Store.Bundle.blobs
      in
      equal int ~msg:"the bundle carries each referenced image exactly once" 2
        (List.length bundle.Store.Bundle.blobs);
      List.iter
        (fun contents ->
          match blob_of contents with
          | Some (_, bytes) ->
              equal string ~msg:"the bundled blob bytes are exact" contents
                bytes
          | None -> failf "missing bundled blob %S" contents)
        [ "alpha\n"; "beta\n" ]

(* Export walks the document's media refs alongside the mutation events, so a
   session with an attachment blob exports it and the bundle round-trips. The
   completeness proof widens to include document-media refs. *)
let export_includes_document_media_blobs () =
  with_store "export-media" @@ fun ~sw ~base:_ ~session:store ~mutation:_ ->
  let id = "export-media" in
  let (_ : Store.Session.Document.t) =
    ok_store "create"
      (Store.Session.create store
         (session_fixture ~id ~at:1_000 ~events:media_events ()))
  in
  let (_ : Mentat_digest.Content_ref.t) =
    ok_attachment "put"
      (Store.Attachment.put store ~session:(sid id) attachment_image_bytes)
  in
  let guard = acquire ~sw store id in
  let bundle_text = export_bundle ~session:store ~mutation:store ~guard in
  match Store.Bundle.decode bundle_text with
  | Error error -> failf "decode failed: %a" Store.Bundle.Error.pp error
  | Ok bundle ->
      is_true ~msg:"the bundle carries the document-media attachment blob"
        (List.exists
           (fun (reference, bytes) ->
             Mentat_digest.Content_ref.equal reference attachment_ref
             && String.equal bytes attachment_image_bytes)
           bundle.Store.Bundle.blobs);
      let supplied =
        Store.Session.Document.session
          (ok_store "load" (Store.Session.load store (sid id)))
      in
      equal string ~msg:"the decoded document re-encodes byte-identically"
        (encode_session supplied)
        (encode_session bundle.Store.Bundle.session)

let tampered_bundles_fail_loudly () =
  with_fenced "tamper"
  @@ fun ~sw:_ ~base ~session ~mutation ~id ~guard ~document ->
  let (_ : Mutation.Event.t list) =
    populate_for_export ~mutation ~guard ~document
  in
  let bundle_text = export_bundle ~session ~mutation ~guard in
  let lines = String.split_on_char '\n' bundle_text in
  (* [split_on_char] on "a\nb\n" yields ["a"; "b"; ""]: the last real line
     is second-to-last. *)
  let rec split_last acc = function
    | [ last; "" ] -> (List.rev acc, last)
    | line :: rest -> split_last (line :: acc) rest
    | _ -> fail "the bundle must end with a terminated manifest line"
  in
  let body, end_line = split_last [] lines in
  let without_end = String.concat "\n" body ^ "\n" in
  (match Store.Bundle.decode without_end with
  | Error Store.Bundle.Error.Truncated -> ()
  | Ok _ -> fail "a bundle without its end line proves nothing"
  | Error error -> failf "wrong error: %a" Store.Bundle.Error.pp error);
  (* Flip one hex character of the manifest digest: every line still
     decodes, the counts still match, and only the digest proof fails. *)
  let marker = {|"digest":"sha256:|} in
  let marker_index =
    let limit = String.length end_line - String.length marker in
    let rec search index =
      if index > limit then fail "the end line must carry a digest"
      else if
        String.equal marker (String.sub end_line index (String.length marker))
      then index
      else search (index + 1)
    in
    search 0
  in
  let flipped_end =
    let position = marker_index + String.length marker in
    String.mapi
      (fun i c ->
        if i = position then if Char.equal c 'a' then 'b' else 'a' else c)
      end_line
  in
  (match
     Store.Bundle.decode (String.concat "\n" body ^ "\n" ^ flipped_end ^ "\n")
   with
  | Error Store.Bundle.Error.Truncated -> ()
  | Ok _ -> fail "a digest that does not cover the bytes must not verify"
  | Error error -> failf "wrong error: %a" Store.Bundle.Error.pp error);
  (* Corrupt one byte of a section line so it no longer decodes. *)
  let corrupted =
    match body with
    | header :: document :: rest ->
        String.concat "\n" ((header :: ("X" ^ document) :: rest) @ [ end_line ])
        ^ "\n"
    | _ -> fail "the bundle must carry a document line"
  in
  (match Store.Bundle.decode corrupted with
  | Error (Store.Bundle.Error.Corrupt _) -> ()
  | Ok _ -> fail "an undecodable line must be Corrupt"
  | Error Store.Bundle.Error.Truncated ->
      fail "an undecodable line is damage, not truncation");
  (* A referenced blob missing from the store is located integrity damage. *)
  let beta = Mentat_digest.Content_ref.of_contents "beta\n" in
  (match blob_file_with base id "beta\n" with
  | Some file -> Sys.remove file
  | None -> fail "the beta blob file must exist before deletion");
  match Store.Export.write ~root:session ~fence:guard ~write:(fun _ -> ()) with
  | Error (`Mutation (Store.Mutation.Error.Missing_blob reference)) ->
      equal content_ref_value ~msg:"the missing blob is named by reference" beta
        reference
  | Ok _ -> fail "an export over a missing referenced blob must fail"
  | Error (`Mutation error) ->
      failf "wrong error: %a" Store.Mutation.Error.pp error
  | Error (`Session error) ->
      failf "wrong error: %a" Store.Session.Error.pp error

(* An overridden revert freezes the unrecorded writer's text — durable
   nowhere else — as the target's expected image: the started op stores it,
   and the export closure carries it, so the whole session decodes. *)
let overridden_reverts_export_cleanly () =
  with_fenced "override"
  @@ fun ~sw:_ ~base:_ ~session ~mutation ~id ~guard ~document ->
  let recorded_a = "alpha original\n" in
  let recorded_b = "unrecorded before\n" in
  let recorded_c = "recorded after\n" in
  let unrecorded = "unrecorded current\n" in
  let result_1 = created_result ~path:"o.ml" ~contents:recorded_a in
  ok_append "edit one"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_1)
       (edit_event ~claim:"claim-1" result_1));
  (* A second recorded change whose before is not the first's after: the
     path's history is non-contiguous. *)
  let result_2 =
    rewritten_result ~path:"o.ml" ~before:recorded_b ~after:recorded_c
  in
  ok_append "edit two"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result_2)
       (edit_event ~ordinal:1 ~claim:"claim-2" result_2));
  let state = replay_state "replay" (read_events mutation id) in
  let current = [ (wpath "o.ml", Edit.Observed.Text unrecorded) ] in
  let evidence = Mutation.Revert.Evidence.make ~current ~blobs:[] in
  let selection = Mutation.Revert.Selection.paths [ wpath "o.ml" ] in
  let prepare ?override () =
    Mutation.Revert.prepare ?override
      ~id:(Mutation.Revert.Id.of_string "revert-o")
      ~evidence state selection
  in
  (match prepare () with
  | Error [ Mutation.Revert.Problem.Needs_override { path } ] ->
      equal path_value ~msg:"the refusal names the non-contiguous path"
        (wpath "o.ml") path
  | Ok _ -> fail "a non-contiguous target must need an override"
  | Error problems ->
      failf "wrong problems: %s"
        (String.concat "; " (List.map Mutation.Revert.Problem.message problems)));
  let override =
    Mutation.Revert.Override.accept_unrecorded_loss [ wpath "o.ml" ]
  in
  let plan = ok_prepare "override" (prepare ~override ()) in
  let started = Mutation.Revert.Plan.started plan in
  let before_revert = before_revert_event plan in
  ok_append "append before-revert checkpoint"
    (Store.Mutation.append mutation ~fence:guard ~document [ before_revert ]);
  ok_mutation "append_revert_started"
    (Store.Mutation.append_revert_started mutation ~fence:guard ~document ~plan
       ~current
       (Mutation.Event.revert_started plan));
  let unrecorded_ref = Mentat_digest.Content_ref.of_contents unrecorded in
  (match Store.Mutation.blob mutation ~session:(sid id) unrecorded_ref with
  | Ok (Some bytes) ->
      equal string
        ~msg:"the unrecorded writer's text is durable once started lands"
        unrecorded bytes
  | Ok None -> fail "the overridden expected image must be stored"
  | Error error -> failf "blob read failed: %a" Store.Mutation.Error.pp error);
  let outcome =
    match
      Edit.apply
        ~io:(fake_io [ (wpath "o.ml", unrecorded) ])
        ~workspace
        (Mutation.Revert.Plan.edit plan)
    with
    | Ok result -> Ok result
    | Error error -> failf "revert apply failed: %a" Edit.Apply_error.pp error
  in
  let settled = Mutation.Revert.settle started outcome in
  ok_mutation "append_revert_settled"
    (Store.Mutation.append_revert_settled mutation ~fence:guard ~document
       ~started ~outcome
       (Mutation.Event.revert_settled settled));
  match Store.Bundle.decode (export_bundle ~session ~mutation ~guard) with
  | Error error ->
      failf "an overridden-revert session must decode: %a" Store.Bundle.Error.pp
        error
  | Ok bundle ->
      equal int ~msg:"the bundle carries the whole lifecycle" 5
        (List.length bundle.Store.Bundle.events);
      is_true ~msg:"the export closure carries the unrecorded expected image"
        (List.exists
           (fun (reference, bytes) ->
             Mentat_digest.Content_ref.equal reference unrecorded_ref
             && String.equal bytes unrecorded)
           bundle.Store.Bundle.blobs)

(* {2 Bundle forgery}

   The manifest digest is computable from public surface ([Mentat_digest]
   over the covered bytes, [Bundle.Line.jsont] for the end line), so the
   pending decoder-hardening tests can mint bundles whose manifest is
   coherent while the content is incoherent — exactly what the decoder must
   reject on its own. *)

let bundle_lines bundle_text =
  match List.rev (String.split_on_char '\n' bundle_text) with
  | "" :: rest -> List.rev rest
  | _ -> fail "the bundle must end with a newline"

let classify line =
  match Jsont_bytesrw.decode_string Store.Bundle.Line.jsont line with
  | Ok (Store.Bundle.Line.Document _) -> `Document
  | Ok (Store.Bundle.Line.Event _) -> `Event
  | Ok (Store.Bundle.Line.Blob _) -> `Blob
  | Ok (Store.Bundle.Line.End _) -> `End
  | Error _ -> `Header

let forge_bundle ~events ~blobs body =
  let covered = String.concat "" (List.map (fun line -> line ^ "\n") body) in
  let digest =
    "sha256:" ^ Mentat_digest.to_hex (Mentat_digest.string covered)
  in
  match
    Jsont_bytesrw.encode_string Store.Bundle.Line.jsont
      (Store.Bundle.Line.End { events; blobs; digest })
  with
  | Ok end_line -> covered ^ end_line ^ "\n"
  | Error message -> failf "end line does not encode: %s" message

let split_sections bundle_text =
  let lines = bundle_lines bundle_text in
  let of_kind kind = List.filter (fun line -> classify line = kind) lines in
  let prelude =
    List.filter
      (fun line ->
        match classify line with `Header | `Document -> true | _ -> false)
      lines
  in
  (prelude, of_kind `Event, of_kind `Blob)

let assert_forge_sane ~events ~blobs prelude event_lines blob_lines =
  match
    Store.Bundle.decode
      (forge_bundle ~events ~blobs (prelude @ event_lines @ blob_lines))
  with
  | Ok _ -> ()
  | Error error ->
      failf "the re-minted unchanged bundle must decode: %a"
        Store.Bundle.Error.pp error

(* A blob section carrying the same reference twice is incoherent content
   the decoder rejects, digest notwithstanding. *)
let bundle_rejects_duplicate_blobs () =
  with_fenced "dupblob"
  @@ fun ~sw:_ ~base:_ ~session ~mutation ~id:_ ~guard ~document ->
  let (_ : Mutation.Event.t list) =
    populate_for_export ~mutation ~guard ~document
  in
  let prelude, event_lines, blob_lines =
    split_sections (export_bundle ~session ~mutation ~guard)
  in
  let events = List.length event_lines and blobs = List.length blob_lines in
  assert_forge_sane ~events ~blobs prelude event_lines blob_lines;
  let duplicate =
    match blob_lines with
    | line :: _ -> line
    | [] -> fail "the export must carry blobs"
  in
  match
    Store.Bundle.decode
      (forge_bundle ~events ~blobs:(blobs + 1)
         (prelude @ event_lines @ blob_lines @ [ duplicate ]))
  with
  | Error (Store.Bundle.Error.Corrupt _) -> ()
  | Ok _ -> fail "a duplicated blob reference must be rejected"
  | Error Store.Bundle.Error.Truncated ->
      fail "a duplicated blob is damage, not truncation"

(* A blob no event references is incoherent content — the bundle carries
   exactly the referenced images, no more. *)
let bundle_rejects_unreferenced_blobs () =
  with_store "unref" @@ fun ~sw ~base:_ ~session ~mutation ->
  let seed_session id =
    let document =
      ok_store "create"
        (Store.Session.create session
           (session_fixture ~id ~at:1_000 ~events:(open_claim_events ()) ()))
    in
    (document, acquire ~sw session id)
  in
  let document, guard = seed_session "s-main" in
  let (_ : Mutation.Event.t list) =
    populate_for_export ~mutation ~guard ~document
  in
  let donor_document, donor_guard = seed_session "s-donor" in
  let donor_result = created_result ~path:"g.ml" ~contents:"gamma\n" in
  ok_append "donor append_edit"
    (Store.Mutation.append_edit mutation ~fence:donor_guard
       ~document:donor_document
       ~entries:(Edit.Result.entries donor_result)
       (edit_event ~claim:"claim-donor" donor_result));
  let stolen =
    let _, _, donor_blobs =
      split_sections (export_bundle ~session ~mutation ~guard:donor_guard)
    in
    match donor_blobs with
    | line :: _ -> line
    | [] -> fail "the donor export must carry a blob"
  in
  let prelude, event_lines, blob_lines =
    split_sections (export_bundle ~session ~mutation ~guard)
  in
  let events = List.length event_lines and blobs = List.length blob_lines in
  assert_forge_sane ~events ~blobs prelude event_lines blob_lines;
  match
    Store.Bundle.decode
      (forge_bundle ~events ~blobs:(blobs + 1)
         (prelude @ event_lines @ blob_lines @ [ stolen ]))
  with
  | Error (Store.Bundle.Error.Corrupt _) -> ()
  | Ok _ -> fail "a blob no event references must be rejected"
  | Error Store.Bundle.Error.Truncated ->
      fail "an unreferenced blob is damage, not truncation"

(* Decoded events replay through [State.of_events] — a semantically invalid
   history behind a coherent manifest is still corruption. *)
let bundle_replays_events_on_decode () =
  with_fenced "replay"
  @@ fun ~sw:_ ~base:_ ~session ~mutation ~id:_ ~guard ~document ->
  let (_ : Mutation.Event.t list) =
    populate_for_export ~mutation ~guard ~document
  in
  let prelude, event_lines, blob_lines =
    split_sections (export_bundle ~session ~mutation ~guard)
  in
  let events = List.length event_lines and blobs = List.length blob_lines in
  assert_forge_sane ~events ~blobs prelude event_lines blob_lines;
  let duplicate =
    match event_lines with
    | line :: _ -> line
    | [] -> fail "the export must carry events"
  in
  match
    Store.Bundle.decode
      (forge_bundle ~events:(events + 1) ~blobs
         (prelude @ event_lines @ [ duplicate ] @ blob_lines))
  with
  | Error (Store.Bundle.Error.Corrupt _) -> ()
  | Ok _ -> fail "a history that does not replay must be rejected"
  | Error Store.Bundle.Error.Truncated ->
      fail "an invalid history is damage, not truncation"

(* A coherent manifest cannot make one session's mutation ledger belong to
   another.  This splices A's document with B's valid event/blob sections and
   recomputes the digest, leaving correlation as the only rejecting invariant.
*)
let bundle_rejects_cross_session_splices () =
  with_store "bundle-splice" @@ fun ~sw ~base ~session:store ~mutation ->
  let seed id call_id =
    let events, claim = open_claim_fixture ~call_id in
    let document =
      ok_store ("create " ^ id)
        (Store.Session.create store (session_fixture ~id ~at:1_000 ~events ()))
    in
    (document, claim, acquire ~sw store id)
  in
  let document_a, claim_a, guard_a = seed "s-bundle-a" "call-bundle-a" in
  let document_b, claim_b, guard_b = seed "s-bundle-b" "call-bundle-b" in
  equal session_id_value ~msg:"the recipient document is session A"
    (sid "s-bundle-a")
    (Store.Session.Document.id document_a);
  is_true ~msg:"both source documents are physically distinct"
    (Sys.file_exists (document_path base "s-bundle-a")
    && Sys.file_exists (document_path base "s-bundle-b"));
  let result_b = created_result ~path:"spliced.ml" ~contents:"from-b\n" in
  let event_b =
    edit_event_for ~turn:tool_turn
      ~claim:(Session.Tool_claim.Started.id claim_b)
      result_b
  in
  ok_append "append donor event"
    (Store.Mutation.append_edit mutation ~fence:guard_b ~document:document_b
       ~entries:(Edit.Result.entries result_b)
       event_b);
  let prelude_a, event_lines_a, blob_lines_a =
    split_sections (export_bundle ~session:store ~mutation ~guard:guard_a)
  in
  let prelude_b, event_lines_b, blob_lines_b =
    split_sections (export_bundle ~session:store ~mutation ~guard:guard_b)
  in
  assert_forge_sane
    ~events:(List.length event_lines_a)
    ~blobs:(List.length blob_lines_a) prelude_a event_lines_a blob_lines_a;
  assert_forge_sane
    ~events:(List.length event_lines_b)
    ~blobs:(List.length blob_lines_b) prelude_b event_lines_b blob_lines_b;
  is_false ~msg:"the fixture claims are genuinely session-distinct"
    (Session.Tool_claim.Id.equal
       (Session.Tool_claim.Started.id claim_a)
       (Session.Tool_claim.Started.id claim_b));
  match
    Store.Bundle.decode
      (forge_bundle
         ~events:(List.length event_lines_b)
         ~blobs:(List.length blob_lines_b)
         (prelude_a @ event_lines_b @ blob_lines_b))
  with
  | Error (Store.Bundle.Error.Corrupt _) -> ()
  | Ok _ -> fail "document A must not accept session B's mutation sections"
  | Error Store.Bundle.Error.Truncated ->
      fail "a recomputed cross-session manifest is corruption, not truncation"

(* Document round-trip law over generated sessions. *)

let documents_round_trip_over_generated_sessions () =
  with_store "gen" @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ->
  let seed = windtrap_seed () in
  let random = Random.State.make [| seed |] in
  let tame = "abcdefghijklmnopqrstuvwxyz0123456789-" in
  let random_tame low high =
    let length = low + Random.State.int random (high - low + 1) in
    String.init length (fun _ ->
        tame.[Random.State.int random (String.length tame)])
  in
  let message_alphabet = [ 'a'; 'z'; '"'; '\\'; '\n'; '\000'; ' ' ] in
  let random_text () =
    let length = 1 + Random.State.int random 8 in
    String.init length (fun _ ->
        List.nth message_alphabet
          (Random.State.int random (List.length message_alphabet)))
  in
  let check label id =
    let created_at = Random.State.int random 1_000_000 in
    let title =
      if Random.State.bool random then Some ("t-" ^ random_tame 1 8) else None
    in
    let events =
      List.init (Random.State.int random 4) (fun _ ->
          user_event (random_text ()))
    in
    let supplied =
      Session.touch
        (time (created_at + Random.State.int random 1_000))
        (session_fixture ?title ~events ~id ~at:created_at ())
    in
    let created =
      ok_store (label ^ ": create") (Store.Session.create store supplied)
    in
    let loaded =
      ok_store (label ^ ": load") (Store.Session.load store (sid id))
    in
    equal string
      ~msg:
        (Printf.sprintf "%s (seed %d): loaded bytes re-encode identically" label
           seed)
      (encode_session supplied)
      (encode_session (Store.Session.Document.session loaded));
    equal digest_value
      ~msg:(label ^ ": created and loaded revisions agree")
      (Store.Session.Document.revision created)
      (Store.Session.Document.revision loaded);
    ignore
      (require_ok ~msg:(label ^ ": remove") (Store.Session.remove store loaded))
  in
  (* Hostile ids pin the escaped path encoding: traversal and separator
     bytes must land inside [sessions/], not structure it. *)
  List.iteri
    (fun index id -> check (Printf.sprintf "hostile %d" index) id)
    [ ".."; "a/b"; "sp ace"; "per%cent"; "col:on"; "Mixed.Case" ];
  for index = 0 to 19 do
    check (Printf.sprintf "generated %d" index) (random_tame 1 12 ^ "-g")
  done

(* Adjudicated changes: verify-on-exists, layout, scan kind, decode version,
   Io change (B3, B9, B10, B8). *)

(* A pre-existing blob is verified against its reference, never trusted (B3):
   an externally damaged file at the content-derived path is [Blob_mismatch],
   and the composite appends no event that would reference it. *)
let put_blob_verifies_a_pre_existing_blob () =
  with_fenced "putverify"
  @@ fun ~sw:_ ~base ~session:_ ~mutation ~id ~guard ~document ->
  let contents = "honest bytes\n" in
  let first = created_result ~path:"a.ml" ~contents in
  let e1 = edit_event ~claim:"claim-a" first in
  ok_append "append_edit"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries first)
       e1);
  let file =
    match blob_file_with base id contents with
    | Some file -> file
    | None -> fail "the stored blob file must exist"
  in
  write_file file "tampered!";
  let reference = Mentat_digest.Content_ref.of_contents contents in
  let second = created_result ~path:"b.ml" ~contents in
  (match
     Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries second)
       (edit_event ~ordinal:1 ~claim:"claim-b" second)
   with
  | Error (Store.Mutation.Error.Blob_mismatch { expected; actual }) ->
      equal content_ref_value ~msg:"the mismatch names the requested reference"
        reference expected;
      equal content_ref_value
        ~msg:"actual hashes the tampered pre-existing bytes"
        (Mentat_digest.Content_ref.of_contents "tampered!")
        actual
  | Ok _ ->
      fail "a put over a damaged pre-existing blob must not append its event"
  | Error error -> failf "wrong error: %a" Store.Mutation.Error.pp error);
  equal (list event_value) ~msg:"the rejected composite appended no event"
    [ e1 ] (read_events mutation id)

(* The attachment namespace is content-addressed, write-once, idempotent, and
   fence-free (its operations take no guard). It is distinct from the mutation
   blob namespace and from other sessions. *)
let attachment_store_is_content_addressed () =
  with_store "attachments" @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ->
  let id = sid "s-att" in
  let _created =
    ok_store "create"
      (Store.Session.create store (session_fixture ~id:"s-att" ~at:1_000 ()))
  in
  let png = "\x89PNG\r\n\x1a\nfake image bytes" in
  let reference =
    ok_attachment "put" (Store.Attachment.put store ~session:id png)
  in
  equal content_ref_value ~msg:"the reference is the content address"
    (Mentat_digest.Content_ref.of_contents png)
    reference;
  equal (option string) ~msg:"get round-trips the stored bytes" (Some png)
    (ok_attachment "get" (Store.Attachment.get store ~session:id reference));
  equal content_ref_value ~msg:"a second put of identical bytes is idempotent"
    reference
    (ok_attachment "put again" (Store.Attachment.put store ~session:id png));
  let absent = Mentat_digest.Content_ref.of_contents "never stored" in
  equal (option string) ~msg:"an absent reference reads None" None
    (ok_attachment "get absent" (Store.Attachment.get store ~session:id absent));
  let jpeg = "\xff\xd8\xff other image bytes" in
  let reference2 =
    ok_attachment "put jpeg" (Store.Attachment.put store ~session:id jpeg)
  in
  is_false ~msg:"distinct bytes yield a distinct reference"
    (Mentat_digest.Content_ref.equal reference reference2);
  equal (option string) ~msg:"the second blob round-trips independently"
    (Some jpeg)
    (ok_attachment "get jpeg"
       (Store.Attachment.get store ~session:id reference2));
  (* The attachment namespace is distinct from the mutation blob namespace: the
     image bytes are not visible through the mutation blob read. *)
  equal (option string)
    ~msg:"the attachment blob is not in the mutation namespace" None
    (ok_mutation "mutation blob"
       (Store.Mutation.blob store ~session:id reference));
  (* Session-scoped: a different session does not see the blob. *)
  let _other =
    ok_store "create other"
      (Store.Session.create store (session_fixture ~id:"s-other" ~at:1_000 ()))
  in
  equal (option string) ~msg:"a different session does not see the blob" None
    (ok_attachment "get cross-session"
       (Store.Attachment.get store ~session:(sid "s-other") reference))

(* Opening a root whose layout child is a regular file is refused, not adopted
   (B9): every op under it would be misplaced. *)
let open_refuses_a_non_directory_layout_child () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let base = Unix.realpath (temp_dir ~prefix:"mentat-store-layout" ()) in
  write_file (Filename.concat base "sessions") "not a directory";
  Eio.Switch.run @@ fun sw ->
  match Store.open_ ~sw (Eio.Path.( / ) fs base) with
  | Error (Store.Error.Layout { path; message = _ }) ->
      equal string ~msg:"the layout refusal names the offending child"
        "sessions" path
  | Ok _ -> fail "a regular-file sessions/ must be refused at open"
  | Error (Store.Error.Io io) -> failf "wrong error: %a" Store.Io.pp io

(* A non-directory entry under [sessions/] is skipped after its kind is checked,
   not crashed through (B9): the scan surfaces a stat failure as an error and a
   stray file as neither a session nor corruption. *)
let scan_skips_non_directory_entries () =
  with_store "scan-stray" @@ fun ~sw:_ ~base ~session:store ~mutation:_ ->
  let (_ : Store.Session.Document.t) =
    ok_store "create"
      (Store.Session.create store (session_fixture ~id:"s-real" ~at:1_000 ()))
  in
  write_file (Filename.concat base "sessions/stray") "not a session directory";
  let documents, corrupt = ok_store "scan" (Store.Session.scan store) in
  equal int ~msg:"the real session still lists" 1 (List.length documents);
  equal int ~msg:"a stray non-directory entry is skipped, never corrupt" 0
    (List.length corrupt)

(* The decoder compares the header's document version with the embedded
   document's own; a coherent digest cannot launder a version the document does
   not carry. *)
let bundle_rejects_a_document_version_mismatch () =
  with_fenced "version"
  @@ fun ~sw:_ ~base:_ ~session ~mutation ~id:_ ~guard ~document ->
  let (_ : Mutation.Event.t list) =
    populate_for_export ~mutation ~guard ~document
  in
  let prelude, event_lines, blob_lines =
    split_sections (export_bundle ~session ~mutation ~guard)
  in
  let tampered_header =
    match
      Jsont_bytesrw.encode_string Store.Bundle.header_jsont
        (Store.Bundle.tag, Store.Bundle.format_version, 4242)
    with
    | Ok text -> text
    | Error message -> failf "header does not encode: %s" message
  in
  let prelude =
    match prelude with
    | _header :: document_line -> tampered_header :: document_line
    | [] -> fail "the bundle must carry a header"
  in
  let events = List.length event_lines and blobs = List.length blob_lines in
  match
    Store.Bundle.decode
      (forge_bundle ~events ~blobs (prelude @ event_lines @ blob_lines))
  with
  | Error (Store.Bundle.Error.Corrupt message) ->
      is_true ~msg:"the mismatch is reported as a version disagreement"
        (String.includes ~affix:"document version" message)
  | Ok _ -> fail "a header/document version mismatch must be Corrupt"
  | Error Store.Bundle.Error.Truncated ->
      fail "a version mismatch is corruption, not truncation"

(* Branching (fork / rewind seed). *)

(* A fork seeds the child's mutation store from the parent's and the child then
   reads back exactly the copied ledger — the diff/revert evidence its inherited
   turns authored, never an empty ledger. The child document here shares the
   parent's claim so the copied events correlate; the branch document itself is
   [Mentat_session.fork]'s job, exercised end to end in the agent and blackbox
   suites. *)
let fork_seeds_the_child_ledger_and_blobs () =
  with_fenced "fork"
  @@ fun ~sw:_ ~base ~session:store ~mutation ~id ~guard ~document ->
  let result = created_result ~path:"note.txt" ~contents:"hello\n" in
  ok_append "append_edit"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result)
       (edit_event ~claim:"c" result));
  let parent_events = read_events store id in
  is_true ~msg:"the parent's blob landed"
    (Option.is_some (blob_file_with base id "hello\n"));
  let child_id = "child-fork" in
  let child_session =
    session_fixture ~id:child_id ~at:2_000 ~events:(open_claim_events ()) ()
  in
  let _ : Store.Session.Document.t =
    ok_store "fork"
      (Store.fork store ~from:(sid id) ~events:parent_events child_session)
  in
  equal (list event_value) ~msg:"the child reads back the copied ledger"
    parent_events
    (read_events store child_id);
  is_true ~msg:"the child holds its own copy of the referenced blob"
    (Option.is_some (blob_file_with base child_id "hello\n"))

(* A branch's document-media [`Ref]s are document refs, not mutation-event refs;
   the fork walks [Mentat_session.media_refs] of the child and copies each
   attachment blob from the parent, so the branch is self-contained and
   resolves every media reference its inherited turns carry. *)
let fork_copies_attachment_blobs () =
  with_store "fork-attach" @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ->
  let parent =
    session_fixture ~id:"att-parent" ~at:1_000 ~events:media_events ()
  in
  let _ : Store.Session.Document.t =
    ok_store "create parent" (Store.Session.create store parent)
  in
  let stored =
    ok_attachment "put"
      (Store.Attachment.put store ~session:(sid "att-parent")
         attachment_image_bytes)
  in
  equal content_ref_value
    ~msg:"the stored reference is the document's media ref" attachment_ref
    stored;
  (* The child branch document carries the same media reference. *)
  let child =
    session_fixture ~id:"att-child" ~at:2_000 ~events:media_events ()
  in
  let _ : Store.Session.Document.t =
    ok_store "fork" (Store.fork store ~from:(sid "att-parent") ~events:[] child)
  in
  equal (option string) ~msg:"the child resolves the copied attachment blob"
    (Some attachment_image_bytes)
    (ok_attachment "child get"
       (Store.Attachment.get store ~session:(sid "att-child") attachment_ref))

(* Blob ownership: the child's copy is its own, reclaimed only with the child.
   Removing the parent — the one blob reclamation point — leaves the child's
   blob intact, so a shared blob could never break the survivor. *)
let fork_child_blob_survives_parent_removal () =
  with_fenced "fork-own"
  @@ fun ~sw:_ ~base ~session:store ~mutation ~id ~guard ~document ->
  let result = created_result ~path:"note.txt" ~contents:"owned\n" in
  ok_append "append_edit"
    (Store.Mutation.append_edit mutation ~fence:guard ~document
       ~entries:(Edit.Result.entries result)
       (edit_event ~claim:"c" result));
  let parent_events = read_events store id in
  let child_id = "child-own" in
  let child_session =
    session_fixture ~id:child_id ~at:2_000 ~events:(open_claim_events ()) ()
  in
  let _ : Store.Session.Document.t =
    ok_store "fork"
      (Store.fork store ~from:(sid id) ~events:parent_events child_session)
  in
  (* [remove] takes the run fence itself, so release the parent's guard. *)
  Store.Run_lock.release guard;
  ignore
    (require_ok ~msg:"the parent is physically removed"
       (Store.Session.remove store document));
  is_true ~msg:"the parent's blobs are reclaimed with it"
    (Option.is_none (blob_file_with base id "owned\n"));
  is_true ~msg:"the child's own blob copy survives"
    (Option.is_some (blob_file_with base child_id "owned\n"));
  equal (list event_value)
    ~msg:"the child's ledger still reads back after the parent is gone"
    parent_events
    (read_events store child_id)

(* The document is the branch's commit point: a seed failure writes no document,
   so the branch is atomic — no child exists holding a settlement whose fact the
   seed did not finish writing. *)
let create_seeded_seed_failure_writes_no_document () =
  with_store "seed-fail" @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ->
  let child = session_fixture ~id:"seedless" ~at:1_000 () in
  let boom = Store.Session.Error.Not_found (sid "seedless") in
  (match
     Store.Session.create_seeded store child ~seed:(fun () -> Error boom)
   with
  | Error (Store.Session.Error.Not_found _) -> ()
  | Ok _ -> fail "a seed failure must not create the document"
  | Error e -> failf "wrong error: %a" Store.Session.Error.pp e);
  match Store.Session.load store (sid "seedless") with
  | Error (Store.Session.Error.Not_found _) -> ()
  | Ok _ -> fail "no document may exist after a seed failure"
  | Error e -> failf "wrong error: %a" Store.Session.Error.pp e

(* A branch into a taken id is refused by the same [Already_exists] guard as a
   plain create, before any seeding. *)
let fork_refuses_a_taken_id () =
  with_fenced "fork-dup"
  @@ fun ~sw:_ ~base:_ ~session:store ~mutation:_ ~id ~guard:_ ~document:_ ->
  let clash = session_fixture ~id ~at:2_000 () in
  match Store.fork store ~from:(sid id) ~events:[] clash with
  | Error (Store.Session.Error.Already_exists reported) ->
      equal session_id_value ~msg:"the refusal names the taken id" (sid id)
        reported
  | Ok _ -> fail "a fork into a taken id must be refused"
  | Error e -> failf "wrong error: %a" Store.Session.Error.pp e

(* On-disk layout probe. *)

(* [on_disk_dir] is the one place the [sessions/<escaped id>] layout resolves to
   a native path, for external tooling that stats sidecar artifacts. It locates a
   real session's directory, document included. *)
let on_disk_dir_locates_the_session_directory () =
  with_store "on-disk-dir" @@ fun ~sw:_ ~base ~session:store ~mutation:_ ->
  let id = sid "s-ondisk" in
  let (_ : Store.Session.Document.t) =
    ok_store "create"
      (Store.Session.create store (session_fixture ~id:"s-ondisk" ~at:1_000 ()))
  in
  let dir = Store.Session.on_disk_dir store id in
  is_true ~msg:"the resolved dir names the escaped session directory"
    (String.ends_with ~suffix:"sessions/s-ondisk" dir);
  is_true ~msg:"it is an absolute path under the store root"
    (String.starts_with ~prefix:base dir);
  is_true ~msg:"the resolved directory exists" (Sys.is_directory dir);
  is_true ~msg:"the directory holds the session document"
    (Sys.file_exists (Filename.concat dir "session.json"))

(* Workspace-boundary captures (Capture). *)

(* The capture store resolves under the same opened root as every other view, at
   [snapshots/<key>]; the tests drive it directly with literal [paths]/[load]
   pairs, independent of the workspace-io walk the adapter supplies. *)
let with_capture name fn =
  with_store name @@ fun ~sw:_ ~base ~session:root ~mutation:_ ->
  fn ~base (Capture.Store.create root ~key:"workspace-key")

let capture_blobs_dir base =
  Filename.concat base "snapshots/workspace-key/blobs"

let ok_capture label store ~paths ~load =
  match Capture.capture store ~paths ~load with
  | Ok capture -> capture
  | Error e -> failf "%s: capture failed: %s" label (Capture.Error.message e)

let capture_load_of table rel =
  match List.find_opt (fun (p, _) -> Rel.equal p rel) table with
  | Some (_, loaded) -> loaded
  | None -> Capture.Skip

let observed_testable =
  Testable.structural ~pp:(fun ppf -> function
    | Capture.File bytes -> Format.fprintf ppf "File %S" bytes
    | Capture.Absent -> Format.fprintf ppf "Absent")

let read_observed label store reference rel =
  match Capture.read store ~reference rel with
  | Ok observed -> observed
  | Error e -> failf "%s: read failed: %s" label (Capture.Error.message e)

let capture_round_trips_covered_files () =
  with_capture "roundtrip" @@ fun ~base:_ store ->
  let table =
    [
      (rel "a.txt", Capture.Loaded "alpha");
      (rel "src/b.ml", Capture.Loaded "let () = ()\n");
      (rel "src/nested/c.txt", Capture.Loaded "");
    ]
  in
  let paths = List.map fst table in
  let capture =
    ok_capture "roundtrip" store ~paths ~load:(capture_load_of table)
  in
  equal int ~msg:"no exclusions" 0 capture.Capture.excluded;
  is_true ~msg:"reference is non-empty"
    (String.length capture.Capture.reference > 0);
  equal observed_testable ~msg:"a.txt" (Capture.File "alpha")
    (read_observed "roundtrip" store capture.Capture.reference (rel "a.txt"));
  equal observed_testable ~msg:"src/b.ml" (Capture.File "let () = ()\n")
    (read_observed "roundtrip" store capture.Capture.reference (rel "src/b.ml"));
  equal observed_testable ~msg:"empty file round-trips" (Capture.File "")
    (read_observed "roundtrip" store capture.Capture.reference
       (rel "src/nested/c.txt"));
  equal observed_testable ~msg:"uncovered path is Absent" Capture.Absent
    (read_observed "roundtrip" store capture.Capture.reference
       (rel "does/not/exist"))

let identical_trees_yield_identical_references () =
  with_capture "determinism" @@ fun ~base:_ store ->
  let table =
    [
      (rel "a.txt", Capture.Loaded "same"); (rel "b.txt", Capture.Loaded "bytes");
    ]
  in
  let paths = List.map fst table in
  let first = ok_capture "det-1" store ~paths ~load:(capture_load_of table) in
  let second = ok_capture "det-2" store ~paths ~load:(capture_load_of table) in
  equal string ~msg:"same tree, same reference" first.Capture.reference
    second.Capture.reference

let empty_capture_is_available () =
  with_capture "empty" @@ fun ~base:_ store ->
  let capture = ok_capture "empty" store ~paths:[] ~load:(capture_load_of []) in
  equal int ~msg:"no exclusions" 0 capture.Capture.excluded;
  is_true ~msg:"empty capture still has a reference"
    (String.length capture.Capture.reference > 0);
  equal observed_testable ~msg:"nothing was covered" Capture.Absent
    (read_observed "empty" store capture.Capture.reference (rel "anything"))

let excluded_paths_are_counted_and_absent () =
  with_capture "excluded" @@ fun ~base:_ store ->
  let table =
    [
      (rel "kept.txt", Capture.Loaded "kept");
      (rel "too-big.bin", Capture.Excluded);
      (rel "vanished.txt", Capture.Skip);
    ]
  in
  let paths = List.map fst table in
  let capture =
    ok_capture "excluded" store ~paths ~load:(capture_load_of table)
  in
  equal int ~msg:"one excluded, skip not counted" 1 capture.Capture.excluded;
  equal observed_testable ~msg:"kept file present" (Capture.File "kept")
    (read_observed "excluded" store capture.Capture.reference (rel "kept.txt"));
  equal observed_testable ~msg:"excluded file is Absent" Capture.Absent
    (read_observed "excluded" store capture.Capture.reference
       (rel "too-big.bin"));
  equal observed_testable ~msg:"skipped file is Absent" Capture.Absent
    (read_observed "excluded" store capture.Capture.reference
       (rel "vanished.txt"))

(* Plant a regular file where the capture store's [snapshots/] tree belongs, so
   [mkdirs] of [snapshots/<key>/blobs/<shard>] fails with ENOTDIR — a genuine
   capture failure the adapter maps to a [Degraded] checkpoint. *)
let capture_failure_when_store_path_is_a_file () =
  with_capture "failure" @@ fun ~base store ->
  write_file (Filename.concat base "snapshots") "not a directory";
  let table = [ (rel "a.txt", Capture.Loaded "alpha") ] in
  match
    Capture.capture store ~paths:(List.map fst table)
      ~load:(capture_load_of table)
  with
  | Ok _ -> fail "expected capture to fail when the snapshots path is a file"
  | Error _ -> ()

let read_rejects_a_malformed_reference () =
  with_capture "malformed-ref" @@ fun ~base:_ store ->
  match Capture.read store ~reference:"not-a-token" (rel "a.txt") with
  | Ok _ -> fail "expected a malformed reference to be rejected"
  | Error _ -> ()

(* Overwrite every blob with different bytes so its content no longer matches the
   reference the manifest names; the read must fail loudly rather than return
   trusted bytes. *)
let read_detects_a_corrupt_blob () =
  with_capture "corrupt-blob" @@ fun ~base store ->
  let table = [ (rel "a.txt", Capture.Loaded "alpha") ] in
  let capture =
    ok_capture "corrupt" store ~paths:(List.map fst table)
      ~load:(capture_load_of table)
  in
  let blobs = capture_blobs_dir base in
  if Sys.file_exists blobs then
    Array.iter
      (fun shard ->
        let shard_dir = Filename.concat blobs shard in
        if Sys.is_directory shard_dir then
          Array.iter
            (fun name -> write_file (Filename.concat shard_dir name) "tampered")
            (Sys.readdir shard_dir))
      (Sys.readdir blobs);
  match
    Capture.read store ~reference:capture.Capture.reference (rel "a.txt")
  with
  | Ok (Capture.File "alpha") -> fail "read returned tampered bytes as trusted"
  | Ok _ | Error _ -> ()

(* Suite. *)

let () =
  run "mentat.store"
    [
      (* Session documents *)
      test "create and load round-trip byte-exact documents"
        create_load_round_trip_is_byte_exact;
      test "commit is compare-and-set carrying both digests"
        commit_is_cas_with_both_digests;
      test "corrupt, missing, and non-file documents are structured"
        corrupt_and_missing_documents_are_structured;
      test "scan returns every session with corrupt facts"
        scan_returns_every_session_and_corrupt_facts;
      test "create refuses a leftover session directory"
        create_refuses_a_leftover_directory;
      test "scan surfaces leftover directories as corrupt"
        scan_surfaces_leftover_directories;
      test "remove is revision-checked and reclaims the session directory"
        remove_is_revision_checked_and_reclaims;
      test "remove is refused while a driver holds the fence"
        remove_is_refused_while_the_fence_is_held;
      (* Branching *)
      test "fork seeds the child ledger and blobs, and the child reads it back"
        fork_seeds_the_child_ledger_and_blobs;
      test "fork copies document-media attachment blobs into the child"
        fork_copies_attachment_blobs;
      test "a forked child's blob copy survives the parent's removal"
        fork_child_blob_survives_parent_removal;
      test "create_seeded writes no document when the seed fails"
        create_seeded_seed_failure_writes_no_document;
      test "fork refuses a taken id before seeding" fork_refuses_a_taken_id;
      (* Run lock *)
      test "the fence excludes a second acquisition and names the holder"
        fence_excludes_and_names_the_holder;
      test "the fence probe observes without contending"
        holder_probes_without_contending;
      test "the fence probe never reads a held fence Free"
        holder_never_reads_a_held_fence_free;
      test "the stamp is a cheap document identity"
        stamp_is_cheap_document_identity;
      test "released guards are refused by every mutation append"
        released_guards_are_refused_by_appends;
      test "a guard never passes against another root's registry"
        guards_never_cross_root_registries;
      test "a stale release never frees a successor's fence"
        stale_release_never_frees_a_successor_fence;
      (* Mutation *)
      test "failed appends retry without duplication"
        failed_appends_retry_without_duplication;
      test "fenced appends round-trip events in order"
        fenced_appends_round_trip_in_order;
      test "an append returns the advanced anchor a fresh read yields"
        append_returns_the_read_anchor;
      test "conflicting batches index over the whole history"
        conflicting_batches_index_the_whole_history;
      test "torn tails repair and damaged lines are located"
        torn_tails_repair_and_damaged_lines_locate;
      test "the document lock serializes commit and mutation"
        document_lock_serializes_commit_and_mutation;
      test "a cancelled document-lock waiter releases the lock"
        cancelled_document_lock_waiter_releases_the_lock;
      test "correlation and stale-document rejections write nothing"
        correlation_rejections_write_nothing;
      test "a settled claim is history, not live append authority"
        settled_claim_is_history_not_live_authority;
      test "After_recovery requires a prior ambiguous claim"
        after_recovery_requires_prior_ambiguity;
      test "append_edit validates before persisting blobs"
        append_edit_validates_before_persisting_blobs;
      test "blob reads verify content and distinguish absence"
        blob_reads_verify_and_distinguish_absence;
      test "blobs round-trip over generated bytes"
        blob_round_trip_over_generated_bytes;
      (* Revert lifecycle *)
      test "the revert lifecycle round-trips through its composite ops"
        revert_lifecycle_round_trips;
      test
        "a clean merge's restore image is put durable before the started event"
        merge_blob_is_durable;
      test "revert settlement derivation is enforced"
        revert_settlement_derivation_is_enforced;
      test "revert_apply runs the fenced checkpoint/started/settled lifecycle"
        revert_apply_runs_the_fenced_lifecycle;
      test "revert_apply threads an override to apply a non-contiguous revert"
        revert_apply_override_applies_non_contiguous;
      test "revert_apply reports nothing-to-revert for a None selection"
        revert_apply_reports_nothing_to_revert;
      test "revert_apply refuses a stale selection without minting a fact"
        revert_apply_refuses_a_stale_selection;
      (* Review *)
      test "review records round-trip and missing is Ok None"
        review_round_trips_and_missing_is_none;
      test "review corruption is loud and replacement is CAS"
        review_corruption_is_loud_and_replacement_is_cas;
      test "review load refuses a base mismatch"
        review_load_refuses_a_base_mismatch;
      test "commit on an externally deleted record is Vanished"
        commit_on_an_externally_deleted_record_vanishes;
      test "review commit refuses a base mismatch"
        commit_refuses_a_base_mismatch;
      (* Export *)
      test "export bundles round-trip the complete session"
        export_round_trips_the_complete_session;
      test "export includes document-media attachment blobs"
        export_includes_document_media_blobs;
      test "tampered or truncated bundles fail loudly"
        tampered_bundles_fail_loudly;
      test "overridden reverts export and decode cleanly"
        overridden_reverts_export_cleanly;
      test "bundles with duplicate blobs are rejected"
        bundle_rejects_duplicate_blobs;
      test "bundles with unreferenced blobs are rejected"
        bundle_rejects_unreferenced_blobs;
      test "bundle events are replayed on decode"
        bundle_replays_events_on_decode;
      test "bundles reject cross-session document/event splices"
        bundle_rejects_cross_session_splices;
      (* Generated documents *)
      test "documents round-trip over generated sessions"
        documents_round_trip_over_generated_sessions;
      (* Adjudicated changes *)
      test "attachment store is content-addressed, idempotent, and fence-free"
        attachment_store_is_content_addressed;
      test "put verifies a pre-existing blob against its reference"
        put_blob_verifies_a_pre_existing_blob;
      test "open refuses a non-directory layout child"
        open_refuses_a_non_directory_layout_child;
      test "scan skips non-directory entries under sessions/"
        scan_skips_non_directory_entries;
      test "the decoder rejects a document version mismatch"
        bundle_rejects_a_document_version_mismatch;
      (* On-disk layout probe *)
      test "on_disk_dir locates a session's on-disk directory"
        on_disk_dir_locates_the_session_directory;
      (* Workspace-boundary captures *)
      test "capture round-trips covered files" capture_round_trips_covered_files;
      test "identical trees yield identical references"
        identical_trees_yield_identical_references;
      test "an empty capture is available with a reference"
        empty_capture_is_available;
      test "excluded paths are counted and read Absent"
        excluded_paths_are_counted_and_absent;
      test "capture fails when the snapshots path is a file"
        capture_failure_when_store_path_is_a_file;
      test "read rejects a malformed reference"
        read_rejects_a_malformed_reference;
      test "read detects a corrupt blob" read_detects_a_corrupt_blob;
    ]
