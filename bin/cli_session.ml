(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Store = Mentat_store
module Session = Mentat_session
module Id = Mentat_session.Id
module Document = Store.Session.Document
module Client = Mentat_client
module Anchor = Session.Anchor
module Turn = Session.Turn
module Mutation = Store.Mutation
module State = Mentat_mutation.State
module Change = Mentat_mutation.Change
module Net = Change.Net
module Revert = Mentat_mutation.Revert
module Revertability = Mentat_mutation.Revertability
module Image = Mentat_mutation.Image
module Ports = Mentat_agent.Ports
module Diff = Textdiff
module Listing = Mentat_session.Listing

let docs = Cli_common.s_session
let fresh_id () = Id.of_string (Session_meta.fresh_id ())

(* A fresh client-minted compaction turn id, minted the way [run]/[reply] mint a
   prompt's turn id. *)
let fresh_turn () = Turn.Id.of_string (Session_meta.fresh_id ~prefix:"t" ())
let doc_id d = Id.to_string (Document.id d)
let ( let* ) = Result.bind

(* An explicit [--id] is validated before it reaches a store smart constructor;
   [None] mints a fresh id. *)
let validate_id_opt = function
  | None -> Ok None
  | Some s -> Result.map Option.some (Argv.session_id s)

(* Rendering. *)

let age_string t updated =
  let now = Session.Time.to_unix_ms (Composition.now_time t) in
  let then_ = Session.Time.to_unix_ms updated in
  let secs = Int64.to_int (Int64.div (Int64.sub now then_) 1000L) in
  if secs < 60 then Printf.sprintf "%ds" secs
  else if secs < 3600 then Printf.sprintf "%dm" (secs / 60)
  else if secs < 86400 then Printf.sprintf "%dh" (secs / 3600)
  else Printf.sprintf "%dd" (secs / 86400)

(* Phase and lifecycle read the session-owned [Summary] projection so the CLI
   offline twin and the [sessions] query responder render one vocabulary. *)
let phase_string session =
  Session.Summary.Phase.to_string
    (Session.Summary.phase (Session.Summary.of_session session))

let listing ~all ~archived ~deleted ~search ~limit : Listing.t =
  let optional enabled status = if enabled then [ status ] else [] in
  {
    Listing.scope = (if all then `All else `Cwd);
    lifecycles =
      [ Session.Metadata.Status.Active ]
      @ optional archived Session.Metadata.Status.Archived
      @ optional deleted Session.Metadata.Status.Deleted;
    search;
    limit = (if limit = 0 then None else Some limit);
  }

let corrupt_json fact =
  Output.Json.obj
    [
      ( "id",
        match Store.Session.Corrupt.id fact with
        | None -> Output.Json.null
        | Some id -> Output.Json.string (Id.to_string id) );
      ("path", Output.Json.string (Store.Session.Corrupt.path fact));
      ("message", Output.Json.string (Store.Session.Corrupt.message fact));
    ]

let report_corrupt fact =
  Output.stderr_printf "mentat: corrupt session document at %s: %s\n"
    (Store.Session.Corrupt.path fact)
    (Store.Session.Corrupt.message fact)

(* One renderer shared by [list] and [search]: JSON emits the shed shape
   (id/phase/lifecycle/title, no event_count/active_turn/revision); the table
   shows [ID PHASE [LIFECYCLE] AGE [CWD] TITLE]. *)
let render_summaries ~json ~type_ ?query ~all ~archived ~deleted ~corrupt t
    summaries =
  List.iter report_corrupt corrupt;
  if json then
    Output.stdout_printf "%s\n"
      (Output.Json.to_string
         (Output.Json.envelope ~type_
            (Option.fold ~none:[]
               ~some:(fun query -> [ ("query", Output.Json.string query) ])
               query
            @ [
                ( "sessions",
                  Output.Json.list
                    (List.map
                       (fun s ->
                         Output.Json.obj
                           [
                             ( "id",
                               Output.Json.string
                                 (Id.to_string (Session.Summary.id s)) );
                             ( "phase",
                               Output.Json.string
                                 (Session.Summary.Phase.to_string
                                    (Session.Summary.phase s)) );
                             ( "lifecycle",
                               Output.Json.string
                                 (Session.Metadata.Status.to_string
                                    (Session.Summary.lifecycle s)) );
                             ( "title",
                               Output.Json.string_or_null
                                 (Session.Summary.title s) );
                           ])
                       summaries) );
                ("corrupt", Output.Json.list (List.map corrupt_json corrupt));
              ])))
  else
    let show_lifecycle = archived || deleted in
    let show_cwd = all in
    let cols a mid b = a @ (if show_lifecycle then mid else []) @ b in
    let header =
      cols [ "ID"; "PHASE" ] [ "LIFECYCLE" ]
        ([ "AGE" ] @ (if show_cwd then [ "CWD" ] else []) @ [ "TITLE" ])
    in
    Output.print_table ~header
      (List.map
         (fun s ->
           cols
             [
               Id.to_string (Session.Summary.id s);
               Session.Summary.Phase.to_string (Session.Summary.phase s);
             ]
             [ Session.Metadata.Status.to_string (Session.Summary.lifecycle s) ]
             ([ age_string t (Session.Summary.updated_at s) ]
             @ (if show_cwd then [ Lpath.Abs.to_string (Session.Summary.cwd s) ]
                else [])
             @ [ Option.value ~default:"" (Session.Summary.title s) ]))
         summaries)

(* create. *)

let create json id_opt title cwd =
  (let* id_opt = validate_id_opt id_opt in
   let* title = Argv.title_opt title in
   Ok
     (Composition.with_base ~cwd ~overrides:[] (fun t ->
          let id = match id_opt with Some id -> id | None -> fresh_id () in
          let session =
            Session.create ~id ?title ~cwd:(Composition.root t)
              ~created_at:(Composition.now_time t) ()
          in
          match Store.Session.create (Composition.store t) session with
          | Error e ->
              Exit_status.of_protocol_error
                (Session_meta.session_store_error_to_protocol id e)
          | Ok _ ->
              if json then
                Output.stdout_printf "%s\n"
                  (Output.Json.to_string
                     (Output.Json.envelope ~type_:"session"
                        [ ("session", Output.Json.string (Id.to_string id)) ]))
              else Output.stdout_printf "%s\n" (Id.to_string id);
              Exit_status.Success)))
  |> Exit_status.of_result

let id_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "id" ] ~docv:"ID" ~doc:"Use this session id.")

let title_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "title" ] ~docv:"TITLE" ~doc:"Session title.")

let create_cmd =
  let doc = "Create an empty session." in
  Cmd.v
    (Cmd.info "create" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const create $ Cli_common.json $ id_opt $ title_opt $ Cli_common.cwd))

(* list. *)

let list json all archived deleted limit cwd =
  match Argv.limit limit with
  | Error status -> status
  | Ok limit ->
      Composition.with_base ~cwd ~overrides:[] (fun t ->
          let listing = listing ~all ~archived ~deleted ~search:None ~limit in
          match Store.Session.scan (Composition.store t) with
            | Error error ->
                Exit_status.of_diagnostic (Store.Session.Error.diagnostic error)
            | Ok (all_docs, corrupt) ->
                let summaries =
                  List.map
                    (fun d -> Session.Summary.of_session (Document.session d))
                    all_docs
                  |> Listing.select ~cwd:(Composition.root t) listing
                in
                render_summaries ~json ~type_:"sessions" ~all ~archived ~deleted
                  ~corrupt t summaries;
                Exit_status.Success)

let all_flag = Arg.(value & flag & info [ "all" ] ~doc:"All workspaces.")

let archived_flag =
  Arg.(value & flag & info [ "archived" ] ~doc:"Archived sessions.")

