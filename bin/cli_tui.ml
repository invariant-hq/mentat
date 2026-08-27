(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner

let keybindings_log =
  Logs.Src.create "mentat.tui.keybindings"
    ~doc:"User keybinding file resolution"

module Keybindings_log = (val Logs.src_log keybindings_log : Logs.LOG)

let notify_log =
  Logs.Src.create "mentat.tui.notify" ~doc:"Notification config resolution"

module Notify_log = (val Logs.src_log notify_log : Logs.LOG)

let theme_log = Logs.Src.create "mentat.tui.theme" ~doc:"Color theme resolution"

module Theme_log = (val Logs.src_log theme_log : Logs.LOG)

let history_max_bytes = 8 * 1024 * 1024

let terminal_supported () =
  Unix.isatty Unix.stdin && Unix.isatty Unix.stdout
  &&
  match Sys.getenv_opt "TERM" with
  | Some term -> not (String.equal term "" || String.equal term "dumb")
  | None -> false

let history_path t =
  Filename.concat (User_dirs.state_home (Composition.dirs t)) "history.jsonl"

let load_prompt_history path () =
  match Fs.read_capped ~max_bytes:history_max_bytes path with
  | Ok (Some contents) -> contents
  | Ok None | Error _ -> ""

let complete_line_tail contents max_bytes =
  let length = String.length contents in
  if length <= max_bytes then contents
  else
    let first = length - max_bytes in
    match String.index_from_opt contents first '\n' with
    | None -> ""
    | Some newline -> String.sub contents (newline + 1) (length - newline - 1)

(* Rewrite a bounded whole-line tail under the executable's shared cancellable
   lock. The TUI owns record validity; this boundary only preserves complete
   encoded lines and file size. *)
let append_prompt_history path encoded =
  let line = encoded ^ "\n" in
  if String.length line <= history_max_bytes then
    ignore
      (Fs.with_lock (path ^ ".lock") (fun () ->
           let prior = load_prompt_history path () in
           let retained =
             complete_line_tail prior (history_max_bytes - String.length line)
           in
           Fs.atomic_write ~perms:0o600 path (retained ^ line)))

let file_diagnostic error =
  Mentat_diagnostic.of_text
    (Format.asprintf "%a" Mentat_workspace_io.File_error.pp error)

(* File completion's universe is the checkpoint capture's: every non-ignored
   regular file, discovered through the glob walker so per-directory
   [.gitignore]/[.ignore]/[.rgignore] rules and VCS metadata pruning apply. A
   hardcoded denylist cannot know a workspace's own ignored trees, and one
   unpruned reference checkout floods the completion with noise. *)
let max_completion_files = 20_000

let take_files count paths =
  let rec loop taken count = function
    | [] -> List.rev taken
    | _ :: _ when count = 0 -> List.rev taken
    | path :: rest -> loop (path :: taken) (count - 1) rest
  in
  loop [] count paths

let enumerate_files workspace_io () =
  let root = Mentat_workspace_io.cwd workspace_io in
  match Mentat_workspace_io.File.lstat workspace_io root with
  | Error error -> Error (file_diagnostic error)
  | Ok stat when stat.Eio.File.Stat.kind <> `Directory -> Ok []
  | Ok _ -> (
      match
        Mentat_tools.Fs.Glob.Enumeration.paths workspace_io
          ~cancelled:(fun () -> false)
          ~root ~pattern:"**"
      with
      | Ok paths ->
          (* Bounded over path order, so the bound keeps the shallowest,
             earliest paths; narrowing the query reaches the rest. *)
          Ok
            (paths
            |> take_files max_completion_files
            |> List.map Mentat_workspace.Path.rel)
      | Error `Cancelled -> Ok []
      | Error (`Invalid_pattern message) ->
          Error (Mentat_diagnostic.of_text message)
      | Error (`File_error error) -> Error (file_diagnostic error))

let process_status = function
  | Unix.WEXITED code -> Printf.sprintf "exited with status %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "was killed by signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "was stopped by signal %d" signal

let rec waitpid pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid pid

(* OS URL opening is the RFC-0013 browser-login precedent: the executable asks
   a platform opener to detach the actual browser, waits only for that small
   launcher, and reports launch/exit failures without invoking a shell. *)
