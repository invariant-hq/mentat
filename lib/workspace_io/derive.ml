(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

let log_src =
  Logs.Src.create "mentat.workspace_io.derive"
    ~doc:"Workspace read/write scope derivation"

module Log = (val Logs.src_log log_src : Logs.LOG)

type derived = {
  workspace_roots : (Mentat_workspace.Root.t * Lpath.Abs.t) list;
  writable : Lpath.Abs.t list;
  platform_writable : Lpath.Abs.t list;
  toolchain_writable : Lpath.Abs.t list;
  readable : Lpath.Abs.t list;
  protected : Lpath.Abs.t list;
  denied : Lpath.Abs.t list;
  path : string;
  describe : (string * Lpath.Abs.t) list;
}

let invalid ~spelling reason = Resolve_error.Invalid_root { spelling; reason }

let unix_reason = function
  | Unix.ENOENT -> Resolve_error.Does_not_exist
  | Unix.ENOTDIR -> Resolve_error.Not_a_directory
  | _ -> Resolve_error.Not_accessible

(* Canonicalize where the path exists so the policy describes what the
   backend enforces (macOS /tmp is a symlink to /private/tmp). A path that
   cannot be resolved keeps its lexical spelling. *)
let canonical path =
  match Unix.realpath (Lpath.Abs.to_string path) with
  | real -> (
      match Lpath.Abs.of_string real with Ok real -> real | Error _ -> path)
  | exception Unix.Unix_error _ -> path

let is_linux () =
  String.equal Sys.os_type "Unix" && Sys.file_exists "/proc/sys/kernel/ostype"

let is_executable_file path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> (
      match Unix.access path [ Unix.X_OK ] with
      | () -> true
      | exception Unix.Unix_error _ -> false)
  | _ -> false
  | exception Unix.Unix_error _ -> false

(* Expand a leading [~] only against [$HOME]. User-name expansion and relative
   roots are intentionally not ambient shell behavior. *)
let abs_of_config_path ~lookup spelling =
  let expanded =
    if String.equal spelling "~" then lookup "HOME"
    else if
      String.length spelling >= 2 && String.equal (String.sub spelling 0 2) "~/"
    then
      match lookup "HOME" with
      | Some home ->
          Some (home ^ String.sub spelling 1 (String.length spelling - 1))
      | None -> None
    else Some spelling
  in
  match expanded with
  | None -> Error (invalid ~spelling Resolve_error.Not_accessible)
  | Some path ->
      Lpath.Abs.of_string path
      |> Result.map_error (fun _ ->
          invalid ~spelling Resolve_error.Not_accessible)

(* Admit a root only for an existing entry of the right kind, and describe it
   by its physical path so the policy names what the backend binds. *)
let physical_root ~spelling ~directory path =
  let path_string = Lpath.Abs.to_string path in
  match Unix.stat path_string with
  | stats
    when stats.Unix.st_kind = Unix.S_DIR
         || ((not directory) && stats.Unix.st_kind = Unix.S_REG) -> (
      match Unix.realpath path_string |> Lpath.Abs.of_string with
      | Ok path -> Ok path
      | Error _ -> Error (invalid ~spelling Resolve_error.Not_accessible))
  | _ ->
      let reason =
        if directory then Resolve_error.Not_a_directory
        else Resolve_error.Not_a_directory_or_file
      in
      Error (invalid ~spelling reason)
  | exception Unix.Unix_error (error, _, _) ->
      Error (invalid ~spelling (unix_reason error))

let account_home () =
  match (Unix.getpwuid (Unix.getuid ())).Unix.pw_dir |> Lpath.Abs.of_string with
  | Ok home -> Some (canonical home)
  | Error _ -> None
  | exception Not_found -> None

let broad_root ~lookup ~workspace_roots path =
  let root = Lpath.Abs.of_string_exn "/" in
  Lpath.Abs.equal path root
  || List.exists (Lpath.Abs.is_strictly_within ~root:path) workspace_roots
  ||
  let broad_account_home =
    match account_home () with
    | None -> false
    | Some home -> Lpath.Abs.is_within ~root:path home
  in
  let configured_home =
    match lookup "HOME" with
    | None -> false
    | Some home -> (
        match Lpath.Abs.of_string home with
        | Error _ -> false
        | Ok home -> Lpath.Abs.equal path (canonical home))
  in
  broad_account_home || configured_home

let user_root ~field ~directory ~lookup ~workspace_roots spelling =
  let* path = abs_of_config_path ~lookup spelling in
  let* path = physical_root ~spelling ~directory path in
  if broad_root ~lookup ~workspace_roots path then
    Error (Resolve_error.Broad_root { field; spelling })
  else Ok path

let user_roots ~field ~directory ~lookup ~workspace_roots spellings =
  let rec loop roots = function
    | [] -> Ok (List.rev roots)
    | spelling :: rest ->
        let* root =
          user_root ~field ~directory ~lookup ~workspace_roots spelling
        in
        loop (root :: roots) rest
  in
  loop [] spellings

let canonical_paths paths = List.sort_uniq Lpath.Abs.compare paths

(* Collapse redundant descendants: keep only paths not strictly within
   another kept path. *)
let root_paths paths =
  let paths = canonical_paths paths in
  List.filter
    (fun path ->
      not
        (List.exists
           (fun candidate -> Lpath.Abs.is_strictly_within ~root:candidate path)
           paths))
    paths

let unique_paths paths =
  List.fold_left
    (fun unique path ->
      if List.exists (Lpath.Abs.equal path) unique then unique
      else path :: unique)
    [] paths
  |> List.rev

let existing_auto_root path =
  match Lpath.Abs.of_string path with
  | Error _ -> None
  | Ok path -> (
      match Unix.stat (Lpath.Abs.to_string path) with
      | { Unix.st_kind = Unix.S_DIR | Unix.S_REG; _ } -> Some (canonical path)
      | _ -> None
      | exception Unix.Unix_error _ -> None)

(* The parent is canonicalized, the final component is not. Both halves matter.
   A denial is enforced against the path the kernel resolves, so a parent left
   lexical names something the backend never sees: on macOS [/tmp] is a link to
   [/private/tmp], and a denial spelled [/tmp/x] simply does not match the
   [/private/tmp/x] the command opens. The final component stays lexical because
   resolving it would let an agent that can plant a symlink there relocate the
   exclusion at its target. *)
let owned_lexical_path path =
  let spelling = Lpath.Abs.to_string path in
  let parent = Filename.dirname spelling in
  match Unix.realpath parent with
  | real -> (
      match
        Lpath.Abs.of_string (Filename.concat real (Filename.basename spelling))
      with
      | Ok path -> path
      | Error _ -> path)
  | exception Unix.Unix_error _ -> path

(* A directory Mentat owns is created rather than existence-filtered, so the
   sealed policy is not a function of whether the machine happens to have it
   yet: a carveout that is skipped when absent protects the machines that
   already have the directory and nothing on a fresh one, and a denial that is
   skipped when absent cannot be masked at all, because bubblewrap has to create
   the mount point inside a new root it may have already sealed.

   Creation is guarded. Both the cache carveouts and the workspace metadata sit
   under a root the confined agent can write, so an agent that plants a symlink
   where the directory will go would otherwise redirect the exclusion at its
   target and leave the real path grantable. [mkdir] refuses to follow a final
   symlink, and on [EEXIST] the entry is [lstat]ed and rejected unless it is a
   real directory this account owns. The lexical path is what enters the policy;
   [realpath] is deliberately not consulted, because a final component the agent
   can replace must not be able to relocate the exclusion. *)
let owned_directory path =
  let path = owned_lexical_path path in
  let spelling = Lpath.Abs.to_string path in
  let accept () =
    match Unix.lstat spelling with
    | { Unix.st_kind = Unix.S_DIR; st_uid; _ } when st_uid = Unix.getuid () ->
        Ok (Some path)
    | _ -> Error (invalid ~spelling Resolve_error.Not_a_directory)
    | exception Unix.Unix_error (error, _, _) ->
        Error (invalid ~spelling (unix_reason error))
  in
  match Unix.mkdir spelling 0o700 with
  | () -> Ok (Some path)
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> accept ()
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.EACCES | Unix.EPERM), _, _)
    ->
      (* A parent that does not exist or is not ours is not Mentat's to make. *)
      Ok None
  | exception Unix.Unix_error (error, _, _) ->
      Error (invalid ~spelling (unix_reason error))

let owned_directories paths =
  let rec loop kept = function
    | [] -> Ok (List.rev kept)
    | path :: rest -> (
        match owned_directory path with
        | Error _ as error -> error
        | Ok None -> loop kept rest
        | Ok (Some path) -> loop (path :: kept) rest)
  in
  loop [] paths

(* Toolchain state a build resolves under [$HOME]. [HOME] is inherited now, so
   the child and the resolver read the same variables and cannot disagree —
   which is what the carry this replaces existed to paper over, one variable at
   a time, and got wrong.

   Each root is admitted at the base directory its variable names, never at a
   version- or switch-specific descendant. That is load-bearing rather than
   tidy: descendant collapse ([root_paths]) folds every switch-relative root
   into [~/.opam], which is why activating a different opam switch does not move
   the sealed identity and so does not break a suspended turn. Admit
   [~/.opam/repo] instead and every switch change would.

   Only dune's cache is written by the tool these roots exist for — the revision
   store whose lock a pinned-source build must take sits directly under it — so
   the grant is [dune] under the cache (or whatever [DUNE_CACHE_ROOT] names
   instead, as dune reads it), not the shared cache base, whose neighbours
   hold other tools' executables. Its own [db] and [toolchains] are
   carved back out: a cache entry is restored by hardlinking into a later
   unsandboxed build without being re-digested, and a downloaded toolchain is
   executed outright, so neither may be reachable through a grant taken for a
   lock file.

   [toolchains] is the stronger of the two, which is worth stating because its
   name suggests the weaker. It is an installation prefix, not a store: it holds
   the compiler dune runs, dune resolves those binaries ahead of [PATH] and
   prepends their directory to it for package actions, and one install is shared
   by every project on the machine. Nothing checks it — reuse turns on the
   directory being present, and the digest in its name covers the lockfile
   fields rather than the installed bytes, so a replaced binary is
   indistinguishable from the real one. A write here is arbitrary code in the
   user's next unconfined build. *)
let resolved_home ~lookup =
  match lookup "HOME" with
  | Some home when not (String.equal home "") -> Some home
  | _ -> Option.map Lpath.Abs.to_string (account_home ())

let home_relative ~lookup ~var ~default =
  let spelling =
    match lookup var with
    | Some value when not (String.equal value "") -> Some value
    | _ ->
        Option.map
          (fun home -> Filename.concat home default)
          (resolved_home ~lookup)
  in
  Option.bind spelling existing_auto_root

let toolchain_home_roots ~lookup ~workspace_roots =
  let admit = function
    | Some path when not (broad_root ~lookup ~workspace_roots path) -> Some path
    | Some path ->
        Log.warn (fun m ->
            m "ignoring toolchain root %S: broad root"
              (Lpath.Abs.to_string path));
        None
    | None -> None
  in
  let under base sub =
    Option.bind base (fun base ->
        existing_auto_root (Filename.concat (Lpath.Abs.to_string base) sub))
  in
  let opam = admit (home_relative ~lookup ~var:"OPAMROOT" ~default:".opam") in
  let config =
    home_relative ~lookup ~var:"XDG_CONFIG_HOME" ~default:".config"
  in
  let cache = home_relative ~lookup ~var:"XDG_CACHE_HOME" ~default:".cache" in
  let dune_config = admit (under config "dune") in
  (* uv aborts outright when reading [uv.toml] returns [EPERM], the same
     failure shape git has with its global config, so its config directory is
     admitted alongside dune's. Neither holds credentials by convention. *)
  let uv_config = admit (under config "uv") in
  (* The cache is materialized rather than merely observed, and the two
     carveouts with it. Observing was the obvious reading — grant what is there —
     but it makes the grant a function of machine state in both directions, and
     both are wrong. A machine that has never run dune has no `~/.cache/dune`,
     so the write grant this whole campaign added to fix the revision-store lock
     is simply absent on the one machine that most needs it. Worse, a machine
     that has the cache but no `db` yet gets the enclosing write grant with no
     read carveout inside it, and a confined build may then fill the cache a
     later unconfined build restores from by hardlink, without re-digesting.

     So the directories are created — under the same guard Mentat's own use,
     which refuses to adopt a symlink, a non-directory, or another user's
     directory — and the write grant is issued only if both carveouts are in
     place. If either cannot be secured the cache is not granted at all, which
     costs a cold build its cache and never trades away the next one. *)
  let owned = function
    | Error _ -> None
    | Ok path -> (
        match owned_directory path with
        | Ok (Some path) -> Some (canonical path)
        | Ok None -> None
        | Error _ ->
            Log.warn (fun m ->
                m "ignoring toolchain root %S: not usable"
                  (Lpath.Abs.to_string path));
            None)
  in
  let owned_under base sub =
    Option.bind base (fun base ->
        owned
          (Lpath.Abs.of_string (Filename.concat (Lpath.Abs.to_string base) sub)))
  in
  (* Dune resolves its cache root from [DUNE_CACHE_ROOT] before the XDG cache
     base, and the child inherits the variable, so the grant follows the same
     resolution: whatever the variable names, else [dune] under the cache base.
     Dune refuses a relative spelling outright, so none is granted either. *)
  let dune_cache_base, dune_cache_label =
    match lookup "DUNE_CACHE_ROOT" with
    | Some root when not (String.equal root "") ->
        (owned (Lpath.Abs.of_string root), "DUNE_CACHE_ROOT")
    | _ -> (owned_under cache "dune", "XDG_CACHE_HOME")
  in
  let dune_cache, carveouts =
    match admit dune_cache_base with
    | None -> (None, [])
    | Some base ->
        let secured =
          List.map
            (fun sub -> owned_under (Some base) sub)
            [ "db"; "toolchains"; "git-repo"; "rev_store" ]
        in
        if List.for_all Option.is_some secured then
          (Some base, List.filter_map Fun.id secured)
        else (None, [])
  in
  let describe =
    List.filter_map
      (fun (label, path) ->
        Option.map (fun p -> ("toolchain:" ^ label, p)) path)
      [
        ("OPAMROOT", opam);
        ("XDG_CONFIG_HOME", dune_config);
        ("XDG_CONFIG_HOME", uv_config);
        (dune_cache_label, dune_cache);
      ]
  in
  ( Option.to_list opam @ Option.to_list dune_config @ Option.to_list uv_config,
    Option.to_list dune_cache,
    carveouts,
    describe )

(* Git treats a denied read of its global configuration as fatal rather than
   absent: [ENOENT] and [EACCES] mean "no config" and are skipped, but the
   [EPERM] a sandbox denial returns aborts every git command before it does
   anything, [git status] included. [HOME] is inherited, so git resolves the
   real files, and dune's package revision store runs git underneath every
   build of a pinned project — the breakage surfaces far from its cause. So
   the files git actually resolves are admitted, read-only. Credential state
   ([~/.git-credentials], helper stores) lives outside all of them.

   [GIT_CONFIG_GLOBAL] replaces both default paths when set, and an empty
   value names nothing, so the admitted roots follow the same resolution. *)
let git_config_roots ~lookup ~workspace_roots =
  let admit = function
    | Some path when not (broad_root ~lookup ~workspace_roots path) -> Some path
    | Some path ->
        Log.warn (fun m ->
            m "ignoring git config root %S: broad root"
              (Lpath.Abs.to_string path));
        None
    | None -> None
  in
  let candidates =
    match lookup "GIT_CONFIG_GLOBAL" with
    | Some "" -> []
    | Some spelling -> [ existing_auto_root spelling ]
    | None ->
        let config_git =
          Option.bind
            (home_relative ~lookup ~var:"XDG_CONFIG_HOME" ~default:".config")
            (fun base ->
              existing_auto_root
                (Filename.concat (Lpath.Abs.to_string base) "git"))
        in
        let gitconfig =
          Option.bind (resolved_home ~lookup) (fun home ->
              existing_auto_root (Filename.concat home ".gitconfig"))
        in
        [ config_git; gitconfig ]
  in
  List.filter_map admit candidates

let platform_roots ~lookup ~workspace_roots =
  let candidates =
    if is_linux () then
      [
        "/bin";
        "/sbin";
        "/usr";
        "/etc";
        "/lib";
        "/lib64";
        "/nix/store";
        "/run/current-system/sw";
      ]
    else
      [
        "/bin";
        "/sbin";
        "/usr/bin";
        "/usr/sbin";
        "/usr/lib";
        "/usr/libexec";
        "/usr/share";
        "/System/Library";
        "/System/iOSSupport/System/Library";
        "/Library/Apple/System/Library";
        "/Library/Apple/usr/lib";
        "/Library/Filesystems/NetFSPlugins";
        "/Library/Preferences";
        "/opt/homebrew";
        "/usr/local/Cellar";
        "/usr/local/opt";
        "/usr/local/lib";
        "/usr/local/share";
        "/private/etc";
        "/private/var/db";
        (* Apple's developer-tool shims (/usr/bin/git, cc, make) resolve
           through the xcode-select data link at /private/var/select into the
           active developer directory; without all three of these, every
           CLT-backed tool fails confined with "unable to read data link at
           /var/select/developer_dir". *)
        "/private/var/select";
        "/Library/Developer";
        "/Applications/Xcode.app";
      ]
  in
  let roots =
    List.concat_map
      (fun spelling ->
        match Lpath.Abs.of_string spelling with
        | Error _ -> []
        | Ok lexical -> (
            match Unix.stat spelling with
            | { Unix.st_kind = Unix.S_DIR | Unix.S_REG; _ } ->
                (* Profiles bind by pathname, so admit both spellings when the
                   lexical path is a symlink to its physical one. *)
                let physical = canonical lexical in
                if Lpath.Abs.equal lexical physical then [ lexical ]
                else [ lexical; physical ]
            | _ -> []
            | exception Unix.Unix_error _ -> []))
      candidates
  in
  match List.find_opt (broad_root ~lookup ~workspace_roots) roots with
  | None -> Ok roots
  | Some path ->
      Error
        (Resolve_error.Broad_root
           { field = "platform"; spelling = Lpath.Abs.to_string path })

let path_roots ~scoped ~lookup ~workspace_roots =
  let value = Option.value (lookup "PATH") ~default:"" in
  let segments = String.split_on_char ':' value in
  let rec loop roots = function
    | [] -> Ok (List.rev roots)
    | segment :: rest -> (
        match Lpath.Abs.of_string segment with
        | Error _ ->
            Error (invalid ~spelling:segment Resolve_error.Not_accessible)
        | Ok path -> (
            let spelling = Lpath.Abs.to_string path in
            match Unix.stat spelling with
            | { Unix.st_kind = Unix.S_DIR; _ } ->
                let path = canonical path in
                if scoped && broad_root ~lookup ~workspace_roots path then
                  Error (Resolve_error.Broad_root { field = "PATH"; spelling })
                else loop (path :: roots) rest
            | _ -> Error (invalid ~spelling Resolve_error.Not_a_directory)
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> loop roots rest
            | exception Unix.Unix_error (error, _, _) ->
                Error (invalid ~spelling (unix_reason error))))
  in
  loop [] segments

(* The executable environment resolves PATH and the toolchain variables the
   way the OCaml toolchain ladder would for a spawned build tool, so the sandbox
   admits the directories dune-family tools actually run from — and, through
   {!Mentat_ocaml_toolchain.toolchain_env}, the switch [bin] directory dune
   hands its child compiler, which a [dune] found on [PATH] would otherwise not
   carry. This same PATH becomes the child's PATH downstream, so bridging it
   here both admits the switch as a read root and puts the compiler on the
   child's search path. *)
let executable_env ~lookup ~project_root =
  let bindings =
    List.filter_map
      (fun name -> Option.map (fun value -> name ^ "=" ^ value) (lookup name))
      [ "PATH"; "OPAM_SWITCH_PREFIX"; "MENTAT_DUNE" ]
    |> Array.of_list
  in
  let toolchain =
    Mentat_ocaml_toolchain.discover ~env:bindings
      ~workspace_root:(Some (Lpath.Abs.to_string project_root))
  in
  let bindings = Mentat_ocaml_toolchain.toolchain_env toolchain in
  fun name ->
    Array.find_map
      (fun binding ->
        match String.index_opt binding '=' with
        | Some index when String.equal (String.sub binding 0 index) name ->
            Some
              (String.sub binding (index + 1)
                 (String.length binding - index - 1))
        | Some _ | None -> None)
      bindings
    |> Option.fold ~none:(lookup name) ~some:Option.some

(* An executable on [PATH] usually reads runtime data beside itself, so a
   [bin]/[sbin] entry also admits the sibling directories that hold it. Only
   those siblings: admitting the whole prefix would make the read scope a
   function of the launcher's [PATH], which is exactly the wrong thing to derive
   authority from — a per-user tool installed under [$HOME] would contribute its
   entire tree, so [~/.local/bin] on [PATH] admits [~/.local] and with it every
   application's data, Mentat's own session store included. The prefix of a
   [PATH] entry is where a tool happens to live, not a statement about what a
   build needs to read. *)
let executable_runtime_roots ~lookup ~scope_roots executable_roots =
  List.concat_map
    (fun executable_root ->
      match
        (Lpath.Abs.basename executable_root, Lpath.Abs.parent executable_root)
      with
      | Some ("bin" | "sbin"), Some prefix ->
          List.filter_map
            (fun component ->
              match Lpath.Abs.add_component prefix component with
              | Error _ -> None
              | Ok candidate -> (
                  match existing_auto_root (Lpath.Abs.to_string candidate) with
                  | Some root
                    when not
                           (broad_root ~lookup ~workspace_roots:scope_roots root)
                    ->
                      Some root
                  | Some _ | None -> None))
            [ "etc"; "lib"; "libexec"; "share" ]
      | _ -> [])
    executable_roots
  |> root_paths

let toolchain_roots ~lookup ~workspace_roots =
  let variables =
    [
      ("CAML_LD_LIBRARY_PATH", true);
      ("OCAMLPATH", true);
      ("OCAML_TOPLEVEL_PATH", false);
      ("OPAM_SWITCH_PREFIX", false);
      ("OCAMLLIB", false);
      ("DUNE_OCAML_STDLIB", false);
    ]
  in
  (* Ambient toolchain values recover the launcher's real toolchain layout;
     they are best-effort, not user intent. A value
     that names no usable directory is dropped with a logged warning so the
     derived read scope only narrows and a stray artifact never bricks startup:
     [dune exec] leaks unexpanded placeholders ([OCAML_TOPLEVEL_PATH=%{toplevel}%]),
     PATH-like values carry empty segments, and a variable can point at a file or
     a since-removed directory. Two cases still fail closed: a value resolving to
     a broad root (/ or $HOME) would silently widen reads to everything, and
     configured roots ([sandbox.readable_roots]/[writable_roots], see [user_roots])
     are an explicit request whose garbage is a real config error. *)
  let rec add_values name roots = function
    | [] -> Ok roots
    | spelling :: rest -> (
        let skip reason =
          Log.warn (fun m ->
              m "ignoring toolchain root %s=%S: %s" name spelling reason);
          add_values name roots rest
        in
        match Lpath.Abs.of_string spelling with
        | Error _ -> skip "not an absolute path"
        | Ok path -> (
            match Unix.stat spelling with
            | { Unix.st_kind = Unix.S_DIR; _ } ->
                let path = canonical path in
                if broad_root ~lookup ~workspace_roots path then
                  Error
                    (Resolve_error.Broad_root
                       { field = name; spelling = Lpath.Abs.to_string path })
                else add_values name ((name, path) :: roots) rest
            | _ -> skip "not a directory"
            | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                add_values name roots rest
            | exception Unix.Unix_error (error, _, _) ->
                skip (Unix.error_message error)))
  in
  let rec loop roots = function
    | [] -> Ok roots
    | (name, list) :: rest ->
        let values =
          match lookup name with
          | None -> []
          | Some value when list -> String.split_on_char ':' value
          | Some value -> [ value ]
        in
        let* roots = add_values name roots values in
        loop roots rest
  in
  loop [] variables

let opam_bin_root ~lookup toolchain_roots =
  match
    List.find_opt
      (fun (name, _) -> String.equal name "OPAM_SWITCH_PREFIX")
      toolchain_roots
  with
  | Some (_, prefix) -> (
      match Lpath.Abs.add_component prefix "bin" with
      | Error _ -> None
      | Ok path -> existing_auto_root (Lpath.Abs.to_string path))
  | None -> (
      match lookup "OPAM_SWITCH_PREFIX" with
      | None -> None
      | Some prefix -> existing_auto_root (Filename.concat prefix "bin"))

let environment_path ~scoped ~path_roots ~toolchain_roots ~lookup =
  let admitted = Option.to_list (opam_bin_root ~lookup toolchain_roots) in
  let paths =
    if scoped then
      admitted @ path_roots |> unique_paths |> List.map Lpath.Abs.to_string
    else List.map Lpath.Abs.to_string admitted @ Option.to_list (lookup "PATH")
  in
  String.concat ":" paths

let existing_entry root name =
  match Lpath.Abs.add_component root name with
  | Error _ -> None
  | Ok path -> (
      match Unix.lstat (Lpath.Abs.to_string path) with
      | _ -> Some path
      | exception Unix.Unix_error _ -> None)

let protected_meta_paths root =
  List.filter_map (existing_entry root) Mentat_workspace.protected_meta_names

(* The session-run directory. A supervised build watch is spawned with a
   private [XDG_RUNTIME_DIR] at [<primary>/.mentat/run/<session>], and dune
   creates and writes its registry entry beneath it at server start — so the
   confined watch must be able to write under [.mentat/run] even though the
   [.mentat] carveout keeps the rest of the project's own directory read-only
   to confined commands. The grant is derived exactly when the carveout that
   would otherwise deny it is: when [.mentat] already exists. A workspace
   without [.mentat] needs neither — the primary write clause covers whatever
   a supervisor creates there. The directory is materialized here because the
   Linux backend binds every clause path at spawn.

   Both components are repository content, so both are guarded the way every
   materialized owned path is: [.mentat] must be a real directory this
   account owns — a tracked symlink is never traversed — and the [run]
   component goes through {!owned_directory}, whose [EEXIST] arm [lstat]s and
   fails resolution closed on a planted entry, and whose lexical path is what
   enters the writable lattice. Consulting [realpath] here would let a
   repository ship [.mentat/run -> ~/.ssh] and turn a trusted clone into an
   arbitrary host write grant for every confined command. *)
let session_run_dirs primary =
  match existing_entry primary ".mentat" with
  | None -> Ok []
  | Some meta -> (
      match Unix.lstat (Lpath.Abs.to_string meta) with
      | { Unix.st_kind = Unix.S_DIR; st_uid; _ }
        when st_uid = Unix.getuid () -> (
          match Lpath.Abs.add_component meta Mentat_workspace.run_dir_name with
          | Error _ -> Ok []
          | Ok run -> Result.map Option.to_list (owned_directory run))
      | _ -> Ok []
      | exception Unix.Unix_error _ -> Ok [])

let read_metadata_path path =
  let spelling = Lpath.Abs.to_string path in
  match open_in_bin spelling with
  | input ->
      Fun.protect
        ~finally:(fun () -> close_in input)
        (fun () ->
          let length = in_channel_length input in
          if length > 4096 then
            Error (invalid ~spelling Resolve_error.Not_accessible)
          else
            let value = really_input_string input length |> String.trim in
            if
              String.equal value "" || String.contains value '\n'
              || String.contains value '\r'
            then Error (invalid ~spelling Resolve_error.Not_accessible)
            else Ok value)
  | exception Sys_error _ ->
      Error (invalid ~spelling Resolve_error.Not_accessible)

let resolve_metadata_dir ~lookup ~workspace_roots ~base spelling =
  let* path =
    Lpath.Abs.resolve_any ~base spelling
    |> Result.map_error (fun _ ->
        invalid ~spelling Resolve_error.Not_accessible)
  in
  let* path = physical_root ~spelling ~directory:true path in
  if broad_root ~lookup ~workspace_roots path then
    Error
      (Resolve_error.Broad_root
         { field = "project gitdir"; spelling = Lpath.Abs.to_string path })
  else Ok path

(* A linked git worktree keeps its metadata outside the project root; the
   [gitdir] and [commondir] targets must be readable and protected or git
   cannot run at all. *)
let linked_git_roots ~lookup ~scope_roots project_root =
  match Lpath.Abs.add_component project_root ".git" with
  | Error _ -> Ok []
  | Ok git -> (
      let spelling = Lpath.Abs.to_string git in
      match Unix.lstat spelling with
      | { Unix.st_kind = Unix.S_DIR; _ } -> Ok []
      | { Unix.st_kind = Unix.S_REG; _ } -> (
          let* line = read_metadata_path git in
          let prefix = "gitdir: " in
          if not (String.starts_with ~prefix line) then
            Error (invalid ~spelling Resolve_error.Not_accessible)
          else
            let target =
              String.sub line (String.length prefix)
                (String.length line - String.length prefix)
            in
            let* gitdir =
              resolve_metadata_dir ~lookup ~workspace_roots:scope_roots
                ~base:project_root target
            in
            match Lpath.Abs.add_component gitdir "commondir" with
            | Error _ -> Ok [ gitdir ]
            | Ok commondir -> (
                match Unix.lstat (Lpath.Abs.to_string commondir) with
                | { Unix.st_kind = Unix.S_REG; _ } ->
                    let* target = read_metadata_path commondir in
                    let* common =
                      resolve_metadata_dir ~lookup ~workspace_roots:scope_roots
                        ~base:gitdir target
                    in
                    Ok [ common; gitdir ]
                | _ -> Ok [ gitdir ]
                | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok [ gitdir ]
                | exception Unix.Unix_error (error, _, _) ->
                    Error
                      (invalid
                         ~spelling:(Lpath.Abs.to_string commondir)
                         (unix_reason error))))
      | _ -> Error (invalid ~spelling Resolve_error.Not_a_directory_or_file)
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
      | exception Unix.Unix_error (error, _, _) ->
          Error (invalid ~spelling (unix_reason error)))

let workspace_root ~scoped ~lookup root =
  let dir = Mentat_workspace.Root.dir root in
  let spelling = Lpath.Abs.to_string dir in
  match physical_root ~spelling ~directory:true dir with
  | Error _ -> Error (Resolve_error.Missing_root root)
  | Ok path ->
      if scoped && broad_root ~lookup ~workspace_roots:[] path then
        Error (Resolve_error.Broad_root { field = "workspace"; spelling })
      else Ok path

let workspace_roots ~scoped ~lookup logical =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | root :: rest ->
        let* path = workspace_root ~scoped ~lookup root in
        loop ((root, path) :: acc) rest
  in
  loop [] (Mentat_workspace.roots logical)

let roots_overlap a b =
  Lpath.Abs.is_within ~root:a b || Lpath.Abs.is_within ~root:b a

(* [/tmp] is where a command puts a scratch file when it does not consult the
   environment for one, and a literal [/tmp/...] path is common enough in build
   scripts and in model-authored commands that its absence reads as a broken
   sandbox rather than a confined one.

   The launcher's temp-dir family joins it. The child inherits all three names,
   and what reads them is not one convention but several: libc helpers take
   [TMPDIR], Node and Python fall through [TMPDIR] then [TEMP] then [TMP]. So
   the set that must be granted is the set that is inherited — grant only
   [TMPDIR] and a launcher that sets [TMP] alone hands the child a path no bind
   covers, which is the very defect this file records for [/tmp]. Each is
   admitted only where it exists and does not resolve broad; a broad one is
   dropped rather than admitted. Canonicalized, because macOS resolves the
   bucket to [/private/tmp]. *)
let temp_variables = [ "TMPDIR"; "TEMP"; "TMP" ]

let shared_temp_dirs ~lookup ~workspace_roots =
  let ambient =
    List.concat_map
      (fun variable ->
        match lookup variable with
        | None -> []
        | Some spelling -> (
            match existing_auto_root spelling with
            | Some path when not (broad_root ~lookup ~workspace_roots path) ->
                [ path ]
            | Some _ | None -> []))
      temp_variables
  in
  List.filter_map existing_auto_root [ "/tmp" ] @ ambient

(* Apple's developer-tool shims (git, xcrun, clang) cache under the per-user
   confstr [DARWIN_USER_CACHE_DIR] — the [C] sibling of the [T] temp bucket —
   which no environment redirect can move; without it every CLT-backed tool
   fails confined ("couldn't create cache file"). The directory is created
   0700 by the system for this user alone, so admitting it as a writable root
   keeps the workspace-write posture: no other user's or project's state is
   reachable through it. Linux has no analogue. *)
let darwin_user_dirs ~lookup =
  if is_linux () then []
  else
    match lookup "TMPDIR" with
    | None -> []
    | Some spelling -> (
        match Lpath.Abs.of_string spelling with
        | Error _ -> []
        | Ok path ->
            let temp = canonical path in
            let temp_spelling = Lpath.Abs.to_string temp in
            if not (String.equal (Filename.basename temp_spelling) "T") then []
            else
              let existing_dir spelling =
                match Unix.stat spelling with
                | { Unix.st_kind = Unix.S_DIR; _ } ->
                    Some (canonical (Lpath.Abs.of_string_exn spelling))
                | _ -> None
                | exception Unix.Unix_error _ -> None
              in
              List.filter_map existing_dir
                [
                  temp_spelling;
                  Filename.concat (Filename.dirname temp_spelling) "C";
                ])

(* A configured writable root that overlaps an admitted read-only root would
   grant writes the admission forbids; refuse it as over-broad. *)
let reject_read_only_writes read_only configured =
  match
    List.find_opt
      (fun configured -> List.exists (roots_overlap configured) read_only)
      configured
  with
  | None -> Ok ()
  | Some path ->
      Error
        (Resolve_error.Broad_root
           {
             field = "sandbox.writable_roots";
             spelling = Lpath.Abs.to_string path;
           })

let run ~scoped ~lookup ~logical ~configured_reads ~configured_writes
    ~mentat_dirs =
  let* roots = workspace_roots ~scoped ~lookup logical in
  let primary, read_only =
    match roots with
    | (_, primary) :: rest -> (primary, List.map snd rest)
    | [] -> assert false (* a workspace always admits a primary root *)
  in
  let scope_roots = List.map snd roots in
  let* configured_reads =
    if scoped then
      user_roots ~field:"sandbox.readable_roots" ~directory:false ~lookup
        ~workspace_roots:scope_roots configured_reads
    else Ok []
  in
  let* configured_writes =
    user_roots ~field:"sandbox.writable_roots" ~directory:true ~lookup
      ~workspace_roots:scope_roots configured_writes
  in
  let* () = reject_read_only_writes read_only configured_writes in
  (* The switch bridge runs on every route, scoped or not: a spawned [dune] needs
     the compiler on its [PATH] whether or not reads are project-scoped, and the
     child [PATH] below is built from this lookup. Only the read-root derivation
     (executable/toolchain/platform roots) is gated on [scoped]. *)
  let exec_lookup = executable_env ~lookup ~project_root:primary in
  let* executable_roots =
    if scoped then
      path_roots ~scoped:true ~lookup:exec_lookup ~workspace_roots:scope_roots
    else Ok []
  in
  let runtime_roots =
    if scoped then
      executable_runtime_roots ~lookup ~scope_roots executable_roots
    else []
  in
  let* toolchain =
    if scoped then toolchain_roots ~lookup ~workspace_roots:scope_roots
    else Ok []
  in
  let* platform =
    if scoped then platform_roots ~lookup ~workspace_roots:scope_roots
    else Ok []
  in
  let* git =
    if scoped then linked_git_roots ~lookup ~scope_roots primary else Ok []
  in
  let path =
    environment_path ~scoped ~path_roots:executable_roots
      ~toolchain_roots:toolchain ~lookup:exec_lookup
  in
  let toolchain_reads, toolchain_writes, toolchain_carveouts, toolchain_describe
      =
    toolchain_home_roots ~lookup ~workspace_roots:scope_roots
  in
  let git_config =
    if scoped then git_config_roots ~lookup ~workspace_roots:scope_roots else []
  in
  let readable =
    if scoped then
      root_paths
        (scope_roots @ configured_reads @ platform @ executable_roots
       @ runtime_roots @ List.map snd toolchain @ git @ toolchain_reads
       @ git_config)
    else []
  in
  let protected =
    protected_meta_paths primary @ read_only @ git @ toolchain_carveouts
    |> canonical_paths
  in
  let* denied = owned_directories mentat_dirs in
  let* session_writes = session_run_dirs primary in
  let writable_lattice =
    (primary :: configured_writes)
    @ session_writes
    @ shared_temp_dirs ~lookup ~workspace_roots:scope_roots
    @ darwin_user_dirs ~lookup @ toolchain_writes
  in
  (* Only an overlap in one direction is a problem. A denial nested inside a
     granted root masks that subtree and leaves the rest of the root intact,
     which is exactly what a store kept inside the workspace needs. A denial
     that contains a granted root masks the root itself, and the agent cannot
     tell an emptied workspace from a deleted one.

     Both kinds of grant are checked, not only the writable ones. A read root
     inside a denied path is the shape a user reaches by pointing
     [sandbox.readable_roots] at something under Mentat's own config home, and
     the backends resolve it exactly as the law says — the deeper grant wins —
     which is the problem, not a bug to work around: it opens the store whose
     confinement identity a resume revalidates against. Refuse it here, where
     the diagnostic can name both paths and the variable to move. *)
  let* () =
    let granted_lattice = writable_lattice @ readable in
    match
      List.find_map
        (fun denied ->
          List.find_map
            (fun granted ->
              if Lpath.Abs.is_within ~root:denied granted then
                Some (denied, granted)
              else None)
            granted_lattice)
        denied
    with
    | None -> Ok ()
    | Some (denied, granted) ->
        Error
          (Resolve_error.Denied_overlaps_grant
             {
               denied = Lpath.Abs.to_string denied;
               granted = Lpath.Abs.to_string granted;
             })
  in
  let describe =
    if scoped then
      [ ("project", primary) ]
      @ List.map (fun p -> ("user-configured", p)) configured_reads
      @ List.map (fun p -> ("platform", p)) platform
      @ List.map (fun p -> ("executable:PATH", p)) executable_roots
      @ List.map (fun p -> ("executable:PATH runtime", p)) runtime_roots
      @ List.map (fun (name, p) -> ("toolchain:" ^ name, p)) toolchain
      @ toolchain_describe
      @ List.map (fun p -> ("git-worktree", p)) git
      @ List.map (fun p -> ("git-config", p)) git_config
    else []
  in
  Ok
    {
      workspace_roots = roots;
      writable = (primary :: configured_writes) @ session_writes;
      platform_writable = shared_temp_dirs ~lookup ~workspace_roots:scope_roots;
      toolchain_writable = darwin_user_dirs ~lookup @ toolchain_writes;
      readable;
      protected;
      denied;
      path;
      describe;
    }
