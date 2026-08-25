(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Public-boundary integration tests for OCaml evaluator. Every
   effectful case crosses the real declaration, provider decoder, cached
   permission request, erased result/output boundary, workspace capability,
   and [Workspace_io.Command] supervisor. The scripted Dune program is a real
   child and protocol peer: it records cwd, argv, and exact stdin, then performs
   one deterministic behavior selected by invocation number.

   Coverage retained from the legacy suite: Dune project context, the
   package-managed toplevel route, exact command-confinement facts, strict
   unknown-member rejection, cancellation, total timeout, and setup failures.
   Coverage added here: JSON safe integers and policy bounds; constructor
   invariants; duplicate-member rejection; default-root and nested-cwd
   addressing; exact two-phase framing and fresh-call count; setup stdout
   completeness; setup stderr drain independence; both-phase exit, signal,
   spawn, timeout, and stop taxonomy; exact structural head/tail capture
   boundaries; invalid UTF-8 repair; ANSI preservation; incomplete pipe drains;
   and versioned D2-safe durable replay.

   A deterministic child cannot make an OS pipe read or supervision primitive
   fail after spawn. [Command.Supervision_failed] injection belongs to the real
   process-supervisor suite; this suite still pins Eval's public rendering and
   classification for every child-controlled terminal cause. *)

open Windtrap
open Test_tools_support
module Access = Mentat_permission.Access
module Eval = Mentat_tools.Ocaml.Eval
module Json = Jsont.Json
module Permission = Mentat_permission
module Tool = Mentat_tool
module Wio = Mentat_workspace_io
module Workspace = Mentat_workspace

type cwd = Root | Nested

type world = {
  sw : Eio.Switch.t;
  ws_dir : string;
  outside_dir : string;
  plan_dir : string;
  io : Wio.t;
  tool : Tool.t;
}

let input ?dir ?timeout_ms code =
  let fields = [ ("code", Json.string code) ] in
  let fields =
    match dir with
    | None -> fields
    | Some dir -> fields @ [ ("dir", Json.string dir) ]
  in
  let fields =
    match timeout_ms with
    | None -> fields
    | Some timeout_ms -> fields @ [ ("timeout_ms", Json.int timeout_ms) ]
  in
  json_object fields

let process_exn result =
  match
    Mentat_tools_output.Codec.decode Mentat_tools_output.Process.jsont
      (output_exn result)
  with
  | Some process -> process
  | None -> fail "ocaml_eval output carried no process semantics"

let decode_call_result tool provider_input =
  Tool.Call.decode tool (model_call tool provider_input)

let decode_call tool provider_input =
  match decode_call_result tool provider_input with
  | Ok call -> call
  | Error error ->
      failf "call decode failed: %s" (Tool.Call.Decode_error.message error)

let run_call ?(cancelled = fun () -> false) call =
  Tool.Call.run call ~cancelled |> finished

let run ?cancelled world provider_input =
  run_call ?cancelled (decode_call world.tool provider_input)

let print_status ?(normalize = Fun.id) result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> print_endline "status: completed"
  | Tool.Result.Failed { kind; message; metadata } ->
      Printf.printf "status: failed %s\nmessage: %s\nmetadata: %b\n"
        (failure_name kind) (normalize message) (Option.is_some metadata)
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "status: interrupted cancelled=%b\nreason: %s\n" cancelled
        reason

let write_disk path contents =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel contents)

let fake_dune_script =
  String.concat "\n"
    [
      "#!/bin/sh";
      "plan=$1";
      "shift";
      "count_file=$plan/count";
      "if [ -f \"$count_file\" ]; then n=$(cat \"$count_file\"); else n=0; fi";
      "n=$((n + 1))";
      "printf '%s' \"$n\" > \"$count_file\"";
      "pwd > \"$plan/cwd-$n\"";
      "printf '%s\\n' \"$@\" > \"$plan/argv-$n\"";
      "cat > \"$plan/stdin-$n\"";
      "behavior=response";
      "if [ -f \"$plan/behavior-$n\" ]; then behavior=$(cat \
       \"$plan/behavior-$n\"); fi";
      ": > \"$plan/started-$n\"";
      "response=$plan/response-$n";
      "error=$plan/stderr-$n";
      "case \"$behavior\" in";
      "  response)";
      "    [ ! -f \"$response\" ] || cat \"$response\"";
      "    [ ! -f \"$error\" ] || cat \"$error\" >&2";
      "    [ ! -f \"$plan/cancel-after-$n\" ] || : > \"$plan/cancel-now\"";
      "    ;;";
      "  wait_release)";
      "    while [ ! -f \"$plan/release-$n\" ]; do /bin/sleep 0.01; done";
      "    [ ! -f \"$response\" ] || cat \"$response\"";
      "    ;;";
      "  exit7)";
      "    printf 'before-exit\\n'";
      "    printf '\\033[31mcompiler failed\\033[0m\\n' >&2";
      "    exit 7";
      "    ;;";
      "  response_exit7)";
      "    [ ! -f \"$response\" ] || cat \"$response\"";
      "    [ ! -f \"$error\" ] || cat \"$error\" >&2";
      "    exit 7";
      "    ;;";
      "  signal) printf 'before-signal\\n'; kill -TERM $$ ;;";
      "  sleep) printf 'before-sleep\\n'; exec /bin/sleep 60 ;;";
      "  remove_self)";
      "    [ ! -f \"$response\" ] || cat \"$response\"";
      "    rm \"$0\"";
      "    ;;";
      "  head_tail)";
      "    /usr/bin/head -c 70000 /dev/zero | /usr/bin/tr '\\0' O";
      "    /usr/bin/head -c 70000 /dev/zero | /usr/bin/tr '\\0' E >&2";
      "    ;;";
      "  large_stdout)";
      "    /usr/bin/head -c 70000 /dev/zero | /usr/bin/tr '\\0' D";
      "    ;;";
      "  large_stderr)";
      "    [ ! -f \"$response\" ] || cat \"$response\"";
      "    /usr/bin/head -c 70000 /dev/zero | /usr/bin/tr '\\0' W >&2";
      "    ;;";
      "  incomplete)";
      "    [ ! -f \"$response\" ] || cat \"$response\"";
      "    ( /bin/sleep 3 ) &";
      "    ;;";
      "  incomplete_stderr)";
      "    [ ! -f \"$response\" ] || cat \"$response\"";
      "    ( exec >/dev/null; /bin/sleep 3 ) &";
      "    ;;";
      "  *) printf 'unknown behavior: %s\\n' \"$behavior\" >&2; exit 64 ;;";
      "esac";
      "";
    ]

