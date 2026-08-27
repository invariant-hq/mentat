(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Runtime = Mentat_tui.Runtime
module Theme = Mentat_tui.Theme
module App = Mentat_tui.App
module Snapshot = Mentat_tui.Snapshot
module Startup = Mentat_tui.Startup
module Client = Mentat_client
module Driver = Client.Driver
module Feed = Client.Feed
module Session = Mentat_session
module Protocol = Mentat_protocol
module Mutation = Mentat_mutation
module Edit = Mentat_edit
module Workspace = Mentat_workspace
module Account = Mentat_provider.Account
module Login = Mentat_client.Login

let epoch = 1000.
let settle_budget = 20_000

module Child_observation = struct
  type t = Live | Drill

  let equal left right =
    match (left, right) with
    | Live, Live | Drill, Drill -> true
    | Live, Drill | Drill, Live -> false
end

module Model_readiness = struct
  let of_providers providers ~discoveries =
    Mentat_provider.Model_readiness.of_catalog
      (Mentat_provider.Catalog.make providers)
      ~discoveries
end

module Mutation_script = struct
  module Change = struct
    type t =
      | Create of { path : Lpath.Rel.t; contents : string }
      | Update of { path : Lpath.Rel.t; before : string; after : string }
      | Delete of { path : Lpath.Rel.t; before : string }

    let validate_path path =
      if Lpath.Rel.is_root path then
        invalid_arg "Tui.Mutation_script.Change: a change must name a file"

    let validate_text operation text =
      if not (String.is_valid_utf_8 text) then
        invalid_arg
          ("Tui.Mutation_script.Change." ^ operation
         ^ ": file contents must be valid UTF-8")

    let create ~path ~contents =
      validate_path path;
      validate_text "create" contents;
      Create { path; contents }

    let update ~path ~before ~after =
      validate_path path;
      validate_text "update" before;
      validate_text "update" after;
      if String.equal before after then
        invalid_arg
          "Tui.Mutation_script.Change.update: before and after must differ";
      Update { path; before; after }

    let delete ~path ~before =
      validate_path path;
      validate_text "delete" before;
      Delete { path; before }

    let path = function
      | Create { path; _ } | Update { path; _ } | Delete { path; _ } -> path

    let texts = function
      | Create { contents; _ } -> [ contents ]
      | Update { before; after; _ } -> [ before; after ]
      | Delete { before; _ } -> [ before ]
  end

  type t = {
    call_id : string;
    changes : Change.t list;
    observed : Lpath.Rel.t list;
  }

  let call_id t = t.call_id
  let duplicate_path paths path = List.exists (Lpath.Rel.equal path) paths

  let validate_paths ~kind paths =
    let rec loop seen = function
      | [] -> ()
      | path :: remaining ->
          if Lpath.Rel.is_root path then
            invalid_arg
              ("Tui.Mutation_script.make: " ^ kind ^ " must name files")
          else if duplicate_path seen path then
            invalid_arg ("Tui.Mutation_script.make: duplicate " ^ kind ^ " path")
          else loop (path :: seen) remaining
    in
    loop [] paths

  let make ~call_id ?(changes = []) ?(observed = []) () =
    if String.is_empty call_id then
      invalid_arg "Tui.Mutation_script.make: call_id must not be empty";
    if changes = [] && observed = [] then
      invalid_arg
        "Tui.Mutation_script.make: exact or observed evidence is required";
    let changed = List.map Change.path changes in
    validate_paths ~kind:"changed" changed;
    validate_paths ~kind:"observed" observed;
    if List.exists (duplicate_path changed) observed then
      invalid_arg
        "Tui.Mutation_script.make: observed paths must exclude exact changes";
    { call_id; changes; observed }
end

module Turn_script = struct
  type tool_outcome =
    | Returned of Mentat_tool.Output.t Mentat_tool.Result.t
    | Ambiguous

  type tool = { call : Mentat_llm.Tool.Call.t; outcome : tool_outcome }

  let tool ~call ~result = { call; outcome = Returned result }
  let ambiguous_tool ~call = { call; outcome = Ambiguous }
  let tool_call tool = tool.call
  let tool_outcome tool = tool.outcome

  type result =
    | Completed of {
        text : string;
        reasoning_summary : string list;
        usage : Mentat_llm.Usage.t option;
        tools : tool list;
      }
    | Failed of Mentat_llm.Error.t

  type t = {
    prompt : string;
    model : Mentat_llm.Model.t option;
    reasoning_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
    reasoning_deltas : string list;
    assistant_deltas : string list;
    downloads : Protocol.Progress.Model_download.t list;
    retries : Mentat_llm.Event.Retry.t list;
    usage : Mentat_llm.Usage.t option;
    task_boards : Session.Task.Board.t list;
    notices : Session.Notice.t list;
    mutations : Mutation_script.t list;
    result : result;
  }

  let validate_prompt prompt =
    if String.trim prompt = "" then
      invalid_arg "Tui.Turn_script: prompt must contain visible text"

  let validate_mutations tools mutations =
    let call_ids =
      List.map (fun tool -> Mentat_llm.Tool.Call.id (tool_call tool)) tools
    in
    let rec loop seen = function
      | [] -> ()
      | (mutation : Mutation_script.t) :: remaining ->
          let call_id = Mutation_script.call_id mutation in
          if not (List.exists (String.equal call_id) call_ids) then
            invalid_arg
              ("Tui.Turn_script.complete: mutation names unknown tool call "
             ^ call_id)
          else if List.exists (String.equal call_id) seen then
            invalid_arg
              ("Tui.Turn_script.complete: duplicate mutation script for "
             ^ call_id)
          else loop (call_id :: seen) remaining
    in
    loop [] mutations

  let complete ?model ?reasoning_effort ?(reasoning_deltas = [])
      ?(assistant_deltas = []) ?(downloads = []) ?(retries = [])
      ?reasoning_summary ?usage ?(task_boards = []) ?(notices = [])
      ?(tools = []) ?(mutations = []) ~prompt text =
    validate_prompt prompt;
    if String.equal text "" then
      invalid_arg "Tui.Turn_script.complete: response text must not be empty";
    validate_mutations tools mutations;
    let reasoning_summary =
      Option.value reasoning_summary ~default:reasoning_deltas
    in
    {
      prompt;
      model;
      reasoning_effort;
      reasoning_deltas;
      assistant_deltas;
      downloads;
      retries;
      usage;
      task_boards;
      notices;
      mutations;
      result = Completed { text; reasoning_summary; usage; tools };
    }

  let fail ?(reasoning_deltas = []) ?(assistant_deltas = []) ?(task_boards = [])
      ~prompt error =
    validate_prompt prompt;
    {
      prompt;
      model = None;
      reasoning_effort = None;
      reasoning_deltas;
      assistant_deltas;
      downloads = [];
      retries = [];
      usage = None;
      task_boards;
      notices = [];
      mutations = [];
      result = Failed error;
    }
end

module Decision_continuation = struct
  type t = { turn : Session.Turn.Id.t; tools : Turn_script.tool list }

  let tools ~turn = function
    | [] ->
        invalid_arg
          "Tui.Decision_continuation.tools: at least one tool is required"
    | tools -> { turn; tools }
end

module Login_script = struct
  type t = {
    provider : Mentat_llm.Provider.t;
    method_ : Mentat_provider.Auth.Login.Id.t;
    steps : (Login.step, Protocol.Error.t) result list;
  }

  let terminal = function
    | Ok (Login.Saved _ | Login.Cancelled) | Error _ -> true
    | Ok (Login.Progress _) -> false

  let make ~provider ~method_ steps =
    match List.rev steps with
    | [] -> invalid_arg "Tui.Login_script.make: steps must not be empty"
    | final :: preceding ->
        if not (terminal final) then
          invalid_arg "Tui.Login_script.make: final step must settle the login";
        if List.exists terminal preceding then
          invalid_arg
            "Tui.Login_script.make: a terminal result must be the final step";
        { provider; method_; steps }
end

module Compaction_script = struct
  type installed = {
    reason : Session.Compaction.Reason.t;
    request_digest : Mentat_digest.t;
    summary_messages : Mentat_llm.Message.t list;
    summarized_upto : int;
    usage : Mentat_llm.Usage.t option;
    context : Session.Compaction.Context_tokens.t option;
  }

  type t = Installed of installed | Skipped | Failed of Protocol.Error.t

  let template_claim =
    Session.Provider_request.Id.of_string "visual-compaction-template"

  let installed ~reason ~request_digest ~summary_messages ~summarized_upto
      ?usage ?context () =
    (* Reuse the owner constructor for every invariant which does not depend on
       the eventually active summary turn. The client responder replaces only
       this placeholder claim with the claim it appends immediately before the
       compaction fact. *)
    ignore
      (Session.Compaction.make ~reason ~provider_claim:template_claim
         ~request_digest ~summary_messages ~summarized_upto ?usage ?context ());
    Installed
      {
        reason;
        request_digest;
        summary_messages;
        summarized_upto;
        usage;
        context;
      }

  let materialize ~turn installed =
    let claim =
      Session.Provider_request.Started.make ~turn
        ~request_digest:installed.request_digest
    in
    let compaction =
      Session.Compaction.make ~reason:installed.reason
        ~provider_claim:(Session.Provider_request.Started.id claim)
        ~request_digest:installed.request_digest
        ~summary_messages:installed.summary_messages
        ~summarized_upto:installed.summarized_upto ?usage:installed.usage
        ?context:installed.context ()
    in
    (claim, compaction)

  let skipped = Skipped
  let failed error = Failed error
end

module Lifecycle_script = struct
  type operation =
    | Rename of { session : Session.Id.t; title : string }
    | Archive of Session.Id.t
    | Restore of Session.Id.t
    | Delete of Session.Id.t

  type t = { operation : operation; result : (unit, Protocol.Error.t) result }

  let rename ~session ~title result =
    { operation = Rename { session; title }; result }

  let archive ~session result = { operation = Archive session; result }
  let restore ~session result = { operation = Restore session; result }
  let delete ~session result = { operation = Delete session; result }

  let operation_session = function
    | Rename { session; _ } -> session
    | Archive session | Restore session | Delete session -> session

  let equal_operation left right =
    match (left, right) with
    | ( Rename { session = left_session; title = left_title },
        Rename { session = right_session; title = right_title } ) ->
        Session.Id.equal left_session right_session
        && String.equal left_title right_title
    | Archive left, Archive right
    | Restore left, Restore right
    | Delete left, Delete right ->
        Session.Id.equal left right
    | Rename _, (Archive _ | Restore _ | Delete _)
    | Archive _, (Rename _ | Restore _ | Delete _)
    | Restore _, (Rename _ | Archive _ | Delete _)
    | Delete _, (Rename _ | Archive _ | Restore _) ->
        false

  let describe = function
    | Rename { session; title } ->
        Printf.sprintf "rename %s to %S" (Session.Id.to_string session) title
    | Archive session -> "archive " ^ Session.Id.to_string session
    | Restore session -> "restore " ^ Session.Id.to_string session
    | Delete session -> "delete " ^ Session.Id.to_string session
end

module Turn_runtime = struct
  type held = {
    complete : unit -> unit;
    interrupt : unit -> unit;
    replace_tasks : Session.Task.Board.t -> unit;
    mutable task_boards : Session.Task.Board.t list;
  }

  type t = {
    mutable scripts : Turn_script.t list;
    mutable session : Session.t option;
    mutable held : held option;
    mutable count : int;
  }
end

module Mutation_runtime = struct
  type ledger = {
    session : Session.Id.t;
    mutable events : Mutation.Event.t list;
    mutable blobs : string list;
  }

  type t = { mutable ledgers : ledger list }

  let find t session =
    List.find_opt
      (fun ledger -> Session.Id.equal ledger.session session)
      t.ledgers

  let ensure t session =
    match find t session with
    | Some ledger -> ledger
    | None ->
        let ledger = { session; events = []; blobs = [] } in
        t.ledgers <- ledger :: t.ledgers;
        ledger

  let state t session =
    let events =
      match find t session with None -> [] | Some ledger -> ledger.events
    in
    match Mutation.State.of_events events with
    | Ok state -> state
    | Error error ->
        Util.failf "next tui harness: invalid mutation fixture: %s"
          (Format.asprintf "%a" Mutation.State.Error.pp error)

  let copy t ~from ~into =
    match find t from with
    | None -> ()
    | Some source ->
        if Option.is_some (find t into) then
          invalid_arg
            ("next tui harness: duplicate mutation ledger for "
           ^ Session.Id.to_string into);
        t.ledgers <-
          { session = into; events = source.events; blobs = source.blobs }
          :: t.ledgers

  let append ledger event = ledger.events <- ledger.events @ [ event ]

  let add_blob ledger contents =
    if not (List.exists (String.equal contents) ledger.blobs) then
      ledger.blobs <- contents :: ledger.blobs

  let edit_plan path = function
    | Mutation_script.Change.Create { contents; _ } ->
        Edit.create ~path ~contents
    | Mutation_script.Change.Update { before; after; _ } ->
        Edit.rewrite ~path ~before ~after
    | Mutation_script.Change.Delete { before; _ } -> Edit.delete ~path ~before

  let require_plan = function
    | Ok plan -> plan
    | Error error ->
        Util.failf "next tui harness: invalid mutation edit plan: %s"
          (Format.asprintf "%a" Edit.Error.pp error)

  let observed_before = function
    | Mutation_script.Change.Create _ -> Edit.Observed.Missing
    | Mutation_script.Change.Update { before; _ }
    | Mutation_script.Change.Delete { before; _ } ->
        Edit.Observed.Text before

  let edit_result ~project changes =
    let root =
      Workspace.Root.of_dir (Lpath.Abs.of_string_exn (Project.root project))
    in
    let workspace = Workspace.single root in
    let entries =
      List.map
        (fun change ->
          let path =
            Workspace.path_at_cwd_root workspace
              (Mutation_script.Change.path change)
          in
          (path, change))
        changes
    in
    let plans =
      List.map
        (fun (path, change) -> require_plan (edit_plan path change))
        entries
    in
    let plan =
      match Edit.concat plans with
      | Ok plan -> plan
      | Error error ->
          Util.failf "next tui harness: invalid mutation edit plan: %s"
            (Format.asprintf "%a" Edit.Error.pp error)
    in
    let io : Edit.Apply.io =
      {
        Edit.Apply.with_write_lock = (fun _paths apply -> apply ());
        revalidate = (fun path -> Ok path);
        read =
          (fun path ->
            match
              List.find_opt
                (fun (candidate, _) -> Workspace.Path.equal candidate path)
                entries
            with
            | None ->
                Error
                  (Edit.Error.io ~path "mutation fixture read an unplanned path")
            | Some (_, change) -> Ok (observed_before change));
        commit = (fun ~path:_ ~before:_ ~after:_ -> Ok ());
      }
    in
    match Edit.apply ~io ~workspace plan with
    | Ok result -> result
    | Error error ->
        Util.failf "next tui harness: mutation fixture apply failed: %s"
          (Format.asprintf "%a" Edit.Apply_error.pp error)

  let path project rel =
    let root =
      Workspace.Root.of_dir (Lpath.Abs.of_string_exn (Project.root project))
    in
    Workspace.path_at_cwd_root (Workspace.single root) rel

  let record t ~project ~session ~turn ~claim script =
    let ledger = ensure t session in
    (match script.Mutation_script.changes with
    | [] -> ()
    | changes ->
        let result = edit_result ~project changes in
        List.iter
          (fun change ->
            List.iter (add_blob ledger) (Mutation_script.Change.texts change))
          changes;
        append ledger
          (Mutation.Event.of_edit ~turn ~claim ~ordinal:0 ~checkpoint:None
             result));
    match script.Mutation_script.observed with
    | [] -> ()
    | observed ->
        append ledger
          (Mutation.Event.tool_observed ~turn ~claim
             (List.map (path project) observed))

  let record_for_call t ~project ~session ~turn ~claim ~call_id scripts =
    match
      List.find_opt
        (fun (script : Mutation_script.t) ->
          String.equal (Mutation_script.call_id script) call_id)
        scripts
    with
    | None -> ()
    | Some script -> record t ~project ~session ~turn ~claim script

  let unavailable text =
    Protocol.Error.Unavailable (Mentat_diagnostic.of_text text)

  let change_diff t ~session ~change =
    let mutation = state t session in
    match Mutation.State.change mutation change with
    | None ->
        Error
          (unavailable
             (Printf.sprintf "no recorded change %s"
                (Mutation.Change.Id.to_string change)))
    | Some row ->
        let blobs =
          match find t session with None -> [] | Some ledger -> ledger.blobs
        in
        let blob reference =
          List.find_opt
            (fun contents ->
              Mentat_digest.Content_ref.matches reference contents)
            blobs
        in
        Result.map_error
          (fun error ->
            unavailable
              (Format.asprintf "%a" Mutation.Change.Hunks_error.pp error))
          (Mutation.Change.hunks ~blob row)
end

module Queue_runtime = struct
  type edit_results =
    | Default_success
    | Scripted of (unit, Protocol.Error.t) result list

  type t = {
    mutable serial : int;
    mutable edit_results : edit_results;
    hold_results : bool;
    mutable current : (unit -> unit) option;
  }
end

module Compaction_runtime = struct
  type t = { mutable scripts : Compaction_script.t list; mutable serial : int }

  let next t =
    match t.scripts with
    | script :: remaining ->
        t.scripts <- remaining;
        script
    | [] ->
        invalid_arg
          "next tui harness: an unexpected manual compaction reached the client"

  let turn_id t =
    t.serial <- t.serial + 1;
    Session.Turn.Id.of_string
      (Printf.sprintf "turn-visual-compaction-%d" t.serial)
end

module Lifecycle_runtime = struct
  type scripts = Default_success | Scripted of Lifecycle_script.t list
  type delivery = { complete : unit -> unit }

  type t = {
    mutable scripts : scripts;
    hold_results : bool;
    mutable current : delivery option;
  }

  let next t operation =
    match t.scripts with
    | Default_success -> Ok ()
    | Scripted [] ->
        Util.failf "next tui harness: unexpected session lifecycle operation %s"
          (Lifecycle_script.describe operation)
    | Scripted (script :: remaining) ->
        if
          not
            (Lifecycle_script.equal_operation script.Lifecycle_script.operation
               operation)
        then
          Util.failf
            "next tui harness: expected session lifecycle operation %s, got %s"
            (Lifecycle_script.describe script.Lifecycle_script.operation)
            (Lifecycle_script.describe operation);
        t.scripts <- Scripted remaining;
        script.Lifecycle_script.result
end

module Screen_sessions_runtime = struct
  type scripts =
    | Default_success
    | Scripted of (unit, Protocol.Error.t) result list

  type delivery = { complete : unit -> unit }

  type t = {
    mutable scripts : scripts;
    hold_results : bool;
    mutable held : delivery list;
  }

  let next t =
    match t.scripts with
    | Default_success -> Ok ()
    | Scripted [] ->
        invalid_arg
          "next tui harness: unexpected full-browser session listing query"
    | Scripted (result :: remaining) ->
        t.scripts <- Scripted remaining;
        result
end

module Gate = struct
  type 'a t = { condition : Eio.Condition.t; mutable value : 'a option }

  let create () = { condition = Eio.Condition.create (); value = None }

  let resolve t value =
    if Option.is_some t.value then
      invalid_arg "next tui harness: an effect result was released twice";
    t.value <- Some value;
    Eio.Condition.broadcast t.condition

  let await t = Eio.Condition.loop_no_mutex t.condition (fun () -> t.value)