let open_url uri =
  let url = Uri.to_string uri in
  if String.equal url "" then
    Error (Mentat_diagnostic.of_text "cannot open an empty URL")
  else
    let candidates =
      if String.equal Sys.os_type "Win32" then
        [
          ( "rundll32.exe",
            [| "rundll32.exe"; "url.dll,FileProtocolHandler"; url |] );
        ]
      else
        let macos =
          if Sys.file_exists "/usr/bin/open" then
            [ ("/usr/bin/open", [| "/usr/bin/open"; url |]) ]
          else []
        in
        macos @ [ ("xdg-open", [| "xdg-open"; url |]) ]
    in
    match Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 with
    | exception Unix.Unix_error (error, _, _) ->
        Error
          (Mentat_diagnostic.of_text
             ("could not open the browser: " ^ Unix.error_message error))
    | null ->
        Fun.protect
          ~finally:(fun () -> Unix.close null)
          (fun () ->
            let rec launch failures = function
              | [] ->
                  Error
                    (Mentat_diagnostic.of_text
                       ("could not open the browser: "
                       ^ String.concat "; " (List.rev failures)))
              | (program, arguments) :: rest -> (
                  match
                    Unix.create_process program arguments null null null
                  with
                  | pid -> (
                      match waitpid pid with
                      | Unix.WEXITED 0 -> Ok ()
                      | status ->
                          launch
                            ((program ^ " " ^ process_status status) :: failures)
                            rest)
                  | exception Unix.Unix_error (error, _, _) ->
                      launch
                        ((program ^ ": " ^ Unix.error_message error) :: failures)
                        rest)
            in
            launch [] candidates)

