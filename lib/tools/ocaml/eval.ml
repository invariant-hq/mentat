(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let max_detail_bytes = 4 * 1024
let max_output_bytes = 64 * 1024
let name = "ocaml_eval"
let default_timeout_ms = 10_000
let max_timeout_ms = 120_000
let max_directive_bytes = 64 * 1024
let capture_head_bytes = max_output_bytes / 2
let capture_tail_bytes = max_output_bytes - capture_head_bytes
let json_string value = Jsont.Json.string value
let json_int value = Jsont.Json.int value
let json_bool value = Jsont.Json.bool value

module Input = struct
  type t = { code : string; dir : string option; timeout_ms : int option }

  let max_input_integer =
    Float.min 9_007_199_254_740_991. (float_of_int Int.max_int)

  let validate_string member value =
    if String.is_empty value then invalid_arg (member ^ " must not be empty");
    if String.contains value '\x00' then
      invalid_arg (member ^ " must not contain NUL")

  let make code dir timeout_ms =
    Mentat_tool.Codec.decode_invalid_arg @@ fun () ->
    validate_string "code" code;
    Option.iter (validate_string "dir") dir;
    (match timeout_ms with
    | Some timeout_ms when timeout_ms <= 0 ->
        invalid_arg "timeout_ms must be positive"
    | Some _ | None -> ());
    { code; dir; timeout_ms }

  let exact_integer =
    let decode = function
      | Jsont.Number (value, _)
        when Float.is_integer value && Float.abs value <= max_input_integer ->
          int_of_float value
      | Jsont.Number _ | Jsont.Null _ | Jsont.Bool _ | Jsont.String _
      | Jsont.Array _ | Jsont.Object _ ->
          Codec.decode_error "expected an integer in JSON's safe integer range"
    in
    Jsont.map ~kind:"integer" ~dec:decode ~enc:json_int Jsont.json

  let object_codec =
    Jsont.Object.map ~kind:"ocaml_eval input" make
    |> Jsont.Object.mem "code" Jsont.string ~enc:(fun input -> input.code)
    |> Jsont.Object.opt_mem "dir" Jsont.string ~enc:(fun input -> input.dir)
    |> Jsont.Object.opt_mem "timeout_ms" exact_integer ~enc:(fun input ->
        input.timeout_ms)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let codec = Codec.strict_object ~kind:"strict ocaml_eval input" object_codec

  let schema =
    Codec.obj
      [
        ("type", json_string "object");
        ( "properties",
          Codec.obj
            [
              ( "code",
                Codec.obj
                  [
                    ("type", json_string "string");
                    ( "description",
                      json_string
                        "Non-empty OCaml toplevel phrase text to evaluate in a \
                         fresh process." );
                    ("minLength", json_int 1);
                  ] );
              ( "dir",
                Codec.obj
                  [
                    ("type", json_string "string");
                    ( "description",
                      json_string
                        "Workspace-relative or workspace-contained absolute \
                         Dune project directory. Defaults to the root owning \
                         the workspace current directory." );
                    ("minLength", json_int 1);
                  ] );
              ( "timeout_ms",
                Codec.obj
                  [
                    ("type", json_string "integer");
                    ( "description",
                      json_string
                        "Optional total setup-and-evaluation timeout in \
                         milliseconds, bounded by host policy." );
                    ("minimum", json_int 1);
                    ("maximum", Jsont.Json.number max_input_integer);
                  ] );
            ] );
        ("required", Jsont.Json.list [ json_string "code" ]);
        ("additionalProperties", json_bool false);
      ]

  let contract = Mentat_tool.Input.make codec ~schema

  let effective_timeout_ms input =
    Option.value input.timeout_ms ~default:default_timeout_ms
end

type stage = Dune_top | Eval

type termination =
  | Exited of int
  | Signaled of int
  | Timed_out
  | Stopped
  | Output_limit of { stream : Mentat_workspace_io.Command.stream; limit : int }
  | Supervision_failed of string

type captured =
  | Complete of string
  | Truncated of { head : string; omitted : int option; tail : string }

type output = {
  address : string;
  stage : stage;
  termination : termination;
  stdout : captured;
  stderr : captured;
  duration_ms : int;
  timeout_ms : int;
  confinement : Mentat_workspace_io.Confinement.t option;
}

let stream_name = function
  | Mentat_workspace_io.Command.Stdout -> "stdout"
  | Mentat_workspace_io.Command.Stderr -> "stderr"

let stage_name = function Dune_top -> "dune_top" | Eval -> "eval"

let captured_of_command = function
  | Mentat_workspace_io.Command.Captured.Complete text -> Complete text
  | Mentat_workspace_io.Command.Captured.Truncated { head; omitted; tail } ->
      Truncated { head; omitted; tail }

let captured_complete = function Complete _ -> true | Truncated _ -> false

let captured_text = function
  | Complete text -> Text_helpers.utf8_lossy text
  | Truncated { head; omitted; tail } ->
      let omission =
        match omitted with
        | Some bytes -> Printf.sprintf "\n... %d bytes omitted ...\n" bytes
        | None -> "\n... bytes omitted ...\n"
      in
      Text_helpers.utf8_lossy head ^ omission ^ Text_helpers.utf8_lossy tail

let status_text output =
  match output.termination with
  | Exited code -> "exited " ^ string_of_int code
  | Signaled signal -> "signaled " ^ string_of_int signal
  | Timed_out -> "timed out after " ^ string_of_int output.timeout_ms ^ "ms"
  | Stopped -> "stopped"
  | Output_limit { stream; limit } ->
      Printf.sprintf "%s exceeded %d-byte output limit" (stream_name stream)
        limit
  | Supervision_failed detail -> "supervision failed: " ^ detail

let output_truncated output =
  (not (captured_complete output.stdout))
  || not (captured_complete output.stderr)

let output_text output =
  Printf.sprintf
    "OCaml eval\n\
     Directory: %s\n\
     Stage: %s\n\
     Status: %s\n\
     Duration: %dms\n\
     Timeout: %dms\n\n\
     stdout:\n\
     %s\n\
     stderr:\n\
     %s"
    output.address (stage_name output.stage) (status_text output)
    output.duration_ms output.timeout_ms
    (captured_text output.stdout)
    (captured_text output.stderr)

let encode_output output =
  let stream = function
    | Mentat_workspace_io.Command.Stdout -> Mentat_tools_output.Process.Stdout
    | Mentat_workspace_io.Command.Stderr -> Mentat_tools_output.Process.Stderr
  in
  let termination =
    match output.termination with
    | Exited code -> Mentat_tools_output.Process.Exited code
    | Signaled signal -> Mentat_tools_output.Process.Signaled signal
    | Timed_out -> Mentat_tools_output.Process.Timed_out
    | Stopped -> Mentat_tools_output.Process.Stopped
    | Output_limit { stream = output_stream; limit } ->
        Mentat_tools_output.Process.Output_limit
          { stream = stream output_stream; limit }
    | Supervision_failed _ -> Mentat_tools_output.Process.Supervision_failed
  in
  let semantic =
    Mentat_tools_output.Process.make ~termination
      ~duration_ms:output.duration_ms
  in
  Mentat_tools_output.Codec.encode Mentat_tools_output.Process.jsont
    ~text:(output_text output) ~truncated:(output_truncated output) semantic

let bounded_detail detail =
  let detail = detail |> Text_helpers.utf8_lossy |> String.trim in
  if String.length detail <= max_detail_bytes then detail
  else Text_helpers.valid_utf8_prefix detail max_detail_bytes

let command_error_message error =
  Mentat_workspace_io.Command.Error.message error |> bounded_detail

let command_error_failure = function
  | Mentat_workspace_io.Command.Error.Sandbox
      ( Mentat_sandbox.Error.Empty_program | Mentat_sandbox.Error.Nul_in_argv _
      | Mentat_sandbox.Error.Grant_denied _
      | Mentat_sandbox.Error.Grant_not_a_directory _ )
  | Mentat_workspace_io.Command.Error.Unknown_cwd_root _ ->
      `Invalid_input
  | Mentat_workspace_io.Command.Error.Sandbox
      ( Mentat_sandbox.Error.Escalation_denied
      | Mentat_sandbox.Error.Escalation_irrelevant
      | Mentat_sandbox.Error.Unavailable _
      | Mentat_sandbox.Error.Cwd_outside_scope _
      | Mentat_sandbox.Error.Stale_policy _ )
  | Mentat_workspace_io.Command.Error.Spawn _
  | Mentat_workspace_io.Command.Error.Io _ ->
      `Unavailable

let elapsed_ms clock started =
  Mtime.span started (Eio.Time.Mono.now clock) |> Mtime.Span.to_float_ns
  |> fun nanoseconds -> int_of_float (nanoseconds /. 1_000_000.)

let remaining_seconds clock started timeout_ms =
  let elapsed =
    Mtime.span started (Eio.Time.Mono.now clock) |> Mtime.Span.to_float_ns
    |> fun nanoseconds -> nanoseconds /. 1_000_000_000.
  in
  let remaining = (float_of_int timeout_ms /. 1_000.) -. elapsed in
  if remaining <= 0. then None else Some remaining

let output_of_outcome ~clock ~started ~address ~stage ~timeout_ms outcome =
  let termination =
    match outcome.Mentat_workspace_io.Command.termination with
    | Mentat_workspace_io.Command.Exited (`Exited code) -> Exited code
    | Mentat_workspace_io.Command.Exited (`Signaled signal) -> Signaled signal
    | Mentat_workspace_io.Command.Timed_out -> Timed_out
    | Mentat_workspace_io.Command.Stopped -> Stopped
    | Mentat_workspace_io.Command.Output_limit { stream; limit } ->
        Output_limit { stream; limit }
    | Mentat_workspace_io.Command.Supervision_failed error ->
        Supervision_failed
          (Format.asprintf "%a" Eio.Exn.pp_err error |> bounded_detail)
  in
  {
    address;
    stage;
    termination;
    stdout = captured_of_command outcome.Mentat_workspace_io.Command.stdout;
    stderr = captured_of_command outcome.Mentat_workspace_io.Command.stderr;
    confinement = outcome.Mentat_workspace_io.Command.confinement;
    duration_ms = elapsed_ms clock started;
    timeout_ms;
  }

let result_of_output output =
  match output.termination with
  | Exited 0 -> Mentat_tool.Result.completed ~output ()
  | Exited code ->
      (* This stage spawns dune, so it is the cold-cache case: a confined
         refusal reached the model as an unexplained nonzero exit. *)
      Mentat_tool.Result.failed ~output `Failed
        (Printf.sprintf "OCaml eval %s exited with status %d"
           (stage_name output.stage) code
        ^ Confinement.denial_note ~widening:`Through_shell output.confinement)
  | Signaled signal ->
      Mentat_tool.Result.failed ~output `Failed
        (Printf.sprintf "OCaml eval %s terminated by signal %d"
           (stage_name output.stage) signal)
  | Timed_out ->
      Mentat_tool.Result.failed ~output `Timed_out
        ("OCaml eval timed out after " ^ string_of_int output.timeout_ms ^ "ms")
  | Stopped -> Mentat_tool.Result.cancelled ~output ()
  | Output_limit { stream; limit } ->
      Mentat_tool.Result.failed ~output `Failed
        (Printf.sprintf "OCaml eval %s exceeded %d-byte output limit"
           (stream_name stream) limit)
  | Supervision_failed detail ->
      Mentat_tool.Result.failed ~output `Failed
        ("OCaml eval supervision failed: " ^ detail)

