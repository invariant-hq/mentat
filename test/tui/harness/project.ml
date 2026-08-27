(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { root : string; home : string }
type binding = string * string

let root t = t.root
let home t = t.home
let canonical_root t = Filename.concat t.home (Filename.basename t.root)
let path t local = Filename.concat t.root local
let scratch t local = Filename.concat (t.root ^ ".xdg") local
let data t local = scratch t (Filename.concat "data/mentat" local)
let state t local = scratch t (Filename.concat "state/mentat" local)
let exists t local = Sys.file_exists (path t local)
let write_path = Util.write_file
let read_path = Util.read_file
let write t local text = write_path (path t local) text
let read t local = read_path (path t local)
let write_scratch t local text = write_path (scratch t local) text
let read_scratch t local = read_path (scratch t local)
let same_name name (candidate, _) = String.equal candidate name

let add_binding bindings ((name, _) as binding) =
  List.filter (fun candidate -> not (same_name name candidate)) bindings
  @ [ binding ]

let validate_name name =
  if String.is_empty name || String.contains name '=' then
    invalid_arg (Printf.sprintf "Project: invalid environment name %S" name)

let normalize_bindings bindings =
  List.iter (fun (name, _) -> validate_name name) bindings;
  List.fold_left add_binding [] bindings

let bindings ?openai_base_url ?(unset = []) ?(extra = []) t =
  List.iter validate_name unset;
  let xdg = t.root ^ ".xdg" in
  let home = t.home in
  let config = Filename.concat xdg "config" in
  let cache = Filename.concat xdg "cache" in
  let data = Filename.concat xdg "data" in
  let runtime = Filename.concat xdg "runtime" in
  let state = Filename.concat xdg "state" in
  List.iter Util.mkdir_p [ home; config; cache; data; runtime; state ];
  let defaults =
    [
      ("HOME", home);
      ("XDG_CONFIG_HOME", config);
      ("XDG_CACHE_HOME", cache);
      ("XDG_DATA_HOME", data);
      ("XDG_RUNTIME_DIR", runtime);
      ("XDG_STATE_HOME", state);
      ("TERM", "xterm-256color");
      ("MENTAT_AUTO_TITLE", "0");
      ("MENTAT_REDUCED_MOTION", "1");
      ("MENTAT_MODEL", "openai/gpt-5.6-sol");
      ("MENTAT_SANDBOX_MODE", "danger-full-access");
      ("MENTAT_WORKSPACE_TOOLING", "off");
    ]
  in
  let provider =
    match openai_base_url with
    | None -> []
    | Some base_url ->
        [ ("OPENAI_API_KEY", "test-key"); ("MENTAT_OPENAI_BASE_URL", base_url) ]
  in
  normalize_bindings (defaults @ provider @ extra)
  |> List.filter (fun (name, _) -> not (List.mem name unset))

let leaks_dune name =
  String.starts_with ~prefix:"DUNE_" name || String.equal name "INSIDE_DUNE"

let isolated_names =
  [
    "ANTHROPIC_API_KEY";
    "GEMINI_API_KEY";
    "GOOGLE_API_KEY";
    "GOOGLE_GENERATIVE_AI_API_KEY";
    "OLLAMA_API_KEY";
    "OPENAI_API_KEY";
    "MENTAT_ANTHROPIC_BASE_URL";
    "MENTAT_AUTO_TITLE";
    "MENTAT_CONFIG";
    "MENTAT_CONFIG_HOME";
    "MENTAT_DATA_HOME";
    "MENTAT_DUNE";
    "MENTAT_GOOGLE_BASE_URL";
    "MENTAT_MAX_STEPS";
    "MENTAT_MODEL";
    "MENTAT_NOW";
    "MENTAT_OLLAMA_BASE_URL";
    "MENTAT_OPENAI_AUTH_BASE_URL";
    "MENTAT_OPENAI_BASE_URL";
    "MENTAT_PERMISSION_UNATTENDED";
    "MENTAT_REASONING";
    "MENTAT_REDUCED_MOTION";
    "MENTAT_SANDBOX_MODE";
    "MENTAT_SANDBOX_NETWORK";
    "MENTAT_SANDBOX_READ";
    "MENTAT_SANDBOX_REQUIRE";
    "MENTAT_SHELL";
    "MENTAT_STATE_HOME";
    "MENTAT_WORKSPACE_TOOLING";
  ]

let is_isolated name = List.mem name isolated_names

let split_environment_binding item =
  match String.index_opt item '=' with
  | None -> None
  | Some equal ->
      let name = String.sub item 0 equal in
      let value =
        String.sub item (equal + 1) (String.length item - equal - 1)
      in
      Some (name, value)

let current_bindings () =
  Unix.environment () |> Array.to_list
  |> List.filter_map split_environment_binding

let with_process_env ?(unset = []) requested f =
  List.iter validate_name unset;
  let requested =
    normalize_bindings requested
    |> List.filter (fun (name, _) ->
        (not (leaks_dune name)) && not (List.mem name unset))
  in
  let current = current_bindings () in
  let controlled =
    List.map fst requested @ unset @ isolated_names
    @ List.filter_map
        (fun (name, _) -> if leaks_dune name then Some name else None)
        current
    |> List.sort_uniq String.compare
  in
  let previous =
    List.map (fun name -> (name, List.assoc_opt name current)) controlled
  in
  let clear () = List.iter Unix.unsetenv controlled in
  let restore () =
    clear ();
    List.iter
      (fun (name, value) -> Option.iter (Unix.putenv name) value)
      previous
  in
  Fun.protect ~finally:restore (fun () ->
      clear ();
      List.iter (fun (name, value) -> Unix.putenv name value) requested;
      f ())

let env_array ?openai_base_url ?(unset = []) ?(extra = []) t =
  List.iter validate_name unset;
  let requested = bindings ?openai_base_url ~unset ~extra t in
  let requested_names = List.map fst requested in
  let should_remove name =
    leaks_dune name || List.mem name unset
    || (is_isolated name && not (List.mem name requested_names))
    || List.mem name requested_names
  in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun item ->
        match split_environment_binding item with
        | None -> true
        | Some (name, _) -> not (should_remove name))
  in
  let requested =
    List.map (fun (name, value) -> name ^ "=" ^ value) requested
  in
  Array.of_list (requested @ inherited)