let run_local_shell definition ~cancelled ~command =
  let input =
    Jsont.Json.object'
      [
        Jsont.Json.mem (Jsont.Json.name "command") (Jsont.Json.string command);
        Jsont.Json.mem (Jsont.Json.name "escalate") (Jsont.Json.bool false);
      ]
  in
  let declaration = Mentat_tool.declaration definition in
  let source =
    Mentat_llm.Tool.Call.make ~id:"tui-local-shell"
      ~name:(Mentat_llm.Tool.name declaration)
      ~input ()
  in
  match Mentat_tool.Call.decode definition source with
  | Error error ->
      Error
        (Mentat_diagnostic.of_text
           (Mentat_tool.Call.Decode_error.message error))
  | Ok call -> (
      (* This is an explicit local-user channel-3 action. The definition keeps
         the composition root's sealed sandbox, but its model-facing permission
         requests do not mediate the user's own command. *)
      match Mentat_tool.Call.run call ~cancelled with
      | Mentat_tool.Call.Finished result -> Ok result
      | Mentat_tool.Call.Prepared _ ->
          Error
            (Mentat_diagnostic.of_text
               "the executable-local shell unexpectedly prepared a staged tool \
                call"))

(* Theme resolution is the executable's only I/O boundary over the palette. A
   built-in preset name resolves from the compiled {!Mentat_tui.Theme.Preset}
   floor; any other name — or a same-named file overlaying a preset — reads
   [<config_home>/themes/<name>.json] (byte-capped) and overlays its roles onto a
   base, which an optional ["extends"] key names (resolved only through the
   built-in floor, never the user namespace, so no chain or cycle can form). The
   retired default name ["mentat"] aliases ["mentat-dark"] for one release, and
   ["auto"] (Phase 2) degrades to the dark default. *)
let canonical_theme_name = function
  | "mentat" | "auto" -> "mentat-dark"
  | name -> name

let themes_dir t =
  Filename.concat (User_dirs.config_home (Composition.dirs t)) "themes"

let theme_names t =
  match Sys.readdir (themes_dir t) with
  | exception _ -> []
  | entries ->
      Array.to_list entries
      |> List.filter_map (fun entry ->
          if Filename.check_suffix entry ".json" then
            Some (Filename.chop_suffix entry ".json")
          else None)
      |> List.sort_uniq String.compare

let read_theme_json t name =
  let path = Filename.concat (themes_dir t) (name ^ ".json") in
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Ok None -> `Missing
  | Error message ->
      Theme_log.warn (fun log ->
          log "theme %S is unreadable (%s); using the default" name message);
      `Failed
  | Ok (Some text) -> (
      match Jsont_bytesrw.decode_string Jsont.json text with
      | Error message ->
          Theme_log.warn (fun log ->
              log "theme %S is not valid JSON (%s); using the default" name
                message);
          `Failed
      | Ok json -> `Json json)

let theme_extends json =
  match json with
  | Jsont.Object (members, _) ->
      List.find_map
        (fun ((key, _), value) ->
          if String.equal key "extends" then
            match value with
            | Jsont.String (spelling, _) -> Some spelling
            | _ -> None
          else None)
        members
  | _ -> None

(* The base a user file overlays, resolved through the built-in floor. An
   [extends] naming no built-in falls back to [mentat-dark] with a diagnostic;
   without [extends], the same-named built-in is the base, else [mentat-dark].
   The base also carries the dark/light appearance the overlay inherits. *)
let theme_base name json =
  match theme_extends json with
  | Some base -> (
      match Mentat_tui.Theme.Preset.find (canonical_theme_name base) with
      | Some preset -> preset.Mentat_tui.Theme.Preset.palette
      | None ->
          Theme_log.warn (fun log ->
              log "theme %S extends unknown theme %S; using mentat-dark" name
                base);
          Mentat_tui.Theme.Palette.default)
  | None -> (
      match Mentat_tui.Theme.Preset.find (canonical_theme_name name) with
      | Some preset -> preset.Mentat_tui.Theme.Preset.palette
      | None -> Mentat_tui.Theme.Palette.default)

(* Resolve one theme by name to its palette: a user file overlays its base, else
   a built-in preset, else the default. *)
let resolve_theme t name =
  let name = canonical_theme_name name in
  let from_preset () =
    match Mentat_tui.Theme.Preset.find name with
    | Some preset -> preset.Mentat_tui.Theme.Preset.palette
    | None -> Mentat_tui.Theme.Palette.default
  in
  match read_theme_json t name with
  | `Json json ->
      let base = theme_base name json in
      let palette, diagnostics = Mentat_tui.Theme.Palette.of_json ~base json in
      List.iter
        (fun diagnostic ->
          Theme_log.warn (fun log ->
              log "theme %S: %s" name
                (Mentat_tui.Theme.Palette.Diagnostic.message diagnostic)))
        diagnostics;
      palette
  | `Failed -> from_preset ()
  | `Missing ->
      if Option.is_some (Mentat_tui.Theme.Preset.find name) then from_preset ()
      else begin
        Theme_log.warn (fun log ->
            log "theme %S not found; using the default" name);
        from_preset ()
      end

(* The catalog the /theme picker previews from: every built-in preset, with a
   same-named user file overlaid onto it (the name kept, and the appearance
   inherited through the overlay's base), then the user files that introduce a
   new name. Built-ins come first. *)
let theme_catalog t =
  let user_names = theme_names t in
  let is_builtin name =
    List.exists
      (fun (preset : Mentat_tui.Theme.Preset.t) ->
        String.equal preset.Mentat_tui.Theme.Preset.name name)
      Mentat_tui.Theme.Preset.all
  in
  let builtins =
    List.map
      (fun (preset : Mentat_tui.Theme.Preset.t) ->
        if List.mem preset.Mentat_tui.Theme.Preset.name user_names then
          {
            preset with
            Mentat_tui.Theme.Preset.palette =
              resolve_theme t preset.Mentat_tui.Theme.Preset.name;
          }
        else preset)
      Mentat_tui.Theme.Preset.all
  in
  let novel =
    List.filter (fun name -> not (is_builtin name)) user_names
    |> List.map (fun name ->
        { Mentat_tui.Theme.Preset.name; palette = resolve_theme t name })
  in
  builtins @ novel

let theme_name t =
  canonical_theme_name
    (Mentat_config.Resolved.get Mentat_config.Field.tui_theme
       (Composition.config t))

let palette t = resolve_theme t (theme_name t)

(* Under [tui.theme = "auto"] the palette follows the terminal's colour scheme
   between the resolved [tui.theme_dark] and [tui.theme_light] members. Resolving
   both here — the palette's only I/O boundary — seeds the dark member and hands
   the pair to the reducer to swap between; [None] leaves the launch theme fixed.
   The raw value drives the check because [theme_name] canonicalizes ["auto"]. *)
let theme_auto t =
  let get field = Mentat_config.Resolved.get field (Composition.config t) in
  if String.equal (get Mentat_config.Field.tui_theme) "auto" then
    let dark = resolve_theme t (get Mentat_config.Field.tui_theme_dark) in
    let light = resolve_theme t (get Mentat_config.Field.tui_theme_light) in
    Some (dark, light)
  else None

let seed_palette t =
  match theme_auto t with Some (dark, _light) -> dark | None -> palette t

(* The launch-fixed notification policy, resolved from the [notify.*] config.
   The channel/focus spellings are validated by the field codecs, so decoding
   them back to the typed enums cannot fail; the fallbacks preserve totality. *)
let notify_policy t =
  let config = Composition.config t in
  let get field = Mentat_config.Resolved.get field config in
  {
    Mentat_tui.App.notify_enabled = get Mentat_config.Field.notify_enabled;
    notify_channel =
      Option.value ~default:Mentat_config.Notify.Channel.Auto
        (Mentat_config.Notify.Channel.of_string
           (get Mentat_config.Field.notify_channel));
    notify_focus =
      Option.value ~default:Mentat_config.Notify.When.Unfocused
        (Mentat_config.Notify.When.of_string
           (get Mentat_config.Field.notify_when));
    (* Validate every notify.on entry rather than silently dropping unknown
       spellings: a typo is reported at load, mirroring the keybinding
       diagnostics. notify.command needs no such check — it is an argv, not a
       closed vocabulary. *)
    notify_on =
      List.filter_map
        (fun spelling ->
          match Mentat_config.Notify.Event.of_string spelling with
          | Some event -> Some event
          | None ->
              Notify_log.warn (fun log ->
                  log "notify.on: ignoring unknown event %S" spelling);
              None)
        (get Mentat_config.Field.notify_on);
  }

(* The external notification hook for the [command] channel: the configured argv
   with the title and body appended, run best-effort with its output discarded so
   it never reaches the TUI-owned terminal. Absent when [notify.command] is
   empty, so the reducer does not advertise the [command] channel. *)
let notify_hook t =
  match
    Mentat_config.Resolved.get Mentat_config.Field.notify_command
      (Composition.config t)
  with
  | [] -> None
  | _ :: _ as prefix ->
      Some
        (fun ~title ~body ->
          let argv = prefix @ [ title; body ] in
          try
            let process_mgr = Eio.Stdenv.process_mgr (Composition.stdenv t) in
            let discard = Buffer.create 256 in
            ignore
              (Eio.Process.parse_out process_mgr Eio.Buf_read.take_all
                 ~stderr:(Eio.Flow.buffer_sink discard)
                 argv)
          with _ -> ())

(* The external-editor escape. The runtime has already suspended the terminal
   (alternate screen left, cooked mode), so the editor spawns attached to the
   real tty on a temp file seeded with the fully-expanded draft. A zero exit
   installs the read-back; a non-zero exit or any failure leaves the draft. *)
let edit_in_editor t ~text =
  let editor =
    match Composition.getenv t "VISUAL" with
    | Some e when String.trim e <> "" -> e
    | Some _ | None -> (
        match Composition.getenv t "EDITOR" with
        | Some e when String.trim e <> "" -> e
        | Some _ | None -> "vi")
  in
  try
    let tmp = Filename.temp_file "mentat-edit-" ".md" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove tmp with _ -> ())
      (fun () ->
        let oc = open_out tmp in
        output_string oc text;
        close_out oc;
        let stdenv = Composition.stdenv t in
        let argv =
          List.filter
            (fun s -> not (String.equal s ""))
            (String.split_on_char ' ' editor)
          @ [ tmp ]
        in
        let status =
          Eio.Switch.run @@ fun sw ->
          let proc =
            Eio.Process.spawn ~sw
              (Eio.Stdenv.process_mgr stdenv)
              ~stdin:(Eio.Stdenv.stdin stdenv)
              ~stdout:(Eio.Stdenv.stdout stdenv)
              ~stderr:(Eio.Stdenv.stderr stdenv) argv
          in
          Eio.Process.await proc
        in
        match status with
        | `Exited 0 ->
            let ic = open_in_bin tmp in
            Fun.protect
              ~finally:(fun () -> close_in_noerr ic)
              (fun () -> Ok (really_input_string ic (in_channel_length ic)))
        | `Exited code ->
            Error
              (Mentat_diagnostic.of_text
                 (Printf.sprintf "editor exited with status %d; draft unchanged"
                    code))
        | `Signaled signal ->
            Error
              (Mentat_diagnostic.of_text
                 (Printf.sprintf "editor stopped by signal %d; draft unchanged"
                    signal)))
  with exn ->
    Error
      (Mentat_diagnostic.of_text
         ("could not run the editor: " ^ Printexc.to_string exn))