let workspace ~cwd ws_dir =
  let root = Workspace.Root.of_dir (Lpath.Abs.of_string_exn ws_dir) in
  match cwd with
  | Root -> Workspace.single root
  | Nested -> (
      let current =
        Workspace.Path.make ~root_key:(Workspace.Root.key root)
          (Lpath.Rel.of_string_exn "logical")
      in
      match Workspace.make ~cwd:current ~primary:root ~read_only:[] () with
      | Ok workspace -> workspace
      | Error error ->
          failf "workspace construction failed: %a" Workspace.Error.pp error)

let with_world ?(cwd = Root) ?(mode = Mentat_config.Mode.Danger_full_access)
    ?clock ?program name fn =
  Eio_main.run @@ fun stdenv ->
  let stdenv = (stdenv :> Eio_unix.Stdenv.base) in
  let base = Unix.realpath (temp_dir ~prefix:("mentat-eval-" ^ name) ()) in
  let ws_dir = Filename.concat base "workspace" in
  let outside_dir = Filename.concat base "outside" in
  let tmp_dir = Filename.concat base "tmp" in
  let plan_dir = Filename.concat ws_dir ".eval-plan" in
  List.iter mkdir [ ws_dir; outside_dir; tmp_dir; plan_dir ];
  List.iter
    (fun path -> mkdir_p (Filename.concat ws_dir path))
    [ "logical/project"; "project" ];
  write_disk (Filename.concat ws_dir "not-a-dir") "file\n";
  Unix.symlink outside_dir (Filename.concat ws_dir "outside-link");
  let fake = Filename.concat ws_dir "fake-dune" in
  install_executable fake fake_dune_script;
  setenv "TMPDIR" (Some tmp_dir);
  Eio.Switch.run @@ fun sw ->
  let logical = workspace ~cwd ws_dir in
  let io = resolve_exn ~sw ~stdenv ~logical ~mode () in
  let program = Option.value program ~default:[ fake; plan_dir ] in
  let tool =
    match clock with
    | None -> Eval.make io ~clock:(Eio.Stdenv.mono_clock stdenv) ~program ()
    | Some clock -> Eval.make io ~clock ~program ()
  in
  fn { sw; ws_dir; outside_dir; plan_dir; io; tool }

let plan_file world stem index =
  Filename.concat world.plan_dir (Printf.sprintf "%s-%d" stem index)

let set_response world index response =
  write_disk (plan_file world "response" index) response

let set_stderr world index stderr =
  write_disk (plan_file world "stderr" index) stderr

let set_behavior world index behavior =
  write_disk (plan_file world "behavior" index) behavior

let started world index = Sys.file_exists (plan_file world "started" index)

let invocation_count world =
  match read_disk (Filename.concat world.plan_dir "count") with
  | text -> int_of_string text
  | exception Sys_error _ -> 0

let invocation world stem index = read_disk (plan_file world stem index)

let normalize world text =
  text
  |> String.replace_all ~sub:world.outside_dir ~by:"<outside>"
  |> String.replace_all ~sub:world.ws_dir ~by:"<workspace>"

let decode_verdict tool label provider_input =
  match decode_call_result tool provider_input with
  | Ok call ->
      Printf.printf "%s: accepted canonical=%s\n" label
        (json_string (Tool.Call.input call))
  | Error error ->
      Printf.printf "%s: rejected diagnostic=%b\n" label
        (not (String.is_empty (Tool.Call.Decode_error.message error)))

let line_value prefix result =
  let text = Tool.Output.text (output_exn result) in
  let line =
    String.split_on_char '\n' text
    |> List.find_opt (String.starts_with ~prefix)
    |> Option.value ~default:("<missing " ^ prefix ^ ">")
  in
  String.sub line (String.length prefix)
    (String.length line - String.length prefix)
  |> String.trim

(* XXX: Use ocaml 5.5 string api here (and scan for other such functions that should use the stdlib) *)
let find_substring ~from needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop index =
    if index + needle_length > haystack_length then None
    else if String.equal (String.sub haystack index needle_length) needle then
      Some index
    else loop (index + 1)
  in
  loop from

let captured_rendered result stream =
  let text = Tool.Output.text (output_exn result) in
  let stdout_marker = "\nstdout:\n" in
  let stderr_marker = "\nstderr:\n" in
  match (stream, find_substring ~from:0 stdout_marker text) with
  | "stdout", Some stdout_at -> (
      let first = stdout_at + String.length stdout_marker in
      match find_substring ~from:first stderr_marker text with
      | Some last -> String.sub text first (last - first)
      | None -> fail "ocaml_eval text carried no stderr marker")
  | "stderr", Some stdout_at -> (
      let after_stdout = stdout_at + String.length stdout_marker in
      match find_substring ~from:after_stdout stderr_marker text with
      | Some stderr_at ->
          let first = stderr_at + String.length stderr_marker in
          String.sub text first (String.length text - first)
      | None -> fail "ocaml_eval text carried no stderr marker")
  | ("stdout" | "stderr"), None ->
      fail "ocaml_eval text carried no stdout marker"
  | stream, _ -> failf "unknown captured stream %S" stream

let termination_name = function
  | Mentat_tools_output.Process.Exited _ -> "exited"
  | Mentat_tools_output.Process.Signaled _ -> "signaled"
  | Mentat_tools_output.Process.Timed_out -> "timed_out"
  | Mentat_tools_output.Process.Stopped -> "stopped"
  | Mentat_tools_output.Process.Output_limit _ -> "output_limit"
  | Mentat_tools_output.Process.Supervision_failed -> "supervision_failed"

