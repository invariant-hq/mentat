(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_session
open Mentat_protocol

(* [Error] resolves to [Mentat_session.Error] under the opens above; the
   protocol error type is always written [Mentat_protocol.Error]. *)

(* ── The connection environment ─────────────────────────────────────────── *)

module Env = struct
  type t = {
    client : Mentat_client.t;
    now : unit -> float;
    new_session : unit -> Id.t;
    new_turn : unit -> Turn.Id.t;
  }

  let make ~client ~now ~new_session ~new_turn =
    { client; now; new_session; new_turn }
end

(* ── Responses ──────────────────────────────────────────────────────────── *)

type response =
  | Html of Html.t
  | Fragment of Html.t list
  | Redirect of string
  | Asset of { media_type : string; body : string }
  | Not_found
  | Bad_request of string
  | Failed of Mentat_protocol.Error.t

module Http = struct
  type t = { status : int; headers : (string * string) list; body : string }
end

let html_media = ("content-type", "text/html; charset=utf-8")

let status_of_error (error : Mentat_protocol.Error.t) =
  let open Mentat_protocol.Error in
  match error with
  | Session_not_found _ | Archived _ | Deleted _ -> 404
  | Invalid_position _ | Invalid_title | Invalid_api_key | Unknown_command _
  | File_unresolved _ ->
      400
  | Busy _ | Active_turn_exists _ | Turn_id_reused _ | No_active_turn _
  | Decision_not_pending _ | Already_resolved _ ->
      409
  | Unavailable _ -> 503

let error_message error = Format.asprintf "%a" Mentat_protocol.Error.pp error

let to_http = function
  | Html node ->
      {
        Http.status = 200;
        headers = [ html_media ];
        body = Html.to_string node;
      }
  | Fragment nodes ->
      {
        Http.status = 200;
        headers = [ html_media ];
        body = String.concat "" (List.map Html.to_string nodes);
      }
  | Redirect location ->
      { Http.status = 303; headers = [ ("location", location) ]; body = "" }
  | Asset { media_type; body } ->
      { Http.status = 200; headers = [ ("content-type", media_type) ]; body }
  | Not_found ->
      {
        Http.status = 404;
        headers = [ html_media ];
        body = Html.to_string (Page.error ~status:404 ~message:"Not found.");
      }
  | Bad_request message ->
      {
        Http.status = 400;
        headers = [ html_media ];
        body = Html.to_string (Page.error ~status:400 ~message);
      }
  | Failed error ->
      let status = status_of_error error in
      {
        Http.status;
        headers = [ html_media ];
        body =
          Html.to_string (Page.error ~status ~message:(error_message error));
      }

(* ── Request-parsing helpers ────────────────────────────────────────────── *)

let query_first key query =
  match List.assoc_opt key query with
  | Some (value :: _) -> Some value
  | _ -> None

let query_flag key query = Option.is_some (List.assoc_opt key query)
let form_field key body = List.assoc_opt key body

let parse_id segment =
  if String.length segment = 0 then None else Some (Id.of_string segment)

let session_path session = "/session/" ^ Id.to_string session

let redirect_of_submit env command target =
  match Mentat_client.submit env.Env.client command with
  | Ok () -> Redirect target
  | Error error -> Failed error

(* ── Transcript folding ─────────────────────────────────────────────────── *)

(* The [#session] cold-load body. [Render.cold] owns the window-split tolerance
   now — it renders complete in-window turns plus a truncation marker for a
   leading edge whose [Turn_started] fell above the tail, so a bounded tail no
   longer fails the happy path. An error here is a genuine post-context firewall
   violation (a projector bug), surfaced inline rather than degraded silently. *)
let cold_body ~now ~session view =
  match Render.cold ~now ~session view with
  | Ok (_acc, body) -> body
  | Error _ ->
      Html.El.div
        ~at:[ Html.At.id "session" ]
        [
          Html.El.div
            ~at:[ Html.At.id "transcript" ]
            [
              Html.El.aside
                ~at:[ Html.At.class_ "notice failure" ]
                [ Html.El.txt "This session could not be fully rendered." ];
            ];
          Render.live ~now ~session Render.initial;
        ]

(* ── GET routes ─────────────────────────────────────────────────────────── *)

let listing_of_query query =
  let lifecycles =
    Metadata.Status.Active
    ::
    (if query_flag "archived" query then [ Metadata.Status.Archived ] else [])
  in
  {
    Listing.scope = (if query_flag "all" query then `All else `Cwd);
    lifecycles;
    search = query_first "q" query;
    limit = None;
  }

let get_session_list env query =
  match Mentat_client.sessions env.Env.client (listing_of_query query) with
  | Error error -> Failed error
  | Ok (sessions, diagnostics) ->
      Html (Page.session_list ~sessions ~unreadable:(List.length diagnostics))

let get_session env session =
  let client = env.Env.client in
  match Mentat_client.session client session with
  | Error error -> Failed error
  | Ok detail -> (
      match Mentat_client.tail client session with
      | Error error -> Failed error
      | Ok view ->
          let now = env.Env.now () in
          let title = Summary.display_title (Session_view.summary detail) in
          Html
            (Page.session ~title ~session ~resume:view.Transcript.Tail.head
               ~earlier:view.Transcript.Tail.page.Transcript.Page.before
               ~body:(cold_body ~now ~session view)))

let get_before env session query =
  match query_first "p" query with
  | None -> Bad_request "missing page cursor"
  | Some raw -> (
      match int_of_string_opt raw with
      | None -> Bad_request "malformed page cursor"
      | Some seq -> (
          let before = Some (Position.make ~session ~seq) in
          match Mentat_client.page env.Env.client session ~before with
          | Error error -> Failed error
          | Ok older ->
              let control =
                Page.earlier_control ~session
                  ~before:older.Transcript.Page.before
              in
              (* A genuine post-context firewall violation in committed history
                 is a projector bug, not a window split (which [Render.page]
                 tolerates); keep the paging affordance rather than failing the
                 scroll-up. *)
              let blocks =
                match
                  Render.page ~now:(env.Env.now ()) older.Transcript.Page.facts
                with
                | Ok (_acc, blocks) -> blocks
                | Error _ -> []
              in
              Fragment (control :: blocks)))

let review_file_row file =
  let { Mentat_review.View.File.path; reviewed; reviewed_units; units; _ } =
    file
  in
  Html.El.li
    ~at:[ Html.At.class_ (if reviewed then "file reviewed" else "file") ]
    [
      Html.El.span
        ~at:[ Html.At.class_ "path" ]
        [ Html.El.txt (Lpath.Rel.to_string path) ];
      Html.El.span
        ~at:[ Html.At.class_ "units" ]
        [ Html.El.txt (Printf.sprintf "%d/%d reviewed" reviewed_units units) ];
    ]

let get_review env =
  match
    Mentat_client.review_state env.Env.client ~scope:Mentat_review.Scope.Feature
  with
  | Error error -> Failed error
  | Ok view ->
      let {
        Mentat_review.View.title;
        base;
        tip;
        reviewed_units;
        units;
        open_crs;
        files;
        _;
      } =
        view
      in
      let heading = Option.value title ~default:"Review" in
      Html
        (Page.document ~head_title:("Mentat — " ^ heading)
           ~body:
             [
               Html.El.v
                 ~at:[ Html.At.class_ "top" ]
                 "header"
                 [
                   Html.El.a
                     ~at:[ Html.At.href "/" ]
                     [ Html.El.txt "← Sessions" ];
                   Html.El.h 1 [ Html.El.txt heading ];
                 ];
               Html.El.v
                 ~at:[ Html.At.class_ "review" ]
                 "main"
                 [
                   Html.El.p
                     [
                       Html.El.txt
                         (Printf.sprintf
                            "%s → %s · %d/%d units reviewed · %d open" base tip
                            reviewed_units units open_crs);
                     ];
                   Html.El.ul
                     ~at:[ Html.At.class_ "files" ]
                     (List.map review_file_row files);
                 ];
             ])

let get_static file =
  match Assets.get file with
  | Some (media_type, body) -> Asset { media_type; body }
  | None -> Not_found

(* ── POST routes ────────────────────────────────────────────────────────── *)

let nonempty text = String.trim text <> ""

let post_prompt env session body =
  match form_field "prompt" body with
  | Some text when nonempty text -> (
      let turn = env.Env.new_turn () in
      match
        Command.prompt ~session ~turn ~input:[ Mentat_llm.Content.text text ] ()
      with
      | Error invalid -> Bad_request (Command.Invalid.message invalid)
      | Ok command -> redirect_of_submit env command (session_path session))
  | _ -> Bad_request "empty prompt"

let post_queue env session body =
  match form_field "prompt" body with
  | Some text when nonempty text -> (
      match
        Command.queue_next ~session ~input:[ Mentat_llm.Content.text text ]
      with
      | Error invalid -> Bad_request (Command.Invalid.message invalid)
      | Ok command -> redirect_of_submit env command (session_path session))
  | _ -> Bad_request "empty queue entry"

let post_queue_clear env session =
  redirect_of_submit env (Command.clear_queued ~session) (session_path session)

let post_interrupt env session body =
  let reason = form_field "reason" body in
  match Command.interrupt ~session ?reason () with
  | Error invalid -> Bad_request (Command.Invalid.message invalid)
  | Ok command -> redirect_of_submit env command (session_path session)

let post_compact env session =
  let turn = env.Env.new_turn () in
  match Mentat_client.compact env.Env.client ~session ~turn with
  | Ok _ -> Redirect (session_path session)
  | Error error -> Failed error

(* Build the kind-erased answer from the form fields, dispatching on the pending
   request's kind. The button values match [Render]'s [decision_form]. *)
let answer_of_form request body =
  let field key = form_field key body in
  match (request, field "answer") with
  | Decision.Request.Permission _, Some "allow-once" ->
      Some
        (Decision.Answer.Permission
           { answer = Mentat_permission.Answer.once; message = None })
  | Decision.Request.Permission _, Some "allow-always" ->
      Some
        (Decision.Answer.Permission
           {
             answer = Mentat_permission.Answer.exact_for_conversation;
             message = None;
           })
  | Decision.Request.Permission _, Some "deny" ->
      Some
        (Decision.Answer.Permission
           { answer = Mentat_permission.Answer.deny; message = None })
  | Decision.Request.Question _, Some "free" ->
      let text = Option.value (field "text") ~default:"" in
      Some (Decision.Answer.Question (Question.Answer.free text))
  | Decision.Request.Question _, Some "choice" -> (
      match Option.bind (field "choice") int_of_string_opt with
      | Some index ->
          Some (Decision.Answer.Question (Question.Answer.choice index))
      | None -> None)
  | Decision.Request.Plan plan, Some "approve" ->
      let feedback =
        match field "feedback" with
        | Some f when nonempty f -> Some f
        | _ -> None
      in
      Some
        (Decision.Answer.Plan
           (Plan.Answer.approve ~body:plan ~context:`Current ?feedback ()))
  | Decision.Request.Plan _, Some "revise" -> (
      match field "feedback" with
      | Some f when nonempty f ->
          Some (Decision.Answer.Plan (Plan.Answer.revise f))
      | _ -> None)
  | Decision.Request.Plan _, Some "keep-planning" ->
      Some (Decision.Answer.Plan Plan.Answer.keep_planning)
  | _, _ -> None

let post_decision env session body =
  match Mentat_client.pending_decision env.Env.client session with
  | Error error -> Failed error
  | Ok None -> Bad_request "no pending decision"
  | Ok (Some requested) -> (
      match answer_of_form (Decision.Requested.request requested) body with
      | None -> Bad_request "malformed decision answer"
      | Some answer ->
          let decision = Decision.Requested.id requested in
          redirect_of_submit env
            (Command.answer_decision ~session ~decision ~answer)
            (session_path session))

let post_new_session env =
  let session = env.Env.new_session () in
  match Mentat_client.create env.Env.client ~id:session () with
  | Ok () -> Redirect (session_path session)
  | Error error -> Failed error

let post_rename env session body =
  match form_field "title" body with
  | Some title when nonempty title -> (
      match Mentat_client.rename env.Env.client ~session ~title with
      | Ok () -> Redirect (session_path session)
      | Error error -> Failed error)
  | _ -> Bad_request "empty title"

let post_archive env session =
  match Mentat_client.archive env.Env.client ~session with
  | Ok () -> Redirect "/"
  | Error error -> Failed error

let post_restore env session =
  match Mentat_client.restore env.Env.client ~session with
  | Ok () -> Redirect (session_path session)
  | Error error -> Failed error

let post_delete env session =
  match Mentat_client.delete env.Env.client ~session with
  | Ok () -> Redirect "/"
  | Error error -> Failed error

(* ── Dispatch ───────────────────────────────────────────────────────────── *)

let with_session segment (k : Id.t -> response) : response =
  match parse_id segment with Some session -> k session | None -> Not_found

let get env ~path ~query : response =
  match path with
  | [] -> get_session_list env query
  | [ "static"; file ] -> get_static file
  | [ "review" ] -> get_review env
  | [ "session"; id ] ->
      with_session id (fun session -> get_session env session)
  | [ "session"; id; "before" ] ->
      with_session id (fun session -> get_before env session query)
  | [ "session"; _; "feed" ] ->
      (* The daemon routes the live stream to {!feed}; it never reaches here. *)
      Not_found
  | _ -> Not_found

let post env ~path ~body =
  match path with
  | [ "sessions" ] -> post_new_session env
  | [ "session"; id; action ] ->
      with_session id (fun session ->
          match action with
          | "prompt" -> post_prompt env session body
          | "queue" -> post_queue env session body
          | "interrupt" -> post_interrupt env session body
          | "compact" -> post_compact env session
          | "rename" -> post_rename env session body
          | "archive" -> post_archive env session
          | "restore" -> post_restore env session
          | "delete" -> post_delete env session
          | _ -> Not_found)
  | [ "session"; id; "queue"; "clear" ] ->
      with_session id (fun session -> post_queue_clear env session)
  | [ "session"; id; "decision"; _decision ] ->
      with_session id (fun session -> post_decision env session body)
  | _ -> Not_found

let handle env ~meth ~path ~query ~body =
  match meth with
  | "GET" | "HEAD" -> get env ~path ~query
  | "POST" -> post env ~path ~body
  | _ -> Not_found

(* ── The live event stream ──────────────────────────────────────────────── *)

module Frame = struct
  type t = { id : int option; html : string }
end

type fault =
  | Attach of Mentat_protocol.Error.t
  | Render_fault of Render.Error.t

let html_of blocks = String.concat "" (List.map Html.to_string blocks)

let feed env ~sw ~session ~from ~emit =
  let client = env.Env.client in
  (* Follow from the beginning and gate emission at the caller's [from]: correct
     (no miss, no duplicate) but an O(history) fold per reconnect. The O(window)
     fix is to seed a bounded suffix through [Render.attach] (which tolerates a
     mid-turn leading edge, so a fresh accumulator no longer trips
     [No_active_turn] on the first post-resume fact) and then follow
     [`After from]. That is deferred: it needs a client read for the committed
     window ending exactly at [from], which [Mentat_client.page ~before] (facts
     strictly before a position) does not express — seeding from the current
     tail instead would double-fold the facts a stale [from] reconnect replays.
     Until that read lands, the correct-but-slow fold stays. *)
  match Mentat_client.follow_session ~sw client session ~from:`Beginning with
  | Error error -> Error (Attach error)
  | Ok feed ->
      let threshold =
        match from with
        | `Beginning -> -1
        | `After position -> Position.seq position
      in
      let acc = ref Render.initial in
      let emit_live () =
        emit
          {
            Frame.id = None;
            html =
              Html.to_string (Render.live ~now:(env.Env.now ()) ~session !acc);
          }
      in
      let rec loop () =
        match Mentat_client.Feed.next feed with
        | Error error -> Error (Attach error)
        | Ok Mentat_client.Feed.Closed -> Ok ()
        | Ok (Mentat_client.Feed.Item (Update.Committed { position; fact }))
          -> (
            match Render.fact ~now:(env.Env.now ()) !acc position fact with
            | Error fault -> Error (Render_fault fault)
            | Ok (next, blocks) ->
                acc := next;
                let seq = Position.seq position in
                if seq > threshold then begin
                  emit { Frame.id = Some seq; html = html_of blocks };
                  emit_live ()
                end;
                loop ())
        | Ok (Mentat_client.Feed.Item (Update.Progress pulse)) ->
            acc := Render.progress !acc pulse;
            emit_live ();
            loop ()
      in
      loop ()