let deleted_flag =
  Arg.(value & flag & info [ "deleted" ] ~doc:"Deleted sessions.")

let limit_opt =
  Arg.(
    value & opt int 25
    & info [ "n"; "limit" ] ~docv:"N" ~doc:"Maximum rows (0 = unlimited).")

let list_cmd =
  let doc = "List sessions." in
  Cmd.v
    (Cmd.info "list" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const list $ Cli_common.json $ all_flag $ archived_flag $ deleted_flag
         $ limit_opt $ Cli_common.cwd))

(* search. — the same offline-store twin as [list], narrowed by a
   case-insensitive substring over the [Summary]'s id, title, preview, and cwd.
   The match reads only summary fields, so it costs no more than a plain list
   (no transcript scan). *)

let search json all archived deleted limit query cwd =
  match
    if String.is_empty query then
      Error (Exit_status.usage "search must not be empty")
    else Argv.limit limit
  with
  | Error status -> status
  | Ok limit ->
      Composition.with_base ~cwd ~overrides:[] (fun t ->
          match Store.Session.scan (Composition.store t) with
          | Error error ->
              Exit_status.of_diagnostic (Store.Session.Error.diagnostic error)
          | Ok (all_docs, corrupt) ->
              let summaries =
                List.map
                  (fun d -> Session.Summary.of_session (Document.session d))
                  all_docs
                |> Listing.select ~cwd:(Composition.root t)
                     (listing ~all ~archived ~deleted ~search:(Some query)
                        ~limit)
              in
              render_summaries ~json ~type_:"session_search" ~query ~all
                ~archived ~deleted ~corrupt t summaries;
              Exit_status.Success)

let query_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"QUERY"
        ~doc:"Case-insensitive substring over id, title, preview, and cwd.")

let search_cmd =
  let doc = "Search sessions by id, title, preview, or cwd." in
  Cmd.v
    (Cmd.info "search" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const search $ Cli_common.json $ all_flag $ archived_flag
         $ deleted_flag $ limit_opt $ query_arg $ Cli_common.cwd))

(* show. *)

let first_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

(* The open decision suspension, surfaced offline through the session's own
   [State.suspension] projection. [show] renders its payload and the [mentat run
   reply] commands that resolve it, the same reply vocabulary [cli_run] prints
   live; a shared [Session_waiting] home is a follow-up once the run surface
   settles. Provider and tool waits are already carried by the [waiting] token. *)
let pending_decision session =
  match Session.State.suspension (Session.state session) with
  | Some (Session.State.Decision requested) -> Some requested
  | Some (Session.State.Provider _ | Session.State.Tool _) | None -> None

let decision_reply_commands ~session requested =
  let prefix =
    Printf.sprintf "mentat run reply %s --decision %s" (Id.to_string session)
      (Session.Decision.Id.to_string (Session.Decision.Requested.id requested))
  in
  match Session.Decision.Requested.request requested with
  | Session.Decision.Request.Permission _ ->
      [
        prefix ^ " --allow";
        prefix ^ " --allow-conversation";
        prefix ^ " --deny";
      ]
  | Session.Decision.Request.Question _ ->
      [ prefix ^ " --answer 'YOUR ANSWER'" ]
  | Session.Decision.Request.Plan _ ->
      [ prefix ^ " --approve-plan"; prefix ^ " --reject-plan" ]

let decision_summary requested =
  Printf.sprintf "%s decision on tool %s (%s)"
    (Session.Decision.Requested.tag requested)
    (Session.Decision.Requested.name requested)
    (Mentat_tool.Stage.to_string (Session.Decision.Requested.stage requested))

let decision_json ~session requested =
  Output.Json.obj
    [
      ( "decision",
        Output.Json.string
          (Session.Decision.Id.to_string
             (Session.Decision.Requested.id requested)) );
      ("tag", Output.Json.string (Session.Decision.Requested.tag requested));
      ("tool", Output.Json.string (Session.Decision.Requested.name requested));
      ( "stage",
        Output.Json.string
          (Mentat_tool.Stage.to_string
             (Session.Decision.Requested.stage requested)) );
      ( "call_id",
        Output.Json.string (Session.Decision.Requested.call_id requested) );
      ( "reply_commands",
        Output.Json.list
          (List.map Output.Json.string
             (decision_reply_commands ~session requested)) );
    ]

let show json session_opt last cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Session_locate.resolve t ~session:session_opt ~last with
      | Error error -> Session_locate.status error
      | Ok d ->
          let view = Session.Session_view.of_session (Document.session d) in
          let summary = Session.Session_view.summary view in
          let id = Id.to_string (Session.Summary.id summary) in
          let phase =
            Session.Summary.Phase.to_string (Session.Summary.phase summary)
          in
          let lifecycle =
            Session.Metadata.Status.to_string
              (Session.Summary.lifecycle summary)
          in
          let title = Session.Summary.title summary in
          let cwd_s = Lpath.Abs.to_string (Session.Summary.cwd summary) in
          let turns = Session.Summary.turns summary in
          let model =
            Option.map Mentat_llm.Model.id
              (Session.Session_view.active_model view)
          in
          let mode =
            Option.map
              (fun m -> Format.asprintf "%a" Session.Contract.Mode.pp m)
              (Session.Session_view.workflow_mode view)
          in
          let outcome =
            Option.map
              (fun o -> Format.asprintf "%a" Session.Turn.Outcome.pp o)
              (Session.Session_view.last_outcome view)
          in
          let waiting =
            Option.map Session.Session_view.Waiting.to_string
              (Session.Session_view.waiting view)
          in
          let last_text = Session.Session_view.last_text view in
          let session_id = Session.Summary.id summary in
          let pending = pending_decision (Document.session d) in
          let metrics = Session.Session_view.metrics view in
          let usage = metrics.Session.Metrics.usage in
          let input_tokens = Mentat_llm.Usage.input_total usage in
          let output_tokens = Mentat_llm.Usage.output_total usage in
          let responses = metrics.Session.Metrics.responses in
          let tool_calls = metrics.Session.Metrics.tool_calls in
          if json then
            Output.stdout_printf "%s\n"
              (Output.Json.to_string
                 (Output.Json.envelope ~type_:"session"
                    [
                      ("id", Output.Json.string id);
                      ("phase", Output.Json.string phase);
                      ("lifecycle", Output.Json.string lifecycle);
                      ("title", Output.Json.string_or_null title);
                      ("cwd", Output.Json.string cwd_s);
                      ("turns", Output.Json.int turns);
                      ("model", Output.Json.string_or_null model);
                      ("workflow_mode", Output.Json.string_or_null mode);
                      ("last_outcome", Output.Json.string_or_null outcome);
                      ("waiting", Output.Json.string_or_null waiting);
                      ( "pending_decision",
                        match pending with
                        | Some requested ->
                            decision_json ~session:session_id requested
                        | None -> Output.Json.null );
                      ("last_text", Output.Json.string_or_null last_text);
                      ( "context",
                        Output.Json.obj
                          [
                            ("input_tokens", Output.Json.int input_tokens);
                            ("output_tokens", Output.Json.int output_tokens);
                            ("responses", Output.Json.int responses);
                            ("tool_calls", Output.Json.int tool_calls);
                          ] );
                    ]))
          else (
            Output.stdout_printf "id=%s\n" id;
            Output.stdout_printf "phase=%s\n" phase;
            Output.stdout_printf "lifecycle=%s\n" lifecycle;
            (match title with
            | Some title -> Output.stdout_printf "title=%s\n" title
            | None -> ());
            Output.stdout_printf "cwd=%s\n" cwd_s;
            Output.stdout_printf "turns=%d\n" turns;
            Option.iter (Output.stdout_printf "model=%s\n") model;
            Option.iter (Output.stdout_printf "mode=%s\n") mode;
            Option.iter (Output.stdout_printf "outcome=%s\n") outcome;
            Option.iter (Output.stdout_printf "waiting=%s\n") waiting;
            Option.iter
              (fun text -> Output.stdout_printf "last=%s\n" (first_line text))
              last_text;
            Output.stdout_printf
              "context=in:%d out:%d responses:%d tool_calls:%d\n" input_tokens
              output_tokens responses tool_calls;
            match pending with
            | None -> ()
            | Some requested ->
                Output.stdout_printf "pending_decision=%s\n"
                  (decision_summary requested);
                Output.stdout_printf "reply:\n";
                List.iter
                  (Output.stdout_printf "  %s\n")
                  (decision_reply_commands ~session:session_id requested));
          Exit_status.Success)

