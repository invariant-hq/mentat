(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status
module Fs = Mentat_boot.Fs
module Output = Mentat_boot.Output
module Session_meta = Mentat_boot.Session_meta

let docs = Cli_common.s_diagnostic

(* The bundle is NDJSON — one self-describing record per line — for the reason
   the session export is: a reader can stream it, skim it, and stop at the line
   it cares about. Records accumulate in memory and land in one atomic write, so
   a bundle is either whole or absent. *)
type builder = { lines : Buffer.t; mutable records : int }

let builder () = { lines = Buffer.create 8192; records = 0 }

let emit builder json =
  Buffer.add_string builder.lines (Output.Json.to_string json);
  Buffer.add_char builder.lines '\n';
  builder.records <- builder.records + 1

let record kind fields =
  Output.Json.obj (("record", Output.Json.string kind) :: fields)

(* The manifest closes the bundle the way the export's does: a count and a digest
   over the exact bytes of every preceding line, so a truncated bundle is
   detectable rather than silently short. *)
let seal builder =
  let body = Buffer.contents builder.lines in
  let digest = Mentat_digest.to_hex (Mentat_digest.string body) in
  let manifest =
    record "manifest"
      [
        ("records", Output.Json.int builder.records);
        ("digest", Output.Json.string ("sha256:" ^ digest));
      ]
  in
  body ^ Output.Json.to_string manifest ^ "\n"

(* Host facts a reader needs to reproduce a report and that no other record
   carries. [uname] is best-effort: the platform distinguishes a seatbelt sandbox
   from a bubblewrap one, which is worth a spawn in a diagnostic command, but its
   absence must not fail the bundle. *)
let uname () =
  match Unix.open_process_in "uname -sm 2>/dev/null" with
  | channel ->
      let line = try Some (input_line channel) with End_of_file -> None in
      ignore (Unix.close_process_in channel);
      line
  | exception (Unix.Unix_error _ | Sys_error _) -> None

(* Every string the bundle takes from outside this process goes through here: a
   file's bytes, a path, an environment value, the note the user typed. Any of
   them can hold a byte that is not valid UTF-8 — [TERM] is settable to anything,
   and a path may be arbitrary bytes on a filesystem that permits it — and one
   such byte would make the whole bundle unparseable while its manifest still
   verified over the bytes emitted. Substituting U+FFFD keeps the text readable
   and the bundle valid; callers that copy a whole file also report the
   substitution rather than presenting a lossy copy as faithful. *)
let scrub_utf_8 text =
  let buffer = Buffer.create (String.length text) in
  let lossy = ref false in
  let rec loop index =
    if index >= String.length text then (Buffer.contents buffer, !lossy)
    else
      let decode = String.get_utf_8_uchar text index in
      let uchar =
        if Uchar.utf_decode_is_valid decode then Uchar.utf_decode_uchar decode
        else (
          lossy := true;
          Uchar.rep)
      in
      Buffer.add_utf_8_uchar buffer uchar;
      loop (index + Uchar.utf_decode_length decode)
  in
  loop 0

let outside text = fst (scrub_utf_8 text)
let outside_json text = Output.Json.string (outside text)
let outside_or_null text = Output.Json.string_or_null (Option.map outside text)

let stamp now =
  let tm = Unix.gmtime now in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let header ~version ~kind ~note ~now =
  let env name = Sys.getenv_opt name in
  record "report"
    [
      ("schema_version", Output.Json.int 1);
      ("mentat_version", Output.Json.string version);
      ("kind", Output.Json.string kind);
      ("note", outside_or_null note);
      ("created_at", Output.Json.string (stamp now));
      ("platform", outside_or_null (uname ()));
      ("os_type", Output.Json.string Sys.os_type);
      ("ocaml", Output.Json.string Sys.ocaml_version);
      ("term", outside_or_null (env "TERM"));
      ("shell", outside_or_null (env "SHELL"));
      ("lang", outside_or_null (env "LANG"));
    ]

(* A diagnostic file is copied whole up to a cap: a log is the trail the crash
   report points at, and truncating its head would lose the boundary line that
   names the session. Unreadable is recorded as such rather than skipped, so the
   bundle never implies a file was empty when it could not be read. *)
let file_record kind ~max_bytes path =
  match Fs.read_capped ~max_bytes path with
  | Ok (Some raw) ->
      let content, lossy = scrub_utf_8 raw in
      record kind
        ([
           ("path", outside_json path);
           ("bytes", Output.Json.int (String.length raw));
           ("content", Output.Json.string content);
         ]
        @ if lossy then [ ("lossy", Output.Json.bool true) ] else [])
  | Ok None ->
      record kind
        [
          ("path", outside_json path);
          ("unavailable", Output.Json.string "missing");
        ]
  | Error message ->
      record kind
        [
          ("path", outside_json path);
          ("unavailable", Output.Json.string message);
        ]

let log_cap = 1024 * 1024
let crash_cap = 256 * 1024

(* The export bundle is a closed integrity envelope: its terminal manifest
   digests the exact bytes of every line before it, so interleaving its lines
   with the report's would destroy a proof the reader should be able to check.
   It is nested whole, base64 so the framing cannot collide, and a reader who
   decodes it gets back a bundle [mentat] itself would accept. *)
let export_record t ~session =
  let buffer = Buffer.create 65536 in
  let write chunk = Buffer.add_string buffer chunk in
  match
    Session_meta.with_fence ~store:(Composition.store t) ~sw:(Composition.sw t)
      ~clock:(Eio.Stdenv.clock (Composition.stdenv t))
      ~owner:(Composition.owner t) session (fun fence ->
        match
          Mentat_store.Export.write ~root:(Composition.store t) ~fence ~write
        with
        | Ok () -> Ok ()
        | Error (`Session e) ->
            Error (Session_meta.session_store_error_to_protocol session e)
        | Error (`Mutation e) ->
            Error
              (Mentat_protocol.Error.Unavailable
                 (Mentat_store.Mutation.Error.diagnostic ~session e)))
  with
  | Ok () ->
      let bytes = Buffer.contents buffer in
      record "session_export"
        [
          ("encoding", Output.Json.string "base64");
          ("bytes", Output.Json.int (String.length bytes));
          ("content", Output.Json.string (Base64.encode_string bytes));
        ]
  (* A fence that falls mid-export, or a damaged blob, is recorded rather than
     raised: a report that fails because one of its records could not be built
     would leave the user with nothing to send. *)
  | Error error ->
      record "session_export"
        [
          ( "unavailable",
            Output.Json.string
              (Mentat_diagnostic.to_string
                 (Mentat_protocol.Error.diagnostic error)) );
        ]
  | exception Invalid_argument message ->
      record "session_export" [ ("unavailable", Output.Json.string message) ]

(* Consent is asked once, before anything is written, and enumerates what the
   bundle will contain rather than asserting it is sanitized. It must describe
   the bundle as it actually is: the session record is a state projection, not a
   transcript, and saying otherwise would teach users to distrust the prompt. A
   non-terminal run must pass [--yes] — a scripted report that silently packaged
   a diagnostic file would be the same mistake in a different costume. *)
let disclosure ~session_included ~export_included ~files =
  let buffer = Buffer.create 512 in
  let add fmt = Printf.ksprintf (Buffer.add_string buffer) fmt in
  add "This report will contain:\n";
  add "  - your Mentat version, platform, terminal, and locale\n";
  if session_included then begin
    add "  - your effective configuration, with credentials redacted\n";
    add
      "  - the session's state and the paths of its stored files, not its \
       conversation\n"
  end;
  if export_included then
    add
      "  - the whole session: every prompt you wrote, every reply, and the \
       source and command output its tools returned\n";
  List.iter (fun path -> add "  - the contents of %s\n" path) files;
  add "Diagnostic files record what Mentat did, not what you asked.\n";
  if not export_included then
    add
      "The conversation itself is not collected; pass --with-session-export to \
       include it.\n";
  add
    "Credentials and your prompt history from other projects are never \
     included. Read it before you send it.\n";
  Buffer.contents buffer

let confirm ~yes ~session_included ~export_included ~files =
  if yes then true
  else if not (Unix.isatty Unix.stdin) then false
  else begin
    Output.stderr_printf "%s\nWrite this report? [y/N] "
      (disclosure ~session_included ~export_included ~files);
    match String.lowercase_ascii (String.trim (input_line stdin)) with
    | "y" | "yes" -> true
    | _ | (exception End_of_file) -> false
  end

(* The readiness picture comes from a probe, which never aborts, so a report
   carries it even when a later stage is the thing that failed. Sequential with
   the base staging below, never nested: each owns its own Eio run. *)
let probe_record ~cwd =
  let captured = ref None in
  ignore
    (Composition.with_probe ~cwd (fun probe ->
         captured := Some (Cli_doctor.probe_checks_json probe);
         Exit_status.Success));
  match !captured with
  | Some checks -> record "doctor" [ ("checks", checks) ]
  | None ->
      record "doctor"
        [ ("unavailable", Output.Json.string "the probe did not run") ]

let default_name ~now ~session =
  let tm = Unix.localtime now in
  let suffix =
    match session with
    | None -> "environment"
    | Some id ->
        let text = Mentat_session.Id.to_string id in
        if String.length text > 8 then String.sub text 0 8 else text
  in
  Printf.sprintf "mentat-report-%04d%02d%02d-%s.ndjson" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday suffix

let write ~output content =
  match output with
  | Some "-" ->
      Output.stdout_printf "%s" content;
      Ok None
  | Some path ->
      Result.map
        (fun () -> Some path)
        (Fs.atomic_write ~perms:0o600 path content)
  | None -> Ok None

(* The environment-only report: no session, and deliberately no composition, so
   an install too broken to stage a store can still produce one. That is exactly
   the user who most needs to file a report. *)
let environment_only ~version ~kind ~note ~output ~yes ~cwd =
  let now = Unix.gettimeofday () in
  if not (confirm ~yes ~session_included:false ~export_included:false ~files:[])
  then Exit_status.runtime "report declined"
  else
    let builder = builder () in
    emit builder (header ~version ~kind ~note ~now);
    emit builder (probe_record ~cwd);
    let path =
      match output with
      | Some path -> Some path
      | None -> Some (default_name ~now ~session:None)
    in
    match write ~output:path (seal builder) with
    | Error message -> Exit_status.runtime message
    | Ok None -> Exit_status.Success
    | Ok (Some path) ->
        Output.stderr_printf "report written: %s\n" path;
        Exit_status.Success

let session_report ~version ~kind ~note ~output ~yes ~with_export ~session ~last
    ~cwd =
  let doctor = probe_record ~cwd in
  Composition.with_base ~cwd ~overrides:[] (fun t ->
      match Session_locate.resolve t ~session ~last with
      | Error error -> Session_locate.status error
      | Ok document -> (
          let projection, logs, crashes = Cli_debug.session_bundle t document in
          if
            not
              (confirm ~yes ~session_included:true ~export_included:with_export
                 ~files:(logs @ crashes))
          then Exit_status.runtime "report declined"
          else
            let now = Unix.gettimeofday () in
            let builder = builder () in
            emit builder (header ~version ~kind ~note ~now);
            emit builder doctor;
            emit builder
              (record "config" [ ("config", Cli_config.resolved_json t) ]);
            emit builder (record "session" [ ("session", projection) ]);
            if with_export then
              emit builder
                (export_record t
                   ~session:(Mentat_store.Session.Document.id document));
            List.iter
              (fun path ->
                emit builder (file_record "log" ~max_bytes:log_cap path))
              logs;
            List.iter
              (fun path ->
                emit builder (file_record "crash" ~max_bytes:crash_cap path))
              crashes;
            let id = Mentat_store.Session.Document.id document in
            let path =
              match output with
              | Some path -> Some path
              | None -> Some (default_name ~now ~session:(Some id))
            in
            match write ~output:path (seal builder) with
            | Error message -> Exit_status.runtime message
            | Ok None -> Exit_status.Success
            | Ok (Some path) ->
                Output.stderr_printf "report written: %s\n" path;
                Exit_status.Success))

let kinds = [ "bug"; "crash"; "question"; "feature" ]

let run version kind note output yes with_export no_session session last cwd =
  if not (List.mem kind kinds) then
    Exit_status.usage
      (Printf.sprintf "unknown report kind %s; expected %s" kind
         (String.concat ", " kinds))
  else if no_session && (Option.is_some session || last) then
    Exit_status.usage "--no-session takes no session target"
  else if no_session && with_export then
    Exit_status.usage "--with-session-export needs a session"
  else if no_session then
    environment_only ~version ~kind ~note ~output ~yes ~cwd
  else
    session_report ~version ~kind ~note ~output ~yes ~with_export ~session ~last
      ~cwd

let kind_opt =
  Arg.(
    value & opt string "bug"
    & info [ "kind" ] ~docv:"KIND"
        ~doc:
          "What the report is about: $(b,bug), $(b,crash), $(b,question), or \
           $(b,feature).")

let note_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "note" ] ~docv:"TEXT"
        ~doc:"A short description of what happened, recorded in the report.")

