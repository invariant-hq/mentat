(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module App = App
module Client = Mentat_client
module Protocol = Mentat_protocol
module Session = Mentat_session

let log_src = Logs.Src.create "mentat.tui-next.runtime" ~doc:"Next TUI runtime"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Local = struct
  type t = {
    load_prompt_history : unit -> string;
    append_prompt_history : string -> unit;
    enumerate_files :
      (unit -> (Lpath.Rel.t list, Mentat_diagnostic.t) result) option;
    open_url : (Uri.t -> (unit, Mentat_diagnostic.t) result) option;
    run_local_shell :
      (cancelled:(unit -> bool) ->
      command:string ->
      (Mentat_tool.Output.t Mentat_tool.Result.t, Mentat_diagnostic.t) result)
      option;
    edit_in_editor :
      (text:string -> (string, Mentat_diagnostic.t) result) option;
    notify : (title:string -> body:string -> unit) option;
    auto_title : (session:Session.Id.t -> prompt:string -> unit) option;
    attach_image_path : (Lpath.Rel.t -> Mentat_workspace.Path.t) option;
        (* Resolves a workspace-relative image path to the workspace path the
         client attach expects. Its presence advertises image attachment. *)
    clipboard_image : (unit -> (string * string) option) option;
        (* Probes the OS clipboard out-of-band for an image, returning its
           [(media_type, bytes)] or [None] when the clipboard holds no image.
           An executable-side spawn; the pure App never reads the clipboard. *)
    attribute_session : (Session.Id.t option -> unit) option;
        (* Reports the active session whenever it changes, so machine-local
           diagnostics can attribute their lines to it. Not advertised: the
           runtime invokes it itself, and no reducer effect depends on it. *)
  }

  let make ~load_prompt_history ~append_prompt_history ?enumerate_files
      ?open_url ?run_local_shell ?edit_in_editor ?notify ?auto_title
      ?attach_image_path ?clipboard_image ?attribute_session () =
    {
      load_prompt_history;
      append_prompt_history;
      enumerate_files;
      open_url;
      run_local_shell;
      edit_in_editor;
      notify;
      auto_title;
      attach_image_path;
      clipboard_image;
      attribute_session;
    }

  (* Attribution is best-effort and never observed: an absent callback and a
     raising one both leave the runtime's own state unchanged. *)
  let attribute t session =
    match t.attribute_session with
    | None -> ()
    | Some attribute -> attribute session

  let advertised t : App.capabilities =
    {
      App.local_shell = Option.is_some t.run_local_shell;
      file_enumeration = Option.is_some t.enumerate_files;
      browser = Option.is_some t.open_url;
      external_editor = Option.is_some t.edit_in_editor;
      notify_command = Option.is_some t.notify;
      image_attach = Option.is_some t.attach_image_path;
    }
end

type outcome = { last_session : Session.Id.t option }
type error = No_tty

type attachment = {
  attachment_request : App.request;
  session : Session.Id.t;
  mutable feed : Client.Feed.t option;
  mutable last_position : Protocol.Position.t option;
  mutable reconnected : bool;
}

type local_shell_run = { shell_request : App.request; mutable cancelled : bool }

let error_message No_tty = "interactive terminal required to run the TUI"

let goodbye ~palette ~color outcome =
  Goodbye.render ~palette ~color ~session:outcome.last_session

(* After a /theme write to the user layer, report whether a higher config layer
   still wins [tui.theme], so the picker can warn that the write will not take
   effect. [None] when the user write is effective (or the query fails); [Some
   (layer, value)] when [layer] pins a different [value]. *)
let theme_shadow client name =
  match Client.configuration client with
  | Error _ -> None
  | Ok view -> (
      let module View = Mentat_config.Resolved.View in
      match
        List.find_opt
          (fun entry -> String.equal (View.Entry.key entry) "tui.theme")
          (View.entries view)
      with
      | None -> None
      | Some entry -> (
          let value =
            match View.Entry.value entry with
            | View.Value.Shown { text; _ } -> text
            | View.Value.Redacted -> ""
          in
          if String.equal value name then None
          else
            match Mentat_config.Origin.source (View.Entry.origin entry) with
            | Mentat_config.Source.User _ | Mentat_config.Source.Default _ ->
                None
            | ( Mentat_config.Source.Project _
              | Mentat_config.Source.Project_local _
              | Mentat_config.Source.Extra_file _ | Mentat_config.Source.Env _
              | Mentat_config.Source.Override ) as source ->
                Some (Mentat_config.Source.kind_string source, value)))

let term_is_supported () =
  match Sys.getenv_opt "TERM" with
  | Some "dumb" | Some "" | None -> false
  | Some _ -> true

let is_interactive () =
  Unix.isatty Unix.stdin && Unix.isatty Unix.stdout && term_is_supported ()

let protocol_message error =
  Protocol.Error.diagnostic error |> Mentat_diagnostic.to_string

let unavailable message = Protocol.Error.unavailable message
let random_seed = lazy (Random.self_init ())
let draft_session = Session.Id.of_string "tui-draft"

let fresh_string prefix =
  Lazy.force random_seed;
  Printf.sprintf "%s-%013.0f-%04x" prefix
    (Unix.gettimeofday () *. 1000.)
    (Random.int 0x10000)

let fresh_session () = Session.Id.of_string (fresh_string "s")
let fresh_turn () = Session.Turn.Id.of_string (fresh_string "t")

(* Replace C0 controls (0x00–0x1f and DEL) with spaces so a notification string
   cannot inject an escape sequence. UTF-8-safe: multi-byte scalars use bytes
   >= 0x80, which are left untouched. *)
let sanitize_notification s =
  String.map
    (fun c -> if Char.code c < 0x20 || Char.code c = 0x7f then ' ' else c)
    s

let run ~stdenv ~client ~(startup : Startup.t) ~(local : Local.t)
    ~reduced_motion ~show_reasoning ~overlay ~notify_policy ~palette ~theme_name
    ~themes ~theme_auto ~image_max_count ~mouse ?matrix ?probe () =
  if Option.is_none matrix && not (is_interactive ()) then Error No_tty
  else
    Eio.Switch.run ~name:"mentat-tui-next" @@ fun sw ->
    let clock = Eio.Stdenv.clock stdenv in
    let matrix =
      match matrix with
      | Some matrix -> matrix
      | None ->
          (* [`Sgr_button] keeps press, release, drag, and wheel but drops
             all-motion reports, which the TUI does not consume. Mouse capture
             is off entirely when [mouse] is false, restoring native selection
             and scroll. *)
          Matrix_eio.create ~mode:`Alt ~sw ~clock ~stdin:stdenv#stdin
            ~stdout:stdenv#stdout ~target_fps:(Some 30.) ~cursor_visible:true
            ~mouse_enabled:mouse
            ~mouse:(if mouse then Some `Sgr_button else None)
            ~exit_on_ctrl_c:false ~start_idle:true ()
    in
    let capabilities = Local.advertised local in
    let dispatch_ref = ref None in
    let deliver message =
      match !dispatch_ref with Some dispatch -> dispatch message | None -> ()
    in
    let process_perform thunk =
      Eio.Fiber.fork_daemon ~sw (fun () ->
          (try thunk () with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              Log.err (fun log ->
                  log "background effect raised and was dropped: %s@.%s"
                    (Printexc.to_string exn)
                    (Printexc.raw_backtrace_to_string backtrace)));
          `Stop_daemon)
    in
    let perform f =
      Mosaic.Cmd.perform (fun dispatch ->
          dispatch_ref := Some dispatch;
          f dispatch)
    in
    let active_session = ref None in
    let next_session = ref (fresh_session ()) in
    let latest_intent : App.request option ref = ref None in
    let main_attachment : attachment option ref = ref None in
    let local_shell_run : local_shell_run option ref = ref None in
    let pending_shell_cancellation : App.request option ref = ref None in
    let current (candidate : attachment) =
      match !main_attachment with
      | Some (active : attachment) ->
          App.equal_request active.attachment_request
            candidate.attachment_request
      | None -> false
    in
    let desire request = latest_intent := Some request in
    let latest request =
      Option.exists (App.equal_request request) !latest_intent
    in
    let close_feed feed =
      Eio.Cancel.protect (fun () ->
          try Client.Feed.close feed
          with exn ->
            Log.warn (fun log ->
                log "session feed cleanup raised and was contained: %s"
                  (Printexc.to_string exn)))
    in
    let close_attachment_feed attachment_value =
      match attachment_value.feed with
      | None -> ()
      | Some feed ->
          attachment_value.feed <- None;
          close_feed feed
    in
    let retire_attachment () =
      match !main_attachment with
      | None -> ()
      | Some active ->
          main_attachment := None;
          close_attachment_feed active
    in
    let fail_attachment attachment_value message =
      if current attachment_value then begin
        main_attachment := None;
        close_attachment_feed attachment_value;
        deliver
          (App.feed_failed ~session:attachment_value.session
             ~request:attachment_value.attachment_request ~message
             ~login_needed:false)
      end
    in
    let raised component operation exn =
      unavailable
        (Printf.sprintf "%s %s raised: %s" component operation
           (Printexc.to_string exn))
    in
    let follow_session session from =
      match Client.follow_session ~sw client session ~from with
      | result -> result
      | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
      | exception exn -> Error (raised "session feed" "attach" exn)
    in
    let next_feed feed =
      match Client.Feed.next feed with
      | result -> result
      | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
      | exception exn -> Error (raised "session feed" "pull" exn)
    in
    let reconnect attachment_value ~from ~otherwise =
      if attachment_value.reconnected then begin
        fail_attachment attachment_value otherwise;
        `Failed
      end
      else begin
        attachment_value.reconnected <- true;
        close_attachment_feed attachment_value;
        match follow_session attachment_value.session from with
        | Ok feed when current attachment_value ->
            attachment_value.feed <- Some feed;
            `Reconnected
        | Ok feed ->
            close_feed feed;
            `Stale
        | Error error when current attachment_value ->
            fail_attachment attachment_value (protocol_message error);
            `Failed
        | Error _ -> `Stale
      end
    in
    let recovery_origin attachment_value =
      match attachment_value.last_position with
      | Some position -> `After position
      | None -> `Beginning
    in
    let rec pull (attachment_value : attachment) =
      if current attachment_value then
        begin match attachment_value.feed with
        | None -> ()
        | Some feed -> (
            let outcome = next_feed feed in
            if current attachment_value then
              match outcome with
              | Ok
                  (Client.Feed.Item
                     (Protocol.Update.Committed { position; fact })) ->
                  attachment_value.last_position <- Some position;
                  deliver
                    (App.fact ~session:attachment_value.session
                       ~request:attachment_value.attachment_request
                       ~now:(Matrix.now matrix) fact);
                  pull attachment_value
              | Ok (Client.Feed.Item (Protocol.Update.Progress progress)) ->
                  deliver
                    (App.progress ~session:attachment_value.session
                       ~request:attachment_value.attachment_request
                       ~now:(Matrix.now matrix) progress);
                  pull attachment_value
              | Ok Client.Feed.Closed -> (
                  match
                    reconnect attachment_value
                      ~from:(recovery_origin attachment_value)
                      ~otherwise:"the session feed closed unexpectedly"
                  with
                  | `Reconnected -> pull attachment_value
                  | `Failed | `Stale -> ())
              | Error (Protocol.Error.Invalid_position _ as error) -> (
                  match
                    reconnect attachment_value
                      ~from:(recovery_origin attachment_value)
                      ~otherwise:(protocol_message error)
                  with
                  | `Reconnected -> pull attachment_value
                  | `Failed | `Stale -> ())
              | Error error ->
                  fail_attachment attachment_value (protocol_message error))
        end
    in
    let follow ~request session ~from =
      if not (latest request) then `Stale
      else
        match follow_session session from with
        | Error error when latest request ->
            deliver (App.command_failed ~request error);
            `Failed
        | Error _ -> `Stale
        | Ok feed -> (
            let possibly_mutating =
              match Client.possibly_mutating client ~session with
              | value -> Ok value
              | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                  raise cancelled
              | exception exn -> Error (raised "session" "recovery check" exn)
            in
            match possibly_mutating with
            | Error error when latest request ->
                close_feed feed;
                deliver (App.command_failed ~request error);
                `Failed
            | Error _ ->
                close_feed feed;
                `Stale
            | Ok _ when not (latest request) ->
                close_feed feed;
                `Stale
            | Ok possibly_mutating ->
                let attachment_value =
                  {
                    attachment_request = request;
                    session;
                    feed = Some feed;
                    last_position = None;
                    reconnected = false;
                  }
                in
                let previous = !main_attachment in
                main_attachment := Some attachment_value;
                active_session := Some session;
                Local.attribute local (Some session);
                Option.iter close_attachment_feed previous;
                deliver
                  (App.session_followed ~request ~session ~possibly_mutating);
                Eio.Fiber.fork_daemon ~sw (fun () ->
                    Eio.Fiber.yield ();
                    pull attachment_value;
                    `Stop_daemon);
                `Admitted)
    in
    let prompt_input ~media ~prompt =
      (* An image-only submit carries empty prompt text; [Content.text] rejects
         the empty string, so the text block is omitted when there is none. *)
      media
      @
      if String.equal prompt "" then [] else [ Mentat_llm.Content.text prompt ]
    in
    let submit_prompt ~request ~session ~prompt ~media ~mode =
      let input = prompt_input ~media ~prompt in
      match
        Protocol.Command.prompt ~session ~turn:(fresh_turn ()) ~input ~mode ()
      with
      | Error invalid ->
          deliver
            (App.command_failed ~request
               (unavailable (Protocol.Command.Invalid.message invalid)))
      | Ok command -> (
          match Client.submit client command with
          | Ok () -> ()
          | Error error -> deliver (App.command_failed ~request error))
    in
    (* Auto-title must persist before the first session-scoped call: that
       call starts the session's agent, which adopts the session and holds
       its fence for its whole life, and the rename commits through the
       offline twin, which needs a free fence. So it runs inline on the
       admission fiber, right after create, under a best-effort contract so
       a titling failure never disturbs the session. *)
    let auto_title ~session ~prompt =
      match local.Local.auto_title with
      | None -> ()
      | Some generate -> (
          try generate ~session ~prompt with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              Log.warn (fun log ->
                  log "auto-title raised and was contained: %s"
                    (Printexc.to_string exn)))
    in
    let append_prompt_history session draft =
      let session = Option.value session ~default:draft_session in
      let ts = Matrix.now matrix |> Float.floor |> int_of_float in
      match History.Entry.of_draft ~session ~ts draft with
      | None -> ()
      | Some entry -> (
          match local.Local.append_prompt_history (History.encode entry) with
          | () -> ()
          | exception _ -> ())
    in
    let query_sessions request loaded listing =
      let result = Client.sessions client listing in
      (* The stage renders only each diagnostic's head line; the full detail
         (store paths, decoder traces) is recoverable here. *)
      (match result with
      | Ok (_, diagnostics) ->
          List.iter
            (fun diagnostic ->
              Log.warn (fun log ->
                  log "session listing diagnostic: %s"
                    (Mentat_diagnostic.to_string diagnostic)))
            diagnostics
      | Error _ -> ());
      deliver (loaded ~request result)
    in
    let active_cwd_listing : Session.Listing.t =
      Session.Listing.
        {
          scope = `Cwd;
          lifecycles = [ Session.Metadata.Status.Active ];
          search = None;
          limit = None;
        }
    in
    let all_sessions_listing : Session.Listing.t =
      Session.Listing.
        {
          scope = `All;
          lifecycles =
            [
              Session.Metadata.Status.Active;
              Session.Metadata.Status.Archived;
              Session.Metadata.Status.Deleted;
            ];
          search = None;
          limit = None;
        }
    in
    let child_feeds =
      Child_feeds.create ~sw ~client
        ~emit:(fun ~observation ~generation ~child outcome ->
          deliver (App.child_feed ~observation ~generation ~child outcome))
    in
    let logins : (Auth_panel.attempt, Client.Login.t) Hashtbl.t =
      Hashtbl.create 4
    in
    let cancel_login login =
      Eio.Cancel.protect (fun () ->
          try Client.Login.cancel login
          with exn ->
            Log.warn (fun log ->
                log "login cleanup raised and was contained: %s"
                  (Printexc.to_string exn)))
    in
    let attach_source source =
      match source with
      | App.Attach_path rel ->
          Option.map
            (fun resolve -> Protocol.Attach.Path (resolve rel))
            local.Local.attach_image_path
      | App.Attach_clipboard -> (
          match local.Local.clipboard_image with
          | None -> None
          | Some probe -> (
              match probe () with
              | Some (media_type, bytes) ->
                  Some (Protocol.Attach.Bytes { media_type; bytes })
              | None -> None))
    in
    let command = function
      | App.Quit -> Mosaic.Cmd.quit
      | App.Attach_image { request; source } ->
          (* The session the blob lands in is the active one, or the not-yet-
             created next session for a first prompt; [put_attachment] is
             fence-free, and the blob is orphan until a prompt references it. A
             missing resolver or an empty clipboard is reported as [Not_an_image]
             so a paste probe that found no image stays silent. *)
          perform (fun _ ->
              let session =
                match !active_session with
                | Some session -> session
                | None -> !next_session
              in
              match attach_source source with
              | None ->
                  deliver
                    (App.attached ~request
                       (Error Protocol.Attach.Error.Not_an_image))
              | Some source ->
                  let result =
                    match Client.attach client ~session source with
                    | result -> result
                    | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                        raise cancelled
                    | exception exn ->
                        Error
                          (Protocol.Attach.Error.Unavailable
                             (Mentat_diagnostic.of_text
                                (Printf.sprintf "attach raised: %s"
                                   (Printexc.to_string exn))))
                  in
                  deliver (App.attached ~request result))
      | App.Start_session { request; prompt; media; mode; history; model } ->
          desire request;
          let session = !next_session in
          next_session := fresh_session ();
          perform (fun _ ->
              Option.iter (append_prompt_history (Some session)) history;
              (* A staged pre-session selection binds between create and the
                 first submit so that turn seals on the chosen model; a refusal
                 fails the start like a create failure rather than letting the
                 turn silently run on the default model. It is the start's
                 first session-scoped call, so it lands on the agent it
                 starts — after the auto-title's offline rename, which needs
                 the fence the agent will hold. *)
              let staged_selection () =
                match model with
                | None -> Ok ()
                | Some (selector, reasoning_effort) ->
                    Client.set_model client ~session ?reasoning_effort selector
              in
              match Client.create client ~id:session () with
              | Error error when latest request ->
                  deliver (App.command_failed ~request error)
              | Error _ -> ()
              | Ok () -> (
                  auto_title ~session ~prompt;
                  match staged_selection () with
                  | Error error when latest request ->
                      deliver (App.command_failed ~request error)
                  | Error _ -> ()
                  | Ok () -> (
                      match follow ~request session ~from:`Now with
                      | `Admitted ->
                          submit_prompt ~request ~session ~prompt ~media ~mode
                      | `Failed | `Stale -> ())))
      | App.Prompt { request; session; prompt; media; mode } ->
          perform (fun _ ->
              submit_prompt ~request ~session ~prompt ~media ~mode)
      | App.Queue_next { request; session; prompt; media } ->
          perform (fun _ ->
              match
                Protocol.Command.queue_next ~session
                  ~input:(prompt_input ~media ~prompt)
                  ()
              with
              | Error invalid ->
                  deliver
                    (App.command_failed ~request
                       (unavailable (Protocol.Command.Invalid.message invalid)))
              | Ok command -> (
                  match Client.submit client command with
                  | Ok () -> deliver (App.command_succeeded ~request)
                  | Error error -> deliver (App.command_failed ~request error)))
      | App.Replace_queued { request; session; inputs } ->
          perform (fun _ ->
              match Protocol.Command.replace_queued ~session ~inputs with
              | Error invalid ->
                  deliver
                    (App.command_failed ~request
                       (unavailable (Protocol.Command.Invalid.message invalid)))
              | Ok command -> (
                  match Client.submit client command with
                  | Ok () -> deliver (App.command_succeeded ~request)
                  | Error error -> deliver (App.command_failed ~request error)))
      | App.Clear_queued { request; session } ->
          perform (fun _ ->
              match
                Client.submit client (Protocol.Command.clear_queued ~session)
              with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Interrupt { session } ->
          perform (fun _ ->
              match Protocol.Command.interrupt ~session () with
              | Error invalid ->
                  deliver
                    (App.operation_failed
                       ~message:(Protocol.Command.Invalid.message invalid)
                       ~login_needed:false)
              | Ok command -> (
                  match Client.submit client command with
                  | Ok () -> ()
                  | Error error ->
                      deliver
                        (App.operation_failed ~message:(protocol_message error)
                           ~login_needed:false)))
      | App.Detach_session ->
          latest_intent := None;
          perform (fun _ ->
              if Option.is_none !latest_intent then begin
                active_session := None;
                Local.attribute local None;
                retire_attachment ()
              end)
      | App.Resume_session { request; session } ->
          desire request;
          perform (fun _ -> ignore (follow ~request session ~from:`Beginning))
      | App.Fork_session { request; session } ->
          desire request;
          let into = !next_session in
          next_session := fresh_session ();
          perform (fun _ ->
              match Client.fork client ~session ~into () with
              | Error error when latest request ->
                  deliver (App.command_failed ~request error)
              | Error _ -> ()
              | Ok () -> ignore (follow ~request into ~from:`Beginning))
      | App.Rewind_session
          { request; source; anchor; prompt; media; mode; history } ->
          desire request;
          let into = !next_session in
          next_session := fresh_session ();
          perform (fun _ ->
              match Client.rewind client ~session:source ~into ~anchor with
              | Error error when latest request ->
                  deliver (App.command_failed ~request error)
              | Error _ -> ()
              | Ok () -> (
                  match follow ~request into ~from:`Beginning with
                  | `Admitted ->
                      (* History is attributed only after the child is admitted,
                         so a rewind that fails before admission never demotes the
                         edit to prompt history under an unrealized child id. *)
                      Option.iter (append_prompt_history (Some into)) history;
                      submit_prompt ~request ~session:into ~prompt ~media ~mode
                  | `Failed | `Stale -> ()))
      | App.Compact_session { request; session } ->
          perform (fun _ ->
              deliver
                (App.compaction_finished ~request
                   (Client.compact client ~session ~turn:(fresh_turn ()))))
      | App.Undo_step { request = _; session; op } ->
          (* The reversible undo step: the durable boundary the driver appends
             drives the armed state, seam, and composer through the feed, so a
             success needs no follow-up here; only a refusal (drift, or nothing
             to undo/redo) or a store error comes back to flash. *)
          perform (fun _ ->
              match Client.undo client ~session ~op with
              | Error error ->
                  deliver
                    (App.operation_failed ~message:(protocol_message error)
                       ~login_needed:false)
              | Ok (Mentat_mutation.Revert.Outcome.Refused messages) ->
                  deliver
                    (App.operation_failed
                       ~message:(String.concat "; " messages)
                       ~login_needed:false)
              | Ok
                  ( Mentat_mutation.Revert.Outcome.Applied _
                  | Mentat_mutation.Revert.Outcome.Nothing_to_revert ) ->
                  ())
      | App.Rename_session { request; session; title } ->
          perform (fun _ ->
              match Client.rename client ~session ~title with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Set_goal { request; session; goal } ->
          perform (fun _ ->
              match Client.set_goal client ~session ~goal with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Goal_continue { request; session; prompt } ->
          (* The steward's continuation: an ordinary prompt turn sealed under
             the goal_status schema through the generic output-schema
             channel, so the engine stays goal-blind and the model can end
             with the structured claim. *)
          perform (fun _ ->
              match
                Protocol.Command.prompt ~session ~turn:(fresh_turn ())
                  ~input:[ Mentat_llm.Content.text prompt ]
                  ~output_schema:Session.Metadata.Goal.Claim.schema ()
              with
              | Error invalid ->
                  deliver
                    (App.command_failed ~request
                       (unavailable (Protocol.Command.Invalid.message invalid)))
              | Ok command -> (
                  match Client.submit client command with
                  | Ok () -> deliver (App.command_succeeded ~request)
                  | Error error -> deliver (App.command_failed ~request error)))
      | App.Archive_session { request; session } ->
          perform (fun _ ->
              match Client.archive client ~session with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Restore_session { request; session } ->
          perform (fun _ ->
              match Client.restore client ~session with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Delete_session { request; session } ->
          perform (fun _ ->
              match Client.delete client ~session with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Load_home_sessions request ->
          perform (fun _ ->
              query_sessions request App.home_sessions_loaded active_cwd_listing)
      | App.Load_quick_sessions request ->
          perform (fun _ ->
              query_sessions request App.quick_sessions_loaded
                active_cwd_listing)
      | App.Load_screen_sessions request ->
          perform (fun _ ->
              query_sessions request App.screen_sessions_loaded
                all_sessions_listing)
      | App.Load_session_view { request; session } ->
          perform (fun _ ->
              deliver
                (App.session_view_loaded ~request ~session
                   (Client.session client session)))
      | App.Load_pending_decision { request; session } ->
          perform (fun _ ->
              deliver
                (App.pending_decision_loaded ~request ~session
                   (Client.pending_decision client session)))
      | App.Load_configuration request ->
          perform (fun _ ->
              deliver
                (App.configuration_loaded ~request
                   (Client.configuration client)))
      | App.Load_account_readiness request ->
          perform (fun _ ->
              deliver
                (App.account_readiness_loaded ~request
                   (Client.account_readiness client)))
      | App.Load_model_readiness { request; refresh } ->
          perform (fun _ ->
              deliver
                (App.model_readiness_loaded ~request
                   (Client.model_readiness ~refresh client)))
      | App.Load_review_state { request; scope } ->
          perform (fun _ ->
              deliver
                (App.review_state_loaded ~request
                   (Client.review_state client ~scope)))
      | App.Load_review_diff { request; path } ->
          perform (fun _ ->
              deliver
                (App.review_diff_loaded ~request ~path
                   (Client.review_diff client ~path)))
      | App.Load_review_crs request ->
          perform (fun _ ->
              deliver
                (App.review_crs_loaded ~request (Client.review_crs client)))
      | App.Load_workspace_glance request ->
          perform (fun _ ->
              deliver
                (App.workspace_glance_loaded ~request
                   (Client.workspace_glance client)))
      | App.Load_workspace_dune request ->
          perform (fun _ ->
              deliver
                (App.workspace_dune_loaded ~request
                   (Client.workspace_dune client)))
      | App.Dune_control { request; op } ->
          perform (fun _ ->
              deliver
                (App.workspace_dune_loaded ~request
                   (Client.workspace_dune_control client ~op)))
      | App.Load_running_processes { request; session } ->
          perform (fun _ ->
              deliver
                (App.running_processes_loaded ~request ~session
                   (Client.running_processes client session)))
      | App.Load_user_commands request ->
          perform (fun _ ->
              deliver
                (App.user_commands_loaded ~request
                   (Client.user_commands client)))
      | App.Expand_command { request; name; arguments; entry } ->
          perform (fun _ ->
              deliver
                (App.command_expanded ~request ~entry
                   (Client.expand_command client ~name ~arguments)))
      | App.Submit_review_command { request; command } ->
          perform (fun _ ->
              deliver
                (App.review_command_finished ~request
                   (Client.review client command)))
      | App.Submit_review_compose { request; edit } ->
          perform (fun _ ->
              deliver
                (App.review_compose_finished ~request
                   (Client.review_compose client edit)))
      | App.Answer_decision { request; session; decision; answer } ->
          perform (fun _ ->
              match
                Client.submit client
                  (Protocol.Command.answer_decision ~session ~decision ~answer)
              with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Set_model { request; session; selector; reasoning_effort } ->
          perform (fun _ ->
              match
                Client.set_model client ~session ?reasoning_effort selector
              with
              | Ok () -> deliver (App.command_succeeded ~request)
              | Error error -> deliver (App.command_failed ~request error))
      | App.Set_permission_review { request; session; review } ->
          perform (fun _ ->
              deliver
                (App.settings_mutation_finished ~request
                   (Client.set_permission_review client ~session review)))
      | App.Persist_ui_theme { request; name } ->
          perform (fun _ ->
              match Client.set_ui_theme client name with
              | Error error ->
                  deliver (App.ui_theme_persisted ~request (Error error))
              | Ok () ->
                  deliver
                    (App.ui_theme_persisted ~request
                       (Ok (theme_shadow client name))))
      | App.Auth_save_api_key { attempt; provider; key } ->
          perform (fun _ ->
              deliver
                (App.auth_save_api_key_finished ~attempt
                   (Client.save_api_key client ~provider ~key)))
      | App.Auth_begin_login { attempt; provider; method_ } ->
          perform (fun _ ->
              let started =
                match Client.login ~sw client ~provider ~method_ with
                | result -> result
                | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                    raise cancelled
                | exception exn -> Error (raised "login" "start" exn)
              in
              match started with
              | Error error -> deliver (App.auth_login_failed ~attempt error)
              | Ok login ->
                  Hashtbl.replace logins attempt login;
                  let rec pull_login () =
                    let step =
                      match Client.Login.next login with
                      | result -> result
                      | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                          raise cancelled
                      | exception exn -> Error (raised "login" "pull" exn)
                    in
                    match step with
                    | Error error ->
                        Hashtbl.remove logins attempt;
                        cancel_login login;
                        deliver (App.auth_login_failed ~attempt error)
                    | Ok step -> (
                        deliver (App.auth_login_step ~attempt step);
                        match step with
                        | Client.Login.Progress _ -> pull_login ()
                        | Client.Login.Saved _ | Client.Login.Cancelled ->
                            Hashtbl.remove logins attempt)
                  in
                  pull_login ())
      | App.Auth_logout { attempt; provider } ->
          perform (fun _ ->
              deliver
                (App.auth_logout_finished ~attempt
                   (Client.logout client provider)))
      | App.Auth_cancel attempt ->
          perform (fun _ ->
              match Hashtbl.find_opt logins attempt with
              | None -> ()
              | Some login ->
                  Hashtbl.remove logins attempt;
                  cancel_login login)
      | App.Load_prompt_history request ->
          perform (fun _ ->
              let contents =
                match local.Local.load_prompt_history () with
                | contents -> contents
                | exception _ -> ""
              in
              deliver (App.prompt_history_loaded ~request contents))
      | App.Append_prompt_history { session; entry } ->
          perform (fun _ -> append_prompt_history session entry)
      | App.Enumerate_files request ->
          perform (fun _ ->
              let result =
                match local.Local.enumerate_files with
                | Some enumerate -> enumerate ()
                | None ->
                    Error
                      (Mentat_diagnostic.of_text
                         "file completion is unavailable")
              in
              deliver (App.files_loaded ~request result))
      | App.Run_local_shell { request; command } ->
          perform (fun _ ->
              Option.iter
                (fun active -> active.cancelled <- true)
                !local_shell_run;
              let cancelled =
                Option.exists
                  (App.equal_request request)
                  !pending_shell_cancellation
              in
              pending_shell_cancellation := None;
              let active = { shell_request = request; cancelled } in
              local_shell_run := Some active;
              let result =
                match local.Local.run_local_shell with
                | None ->
                    Error
                      (Mentat_diagnostic.of_text "local shell is unavailable")
                | Some run -> (
                    match
                      run ~cancelled:(fun () -> active.cancelled) ~command
                    with
                    | result -> result
                    | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                        raise cancelled
                    | exception exn ->
                        Error
                          (Mentat_diagnostic.of_text
                             ("local shell callback raised: "
                            ^ Printexc.to_string exn)))
              in
              match !local_shell_run with
              | Some current
                when App.equal_request current.shell_request
                       active.shell_request -> (
                  local_shell_run := None;
                  match result with
                  | Ok result ->
                      deliver
                        (App.local_shell_finished ~request
                           (Ok (Tool_distill.local_shell ~command result)))
                  | Error diagnostic ->
                      deliver (App.capability_failed ~request diagnostic))
              | Some _ | None -> ())
      | App.Cancel_local_shell request ->
          perform (fun _ ->
              match !local_shell_run with
              | Some active when App.equal_request active.shell_request request
                ->
                  active.cancelled <- true
              | Some _ | None -> pending_shell_cancellation := Some request)
      | App.Edit_in_editor { request; text } ->
          (* The runtime owns the terminal, so it brackets the callback:
             [suspend ~leave_alt:true] hands the primary screen and its scrollback
             to a full-screen $EDITOR, and [resume] re-enters the alternate
             screen, discards keystrokes typed while the editor ran, and repaints.
             Resume is unconditional in a finalizer so an editor crash still
             restores the terminal. *)
          perform (fun _ ->
              let result =
                match local.Local.edit_in_editor with
                | None ->
                    Error
                      (Mentat_diagnostic.of_text
                         "external editor is unavailable")
                | Some edit ->
                    Matrix.suspend ~leave_alt:true matrix;
                    Fun.protect
                      ~finally:(fun () -> Matrix.resume matrix)
                      (fun () ->
                        match edit ~text with
                        | result -> result
                        | exception (Eio.Cancel.Cancelled _ as cancelled) ->
                            raise cancelled
                        | exception exn ->
                            Error
                              (Mentat_diagnostic.of_text
                                 ("editor callback raised: "
                                ^ Printexc.to_string exn)))
              in
              deliver (App.editor_finished ~request result))
      | App.Notify { channels; title; body } ->
          (* R10: the reducer already decided; the runtime only encodes each
             channel to a Mosaic command and writes — bell and OSC 9/777 to the
             terminal, [`Command] to the notification hook — and re-decides
             nothing. Strip C0 controls (ESC, BEL, …) from the strings so a
             session/workspace title cannot break out of the OSC payload;
             UTF-8-safe since continuation bytes are >= 0x80. *)
          let title = sanitize_notification title in
          let body = sanitize_notification body in
          let emit = function
            | `Bell -> Mosaic.Cmd.bell
            | `Osc9 | `Osc777 -> Mosaic.Cmd.notify ~title ~body
            | `Command -> (
                match local.Local.notify with
                | Some notify -> perform (fun _ -> notify ~title ~body)
                | None -> Mosaic.Cmd.none)
          in
          Mosaic.Cmd.batch (List.map emit channels)
      | App.Copy_text text -> Mosaic.Cmd.copy_to_clipboard text
      | App.Copy_selection -> Mosaic.Cmd.copy_selection
      | App.Query_color_scheme -> Mosaic.Cmd.query_color_scheme
      | App.Open_url { attempt; url } ->
          perform (fun _ ->
              if Hashtbl.mem logins attempt then
                match local.Local.open_url with
                | None ->
                    deliver
                      (App.auth_url_open_failed ~attempt
                         ~message:"opening a browser is unavailable")
                | Some open_url -> (
                    match open_url url with
                    | Ok () -> deliver (App.auth_url_opened ~attempt)
                    | Error diagnostic ->
                        deliver
                          (App.auth_url_open_failed ~attempt
                             ~message:(Mentat_diagnostic.to_string diagnostic))))
      | App.Observe_child { request; child } ->
          perform (fun _ ->
              let generation = Child_feeds.follow_live child_feeds child in
              deliver
                (App.child_observation_started ~request
                   ~observation:Child_feeds.Live ~child ~generation))
      | App.Drill_child { request; child } ->
          perform (fun _ ->
              let generation = Child_feeds.drill child_feeds child in
              deliver
                (App.child_observation_started ~request
                   ~observation:Child_feeds.Drill ~child ~generation))
      | App.Close_child_drill { child; generation } ->
          perform (fun _ ->
              Child_feeds.close_drill child_feeds ~child ~generation)
      | App.Close_child_pane ->
          perform (fun _ -> Child_feeds.close_pane child_feeds)
    in
    let interpret commands = Mosaic.Cmd.batch (List.map command commands) in
    let last_title = ref None in
    let sync_title model commands =
      let title = App.terminal_title model in
      if !last_title = Some title then interpret commands
      else begin
        last_title := Some title;
        Mosaic.Cmd.batch [ interpret commands; Mosaic.Cmd.set_title title ]
      end
    in
    let app =
      {
        Mosaic.init =
          (fun () ->
            let model, commands =
              App.init ~now:(Matrix.now matrix) ~startup ~capabilities
                ~reduced_motion ~show_reasoning ~overlay ~notify_policy ~palette
                ~theme_name ~themes ~theme_auto ~image_max_count
            in
            (model, sync_title model commands));
        update =
          (fun message model ->
            let model, commands = App.update message model in
            (model, sync_title model commands));
        view = App.view;
        subscriptions = App.subscriptions;
      }
    in
    let contain_cleanup label cleanup =
      try Eio.Cancel.protect cleanup
      with exn ->
        Log.warn (fun log ->
            log "%s cleanup raised and was contained: %s" label
              (Printexc.to_string exn))
    in
    Fun.protect
      ~finally:(fun () ->
        dispatch_ref := None;
        latest_intent := None;
        Option.iter (fun active -> active.cancelled <- true) !local_shell_run;
        local_shell_run := None;
        pending_shell_cancellation := None;
        contain_cleanup "main feed" retire_attachment;
        contain_cleanup "child feeds" (fun () ->
            Child_feeds.close_pane child_feeds);
        let active_logins = Hashtbl.to_seq_values logins |> List.of_seq in
        Hashtbl.clear logins;
        List.iter
          (fun login -> contain_cleanup "login" (fun () -> cancel_login login))
          active_logins)
      (fun () -> Mosaic.run ~matrix ~process_perform ?probe app);
    Ok { last_session = !active_session }