end

module Main_feeds = struct
  type packet = (Feed.outcome, Protocol.Error.t) result

  type held_pull = {
    result : packet Gate.t;
    claimed_signal : Eio.Condition.t;
    mutable claimed : bool;
  }

  type queued = Ready of packet | Held of held_pull

  type feed = {
    session : Session.Id.t;
    signal : Eio.Condition.t;
    mutable pending : queued list;
    mutable known : Protocol.Position.t list;
    mutable closed : bool;
  }

  type t = {
    mutable feeds : feed list;
    mutable held_pulls : (feed * held_pull) list;
  }

  let create () = { feeds = []; held_pulls = [] }

  let knows feed position =
    List.exists (Protocol.Position.equal position) feed.known

  let committed (position, fact) =
    Ok (Feed.Item (Protocol.Update.Committed { position; fact }))

  let attach t ~session ~known updates =
    let feed =
      {
        session;
        signal = Eio.Condition.create ();
        pending = List.map (fun update -> Ready (committed update)) updates;
        known;
        closed = false;
      }
    in
    t.feeds <- feed :: t.feeds;
    let next () =
      let queued =
        Eio.Condition.loop_no_mutex feed.signal (fun () ->
            match feed.pending with
            | queued :: remaining ->
                feed.pending <- remaining;
                Some queued
            | [] when feed.closed -> Some (Ready (Ok Feed.Closed))
            | [] -> None)
      in
      match queued with
      | Ready packet -> packet
      | Held held ->
          held.claimed <- true;
          Eio.Condition.broadcast held.claimed_signal;
          Gate.await held.result
    in
    let close () =
      feed.closed <- true;
      Eio.Condition.broadcast feed.signal
    in
    Ok { Feed.next; close }

  let publish_committed t ~session updates =
    List.iter
      (fun feed ->
        if (not feed.closed) && Session.Id.equal feed.session session then begin
          let fresh =
            List.filter (fun (position, _) -> not (knows feed position)) updates
          in
          feed.known <- List.map fst fresh @ feed.known;
          feed.pending <-
            feed.pending
            @ List.map (fun update -> Ready (committed update)) fresh;
          if fresh <> [] then Eio.Condition.broadcast feed.signal
        end)
      t.feeds

  let publish_progress t ~session progress =
    List.iter
      (fun feed ->
        if (not feed.closed) && Session.Id.equal feed.session session then begin
          feed.pending <-
            feed.pending
            @ [ Ready (Ok (Feed.Item (Protocol.Update.Progress progress))) ];
          Eio.Condition.broadcast feed.signal
        end)
      t.feeds

  let current t = List.find_opt (fun feed -> not feed.closed) t.feeds

  let fail_current t error =
    match current t with
    | None -> invalid_arg "Tui.lose_feed: no main feed is installed"
    | Some feed ->
        feed.pending <- feed.pending @ [ Ready (Error error) ];
        Eio.Condition.broadcast feed.signal

  let hold_current_pull t =
    match current t with
    | None -> invalid_arg "Tui.hold_feed_pull: no main feed is installed"
    | Some feed ->
        let held =
          {
            result = Gate.create ();
            claimed_signal = Eio.Condition.create ();
            claimed = false;
          }
        in
        t.held_pulls <- (feed, held) :: t.held_pulls;
        feed.pending <- feed.pending @ [ Held held ];
        Eio.Condition.broadcast feed.signal;
        Eio.Condition.loop_no_mutex held.claimed_signal (fun () ->
            if held.claimed then Some () else None)

  let fail_retired_pull t error =
    match
      List.find_opt
        (fun (feed, held) ->
          feed.closed && held.claimed && Option.is_none held.result.Gate.value)
        t.held_pulls
    with
    | None ->
        invalid_arg
          "Tui.lose_retired_feed: no in-flight pull from a retired feed is held"
    | Some (_, held) -> Gate.resolve held.result (Error error)
end

module Child_runtime = struct
  type expectation = {
    expected_child : Session.Id.t;
    expected_observation : Child_observation.t;
  }

  type feed = {
    child : Session.Id.t;
    observation : Child_observation.t;
    updates : (Protocol.Position.t * Protocol.Fact.t) array;
    signal : Eio.Condition.t;
    mutable cursor : int;
    mutable permits : int;
    mutable closed : bool;
  }

  type t = {
    sessions : Session.t list;
    state_changed : Eio.Condition.t;
    mutable expected : expectation list;
    mutable feeds : feed list;
  }

  let find_session t child =
    List.find_opt
      (fun session -> Session.Id.equal child (Session.id session))
      t.sessions

  let rec validate seen = function
    | [] -> ()
    | session :: remaining ->
        let child = Session.id session in
        if List.exists (Session.Id.equal child) seen then
          invalid_arg
            ("Tui.run: duplicate child session " ^ Session.Id.to_string child)
        else validate (child :: seen) remaining

  let create sessions =
    validate [] sessions;
    {
      sessions;
      state_changed = Eio.Condition.create ();
      expected = [];
      feeds = [];
    }

  let expect t ~child observation =
    if Option.is_none (find_session t child) then
      invalid_arg
        ("next tui harness: no child feed document for "
       ^ Session.Id.to_string child);
    t.expected <-
      t.expected
      @ [ { expected_child = child; expected_observation = observation } ];
    Eio.Condition.broadcast t.state_changed

  let rec take_expected child before = function
    | [] -> None
    | ({ expected_child; _ } as candidate) :: rest ->
        if Session.Id.equal child expected_child then
          Some (candidate, List.rev_append before rest)
        else take_expected child (candidate :: before) rest

  let empty_mutation () =
    match Mentat_mutation.State.of_events [] with
    | Ok mutation -> mutation
    | Error _ -> assert false

  let updates session =
    Protocol.Projection.all ~session ~mutation:(empty_mutation ())
    |> Array.of_list

  let follow t child ~from =
    let expectation =
      match take_expected child [] t.expected with
      | None ->
          invalid_arg
            ("next tui harness: unexpected child follow for "
           ^ Session.Id.to_string child)
      | Some (expectation, remaining) ->
          t.expected <- remaining;
          expectation
    in
    (match from with
    | `Beginning -> ()
    | `Now | `After _ ->
        invalid_arg
          ("next tui harness: child observation did not replay from the "
         ^ "beginning for " ^ Session.Id.to_string child));
    let session = Option.get (find_session t child) in
    let feed =
      {
        child;
        observation = expectation.expected_observation;
        updates = updates session;
        signal = Eio.Condition.create ();
        cursor = 0;
        permits = 0;
        closed = false;
      }
    in
    t.feeds <- feed :: t.feeds;
    Eio.Condition.broadcast t.state_changed;
    let next () =
      Eio.Condition.loop_no_mutex feed.signal (fun () ->
          if feed.closed then Some (Ok Feed.Closed)
          else if feed.permits = 0 then None
          else if feed.cursor >= Array.length feed.updates then
            failwith "next tui harness: released beyond the child document head"
          else begin
            let position, fact = feed.updates.(feed.cursor) in
            feed.cursor <- feed.cursor + 1;
            feed.permits <- feed.permits - 1;
            Some (Ok (Feed.Item (Protocol.Update.Committed { position; fact })))
          end)
    in
    let close () =
      feed.closed <- true;
      Eio.Condition.broadcast feed.signal;
      Eio.Condition.broadcast t.state_changed
    in
    Ok { Feed.next; close }

  let current t ~child ~observation =
    List.find_opt
      (fun feed ->
        (not feed.closed)
        && Session.Id.equal child feed.child
        && Child_observation.equal observation feed.observation)
      t.feeds

  let observed t ~child ~observation =
    List.exists
      (fun feed ->
        Session.Id.equal child feed.child
        && Child_observation.equal observation feed.observation)
      t.feeds

  let rec await t ~child ~observation =
    match current t ~child ~observation with
    | Some feed -> feed
    | None ->
        if Option.is_none (find_session t child) then
          invalid_arg
            ("next tui harness: no child feed document for "
           ^ Session.Id.to_string child);
        Eio.Condition.await_no_mutex t.state_changed;
        await t ~child ~observation

  let release_next t ~child ~observation =
    let feed = await t ~child ~observation in
    if feed.cursor + feed.permits >= Array.length feed.updates then
      invalid_arg
        ("Tui.next_child_fact: no unreleased child fact for "
       ^ Session.Id.to_string child);
    feed.permits <- feed.permits + 1;
    Eio.Condition.broadcast feed.signal

  let release_all t ~child ~observation =
    let feed = await t ~child ~observation in
    let remaining = Array.length feed.updates - feed.cursor - feed.permits in
    if remaining <= 0 then
      invalid_arg
        ("Tui.drain_child: no unreleased child facts for "
       ^ Session.Id.to_string child);
    feed.permits <- feed.permits + remaining;
    Eio.Condition.broadcast feed.signal
end

module Model_runtime = struct
  type t = {
    mutable expected : Mentat_provider.Selector.t list;
    mutable current : ((unit, Protocol.Error.t) result -> unit) option;
  }
end

module Permission_runtime = struct
  type delivery = { complete : (unit, Protocol.Error.t) result -> unit }

  type t = {
    mutable expected : Mentat_permission.Review_behavior.t list;
    mutable current : delivery option;
    mutable effective : Mentat_permission.Review_behavior.t;
  }
end

module Goal_runtime = struct
  type delivery = {
    acknowledge : unit -> unit;
    commit : unit -> unit;
    reject : Protocol.Error.t -> unit;
    mutable acknowledged : bool;
  }

  type t = {
    mutable current : delivery option;
    mutable update : (Session.Goal.Update.t -> unit) option;
  }
end

module Decision_runtime = struct
  type delivery = {
    acknowledge : unit -> unit;
    resolve : unit -> unit;
    fail : Protocol.Error.t -> unit;
  }

  type t = {
    mutable expected : Session.Decision.Answer.t list;
    mutable continuations : Decision_continuation.t list;
    hold : bool;
    mutable current : delivery option;
  }
end

module Query_runtime = struct
  type configuration_result =
    (Mentat_config.Resolved.View.t, Protocol.Error.t) Stdlib.result

  type configuration_source =
    | Default_unavailable
    | Scripted_configuration of configuration_result list

  type model_readiness_result =
    (Mentat_provider.Model_readiness.t, Protocol.Error.t) Stdlib.result

  type model_readiness_source =
    | Default_model_readiness_unavailable
    | Scripted_model_readiness of model_readiness_result list

  type session_view_source =
    | Default_success
    | Scripted of (unit, Protocol.Error.t) result list

  type t = {
    hold_settings : bool;
    hold_session_views : bool;
    mutable configuration_source : configuration_source;
    mutable model_readiness_source : model_readiness_source;
    mutable session_views : int;
    mutable session_view_source : session_view_source;
    mutable held : (unit -> unit) list;
    mutable held_session_views : (unit -> unit) list;
  }

  let deliver ~hold t delivery =
    if t.hold_settings && hold then t.held <- t.held @ [ delivery ]
    else delivery ()

  let next_configuration t =
    match t.configuration_source with
    | Default_unavailable ->
        Error
          (Protocol.Error.Unavailable
             (Mentat_diagnostic.of_text
                "configuration unavailable in the visual harness"))
    | Scripted_configuration (configuration :: remaining) ->
        t.configuration_source <- Scripted_configuration remaining;
        configuration
    | Scripted_configuration [] ->
        invalid_arg
          "next tui harness: configuration response script is exhausted"

  let next_model_readiness t =
    match t.model_readiness_source with
    | Default_model_readiness_unavailable ->
        Error
          (Protocol.Error.Unavailable
             (Mentat_diagnostic.of_text
                "model readiness unavailable in the visual harness"))
    | Scripted_model_readiness (readiness :: remaining) ->
        t.model_readiness_source <- Scripted_model_readiness remaining;
        readiness
    | Scripted_model_readiness [] ->
        invalid_arg
          "next tui harness: model-readiness response script is exhausted"

  let next_session_view t =
    match t.session_view_source with
    | Default_success -> Ok ()
    | Scripted (result :: remaining) ->
        t.session_view_source <- Scripted remaining;
        result
    | Scripted [] ->
        invalid_arg
          "next tui harness: session-view response script is exhausted"

  let deliver_session_view t delivery =
    if t.hold_settings && t.session_views > 1 then
      t.held <- t.held @ [ delivery ]
    else if t.hold_session_views then
      t.held_session_views <- t.held_session_views @ [ delivery ]
    else delivery ()
end

module Local_shell_runtime = struct
  (* The fixture only holds the run open until a test settles it. Shell output
     and cancellation are observed through the rendered frame, not fixture
     introspection, so the run is nothing more than its failure gate. *)
  type t = {
    mutable current :
      (Mentat_tool.Output.t Mentat_tool.Result.t, Mentat_diagnostic.t) result
      Gate.t
      option;
  }
end

module Login_runtime = struct
  type current = {
    mutable steps : (Login.step, Protocol.Error.t) result list;
    mutable released : (Login.step, Protocol.Error.t) result list;
    signal : Eio.Condition.t;
    mutable cancelled : bool;
  }

  type t = {
    mutable scripts : Login_script.t list;
    mutable current : current option;
  }
end

module Readiness_runtime = struct
  type result = (Account.Discovery.t list, Protocol.Error.t) Stdlib.result
  type source = Constant of result | Scripted of result list
  type t = { mutable source : source; mutable calls : int }

  let next t =
    t.calls <- t.calls + 1;
    match t.source with
    | Constant readiness -> readiness
    | Scripted (readiness :: remaining) ->
        t.source <- Scripted remaining;
        readiness
    | Scripted [] ->
        invalid_arg
          "next tui harness: account-readiness response script is exhausted"
end

module Account_runtime = struct
  type current =
    | Save_api_key of {
        result : (Account.t, Protocol.Error.t) result;
        complete : (Account.t, Protocol.Error.t) result -> unit;
      }
    | Logout of {
        result : (Account.Logout.t, Protocol.Error.t) result;
        complete : (Account.Logout.t, Protocol.Error.t) result -> unit;
      }

  type t = {
    mutable current : current option;
    mutable opened_urls : Uri.t list;
  }
end

type capabilities = {
  local_shell : bool;
  file_enumeration : bool;
  browser : bool;
}

(* The image-attach responder. A test scripts explicit responses; an exhausted
   or empty script yields a canned media block whose MIME type follows the
   source, so a test that only needs "attach succeeds" scripts nothing. The
   referenced bytes are a stable content ref keyed by the media type — enough for
   the transcript to render [[media: <type>] · attachment] deterministically. *)
module Attach_runtime = struct
  type t = {
    mutable responses :
      (Mentat_llm.Content.t, Protocol.Attach.Error.t) result list;
  }

  let media_type_of_source = function
    | Protocol.Attach.Bytes { media_type; _ } -> media_type
    | Protocol.Attach.Path path ->
        let name =
          String.lowercase_ascii
            (Lpath.Rel.to_string (Mentat_workspace.Path.rel path))
        in
        if
          String.ends_with ~suffix:".jpg" name
          || String.ends_with ~suffix:".jpeg" name
        then "image/jpeg"
        else if String.ends_with ~suffix:".gif" name then "image/gif"
        else if String.ends_with ~suffix:".webp" name then "image/webp"
        else "image/png"

  let next t source =
    match t.responses with
    | response :: rest ->
        t.responses <- rest;
        response
    | [] ->
        let media_type = media_type_of_source source in
        Ok
          (Mentat_llm.Content.media ~media_type
             (`Ref
                (Mentat_digest.Content_ref.of_contents (media_type ^ "-bytes"))))