let show_cmd =
  let doc = "Show one session." in
  Cmd.v
    (Cmd.info "show" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const show $ Cli_common.json $ Cli_common.session_arg $ Cli_common.last
         $ Cli_common.cwd))

(* fenced mutations — the offline-store twin. *)

(* One fenced-commit implementation ({!Session_meta}) serves both the online
   Lifecycle cone and this offline twin, so their behaviour cannot drift; a store
   or session-library error reaches the user through the protocol ladder, never a
   flattened string. *)
let target_action ~report ~make_transform session_opt last cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Session_locate.resolve t ~session:session_opt ~last with
      | Error error -> Session_locate.status error
      | Ok d -> (
          let id = Document.id d in
          match
            Session_meta.commit_transform ~store:(Composition.store t)
              ~sw:(Composition.sw t) ~owner:(Composition.owner t)
              ~now:(Composition.now_time t) id ~transform:(make_transform id)
          with
          | Ok () ->
              report id ();
              Exit_status.Success
          | Error e -> Exit_status.of_protocol_error e))

let session_transform id f s =
  Result.map_error (Session_meta.session_error_to_protocol id) (f s)

let report_id id () = Output.stdout_printf "%s\n" (Id.to_string id)

let rename title session_opt last cwd =
  match Argv.title title with
  | Error status -> status
  | Ok title ->
      target_action ~report:report_id
        ~make_transform:(fun _id s -> Ok (Session.set_title (Some title) s))
        session_opt last cwd

let title_req =
  Arg.(
    required
    & pos 1 (some string) None
    & info [] ~docv:"TITLE" ~doc:"The new title.")

let rename_cmd =
  let doc = "Rename a session." in
  Cmd.v
    (Cmd.info "rename" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const rename $ title_req $ Cli_common.session_arg $ Cli_common.last
         $ Cli_common.cwd))

let archive session_opt last cwd =
  target_action ~report:report_id
    ~make_transform:(fun id -> session_transform id Session.archive)
    session_opt last cwd

let archive_cmd =
  let doc = "Archive a session." in
  Cmd.v
    (Cmd.info "archive" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const archive $ Cli_common.session_arg $ Cli_common.last
         $ Cli_common.cwd))

let restore session_opt last cwd =
  target_action ~report:report_id
    ~make_transform:(fun id -> session_transform id Session.restore)
    session_opt last cwd

let restore_cmd =
  let doc = "Restore an archived session." in
  Cmd.v
    (Cmd.info "restore" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const restore $ Cli_common.session_arg $ Cli_common.last
         $ Cli_common.cwd))

let delete yes session_opt last cwd =
  if not yes then
    Composition.with_base ~cwd ~overrides:[] (fun _ ->
        Exit_status.usage "refusing to delete without --yes")
  else
    target_action ~report:report_id
      ~make_transform:(fun id -> session_transform id Session.delete)
      session_opt last cwd

let yes_flag = Arg.(value & flag & info [ "yes" ] ~doc:"Confirm the deletion.")

let delete_cmd =
  let doc = "Delete a session (recoverable tombstone)." in
  Cmd.v
    (Cmd.info "delete" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const delete $ yes_flag $ Cli_common.session_arg $ Cli_common.last
         $ Cli_common.cwd))

(* purge. — permanent reclamation of the disk a deleted session still holds.
   [delete] only records a recoverable tombstone; the document, its event log,
   and its blobs stay on disk until [purge] physically removes them. Purge is
   the named consumer of the store's one blob-reclamation point
   ({!Store.Session.remove}); a session a driver is running is refused
   ([Locked]) rather than unlinked under a live fence, and reported, not
   reclaimed. *)

let purge yes cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Store.Session.scan (Composition.store t) with
      | Error e -> Exit_status.runtime (Store.Session.Error.message e)
      | Ok (all_docs, corrupt) -> (
          List.iter report_corrupt corrupt;
          let tombstoned =
            List.filter
              (fun d ->
                Session.Metadata.is_deleted
                  (Session.metadata (Document.session d)))
              all_docs
          in
          match tombstoned with
          | [] when corrupt = [] ->
              Output.stdout_printf "no deleted sessions to purge\n";
              Exit_status.Success
          | [] ->
              Exit_status.runtime
                (Printf.sprintf
                   "%d corrupt session document(s) prevent a complete purge"
                   (List.length corrupt))
          | _ when not yes ->
              Exit_status.usage
                (Printf.sprintf
                   "refusing to purge %d deleted session(s) without --yes"
                   (List.length tombstoned))
          | _ ->
              let removed, skipped =
                List.fold_left
                  (fun (removed, skipped) d ->
                    match Store.Session.remove (Composition.store t) d with
                    | Ok () -> (removed + 1, skipped)
                    | Error err -> (removed, (d, err) :: skipped))
                  (0, []) tombstoned
              in
              List.iter
                (fun (d, err) ->
                  Output.stderr_printf "mentat: could not purge %s: %s\n"
                    (doc_id d)
                    (Store.Session.Error.message err))
                (List.rev skipped);
              Output.stdout_printf "purged %d session(s)\n" removed;
              if skipped = [] && corrupt = [] then Exit_status.Success
              else
                Exit_status.runtime
                  (Printf.sprintf
                     "purge incomplete: %d removal failure(s), %d corrupt \
                      session document(s)"
                     (List.length skipped) (List.length corrupt))))

let purge_cmd =
  let doc = "Permanently reclaim the disk held by deleted sessions." in
  Cmd.v
    (Cmd.info "purge" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term Term.(const purge $ yes_flag $ Cli_common.cwd))

(* fork. — non-destructive; creates a new session from a copied prefix. *)

let fork into_opt title session_opt last cwd =
  (let* into_opt = validate_id_opt into_opt in
   let* title = Argv.title_opt title in
   Ok
     (Composition.with_base ~cwd ~overrides:[] (fun t ->
          match Session_locate.resolve t ~session:session_opt ~last with
          | Error error -> Session_locate.status error
          | Ok d -> (
              let into =
                match into_opt with Some id -> id | None -> fresh_id ()
              in
              match
                Session.fork ~id:into ?title ~cwd:(Composition.root t)
                  ~created_at:(Composition.now_time t) (Document.session d)
              with
              | Error e ->
                  Exit_status.of_protocol_error
                    (Session_meta.session_error_to_protocol into e)
              | Ok forked -> (
                  let store = Composition.store t in
                  (* Copy the parent's mutation ledger and blobs into the child
                     alongside its document, so the fork's diff and revert see the
                     same edits its inherited turns authored. A fork retains every
                     turn, so the whole ledger crosses. *)
                  match Mutation.read store d with
                  | Error e ->
                      Exit_status.of_diagnostic
                        (Mutation.Error.diagnostic ~session:(Document.id d) e)
                  | Ok state -> (
                      let keep turn =
                        Option.is_some
                          (Session.State.turn turn (Session.state forked))
                      in
                      let events = State.prefix_for_turns state ~keep in
                      match
                        Store.fork store ~from:(Document.id d) ~events forked
                      with
                      | Ok _ ->
                          Output.stdout_printf "%s\n" (Id.to_string into);
                          Exit_status.Success
                      | Error e ->
                          Exit_status.of_protocol_error
                            (Session_meta.session_store_error_to_protocol into e)
                      ))))))
  |> Exit_status.of_result

