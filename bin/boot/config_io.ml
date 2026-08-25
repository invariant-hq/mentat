(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Config = Mentat_config

type layer = User | Project | Project_local

let ( let* ) = Result.bind

(* The single config read path, byte-capped: an absent file is [None] (never
   conflated with a present-but-malformed one); an unreadable or over-large file
   is treated as absent for layering. *)
let read_file path =
  match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
  | Ok bytes -> bytes
  | Error _ -> None

let read ~path = Fs.read_capped ~max_bytes:Fs.default_max_bytes path
let abs s = Lpath.Abs.of_string_exn s

let layer_path ~dirs ~root layer =
  match layer with
  | User -> User_dirs.config_file dirs
  | Project -> Filename.concat (Lpath.Abs.to_string root) ".mentat/config.json"
  | Project_local ->
      Filename.concat (Lpath.Abs.to_string root) ".mentat/config.local.json"

(* Which layer a path names, decided on the files themselves rather than on
   spelling: a relative path, a symlinked home, and the layer's own absolute
   path all name the same file, and the answer governs which keys that file may
   carry. An unresolvable path names no layer. *)
let same_file a b =
  match (Unix.realpath a, Unix.realpath b) with
  | a, b -> String.equal a b
  | exception Unix.Unix_error _ -> false

let layer_of_path ~dirs ~root path =
  List.find_opt
    (fun layer -> same_file path (layer_path ~dirs ~root layer))
    [ User; Project; Project_local ]

let read_layer ~dirs ~root layer =
  let path = layer_path ~dirs ~root layer in
  match read_file path with
  | None -> Ok Config.empty
  | Some text ->
      Result.map_error Config.Error.message (Config.of_text ~source:path text)

(* One workspace file's state for [resolve]: parsed, invalid-with-reason, or
   absent. *)
let workspace_file path : Config.workspace_file =
  match read_file path with
  | None -> Config.Absent
  | Some text -> (
      match Config.of_text ~source:path text with
      | Ok config -> Config.Loaded (abs path, config)
      | Error e -> Config.Invalid (abs path, Config.Error.message e))

let resolve ~dirs ~root ~trusted ~getenv ~overrides =
  let user_path = User_dirs.config_file dirs in
  let* user_config =
    match read_file user_path with
    | None -> Ok Config.empty
    | Some text ->
        Result.map_error Config.Error.message
          (Config.of_text ~source:user_path text)
  in
  let user = (abs user_path, user_config) in
  let* extra =
    match getenv "MENTAT_CONFIG" with
    | Some path when String.length path > 0 && Filename.is_relative path ->
        (* Env-sourced, so a bad path is a runtime error through the ladder,
           never an [Abs.of_string_exn] escape to the internal-error guard. *)
        Error (Printf.sprintf "MENTAT_CONFIG must be an absolute path: %s" path)
    | Some path when String.length path > 0 && Sys.file_exists path -> (
        match read_file path with
        | None -> Ok None
        | Some text ->
            Result.map
              (fun c -> Some (abs path, c))
              (Result.map_error Config.Error.message
                 (Config.of_text ~source:path text)))
    | Some _ | None -> Ok None
  in
  let project_path = layer_path ~dirs ~root Project in
  let project_local_path = layer_path ~dirs ~root Project_local in
  let workspace_config : Config.workspace_config =
    if trusted then
      Config.Trusted
        {
          project = workspace_file project_path;
          project_local = workspace_file project_local_path;
        }
    else
      Config.Disabled
        {
          status = "untrusted";
          project =
            (if Sys.file_exists project_path then Some (abs project_path)
             else None);
          project_local =
            (if Sys.file_exists project_local_path then
               Some (abs project_local_path)
             else None);
        }
  in
  Result.map_error Config.Error.message
    (Config.resolve ~env:getenv ~user ~extra ~workspace_config ~overrides)

let ensure_gitignored ~root name =
  let gitignore =
    Filename.concat (Lpath.Abs.to_string root) ".mentat/.gitignore"
  in
  let existing = Option.value ~default:"" (read_file gitignore) in
  let lines = String.split_on_char '\n' existing in
  if List.exists (String.equal name) lines then Ok ()
  else
    let updated =
      if
        String.length existing = 0
        || Char.equal existing.[String.length existing - 1] '\n'
      then existing ^ name ^ "\n"
      else existing ^ "\n" ^ name ^ "\n"
    in
    Fs.atomic_write ~perms:0o644 gitignore updated

let plan_write ~dirs ~root layer ~f =
  let path = layer_path ~dirs ~root layer in
  (* Serialize the read-plan-write against a concurrent [config set] so the
     later writer cannot lose the earlier edit; the write is atomic. *)
  Fs.with_lock (path ^ ".lock") (fun () ->
      let original = Option.value ~default:"" (read_file path) in
      let* plan =
        Result.map_error Config.Error.message
          (Config.plan ~source:path ~original ~f)
      in
      match plan with
      | Config.Plan.Unchanged -> Ok false
      | Config.Plan.Write bytes ->
          let* () =
            match layer with
            | Project_local -> ensure_gitignored ~root "config.local.json"
            | User | Project -> Ok ()
          in
          Result.map (fun () -> true) (Fs.atomic_write ~perms:0o644 path bytes))

(* The single init path: create the layer file — an empty [{}] if
   absent, left untouched otherwise — through [Fs.atomic_write] (which creates
   the parent chain, killing the silent no-create when [.mentat/] was absent), and
   scaffold [.gitignore] for the project-local layer. Returns the file path. *)
let init ~dirs ~root layer =
  let path = layer_path ~dirs ~root layer in
  let* () =
    match layer with
    | Project_local -> ensure_gitignored ~root "config.local.json"
    | User | Project -> Ok ()
  in
  if Sys.file_exists path then Ok path
  else Result.map (fun () -> path) (Fs.atomic_write ~perms:0o644 path "{}\n")