let terminate_phrase code =
  let trimmed = String.trim code in
  let length = String.length trimmed in
  if
    length >= 2
    && Char.equal trimmed.[length - 1] ';'
    && Char.equal trimmed.[length - 2] ';'
  then code
  else code ^ "\n;;\n"

let evaluation_source ~directives ~code =
  let phrase = terminate_phrase code in
  let buffer = Buffer.create 4096 in
  Buffer.add_string buffer directives;
  if
    (not (String.is_empty directives))
    && not (Char.equal directives.[String.length directives - 1] '\n')
  then Buffer.add_char buffer '\n';
  Buffer.add_string buffer phrase;
  Buffer.add_string buffer "\n#quit;;\n";
  Buffer.contents buffer

let requested_directory workspace_io input =
  match input.Input.dir with
  | Some dir -> Mentat_workspace_io.resolve_path workspace_io dir
  | None ->
      Ok (Mentat_workspace.Path.root_of (Mentat_workspace_io.cwd workspace_io))

let resolve_directory workspace_io input =
  match requested_directory workspace_io input with
  | Error error ->
      Error
        (Mentat_tool.Result.failed `Invalid_input
           (Mentat_workspace.Resolve_error.message error))
  | Ok directory -> (
      match Mentat_workspace_io.File.stat workspace_io directory with
      | Error error -> Error (Fs_error.failed error)
      | Ok stat -> (
          match stat.Eio.File.Stat.kind with
          | `Directory -> (
              match Address.provider workspace_io directory with
              | Ok address -> Ok (directory, address)
              | Error diagnostic ->
                  Error (Mentat_tool.Result.failed `Failed diagnostic))
          | kind ->
              Error
                (Mentat_tool.Result.failed `Invalid_input
                   (Mentat_workspace.Path.display directory
                   ^ ": expected a directory, found " ^ Stat_kind.kind_name kind
                   ))))