let print_output_summary result =
  let output = output_exn result in
  let process = process_exn result in
  Printf.printf
    "output: stage=%s termination=%s timeout=%s duration_nonnegative=%b \
     truncated=%b\n"
    (line_value "Stage:" result)
    (termination_name (Mentat_tools_output.Process.termination process))
    (line_value "Timeout:" result)
    (Mentat_tools_output.Process.duration_ms process >= 0)
    (Tool.Output.truncated output)

let%expect_test "declaration and provider input are exact, bounded, and safe" =
  with_world "schema" @@ fun world ->
  let declaration = Tool.declaration world.tool in
  Printf.printf "name: %s\n" (Mentat_llm.Tool.name declaration);
  Printf.printf "schema: %s\n"
    (json_string (Mentat_llm.Tool.input_schema declaration));
  decode_verdict world.tool "minimal" (input "1 + 1");
  decode_verdict world.tool "full"
    (input ~dir:"project" ~timeout_ms:120_000 "1 + 1;;");
  List.iter
    (fun (label, provider_input) ->
      decode_verdict world.tool label provider_input)
    [
      ("missing code", json_object []);
      ( "unknown member",
        json_object [ ("code", Json.string "1"); ("x", Json.bool true) ] );
      ("non-object input", Json.array [||]);
      ( "duplicate code",
        json_object
          [ ("code", Json.string "first"); ("code", Json.string "second") ] );
      ( "duplicate timeout",
        json_object
          [
            ("code", Json.string "1");
            ("timeout_ms", Json.int 1);
            ("timeout_ms", Json.int 2);
          ] );
      ("whitespace code", input " \n");
      ("empty code", input "");
      ("NUL code", input "x\x00y");
      ("code type", json_object [ ("code", Json.int 1) ]);
      ("empty dir", input ~dir:"" "1");
      ("NUL dir", input ~dir:"x\x00y" "1");
      ("timeout zero", input ~timeout_ms:0 "1");
      ("timeout negative", input ~timeout_ms:(-1) "1");
      ( "timeout string",
        json_object
          [ ("code", Json.string "1"); ("timeout_ms", Json.string "10") ] );
      ( "timeout fraction",
        json_object
          [ ("code", Json.string "1"); ("timeout_ms", Json.number 1.5) ] );
      ( "timeout largest safe",
        json_object
          [
            ("code", Json.string "1");
            ("timeout_ms", Json.number 9_007_199_254_740_991.);
          ] );
      ( "timeout unsafe",
        json_object
          [
            ("code", Json.string "1");
            ("timeout_ms", Json.number 9_007_199_254_740_992.);
          ] );
      ( "timeout infinity",
        json_object
          [ ("code", Json.string "1"); ("timeout_ms", Json.number infinity) ] );
    ];
  [%expect
    {|
    name: ocaml_eval
    schema: {"type":"object","properties":{"code":{"type":"string","description":"Non-empty OCaml toplevel phrase text to evaluate in a fresh process.","minLength":1},"dir":{"type":"string","description":"Workspace-relative or workspace-contained absolute Dune project directory. Defaults to the root owning the workspace current directory.","minLength":1},"timeout_ms":{"type":"integer","description":"Optional total setup-and-evaluation timeout in milliseconds, bounded by host policy.","minimum":1,"maximum":9007199254740991}},"required":["code"],"additionalProperties":false}
    minimal: accepted canonical={"code":"1 + 1"}
    full: accepted canonical={"code":"1 + 1;;","dir":"project","timeout_ms":120000}
    missing code: rejected diagnostic=true
    unknown member: rejected diagnostic=true
    non-object input: rejected diagnostic=true
    duplicate code: rejected diagnostic=true
    duplicate timeout: rejected diagnostic=true
    whitespace code: accepted canonical={"code":" \n"}
    empty code: rejected diagnostic=true
    NUL code: rejected diagnostic=true
    code type: rejected diagnostic=true
    empty dir: rejected diagnostic=true
    NUL dir: rejected diagnostic=true
    timeout zero: rejected diagnostic=true
    timeout negative: rejected diagnostic=true
    timeout string: rejected diagnostic=true
    timeout fraction: rejected diagnostic=true
    timeout largest safe: accepted canonical={"code":"1","timeout_ms":9007199254740991}
    timeout unsafe: rejected diagnostic=true
    timeout infinity: rejected diagnostic=true
    |}]

let print_permissions call =
  let requests = Tool.Call.permissions call in
  Printf.printf "requests: %d\n" (List.length requests);
  List.iter
    (fun request ->
      Printf.printf "source: %s display: %s\n"
        (Option.value ~default:"none" (Permission.Request.source request))
        (Option.value ~default:"none" (Permission.Request.display request));
      List.iter
        (function
          | Access.Custom { name; subject } ->
              Printf.printf "custom: name=%s subject=%s\n" name
                (Option.value ~default:"none" subject)
          | access -> failf "unexpected Eval permission: %a" Access.pp access)
        (Permission.Request.accesses request))
    requests

let%expect_test "permissions are one cached command-confinement fact" =
  with_world "permission-direct" @@ fun direct ->
  let call = decode_call direct.tool (input ~dir:"missing" "1 + 1") in
  print_endline "-- direct --";
  print_permissions call;
  write_disk (Filename.concat direct.ws_dir "unrelated") "changed";
  print_endline "-- cached --";
  print_permissions call;
  with_world ~mode:Mentat_config.Mode.External_sandbox "permission-external"
  @@ fun external_world ->
  print_endline "-- external --";
  print_permissions (decode_call external_world.tool (input "1 + 1"));
  [%expect
    {|
    -- direct --
    requests: 1
    source: ocaml_eval display: none
    custom: name=command.confinement subject=direct
    -- cached --
    requests: 1
    source: ocaml_eval display: none
    custom: name=command.confinement subject=direct
    -- external --
    requests: 1
    source: ocaml_eval display: none
    custom: name=command.confinement subject=external
    |}]

