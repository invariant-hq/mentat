(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

type event = Opened | Resumed | Switched | Detached

(* A per-process identifier stamped on shared-sink lines and on the log and
   crash filenames, so a reader can pull one process's trail out of an
   interleaved file and correlate a crash report with its run by name. *)
let run_id =
  Printf.sprintf "%Ld-%d"
    (Int64.of_float (Unix.gettimeofday () *. 1_000_000.))
    (Unix.getpid ())

(* The frontend's active session, read by the reporter for the [s=] tag and by
   the crash writer for its header. An [Atomic] because the reporter may run on a
   worker domain while the frontend fiber updates it. *)
let breadcrumb : string option Atomic.t = Atomic.make None

(* Retained by [started] so a crash report written from deep in boot staging
   need not thread the version through every stage. *)
let noted_version : string option Atomic.t = Atomic.make None

(* The subcommand token [started] resolved. A crash is far more legible for
   knowing which command produced it, and the token is the one piece of argv
   that carries no user text. *)
let noted_command : string option Atomic.t = Atomic.make None

(* Where this process's own records are going, and whether the file is a shared
   sink other processes also append to. A crash report copies the tail so it
   travels alone; on a shared sink only this run's lines qualify, which is what
   the [run=] tag exists for. *)
let sink : (string * [ `Shared | `Private ]) option Atomic.t = Atomic.make None

let timestamp () =
  let now = Unix.gettimeofday () in
  let tm = Unix.localtime now in
  let ms = int_of_float (Float.rem now 1. *. 1000.) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec ms

let session_tag () =
  match Atomic.get breadcrumb with
  | None -> ""
  | Some id ->
      let short = if String.length id > 8 then String.sub id 0 8 else id in
      Printf.sprintf " [s=%s]" short

(* Format's own ceiling is [pp_infinity], 1e9 + 10; stay clear of it. *)
let unbounded_margin = 1_000_000_000

(* [run_tag] distinguishes the shared sinks (stderr, an explicit [MENTAT_LOG_FILE])
   — which interleave across processes and so carry [run=<run_id>] — from the
   per-run divert file, whose filename already is the run identity. Every message
   flushes so a crashed or killed process keeps its trail. *)
let reporter ~run_tag oc =
  let formatter = Format.formatter_of_out_channel oc in
  (* A log record is one physical line: every reader is line-oriented — grep,
     the session correlation in [debug session], a report bundle. Two Format
     defaults would break one across lines. A break hint fires once the 78-column
     margin is passed, and opening a box past [max_indent] (78 minus the ten
     columns Format reserves) forces a line break outright — which the
     shared-sink prefix alone exceeds, so every record split. Both ceilings are
     lifted rather than tuned, since no width is ever the right one here, and the
     message is printed outside any box. *)
  Format.pp_set_geometry formatter ~max_indent:(unbounded_margin - 1)
    ~margin:unbounded_margin;
  let pid = Unix.getpid () in
  let report src level ~over k msgf =
    let k _ =
      Format.pp_print_flush formatter ();
      over ();
      k ()
    in
    let run = if run_tag then Printf.sprintf " [run=%s]" run_id else "" in
    let prefix =
      Printf.sprintf "%s [%d]%s%s %s [%s] " (timestamp ()) pid run
        (session_tag ())
        (Format.asprintf "%a" Logs.pp_level level)
        (Logs.Src.name src)
    in
    msgf @@ fun ?header:_ ?tags:_ fmt ->
    Format.kfprintf k formatter ("%s" ^^ fmt ^^ "@.") prefix
  in
  { Logs.report }

let level_of_env ~getenv =
  match getenv "MENTAT_LOG" with
  | None -> Ok None
  | Some value -> (
      match Logs.level_of_string value with
      | Ok level -> Ok level
      | Error (`Msg message) ->
          (* Env-sourced, so the flag-provenance split classifies it as a
             runtime error, never usage: only flag-carried input exits 2. *)
          Error (Exit_status.runtime (Printf.sprintf "MENTAT_LOG: %s" message)))

(* [MENTAT_LOG] governs Mentat's own sources. Linked libraries declare their own,
   and theirs are not ours to publish: cohttp writes whole HTTP requests and
   responses at debug, bodies and the [Authorization] header included, which
   would put the conversation and the user's API key into the very file we ask
   people to attach to a bug report. They are held at [warning], where a
   transport or TLS fault still surfaces but no payload does. *)
let is_ours src =
  let name = Logs.Src.name src in
  String.equal name "mentat" || String.starts_with ~prefix:"mentat." name

let without_payloads = function
  | Some (Logs.Info | Logs.Debug) -> Some Logs.Warning
  | level -> level

(* The ceiling is the global level, so a source created after this point is
   quiet by default rather than loud — the failure mode a privacy rule wants.
   It preserves [None], so a [quiet] run stays wholly silent. *)
let set_level level =
  Logs.set_level ~all:true (without_payloads level);
  List.iter
    (fun src -> if is_ours src then Logs.Src.set_level src level)
    (Logs.Src.list ())

(* Append mode so concurrent processes and successive runs accumulate rather
   than truncate; the Unix strerror already names the path, so it needs no
   further prefix. *)
let open_log_file path =
  match open_out_gen [ Open_append; Open_creat ] 0o600 path with
  | oc -> Ok oc
  | exception Sys_error message -> Error (Exit_status.runtime message)

(* Whether the level was chosen deliberately — by [MENTAT_LOG] or by [-v] — so
   the terminal's own default does not quietly override a choice the user made.
   [MENTAT_LOG=quiet] resolves to no level at all, which is why presence of the
   variable is the test rather than the level it produced. *)
let chosen_level = Atomic.make false

let install ~getenv ~verbosity =
  Logs_threaded.enable ();
  let* from_env = level_of_env ~getenv in
  (* A flag beats the environment: someone typing [-v] is asking about the run
     in front of them, not about whatever their shell profile set. *)
  let level =
    match verbosity with
    | 0 -> from_env
    | 1 -> Some Logs.Info
    | _ -> Some Logs.Debug
  in
  if verbosity > 0 || Option.is_some (getenv "MENTAT_LOG") then
    Atomic.set chosen_level true;
  set_level level;
  match getenv "MENTAT_LOG_FILE" with
  | None ->
      Logs.set_reporter (reporter ~run_tag:true stderr);
      Ok ()
  | Some path when Filename.is_relative path ->
      Error
        (Exit_status.runtime
           (Printf.sprintf "MENTAT_LOG_FILE must be an absolute path: %s" path))
  | Some path ->
      let* oc = open_log_file path in
      Logs.set_reporter (reporter ~run_tag:true oc);
      Atomic.set sink (Some (path, `Shared));
      Ok ()

let src = Logs.Src.create "mentat.next" ~doc:"Executable lifecycle"

module Log = (val Logs.src_log src : Logs.LOG)

let started ~version ~argv =
  Atomic.set noted_version (Some version);
  (* Only the subcommand token: a positional argument can carry prompt text,
     which never belongs in a log. *)
  let command =
    if
      Array.length argv > 1
      && String.length argv.(1) > 0
      && not (Char.equal argv.(1).[0] '-')
    then argv.(1)
    else "(default)"
  in
  Atomic.set noted_command (Some command);
  Log.info (fun m -> m "mentat started version=%s command=%s" version command)

let event_word = function
  | Opened -> "opened"
  | Resumed -> "resumed"
  | Switched -> "switched"
  | Detached -> "detached"

let set_session ?event id =
  let previous = Atomic.exchange breadcrumb id in
  if not (Option.equal String.equal previous id) then
    let transition =
      match event with
      | Some event -> event
      | None -> (
          match (previous, id) with
          | Some _, Some _ -> Switched
          | _, None -> Detached
          | None, Some _ -> Opened)
    in
    (* The boundary line always carries the full id (info level): the session
       being left when detaching, the one being entered otherwise. *)
    let subject = match id with Some _ -> id | None -> previous in
    Option.iter
      (fun full ->
        Log.info (fun m -> m "session %s %s" full (event_word transition)))
      subject

let save_latest ~dir ~path =
  let latest = Filename.concat dir "latest.json" in
  let text =
    Output.Json.to_string
      (Output.Json.obj
         [
           ("run_id", Output.Json.string run_id);
           ("path", Output.Json.string path);
         ])
    ^ "\n"
  in
  ignore (Fs.atomic_write ~perms:0o644 latest text)

(* Keep the newest [keep] [.log] files, [current] always among them; shared by
   the logs and crashes directories, which both stamp [<run_id>.log], and by the
   daemon's own log, which rotates on spawn. *)
let retain_logs ~keep ~dir ~current =
  let entries =
    try
      Sys.readdir dir |> Array.to_list
      |> List.filter_map (fun name ->
          let path = Filename.concat dir name in
          if
            String.equal path current || not (Filename.check_suffix name ".log")
          then None
          else
            match Unix.stat path with
            | stat -> Some (stat.Unix.st_mtime, path)
            | exception Unix.Unix_error _ -> None)
      |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
    with Sys_error _ -> []
  in
  List.drop (Int.max 0 (keep - 1)) entries
  |> List.iter (fun (_, path) ->
      try Unix.unlink path with Unix.Unix_error _ | Sys_error _ -> ())

let divert_to_file ~getenv =
  (* Silence rather than leave the stderr reporter in place on any failure: the
     invariant is that no log byte reaches the terminal the TUI owns. A broken
     state home is reported by base staging, not here. *)
  let silence () = Logs.set_reporter Logs.nop_reporter in
  match User_dirs.resolve ~getenv with
  | Error _ -> silence ()
  | Ok dirs -> (
      let dir = Filename.concat (User_dirs.state_home dirs) "logs" in
      match Fs.mkdir_p dir with
      | Error _ -> silence ()
      | Ok () -> (
          let path = Filename.concat dir (run_id ^ ".log") in
          match open_log_file path with
          | Error _ -> silence ()
          | Ok oc ->
              Logs.set_reporter (reporter ~run_tag:false oc);
              Atomic.set sink (Some (path, `Private));
              save_latest ~dir ~path;
              retain_logs ~keep:20 ~dir ~current:path))

let divert_for_tui ~getenv =
  (* The TUI default level is info, because the session-boundary line that maps
     a truncated [s=] tag back to a full id is itself info: at warning the file
     records faults with nothing to attribute them to. Info adds the provider
     request/settle pair and a handful of once-per-process lines, which is why
     the private, rotated per-run file can afford it. A level the user chose,
     through MENTAT_LOG (including quiet) or [-v], wins. *)
  if not (Atomic.get chosen_level) then set_level (Some Logs.Info);
  match getenv "MENTAT_LOG_FILE" with
  | Some _ ->
      () (* an explicit shared-sink file is respected; the screen is safe *)
  | None -> (
      match Logs.level () with
      | None -> () (* quiet: nothing logs, so the screen needs no divert *)
      | Some _ -> divert_to_file ~getenv)

(* The records this run wrote, newest last, so a crash report is legible without
   its log file beside it — the file may have rotated away, or never have been
   kept at all. A shared sink interleaves processes, so it is filtered to this
   run's tag; the read is capped because the sink's size is not ours to bound. *)
let recent_records () =
  let keep = 40 in
  match Atomic.get sink with
  | None -> []
  | Some (path, ownership) -> (
      match Fs.read_capped ~max_bytes:(4 * 1024 * 1024) path with
      | Ok (Some contents) ->
          let lines =
            String.split_on_char '\n' contents
            |> List.filter (fun line -> not (String.equal line ""))
          in
          let lines =
            match ownership with
            | `Private -> lines
            | `Shared ->
                let tag = Printf.sprintf "[run=%s]" run_id in
                List.filter (String.includes ~affix:tag) lines
          in
          let surplus = List.length lines - keep in
          if surplus > 0 then List.drop surplus lines else lines
      | Ok None | Error _ -> [])

let write_crash_report ~version ~backtrace ~getenv =
  match User_dirs.resolve ~getenv with
  | Error _ -> None
  | Ok dirs -> (
      let dir = Filename.concat (User_dirs.state_home dirs) "crashes" in
      let path = Filename.concat dir (run_id ^ ".log") in
      let session = Option.value ~default:"-" (Atomic.get breadcrumb) in
      let or_dash = Option.value ~default:"-" in
      let trail =
        match recent_records () with
        | [] -> ""
        | records -> "\nrecent records:\n" ^ String.concat "\n" records ^ "\n"
      in
      let content =
        Printf.sprintf
          "mentat_version=%s\n\
           run_id=%s\n\
           pid=%d\n\
           session=%s\n\
           command=%s\n\
           term=%s\n\
           ocaml=%s\n\
           log=%s\n\
           %s\n\
           %s"
          version run_id (Unix.getpid ()) session
          (or_dash (Atomic.get noted_command))
          (or_dash (getenv "TERM"))
          Sys.ocaml_version
          (or_dash (Option.map fst (Atomic.get sink)))
          trail backtrace
      in
      match Fs.atomic_write ~perms:0o600 path content with
      | Error _ -> None
      | Ok () ->
          retain_logs ~keep:20 ~dir ~current:path;
          Some path)

let write_boot_failure_report ~message ~diagnostic ~getenv =
  let version = Option.value ~default:"unknown" (Atomic.get noted_version) in
  let body =
    match diagnostic with
    | Some trace -> message ^ "\n\n" ^ trace
    | None -> message ^ "\n"
  in
  write_crash_report ~version ~backtrace:body ~getenv