end

(* An in-memory workspace-review responder for [/review] tests, self-contained
   here so future agents find it in one place. Unseeded, every field reports
   [Unavailable] — matching a workspace with no review. Seeded, it holds a
   [Mentat_review.t] derived from in-memory before/after texts, serves the five
   [Driver.Review] fields, and applies commands and CR edits in place: a CR edit
   rewrites the source text and refreshes the review, carrying marks forward as
   production does. No git is needed — the feature is built directly from the
   supplied texts. *)
module Review_runtime = struct
  type file = {
    path : Lpath.Rel.t;
    before : string option;
    mutable after : string option;
  }

  type t = { mutable review : Mentat_review.t option; files : file list }

  let unavailable message =
    Error (Protocol.Error.Unavailable (Mentat_diagnostic.of_text message))

  let make_file f =
    match
      (* Match the git loader's context (see [Workspace_io.git]) so the fixture
         splits hunks exactly as production does. *)
      Mentat_review.Feature.File.make ~context:3 ~path:f.path ~before:f.before
        ~after:f.after ()
    with
    | Ok file -> file
    | Error error ->
        Util.failf "Review_runtime: %s" (Mentat_review.Error.message error)

  let feature_of files =
    Mentat_review.Feature.v ~base:"HEAD" ~tip:"worktree"
      (List.map make_file files)

  let crs_of files =
    List.concat_map
      (fun f ->
        match f.after with
        | Some text -> Mentat_review.Cr.scan_file ~path:f.path ~text
        | None -> [])
      files

  let empty = { review = None; files = [] }

  let seed entries =
    let files =
      List.map
        (fun (path, before, after) ->
          { path = Lpath.Rel.of_string_exn path; before; after })
        entries
    in
    let review =
      Mentat_review.v ~feature:(feature_of files) ~crs:(crs_of files)
    in
    { review = Some review; files }

  let occurrences t =
    match t.review with Some r -> Mentat_review.crs r | None -> []

  let state t ~scope =
    match t.review with
    | Some r -> Ok (Mentat_review.View.of_review r ~focus:scope)
    | None -> unavailable "no workspace review"

  let diff t ~path =
    match t.review with
    | Some r -> (
        match
          Mentat_review.Feature.find_file (Mentat_review.feature r) ~path
        with
        | Some file -> Ok (Some (Mentat_review.File_diff.of_file file))
        | None -> Ok None)
    | None -> unavailable "no workspace review"

  let crs t () =
    match t.review with
    | Some _ -> Ok (Mentat_review.Cr.views (occurrences t))
    | None -> unavailable "no workspace review"

  let apply t command =
    match t.review with
    | Some r -> (
        match Mentat_review.Command.apply r command with
        | Ok r' ->
            t.review <- Some r';
            Ok ()
        | Error error -> unavailable (Mentat_review.Error.message error))
    | None -> unavailable "no workspace review"

  (* Map a wire ref back to its scanned occurrence: the ordinal-th occurrence at
     the ref's path whose comment digest matches. *)
  let find_occurrence t (r : Mentat_review.Cr.Ref.t) =
    let matches occ =
      Lpath.Rel.equal
        (Mentat_review.Cr.Occurrence.path occ)
        r.Mentat_review.Cr.Ref.path
      && Mentat_digest.Content_ref.equal
           (Mentat_review.Cr.Occurrence.digest occ)
           r.Mentat_review.Cr.Ref.digest
    in
    let rec nth i = function
      | occ :: rest ->
          if matches occ then
            if i = r.Mentat_review.Cr.Ref.ordinal then Some occ
            else nth (i + 1) rest
          else nth i rest
      | [] -> None
    in
    nth 0 (occurrences t)

  let file_of t path =
    List.find_opt (fun f -> Lpath.Rel.equal f.path path) t.files

  let rewrite t path result =
    match result with
    | Error error -> unavailable (Mentat_review.Cr.Error.message error)
    | Ok text -> (
        match (file_of t path, t.review) with
        | Some file, Some review ->
            file.after <- Some text;
            let feature = feature_of t.files and crs = crs_of t.files in
            t.review <- Some (Mentat_review.refresh review ~feature ~crs);
            Ok ()
        | _ -> unavailable "no such review file")

  let compose t (edit : Mentat_review.Cr.Edit.t) =
    match edit with
    | Mentat_review.Cr.Edit.Add { path; line; cr } -> (
        match (file_of t path, Mentat_review.Cr.Syntax.of_path path) with
        | Some { after = Some text; _ }, Some syntax ->
            rewrite t path
              (Mentat_review.Cr.add_before_line ~syntax ~text ~line cr)
        | _ -> unavailable "cannot add a CR here")
    | Mentat_review.Cr.Edit.Replace { ref = r; cr } -> (
        match (find_occurrence t r, file_of t r.Mentat_review.Cr.Ref.path) with
        | Some occ, Some { after = Some text; _ } ->
            rewrite t r.Mentat_review.Cr.Ref.path
              (Mentat_review.Cr.replace ~text occ cr)
        | _ -> unavailable "the CR comment moved; re-query review_crs")
    | Mentat_review.Cr.Edit.Remove { ref = r } -> (
        match (find_occurrence t r, file_of t r.Mentat_review.Cr.Ref.path) with
        | Some occ, Some { after = Some text; _ } ->
            rewrite t r.Mentat_review.Cr.Ref.path
              (Mentat_review.Cr.remove ~text occ)
        | _ -> unavailable "the CR comment moved; re-query review_crs")
end

type fixture = {
  mutable sessions : Session.t list;
  mutable start_serial : int;
  mutable fork_serial : int;
  session_diagnostics : Mentat_diagnostic.t list;
  providers : Mentat_provider.t list;
  readiness_runtime : Readiness_runtime.t;
  history : string;
  draft : string option;
  startup_session : Session.Id.t option;
  possibly_mutating : bool;
  enumerate_files : unit -> (Lpath.Rel.t list, Mentat_diagnostic.t) result;
  capabilities : capabilities;
  image_attach : bool;
      (* Whether the executable-local image-attach path resolver is supplied, so
         the reducer advertises image attachment. *)
  attach_runtime : Attach_runtime.t;
  clipboard_image : (string * string) option;
      (* A constant clipboard image probe result: [Some (media_type, bytes)]
         when the clipboard holds an image, else [None] so a paste stays text. *)
  child_observation_error : Protocol.Error.t option;
  child_documents : Child_runtime.t;
  main_feeds : Main_feeds.t;
  save_api_key :
    (Mentat_llm.Provider.t ->
    key:string ->
    (Account.t, Protocol.Error.t) result)
    option;
  logout :
    (Mentat_llm.Provider.t -> (Account.Logout.t, Protocol.Error.t) result)
    option;
  turn_runtime : Turn_runtime.t;
  mutation_runtime : Mutation_runtime.t;
  compaction_runtime : Compaction_runtime.t;
  lifecycle_runtime : Lifecycle_runtime.t;
  screen_sessions_runtime : Screen_sessions_runtime.t;
  queue_runtime : Queue_runtime.t;
  model_runtime : Model_runtime.t;
  permission_runtime : Permission_runtime.t;
  goal_runtime : Goal_runtime.t;
  decision_runtime : Decision_runtime.t;
  login_runtime : Login_runtime.t;
  account_runtime : Account_runtime.t;
  query_runtime : Query_runtime.t;
  review_runtime : Review_runtime.t;
  local_shell_runtime : Local_shell_runtime.t;
  edit_in_editor : (string -> string) option;
      (* A fake external editor: given the seed text it returns the edited
         buffer. Supplying it advertises the external-editor capability. *)
  notify : (title:string -> body:string -> unit) option;
      (* A capturing notification hook. Supplying it advertises the notify
         command channel. *)
  workspace : Project.t;
  glance : Textdiff.stats option * Workspace.Health.t;
  running : unit -> Mentat_protocol.Process.View.t list;
      (* The side pane's background-process view, as a thunk so a test can flip
         it between turns (a process appearing, then exiting) through its own
         ref. The session-scoped cone reads it on each poll. *)
  user_commands : (Protocol.User_command.t * string) list;
      (* The custom-command catalog for the slash palette: each summary paired
         with the template body its [expand_command] responder substitutes. *)
  resume_failure_script : Protocol.Error.t option ref;
  drop_first_start : bool ref;
  canonical_ids : (Session.Id.t * string) list ref;
}

type t = {
  backend : Matrix_test.t;
  real_clock : float Eio.Time.clock_ty Eio.Std.r;
  cond : Eio.Condition.t;
  parked_cond : Eio.Condition.t;
  mutable signaled : bool;
  mutable parked : bool;
  mutable idles : int;
  mutable wakes : int;
  mutable last_timeout : float option;
  mutable stopping : bool;
  mutable finished : bool;
  mutable probe : Mosaic.Probe.t option;
  mutable launch_now : float;
      (* The virtual instant the runtime handed back its probe — the boot-span
         launch mark, stamped once when [Runtime.run] calls [?probe]. *)
  turns : Turn_runtime.t;
  lifecycles : Lifecycle_runtime.t;
  screen_sessions : Screen_sessions_runtime.t;
  models : Model_runtime.t;
  permissions : Permission_runtime.t;
  goals : Goal_runtime.t;
  decisions : Decision_runtime.t;
  logins : Login_runtime.t;
  accounts : Account_runtime.t;
  queries : Query_runtime.t;
  local_shells : Local_shell_runtime.t;
  queue_edits : Queue_runtime.t;
  child_runtime : Child_runtime.t;
  project : Project.t;
  resume_failure : Protocol.Error.t option ref;
  feed_runtime : Main_feeds.t;
  id_replacements : (Session.Id.t * string) list ref;
}

let wake t =
  t.wakes <- t.wakes + 1;
  t.signaled <- true;
  Eio.Condition.broadcast t.cond

let breathe t = Eio.Time.sleep t.real_clock 0.001

let check_alive t =
  if t.finished then
    failwith "next tui harness: the application exited while awaiting a frame"

let wait_parked t =
  while not t.parked do
    check_alive t;
    Eio.Condition.await_no_mutex t.parked_cond
  done

let round_trip t =
  let target = t.idles + 1 in
  wake t;
  while t.idles < target do
    check_alive t;
    Eio.Condition.await_no_mutex t.parked_cond
  done

let visual_pending probe =
  (* Runtime effects may deliberately remain in flight while their result is
     controlled by a visual-test boundary. Such performs can coexist with an
     inspectable stable frame; their eventual messages and redraws remain
     settlement blockers after the boundary is released. *)
  Mosaic.Probe.pending probe
  |> List.filter (fun label -> not (String.equal label "performs"))

let rec settle_from t spent quiet =
  if spent > settle_budget then begin
    let pending =
      match t.probe with
      | None -> "probe unavailable"
      | Some probe -> visual_pending probe |> String.concat ","
    in
    Util.failf "next tui harness: frame did not settle (pending: %s)" pending
  end
  else begin
    wait_parked t;
    let probe = Option.get t.probe in
    let pending = visual_pending probe in
    if
      (* [Matrix_test.feed] queues input before [wake] marks the application
         runnable. The application can therefore still expose its preceding
         parked generation while [signaled] is true. Treat that wake as
         pending work and cross a complete idle generation before inspecting
         quiescence again. *)
      t.signaled
      || List.mem "messages" pending
      || Matrix.redraw_requested (Matrix_test.app t.backend)
    then (
      round_trip t;
      settle_from t (spent + 1) 0)
    else if List.mem "render" pending then (
      Matrix.request_redraw (Matrix_test.app t.backend);
      round_trip t;
      settle_from t (spent + 1) 0)
    else if pending <> [] then (
      breathe t;
      settle_from t (spent + 1) 0)
    else if quiet < 3 then (
      (* Runtime effects can hand work to another daemon after their own
         perform has completed. Cross three complete Matrix idle generations
         so an intermediate stable frame is not mistaken for final visual
         quiescence. An asynchronous wake or extra idle generation resets the
         confirmation; [round_trip] itself accounts for one of each. *)
      let before_idles = t.idles in
      let before_wakes = t.wakes in
      round_trip t;
      let quiet =
        if
          t.parked && (not t.signaled)
          && t.idles = before_idles + 1
          && t.wakes = before_wakes + 1
        then quiet + 1
        else 0
      in
      settle_from t (spent + 1) quiet)
  end

let settle t = settle_from t 0 0
let fail_next_resume (t : t) error = t.resume_failure := Some error

let lose_feed (t : t) ~message =
  Main_feeds.fail_current t.feed_runtime
    (Protocol.Error.Unavailable (Mentat_diagnostic.of_text message));
  wake t

let hold_feed_pull (t : t) = Main_feeds.hold_current_pull t.feed_runtime

let lose_retired_feed (t : t) ~message =
  Main_feeds.fail_retired_pull t.feed_runtime
    (Protocol.Error.Unavailable (Mentat_diagnostic.of_text message));
  wake t

let step_to t target =
  let rec loop () =
    wait_parked t;
    let now = Matrix_test.now t.backend in
    if now < target then begin
      let step =
        match t.last_timeout with
        | Some timeout when timeout > 0. -> Float.min timeout (target -. now)
        | None | Some _ -> target -. now
      in
      Matrix_test.set_now t.backend (now +. step);
      round_trip t;
      loop ()
    end
  in
  loop ()

let advance t seconds =
  if (not (Float.is_finite seconds)) || seconds < 0. then
    invalid_arg "Tui.advance: seconds must be finite and nonnegative";
  step_to t (Matrix_test.now t.backend +. seconds);
  settle t

let now t = Matrix_test.now t.backend
let launch_now t = t.launch_now
let output_bytes t = String.length (Matrix_test.output t.backend)

let ends_with_escape bytes =
  let length = String.length bytes in
  length > 0 && Char.equal bytes.[length - 1] '\027'

let keys t bytes =
  Matrix_test.feed t.backend bytes;
  wake t;
  if ends_with_escape bytes then begin
    round_trip t;
    Matrix_test.set_now t.backend (Matrix_test.now t.backend +. 0.06);
    wake t
  end

let enter t = keys t Key.enter
let paste t text = keys t (Key.bracketed_paste text)

let resize t ~width ~height =
  Matrix_test.resize t.backend ~width ~height;
  wake t

let screen t =
  List.fold_left
    (fun screen (actual, canonical) ->
      let actual = Session.Id.to_string actual in
      let width text =
        Matrix.Text.measure ~width_method:`Unicode ~tab_width:2 text
      in
      let actual_width = width actual in
      let canonical_width = width canonical in
      if canonical_width > actual_width then
        Util.failf
          "next tui harness: canonical session id %S is wider than rendered id \
           %S"
          canonical actual;
      (* Canonicalization happens after Mosaic has laid out and Matrix has
         presented the frame. Preserve the replaced identifier's terminal
         extent or every following cell moves left in the visual golden even
         though it did not move in the UI. *)
      let canonical =
        canonical ^ String.make (actual_width - canonical_width) ' '
      in
      Util.replace_all ~pattern:actual ~with_:canonical screen)
    (Matrix_test.screen t.backend)
    !(t.id_replacements)

(* The colour-preserving counterpart to [screen]: theme tests observe a role's
   resolved hue in the frame, which the plain-text grid discards. Session ids
   are not canonicalized, so it suits frames that carry none. *)
let screen_ansi t = Matrix_test.screen_ansi t.backend

let print (t : t) =
  Screen.print ~project:t.project (screen t);
  flush stdout

(* The frame protocol hides the terminal cursor in the preamble, paints, then
   repositions and re-shows it — so the caret never appears in the cell grid
   and is only observable in the output stream. Replay visibility toggles and
   cursor addressing to recover what a real terminal would display. *)
let cursor (t : t) =
  let output = Matrix_test.output t.backend in
  let length = String.length output in
  let matches_at index affix =
    index + String.length affix <= length
    && String.equal (String.sub output index (String.length affix)) affix
  in
  let digits index =
    let stop = ref index in
    while !stop < length && output.[!stop] >= '0' && output.[!stop] <= '9' do
      incr stop
    done;
    if !stop = index then None
    else Some (int_of_string (String.sub output index (!stop - index)), !stop)
  in
  let visible = ref false in
  let position = ref None in
  let index = ref 0 in
  while !index < length do
    (if matches_at !index "\x1b[" then
       let start = !index + 2 in
       if matches_at start "?25h" then visible := true
       else if matches_at start "?25l" then visible := false
       else
         match digits start with
         | Some (row, after) when matches_at after ";" -> (
             match digits (after + 1) with
             | Some (col, stop) when matches_at stop "H" ->
                 position := Some (row, col)
             | Some _ | None -> ())
         | Some _ | None -> ());
    incr index
  done;
  if !visible then !position else None

let next_child_fact ?(observation = Child_observation.Live) (t : t) child =
  (* Settlement may expose an inspectable frame while Runtime still owns a
     non-visual perform which will attach this controlled feed. Wake before
     awaiting the feed so the fixture cannot deadlock on the very Runtime
     command that creates it. The second wake admits the released fact. *)
  wake t;
  Child_runtime.release_next t.child_runtime ~child ~observation;
  wake t

let drain_child ?(observation = Child_observation.Live) (t : t) child =
  wake t;
  Child_runtime.release_all t.child_runtime ~child ~observation;
  wake t

let finish_turn (t : t) =
  match t.turns.Turn_runtime.held with
  | None -> invalid_arg "Tui.finish_turn: no scripted turn is awaiting release"
  | Some held -> (
      match held.Turn_runtime.task_boards with
      | _ :: _ ->
          invalid_arg
            "Tui.finish_turn: task-board replacements remain unreleased"
      | [] ->
          t.turns.Turn_runtime.held <- None;
          held.Turn_runtime.complete ();
          wake t)

let finish_queue_edit_result (t : t) =
  match t.queue_edits.Queue_runtime.current with
  | None ->
      invalid_arg
        "Tui.finish_queue_edit_result: no queued-draft edit is awaiting a \
         result"
  | Some complete ->
      t.queue_edits.Queue_runtime.current <- None;
      complete ();
      wake t

let finish_lifecycle_result (t : t) =
  match t.lifecycles.Lifecycle_runtime.current with
  | None ->
      invalid_arg
        "Tui.finish_lifecycle_result: no session lifecycle operation is \
         awaiting a result"
  | Some delivery ->
      t.lifecycles.Lifecycle_runtime.current <- None;
      delivery.Lifecycle_runtime.complete ();
      wake t

let finish_screen_session_result (t : t) =
  match t.screen_sessions.Screen_sessions_runtime.held with
  | [] ->
      invalid_arg
        "Tui.finish_screen_session_result: no full-browser session query is \
         held"
  | delivery :: remaining ->
      t.screen_sessions.Screen_sessions_runtime.held <- remaining;
      delivery.Screen_sessions_runtime.complete ();
      wake t

let finish_latest_screen_session_result (t : t) =
  match List.rev t.screen_sessions.Screen_sessions_runtime.held with
  | [] ->
      invalid_arg
        "Tui.finish_latest_screen_session_result: no full-browser session \
         query is held"
  | delivery :: reversed_remaining ->
      t.screen_sessions.Screen_sessions_runtime.held <-
        List.rev reversed_remaining;
      delivery.Screen_sessions_runtime.complete ();
      wake t

let next_task_board (t : t) =
  match t.turns.Turn_runtime.held with
  | None -> invalid_arg "Tui.next_task_board: no scripted turn is active"
  | Some held -> (
      match held.Turn_runtime.task_boards with
      | [] ->
          invalid_arg
            "Tui.next_task_board: no scripted task-board replacement remains"
      | board :: remaining ->
          held.Turn_runtime.task_boards <- remaining;
          held.Turn_runtime.replace_tasks board;
          wake t)

let finish_model_selection (t : t) result =
  match t.models.Model_runtime.current with
  | None ->
      invalid_arg
        "Tui.finish_model_selection: no model selection is awaiting a result"
  | Some complete ->
      t.models.Model_runtime.current <- None;
      complete result;
      wake t

let finish_permission_review (t : t) result =
  match t.permissions.Permission_runtime.current with
  | None ->
      invalid_arg
        "Tui.finish_permission_review: no permission review is awaiting a \
         result"
  | Some delivery ->
      t.permissions.Permission_runtime.current <- None;
      delivery.Permission_runtime.complete result;
      wake t

let acknowledge_goal_mutation (t : t) =
  match t.goals.Goal_runtime.current with
  | None ->
      invalid_arg
        "Tui.acknowledge_goal_mutation: no goal mutation is awaiting a result"
  | Some delivery ->
      if delivery.Goal_runtime.acknowledged then
        invalid_arg
          "Tui.acknowledge_goal_mutation: the current mutation is already \
           acknowledged";
      delivery.Goal_runtime.acknowledged <- true;
      delivery.Goal_runtime.acknowledge ();
      wake t

let commit_goal_mutation (t : t) =
  match t.goals.Goal_runtime.current with
  | None ->
      invalid_arg
        "Tui.commit_goal_mutation: no goal mutation is awaiting a fact"
  | Some delivery ->
      if not delivery.Goal_runtime.acknowledged then
        invalid_arg
          "Tui.commit_goal_mutation: acknowledge the client result before the \
           durable fact";
      t.goals.Goal_runtime.current <- None;
      delivery.Goal_runtime.commit ();
      wake t

let fail_goal_mutation (t : t) error =
  match t.goals.Goal_runtime.current with
  | None ->
      invalid_arg
        "Tui.fail_goal_mutation: no goal mutation is awaiting a result"
  | Some delivery ->
      t.goals.Goal_runtime.current <- None;
      delivery.Goal_runtime.reject error;
      wake t

let update_goal (t : t) update =
  match t.goals.Goal_runtime.update with
  | None -> invalid_arg "Tui.update_goal: goal fixture is not installed"
  | Some apply ->
      apply update;
      wake t

let next_login_step (t : t) =
  match t.logins.Login_runtime.current with
  | None -> invalid_arg "Tui.next_login_step: no interactive login is active"
  | Some current -> (
      match current.Login_runtime.steps with
      | [] -> invalid_arg "Tui.next_login_step: active login has no next step"
      | result :: rest ->
          current.Login_runtime.steps <- rest;
          let terminal = Login_script.terminal result in
          if terminal then t.logins.Login_runtime.current <- None;
          current.Login_runtime.released <-
            current.Login_runtime.released @ [ result ];
          Eio.Condition.broadcast current.Login_runtime.signal;
          wake t)

let opened_urls (t : t) = List.rev t.accounts.Account_runtime.opened_urls

let finish_save_api_key (t : t) =
  match t.accounts.Account_runtime.current with
  | None ->
      invalid_arg
        "Tui.finish_save_api_key: no direct account operation is awaiting a \
         result"
  | Some (Account_runtime.Save_api_key { result; complete }) ->
      t.accounts.Account_runtime.current <- None;
      complete result;
      wake t
  | Some (Account_runtime.Logout _) ->
      invalid_arg "Tui.finish_save_api_key: the active operation is logout"

let finish_logout (t : t) =
  match t.accounts.Account_runtime.current with
  | None ->
      invalid_arg
        "Tui.finish_logout: no direct account operation is awaiting a result"
  | Some (Account_runtime.Logout { result; complete }) ->
      t.accounts.Account_runtime.current <- None;
      complete result;
      wake t
  | Some (Account_runtime.Save_api_key _) ->
      invalid_arg "Tui.finish_logout: the active operation is an API-key save"

let finish_settings_queries (t : t) =
  match t.queries.Query_runtime.held with
  | [] -> invalid_arg "Tui.finish_settings_queries: no settings query is held"
  | held ->
      t.queries.Query_runtime.held <- [];
      List.iter (fun deliver -> deliver ()) held;
      wake t

let finish_session_view_results (t : t) =
  match t.queries.Query_runtime.held_session_views with
  | [] ->
      invalid_arg
        "Tui.finish_session_view_results: no session-view result is held"
  | held ->
      t.queries.Query_runtime.held_session_views <- [];
      List.iter (fun deliver -> deliver ()) held;
      wake t

let fail_local_shell (t : t) diagnostic =
  match t.local_shells.Local_shell_runtime.current with
  | None -> invalid_arg "Tui.fail_local_shell: no local shell run is pending"
  | Some failure ->
      t.local_shells.Local_shell_runtime.current <- None;
      Gate.resolve failure (Error diagnostic);
      wake t

let acknowledge_decision (t : t) =
  match t.decisions.Decision_runtime.current with
  | None -> invalid_arg "Tui.acknowledge_decision: no decision answer is held"
  | Some delivery ->
      delivery.Decision_runtime.acknowledge ();
      wake t

let resolve_decision (t : t) =
  match t.decisions.Decision_runtime.current with
  | None -> invalid_arg "Tui.resolve_decision: no decision answer is held"
  | Some delivery ->
      t.decisions.Decision_runtime.current <- None;
      delivery.Decision_runtime.resolve ();
      wake t

let fail_decision (t : t) error =
  match t.decisions.Decision_runtime.current with
  | None -> invalid_arg "Tui.fail_decision: no decision answer is held"
  | Some delivery ->
      t.decisions.Decision_runtime.current <- None;
      delivery.Decision_runtime.fail error;
      wake t

let session_by_id (fixture : fixture) id =
  match fixture.turn_runtime.Turn_runtime.session with
  | Some session when Session.Id.equal (Session.id session) id -> Some session
  | Some _ | None ->
      List.find_opt
        (fun session -> Session.Id.equal (Session.id session) id)
        fixture.sessions

let retain_session (fixture : fixture) document =
  let retained = Session.id document in
  fixture.sessions <-
    document
    :: List.filter
         (fun candidate ->
           not (Session.Id.equal retained (Session.id candidate)))
         fixture.sessions

let replace_session (fixture : fixture) replacement =
  let replacement_id = Session.id replacement in
  retain_session fixture replacement;
  fixture.turn_runtime.Turn_runtime.session <-
    (match fixture.turn_runtime.Turn_runtime.session with
    | Some active when Session.Id.equal (Session.id active) replacement_id ->
        Some replacement
    | Some active -> Some active
    | None -> None)

let projected_updates (fixture : fixture) document =
  let session = Session.id document in
  Protocol.Projection.all ~session:document
    ~mutation:(Mutation_runtime.state fixture.mutation_runtime session)

let publish_session (fixture : fixture) document =
  Main_feeds.publish_committed fixture.main_feeds ~session:(Session.id document)
    (projected_updates fixture document)

let publish_active_session (fixture : fixture) =
  match fixture.turn_runtime.Turn_runtime.session with
  | None -> failwith "next tui harness: no active session to publish"
  | Some document ->
      retain_session fixture document;
      publish_session fixture document

let publish_progress (fixture : fixture) ~session progress =
  Main_feeds.publish_progress fixture.main_feeds ~session progress

let provider = Mentat_llm.Provider.make "openai"
let api = Mentat_llm.Model.Api.make "responses"
let model = Mentat_llm.Model.make ~provider ~api ~id:"gpt-5.5"

let contract ~review (script : Turn_script.t) mode =
  let model = Option.value script.Turn_script.model ~default:model in
  let options =
    Option.map
      (fun reasoning_effort ->
        Mentat_llm.Request.Options.make ~reasoning_effort ())
      script.Turn_script.reasoning_effort
  in
  Session.Contract.make ~mode ~model ?options ~declarations:[]
    ~policy:Mentat_permission.Policy.default ~review
    ~sandbox:(Mentat_sandbox.identity Mentat_sandbox.direct)
    ()

let append_events (runtime : Turn_runtime.t) events =
  let session =
    match runtime.Turn_runtime.session with
    | Some session -> session
    | None -> failwith "next tui harness: scripted turn has no session"
  in
  match Session.append_all events session with
  | Ok session -> runtime.Turn_runtime.session <- Some session
  | Error error ->
      Util.failf "next tui harness: invalid scripted session: %s"
        (Session.Error.message error)

let take_script (runtime : Turn_runtime.t) prompt =
  match runtime.Turn_runtime.scripts with
  | [] -> Util.failf "next tui harness: unexpected submitted prompt %S" prompt
  | script :: rest ->
      if not (String.equal prompt script.Turn_script.prompt) then
        Util.failf "next tui harness: expected prompt %S, got %S"
          script.Turn_script.prompt prompt;
      if Option.is_some runtime.Turn_runtime.held then
        failwith "next tui harness: a scripted turn is already awaiting release";
      runtime.Turn_runtime.scripts <- rest;
      runtime.Turn_runtime.count <- runtime.Turn_runtime.count + 1;
      script

let turn_id (runtime : Turn_runtime.t) =
  Session.Turn.Id.of_string
    (Printf.sprintf "turn-visual-%d" runtime.Turn_runtime.count)

let mint_queue_id (runtime : Queue_runtime.t) =
  runtime.Queue_runtime.serial <- runtime.Queue_runtime.serial + 1;
  Session.Queue.Id.of_string
    (Printf.sprintf "queue-visual-%d" runtime.Queue_runtime.serial)

let take_queue_edit_result (runtime : Queue_runtime.t) =
  match runtime.Queue_runtime.edit_results with
  | Queue_runtime.Default_success -> Ok ()
  | Queue_runtime.Scripted [] ->
      failwith
        "next tui harness: an unexpected queued-draft edit reached the client"
  | Queue_runtime.Scripted (result :: remaining) ->
      runtime.Queue_runtime.edit_results <- Queue_runtime.Scripted remaining;
      result

let response ~model ?usage ~reasoning_summary text =
  Mentat_llm.Response.make ~model ?usage ~reasoning_summary
    (Mentat_llm.Message.Assistant.text text)

let tool_response ~model tools =
  let parts =
    List.map
      (fun (tool : Turn_script.tool) ->
        Mentat_llm.Message.Assistant.tool_call (Turn_script.tool_call tool))
      tools
  in
  Mentat_llm.Response.make ~model ~stop:Mentat_llm.Response.Stop.tool_call
    (Mentat_llm.Message.Assistant.make parts)

let tool_lifecycle fixture ~session ~turn ~mutations tools =
  let one (tool : Turn_script.tool) =
    let call = Turn_script.tool_call tool in
    let started =
      Session.Tool_claim.Started.make ~turn ~stage:Mentat_tool.Stage.Direct
        ~call
        ~input:(Mentat_llm.Tool.Call.input call)
        ~requests:[]
    in
    let id = Session.Tool_claim.Started.id started in
    Mutation_runtime.record_for_call fixture.mutation_runtime
      ~project:fixture.workspace ~session ~turn ~claim:id
      ~call_id:(Mentat_llm.Tool.Call.id call)
      mutations;
    let settled =
      match Turn_script.tool_outcome tool with
      | Turn_script.Returned result ->
          Session.Tool_claim.Settled.returned ~id result
      | Turn_script.Ambiguous -> Session.Tool_claim.Settled.ambiguous ~id
    in
    ( [ Session.Event.tool_claimed started; Session.Event.tool_settled settled ],
      id )
  in
  let events, claims = List.map one tools |> List.split in
  (List.concat events, claims)

let projected_tool_facts fixture ~session claims =
  let document =
    match fixture.turn_runtime.Turn_runtime.session with
    | Some document when Session.Id.equal (Session.id document) session ->
        document
    | Some _ | None ->
        Util.failf
          "next tui harness: mutation projection lost active session %s"
          (Session.Id.to_string session)
  in
  let belongs claim = List.exists (Session.Tool_claim.Id.equal claim) claims in
  Protocol.Projection.all ~session:document
    ~mutation:(Mutation_runtime.state fixture.mutation_runtime session)
  |> List.filter_map (fun (_, fact) ->
      match fact with
      | Protocol.Fact.Tool_started started
        when belongs (Session.Tool_claim.Started.id started) ->
          Some fact
      | Protocol.Fact.Tool_prepared { claim; _ }
      | Protocol.Fact.Tool_returned { claim; _ }
      | Protocol.Fact.Tool_ambiguous { claim; _ }
        when belongs claim ->
          Some fact
      | Protocol.Fact.Turn_started _ | Protocol.Fact.Turn_assistant _
      | Protocol.Fact.Turn_assistant_interrupted _
      | Protocol.Fact.Turn_provider_failed _ | Protocol.Fact.Turn_message _
      | Protocol.Fact.Turn_settled _ | Protocol.Fact.Tool_started _
      | Protocol.Fact.Tool_prepared _ | Protocol.Fact.Tool_returned _
      | Protocol.Fact.Tool_ambiguous _ | Protocol.Fact.Decision_requested _
      | Protocol.Fact.Decision_resolved _ | Protocol.Fact.Journal_task_board _
      | Protocol.Fact.Journal_goal _ | Protocol.Fact.Journal_delegation _
      | Protocol.Fact.Journal_queue _ | Protocol.Fact.Compaction _
      | Protocol.Fact.Workspace_notice _ | Protocol.Fact.Undo _ ->
          None)

let require_active_session (fixture : fixture) ~operation session =
  match fixture.turn_runtime.Turn_runtime.session with
  | Some active when Session.Id.equal (Session.id active) session -> active
  | Some _ | None ->
      Util.failf "next tui harness: %s targeted inactive session %s" operation
        (Session.Id.to_string session)

let continue_after_decision fixture ~session ~turn =
  match fixture.decision_runtime.Decision_runtime.continuations with
  | [] -> ()
  | continuation :: remaining ->
      if
        not (Session.Turn.Id.equal continuation.Decision_continuation.turn turn)
      then
        Util.failf
          "next tui harness: post-decision continuation expected turn %s, got \
           %s"
          (Session.Turn.Id.to_string continuation.Decision_continuation.turn)
          (Session.Turn.Id.to_string turn);
      let active =
        require_active_session fixture ~operation:"decision continuation"
          session
      in
      (match Session.State.active_turn (Session.state active) with
      | Some active_turn
        when Session.Turn.Id.equal (Session.Turn.id active_turn) turn ->
          ()
      | Some active_turn ->
          Util.failf
            "next tui harness: decision continuation targeted turn %s, not \
             active turn %s"
            (Session.Turn.Id.to_string turn)
            (Session.Turn.Id.to_string (Session.Turn.id active_turn))
      | None ->
          Util.failf
            "next tui harness: decision continuation targeted settled turn %s"
            (Session.Turn.Id.to_string turn));
      fixture.decision_runtime.Decision_runtime.continuations <- remaining;
      let tools = continuation.Decision_continuation.tools in
      let response = tool_response ~model tools in
      let claim =
        Session.Provider_request.Started.make ~turn
          ~request_digest:
            (Mentat_digest.string
               ("visual post-decision continuation: "
               ^ Session.Turn.Id.to_string turn))
      in
      let tool_events, tool_claims =
        tool_lifecycle fixture ~session ~turn ~mutations:[] tools
      in
      append_events fixture.turn_runtime
        (Session.Event.provider_requested claim
        :: Session.Event.provider_settled
             (Session.Provider_request.Settled.responded
                ~id:(Session.Provider_request.Started.id claim)
                response)
        :: tool_events);
      ignore (projected_tool_facts fixture ~session tool_claims);
      publish_active_session fixture

let dispatch_turn_progress fixture session turn (script : Turn_script.t) =
  let emit update =
    publish_progress fixture ~session (Protocol.Progress.Model { turn; update })
  in
  emit Protocol.Progress.Model.Started;
  List.iter
    (fun update ->
      publish_progress fixture ~session
        (Protocol.Progress.Model_download { turn; update }))
    script.Turn_script.downloads;
  List.iter
    (fun retry -> emit (Protocol.Progress.Model.Retrying retry))
    script.Turn_script.retries;
  List.iter
    (fun text -> emit (Protocol.Progress.Model.Reasoning_delta { text }))
    script.Turn_script.reasoning_deltas;
  List.iter
    (fun text -> emit (Protocol.Progress.Model.Assistant_delta { text }))
    script.Turn_script.assistant_deltas;
  Option.iter
    (fun usage -> emit (Protocol.Progress.Model.Usage usage))
    script.Turn_script.usage

(* The one nonblank text part of an input, ignoring any image media blocks that
   ride ahead of it. Media submits carry [`Media …; Text prompt]; text-only
   submits carry [Text prompt]. *)