let%expect_test "two real phases receive exact cwd argv stdin and defaults" =
  with_world "transport" @@ fun world ->
  let directives =
    "#directory \"_build/default/lib\";;\n#load \"fixture.cma\";;\n"
  in
  set_response world 1 directives;
  set_response world 2
    "Error: provider text is not a status protocol\nvalue: 42\n";
  set_stderr world 2 "Warning 99: fixture warning\n";
  let result = run world (input "Fixture.answer + 1") in
  print_status result;
  print_output_summary result;
  Printf.printf "invocations: %d\n" (invocation_count world);
  Printf.printf "cwd-1: %s\ncwd-2: %s\n"
    (normalize world (String.trim (invocation world "cwd" 1)))
    (normalize world (String.trim (invocation world "cwd" 2)));
  Printf.printf "argv-1: %S\nargv-2: %S\n"
    (invocation world "argv" 1)
    (invocation world "argv" 2);
  Printf.printf "stdin-1-empty: %b\nstdin-2: %S\n"
    (String.is_empty (invocation world "stdin" 1))
    (invocation world "stdin" 2);
  Printf.printf "stdout: %S\nstderr: %S\n"
    (captured_rendered result "stdout")
    (captured_rendered result "stderr");
  [%expect
    {|
    status: completed
    output: stage=eval termination=exited timeout=10000ms duration_nonnegative=true truncated=false
    invocations: 2
    cwd-1: <workspace>
    cwd-2: <workspace>
    argv-1: "ocaml\ntop\n.\n"
    argv-2: "exec\n--\nocaml\n-stdin\n-noinit\n"
    stdin-1-empty: true
    stdin-2: "#directory \"_build/default/lib\";;\n#load \"fixture.cma\";;\nFixture.answer + 1\n;;\n\n#quit;;\n"
    stdout: "Error: provider text is not a status protocol\nvalue: 42\n"
    stderr: "Warning 99: fixture warning\n"
    |}]

let%expect_test "explicit nested directories and phrase terminators are exact" =
  with_world ~cwd:Nested "directory" @@ fun world ->
  set_response world 1 "#directory \"nested\";;\n";
  set_response world 2 "done\n";
  let terminated = run world (input ~dir:"project" "let x = 1;;\n") in
  print_status terminated;
  print_output_summary terminated;
  Printf.printf "address: %s\ncwd: %s\nstdin: %S\n"
    (line_value "Directory:" terminated |> normalize world)
    (normalize world (String.trim (invocation world "cwd" 2)))
    (invocation world "stdin" 2);
  [%expect
    {|
    status: completed
    output: stage=eval termination=exited timeout=10000ms duration_nonnegative=true truncated=false
    address: project
    cwd: <workspace>/logical/project
    stdin: "#directory \"nested\";;\nlet x = 1;;\n\n#quit;;\n"
    |}]

let%expect_test "each call reloads directives in a fresh default-root process" =
  with_world ~cwd:Nested "fresh" @@ fun world ->
  set_response world 1 "#directory \"first\";;\n";
  set_response world 2 "first\n";
  set_response world 3 "#directory \"second\";;";
  set_response world 4 "second\n";
  let first = run world (input "let state = 1;;\n") in
  let second = run world (input "state") in
  print_status first;
  print_status second;
  Printf.printf "invocations: %d\n" (invocation_count world);
  Printf.printf "addresses: %s | %s\n"
    (line_value "Directory:" first |> normalize world)
    (line_value "Directory:" second |> normalize world);
  Printf.printf "setup-cwds: %s | %s\n"
    (invocation world "cwd" 1 |> String.trim |> normalize world)
    (invocation world "cwd" 3 |> String.trim |> normalize world);
  Printf.printf "first-stdin: %S\nsecond-stdin: %S\n"
    (invocation world "stdin" 2)
    (invocation world "stdin" 4);
  Printf.printf "outputs: %S | %S\n"
    (captured_rendered first "stdout")
    (captured_rendered second "stdout");
  [%expect
    {|
    status: completed
    status: completed
    invocations: 4
    addresses: <workspace> | <workspace>
    setup-cwds: <workspace> | <workspace>
    first-stdin: "#directory \"first\";;\nlet state = 1;;\n\n#quit;;\n"
    second-stdin: "#directory \"second\";;\nstate\n;;\n\n#quit;;\n"
    outputs: "first\n" | "second\n"
    |}]

let%expect_test "evaluation runs in a real temporary Dune library context" =
  with_world ~program:[ "dune" ] "real-dune" @@ fun world ->
  write_disk
    (Filename.concat world.ws_dir "dune-project")
    "(lang dune 3.0)\n(name fixture)\n";
  write_disk
    (Filename.concat world.ws_dir "lib/dune")
    "(library (name fixture_lib))\n";
  write_disk
    (Filename.concat world.ws_dir "lib/fixture_lib.ml")
    "let answer = 42\n";
  let result =
    run world
      (input ~dir:"lib" {|Printf.printf "%d\n%!" (Fixture_lib.answer + 1)|})
  in
  print_status result;
  let stdout = captured_rendered result "stdout" in
  Printf.printf "stage: %s\n" (line_value "Stage:" result);
  Printf.printf "directory: %s\n" (line_value "Directory:" result);
  Printf.printf "library answer: %b\n"
    (String.split_on_char '\n' stdout |> List.exists (String.equal "43"));
  Printf.printf "truncated: %b\n" (Tool.Output.truncated (output_exn result));
  [%expect
    {|
    status: completed
    stage: eval
    directory: lib
    library answer: true
    truncated: false
    |}]