let fork_cmd =
  let doc = "Fork a session into a new one." in
  Cmd.v
    (Cmd.info "fork" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const fork $ id_opt $ title_opt $ Cli_common.session_arg
         $ Cli_common.last $ Cli_common.cwd))

(* rewind. — client-routed: a new-journal-minting op the engine authors, cut at
   a turn boundary. The [into] child id is client-minted; an explicit [--id]
   validates at the boundary, else a fresh id is minted. *)

let rewind json into_opt to_turn before after session_opt last cwd =
  (let* into_opt = validate_id_opt into_opt in
   Ok
     (Composition.with_base ~cwd ~overrides:[] (fun t ->
          match to_turn with
          | None -> Exit_status.usage "rewind requires --to-turn TURN"
          | Some turn_raw when String.length turn_raw = 0 ->
              Exit_status.usage "--to-turn must not be empty"
          | Some _ when before && after ->
              Exit_status.usage "choose either --before or --after, not both"
          | Some turn_raw -> (
              match Composition.client t with
              | Error status -> status
              | Ok client -> (
                  match Session_locate.resolve t ~session:session_opt ~last with
                  | Error error -> Session_locate.status error
                  | Ok d -> (
                      let session = Document.id d in
                      let turn = Turn.Id.of_string turn_raw in
                      let anchor =
                        if after then Anchor.after_turn turn
                        else Anchor.before_turn turn
                      in
                      let into =
                        match into_opt with
                        | Some id -> id
                        | None -> fresh_id ()
                      in
                      match Client.rewind client ~session ~into ~anchor with
                      | Error e -> Exit_status.of_protocol_error e
                      | Ok () ->
                          if json then
                            Output.stdout_printf "%s\n"
                              (Output.Json.to_string
                                 (Output.Json.envelope ~type_:"session.rewind"
                                    [
                                      ( "session",
                                        Output.Json.string (Id.to_string into)
                                      );
                                    ]))
                          else Output.stdout_printf "%s\n" (Id.to_string into);
                          Exit_status.Success))))))
  |> Exit_status.of_result

let to_turn_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "to-turn" ] ~docv:"TURN" ~doc:"Cut at this turn boundary.")

let before_flag =
  Arg.(
    value & flag
    & info [ "before" ]
        ~doc:"Cut before the turn (default): drop it and every later event.")

let after_flag =
  Arg.(
    value & flag
    & info [ "after" ]
        ~doc:"Cut after the turn: keep it, drop every later event.")

let rewind_cmd =
  let doc = "Rewind a session at a turn boundary into a new one." in
  Cmd.v
    (Cmd.info "rewind" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const rewind $ Cli_common.json $ id_opt $ to_turn_opt $ before_flag
         $ after_flag $ Cli_common.session_arg $ Cli_common.last
         $ Cli_common.cwd))

(* diff & revert — the mutation-ledger scoping shared by both. *)

let hunk_json hunk =
  match Jsont.Json.encode Diff.Hunk.jsont hunk with
  | Ok j -> j
  | Error _ -> Output.Json.null

let display_path p = Mentat_workspace.Path.display p

(* A [--path] scope resolves against the recorded net paths rather than a
   constructed path value, so the selection names the exact ledger paths and an
   unrecorded path scopes to nothing. *)
let paths_selection ~path state =
  match
    List.filter
      (fun (e : Net.entry) -> String.equal (display_path e.Net.path) path)
      (State.net state Revert.Selection.all)
  with
  | [] -> None
  | entries ->
      Some
        (Revert.Selection.paths
           (List.map (fun (e : Net.entry) -> e.Net.path) entries))

let sources_json (e : Net.entry) =
  Output.Json.list
    (List.map
       (fun id -> Output.Json.string (Change.Id.to_string id))
       e.Net.sources)

let revertability_json answer =
  match Jsont.Json.encode Revertability.jsont answer with
  | Ok j -> j
  | Error _ -> Output.Json.null

(* diff. — the offline-store twin over the mutation ledger,
   collapsed to net per-path changes. It nets the selection's exact change rows
   through [State.net] and renders each path's first-before to last-after
   transition through [Textdiff] over [Store.Mutation.blob] bytes. A
   discontinuous net entry (an unrecorded writer intervened) is marked, and a
   selection whose ledger evidence cannot prove a clean revert carries the
   revert-safety note — the realized attribution the ledger owns. No engine
   assembly: a read-only diff must not pay for it. *)