let text_of_input input =
  List.filter_map
    (function
      | Mentat_llm.Content.Text text when String.trim text <> "" -> Some text
      | Mentat_llm.Content.Text _ | Mentat_llm.Content.Media _ -> None)
    input

let queued_prompt (entry : Session.Queue.Entry.t) =
  match text_of_input (Session.Queue.Entry.input entry) with
  | [ prompt ] -> prompt
  | _ ->
      Util.failf
        "next tui harness: queued admission was not the exact non-empty text \
         input minted by Queue_next"

let rec begin_turn (fixture : fixture) ~turn_id ~session ~prompt ~content ~mode
    ~origin =
  let runtime = fixture.turn_runtime in
  let script = take_script runtime prompt in
  let model = Option.value script.Turn_script.model ~default:model in
  (* [content] is the exact submitted input — image media ahead of the prompt
     text — so the committed [Turn_started] carries the attachments a media
     submit sent, while [prompt] is that input's text part for script matching. *)
  let turn =
    Session.Turn.make ~id:turn_id ~origin
      ~input:(Session.Turn.Input.user content)
      ~max_steps:100
      ~contract:
        (contract
           ~review:fixture.permission_runtime.Permission_runtime.effective
           script mode)
      ()
  in
  let claim =
    Session.Provider_request.Started.make ~turn:turn_id
      ~request_digest:(Mentat_digest.string ("visual request: " ^ prompt))
  in
  let initial_board, task_boards =
    match script.Turn_script.task_boards with
    | [] -> (None, [])
    | board :: replacements -> (Some board, replacements)
  in
  let board_events =
    Option.to_list (Option.map Session.Event.tasks_replaced initial_board)
  in
  (* Workspace notices are turn-scoped: they land right after [turn_started],
     exactly as the engine records the drained observations against the turn. *)
  let notice_events =
    List.map Session.Event.workspace_notice script.Turn_script.notices
  in
  append_events runtime
    ((Session.Event.turn_started turn :: notice_events)
    @ board_events
    @ [ Session.Event.provider_requested claim ]);
  publish_active_session fixture;
  dispatch_turn_progress fixture session turn_id script;
  runtime.Turn_runtime.held <-
    Some
      {
        Turn_runtime.complete =
          (fun () ->
            let claim_id = Session.Provider_request.Started.id claim in
            let events, facts, admit_queue =
              match script.Turn_script.result with
              | Turn_script.Completed
                  { text; reasoning_summary; usage; tools = [] } ->
                  let response =
                    response ~model ?usage ~reasoning_summary text
                  in
                  ( [
                      Session.Event.provider_settled
                        (Session.Provider_request.Settled.responded ~id:claim_id
                           response);
                      Session.Event.turn_finished ~turn:turn_id
                        Session.Turn.Outcome.completed;
                    ],
                    (fun () ->
                      [
                        Protocol.Fact.Turn_assistant response;
                        Protocol.Fact.Turn_settled
                          {
                            turn = turn_id;
                            outcome = Session.Turn.Outcome.completed;
                          };
                      ]),
                    true )
              | Turn_script.Completed { text; reasoning_summary; usage; tools }
                ->
                  let requested = tool_response ~model tools in
                  let tool_events, tool_claims =
                    tool_lifecycle fixture ~session ~turn:turn_id
                      ~mutations:script.Turn_script.mutations tools
                  in
                  let final_claim =
                    Session.Provider_request.Started.make ~turn:turn_id
                      ~request_digest:
                        (Mentat_digest.string ("visual follow-up: " ^ prompt))
                  in
                  let final_response =
                    response ~model ?usage ~reasoning_summary text
                  in
                  let final_settlement =
                    Session.Provider_request.Settled.responded
                      ~id:(Session.Provider_request.Started.id final_claim)
                      final_response
                  in
                  ( Session.Event.provider_settled
                      (Session.Provider_request.Settled.responded ~id:claim_id
                         requested)
                    :: tool_events
                    @ [
                        Session.Event.provider_requested final_claim;
                        Session.Event.provider_settled final_settlement;
                        Session.Event.turn_finished ~turn:turn_id
                          Session.Turn.Outcome.completed;
                      ],
                    (fun () ->
                      Protocol.Fact.Turn_assistant requested
                      :: projected_tool_facts fixture ~session tool_claims
                      @ [
                          Protocol.Fact.Turn_assistant final_response;
                          Protocol.Fact.Turn_settled
                            {
                              turn = turn_id;
                              outcome = Session.Turn.Outcome.completed;
                            };
                        ]),
                    true )
              | Turn_script.Failed error ->
                  let outcome =
                    Session.Turn.Outcome.failed
                      ~message:(Mentat_llm.Error.message error)
                  in
                  ( [
                      Session.Event.provider_settled
                        (Session.Provider_request.Settled.failed ~id:claim_id
                           error);
                      Session.Event.turn_finished ~turn:turn_id outcome;
                    ],
                    (fun () ->
                      [
                        Protocol.Fact.Turn_provider_failed
                          { claim = claim_id; error };
                        Protocol.Fact.Turn_settled { turn = turn_id; outcome };
                      ]),
                    false )
            in
            append_events runtime events;
            ignore (facts ());
            publish_active_session fixture;
            if admit_queue then admit_queued fixture ~session);
        interrupt =
          (fun () ->
            let claim_id = Session.Provider_request.Started.id claim in
            let assistant_text =
              String.concat "" script.Turn_script.assistant_deltas
            in
            let provider_event, provider_facts =
              if String.trim assistant_text = "" then
                ( Session.Event.provider_settled
                    (Session.Provider_request.Settled.ambiguous ~id:claim_id),
                  [] )
              else
                ( Session.Event.provider_settled
                    (Session.Provider_request.Settled.interrupted ~id:claim_id
                       ~text:assistant_text ()),
                  [
                    Protocol.Fact.Turn_assistant_interrupted
                      { text = assistant_text };
                  ] )
            in
            let outcome = Session.Turn.Outcome.interrupted ~cancelled:true () in
            append_events runtime
              [
                Session.Event.interrupt_requested ~turn:turn_id ();
                provider_event;
                Session.Event.turn_finished ~turn:turn_id outcome;
              ];
            ignore provider_facts;
            publish_active_session fixture;
            admit_queued fixture ~session);
        replace_tasks =
          (fun board ->
            append_events runtime [ Session.Event.tasks_replaced board ];
            publish_active_session fixture);
        task_boards;
      }

and admit_queued (fixture : fixture) ~session =
  let runtime = fixture.turn_runtime in
  let document =
    match runtime.Turn_runtime.session with
    | Some document when Session.Id.equal (Session.id document) session ->
        document
    | Some _ | None ->
        Util.failf "next tui harness: queued admission lost active session %s"
          (Session.Id.to_string session)
  in
  match Session.State.pending_queue (Session.state document) with
  | [] -> ()
  | entry :: _ ->
      begin_turn fixture ~turn_id:(turn_id runtime) ~session
        ~prompt:(queued_prompt entry)
        ~content:(Session.Queue.Entry.input entry)
        ~mode:Session.Contract.Mode.Build
        ~origin:(Session.Turn.Origin.Queued (Session.Queue.Entry.id entry))

let commit_goal_update fixture update =
  if Option.is_none fixture.turn_runtime.Turn_runtime.session then
    failwith "next tui harness: goal update has no active session";
  append_events fixture.turn_runtime [ Session.Event.goal_updated update ];
  let document =
    match fixture.turn_runtime.Turn_runtime.session with
    | None -> assert false
    | Some document -> document
  in
  retain_session fixture document;
  publish_session fixture document

let mutate_session_result (fixture : fixture) ~operation mutation =
  (match fixture.lifecycle_runtime.Lifecycle_runtime.current with
  | Some _ ->
      Util.failf
        "next tui harness: attempted %s while another session lifecycle result \
         was pending"
        (Lifecycle_script.describe operation)
  | None -> ());
  let session = Lifecycle_script.operation_session operation in
  let document =
    match session_by_id fixture session with
    | Some document -> document
    | None ->
        Util.failf "next tui harness: lifecycle targeted unknown session %s"
          (Session.Id.to_string session)
  in
  let scripted = Lifecycle_runtime.next fixture.lifecycle_runtime operation in
  let replacement =
    match scripted with
    | Error error -> Error error
    | Ok () -> (
        match mutation document with
        | Ok replacement -> Ok replacement
        | Error error ->
            Util.failf "next tui harness: invalid lifecycle fixture for %s: %s"
              (Session.Id.to_string session)
              (Session.Error.message error))
  in
  let applied = ref false in
  let gate = Gate.create () in
  let complete () =
    let result =
      match replacement with
      | Ok replacement ->
          if not !applied then begin
            applied := true;
            replace_session fixture replacement
          end;
          Ok ()
      | Error error -> Error error
    in
    Gate.resolve gate result
  in
  let delivery = { Lifecycle_runtime.complete } in
  if fixture.lifecycle_runtime.Lifecycle_runtime.hold_results then begin
    fixture.lifecycle_runtime.Lifecycle_runtime.current <- Some delivery;
    Gate.await gate
  end
  else begin
    complete ();
    Gate.await gate
  end

let register_canonical_id (fixture : fixture) id label =
  fixture.canonical_ids := (id, label) :: !(fixture.canonical_ids)

let create_session_with_id (fixture : fixture) id =
  fixture.start_serial <- fixture.start_serial + 1;
  let canonical = Printf.sprintf "session-visual-%05d" fixture.start_serial in
  register_canonical_id fixture id canonical;
  let document =
    Session.create ~id
      ~cwd:(Lpath.Abs.of_string_exn (Project.root fixture.workspace))
      ~created_at:(Session.Time.of_unix_ms 1_000_000L)
      ()
  in
  fixture.turn_runtime.Turn_runtime.session <- Some document

let fork_session_into (fixture : fixture) ~session ~into =
  let parent =
    match session_by_id fixture session with
    | Some parent -> parent
    | None ->
        Util.failf "next tui harness: fork targeted unknown session %s"
          (Session.Id.to_string session)
  in
  fixture.fork_serial <- fixture.fork_serial + 1;
  register_canonical_id fixture into
    (Printf.sprintf "session-fork-%07d" fixture.fork_serial);
  let cwd = Lpath.Abs.of_string_exn (Project.root fixture.workspace) in
  let created_at = Session.Time.of_unix_ms 1_000_000L in
  match Session.fork ~id:into ~cwd ~created_at parent with
  | Error error ->
      Util.failf "next tui harness: invalid fork fixture for %s: %s"
        (Session.Id.to_string session)
        (Session.Error.message error)
  | Ok child ->
      retain_session fixture parent;
      retain_session fixture child;
      Mutation_runtime.copy fixture.mutation_runtime ~from:session ~into;
      fixture.turn_runtime.Turn_runtime.session <- Some child;
      Ok ()

(* Rewind mirrors [fork_session_into] but cuts the parent journal at [anchor],
   so a non-destructive branch begins from a prior turn boundary. The source is
   retained unchanged, proving the flow keeps the original conversation. *)
let rewind_session_into (fixture : fixture) ~session ~into ~anchor =
  let parent =
    match session_by_id fixture session with
    | Some parent -> parent
    | None ->
        Util.failf "next tui harness: rewind targeted unknown session %s"
          (Session.Id.to_string session)
  in
  fixture.fork_serial <- fixture.fork_serial + 1;
  register_canonical_id fixture into
    (Printf.sprintf "session-fork-%07d" fixture.fork_serial);
  let cwd = Lpath.Abs.of_string_exn (Project.root fixture.workspace) in
  let created_at = Session.Time.of_unix_ms 1_000_000L in
  match Session.rewind ~id:into ~cwd ~created_at anchor parent with
  | Error error ->
      Util.failf "next tui harness: invalid rewind fixture for %s: %s"
        (Session.Id.to_string session)
        (Session.Error.message error)
  | Ok child ->
      retain_session fixture parent;
      retain_session fixture child;
      Mutation_runtime.copy fixture.mutation_runtime ~from:session ~into;
      fixture.turn_runtime.Turn_runtime.session <- Some child;
      Ok ()

let follow_session (fixture : fixture) session ~from =
  match !(fixture.resume_failure_script) with
  | Some error ->
      fixture.resume_failure_script := None;
      Error error
  | None -> (
      match Child_runtime.find_session fixture.child_documents session with
      | Some _ -> (
          match fixture.child_observation_error with
          | Some error -> Error error
          | None ->
              let observation =
                (* A completed live feed is closed before a later drill replay
                   follows the same session. Classify by historical admission,
                   not only by the currently open feed, or that drill is
                   mislabeled Live and its controlled facts can never be
                   released through the Drill boundary. *)
                if
                  Child_runtime.observed fixture.child_documents ~child:session
                    ~observation:Child_observation.Live
                then Child_observation.Drill
                else Child_observation.Live
              in
              Child_runtime.expect fixture.child_documents ~child:session
                observation;
              Child_runtime.follow fixture.child_documents session ~from)
      | None -> (
          match session_by_id fixture session with
          | None -> (
              match fixture.child_observation_error with
              | Some error -> Error error
              | None -> Error (Protocol.Error.Session_not_found session))
          | Some document -> (
              fixture.turn_runtime.Turn_runtime.session <- Some document;
              let all = projected_updates fixture document in
              let selected =
                match from with
                | `Beginning -> Ok all
                | `Now -> Ok []
                | `After position -> (
                    match
                      Protocol.Projection.after position ~session:document
                        ~mutation:
                          (Mutation_runtime.state fixture.mutation_runtime
                             session)
                    with
                    | Ok updates -> Ok updates
                    | Error invalid ->
                        Error (Protocol.Error.Invalid_position invalid))
              in
              match selected with
              | Error _ as error -> error
              | Ok updates ->
                  Main_feeds.attach fixture.main_feeds ~session
                    ~known:(List.map fst all) updates)))

let command_prompt input =
  match text_of_input input with
  | [ prompt ] -> prompt
  | _ ->
      failwith
        "next tui harness: visual prompts must contain one nonblank text part"

let queue_update fixture session update =
  ignore (require_active_session fixture ~operation:"queue edit" session);
  append_events fixture.turn_runtime [ Session.Event.queue_updated update ];
  publish_active_session fixture

let await_queue_edit fixture apply =
  let result = take_queue_edit_result fixture.queue_runtime in
  let gate = Gate.create () in
  let complete () =
    (match result with Ok () -> apply () | Error _ -> ());
    Gate.resolve gate result
  in
  if fixture.queue_runtime.Queue_runtime.hold_results then begin
    (match fixture.queue_runtime.Queue_runtime.current with
    | None -> fixture.queue_runtime.Queue_runtime.current <- Some complete
    | Some _ ->
        failwith "next tui harness: a queued-draft edit result is already held");
    Gate.await gate
  end
  else begin
    complete ();
    Gate.await gate
  end

let answer_decision fixture ~session ~decision ~answer =
  let active =
    require_active_session fixture ~operation:"decision answer" session
  in
  (match fixture.decision_runtime.Decision_runtime.expected with
  | [] ->
      Util.failf "next tui harness: unexpected decision answer %s"
        (Format.asprintf "%a" Session.Decision.Answer.pp answer)
  | expected :: remaining ->
      if not (Session.Decision.Answer.equal expected answer) then
        Util.failf "next tui harness: expected decision answer %s, got %s"
          (Format.asprintf "%a" Session.Decision.Answer.pp expected)
          (Format.asprintf "%a" Session.Decision.Answer.pp answer);
      fixture.decision_runtime.Decision_runtime.expected <- remaining);
  let requested =
    match Session.State.decision decision (Session.state active) with
    | Some (requested, None) -> requested
    | Some (_, Some _) ->
        Util.failf "next tui harness: decision %s was already resolved"
          (Session.Decision.Id.to_string decision)
    | None ->
        Util.failf "next tui harness: unknown decision %s"
          (Session.Decision.Id.to_string decision)
  in
  let resolved =
    match
      Session.Decision.resolve requested
        ~call:(Session.Decision.Requested.call requested)
        ~by:Session.Principal.local_user answer
    with
    | Ok (resolved, _) -> resolved
    | Error error ->
        Util.failf "next tui harness: decision resolution failed: %s"
          (Format.asprintf "%a" Session.Decision.Resolve_error.pp error)
  in
  let admission = Gate.create () in
  let delivery : Decision_runtime.delivery =
    {
      Decision_runtime.acknowledge = (fun () -> Gate.resolve admission (Ok ()));
      resolve =
        (fun () ->
          append_events fixture.turn_runtime
            [ Session.Event.decision_resolved resolved ];
          publish_active_session fixture;
          continue_after_decision fixture ~session
            ~turn:(Session.Decision.Requested.turn requested));
      fail = (fun error -> Gate.resolve admission (Error error));
    }
  in
  if fixture.decision_runtime.Decision_runtime.hold then begin
    if Option.is_some fixture.decision_runtime.Decision_runtime.current then
      failwith "next tui harness: overlapping held decision answers";
    fixture.decision_runtime.Decision_runtime.current <- Some delivery
  end
  else begin
    delivery.Decision_runtime.resolve ();
    delivery.Decision_runtime.acknowledge ()
  end;
  Gate.await admission

let hold_goal_command fixture ~session update =
  ignore (require_active_session fixture ~operation:"goal mutation" session);
  if Option.is_some fixture.goal_runtime.Goal_runtime.current then
    failwith
      "next tui harness: a second goal mutation escaped while one was pending";
  let admission = Gate.create () in
  let delivery : Goal_runtime.delivery =
    {
      Goal_runtime.acknowledge = (fun () -> Gate.resolve admission (Ok ()));
      commit = (fun () -> commit_goal_update fixture update);
      reject = (fun error -> Gate.resolve admission (Error error));
      acknowledged = false;
    }
  in
  fixture.goal_runtime.Goal_runtime.current <- Some delivery;
  Gate.await admission

let submit_command (fixture : fixture) = function
  | Protocol.Command.Prompt { session; turn; input; mode; goal; _ } ->
      ignore (require_active_session fixture ~operation:"prompt" session);
      (* A staged goal is invisible in any rendered frame once the cue clears,
         so the journey surfaces the declaration the prompt carried. *)
      Option.iter
        (fun { Protocol.Command.objective; token_budget = _ } ->
          Printf.printf "goal declared on prompt: %s\n" objective)
        goal;
      begin_turn fixture ~turn_id:turn ~session ~prompt:(command_prompt input)
        ~content:input
        ~mode:(Option.value mode ~default:Session.Contract.Mode.Build)
        ~origin:Session.Turn.Origin.User;
      Ok ()
  | Protocol.Command.Queue_next { session; input } ->
      let entry =
        Session.Queue.Entry.make
          ~id:(mint_queue_id fixture.queue_runtime)
          ~input
      in
      queue_update fixture session (Session.Queue.Update.enqueued entry);
      Ok ()
  | Protocol.Command.Replace_queued { session; inputs } ->
      await_queue_edit fixture (fun () ->
          let entries =
            List.map
              (fun input ->
                Session.Queue.Entry.make
                  ~id:(mint_queue_id fixture.queue_runtime)
                  ~input)
              inputs
          in
          queue_update fixture session (Session.Queue.Update.replaced entries))
  | Protocol.Command.Clear_queued { session } ->
      await_queue_edit fixture (fun () ->
          queue_update fixture session Session.Queue.Update.cleared)
  | Protocol.Command.Interrupt { session; _ } ->
      ignore (require_active_session fixture ~operation:"interrupt" session);
      (match fixture.turn_runtime.Turn_runtime.held with
      | None ->
          failwith "next tui harness: Interrupt escaped without a held turn"
      | Some held ->
          fixture.turn_runtime.Turn_runtime.held <- None;
          held.Turn_runtime.interrupt ());
      Ok ()
  | Protocol.Command.Answer_decision { session; decision; answer } ->
      answer_decision fixture ~session ~decision ~answer
  | Protocol.Command.Goal_pause { session; goal } ->
      hold_goal_command fixture ~session (Session.Goal.Update.pause ~id:goal)
  | Protocol.Command.Goal_edit { session; goal; objective } ->
      hold_goal_command fixture ~session
        (Session.Goal.Update.edit ~id:goal ~objective)
  | Protocol.Command.Goal_resume { session; goal; budget } ->
      hold_goal_command fixture ~session
        (Session.Goal.Update.resume ~id:goal ?token_budget:budget ())
  | Protocol.Command.Goal_clear { session; goal } ->
      hold_goal_command fixture ~session (Session.Goal.Update.clear ~id:goal)

let unavailable text =
  Error (Protocol.Error.Unavailable (Mentat_diagnostic.of_text text))

let model_selection fixture ~session:_ ?reasoning_effort:_ selector =
  (match fixture.model_runtime.Model_runtime.current with
  | Some _ ->
      failwith
        "next tui harness: a second model selection escaped while one was \
         pending"
  | None -> ());
  (match fixture.model_runtime.Model_runtime.expected with
  | [] ->
      Util.failf "next tui harness: unexpected model selection %s"
        (Mentat_provider.Selector.to_string selector)
  | expected :: rest ->
      if not (Mentat_provider.Selector.equal selector expected) then
        Util.failf "next tui harness: expected model selection %s, got %s"
          (Mentat_provider.Selector.to_string expected)
          (Mentat_provider.Selector.to_string selector);
      fixture.model_runtime.Model_runtime.expected <- rest);
  let gate = Gate.create () in
  let complete result = Gate.resolve gate result in
  fixture.model_runtime.Model_runtime.current <- Some complete;
  Gate.await gate

let permission_review fixture ~session review =
  ignore
    (require_active_session fixture ~operation:"set permission review" session);
  (match fixture.permission_runtime.Permission_runtime.current with
  | Some _ ->
      failwith
        "next tui harness: a second permission review escaped while one was \
         pending"
  | None -> ());
  (match fixture.permission_runtime.Permission_runtime.expected with
  | [] ->
      Util.failf "next tui harness: unexpected permission review %s"
        (Format.asprintf "%a" Mentat_permission.Review_behavior.pp review)
  | expected :: rest ->
      if not (Mentat_permission.Review_behavior.equal review expected) then
        Util.failf "next tui harness: expected permission review %s, got %s"
          (Format.asprintf "%a" Mentat_permission.Review_behavior.pp expected)
          (Format.asprintf "%a" Mentat_permission.Review_behavior.pp review);
      fixture.permission_runtime.Permission_runtime.expected <- rest);
  let gate = Gate.create () in
  let settled = ref false in
  let complete result =
    if not !settled then begin
      settled := true;
      match result with
      | Ok () ->
          fixture.permission_runtime.Permission_runtime.effective <- review
      | Error _ -> ()
    end;
    Gate.resolve gate result
  in
  let delivery = { Permission_runtime.complete } in
  fixture.permission_runtime.Permission_runtime.current <- Some delivery;
  Gate.await gate

let login fixture ~provider ~method_ =
  (match fixture.login_runtime.Login_runtime.current with
  | Some _ ->
      failwith
        "next tui harness: a second interactive login escaped while one was \
         active"
  | None -> ());
  let script =
    match fixture.login_runtime.Login_runtime.scripts with
    | [] ->
        Util.failf "next tui harness: unexpected login %s/%s"
          (Mentat_llm.Provider.id provider)
          (Mentat_provider.Auth.Login.Id.to_string method_)
    | script :: rest ->
        if not (Mentat_llm.Provider.equal provider script.Login_script.provider)
        then
          Util.failf "next tui harness: expected login provider %s, got %s"
            (Mentat_llm.Provider.id script.Login_script.provider)
            (Mentat_llm.Provider.id provider);
        if
          not
            (Mentat_provider.Auth.Login.Id.equal method_
               script.Login_script.method_)
        then
          Util.failf "next tui harness: expected login method %s, got %s"
            (Mentat_provider.Auth.Login.Id.to_string script.Login_script.method_)
            (Mentat_provider.Auth.Login.Id.to_string method_);
        fixture.login_runtime.Login_runtime.scripts <- rest;
        script
  in
  let current : Login_runtime.current =
    {
      Login_runtime.steps = script.Login_script.steps;
      released = [];
      signal = Eio.Condition.create ();
      cancelled = false;
    }
  in
  fixture.login_runtime.Login_runtime.current <- Some current;
  let next () =
    Eio.Condition.loop_no_mutex current.Login_runtime.signal (fun () ->
        match current.Login_runtime.released with
        | step :: remaining ->
            current.Login_runtime.released <- remaining;
            Some step
        | [] when current.Login_runtime.cancelled -> Some (Ok Login.Cancelled)
        | [] -> None)
  in
  let cancel () =
    current.Login_runtime.cancelled <- true;
    Eio.Condition.broadcast current.Login_runtime.signal
  in
  Ok { Login.next; cancel }

let hold_save_api_key fixture result =
  (match fixture.account_runtime.Account_runtime.current with
  | Some _ ->
      failwith
        "next tui harness: a second direct account operation escaped while one \
         was active"
  | None -> ());
  let gate = Gate.create () in
  let complete = Gate.resolve gate in
  fixture.account_runtime.Account_runtime.current <-
    Some (Account_runtime.Save_api_key { result; complete });
  Gate.await gate

let hold_logout fixture result =
  (match fixture.account_runtime.Account_runtime.current with
  | Some _ ->
      failwith
        "next tui harness: a second direct account operation escaped while one \
         was active"
  | None -> ());
  let gate = Gate.create () in
  let complete = Gate.resolve gate in
  fixture.account_runtime.Account_runtime.current <-
    Some (Account_runtime.Logout { result; complete });
  Gate.await gate

let query_sessions fixture ~screen =
  let summaries = List.map Session.Summary.of_session fixture.sessions in
  if not screen then Ok (summaries, fixture.session_diagnostics)
  else
    let scripted =
      Screen_sessions_runtime.next fixture.screen_sessions_runtime
    in
    let result =
      match scripted with
      | Ok () -> Ok (summaries, fixture.session_diagnostics)
      | Error error -> Error error
    in
    let gate = Gate.create () in
    let complete () = Gate.resolve gate result in
    if fixture.screen_sessions_runtime.Screen_sessions_runtime.hold_results then
      fixture.screen_sessions_runtime.Screen_sessions_runtime.held <-
        fixture.screen_sessions_runtime.Screen_sessions_runtime.held
        @ [ { Screen_sessions_runtime.complete } ]
    else complete ();
    Gate.await gate

let query_session_view fixture session =
  fixture.query_runtime.Query_runtime.session_views <-
    fixture.query_runtime.Query_runtime.session_views + 1;
  let scripted = Query_runtime.next_session_view fixture.query_runtime in
  let result =
    match (scripted, session_by_id fixture session) with
    | _, None -> unavailable "session detail fixture is missing"
    | Error error, Some _ -> Error error
    | Ok (), Some document -> Ok (Session.Session_view.of_session document)
  in
  let gate = Gate.create () in
  Query_runtime.deliver_session_view fixture.query_runtime (fun () ->
      Gate.resolve gate result);
  Gate.await gate

let query_configuration fixture =
  let result = Query_runtime.next_configuration fixture.query_runtime in
  let gate = Gate.create () in
  Query_runtime.deliver ~hold:true fixture.query_runtime (fun () ->
      Gate.resolve gate result);
  Gate.await gate

let query_model_readiness fixture =
  let result = Query_runtime.next_model_readiness fixture.query_runtime in
  let gate = Gate.create () in
  Query_runtime.deliver ~hold:true fixture.query_runtime (fun () ->
      Gate.resolve gate result);
  Gate.await gate

let query_readiness fixture =
  let result = Readiness_runtime.next fixture.readiness_runtime in
  let gate = Gate.create () in
  Query_runtime.deliver
    ~hold:(fixture.readiness_runtime.Readiness_runtime.calls > 1)
    fixture.query_runtime (fun () -> Gate.resolve gate result);
  Gate.await gate

let client (fixture : fixture) =
  let session : Driver.Session.t =
    {
      Driver.Session.submit = submit_command fixture;
      follow = follow_session fixture;
      answer_unattended =
        (fun ~session:_ ~decision:_ -> unavailable "answer_unattended");
      possibly_mutating =
        (fun ~session ->
          match Child_runtime.find_session fixture.child_documents session with
          | Some _ -> false
          | None -> fixture.possibly_mutating);
      faulted = (fun ~session:_ -> None);
      fork = fork_session_into fixture;
      rewind = rewind_session_into fixture;
      compact =
        (fun ~session ~turn:_ ->
          let document =
            require_active_session fixture ~operation:"compact session" session
          in
          match Compaction_runtime.next fixture.compaction_runtime with
          | Compaction_script.Installed installed ->
              let previous_turn =
                match
                  Session.State.turns (Session.state document) |> List.rev
                with
                | previous :: _ -> previous
                | [] ->
                    failwith
                      "next tui harness: compaction requires a preceding turn"
              in
              let turn_id =
                Compaction_runtime.turn_id fixture.compaction_runtime
              in
              let turn =
                Session.Turn.make ~id:turn_id ~origin:Session.Turn.Origin.User
                  ~input:Session.Turn.Input.continue
                  ~max_steps:(Session.Turn.max_steps previous_turn)
                  ~contract:(Session.Turn.contract previous_turn)
                  ()
              in
              let claim, compaction =
                Compaction_script.materialize ~turn:turn_id installed
              in
              append_events fixture.turn_runtime
                [
                  Session.Event.turn_started turn;
                  Session.Event.provider_requested claim;
                  Session.Event.compaction_installed compaction;
                  Session.Event.turn_finished ~turn:turn_id
                    Session.Turn.Outcome.completed;
                ];
              publish_active_session fixture;
              Ok Client.Installed
          | Compaction_script.Skipped -> Ok Client.Skipped
          | Compaction_script.Failed error -> Error error);
      pending_decision = (fun _ -> Ok None);
      running_processes = (fun _ -> Ok (fixture.running ()));
      change_diff =
        (fun ~session ~change ->
          Mutation_runtime.change_diff fixture.mutation_runtime ~session ~change);
      tail = (fun ?n:_ _ -> unavailable "tail");
      page = (fun ?n:_ _ ~before:_ -> unavailable "page");
      revert = (fun ~session:_ ~scope:_ -> unavailable "revert");
      undo =
        (fun ~session ~op ->
          (* A functional fake: append the durable undo boundary to the active
             session's feed exactly as the engine driver does, so the TUI seam,
             armed state, and composer reload exercise the real fold. File
             reverts are canned as [Nothing_to_revert] — the scripted turns
             record no edits. *)
          let document =
            require_active_session fixture ~operation:"undo" session
          in
          let st = Session.state document in
          let user_ids =
            List.filter_map
              (fun turn ->
                let id = Session.Turn.id turn in
                if Session.State.can_undo_anchor id st then Some id else None)
              (Session.State.turns st)
          in
          let current =
            Option.map (fun u -> u.Session.State.anchor) (Session.State.undo st)
          in
          let boundary =
            match op with
            | `Undo ->
                let target =
                  match current with
                  | None -> (
                      match List.rev user_ids with
                      | id :: _ -> Some id
                      | [] -> None)
                  | Some anchor ->
                      let rec before prev = function
                        | [] -> None
                        | id :: rest ->
                            if Session.Turn.Id.equal id anchor then prev
                            else before (Some id) rest
                      in
                      before None user_ids
                in
                Option.map
                  (fun anchor -> Session.Undo.Update.armed ~anchor ())
                  target
            | `Redo | `Cancel -> Some Session.Undo.Update.released
          in
          match boundary with
          | None -> Ok (Mutation.Revert.Outcome.Refused [ "nothing to undo" ])
          | Some update ->
              append_events fixture.turn_runtime
                [ Session.Event.undo_updated update ];
              publish_active_session fixture;
              Ok Mutation.Revert.Outcome.Nothing_to_revert);
      export = (fun ~session:_ -> unavailable "export");
    }
  in
  let accounts : Driver.Accounts.t =
    {
      Driver.Accounts.login = login fixture;
      save_api_key =
        (fun ~provider ~key ->
          match fixture.save_api_key with
          | None -> unavailable "unsupported effect auth_save_api_key"
          | Some save -> hold_save_api_key fixture (save provider ~key));
      logout =
        (fun ?revoke:_ provider ->
          match fixture.logout with
          | None -> unavailable "unsupported effect auth_logout"
          | Some logout -> hold_logout fixture (logout provider));
      account_readiness = (fun () -> query_readiness fixture);
      model_readiness = (fun ?refresh:_ () -> query_model_readiness fixture);
    }
  in
  let settings : Driver.Settings.t =
    {
      Driver.Settings.set_model = model_selection fixture;
      set_permission_review = permission_review fixture;
      configuration = (fun () -> query_configuration fixture);
      set_default_model =
        (fun ?reasoning_effort:_ _ -> unavailable "set_default_model");
      set_ui_theme = (fun ~theme:_ -> unavailable "set_ui_theme");
    }
  in
  let lifecycle : Driver.Lifecycle.t =
    {
      Driver.Lifecycle.create =
        (fun ~id ~title:_ ->
          if !(fixture.drop_first_start) then begin
            fixture.drop_first_start := false;
            let never = Gate.create () in
            Gate.await never
          end
          else begin
            create_session_with_id fixture id;
            Ok ()
          end);
      rename =
        (fun ~session ~title ->
          mutate_session_result fixture
            ~operation:(Lifecycle_script.Rename { session; title })
            (fun document -> Ok (Session.set_title (Some title) document)));
      archive =
        (fun ~session ->
          mutate_session_result fixture
            ~operation:(Lifecycle_script.Archive session) Session.archive);
      restore =
        (fun ~session ->
          mutate_session_result fixture
            ~operation:(Lifecycle_script.Restore session) Session.restore);
      delete =
        (fun ~session ->
          mutate_session_result fixture
            ~operation:(Lifecycle_script.Delete session) Session.delete);
      sessions =
        (fun ~listing ->
          query_sessions fixture
            ~screen:(List.length listing.Session.Listing.lifecycles > 1));
      session = query_session_view fixture;
    }
  in
  let review : Driver.Review.t =
    {
      Driver.Review.apply = Review_runtime.apply fixture.review_runtime;
      state = Review_runtime.state fixture.review_runtime;
      diff = Review_runtime.diff fixture.review_runtime;
      crs = Review_runtime.crs fixture.review_runtime;
      compose = Review_runtime.compose fixture.review_runtime;
    }
  in
  let workspace : Driver.Workspace.t =
    {
      Driver.Workspace.glance = (fun () -> Ok (fst fixture.glance));
      dune = (fun () -> Ok (snd fixture.glance));
      dune_control =
        (fun ~op:_ ->
          Ok (Mentat_workspace.Health.Off Mentat_workspace.Health.Off.Disabled));
    }
  in
  let user_commands () = Ok (List.map fst fixture.user_commands) in
  let expand_command ~name ~arguments =
    match
      List.find_opt
        (fun ((summary : Protocol.User_command.t), _) ->
          String.equal
            (Protocol.User_command.Name.to_string
               summary.Protocol.User_command.name)
            name)
        fixture.user_commands
    with
    | Some (_, body) ->
        let text = Mentat_context.Commands.substitute ~body ~arguments in
        if String.equal (String.trim text) "" then Ok []
        else Ok [ Mentat_llm.Content.text text ]
    | None -> (
        match Protocol.User_command.Name.of_string name with
        | Ok command_name -> Error (Protocol.Error.Unknown_command command_name)
        | Error message ->
            Error
              (Protocol.Error.Unavailable (Mentat_diagnostic.of_text message)))
  in
  Client.make ~user_commands ~expand_command
    ~attach:(fun ~session:_ source ->
      Attach_runtime.next fixture.attach_runtime source)
    { Driver.session; accounts; settings; lifecycle; review; workspace }

let local (fixture : fixture) =
  let enumerate_files =
    if fixture.capabilities.file_enumeration then Some fixture.enumerate_files
    else None
  in
  let open_url =
    if fixture.capabilities.browser then
      Some
        (fun url ->
          fixture.account_runtime.Account_runtime.opened_urls <-
            url :: fixture.account_runtime.Account_runtime.opened_urls;
          Ok ())
    else None
  in
  let run_local_shell =
    if fixture.capabilities.local_shell then
      Some
        (fun ~cancelled:_ ~command:_ ->
          let failure = Gate.create () in
          fixture.local_shell_runtime.Local_shell_runtime.current <-
            Some failure;
          Gate.await failure)
    else None
  in
  let edit_in_editor =
    Option.map (fun edit ~text -> Ok (edit text)) fixture.edit_in_editor
  in
  let attach_image_path =
    if fixture.image_attach then
      let workspace =
        Mentat_workspace.single
          (Mentat_workspace.Root.of_dir
             (Lpath.Abs.of_string_exn (Project.root fixture.workspace)))
      in
      Some (fun rel -> Mentat_workspace.path_at_cwd_root workspace rel)
    else None
  in
  let clipboard_image =
    Option.map (fun image () -> Some image) fixture.clipboard_image
  in
  Runtime.Local.make
    ~load_prompt_history:(fun () -> fixture.history)
    ~append_prompt_history:(fun _ -> ())
    ?enumerate_files ?open_url ?run_local_shell ?edit_in_editor
    ?notify:fixture.notify ?attach_image_path ?clipboard_image ()

(* A launch draft rides the [--draft] startup input, the one supported way to
   seed the composer at launch. *)
let startup fixture snapshot =
  let input =
    match fixture.draft with
    | None -> Startup.Empty
    | Some text -> Startup.Draft text
  in
  Startup.make ~snapshot ~mode:Session.Contract.Mode.Build
    ~session:fixture.startup_session ~input ~providers:fixture.providers
    ~permission_review:fixture.permission_runtime.Permission_runtime.effective
    ()

(* Notifications are off by default so ordinary suites see no notify effects; a
   notification test supplies its own policy and a capturing [notify] hook. *)
let disabled_notify_policy =
  {
    App.notify_enabled = false;
    notify_channel = Mentat_config.Notify.Channel.Auto;
    notify_focus = Mentat_config.Notify.When.Unfocused;
    notify_on = [];
  }

let run ?(size = (80, 24)) ?(env = []) ?(reduced_motion = true)
    ?(show_reasoning = true) ?(overlay = Mentat_tui.Command.Overlay.empty)
    ?(notify_policy = disabled_notify_policy) ?notify
    ?(palette = Theme.Palette.default) ?(sessions = fun _ -> [])
    ?(session_diagnostics = []) ?(history = "") ?draft ?session
    ?(possibly_mutating = false) ?(child_sessions = fun _ -> [])
    ?(drop_first_start = false)
    ?(enumerate_files =
      fun () -> Util.failf "next tui harness: no workspace-file fixture")
    ?(file_enumeration = false) ?(local_shell = false) ?edit_in_editor
    ?(browser = false) ?(image_attach = false) ?(attach_responses = [])
    ?clipboard_image ?(image_max_count = 20) ?child_observation_error
    ?(providers = []) ?readiness ?readiness_responses ?readiness_results
    ?model_readiness_results ?save_api_key ?logout ?(login_scripts = [])
    ?(model_selections = []) ?(permission_reviews = []) ?(decision_answers = [])
    ?(decision_continuations = []) ?(turns = []) ?(compactions = [])
    ?(review = []) ?(workspace_glance = (None, Workspace.Health.Off Workspace.Health.Off.Disabled))
    ?(running_processes = fun () -> []) ?(user_commands = []) ?lifecycle_results
    ?(hold_lifecycle_results = false) ?screen_session_results
    ?(hold_screen_session_results = false) ?queue_edit_results
    ?(hold_queue_edit_results = false) ?session_view_results
    ?(hold_session_view_results = false) ?configuration_results
    ?(hold_settings_queries = false) ?(hold_decision_resolution = false)
    ?snapshot ?(trusted = true)
    ?(home =
      fun project ->
        Some (Lpath.Abs.of_string_exn (Filename.dirname (Project.root project))))
    ~name f =
  Project.with_temp name @@ fun project ->
  let home = home project in
  let snapshot =
    match snapshot with
    | Some snapshot -> snapshot project ~trusted
    | None ->
        Snapshot.make ~version:"dev" ~model:"openai/gpt-5.5"
          ~effort:(Some "medium")
          ~cwd:(Lpath.Abs.of_string_exn (Project.root project))
          ~home ~context_window:(Some 128_000)
          ~sandbox:(Some "danger-full-access") ~trusted
  in
  let sessions = sessions project in
  let child_runtime = Child_runtime.create (child_sessions project) in
  let capabilities : capabilities =
    { local_shell; file_enumeration; browser }
  in
  let turns =
    {
      Turn_runtime.scripts = turns;
      Turn_runtime.session = None;
      Turn_runtime.held = None;
      Turn_runtime.count = 0;
    }
  in
  let mutation_runtime = { Mutation_runtime.ledgers = [] } in
  let compaction_runtime =
    { Compaction_runtime.scripts = compactions; serial = 0 }
  in
  let lifecycle_scripts =
    match lifecycle_results with
    | None -> Lifecycle_runtime.Default_success
    | Some scripts -> Lifecycle_runtime.Scripted scripts
  in
  let lifecycle_runtime =
    {
      Lifecycle_runtime.scripts = lifecycle_scripts;
      hold_results = hold_lifecycle_results;
      current = None;
    }
  in
  let screen_session_scripts =
    match screen_session_results with
    | None -> Screen_sessions_runtime.Default_success
    | Some results -> Screen_sessions_runtime.Scripted results
  in
  let screen_sessions_runtime =
    {
      Screen_sessions_runtime.scripts = screen_session_scripts;
      hold_results = hold_screen_session_results;
      held = [];
    }
  in
  let edit_results =
    match queue_edit_results with
    | None -> Queue_runtime.Default_success
    | Some results -> Queue_runtime.Scripted results
  in
  let queue =
    {
      Queue_runtime.serial = 0;
      edit_results;
      hold_results = hold_queue_edit_results;
      current = None;
    }
  in
  let models =
    { Model_runtime.expected = model_selections; Model_runtime.current = None }
  in
  let permissions =
    {
      Permission_runtime.expected = permission_reviews;
      current = None;
      effective = Mentat_permission.Review_behavior.Enforce;
    }
  in
  let goals = { Goal_runtime.current = None; update = None } in
  let decisions =
    {
      Decision_runtime.expected = decision_answers;
      continuations = decision_continuations;
      hold = hold_decision_resolution;
      current = None;
    }
  in
  let logins =
    { Login_runtime.scripts = login_scripts; Login_runtime.current = None }
  in
  let readiness_value =
    Option.value readiness
      ~default:
        [
          Account.Discovery.Known
            (Account.missing ~provider:(Mentat_llm.Provider.make "openai"));
        ]
  in
  let readiness_source =
    match (readiness, readiness_responses, readiness_results) with
    | Some _, (Some _ | None), Some _
    | Some _, Some _, None
    | None, Some _, Some _ ->
        invalid_arg
          "Tui.run: readiness, readiness_responses, and readiness_results are \
           mutually exclusive"
    | None, None, Some results -> Readiness_runtime.Scripted results
    | None, Some responses, None ->
        Readiness_runtime.Scripted (List.map Result.ok responses)
    | None, None, None | Some _, None, None ->
        Readiness_runtime.Constant (Ok readiness_value)
  in
  let readiness_runtime =
    { Readiness_runtime.source = readiness_source; calls = 0 }
  in
  let accounts = { Account_runtime.current = None; opened_urls = [] } in
  let queries =
    let configuration_source =
      match configuration_results with
      | None -> Query_runtime.Default_unavailable
      | Some results -> Query_runtime.Scripted_configuration results
    in
    let model_readiness_source =
      match model_readiness_results with
      | None -> Query_runtime.Default_model_readiness_unavailable
      | Some results -> Query_runtime.Scripted_model_readiness results
    in
    let session_view_source =
      match session_view_results with
      | None -> Query_runtime.Default_success
      | Some results -> Query_runtime.Scripted results
    in
    {
      Query_runtime.hold_settings = hold_settings_queries;
      hold_session_views = hold_session_view_results;
      configuration_source;
      model_readiness_source;
      session_views = 0;
      session_view_source;
      held = [];
      held_session_views = [];
    }
  in
  let local_shells = { Local_shell_runtime.current = None } in
  let bindings = Project.bindings ~extra:env project in
  Project.with_process_env bindings @@ fun () ->
  Eio_main.run @@ fun stdenv ->
  let width, height = size in
  let cell = ref None in
  let on_idle _backend ~timeout =
    let t = Option.get !cell in
    t.idles <- t.idles + 1;
    t.last_timeout <- timeout;
    t.parked <- true;
    Eio.Condition.broadcast t.parked_cond;
    while (not t.signaled) && not t.stopping do
      Eio.Condition.await_no_mutex t.cond
    done;
    t.signaled <- false;
    t.parked <- false
  in
  let on_wake () = Option.iter wake !cell in
  let backend =
    Matrix_test.create ~target_fps:10. ~now:epoch ~on_idle ~on_wake ~width
      ~height ()
  in
  let resume_failure = ref None in
  let main_feeds = Main_feeds.create () in
  let canonical_ids = ref [] in
  let drop_first_start = ref drop_first_start in
  let t =
    {
      backend;
      real_clock = Eio.Stdenv.clock stdenv;
      cond = Eio.Condition.create ();
      parked_cond = Eio.Condition.create ();
      signaled = false;
      parked = false;
      idles = 0;
      wakes = 0;
      last_timeout = None;
      stopping = false;
      finished = false;
      probe = None;
      launch_now = epoch;
      turns;
      lifecycles = lifecycle_runtime;
      screen_sessions = screen_sessions_runtime;
      models;
      permissions;
      goals;
      decisions;
      logins;
      accounts;
      queries;
      local_shells;
      queue_edits = queue;
      child_runtime;
      project;
      resume_failure;
      feed_runtime = main_feeds;
      id_replacements = canonical_ids;
    }
  in
  cell := Some t;
  let fixture =
    {
      sessions;
      start_serial = 0;
      fork_serial = 0;
      session_diagnostics;
      providers;
      readiness_runtime;
      history;
      draft;
      startup_session = session;
      possibly_mutating;
      enumerate_files;
      capabilities;
      image_attach;
      attach_runtime = { Attach_runtime.responses = attach_responses };
      clipboard_image;
      child_observation_error;
      child_documents = child_runtime;
      main_feeds;
      save_api_key;
      logout;
      turn_runtime = turns;
      mutation_runtime;
      compaction_runtime;
      lifecycle_runtime;
      screen_sessions_runtime;
      queue_runtime = queue;
      model_runtime = models;
      permission_runtime = permissions;
      goal_runtime = goals;
      decision_runtime = decisions;
      login_runtime = logins;
      account_runtime = accounts;
      query_runtime = queries;
      review_runtime =
        (match review with
        | [] -> Review_runtime.empty
        | e -> Review_runtime.seed e);
      local_shell_runtime = local_shells;
      edit_in_editor;
      notify;
      workspace = project;
      glance = workspace_glance;
      running = running_processes;
      user_commands;
      resume_failure_script = resume_failure;
      drop_first_start;
      canonical_ids;
    }
  in
  goals.Goal_runtime.update <-
    Some (fun update -> commit_goal_update fixture update);
  Eio.Fiber.both
    (fun () ->
      Fun.protect
        ~finally:(fun () ->
          t.finished <- true;
          Eio.Condition.broadcast t.parked_cond)
        (fun () ->
          match
            Runtime.run ~stdenv ~client:(client fixture)
              ~startup:(startup fixture snapshot) ~local:(local fixture)
              ~reduced_motion ~show_reasoning ~overlay ~notify_policy ~palette
              ~theme_name:"mentat-dark" ~themes:Theme.Preset.all
              ~theme_auto:None ~image_max_count ~mouse:true
              ~matrix:(Matrix_test.app backend)
              ~probe:(fun probe ->
                t.launch_now <- Matrix_test.now backend;
                t.probe <- Some probe)
              ()
          with
          | Ok _ -> ()
          | Error error -> failwith (Runtime.error_message error)))
    (fun () ->
      Fun.protect
        ~finally:(fun () ->
          t.stopping <- true;
          Matrix_test.stop backend;
          wake t)
        (fun () ->
          f t;
          (match accounts.Account_runtime.current with
          | None -> ()
          | Some (Account_runtime.Save_api_key _) ->
              failwith
                "next tui harness: an API-key save was left without a result"
          | Some (Account_runtime.Logout _) ->
              failwith "next tui harness: a logout was left without a result");
          if Option.is_some queue.Queue_runtime.current then
            failwith
              "next tui harness: a queued-draft edit was left without a result";
          if Option.is_some lifecycle_runtime.Lifecycle_runtime.current then
            failwith
              "next tui harness: a session lifecycle operation was left \
               without a result";
          (match screen_sessions_runtime.Screen_sessions_runtime.held with
          | [] -> ()
          | held ->
              Util.failf
                "next tui harness: %d full-browser session result(s) remained \
                 held"
                (List.length held));
          (match queries.Query_runtime.held_session_views with
          | [] -> ()
          | held ->
              Util.failf
                "next tui harness: %d session-view result(s) remained held"
                (List.length held));
          if Option.is_some permissions.Permission_runtime.current then
            failwith
              "next tui harness: a permission review was left without a result";
          if Option.is_some goals.Goal_runtime.current then
            failwith
              "next tui harness: a goal mutation was left without a result or \
               durable fact";
          (match readiness_runtime.Readiness_runtime.source with
          | Readiness_runtime.Constant _ | Readiness_runtime.Scripted [] -> ()
          | Readiness_runtime.Scripted remaining ->
              Util.failf
                "next tui harness: %d account-readiness response(s) were unused"
                (List.length remaining));
          (match fixture.attach_runtime.Attach_runtime.responses with
          | [] -> ()
          | remaining ->
              Util.failf "next tui harness: %d attach response(s) were unused"
                (List.length remaining));
          (match queue.Queue_runtime.edit_results with
          | Queue_runtime.Default_success | Queue_runtime.Scripted [] -> ()
          | Queue_runtime.Scripted remaining ->
              Util.failf
                "next tui harness: %d queued-draft edit result(s) were unused"
                (List.length remaining));
          (match compaction_runtime.Compaction_runtime.scripts with
          | [] -> ()
          | remaining ->
              Util.failf
                "next tui harness: %d manual-compaction result(s) were unused"
                (List.length remaining));
          (match lifecycle_runtime.Lifecycle_runtime.scripts with
          | Lifecycle_runtime.Default_success | Lifecycle_runtime.Scripted [] ->
              ()
          | Lifecycle_runtime.Scripted remaining ->
              Util.failf
                "next tui harness: %d session lifecycle result(s) were unused"
                (List.length remaining));
          (match screen_sessions_runtime.Screen_sessions_runtime.scripts with
          | Screen_sessions_runtime.Default_success
          | Screen_sessions_runtime.Scripted [] ->
              ()
          | Screen_sessions_runtime.Scripted remaining ->
              Util.failf
                "next tui harness: %d full-browser session result(s) were \
                 unused"
                (List.length remaining));
          (match queries.Query_runtime.session_view_source with
          | Query_runtime.Default_success | Query_runtime.Scripted [] -> ()
          | Query_runtime.Scripted remaining ->
              Util.failf
                "next tui harness: %d session-view result(s) were unused"
                (List.length remaining));
          (match queries.Query_runtime.configuration_source with
          | Query_runtime.Default_unavailable
          | Query_runtime.Scripted_configuration [] ->
              ()
          | Query_runtime.Scripted_configuration remaining ->
              Util.failf
                "next tui harness: %d configuration response(s) were unused"
                (List.length remaining));
          (match queries.Query_runtime.model_readiness_source with
          | Query_runtime.Default_model_readiness_unavailable
          | Query_runtime.Scripted_model_readiness [] ->
              ()
          | Query_runtime.Scripted_model_readiness remaining ->
              Util.failf
                "next tui harness: %d model-readiness response(s) were unused"
                (List.length remaining));
          (match decisions.Decision_runtime.expected with
          | [] -> ()
          | remaining ->
              Util.failf
                "next tui harness: %d expected decision answer(s) were unused"
                (List.length remaining));
          (match decisions.Decision_runtime.continuations with
          | [] -> ()
          | remaining ->
              Util.failf
                "next tui harness: %d post-decision continuation(s) were unused"
                (List.length remaining));
          (match permissions.Permission_runtime.expected with
          | [] -> ()
          | remaining ->
              Util.failf
                "next tui harness: %d expected permission review(s) were unused"
                (List.length remaining));
          match turns.Turn_runtime.scripts with
          | [] -> (
              match models.Model_runtime.expected with
              | [] -> (
                  match
                    (logins.Login_runtime.scripts, logins.Login_runtime.current)
                  with
                  | [], None -> ()
                  | remaining, None ->
                      Util.failf
                        "next tui harness: %d scripted login(s) were unused"
                        (List.length remaining)
                  | _, Some current ->
                      Util.failf
                        "next tui harness: active login retained %d step(s)"
                        (List.length current.Login_runtime.steps))
              | remaining ->
                  Util.failf
                    "next tui harness: %d expected model selection(s) were \
                     unused"
                    (List.length remaining))
          | remaining ->
              Util.failf "next tui harness: %d scripted turn(s) were unused"
                (List.length remaining)))