let%expect_test "setup failures preserve bounded UTF-8 and ANSI transcripts" =
  with_world "setup-exit" @@ fun exited ->
  set_behavior exited 1 "exit7";
  let exit_result = run exited (input "1") in
  print_endline "-- exit --";
  print_status exit_result;
  print_output_summary exit_result;
  let exit_stderr = captured_rendered exit_result "stderr" in
  Printf.printf "ansi-preserved: %b utf8: %b invocations: %d\n"
    (String.contains exit_stderr '\x1b')
    (String.is_valid_utf_8 exit_stderr)
    (invocation_count exited);
  with_world "setup-signal" @@ fun signaled ->
  set_behavior signaled 1 "signal";
  let signal_result = run signaled (input "1") in
  print_endline "-- signal --";
  (match Tool.Result.status signal_result with
  | Tool.Result.Failed { kind = `Failed; message; metadata } ->
      Printf.printf "status: failed failed diagnostic=%b metadata=%b\n"
        (not (String.is_empty message))
        (Option.is_some metadata)
  | Tool.Result.Failed { kind; _ } ->
      failf "setup signal had failure kind %s" (failure_name kind)
  | Tool.Result.Completed -> fail "signaled setup unexpectedly completed"
  | Tool.Result.Interrupted _ ->
      fail "signaled setup was unexpectedly interrupted");
  print_output_summary signal_result;
  Printf.printf "invocations: %d\n" (invocation_count signaled);
  with_world "setup-timeout" @@ fun timed_out ->
  set_behavior timed_out 1 "sleep";
  let timeout_result = run timed_out (input ~timeout_ms:50 "1") in
  print_endline "-- timeout --";
  print_status timeout_result;
  print_output_summary timeout_result;
  Printf.printf "at most one setup invocation: %b\n"
    (invocation_count timed_out <= 1);
  with_world ~program:[ "/mentat-eval-expect/no-such-program" ] "setup-spawn"
  @@ fun spawn ->
  let spawn_result = run spawn (input "1") in
  print_endline "-- spawn --";
  (match Tool.Result.status spawn_result with
  | Tool.Result.Failed { kind = `Unavailable; message; metadata } ->
      Printf.printf "status: failed unavailable diagnostic=%b metadata=%b\n"
        (not (String.is_empty message))
        (Option.is_some metadata)
  | Tool.Result.Failed { kind; _ } ->
      failf "setup spawn had failure kind %s" (failure_name kind)
  | Tool.Result.Completed -> fail "setup spawn unexpectedly completed"
  | Tool.Result.Interrupted _ -> fail "setup spawn was unexpectedly interrupted");
  Printf.printf "output: %b invocations: %d\n"
    (Option.is_some (Tool.Result.output spawn_result))
    (invocation_count spawn);
  with_world "setup-invalid" @@ fun invalid ->
  set_behavior invalid 1 "response_exit7";
  set_response invalid 1 "\xffbad directives\n";
  let invalid_result = run invalid (input "1") in
  print_endline "-- invalid UTF-8 directives --";
  print_status invalid_result;
  print_output_summary invalid_result;
  Printf.printf "repaired: %b replacement: %b invocations: %d\n"
    (String.is_valid_utf_8 (captured_rendered invalid_result "stdout"))
    (String.includes ~affix:"\239\191\189"
       (captured_rendered invalid_result "stdout"))
    (invocation_count invalid);
  with_world "setup-large" @@ fun large ->
  set_behavior large 1 "large_stdout";
  let large_result = run large (input "1") in
  print_endline "-- incomplete directives --";
  print_status large_result;
  print_output_summary large_result;
  Printf.printf "stdout-bytes: %d invocations: %d\n"
    (String.length (captured_rendered large_result "stdout"))
    (invocation_count large);
  [%expect
    {|
    -- exit --
    status: failed failed
    message: OCaml eval dune_top exited with status 7
    metadata: false
    output: stage=dune_top termination=exited timeout=10000ms duration_nonnegative=true truncated=false
    ansi-preserved: true utf8: true invocations: 1
    -- signal --
    status: failed failed diagnostic=true metadata=false
    output: stage=dune_top termination=signaled timeout=10000ms duration_nonnegative=true truncated=false
    invocations: 1
    -- timeout --
    status: failed timed_out
    message: OCaml eval timed out after 50ms
    metadata: false
    output: stage=dune_top termination=timed_out timeout=50ms duration_nonnegative=true truncated=false
    at most one setup invocation: true
    -- spawn --
    status: failed unavailable diagnostic=true metadata=false
    output: false invocations: 0
    -- invalid UTF-8 directives --
    status: failed failed
    message: OCaml eval dune_top exited with status 7
    metadata: false
    output: stage=dune_top termination=exited timeout=10000ms duration_nonnegative=true truncated=false
    repaired: true replacement: true invocations: 1
    -- incomplete directives --
    status: failed failed
    message: dune ocaml top output was incomplete
    metadata: false
    output: stage=dune_top termination=exited timeout=10000ms duration_nonnegative=true truncated=true
    stdout-bytes: 65564 invocations: 1
    |}]