let interrupted () = Mentat_tool.Result.cancelled ()

let run_command workspace_io ~clock ~started ~cwd ~capture ~timeout_ms
    ~cancelled argv stdin =
  match remaining_seconds clock started timeout_ms with
  | None -> `Expired
  | Some seconds ->
      let timeout = Eio.Time.Timeout.seconds clock seconds in
      let result =
        match stdin with
        | None ->
            Mentat_workspace_io.Command.run workspace_io ~cwd ~capture ~timeout
              ~cancelled argv
        | Some source ->
            Mentat_workspace_io.Command.run workspace_io ~cwd
              ~stdin:(Eio.Flow.string_source source)
              ~capture ~timeout ~cancelled argv
      in
      `Result result

let synthetic_timeout ~clock ~started ~address ~stage ~timeout_ms =
  {
    address;
    stage;
    termination = Timed_out;
    stdout = Complete "";
    stderr = Complete "";
    duration_ms = elapsed_ms clock started;
    timeout_ms;
    confinement = None;
  }
  |> result_of_output

let run_evaluation workspace_io ~clock ~program ~started ~directory ~address
    ~timeout_ms ~cancelled input directives =
  let source = evaluation_source ~directives ~code:input.Input.code in
  let argv = program @ [ "exec"; "--"; "ocaml"; "-stdin"; "-noinit" ] in
  let capture =
    Mentat_workspace_io.Command.Head_tail
      { head = capture_head_bytes; tail = capture_tail_bytes }
  in
  match
    run_command workspace_io ~clock ~started ~cwd:directory ~capture ~timeout_ms
      ~cancelled argv (Some source)
  with
  | `Expired ->
      synthetic_timeout ~clock ~started ~address ~stage:Eval ~timeout_ms
  | `Result (Error error) ->
      Mentat_tool.Result.failed
        (command_error_failure error)
        (command_error_message error)
  | `Result (Ok outcome) ->
      output_of_outcome ~clock ~started ~address ~stage:Eval ~timeout_ms outcome
      |> result_of_output

let run_setup workspace_io ~clock ~program ~started ~directory ~address
    ~timeout_ms ~cancelled input =
  let argv = program @ [ "ocaml"; "top"; "." ] in
  let head = max_directive_bytes / 2 in
  let capture =
    Mentat_workspace_io.Command.Head_tail
      { head; tail = max_directive_bytes - head }
  in
  match
    run_command workspace_io ~clock ~started ~cwd:directory ~capture ~timeout_ms
      ~cancelled argv None
  with
  | `Expired ->
      synthetic_timeout ~clock ~started ~address ~stage:Dune_top ~timeout_ms
  | `Result (Error error) ->
      Mentat_tool.Result.failed
        (command_error_failure error)
        (command_error_message error)
  | `Result (Ok outcome) -> (
      let output =
        output_of_outcome ~clock ~started ~address ~stage:Dune_top ~timeout_ms
          outcome
      in
      match output.termination with
      | Exited 0 when captured_complete output.stdout -> (
          if cancelled () then interrupted ()
          else
            match output.stdout with
            | Complete directives ->
                run_evaluation workspace_io ~clock ~program ~started ~directory
                  ~address ~timeout_ms ~cancelled input directives
            | Truncated _ ->
                Mentat_tool.Result.failed ~output `Failed
                  "dune ocaml top output was incomplete")
      | Exited 0 ->
          Mentat_tool.Result.failed ~output `Failed
            "dune ocaml top output was incomplete"
      | Exited _ | Signaled _ | Timed_out | Stopped | Output_limit _
      | Supervision_failed _ ->
          result_of_output output)

(* The refusal while a build watch — supervised or foreign — holds dune's
   build lock. The
   setup command ([dune ocaml top .]) takes that lock and would fail with
   dune's own advice — which suggests deleting [_build/.lock], exactly what a
   caller must never do while a watch runs — so the tool answers honestly and
   names the lock-free alternatives instead. *)
let watch_lock_message =
  "a build watch holds dune's build lock, and ocaml_eval needs `dune ocaml \
   top`, which cannot run beside it; use ocaml_type_at, \
   ocaml_find_definitions, or ocaml_docs path queries instead"

let run workspace_io ~clock ~program ~dune_lock_held ~cancelled input =
  if cancelled () then interrupted ()
  else if dune_lock_held () then
    Mentat_tool.Result.failed `Unavailable watch_lock_message
  else
    let timeout_ms = Input.effective_timeout_ms input in
    if timeout_ms > max_timeout_ms then
      Mentat_tool.Result.failed `Invalid_input
        ("timeout_ms must be <= " ^ string_of_int max_timeout_ms)
    else
      match resolve_directory workspace_io input with
      | Error result -> result
      | Ok (directory, address) ->
          if cancelled () then interrupted ()
          else
            let started = Eio.Time.Mono.now clock in
            run_setup workspace_io ~clock ~program ~started ~directory ~address
              ~timeout_ms ~cancelled input

let permissions execution _input =
  [
    Mentat_permission.Request.of_accesses ~source:name
      [ Confinement.custom_access execution ];
  ]

let validate_program program =
  if List.is_empty program then
    invalid_arg "Ocaml.Eval.make: program prefix must not be empty";
  List.iteri
    (fun index token ->
      if String.is_empty token then
        invalid_arg
          ("Ocaml.Eval.make: program token " ^ string_of_int index
         ^ " must not be empty");
      if String.contains token '\x00' then
        invalid_arg
          ("Ocaml.Eval.make: program token " ^ string_of_int index
         ^ " must not contain NUL"))
    program

let make workspace_io ~clock ~program ?(dune_lock_held = fun () -> false) () =
  validate_program program;
  let execution = Confinement.confined workspace_io in
  Mentat_tool.make ~name ~description:Mentat_prompts.Tools.ocaml_eval
    ~input:Input.contract ~output:encode_output
    ~permissions:(permissions execution)
    ~run:(fun ~cancelled input ->
      run workspace_io ~clock ~program ~dune_lock_held ~cancelled input)
    ()