(* The single-letter operation of a netted diff entry. *)
let diff_op = function `Added -> "A" | `Deleted -> "D" | `Modified -> "M"

let diff_scope_usage ~latest ~turn ~path =
  match (latest, turn, path) with
  | false, None, None
  | true, None, None
  | false, Some _, None
  | false, None, Some _ -> (
      match (turn, path) with
      | Some "", _ -> Error (Exit_status.usage "--turn must not be empty")
      | _, Some "" -> Error (Exit_status.usage "--path must not be empty")
      | _ -> Ok ())
  | _ ->
      Error (Exit_status.usage "use at most one of --latest, --turn, or --path")

let diff_selection ~latest ~turn ~path state =
  match (latest, turn, path) with
  | true, _, _ ->
      Option.map
        (fun t -> Revert.Selection.turns [ t ])
        (Session_meta.latest_edit_turn state)
  | _, Some turn, _ -> Some (Revert.Selection.turns [ Turn.Id.of_string turn ])
  | _, _, Some path -> paths_selection ~path state
  | _ -> Some Revert.Selection.all

let diff json latest turn path session_opt last cwd =
  match diff_scope_usage ~latest ~turn ~path with
  | Error status -> status
  | Ok () ->
      Composition.with_base ~cwd ~overrides:[] (fun t ->
          match Session_locate.resolve t ~session:session_opt ~last with
          | Error error -> Session_locate.status error
          | Ok d -> (
              let session = Document.id d in
              let store = Composition.store t in
              match Mutation.read store d with
              | Error e ->
                  Exit_status.of_diagnostic
                    (Mutation.Error.diagnostic ~session e)
              | Ok state -> (
                  match diff_selection ~latest ~turn ~path state with
                  | None ->
                      if json then
                        Output.stdout_printf "%s\n"
                          (Output.Json.to_string
                             (Output.Json.envelope ~type_:"session.diff"
                                [
                                  ("files", Output.Json.int 0);
                                  ("additions", Output.Json.int 0);
                                  ("deletions", Output.Json.int 0);
                                  ("changes", Output.Json.int 0);
                                  ("diff", Output.Json.list []);
                                ]))
                      else Output.stderr_printf "changed 0 file(s) (+0 -0)\n";
                      Exit_status.Success
                  | Some selection ->
                      (* The mutation-ledger diff mechanics live in
                         {!Mentat_mutation.Diff}; this command supplies the blob
                         reader and renders the netted entries. *)
                      let resolve reference =
                        match Mutation.blob store ~session reference with
                        | Ok (Some bytes) -> Some bytes
                        | Ok None | Error _ -> None
                      in
                      let computed =
                        Mentat_mutation.Diff.compute ~state ~selection ~resolve
                          ()
                      in
                      let entries = computed.Mentat_mutation.Diff.entries in
                      let additions = computed.Mentat_mutation.Diff.additions in
                      let deletions = computed.Mentat_mutation.Diff.deletions in
                      let answer =
                        computed.Mentat_mutation.Diff.revertability
                      in
                      let files = List.length entries in
                      if json then
                        Output.stdout_printf "%s\n"
                          (Output.Json.to_string
                             (Output.Json.envelope ~type_:"session.diff"
                                ([
                                   ("files", Output.Json.int files);
                                   ("additions", Output.Json.int additions);
                                   ("deletions", Output.Json.int deletions);
                                   ("changes", Output.Json.int files);
                                   ( "diff",
                                     Output.Json.list
                                       (List.map
                                          (fun {
                                                 Mentat_mutation.Diff.Entry.path;
                                                 operation;
                                                 contiguous;
                                                 hunks;
                                                 _;
                                               } ->
                                            Output.Json.obj
                                              [
                                                ( "path",
                                                  Output.Json.string
                                                    (display_path path) );
                                                ( "operation",
                                                  Output.Json.string
                                                    (diff_op operation) );
                                                ( "contiguous",
                                                  Output.Json.bool contiguous );
                                                ( "hunks",
                                                  Output.Json.list
                                                    (match hunks with
                                                    | Some hs ->
                                                        List.map hunk_json hs
                                                    | None -> []) );
                                              ])
                                          entries) );
                                 ]
                                @
                                if
                                  Revertability.equal answer
                                    Revertability.Available
                                then []
                                else
                                  [
                                    ("revertability", revertability_json answer);
                                  ])))
                      else (
                        List.iter
                          (fun {
                                 Mentat_mutation.Diff.Entry.path;
                                 operation;
                                 contiguous;
                                 hunks;
                                 _;
                               } ->
                            Output.stdout_printf "%s %s%s\n" (diff_op operation)
                              (display_path path)
                              (if contiguous then "" else " (discontinuous)");
                            Output.stdout_printf "--- %s\n" (display_path path);
                            match hunks with
                            | Some hs ->
                                List.iter
                                  (fun h ->
                                    Output.stdout_printf "%s"
                                      (Diff.Hunk.render h))
                                  hs
                            | None ->
                                Output.stdout_printf
                                  "  (diff unavailable: blob missing or bound \
                                   exceeded)\n")
                          entries;
                        if
                          not
                            (Revertability.equal answer Revertability.Available)
                        then
                          Output.stderr_printf "note: %s\n"
                            (Revertability.message answer);
                        Output.stderr_printf "changed %d file(s) (+%d -%d)\n"
                          files additions deletions);
                      Exit_status.Success)))

let latest_flag =
  Arg.(
    value & flag
    & info [ "latest" ]
        ~doc:"Scope to the most recent turn that recorded edits.")

let turn_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "turn" ] ~docv:"TURN" ~doc:"Scope to this turn's edits.")

let path_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "path" ] ~docv:"PATH"
        ~doc:"Scope to this file (workspace-relative display path).")

let diff_cmd =
  let doc =
    "Show Mentat-authored workspace changes from the mutation ledger."
  in
  Cmd.v
    (Cmd.info "diff" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const diff $ Cli_common.json $ latest_flag $ turn_opt $ path_opt
         $ Cli_common.session_arg $ Cli_common.last $ Cli_common.cwd))

(* revert. — the offline-store twin over the revert lifecycle.
   Preview by default
   renders the netted plan and the ledger's revert-safety read, touching no file.
   [--apply] resolves the workspace-write capability, and under one run fence:
   captures a [Before_revert] safety checkpoint (so the revert is itself
   undoable), freezes the prepared plan before any IO ([Revert_started]), applies
   the all-or-nothing [Mentat_edit] — which re-observes each target under the
   write lock, so a target changed since planning fails stale — and records the
   per-path settlement ([Revert_settled]). A stale preflight changes no file. *)

let revert_scope_usage ~latest ~change ~path =
  match (latest, change, path) with
  | false, None, None
  | true, None, None
  | false, Some _, None
  | false, None, Some _ -> (
      match (change, path) with
      | Some "", _ -> Error (Exit_status.usage "--change must not be empty")
      | _, Some "" -> Error (Exit_status.usage "--path must not be empty")
      | _ -> Ok ())
  | _ ->
      Error
        (Exit_status.usage "use at most one of --latest, --change, or --path")

let revert_selection ~latest ~change ~path state =
  match (latest, change, path) with
  | true, _, _ ->
      Option.map
        (fun t -> Revert.Selection.turns [ t ])
        (Session_meta.latest_edit_turn state)
  | _, Some change, _ ->
      Some (Revert.Selection.changes [ Change.Id.of_string change ])
  | _, _, Some path -> paths_selection ~path state
  | _ -> Some Revert.Selection.all

(* The undo transition a revert of one net entry performs: restoring the
   net-before image reverses the recorded direction. *)
let revert_op (e : Net.entry) =
  match (e.Net.before, e.Net.after) with
  | Image.Missing, _ -> "D"
  | _, Image.Missing -> "A"
  | _ -> "M"

(* The copy-pasteable [--apply] invocation for the previewed scope; flags precede
   the id so a dash-prefixed id is not read as an option. *)
let revert_apply_hint ~latest ~change ~path session =
  let scope =
    if latest then "--latest "
    else
      match (change, path) with
      | Some change, _ -> Printf.sprintf "--change %s " change
      | _, Some path -> Printf.sprintf "--path %s " path
      | None, None -> ""
  in
  Printf.sprintf "mentat session revert %s--apply %s" scope
    (Id.to_string session)

let outcome_string = function
  | Revert.Settled.Confirmed _ -> "confirmed"
  | Revert.Settled.Ambiguous -> "ambiguous"
  | Revert.Settled.Not_attempted -> "not_attempted"

let render_revert_settled ~json ~session settled =
  let outcomes = settled.Revert.Settled.outcomes in
  let confirmed =
    List.length
      (List.filter
         (fun (_, o) ->
           match o with Revert.Settled.Confirmed _ -> true | _ -> false)
         outcomes)
  in
  let total = List.length outcomes in
  if json then
    Output.stdout_printf "%s\n"
      (Output.Json.to_string
         (Output.Json.envelope ~type_:"session.revert"
            [
              ("session", Output.Json.string (Id.to_string session));
              ( "revert_id",
                Output.Json.string
                  (Revert.Id.to_string settled.Revert.Settled.revert) );
              ("reverted", Output.Json.int confirmed);
              ( "outcomes",
                Output.Json.list
                  (List.map
                     (fun (path, o) ->
                       Output.Json.obj
                         [
                           ("path", Output.Json.string (display_path path));
                           ("outcome", Output.Json.string (outcome_string o));
                         ])
                     outcomes) );
            ]))
  else (
    List.iter
      (fun (path, o) ->
        match o with
        | Revert.Settled.Confirmed _ -> ()
        | Revert.Settled.Ambiguous ->
            Output.stderr_printf "uncertain %s\n" (display_path path)
        | Revert.Settled.Not_attempted ->
            Output.stderr_printf "not attempted %s\n" (display_path path))
      outcomes;
    Output.stdout_printf "reverted %d file(s)\n" confirmed);
  if confirmed = total then Exit_status.Success
  else
    Exit_status.runtime
      (Printf.sprintf
         "revert incomplete: %d of %d file(s) confirmed; the settlement is \
          recorded"
         confirmed total)

(* The offline revert-apply lifecycle lives in {!Mentat_store.Mutation}; this
   command resolves the workspace-write capability, wires the three workspace
   effects as ports, holds the run fence, and renders the outcome. *)
let revert_apply t ~json ~document ~latest ~change ~path ~force =
  let session = Document.id document in
  let store = Composition.store t in
  match Mutation.read store document with
  | Error e -> Exit_status.of_diagnostic (Mutation.Error.diagnostic ~session e)
  | Ok state -> (
      let selection = revert_selection ~latest ~change ~path state in
      match
        Composition.resolve_workspace t
          ~mode:(Composition.configured_sandbox_mode t)
          ~network:Mentat_sandbox.Policy.Network.Restricted
      with
      | Error status -> status
      | Ok capability -> (
          let observe = Workspace_adapter.observe capability in
          let ports =
            Workspace_adapter.make
              ~store:(Composition.snapshot_store t)
              ?self_prefix:(Composition.snapshot_self_prefix t)
              capability
          in
          (* The offline twin over the shared revert lifecycle: it
             resolves the selection from its command flags — including the
             whole-session and string-path scopes the wire [Scope.t] does not
             carry — then runs the same {!Session_meta.revert} the online cone's
             store adapter runs, under a fence it acquires itself. *)
          let run fence override =
            Session_meta.revert
              ~merge:(Composition.configured_revert_merge t)
              ~override ~store ~fence ~document ~selection ~observe
              ~checkpoint:ports.Ports.checkpoint
              ~apply:(Mentat_workspace_io.Edit.apply capability)
              ~new_id:Session_meta.fresh_revert_id
          in
          let needs_override problems =
            List.filter_map
              (function
                | Revert.Problem.Needs_override { path } -> Some path
                | _ -> None)
              problems
          in
          (* Offline consent surface: the structured refusal lets
             this twin read the non-contiguous paths and, under --force, re-run
             the same fence with a path-specific override built from the presented
             refusal — never a blanket accept. *)
          let result =
            Session_meta.with_fence ~store ~sw:(Composition.sw t)
              ~owner:(Composition.owner t) session (fun fence ->
                Result.map_error
                  (fun e ->
                    Mentat_protocol.Error.Unavailable
                      (Mutation.Error.diagnostic ~session e))
                  (match run fence None with
                  | Ok (Mutation.Refused problems) as refused -> (
                      match (force, needs_override problems) with
                      | true, (_ :: _ as paths) ->
                          run fence
                            (Some (Revert.Override.accept_unrecorded_loss paths))
                      | _ -> refused)
                  | other -> other))
          in
          match result with
          | Error e -> Exit_status.of_protocol_error e
          | Ok (Mutation.Applied settled) ->
              render_revert_settled ~json ~session settled
          | Ok Mutation.Nothing_to_revert ->
              Output.stdout_printf "nothing to revert\n";
              Exit_status.Success
          | Ok (Mutation.Refused problems) ->
              List.iter
                (fun problem ->
                  Output.stderr_printf "%s\n" (Revert.Problem.message problem))
                problems;
              if (not force) && needs_override problems <> [] then
                Output.stderr_printf
                  "re-run with --force to override and discard the unrecorded \
                   edits\n";
              Exit_status.runtime "revert refused; no files were changed"))

let revert_preview t ~json ~document ~latest ~change ~path =
  let session = Document.id document in
  let store = Composition.store t in
  match Mutation.read store document with
  | Error e -> Exit_status.of_diagnostic (Mutation.Error.diagnostic ~session e)
  | Ok state -> (
      let empty_selection () =
        if json then
          Output.stdout_printf "%s\n"
            (Output.Json.to_string
               (Output.Json.envelope ~type_:"session.revert"
                  [
                    ("session", Output.Json.string (Id.to_string session));
                    ("applied", Output.Json.bool false);
                    ("ready", Output.Json.bool false);
                    ("changes", Output.Json.list []);
                  ]))
        else Output.stdout_printf "nothing to revert\n";
        Exit_status.Success
      in
      match revert_selection ~latest ~change ~path state with
      | None -> empty_selection ()
      | Some selection ->
          let net = State.net state selection in
          if net = [] then empty_selection ()
          else
            let answer = State.revertability state selection in
            (* Readiness is the merge feasibility, not the byte-free
               revertability: a superseded selection that merges cleanly applies,
               so route through {!Mentat_mutation.Diff}, reading
               the current files from disk exactly as apply does. If the
               workspace cannot be opened, the merge falls back to the recorded
               head — an advisory answer. *)
            let resolve reference =
              match Mutation.blob store ~session reference with
              | Ok (Some bytes) -> Some bytes
              | Ok None | Error _ -> None
            in
            let current =
              match
                Composition.resolve_workspace t
                  ~mode:(Composition.configured_sandbox_mode t)
                  ~network:Mentat_sandbox.Policy.Network.Restricted
              with
              | Ok capability -> Some (Workspace_adapter.observe_opt capability)
              | Error _ -> None
            in
            let ready =
              (* Preview matches a no-override apply. Feasibility answers only the
                 merge (it and Revertability are orthogonal, neither
                 subsumes), so a non-contiguous entry — which apply refuses with
                 Needs_override, the preview carrying no override — must gate
                 readiness too. A clean merge is likewise ready only while the
                 gate is on; with it off, apply refuses the superseded selection. *)
              List.for_all (fun (e : Net.entry) -> e.Net.contiguous) net
              &&
              match
                Mentat_mutation.Diff.feasibility
                  (Mentat_mutation.Diff.compute ~state ~selection ?current
                     ~resolve ())
              with
              | Mentat_mutation.Diff.Feasibility.Trivial -> true
              | Mentat_mutation.Diff.Feasibility.Mergeable _ ->
                  Composition.configured_revert_merge t
              | Mentat_mutation.Diff.Feasibility.Blocked _ -> false
            in
            if json then
              Output.stdout_printf "%s\n"
                (Output.Json.to_string
                   (Output.Json.envelope ~type_:"session.revert"
                      [
                        ("session", Output.Json.string (Id.to_string session));
                        ("applied", Output.Json.bool false);
                        ("ready", Output.Json.bool ready);
                        ( "changes",
                          Output.Json.list
                            (List.map
                               (fun (e : Net.entry) ->
                                 Output.Json.obj
                                   [
                                     ( "path",
                                       Output.Json.string
                                         (display_path e.Net.path) );
                                     ( "operation",
                                       Output.Json.string (revert_op e) );
                                     ( "contiguous",
                                       Output.Json.bool e.Net.contiguous );
                                     ("sources", sources_json e);
                                   ])
                               net) );
                        ("revertability", revertability_json answer);
                      ]))
            else (
              Output.stdout_printf "would revert %d file(s):\n"
                (List.length net);
              List.iter
                (fun (e : Net.entry) ->
                  Output.stdout_printf "%s %s%s\n" (revert_op e)
                    (display_path e.Net.path)
                    (if e.Net.contiguous then "" else " (discontinuous)"))
                net;
              if not (Revertability.equal answer Revertability.Available) then
                Output.stdout_printf "note: %s\n" (Revertability.message answer);
              if ready then
                Output.stdout_printf "apply: %s\n"
                  (revert_apply_hint ~latest ~change ~path session));
            Exit_status.Success)

let revert json apply latest change path session_opt last force cwd =
  match revert_scope_usage ~latest ~change ~path with
  | Error status -> status
  | Ok () ->
      Composition.with_base ~cwd ~overrides:[] (fun t ->
          match Session_locate.resolve t ~session:session_opt ~last with
          | Error error -> Session_locate.status error
          | Ok d ->
              if apply then
                revert_apply t ~json ~document:d ~latest ~change ~path ~force
              else revert_preview t ~json ~document:d ~latest ~change ~path)

let change_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "change" ] ~docv:"ID" ~doc:"Scope to this recorded change id.")

let apply_flag =
  Arg.(
    value & flag
    & info [ "apply" ]
        ~doc:"Apply the revert (default previews without changing files).")

let force_flag =
  Arg.(
    value & flag
    & info [ "force" ]
        ~doc:
          "Override a non-contiguous revert, discarding unrecorded edits on \
           the affected paths.")

let revert_cmd =
  let doc =
    "Revert Mentat-authored workspace changes from the mutation ledger."
  in
  Cmd.v
    (Cmd.info "revert" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const revert $ Cli_common.json $ apply_flag $ latest_flag $ change_opt
         $ path_opt $ Cli_common.session_arg $ Cli_common.last $ force_flag
         $ Cli_common.cwd))

(* export. — the offline-store twin over the export bundle.
   [--format json] streams the store's complete, integrity-verified bundle under
   a held fence — the value the protocol Export query streams. [--format
   text|markdown] render a numbered transcript over the session's own event
   vocabulary ({!Session.events}, formatted through {!Session.Event.pp}), so the
   human formats carry the whole history the JSON bundle carries. *)

let event_line e = Format.asprintf "%a" Session.Event.pp e

let transcript_string d ~markdown =
  let s = Document.session d in
  let m = Session.metadata s in
  let id = doc_id d in
  let title = Session.Metadata.title m in
  let phase = phase_string s in
  let lifecycle =
    Session.Metadata.Status.to_string (Session.Metadata.status m)
  in
  let cwd = Lpath.Abs.to_string (Session.Metadata.cwd m) in
  let events = Session.events s in
  let b = Buffer.create 4096 in
  let add fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  if markdown then (
    add "# Session %s\n\n" id;
    (match title with
    | Some title -> add "- **title**: %s\n" title
    | None -> ());
    add "- **phase**: %s\n" phase;
    add "- **lifecycle**: %s\n" lifecycle;
    add "- **cwd**: %s\n" cwd;
    add "- **events**: %d\n" (List.length events);
    if events <> [] then (
      add "\n## Transcript\n\n";
      List.iteri (fun i e -> add "%d. `%s`\n" (i + 1) (event_line e)) events))
  else (
    add "session %s\n" id;
    (match title with Some title -> add "title: %s\n" title | None -> ());
    add "phase: %s\n" phase;
    add "lifecycle: %s\n" lifecycle;
    add "cwd: %s\n" cwd;
    add "events: %d\n" (List.length events);
    List.iteri (fun i e -> add "%d. %s\n" (i + 1) (event_line e)) events);
  Buffer.contents b

(* [-o FILE] applies to every format: the whole rendered document is written to
   [path] atomically, or to stdout when absent. *)
let write_output ~output content =
  match output with
  | None ->
      Output.stdout_printf "%s" content;
      Ok ()
  | Some path -> Fs.atomic_write ~perms:0o644 path content

let export format output no_timestamp max_bytes max_tool_bytes max_image_bytes
    quiet session_opt last cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Session_locate.resolve t ~session:session_opt ~last with
      | Error error -> Session_locate.status error
      | Ok d -> (
          let session = Document.id d in
          match String.lowercase_ascii format with
          | "json" when Agent_client.serving t session -> (
              (* The session's agent holds the fence (running, parked, or
                 lingering), so the offline fenced stream cannot run; the
                 online export cone over the agent's socket serves the same
                 integrity-verified bundle — the driven half of the export
                 contract. *)
              match Agent_client.client t with
              | Error status -> status
              | Ok client -> (
                  match Client.export client ~session with
                  | Error e -> Exit_status.of_protocol_error e
                  | Ok bundle -> (
                      match output with
                      | None ->
                          Output.stdout_printf "%s" bundle;
                          Exit_status.Success
                      | Some path -> (
                          match Fs.atomic_write ~perms:0o644 path bundle with
                          | Ok () -> Exit_status.Success
                          | Error msg -> Exit_status.runtime msg))))
          | "json" -> (
              let store = Composition.store t in
              let buf = Buffer.create 4096 in
              let write line =
                match output with
                | None -> Output.stdout_printf "%s" line
                | Some _ -> Buffer.add_string buf line
              in
              let result =
                Session_meta.with_fence ~store ~sw:(Composition.sw t)
                  ~owner:(Composition.owner t) session (fun fence ->
                    match Store.Export.write ~root:store ~fence ~write with
                    | Ok () -> Ok ()
                    | Error (`Session e) ->
                        Error
                          (Session_meta.session_store_error_to_protocol session
                             e)
                    | Error (`Mutation e) ->
                        Error
                          (Mentat_protocol.Error.Unavailable
                             (Mutation.Error.diagnostic ~session e)))
              in
              match result with
              | Error e -> Exit_status.of_protocol_error e
              | Ok () -> (
                  match output with
                  | None -> Exit_status.Success
                  | Some path -> (
                      match
                        Fs.atomic_write ~perms:0o644 path (Buffer.contents buf)
                      with
                      | Ok () -> Exit_status.Success
                      | Error msg -> Exit_status.runtime msg)))
          | "text" -> (
              match
                write_output ~output (transcript_string d ~markdown:false)
              with
              | Ok () -> Exit_status.Success
              | Error msg -> Exit_status.runtime msg)
          | "markdown" -> (
              match
                write_output ~output (transcript_string d ~markdown:true)
              with
              | Ok () -> Exit_status.Success
              | Error msg -> Exit_status.runtime msg)
          | "html" -> (
              let store = Composition.store t in
              match Mutation.read store d with
              | Error e ->
                  Exit_status.of_diagnostic
                    (Mutation.Error.diagnostic ~session e)
              | Ok mutation -> (
                  let s = Document.session d in
                  let facts =
                    Mentat_protocol.Projection.all ~session:s ~mutation
                  in
                  (* [Session.metrics] can raise on an integer-lane overflow;
                     degrade the header rather than bypass the exit ladder. *)
                  let metrics =
                    try Some (Session.metrics s)
                    with Invalid_argument _ -> None
                  in
                  let head =
                    {
                      Session_html.id = Document.id d;
                      title = Session.Metadata.title (Session.metadata s);
                      metadata = Session.metadata s;
                      metrics;
                    }
                  in
                  let timestamp =
                    if no_timestamp then None else Some (Composition.now_time t)
                  in
                  let options =
                    Session_html.Options.make ?timestamp ~max_tool_bytes
                      ~max_image_bytes ~max_total_bytes:max_bytes ~quiet ()
                  in
                  (* The CLI-side media resolve pass: load each attachment blob
                     the transcript's media references so the HTML embeds the
                     real image. A missing or damaged blob keeps the placeholder;
                     the store read is fence-free. *)
                  let resolve_media reference =
                    match
                      Store.Attachment.get store ~session:(Document.id d)
                        reference
                    with
                    | Ok bytes -> bytes
                    | Error _ -> None
                  in
                  match
                    Session_html.render ~options ~resolve_media head facts
                  with
                  | Ok html -> (
                      match write_output ~output html with
                      | Ok () -> Exit_status.Success
                      | Error msg -> Exit_status.runtime msg)
                  | Error (`Too_large n) ->
                      Exit_status.runtime
                        (Printf.sprintf
                           "session too large to render as HTML (%d bytes); \
                            use --format json for a full archive"
                           n)))
          | other ->
              Exit_status.usage
                (Printf.sprintf
                   "unknown export format %s; expected json, text, markdown, \
                    or html"
                   other)))