let%expect_test "setup ignores bounded stderr loss but rejects an open stdout" =
  with_world "setup-stdout-boundary" @@ fun boundary ->
  set_response boundary 1 (String.make Eval.max_directive_bytes 'D');
  set_response boundary 2 "evaluated\n";
  let boundary_result = run boundary (input "1") in
  print_endline "-- exact setup stdout bound --";
  print_status boundary_result;
  Printf.printf "invocations: %d eval-stdin-bytes: %d\n"
    (invocation_count boundary)
    (String.length (invocation boundary "stdin" 2));
  with_world "setup-stdout-over" @@ fun over ->
  set_response over 1 (String.make (Eval.max_directive_bytes + 1) 'D');
  let over_result = run over (input "1") in
  print_endline "-- setup stdout one byte over --";
  print_status over_result;
  print_output_summary over_result;
  Printf.printf "invocations: %d\n" (invocation_count over);
  with_world "setup-stderr" @@ fun stderr_world ->
  set_behavior stderr_world 1 "large_stderr";
  set_response stderr_world 1 "#directory \"ok\";;\n";
  set_response stderr_world 2 "evaluated\n";
  let stderr_result = run stderr_world (input "1") in
  print_endline "-- large setup stderr --";
  print_status stderr_result;
  Printf.printf "invocations: %d stdout: %S\n"
    (invocation_count stderr_world)
    (captured_rendered stderr_result "stdout");
  with_world "setup-open-stdout" @@ fun open_world ->
  set_behavior open_world 1 "incomplete";
  set_response open_world 1 "#directory \"late\";;\n";
  let open_result = run open_world (input "1") in
  print_endline "-- open setup stdout --";
  print_status open_result;
  print_output_summary open_result;
  Printf.printf "invocations: %d\n" (invocation_count open_world);
  with_world "setup-open-stderr" @@ fun open_stderr ->
  set_behavior open_stderr 1 "incomplete_stderr";
  set_response open_stderr 1 "#directory \"ok\";;\n";
  set_response open_stderr 2 "evaluated\n";
  let open_stderr_result = run open_stderr (input "1") in
  print_endline "-- open setup stderr --";
  print_status open_stderr_result;
  Printf.printf "invocations: %d stdout: %S\n"
    (invocation_count open_stderr)
    (captured_rendered open_stderr_result "stdout");
  [%expect
    {|
    -- exact setup stdout bound --
    status: completed
    invocations: 2 eval-stdin-bytes: 65551
    -- setup stdout one byte over --
    status: failed failed
    message: dune ocaml top output was incomplete
    metadata: false
    output: stage=dune_top termination=exited timeout=10000ms duration_nonnegative=true truncated=true
    invocations: 1
    -- large setup stderr --
    status: completed
    invocations: 2 stdout: "evaluated\n"
    -- open setup stdout --
    status: failed failed
    message: dune ocaml top output was incomplete
    metadata: false
    output: stage=dune_top termination=exited timeout=10000ms duration_nonnegative=true truncated=true
    invocations: 1
    -- open setup stderr --
    status: completed
    invocations: 2 stdout: "evaluated\n"
    |}]

let%expect_test "evaluation exit signal and second-phase spawn remain distinct"
    =
  with_world "eval-exit" @@ fun exited ->
  set_response exited 1 "";
  set_behavior exited 2 "exit7";
  let exit_result = run exited (input "1") in
  print_endline "-- exit --";
  print_status exit_result;
  print_output_summary exit_result;
  with_world "eval-signal" @@ fun signaled ->
  set_response signaled 1 "";
  set_behavior signaled 2 "signal";
  let signal_result = run signaled (input "1") in
  print_endline "-- signal --";
  (match Tool.Result.status signal_result with
  | Tool.Result.Failed { kind = `Failed; message; metadata } ->
      Printf.printf "status: failed failed signal-diagnostic=%b metadata=%b\n"
        (not (String.is_empty message))
        (Option.is_some metadata)
  | Tool.Result.Failed { kind; _ } ->
      failf "signal failure had kind %s" (failure_name kind)
  | Tool.Result.Completed -> fail "signaled evaluator unexpectedly completed"
  | Tool.Result.Interrupted _ ->
      fail "signaled evaluator was unexpectedly interrupted");
  print_output_summary signal_result;
  with_world "eval-spawn" @@ fun spawn ->
  set_behavior spawn 1 "remove_self";
  set_response spawn 1 "";
  let spawn_result = run spawn (input "1") in
  print_endline "-- spawn --";
  (match Tool.Result.status spawn_result with
  | Tool.Result.Failed { kind = `Unavailable; message; metadata } ->
      Printf.printf "status: failed unavailable diagnostic=%b metadata=%b\n"
        (not (String.is_empty message))
        (Option.is_some metadata)
  | Tool.Result.Failed { kind; _ } ->
      failf "spawn failure had kind %s" (failure_name kind)
  | Tool.Result.Completed -> fail "spawn failure unexpectedly completed"
  | Tool.Result.Interrupted _ ->
      fail "spawn failure was unexpectedly interrupted");
  Printf.printf "output: %b invocations: %d\n"
    (Option.is_some (Tool.Result.output spawn_result))
    (invocation_count spawn);
  [%expect
    {|
    -- exit --
    status: failed failed
    message: OCaml eval eval exited with status 7
    metadata: false
    output: stage=eval termination=exited timeout=10000ms duration_nonnegative=true truncated=false
    -- signal --
    status: failed failed signal-diagnostic=true metadata=false
    output: stage=eval termination=signaled timeout=10000ms duration_nonnegative=true truncated=false
    -- spawn --
    status: failed unavailable diagnostic=true metadata=false
    output: false invocations: 1
    |}]