let output_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "o"; "output" ] ~docv:"FILE"
        ~doc:"Write the report to FILE, or to standard output for $(b,-).")

let yes_opt =
  Arg.(
    value & flag
    & info [ "yes" ]
        ~doc:
          "Skip the confirmation. Required when standard input is not a \
           terminal.")

let with_export_opt =
  Arg.(
    value & flag
    & info [ "with-session-export" ]
        ~doc:
          "Include the whole session — every prompt, reply, and tool result — \
           as a nested export bundle. It is the most useful attachment and the \
           most revealing; read it before sending.")

let no_session_opt =
  Arg.(
    value & flag
    & info [ "no-session" ]
        ~doc:
          "Report the environment only, without a session. Works even when the \
           session store cannot be opened.")

let cmd ~version =
  let doc = "Package a bug report." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Collects what a maintainer needs to diagnose a problem into one \
         NDJSON file: the Mentat version and platform, the session's state and \
         on-disk artifacts, and the diagnostics logs and crash reports whose \
         records name that session.";
      `P
        "The bundle contains your conversation. It never contains credentials \
         or your prompt history from other projects. Mentat asks before \
         writing it, and uploads nothing.";
    ]
  in
  Cmd.v
    (Cmd.info "report" ~doc ~docs ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const (run version)
         $ kind_opt $ note_opt $ output_opt $ yes_opt $ with_export_opt
         $ no_session_opt $ Cli_common.session_arg $ Cli_common.last
         $ Cli_common.cwd))