let format_opt =
  Arg.(
    value & opt string "json"
    & info [ "format" ] ~docv:"FORMAT"
        ~doc:"Output format: json (full bundle), text, markdown, or html.")

let output_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "o"; "output" ] ~docv:"FILE"
        ~doc:"Write output to FILE instead of stdout.")

let no_timestamp_opt =
  Arg.(
    value & flag
    & info [ "no-timestamp" ]
        ~doc:
          "HTML: omit the \"generated at\" stamp for byte-reproducible output.")

let max_bytes_opt =
  Arg.(
    value & opt int 50_000_000
    & info [ "max-bytes" ] ~docv:"N"
        ~doc:"HTML: fail rather than emit a document larger than N bytes.")

let max_tool_bytes_opt =
  Arg.(
    value & opt int 100_000
    & info [ "max-tool-bytes" ] ~docv:"N"
        ~doc:"HTML: cap each rendered tool-output body at N bytes.")

let max_image_bytes_opt =
  Arg.(
    value & opt int 2_000_000
    & info [ "max-image-bytes" ] ~docv:"N"
        ~doc:"HTML: inline images up to N bytes; larger become placeholders.")

let quiet_opt =
  Arg.(
    value & flag & info [ "quiet" ] ~doc:"HTML: drop low-signal queue chatter.")