let%expect_test "one timeout budget spans setup and evaluation" =
  let clock = Eio_mock.Clock.Mono.make () in
  Eio_mock.Clock.Mono.set_time clock (Mtime.of_uint64_ns 0L);
  with_world ~clock "total-timeout" @@ fun world ->
  set_behavior world 1 "wait_release";
  set_response world 1 "";
  set_behavior world 2 "sleep";
  let rec drive () =
    Eio.Fiber.yield ();
    if started world 1 then begin
      Eio_mock.Clock.Mono.set_time clock (Mtime.of_uint64_ns 7_000_000_000L);
      write_disk (plan_file world "release" 1) "";
      let rec await_eval () =
        Eio.Fiber.yield ();
        if started world 2 && Eio_mock.Clock.Mono.try_advance clock then
          `Stop_daemon
        else await_eval ()
      in
      await_eval ()
    end
    else drive ()
  in
  Eio.Fiber.fork_daemon ~sw:world.sw drive;
  let result = run world (input ~timeout_ms:10_000 "1") in
  print_status result;
  print_output_summary result;
  Printf.printf "duration: %d invocations: %d\n"
    (process_exn result |> Mentat_tools_output.Process.duration_ms)
    (invocation_count world);
  [%expect
    {|
    +mock time is now 0
    +mock time is now 7
    +mock time is now 10
    status: failed timed_out
    message: OCaml eval timed out after 10000ms
    metadata: false
    output: stage=eval termination=timed_out timeout=10000ms duration_nonnegative=true truncated=false
    duration: 10000 invocations: 2
    |}]

let%expect_test "cancellation is terminal before between and within phases" =
  with_world "cancel-before" @@ fun before ->
  let before_result = run ~cancelled:(fun () -> true) before (input "1") in
  print_endline "-- before --";
  print_status before_result;
  Printf.printf "output: %b invocations: %d\n"
    (Option.is_some (Tool.Result.output before_result))
    (invocation_count before);
  with_world "cancel-between" @@ fun between ->
  set_response between 1 "";
  write_disk (plan_file between "cancel-after" 1) "";
  let between_result =
    run
      ~cancelled:(fun () ->
        Sys.file_exists (Filename.concat between.plan_dir "cancel-now"))
      between (input "1")
  in
  print_endline "-- between --";
  print_status between_result;
  Printf.printf "output: %b invocations: %d\n"
    (Option.is_some (Tool.Result.output between_result))
    (invocation_count between);
  with_world "cancel-setup" @@ fun setup ->
  set_behavior setup 1 "sleep";
  let setup_deadline = Unix.gettimeofday () +. 0.1 in
  let setup_result =
    run
      ~cancelled:(fun () -> Unix.gettimeofday () >= setup_deadline)
      setup
      (input ~timeout_ms:5_000 "1")
  in
  print_endline "-- setup running --";
  print_status setup_result;
  print_output_summary setup_result;
  with_world "cancel-eval" @@ fun eval ->
  set_response eval 1 "";
  set_behavior eval 2 "sleep";
  let eval_deadline = ref None in
  let cancel_eval () =
    if not (started eval 2) then false
    else
      match !eval_deadline with
      | None ->
          eval_deadline := Some (Unix.gettimeofday () +. 0.1);
          false
      | Some deadline -> Unix.gettimeofday () >= deadline
  in
  let eval_result =
    run ~cancelled:cancel_eval eval (input ~timeout_ms:5_000 "1")
  in
  print_endline "-- eval running --";
  print_status eval_result;
  print_output_summary eval_result;
  [%expect
    {|
    -- before --
    status: interrupted cancelled=true
    reason: tool call cancelled
    output: false invocations: 0
    -- between --
    status: interrupted cancelled=true
    reason: tool call cancelled
    output: false invocations: 1
    -- setup running --
    status: interrupted cancelled=true
    reason: tool call cancelled
    output: stage=dune_top termination=stopped timeout=5000ms duration_nonnegative=true truncated=false
    -- eval running --
    status: interrupted cancelled=true
    reason: tool call cancelled
    output: stage=eval termination=stopped timeout=5000ms duration_nonnegative=true truncated=false
    |}]

let%expect_test "evaluation head-tail capture is structural and UTF-8 safe" =
  with_world "head-tail" @@ fun world ->
  set_response world 1 "";
  set_behavior world 2 "head_tail";
  let result = run world (input "1") in
  print_status result;
  print_output_summary result;
  let summarize stream =
    let rendered = captured_rendered result stream in
    Printf.printf "%s: bytes=%d valid_utf8=%b marker=%b begins=%S ends=%S\n"
      stream (String.length rendered)
      (String.is_valid_utf_8 rendered)
      (String.includes ~affix:"\n... 4464 bytes omitted ...\n" rendered)
      (String.sub rendered 0 4)
      (String.sub rendered (String.length rendered - 4) 4)
  in
  summarize "stdout";
  summarize "stderr";
  with_world "head-tail-boundary" @@ fun boundary ->
  set_response boundary 1 "";
  set_response boundary 2 (String.make Eval.max_output_bytes 'B');
  let boundary_result = run boundary (input "1") in
  Printf.printf "boundary: completed=%b bytes=%d truncated=%b\n"
    (match Tool.Result.status boundary_result with
    | Tool.Result.Completed -> true
    | Tool.Result.Failed _ | Tool.Result.Interrupted _ -> false)
    (String.length (captured_rendered boundary_result "stdout"))
    (Tool.Output.truncated (output_exn boundary_result));
  with_world "head-tail-over" @@ fun over ->
  set_response over 1 "";
  set_response over 2 (String.make (Eval.max_output_bytes + 1) 'O');
  let over_result = run over (input "1") in
  let over_stdout = captured_rendered over_result "stdout" in
  Printf.printf "over: completed=%b one-omitted=%b truncated=%b\n"
    (match Tool.Result.status over_result with
    | Tool.Result.Completed -> true
    | Tool.Result.Failed _ | Tool.Result.Interrupted _ -> false)
    (String.includes ~affix:"\n... 1 bytes omitted ...\n" over_stdout)
    (Tool.Output.truncated (output_exn over_result));
  with_world "eval-invalid" @@ fun invalid ->
  set_response invalid 1 "";
  set_response invalid 2 "\xffbad\n";
  set_stderr invalid 2 "\xfeerror\n";
  let invalid_result = run invalid (input "1") in
  let stdout = captured_rendered invalid_result "stdout" in
  let stderr = captured_rendered invalid_result "stderr" in
  Printf.printf "invalid: stdout_utf8=%b stderr_utf8=%b replacements=%b\n"
    (String.is_valid_utf_8 stdout)
    (String.is_valid_utf_8 stderr)
    (String.includes ~affix:"\239\191\189" stdout
    && String.includes ~affix:"\239\191\189" stderr);
  ignore (encode result_codec invalid_result);
  [%expect
    {|
    status: completed
    output: stage=eval termination=exited timeout=10000ms duration_nonnegative=true truncated=true
    stdout: bytes=65564 valid_utf8=true marker=true begins="OOOO" ends="OOOO"
    stderr: bytes=65564 valid_utf8=true marker=true begins="EEEE" ends="EEEE"
    boundary: completed=true bytes=65536 truncated=false
    over: completed=true one-omitted=true truncated=true
    invalid: stdout_utf8=true stderr_utf8=true replacements=true
    |}]

let%expect_test "an exited evaluator with open descendant pipes stays durable" =
  with_world "incomplete-eval" @@ fun world ->
  set_response world 1 "";
  set_behavior world 2 "incomplete";
  set_response world 2 "done\n";
  let result = run world (input "1") in
  print_status result;
  print_output_summary result;
  Printf.printf "stdout: %S stderr: %S invocations: %d\n"
    (captured_rendered result "stdout")
    (captured_rendered result "stderr")
    (invocation_count world);
  [%expect
    {|
    status: completed
    output: stage=eval termination=exited timeout=10000ms duration_nonnegative=true truncated=true
    stdout: "done\n\n... bytes omitted ...\n" stderr: "\n... bytes omitted ...\n" invocations: 2
    |}]

let%expect_test "directory and timeout failures stop before any child" =
  with_world "validation" @@ fun world ->
  let cases =
    [
      ("missing", input ~dir:"missing" "1");
      ("file", input ~dir:"not-a-dir" "1");
      ("escaping symlink", input ~dir:"outside-link" "1");
      ("absolute outside", input ~dir:world.outside_dir "1");
      ("timeout high", input ~timeout_ms:120_001 "1");
    ]
  in
  List.iter
    (fun (label, provider_input) ->
      Printf.printf "-- %s --\n" label;
      let call = decode_call world.tool provider_input in
      Printf.printf "permissions: %d\n"
        (List.length (Tool.Call.permissions call));
      let result = run_call call in
      print_status ~normalize:(normalize world) result;
      Printf.printf "output: %b\n" (Option.is_some (Tool.Result.output result)))
    cases;
  Printf.printf "invocations: %d\n" (invocation_count world);
  [%expect
    {|
    -- missing --
    permissions: 1
    status: failed not_found
    message: missing: path does not exist
    metadata: false
    output: false
    -- file --
    permissions: 1
    status: failed invalid_input
    message: not-a-dir: expected a directory, found regular file
    metadata: false
    output: false
    -- escaping symlink --
    permissions: 1
    status: failed invalid_input
    message: outside-link: path resolves outside workspace
    metadata: false
    output: false
    -- absolute outside --
    permissions: 1
    status: failed invalid_input
    message: path is outside workspace: <outside>
    metadata: false
    output: false
    -- timeout high --
    permissions: 1
    status: failed invalid_input
    message: timeout_ms must be <= 120000
    metadata: false
    output: false
    invocations: 0
    |}]

let%expect_test "durable replay is versioned and carries no authority" =
  with_world "durable" @@ fun world ->
  set_response world 1 "";
  set_response world 2 "durable\n";
  let result = run world (input "1 + 1") in
  let stored = encode result_codec result in
  let replay = decode result_codec stored in
  let stored_again = encode result_codec replay in
  let original_output = output_exn result in
  let replay_output = output_exn replay in
  let semantic =
    Tool.Output.json replay_output |> Option.value ~default:(Json.null ())
  in
  let semantic_names = json_member_names semantic in
  Printf.printf "roundtrip: %b durable-equal: %b text-valid: %b\n"
    (Json.equal stored stored_again)
    (Tool.Output.equal original_output replay_output)
    (String.is_valid_utf_8 (Tool.Output.text replay_output));
  let forbidden =
    [
      "receipt";
      "checkpoint";
      "mutation";
      "before";
      "after";
      "claim";
      "handle";
      "capability";
      "sandbox";
      "permissions";
      "directory";
      "dir";
      "phase";
      "timeout_ms";
      "stdout";
      "stderr";
      "diagnostic";
      "framing";
    ]
  in
  let names = json_member_names stored in
  let leaked = List.filter (fun name -> List.mem name forbidden) names in
  let replay_process = process_exn replay in
  Printf.printf "termination=%s authority-fields=%d invocations=%d\n"
    (termination_name (Mentat_tools_output.Process.termination replay_process))
    (List.length leaked) (invocation_count world);
  Printf.printf "semantic-fields: %s input-phrase-leaked: %b\n"
    (String.concat "," semantic_names)
    (String.includes ~affix:"1 + 1" (json_string stored));
  [%expect
    {|
    roundtrip: true durable-equal: true text-valid: true
    termination=exited authority-fields=0 invocations=2
    semantic-fields: version,termination,kind,code,duration_ms input-phrase-leaked: false
    |}]

let%expect_test "constructor rejects invalid immutable program prefixes" =
  with_world "constructor" @@ fun world ->
  let clock = Eio_mock.Clock.Mono.make () in
  List.iter
    (fun (label, program) ->
      let raised =
        match Eval.make world.io ~clock ~program () with
        | _ -> false
        | exception Invalid_argument diagnostic ->
            Printf.printf "%s: %s\n" label diagnostic;
            true
      in
      Printf.printf "%s-raised: %b\n" label raised)
    [
      ("empty", []);
      ("empty-token", [ "dune"; "" ]);
      ("NUL-token", [ "du\x00ne" ]);
    ];
  Printf.printf "invocations: %d\n" (invocation_count world);
  [%expect
    {|
    empty: Ocaml.Eval.make: program prefix must not be empty
    empty-raised: true
    empty-token: Ocaml.Eval.make: program token 1 must not be empty
    empty-token-raised: true
    NUL-token: Ocaml.Eval.make: program token 0 must not contain NUL
    NUL-token-raised: true
    invocations: 0
    |}]

let%expect_test "the tool refuses while a supervised watch holds dune's lock" =
  with_world "watch-lock" @@ fun world ->
  let clock = Eio_mock.Clock.Mono.make () in
  let tool =
    Eval.make world.io ~clock ~program:[ "dune" ]
      ~dune_lock_held:(fun () -> true)
      ()
  in
  let result = run_call (decode_call tool (input "1 + 1")) in
  print_status result;
  Printf.printf "invocations: %d\n" (invocation_count world);
  [%expect
    {|
    status: failed unavailable
    message: a build watch holds dune's build lock, and ocaml_eval needs `dune ocaml top`, which cannot run beside it; use ocaml_type_at, ocaml_find_definitions, or ocaml_docs path queries instead
    metadata: false
    invocations: 0
    |}]