let attach_image_path t =
  (* The mention path is workspace-relative; the client attach reads it below the
     workspace root the composition holds. The [Path] value's root key is
     decorative here — the executable's responder reads the rel below [root]. *)
  let workspace =
    Mentat_workspace.single (Mentat_workspace.Root.of_dir (Composition.root t))
  in
  fun rel -> Mentat_workspace.path_at_cwd_root workspace rel

let local t client workspace_io shell =
  let history = history_path t in
  Mentat_tui.Runtime.Local.make
    ~load_prompt_history:(load_prompt_history history)
    ~append_prompt_history:(append_prompt_history history)
    ~enumerate_files:(enumerate_files workspace_io)
    ~run_local_shell:(run_local_shell shell) ~open_url
    ~edit_in_editor:(edit_in_editor t) ?notify:(notify_hook t)
    ~auto_title:(fun ~session ~prompt ->
      Auto_title.run t ~client ~session ~prompt)
    ~attach_image_path:(attach_image_path t)
    ~clipboard_image:(Image_clipboard.probe ~stdenv:(Composition.stdenv t))
    ~attribute_session:(fun session ->
      Log_setup.set_session (Option.map Mentat_session.Id.to_string session))
    ()

(* The workspace root reaching the interface has already been canonicalized, so
   the home boundary must be canonicalized too or a symlinked home (macOS spells
   [/tmp] as [/private/tmp]) would never contain it and every workspace path
   would render absolute. *)
let canonical_home path =
  let canonical =
    match Unix.realpath path with
    | canonical -> canonical
    | exception Unix.Unix_error _ -> path
  in
  Result.to_option (Lpath.Abs.of_string canonical)

let home t = Option.bind (Composition.getenv t "HOME") canonical_home
let ambient_home () = Option.bind (Sys.getenv_opt "HOME") canonical_home

let snapshot ~version t model =
  let selector = Mentat_provider.Selector.of_model model in
  match Mentat_provider.Catalog.find (Composition.catalog t) selector with
  | Error error ->
      Error (Exit_status.runtime (Mentat_provider.Catalog.Error.message error))
  | Ok catalog_model ->
      let effort =
        match
          Mentat_config.Resolved.find Mentat_config.Field.reasoning
            (Composition.config t)
        with
        | Some effort -> Some effort
        | None -> Mentat_provider.Model.default_reasoning catalog_model
      in
      Ok
        (Mentat_tui.Snapshot.make ~version
           ~model:(Mentat_provider.Selector.to_string selector)
           ~effort:
             (Option.map Mentat_llm.Request.Options.Reasoning_effort.to_string
                effort)
           ~cwd:(Composition.root t) ~home:(home t)
           ~context_window:(Mentat_provider.Model.context_window catalog_model)
           ~sandbox:
             (Some
                (Mentat_config.Mode.to_string
                   (Composition.configured_sandbox_mode t)))
           ~trusted:(Composition.trusted t))

let use_color () =
  match Sys.getenv_opt "NO_COLOR" with
  | Some value when not (String.equal value "") -> false
  | Some _ | None -> true

let reduced_motion t =
  match Composition.getenv t "MENTAT_REDUCED_MOTION" with
  | Some ("1" | "true") -> true
  | Some _ | None -> false

(* Parse the keybindings.json at [path] into its launch-fixed overlay and a
   plain message for each entry the parser rejected. An absent or unreadable
   file, or malformed JSON, overlays nothing and is never fatal; every returned
   message names one keybindings.json problem. This is the single home of the
   parse — the interactive {!overlay} and the diagnostic-only
   {!keybindings_diagnostics} both project it. *)
let read_keybindings path =
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Ok None -> (Mentat_tui.Command.Overlay.empty, [])
  | Error message ->
      ( Mentat_tui.Command.Overlay.empty,
        [ Printf.sprintf "unreadable (%s)" message ] )
  | Ok (Some text) -> (
      match Jsont_bytesrw.decode_string Jsont.json text with
      | Error message ->
          ( Mentat_tui.Command.Overlay.empty,
            [ Printf.sprintf "invalid JSON: %s" message ] )
      | Ok json ->
          let overlay, diagnostics = Mentat_tui.Command.Overlay.of_json json in
          (overlay, List.map Mentat_tui.Command.Diagnostic.message diagnostics))

(* The launch-fixed keybinding overlay over the registry defaults. An absent
   file overlays nothing; a malformed file or a rejected entry keeps the default
   for that entry and is logged. Never fatal. *)
let overlay t =
  let path =
    Filename.concat
      (User_dirs.config_home (Composition.dirs t))
      "keybindings.json"
  in
  let overlay, diagnostics = read_keybindings path in
  List.iter
    (fun message ->
      Keybindings_log.warn (fun log -> log "keybindings.json: %s" message))
    diagnostics;
  overlay

let keybindings_diagnostics path = snd (read_keybindings path)

let print_goodbye t outcome =
  let stdout = (Composition.stdenv t)#stdout in
  Eio.Flow.copy_string
    (Mentat_tui.Runtime.goodbye ~palette:(palette t) ~color:(use_color ())
       outcome)
    stdout

let resolve_session t session last =
  match (session, last) with
  | None, false -> Ok None
  | Some _, true ->
      Error (Exit_status.usage "choose SESSION or --last, not both")
  | Some _, false | None, true -> (
      match Session_locate.resolve t ~session ~last with
      | Ok document -> Ok (Some (Mentat_store.Session.Document.id document))
      | Error error -> Error (Session_locate.status error))

type gate = Run | Reload | Stop

let prompt_for_trust ?notice ?home ~stdenv ~set root =
  let decide = function
    | Cli_trust_prompt.Untrusted -> (
        match set Trust_store.Untrusted with
        | Ok () -> Ok `Run
        | Error error ->
            Error
              ("Could not save the decision: " ^ Trust_store.Error.message error)
        )
    | Cli_trust_prompt.Trusted -> (
        match set Trust_store.Trusted with
        | Ok () -> Ok `Reload
        | Error error ->
            Error
              ("Could not save the decision: " ^ Trust_store.Error.message error)
        )
  in
  match Cli_trust_prompt.run ?notice ?home ~stdenv ~root ~decide () with
  | Cli_trust_prompt.Exit_prompt ->
      Output.stdout_printf
        "\nExited without saving a workspace trust decision.\n";
      Stop
  | Cli_trust_prompt.Continue `Run ->
      Output.stdout_printf "\nRepository remains restricted.\n";
      Run
  | Cli_trust_prompt.Continue `Reload -> Reload

let trust_gate t =
  let root = Composition.root t in
  let root_text = Lpath.Abs.to_string root in
  let path = User_dirs.trust_file (Composition.dirs t) in
  match Trust_store.status ~path ~root:root_text with
  | Error error -> Error (Exit_status.runtime (Trust_store.Error.message error))
  | Ok (Trust_store.Trusted | Trust_store.Untrusted) -> Ok Run
  | Ok Trust_store.Unknown ->
      if not (terminal_supported ()) then
        Error
          (Exit_status.runtime
             (Mentat_tui.Runtime.error_message Mentat_tui.Runtime.No_tty))
      else
        Ok
          (prompt_for_trust ?home:(home t) ~stdenv:(Composition.stdenv t) root
             ~set:(fun status -> Trust_store.set ~path ~root:root_text status))

(* [--sandbox] overlays the configured build posture for this interactive
   session, exactly as the headless run flag does. *)
let sandbox_overrides = function
  | None -> Ok []
  | Some raw -> (
      match
        Mentat_config.set_text Mentat_config.Field.sandbox_mode raw
          Mentat_config.empty
      with
      | Ok config -> Ok [ config ]
      | Error e -> Error (Exit_status.usage (Mentat_config.Error.message e)))

(* The client bundle the TUI drives: in-process by default, or — under
   [--attach] — a driver the per-user daemon fills over the wire, wrapped with
   local command expansion, paired with the {b local} read capability and shell
   ([tui_capabilities]): when attached the engine is remote but file completion
   and the local shell stay local. Trust prompting precedes this (in [launch]),
   so an untrusted workspace never spawns a daemon. *)
let tui_client_bundle t ~attach =
  if attach then
    match Daemon.find_or_spawn t with
    | Error status -> Error status
    | Ok driver -> (
        match Composition.tui_capabilities t with
        | Error status -> Error status
        | Ok (read_capability, shell) ->
            Ok (Composition.attach_client t driver, read_capability, shell))
  else Composition.client_with_tui_capabilities t

let launch_loaded ?(activation_ready = fun () -> ()) ?(launch_review = false)
    ~version ~attach ~mode ~session ~last ~input t =
  match Composition.default_model t with
  | Error message -> Exit_status.runtime message
  | Ok model -> (
      match snapshot ~version t model with
      | Error status -> status
      | Ok snapshot -> (
          match tui_client_bundle t ~attach with
          | Error status -> status
          | Ok (client, read_capability, shell) -> (
              activation_ready ();
              match resolve_session t session last with
              | Error status -> status
              | Ok session -> (
                  (* Attribute logs to the resumed session before the runtime
                     starts, so a failure between here and the first attachment
                     is still named. Sessions opened fresh inside the terminal
                     and later in-TUI switches arrive through the runtime's
                     [attribute_session] port, which repeats this identity
                     harmlessly: [set_session] is idempotent. *)
                  Option.iter
                    (fun id ->
                      Log_setup.set_session ~event:Log_setup.Resumed
                        (Some (Mentat_session.Id.to_string id)))
                    session;
                  let startup =
                    Mentat_tui.Startup.make ~launch_review ~snapshot ~mode
                      ~session ~input
                      ~providers:
                        (Mentat_provider.Catalog.declarations
                           (Composition.catalog t))
                      ~permission_review:
                        Mentat_permission.Review_behavior.Enforce ()
                  in
                  let show_reasoning =
                    Mentat_config.Resolved.get Mentat_config.Field.tui_thinking
                      (Composition.config t)
                  in
                  let mouse =
                    Mentat_config.Resolved.get Mentat_config.Field.tui_mouse
                      (Composition.config t)
                  in
                  let image_max_count =
                    Mentat_config.Resolved.get
                      Mentat_config.Field.image_max_count (Composition.config t)
                  in
                  match
                    Mentat_tui.Runtime.run ~stdenv:(Composition.stdenv t)
                      ~client ~startup
                      ~local:(local t client read_capability shell)
                      ~reduced_motion:(reduced_motion t) ~show_reasoning
                      ~overlay:(overlay t) ~notify_policy:(notify_policy t)
                      ~palette:(seed_palette t) ~theme_name:(theme_name t)
                      ~themes:(theme_catalog t) ~theme_auto:(theme_auto t)
                      ~image_max_count ~mouse ()
                  with
                  | Error error ->
                      Exit_status.runtime
                        (Mentat_tui.Runtime.error_message error)
                  | Ok outcome ->
                      print_goodbye t outcome;
                      Exit_status.Success))))

let activation_failure status rollback =
  let rollback_message =
    match rollback with
    | Ok () -> "The repository was returned to restricted mode."
    | Error error ->
        "Mentat also could not restore restricted mode: "
        ^ Trust_store.Error.message error
  in
  match status with
  | Exit_status.Runtime_error message ->
      Exit_status.runtime
        ("repository activation failed: " ^ message ^ "\n" ^ rollback_message)
  | Exit_status.Internal message ->
      Exit_status.Internal
        ("repository activation failed: " ^ message ^ "\n" ^ rollback_message)
  | Exit_status.Success | Exit_status.Failed | Exit_status.Usage_error _
  | Exit_status.Blocked _ | Exit_status.Interrupted ->
      status

let activation_notice status =
  let message =
    match status with
    | Exit_status.Runtime_error message
    | Exit_status.Usage_error message
    | Exit_status.Blocked message
    | Exit_status.Internal message ->
        message
    | Exit_status.Failed -> "activation failed"
    | Exit_status.Interrupted -> "activation was interrupted"
    | Exit_status.Success -> "activation did not enter the composition root"
  in
  "Repository activation failed: " ^ message
  ^ "\nThe repository was returned to restricted mode."

let set_trust path root status =
  Eio_main.run @@ fun _ -> Trust_store.set ~path ~root status

let rec launch_trusted ~launch_review ~review_base ~version ~attach ~cwd
    ~overrides ~mode ~session ~last ~input ~path ~root ~root_text =
  let entered = ref false in
  let status =
    Composition.with_base ?review_base ~cwd ~overrides (fun t ->
        launch_loaded ~launch_review ~version ~attach ~mode ~session ~last
          ~input t ~activation_ready:(fun () ->
            entered := true;
            Output.stdout_printf "\nRepository activation is enabled.\n"))
  in
  if !entered then status
  else
    match set_trust path root_text Trust_store.Untrusted with
    | Error _ as rollback -> activation_failure status rollback
    | Ok () -> (
        let gate =
          Eio_main.run @@ fun stdenv ->
          prompt_for_trust ~notice:(activation_notice status)
            ?home:(ambient_home ()) ~stdenv root ~set:(fun status ->
              Trust_store.set ~path ~root:root_text status)
        in
        match gate with
        | Stop -> Exit_status.Success
        | Run ->
            Composition.with_base ?review_base ~cwd ~overrides (fun t ->
                launch_loaded ~launch_review ~version ~attach ~mode ~session
                  ~last ~input t)
        | Reload ->
            launch_trusted ~launch_review ~review_base ~version ~attach ~cwd
              ~overrides ~mode ~session ~last ~input ~path ~root ~root_text)

let launch ~launch_review ~review_base ~version ~attach ~cwd ~overrides ~mode
    ~session ~last ~input =
  let reload = ref None in
  let first =
    Composition.with_base ?review_base ~cwd ~overrides (fun t ->
        match trust_gate t with
        | Error status -> status
        | Ok Stop -> Exit_status.Success
        | Ok Run ->
            launch_loaded ~launch_review ~version ~attach ~mode ~session ~last
              ~input t
        | Ok Reload ->
            reload :=
              Some
                ( User_dirs.trust_file (Composition.dirs t),
                  Composition.root t,
                  Lpath.Abs.to_string (Composition.root t) );
            Exit_status.Success)
  in
  match !reload with
  | None -> first
  | Some (path, root, root_text) ->
      launch_trusted ~launch_review ~review_base ~version ~attach ~cwd
        ~overrides ~mode ~session ~last ~input ~path ~root ~root_text

let launch_input draft prompt =
  match (draft, prompt) with
  | None, None -> Ok Mentat_tui.Startup.Empty
  | Some draft, None -> Ok (Mentat_tui.Startup.Draft draft)
  | None, Some prompt -> Ok (Mentat_tui.Startup.Submit prompt)
  | Some _, Some _ ->
      Error (Exit_status.usage "choose only one of --draft or --prompt")

let run version session last continue sandbox mode_raw draft prompt attach cwd =
  (* The interactive terminal owns the screen, so stderr logging would corrupt
     it. Divert before any launch path (trust prompt included) enters raw mode. *)
  Log_setup.divert_for_tui ~getenv:Sys.getenv_opt;
  match sandbox_overrides sandbox with
  | Error status -> status
  | Ok overrides -> (
      let mode =
        match mode_raw with
        | None -> Ok Mentat_session.Contract.Mode.Build
        | Some raw -> Argv.workflow_mode raw
      in
      match mode with
      | Error status -> status
      | Ok mode -> (
          match launch_input draft prompt with
          | Error status -> status
          | Ok input ->
              (* [-c]/[--continue] is [--last]: open the newest resumable
                 session in the workspace. *)
              launch ~launch_review:false ~review_base:None ~version ~attach
                ~cwd ~overrides ~mode ~session ~last:(last || continue) ~input))

let run_review version base attach cwd =
  Log_setup.divert_for_tui ~getenv:Sys.getenv_opt;
  (* [review_base] configures the review responder's base at composition build
     (Composition.with_base); it wins over MENTAT_REVIEW_BASE, which wins over
     the HEAD default. [None] leaves the default in force. *)
  launch ~launch_review:true ~review_base:base ~version ~attach ~cwd
    ~overrides:[] ~mode:Mentat_session.Contract.Mode.Build ~session:None
    ~last:false ~input:Mentat_tui.Startup.Empty

let session_option =
  let doc = "Open the TUI with session $(docv) loaded." in
  Arg.(value & opt (some string) None & info [ "session" ] ~docv:"SESSION" ~doc)

let draft_option =
  let doc = "Open the TUI with text $(docv) in the composer." in
  Arg.(value & opt (some string) None & info [ "draft" ] ~docv:"TEXT" ~doc)

let prompt_option =
  let doc =
    "Submit $(docv) as the first turn after the TUI starts. On a resumed \
     session, load it into the composer without submitting."
  in
  Arg.(
    value & opt (some string) None & info [ "p"; "prompt" ] ~docv:"TEXT" ~doc)

let continue_flag =
  let doc = "Resume the newest resumable session in the workspace." in
  Arg.(value & flag & info [ "c"; "continue" ] ~doc)

let sandbox_option =
  let doc =
    "Sandbox mode for this session: read-only, workspace-write, \
     danger-full-access, or external-sandbox."
  in
  Arg.(value & opt (some string) None & info [ "sandbox" ] ~docv:"MODE" ~doc)

let mode_option =
  let doc = "Workflow mode: build, plan, or review." in
  Arg.(value & opt (some string) None & info [ "mode" ] ~docv:"MODE" ~doc)

let default_term ~version =
  Exit_status.term
    Term.(
      const (run version)
      $ session_option $ Cli_common.last $ continue_flag $ sandbox_option
      $ mode_option $ draft_option $ prompt_option $ Cli_common.attach
      $ Cli_common.cwd)

let resume_session =
  let doc = "Session id or unique prefix to replay." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"SESSION" ~doc)

let resume_cmd ~version =
  let doc = "Resume a saved session in the interactive TUI." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Opens the interactive terminal on a saved session. Without a target, \
         opens Home; $(b,--last) selects the newest resumable session in the \
         workspace.";
    ]
  in
  Cmd.v
    (Cmd.info "resume" ~doc ~docs:Cli_common.s_run ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const (run version)
         $ resume_session $ Cli_common.last $ Term.const false $ sandbox_option
         $ mode_option $ draft_option $ prompt_option $ Cli_common.attach
         $ Cli_common.cwd))

let review_base =
  let doc = "Base revision to review the worktree against (default HEAD)." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"BASE" ~doc)

let review_cmd ~version =
  let doc = "Review the worktree diff against a base in the interactive TUI." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Opens the interactive terminal directly on the review screen over the \
         worktree diff against $(i,BASE) (default HEAD): a directory-grouped \
         nav, the selected file's diff, marks and a verdict, and inline CR \
         comments. Closing the review returns to the terminal.";
    ]
  in
  Cmd.v
    (Cmd.info "review" ~doc ~docs:Cli_common.s_run ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const (run_review version)
         $ review_base $ Cli_common.attach $ Cli_common.cwd))