let export_cmd =
  let doc = "Export a session as a self-describing bundle." in
  Cmd.v
    (Cmd.info "export" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const export $ format_opt $ output_opt $ no_timestamp_opt
         $ max_bytes_opt $ max_tool_bytes_opt $ max_image_bytes_opt $ quiet_opt
         $ Cli_common.session_arg $ Cli_common.last $ Cli_common.cwd))

(* compact. — manual compaction. Client-routed: the engine
   admits a compaction-only turn whose single billable summary call the driver
   installs and settles. Idle-only, guarded offline before any model or
   credential work; an optional [--model] overrides the summarizer through a
   per-invocation config overlay. *)

(* Manual compaction requires an active-lifecycle idle session, rejected before
   any client work. Archived and deleted sessions report their lifecycle; any
   active turn — including a stale mid-flight one — must finish or be interrupted
   first. Automatic compaction during execution is unaffected by this rule. *)
let require_idle_for_compaction session =
  let status = Session.Metadata.status (Session.metadata session) in
  if Session.Metadata.Status.is_deleted status then
    Error
      (Exit_status.of_protocol_error
         (Mentat_protocol.Error.Deleted (Session.id session)))
  else if Session.Metadata.Status.is_archived status then
    Error
      (Exit_status.of_protocol_error
         (Mentat_protocol.Error.Archived (Session.id session)))
  else
    match Session.Summary.phase (Session.Summary.of_session session) with
    | Session.Summary.Phase.Idle -> Ok ()
    | Session.Summary.Phase.Working | Session.Summary.Phase.Waiting ->
        Error
          (Exit_status.usage
             "session has an active turn; manual compaction requires an idle \
              session")