let string_of_process_status = function
  | Unix.WEXITED code -> Printf.sprintf "exited with status %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "was killed by signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "was stopped by signal %d" signal

let rec waitpid pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid pid

let git t args =
  let command =
    "git" :: "-C" :: t.root :: "-c" :: "user.name=Reviewer" :: "-c"
    :: "user.email=reviewer@example.com" :: args
  in
  let rendered = String.concat " " (List.map Filename.quote command) in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close dev_null)
    (fun () ->
      let argv = Array.of_list command in
      let pid = Unix.create_process "git" argv dev_null dev_null dev_null in
      match waitpid pid with
      | Unix.WEXITED 0 -> ()
      | status -> Util.failf "%s %s" rendered (string_of_process_status status))

let git_baseline t =
  git t [ "init"; "-q" ];
  git t [ "add"; "-A" ];
  git t [ "commit"; "-q"; "-m"; "baseline" ]

let invalid_fixture_name name =
  String.is_empty name || String.contains name Filename.dir_sep.[0]

(* The fixture lives one level below a private container that doubles as [HOME],
   so every surface that formats the workspace against the home boundary renders
   the same [~/mentat-tui-<token>] on Linux and macOS. The container is the unit
   of ownership and removal; the workspace and its XDG sibling are inside it. *)
let fresh_container name =
  if invalid_fixture_name name then
    invalid_arg (Printf.sprintf "Project.with_temp: invalid name %S" name);
  let executable = Sys.executable_name in
  let runner =
    Filename.concat
      (Filename.basename (Filename.dirname executable))
      (Filename.basename executable)
  in
  let identity = runner ^ "\000" ^ name in
  let digest = Digest.to_hex (Digest.string identity) in
  let width = String.length name in
  (* Qualify names by their stable runner identity so independently-run visual
     suites cannot claim the same deterministic root. The identity is the
     runner's enclosing directory with its basename: every inline-test runner
     is spelled [inline-test-runner.exe], and only its [.<library>.inline-tests]
     directory tells the suites apart. Keep long fixture paths at their
     existing readable width, but give short names enough digest space to
     avoid collapsing them into a one-character bucket. *)
  let prefix_width = max 0 (width - 8) in
  let token = String.sub name 0 prefix_width ^ String.sub digest 0 8 in
  let container = Filename.concat "/tmp" ("mentat-tui-" ^ token ^ ".home") in
  match Unix.mkdir container 0o700 with
  | () -> (container, "mentat-tui-" ^ token)
  | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
      Util.failf
        "Project.with_temp: deterministic fixture container already exists: %s"
        container

let with_temp name f =
  let container, basename = fresh_container name in
  (* The workspace keeps its logical [/tmp] spelling: macOS resolves [/tmp] to
     [/private/tmp], and a canonicalized root would change the width of every
     path an absolute-rendering fixture lays out. [HOME] is the canonical
     container instead, because a real child canonicalizes its own working
     directory and must still recognize it as living under that home. *)
  let root = Filename.concat container basename in
  Unix.mkdir root 0o700;
  let project = { root; home = Unix.realpath container } in
  write project "dune-project" "(lang dune 3.0)\n(name fixture)\n";
  Fun.protect ~finally:(fun () -> Util.rm_rf container) (fun () -> f project)

let with_git_fixture name f =
  with_temp name @@ fun project ->
  write project "lib/code.ml"
    "let alpha = 1\nlet beta = 2\nlet gamma = 3\nlet delta = 4\n";
  write project "notes.txt" "baseline\n";
  git_baseline project;
  f project

let stop_process pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> (
      (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
          ignore (waitpid pid : Unix.process_status)
      | _ -> ()
      | exception Unix.Unix_error _ -> ())
  | _ -> ()
  | exception Unix.Unix_error _ -> ()

let with_external_dune_watch t f =
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let argv = [| "dune"; "build"; "--root"; t.root; "--watch"; "@all" |] in
  let pid =
    Fun.protect
      ~finally:(fun () -> Unix.close dev_null)
      (fun () ->
        Unix.create_process_env "dune" argv (env_array t) dev_null dev_null
          dev_null)
  in
  Fun.protect ~finally:(fun () -> stop_process pid) f

let resolve_env_path name =
  match Sys.getenv_opt name with
  | None -> Util.failf "%s is not set" name
  | Some configured ->
      let resolved =
        if Filename.is_relative configured then
          Filename.concat (Sys.getcwd ()) configured
        else configured
      in
      if Sys.file_exists resolved then Unix.realpath resolved
      else Util.failf "%s does not exist: %s" name resolved

let wait_for_file path =
  let rec loop remaining =
    if remaining = 0 then Util.failf "timed out waiting for %s" path
    else
      let ready =
        match Unix.stat path with
        | stat -> stat.Unix.st_size > 0
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
      in
      if ready then ()
      else (
        Unix.sleepf 0.05;
        loop (remaining - 1))
  in
  (* 30 s: first spawns on a busy host — fresh-inode syspolicyd scans, a
     live watch rebuilding beside the suite — can exceed the old 10 s
     bound; only failing tests pay the longer wait. *)
  loop 600