(* [--model] applies as a per-invocation config overlay, the same channel [run]
   uses: the resolved model becomes the summarizer's, without a durable
   session change. *)
let overrides_of_model = function
  | None -> Ok []
  | Some m -> (
      match Argv.model_selector m with
      | Error status -> Error status
      | Ok m -> (
          match
            Mentat_config.set_text Mentat_config.Field.model m
              Mentat_config.empty
          with
          | Ok config -> Ok [ config ]
          | Error e -> Error (Exit_status.usage (Mentat_config.Error.message e))
          ))

let compact json model session_opt last cwd =
  (let* overrides = overrides_of_model model in
   Ok
     (Composition.with_base ~cwd ~overrides (fun t ->
          match Session_locate.resolve t ~session:session_opt ~last with
          | Error error -> Session_locate.status error
          | Ok d -> (
              match require_idle_for_compaction (Document.session d) with
              | Error status -> status
              | Ok () -> (
                  match Composition.client t with
                  | Error status -> status
                  | Ok client -> (
                      let session = Document.id d in
                      match
                        Client.compact client ~session ~turn:(fresh_turn ())
                      with
                      | Error e -> Exit_status.of_protocol_error e
                      | Ok result ->
                          let installed =
                            match result with
                            | Client.Installed -> true
                            | Client.Skipped -> false
                          in
                          if json then
                            Output.stdout_printf "%s\n"
                              (Output.Json.to_string
                                 (Output.Json.envelope ~type_:"session.compact"
                                    [
                                      ( "session",
                                        Output.Json.string
                                          (Id.to_string session) );
                                      ( "result",
                                        Output.Json.string
                                          (if installed then "installed"
                                           else "skipped") );
                                    ]))
                          else
                            Output.stdout_printf "%s %s\n"
                              (if installed then "compacted" else "skipped")
                              (Id.to_string session);
                          Exit_status.Success))))))
  |> Exit_status.of_result

let compact_model_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "model" ] ~docv:"MODEL"
        ~doc:"Override the summarizer model for this compaction.")

let compact_cmd =
  let doc = "Compact a session's context into a summary." in
  Cmd.v
    (Cmd.info "compact" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const compact $ Cli_common.json $ compact_model_opt
         $ Cli_common.session_arg $ Cli_common.last $ Cli_common.cwd))

(* send. *)

(* The owner's mail surface: an owner-origin send (no origin member — absence
   is the one spelling of "the owner sent this") to any session in the store,
   through the broker's one delivery loop. The returned [`Undelivered] IS the
   handling — the printed reason and a nonzero exit; nothing pretends to
   retry. Sending never wakes: a dormant target keeps the mail durably until
   something next runs it. *)
let send json session_arg text cwd =
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Session_locate.resolve t ~session:(Some session_arg) ~last:false with
      | Error error -> Session_locate.status error
      | Ok d ->
          if String.equal (String.trim text) "" then
            Exit_status.usage "message must not be empty"
          else
            let target = Document.id d in
            let id =
              Session.Queue.Id.of_string (Session_meta.fresh_id ~prefix:"q" ())
            in
            let input = [ Mentat_llm.Content.text text ] in
            match
              Mentat_broker.send (Composition.broker t) ~target ~id ~input ()
            with
            | `Undelivered reason -> Exit_status.runtime reason
            | `Delivered ->
                if json then
                  Output.stdout_printf "%s\n"
                    (Output.Json.to_string
                       (Output.Json.envelope ~type_:"session.send"
                          [
                            ("session", Output.Json.string (Id.to_string target));
                            ("result", Output.Json.string "delivered");
                          ]))
                else
                  Output.stdout_printf "delivered %s\n" (Id.to_string target);
                Exit_status.Success)

let send_session_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"SESSION" ~doc:"The target session id or unique prefix.")

let send_text_arg =
  Arg.(
    required
    & pos 1 (some string) None
    & info [] ~docv:"TEXT" ~doc:"The message text.")

let send_cmd =
  let doc = "Mail a message into a session's queue." in
  let man =
    [
      `S "DESCRIPTION";
      `P
        "$(b,mentat session send) lands TEXT durably in the target session's \
         next-turn queue, as the session owner. The session reads it at its \
         next turn boundary; sending never starts a turn — a dormant session \
         keeps the mail until something next runs it.";
      `P
        "Delivery is durable-or-loud: success means the queue entry is in \
         the target's journal; an undelivered send prints the reason and \
         exits nonzero.";
    ]
  in
  Cmd.v
    (Cmd.info "send" ~doc ~man ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const send $ Cli_common.json $ send_session_arg $ send_text_arg
         $ Cli_common.cwd))

let cmd =
  let doc = "Manage sessions." in
  Cmd.group
    (Cmd.info "session" ~doc ~docs ~exits:Cli_common.exits)
    [
      create_cmd;
      list_cmd;
      search_cmd;
      show_cmd;
      rename_cmd;
      archive_cmd;
      restore_cmd;
      delete_cmd;
      purge_cmd;
      fork_cmd;
      rewind_cmd;
      diff_cmd;
      revert_cmd;
      export_cmd;
      compact_cmd;
      send_cmd;
    ]
