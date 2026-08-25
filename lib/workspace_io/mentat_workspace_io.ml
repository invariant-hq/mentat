(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Resolve_error = Resolve_error
module Env_policy = Child_env.Policy
module File_error = File_error

let ( let* ) = Result.bind

(* Claim scope.

   The attribution window for one tool claim. The window lives on the
   capability because the native-write enforcer does: {!Edit.apply} records
   the workspace effect of every apply — successful results, and the
   committed prefix and uncertain commit target of failed ones — into the
   window it started under; {!observe} is the intake for observational
   attribution. Lists are kept in reverse order until [close] yields the
   evidence.

   Two flags separate intake from harvest. [sealed] stops intake: a later
   {!open_claim_scope} seals the window it supersedes, because a claim
   cancelled before it could [close] must not wedge the capability. [closed]
   marks the one-shot harvest: [close] on a sealed window still yields
   everything recorded up to the supersession; a second [close], or an
   [observe] after sealing, is a programmer error. *)

module Claim_scope = struct
  type t = {
    mutable sealed : bool; (* intake stopped; a successor window opened *)
    mutable closed : bool; (* harvested; the window is spent *)
    mutable applies : Mentat_edit.Apply_evidence.apply list;
        (* one chronological list, reverse application order: successes and
           effectful failures record in the order they occur *)
    mutable observed : Mentat_workspace.Path.t list; (* reverse intake order *)
  }

  let observe scope path =
    if scope.sealed || scope.closed then invalid_arg "claim scope is closed";
    scope.observed <- path :: scope.observed

  (* Observational attribution covers what the native path could not: a path
     an apply already recorded — a confirmed transition or the uncertain
     commit target — is authoritative evidence, and a duplicate observation
     would demote it to an unexplained window change. *)
  let native_paths applies =
    List.concat_map
      (function
        | Mentat_edit.Apply_evidence.Applied result ->
            List.map Mentat_edit.Result.Entry.target_path
              (Mentat_edit.Result.entries result)
        | Mentat_edit.Apply_evidence.Attempted
            { Mentat_edit.Apply_evidence.Attempt.applied; uncertain } ->
            List.map Mentat_edit.Result.Entry.target_path applied
            @ Option.to_list uncertain)
      applies

  let close scope =
    if scope.closed then invalid_arg "claim scope is closed";
    scope.closed <- true;
    scope.sealed <- true;
    let applies = List.rev scope.applies in
    let native = native_paths applies in
    let observed =
      List.filter
        (fun path ->
          not (List.exists (Mentat_workspace.Path.equal path) native))
        (List.rev scope.observed)
    in
    { Mentat_edit.Apply_evidence.applies; observed }
end

(* One admitted root: its logical identity, the canonical directory recorded
   at resolution, and two capabilities opened once under the resolve switch —
   the Eio directory the read paths resolve beneath, and the raw descriptor
   the no-follow write traversal starts from. [depth] orders
   most-specific-root binding. *)
type root = {
  root : Mentat_workspace.Root.t;
  canonical : Lpath.Abs.t;
  depth : int;
  writable : bool;
  opened : Eio.Fs.dir_ty Eio.Path.t;
  dirfd : Unix.file_descr;
  identity : int * int; (* [(st_dev, st_ino)] of the inode opened here. *)
}

type t = {
  logical : Mentat_workspace.t;
  roots : root list;
  environment : string array;
  path_dirs : string list;
  sandbox : Mentat_sandbox.t;
  described_roots : (string * Lpath.Abs.t) list;
  read_only : bool;
  fs : Eio.Fs.dir_ty Eio.Path.t;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Std.r;
  mono : Eio.Time.Mono.ty Eio.Std.r;
  edit_lock : Eio.Mutex.t;
  mutable claim_scope : Claim_scope.t option;
}

(* The per-physical-workspace edit lock.

   [Mentat_edit.Apply.io.with_write_lock] demands a critical section that
   serializes writes to every target — which one mutex per resolved [t]
   cannot provide when two capabilities open the same physical workspace.
   Locks are therefore keyed by the opened primary root's identity, so every
   capability this process resolves over one workspace shares one lock. The
   table is tiny (one entry per distinct workspace) and entries are never
   removed. Serializing cooperating Mentat *processes* needs an OS-backed
   mechanism this deliberately does not fake; an external writer takes no
   lock and races remain ambiguous by contract. *)

let edit_locks : (int * int, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 4
let edit_locks_mutex = Mutex.create ()

let edit_lock_for key =
  Mutex.protect edit_locks_mutex (fun () ->
      match Hashtbl.find_opt edit_locks key with
      | Some lock -> lock
      | None ->
          let lock = Eio.Mutex.create () in
          Hashtbl.add edit_locks key lock;
          lock)

let process_environment () =
  Array.to_list (Unix.environment ())
  |> List.filter_map (fun binding ->
      match String.index_opt binding '=' with
      | None -> None
      | Some i ->
          Some
            ( String.sub binding 0 i,
              String.sub binding (i + 1) (String.length binding - i - 1) ))

(* The ambient environment is supplied by the caller and indexed exactly once,
   at resolution: a lookup by name (first binding wins, as execve would), and
   the names themselves for the families the child inherits by prefix. The
   caller decides whose environment "ambient" means — the process's own for a
   local run, the invoking client's snapshot for a daemon-hosted one — because
   a daemon that resolved from its own environment would configure every
   child from whichever shell happened to spawn it first. *)
let index_environment environment =
  let table = Hashtbl.create (List.length environment) in
  (* A snapshot of a real process environment cannot hold these, but the list
     may arrive over the wire from a raw client: a name that is empty or
     carries ['='] or NUL would smuggle or truncate an exec binding, so such
     bindings are dropped rather than indexed. *)
  let well_formed name value =
    (not (String.equal name ""))
    && (not (String.contains name '='))
    && (not (String.contains name '\000'))
    && not (String.contains value '\000')
  in
  List.iter
    (fun (name, value) ->
      if well_formed name value && not (Hashtbl.mem table name) then
        Hashtbl.add table name value)
    environment;
  let names = Hashtbl.fold (fun name _ names -> name :: names) table [] in
  ((fun name -> Hashtbl.find_opt table name), names)

let open_roots ~sw ~fs ~logical workspace_roots =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (root, canonical) :: rest -> (
        let spelling = Lpath.Abs.to_string canonical in
        match Eio.Path.open_subtree ~sw (Eio.Path.( / ) fs spelling) with
        | exception Eio.Exn.Io (cause, _) ->
            Error
              (Resolve_error.Io
                 { operation = "open workspace root"; spelling; cause })
        | opened -> (
            match Nofollow.open_dir spelling with
            | exception Unix.Unix_error (code, fn, arg) ->
                Error
                  (Resolve_error.Io
                     {
                       operation = "open workspace root";
                       spelling;
                       cause = Eio.Exn.X (Eio_unix.Unix_error (code, fn, arg));
                     })
            | dirfd -> (
                Eio.Switch.on_release sw (fun () ->
                    match Unix.close dirfd with
                    | () -> ()
                    | exception Unix.Unix_error _ -> ());
                match Unix.fstat dirfd with
                | exception Unix.Unix_error (code, fn, arg) ->
                    Error
                      (Resolve_error.Io
                         {
                           operation = "open workspace root";
                           spelling;
                           cause =
                             Eio.Exn.X (Eio_unix.Unix_error (code, fn, arg));
                         })
                | stat ->
                    let entry =
                      {
                        root;
                        canonical;
                        depth = List.length (Lpath.Abs.components canonical);
                        writable = Mentat_workspace.is_writable logical root;
                        opened;
                        dirfd;
                        identity = (stat.Unix.st_dev, stat.Unix.st_ino);
                      }
                    in
                    loop (entry :: acc) rest)))
  in
  loop [] workspace_roots

(* Display facts keep only roots the sealed policy actually reads, without
   duplicates, in display order. *)
let described_roots ~sandbox facts =
  match Mentat_sandbox.policy sandbox with
  | None -> []
  | Some policy -> (
      match Mentat_sandbox.Policy.reads_default policy with
      | Mentat_sandbox.Policy.All -> []
      | Mentat_sandbox.Policy.Denied ->
          let admitted = Mentat_sandbox.Policy.readable_roots policy in
          List.fold_left
            (fun acc ((_, path) as fact) ->
              if
                List.exists (Lpath.Abs.equal path) admitted
                && not
                     (List.exists
                        (fun (_, seen) -> Lpath.Abs.equal path seen)
                        acc)
              then fact :: acc
              else acc)
            [] facts
          |> List.rev)

let resolve ~sw ~stdenv ~logical ~environment
    ?(env_policy = Child_env.Policy.default) ~mode ~read ~readable_roots
    ~writable_roots ~mentat_dirs ~network () =
  let lookup, ambient_names = index_environment environment in
  let fs = Eio.Stdenv.fs stdenv in
  let confined =
    match mode with
    | Mentat_config.Mode.Read_only | Mentat_config.Mode.Workspace_write -> true
    | Mentat_config.Mode.Danger_full_access
    | Mentat_config.Mode.External_sandbox ->
        false
  in
  let scoped =
    confined
    &&
    match read with
    | Mentat_config.Read.Project -> true
    | Mentat_config.Read.All -> false
  in
  (* Derivation's blocking filesystem batch (stat, realpath, getpwuid,
     git-worktree reads) is a bounded startup batch, moved off the Eio domain
     into one systhread so a slow filesystem or name service cannot stall the
     whole domain (B8); opening the capabilities stays on the fiber, below. *)
  let* derived =
    Eio_unix.run_in_systhread ~label:"workspace_io.derive" (fun () ->
        Derive.run ~scoped ~lookup ~logical ~mentat_dirs
          ~configured_reads:(if scoped then readable_roots else [])
          ~configured_writes:writable_roots)
  in
  let capability () =
    let env =
      Child_env.make ~path:derived.Derive.path ~lookup ~names:ambient_names
        ~policy:env_policy
    in
    let sandbox =
      match mode with
      | Mentat_config.Mode.Danger_full_access -> Mentat_sandbox.direct
      | Mentat_config.Mode.External_sandbox -> Mentat_sandbox.external_
      | Mentat_config.Mode.Read_only | Mentat_config.Mode.Workspace_write ->
          (* One clause per admitted path. Specificity decides the rest:
             a carveout is a [Read] beneath a [Write], a denial outranks both
             wherever it lands, and no list has to be filtered against another
             to say so. *)
          let reads_default =
            match read with
            | Mentat_config.Read.All -> Mentat_sandbox.Policy.All
            | Mentat_config.Read.Project -> Mentat_sandbox.Policy.Denied
          in
          let mutates =
            match mode with Mentat_config.Mode.Read_only -> false | _ -> true
          in
          let writable, carveouts =
            match mode with
            | Mentat_config.Mode.Read_only ->
                (derived.Derive.platform_writable, [])
            | _ ->
                ( derived.Derive.writable @ derived.Derive.platform_writable
                  @ derived.Derive.toolchain_writable,
                  derived.Derive.protected )
          in
          let clause access paths =
            List.map (fun path -> (path, access)) paths
          in
          let entries =
            clause Mentat_sandbox.Policy.Access.Read derived.Derive.readable
            @ clause Mentat_sandbox.Policy.Access.Write writable
            @ clause Mentat_sandbox.Policy.Access.Read carveouts
            @ clause Mentat_sandbox.Policy.Access.Deny derived.Derive.denied
          in
          let policy =
            Mentat_sandbox.Policy.make ~entries ~reads_default ~network
          in
          let backend = Probe.backend ~stdenv ~lookup in
          Mentat_sandbox.confined ~backend ~mutates policy
    in
    let* roots = open_roots ~sw ~fs ~logical derived.Derive.workspace_roots in
    let primary =
      match roots with
      | primary :: _ -> primary
      | [] -> assert false (* a workspace always admits a primary root *)
    in
    let lock_key = primary.identity in
    Ok
      {
        logical;
        roots;
        environment = env.Child_env.bindings;
        path_dirs = env.Child_env.path_dirs;
        sandbox;
        described_roots = described_roots ~sandbox derived.Derive.describe;
        read_only =
          (match mode with
          | Mentat_config.Mode.Read_only -> true
          | Mentat_config.Mode.Workspace_write
          | Mentat_config.Mode.Danger_full_access
          | Mentat_config.Mode.External_sandbox ->
              false);
        fs;
        proc_mgr = Eio.Stdenv.process_mgr stdenv;
        mono = Eio.Stdenv.mono_clock stdenv;
        edit_lock = edit_lock_for lock_key;
        claim_scope = None;
      }
  in
  capability ()

(* Accessors.

   Projections only: the sealed sandbox value itself never leaves the
   capability, so its public lowering bridges are unreachable from a holder. *)

let identity t = Mentat_sandbox.identity t.sandbox
let policy t = Mentat_sandbox.policy t.sandbox
let evidence t = Mentat_sandbox.evidence t.sandbox
let escalation t = Mentat_sandbox.escalation t.sandbox

(* A diagnostic projection for parity reporting: where the child's [PATH]
   resolves a bare program name. Not a launch surface — launches resolve
   internally, at spawn — and not the child environment itself, which no
   accessor returns. *)
let child_program t program =
  if String.contains program '/' then None
  else
    List.find_map
      (fun dir ->
        let candidate = Filename.concat dir program in
        if Derive.is_executable_file candidate then Some candidate else None)
      t.path_dirs

let describe_roots t = t.described_roots

(* Obligation discharge.

   The per-launch (and startup) existence re-checks the pure sandbox names
   but cannot perform. [Exists] is an [lstat] — it confirms existence without
   following a swapped symlink; [Directory] follows and requires a
   directory. *)

let discharged t obligation =
  let path = Mentat_sandbox.Obligation.path obligation in
  let target = Eio.Path.( / ) t.fs (Lpath.Abs.to_string path) in
  match Mentat_sandbox.Obligation.kind obligation with
  | Mentat_sandbox.Obligation.Exists -> (
      match Eio.Path.stat ~follow:false target with
      | _ -> true
      | exception Eio.Exn.Io _ -> false)
  | Mentat_sandbox.Obligation.Directory -> (
      match Eio.Path.stat ~follow:true target with
      | stat -> stat.Eio.File.Stat.kind = `Directory
      | exception Eio.Exn.Io _ -> false)

let discharge t sandbox =
  let rec loop = function
    | [] -> Ok ()
    | obligation :: rest ->
        if discharged t obligation then loop rest
        else Error (Mentat_sandbox.Obligation.path obligation)
  in
  loop (Mentat_sandbox.obligations sandbox)

let check t ~requirement =
  match Mentat_sandbox.admits requirement t.sandbox with
  | Error _ as error -> error
  | Ok () -> (
      match discharge t t.sandbox with
      | Ok () -> Ok ()
      | Error path ->
          Error
            (Mentat_sandbox.Requirement.Rejection.Unenforceable
               (Mentat_sandbox.Error.Stale_policy { path })))

(* Path binding.

   Every workspace path re-binds to the most-specific opened root containing
   its canonical address, before any writability or protected-meta check, and
   is then interpreted beneath that root's opened capability. *)

type bound = { broot : root; rel : Lpath.Rel.t; abs : Lpath.Abs.t }

let bind t path =
  let key = Mentat_workspace.Path.root_key path in
  match
    List.find_opt
      (fun entry ->
        Mentat_workspace.Root.Key.equal key
          (Mentat_workspace.Root.key entry.root))
      t.roots
  with
  | None -> Error key
  | Some home ->
      let abs =
        Lpath.Abs.append_rel home.canonical (Mentat_workspace.Path.rel path)
      in
      let best =
        List.fold_left
          (fun best candidate ->
            if Lpath.Abs.is_within ~root:candidate.canonical abs then
              match best with
              | Some chosen when chosen.depth >= candidate.depth -> best
              | Some _ | None -> Some candidate
            else best)
          None t.roots
      in
      let broot =
        match best with
        | Some broot -> broot
        | None -> home (* [abs] is beneath [home.canonical] by construction *)
      in
      let rel =
        match Lpath.Abs.relativize ~root:broot.canonical abs with
        | Some rel -> rel
        | None -> assert false (* containment established just above *)
      in
      Ok { broot; rel; abs }

let bound_path bound =
  Mentat_workspace.Path.make
    ~root_key:(Mentat_workspace.Root.key bound.broot.root)
    bound.rel

let eio_at root rel =
  if Lpath.Rel.is_root rel then root.opened
  else Eio.Path.( / ) root.opened (Lpath.Rel.to_string rel)

let bound_eio bound = eio_at bound.broot bound.rel
let resolve_path t input = Mentat_workspace.resolve_string t.logical input

let cwd t =
  match resolve_path t "." with
  | Ok path -> path
  (* ["."] resolves against the logical root by construction; the failure arm is
     unreachable. *)
  | Error _ -> assert false

let to_abs t path =
  match bind t path with
  | Ok bound -> Ok bound.abs
  | Error key -> Error (Mentat_workspace.Resolve_error.Unknown_root key)

(* File. *)

(* Confined resolution reports an escape as [Permission_denied] with a
   backend marker; a genuine EACCES/EPERM keeps its Unix payload. *)
let file_error path exn =
  match exn with
  | Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> File_error.Not_found path
  | Eio.Exn.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.ENOTDIR, _, _)), _) ->
      File_error.Not_found path
  | Eio.Exn.Io
      ( (Eio.Fs.E
           (Eio.Fs.Permission_denied
              (Eio_unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _))) as cause),
        _ ) ->
      File_error.Io { path; cause }
  | Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) ->
      File_error.Escapes_workspace path
  | Eio.Exn.Io (cause, _) -> File_error.Io { path; cause }
  | exn -> raise exn

let with_bound t path fn =
  match bind t path with
  | Error key -> Error (File_error.Unknown_root key)
  | Ok bound -> (
      match fn bound with
      | value -> Ok value
      | exception (Eio.Exn.Io _ as exn) -> Error (file_error path exn))

module File = struct
  type slice = { contents : string; eof : bool }

  let stat t path =
    with_bound t path (fun bound ->
        Eio.Path.stat ~follow:true (bound_eio bound))

  let lstat t path =
    with_bound t path (fun bound ->
        Eio.Path.stat ~follow:false (bound_eio bound))

  let read_link t path =
    with_bound t path (fun bound -> Eio.Path.read_link (bound_eio bound))

  let read t path ~offset ~max_bytes =
    if offset < 0 then invalid_arg "offset must be non-negative";
    if max_bytes < 0 then invalid_arg "max_bytes must be non-negative";
    with_bound t path (fun bound ->
        Eio.Path.with_open_in (bound_eio bound) (fun file ->
            let size = Optint.Int63.to_int (Eio.File.size file) in
            let available = max 0 (size - min offset size) in
            let length = min max_bytes available in
            if length = 0 then { contents = ""; eof = offset >= size }
            else
              let buffer = Cstruct.create length in
              let rec fill position =
                if position = length then position
                else
                  let chunk = Cstruct.sub buffer position (length - position) in
                  let read =
                    Eio.File.pread file
                      ~file_offset:(Optint.Int63.of_int (offset + position))
                      [ chunk ]
                  in
                  if read = 0 then position else fill (position + read)
              in
              let read = fill 0 in
              {
                contents = Cstruct.to_string (Cstruct.sub buffer 0 read);
                eof = read < length || offset + read >= size;
              }))

  let read_flow flow =
    let buffer = Buffer.create 65536 in
    let chunk = Cstruct.create 65536 in
    let rec loop () =
      match Eio.Flow.single_read flow chunk with
      | n ->
          Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub chunk 0 n));
          loop ()
      | exception End_of_file -> Buffer.contents buffer
    in
    loop ()

  (* Bounded observation read: the file's size is taken from the open
     descriptor, so an over-bound file is [Too_large] before any bytes are
     buffered — an observation read cannot exhaust memory. *)
  let load t path ~max_bytes =
    match bind t path with
    | Error key -> Error (File_error.Unknown_root key)
    | Ok bound -> (
        match
          Eio.Path.with_open_in (bound_eio bound) (fun flow ->
              let size = Optint.Int63.to_int64 (Eio.File.size flow) in
              if Int64.compare size (Int64.of_int max_bytes) > 0 then
                `Too_large size
              else `Loaded (read_flow flow))
        with
        | `Loaded contents -> Ok contents
        | `Too_large size ->
            Error (File_error.Too_large { path; size; max_bytes })
        | exception (Eio.Exn.Io _ as exn) -> Error (file_error path exn))

  let read_dir t path =
    with_bound t path (fun bound ->
        Eio.Path.read_dir (bound_eio bound)
        |> List.filter_map (fun name ->
            match Mentat_workspace.Path.add_component path name with
            | Ok child -> Some child
            | Error _ -> None))

  (* Directory reads carry each entry's kind, but only on filesystems that
     record it in the directory itself; the rest report [`Unknown] and are owed
     the [lstat] the walk would otherwise have spent on every entry. Resolving
     it here rather than at the call sites keeps the returned kind decisive, so
     no caller can mistake "this filesystem does not say" for "not a file the
     walk wants" and silently traverse nothing. *)
  let read_dir_entries t path =
    with_bound t path (fun bound ->
        let dir = bound_eio bound in
        Eio.Path.read_dir_entries dir
        |> List.filter_map (fun (kind, name) ->
            match Mentat_workspace.Path.add_component path name with
            | Error _ -> None
            | Ok child ->
                let kind =
                  match kind with
                  | `Unknown ->
                      (Eio.Path.stat ~follow:false (Eio.Path.( / ) dir name))
                        .Eio.File.Stat.kind
                  | kind -> kind
                in
                Some (kind, child)))
end

(* Edit.

   Native writes are no-follow: every commit-path traversal — parent chain,
   temporary entries, the final component — runs on the private
   [openat]/[O_NOFOLLOW] seam, fd-relative to the bound root's descriptor. A
   symlink anywhere on the write path is refused, never followed, which is
   what stops an in-root [alias -> .git] from laundering a native write past
   the protected-meta and read-only refusals; because every step is
   fd-relative, the law holds under concurrent replacement too. *)

module Edit = struct
  (* The complete-read bound for edit targets. *)
  let max_file_bytes = 1024 * 1024
  let temp_counter = Atomic.make 0

  let is_text_control = function
    | '\t' | '\n' | '\r' | '\x0c' -> true
    | _ -> false

  let is_control_byte c = Char.Ascii.is_control c && not (is_text_control c)

  let looks_binary text =
    if String.contains text '\x00' then true
    else begin
      let controls = ref 0 in
      String.iter (fun c -> if is_control_byte c then incr controls) text;
      !controls * 10 > String.length text
    end

  let symlink_reason = "path traverses a symlink: native writes are no-follow"

  let unix_error path fname code =
    Mentat_edit.Error.io ~path
      (Printf.sprintf "%s: %s" fname (Unix.error_message code))

  (* The boundary's own sealed posture first — a read-only resolution refuses
     every native write on every route — then path binding before the protection
     checks: rebind to the most-specific opened root and refuse read-only and
     protected targets,
     before any read or commit. Errors name the caller's planned path;
     success returns the rebound identity every later read and commit
     uses. *)
  let revalidate t path =
    if t.read_only then Error (Mentat_edit.Error.read_only_path path)
    else
      match bind t path with
      | Error key ->
          Error
            (Mentat_edit.Error.workspace ~path
               (Mentat_workspace.Resolve_error.Unknown_root key))
      | Ok bound -> (
          if not bound.broot.writable then
            Error (Mentat_edit.Error.read_only_path path)
          else
            let rebound = bound_path bound in
            match Mentat_workspace.protected_meta_component rebound with
            | Some name -> Error (Mentat_edit.Error.protected_path ~path ~name)
            | None -> Ok rebound)

  let too_large ~path size =
    Mentat_edit.Error.too_large ~path ~size
      ~max_size:(Int64.of_int max_file_bytes)

  let rec write_all fd contents off =
    let len = String.length contents - off in
    if len > 0 then
      match Unix.single_write_substring fd contents off len with
      | written -> write_all fd contents (off + written)
      | exception Unix.Unix_error (Unix.EINTR, _, _) ->
          write_all fd contents off

  let rec read_chunk fd chunk =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | read -> read
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_chunk fd chunk

  (* Reads at most one chunk beyond the complete-read bound; the caller turns
     an over-bound result into [Too_large]. *)
  let read_all fd =
    let chunk = Bytes.create 65536 in
    let buffer = Buffer.create 65536 in
    let rec go () =
      if Buffer.length buffer > max_file_bytes then Buffer.contents buffer
      else
        let read = read_chunk fd chunk in
        if read = 0 then Buffer.contents buffer
        else begin
          Buffer.add_subbytes buffer chunk 0 read;
          go ()
        end
    in
    go ()

  (* [walk ~path ~mkdirs ~absent bound fn] opens the target's parent chain
     beneath the bound root's descriptor — no-follow at every component — and
     runs [fn ~parent base] with [base] the final component. [absent] maps a
     missing parent when [mkdirs] is false; a symlink or non-directory parent
     is always a structured invalid-target error naming that component. [mkdirs]
     creates missing parents (mode 0o777 under the umask). On an [Error] result
     every directory this walk created is removed again; every descriptor the
     walk opened is closed either way. *)
  let walk ~path ~mkdirs ~absent bound fn =
    match List.rev (Lpath.Rel.components bound.rel) with
    | [] -> Error (Mentat_edit.Error.io ~path "invalid edit target")
    | base :: ancestors ->
        let parents = List.rev ancestors in
        let opened = ref [] in
        let created =
          ref []
          (* (parent fd, name), deepest first *)
        in
        let track fd =
          opened := fd :: !opened;
          fd
        in
        (* [O_DIRECTORY|O_NOFOLLOW] reports a symlink component as [ELOOP] on
           Linux but [ENOTDIR] on macOS; a no-follow stat disambiguates so
           the symlink law is named precisely, with [fallback] deciding the
           genuine non-directory case. *)
        let root = Mentat_workspace.Path.root_of path in
        let component_path parent component =
          Result.get_ok (Mentat_workspace.Path.add_component parent component)
        in
        let invalid_parent component_path reason =
          Error (Mentat_edit.Error.invalid_target ~path:component_path reason)
        in
        let symlink_or fd component component_path fallback =
          match (Nofollow.fstatat fd component).Nofollow.kind with
          | `Symlink ->
              invalid_parent component_path
                Mentat_edit.Error.Target_error.Symlink
          | `Regular | `Directory | `Other -> fallback ()
          | exception Unix.Unix_error _ -> fallback ()
        in
        let not_a_directory component_path () =
          invalid_parent component_path
            Mentat_edit.Error.Target_error.Not_a_directory
        in
        let rec descend fd parent_path = function
          | [] -> fn ~parent:fd base
          | component :: rest -> (
              let child_path = component_path parent_path component in
              match Nofollow.openat_dir fd component with
              | child -> descend (track child) child_path rest
              | exception Unix.Unix_error (Unix.ENOENT, _, _) when mkdirs -> (
                  match Nofollow.mkdirat fd component 0o777 with
                  | () ->
                      created := (fd, component) :: !created;
                      reopen fd component child_path rest
                  | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
                      (* lost a creation race; whatever appeared must still
                         open as a real directory, no-follow *)
                      reopen fd component child_path rest
                  | exception Unix.Unix_error (code, fname, _) ->
                      Error (unix_error path fname code))
              | exception Unix.Unix_error (Unix.ENOENT, _, _) -> absent ()
              | exception
                  Unix.Unix_error
                    ((Unix.ELOOP | Unix.EMLINK | Unix.ENOTDIR), _, _) ->
                  symlink_or fd component child_path
                    (not_a_directory child_path)
              | exception Unix.Unix_error (code, fname, _) ->
                  Error (unix_error path fname code))
        and reopen fd component child_path rest =
          match Nofollow.openat_dir fd component with
          | child -> descend (track child) child_path rest
          | exception
              Unix.Unix_error ((Unix.ELOOP | Unix.EMLINK | Unix.ENOTDIR), _, _)
            ->
              symlink_or fd component child_path (not_a_directory child_path)
          | exception Unix.Unix_error (code, fname, _) ->
              Error (unix_error path fname code)
        in
        Fun.protect
          ~finally:(fun () ->
            List.iter
              (fun fd ->
                match Unix.close fd with
                | () -> ()
                | exception Unix.Unix_error _ -> ())
              !opened)
          (fun () ->
            let result = descend bound.broot.dirfd root parents in
            (match result with
            | Ok _ -> ()
            | Error _ ->
                List.iter
                  (fun (fd, name) ->
                    match Nofollow.unlinkat fd name ~dir:true with
                    | () -> ()
                    | exception Unix.Unix_error _ -> ())
                  !created);
            result)

  (* Write [contents] beside the target as a fresh exclusive no-follow temp
     entry; the returned name is fully written and closed. When [exact], the
     target's exact permission bits are restored through the open descriptor
     before it closes — the creation mode is masked by the umask — and a
     failure is structured, never swallowed. *)
  let write_temp ~parent ~base ~perm ~exact ~path contents =
    let unlink_temp name =
      match Nofollow.unlinkat parent name ~dir:false with
      | () -> ()
      | exception Unix.Unix_error _ -> ()
    in
    let rec attempt tries =
      if tries = 0 then
        Error
          (Mentat_edit.Error.io ~path
             "could not allocate a temporary path for atomic write")
      else
        let name =
          base ^ ".mentat-"
          ^ string_of_int (Atomic.fetch_and_add temp_counter 1)
          ^ ".tmp"
        in
        match Nofollow.openat_create parent name perm with
        | exception Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (tries - 1)
        | exception Unix.Unix_error (code, fname, _) ->
            Error (unix_error path fname code)
        | fd -> (
            match
              write_all fd contents 0;
              if exact then Unix.fchmod fd perm
            with
            | () -> (
                match Unix.close fd with
                | () -> Ok name
                | exception Unix.Unix_error (code, fname, _) ->
                    unlink_temp name;
                    Error (unix_error path fname code))
            | exception Unix.Unix_error (code, fname, _) ->
                (try Unix.close fd with Unix.Unix_error _ -> ());
                unlink_temp name;
                Error (unix_error path fname code))
    in
    attempt 32

  (* Creation publishes the finished temp entry with an atomic no-replace
     [linkat]: a mid-write failure leaves no partial target, and a concurrent
     creation of the same name loses cleanly as a state mismatch instead of
     being overwritten. *)
  let create path bound contents =
    if String.length contents > max_file_bytes then
      Error (too_large ~path (Int64.of_int (String.length contents)))
    else
      walk ~path ~mkdirs:true
        ~absent:(fun () -> assert false (* [mkdirs] creates missing parents *))
        bound
      @@ fun ~parent base ->
      let* tmp =
        write_temp ~parent ~base ~perm:0o666 ~exact:false ~path contents
      in
      let unlink_temp () =
        match Nofollow.unlinkat parent tmp ~dir:false with
        | () -> ()
        | exception Unix.Unix_error _ -> ()
      in
      match Nofollow.linkat parent tmp base with
      | () ->
          unlink_temp ();
          Ok ()
      | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
          unlink_temp ();
          Error
            (Mentat_edit.Error.state_mismatch ~path ~expected:`Missing
               ~actual:`Other)
      | exception Unix.Unix_error (code, fname, _) ->
          unlink_temp ();
          Error (unix_error path fname code)

  let replace path bound contents =
    if String.length contents > max_file_bytes then
      Error (too_large ~path (Int64.of_int (String.length contents)))
    else
      walk ~path ~mkdirs:false
        ~absent:(fun () ->
          Error (Mentat_edit.Error.io ~path "target vanished before commit"))
        bound
      @@ fun ~parent base ->
      (* The target's exact permission bits, observed no-follow: a symlink
         swapped in as the target refuses instead of leaking its referent's
         bits. *)
      let* perm =
        match Nofollow.fstatat parent base with
        | { Nofollow.kind = `Symlink; _ } ->
            Error (Mentat_edit.Error.io ~path symlink_reason)
        | { Nofollow.perm; _ } -> Ok perm
        | exception Unix.Unix_error (code, fname, _) ->
            Error (unix_error path fname code)
      in
      let* tmp = write_temp ~parent ~base ~perm ~exact:true ~path contents in
      (* [renameat] replaces the target entry atomically and follows neither
         final component: a symlink swapped in as the target is replaced as
         an entry, never written through. *)
      match Nofollow.renameat parent tmp base with
      | () -> Ok ()
      | exception Unix.Unix_error (code, fname, _) ->
          (match Nofollow.unlinkat parent tmp ~dir:false with
          | () -> ()
          | exception Unix.Unix_error _ -> ());
          Error (unix_error path fname code)

  let remove path bound =
    walk ~path ~mkdirs:false
      ~absent:(fun () ->
        Error
          (Mentat_edit.Error.state_mismatch ~path ~expected:`Text
             ~actual:`Missing))
      bound
    @@ fun ~parent base ->
    match Nofollow.unlinkat parent base ~dir:false with
    | () -> Ok ()
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        Error
          (Mentat_edit.Error.state_mismatch ~path ~expected:`Text
             ~actual:`Missing)
    | exception Unix.Unix_error (code, fname, _) ->
        Error (unix_error path fname code)

  (* The write-side preflight read observes through the same no-follow
     traversal the commit uses, so the before evidence and the committed
     target are the same physical file: a final symlink reads as un-editable
     ([Other]), an intermediate symlink refuses. *)
  let read ?(invalid_text_errors = false) t path =
    match bind t path with
    | Error key ->
        Error
          (Mentat_edit.Error.workspace ~path
             (Mentat_workspace.Resolve_error.Unknown_root key))
    | Ok bound -> (
        walk ~path ~mkdirs:false
          ~absent:(fun () -> Ok Mentat_edit.Observed.Missing)
          bound
        @@ fun ~parent base ->
        (* Stat first, no-follow: a symlink or non-regular target is
           un-editable and is never opened (a FIFO must not stall the
           read). *)
        match Nofollow.fstatat parent base with
        | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
            Ok Mentat_edit.Observed.Missing
        | exception Unix.Unix_error (code, fname, _) ->
            Error (unix_error path fname code)
        | { Nofollow.kind = `Symlink | `Directory | `Other; _ } ->
            Ok Mentat_edit.Observed.Other
        | { Nofollow.kind = `Regular; size; _ } -> (
            if Int64.compare size (Int64.of_int max_file_bytes) > 0 then
              Error (too_large ~path size)
            else
              match Nofollow.openat_read parent base with
              | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                  Ok Mentat_edit.Observed.Missing
              | exception Unix.Unix_error (Unix.ELOOP, _, _) ->
                  Ok Mentat_edit.Observed.Other
              | exception Unix.Unix_error (code, fname, _) ->
                  Error (unix_error path fname code)
              | fd ->
                  let observe () =
                    if (Unix.fstat fd).Unix.st_kind <> Unix.S_REG then
                      Ok Mentat_edit.Observed.Other
                    else
                      let contents = read_all fd in
                      if String.length contents > max_file_bytes then
                        Error
                          (too_large ~path
                             (Int64.of_int (String.length contents)))
                      else if looks_binary contents then
                        if invalid_text_errors then
                          Error
                            (Mentat_edit.Error.invalid_text ~path "binary file")
                        else Ok Mentat_edit.Observed.Other
                      else if not (String.is_valid_utf_8 contents) then
                        if invalid_text_errors then
                          Error
                            (Mentat_edit.Error.invalid_text ~path
                               "not valid UTF-8 text")
                        else Ok Mentat_edit.Observed.Other
                      else Ok (Mentat_edit.Observed.Text contents)
                  in
                  Fun.protect
                    ~finally:(fun () ->
                      match Unix.close fd with
                      | () -> ()
                      | exception Unix.Unix_error _ -> ())
                    (fun () ->
                      match observe () with
                      | result -> result
                      | exception Unix.Unix_error (code, fname, _) ->
                          Error (unix_error path fname code))))

  let observe t path =
    Eio.Mutex.use_rw ~protect:true t.edit_lock @@ fun () ->
    let* target = revalidate t path in
    read ~invalid_text_errors:true t target

  let commit t ~path ~before ~after =
    match bind t path with
    | Error key ->
        Error
          (Mentat_edit.Error.workspace ~path
             (Mentat_workspace.Resolve_error.Unknown_root key))
    | Ok bound -> (
        match (before, after) with
        | Mentat_edit.State.Missing, Mentat_edit.State.Text contents ->
            create path bound contents
        | Mentat_edit.State.Text _, Mentat_edit.State.Text contents ->
            replace path bound contents
        | Mentat_edit.State.Text _, Mentat_edit.State.Missing ->
            remove path bound
        | Mentat_edit.State.Missing, Mentat_edit.State.Missing ->
            Error (Mentat_edit.Error.io ~path "empty edit transition"))

  let io t =
    {
      Mentat_edit.Apply.with_write_lock =
        (fun _paths fn -> Eio.Mutex.use_rw ~protect:true t.edit_lock fn);
      revalidate = revalidate t;
      read = read t;
      commit = (fun ~path ~before ~after -> commit t ~path ~before ~after);
    }

  (* The claim-scope recording seam. Every apply records its workspace effect
     into the window that was open when it started: the authoritative result
     on success; the confirmed committed prefix and the uncertain commit
     target on failure. A preflight refusal has no effect and records
     nothing, and an apply with no open window is enforced identically and
     records nothing. *)
  let record scope result =
    match result with
    | Ok applied ->
        scope.Claim_scope.applies <-
          Mentat_edit.Apply_evidence.Applied applied
          :: scope.Claim_scope.applies
    | Error error ->
        let applied = Mentat_edit.Apply_error.applied error in
        let uncertain =
          match Mentat_edit.Apply_error.phase error with
          | Mentat_edit.Apply_error.Phase.Commit { target } -> Some target
          | Mentat_edit.Apply_error.Phase.Preflight -> None
        in
        if applied <> [] || uncertain <> None then
          scope.Claim_scope.applies <-
            Mentat_edit.Apply_evidence.Attempted
              { Mentat_edit.Apply_evidence.Attempt.applied; uncertain }
            :: scope.Claim_scope.applies

  (* [Cancel.protect] makes commit-plus-recording one uncancellable step, so
     a confirmed transition is never lost between the commit and its claim
     evidence; under the engine's serialized drain this also keeps recorded
     order equal to application order. The window is captured before the
     apply so a scope opened mid-apply never receives another claim's edit;
     a window superseded mid-apply still harvests the edit that started
     under it, unless it was already closed. *)
  let apply t plan =
    Eio.Cancel.protect @@ fun () ->
    let scope = t.claim_scope in
    let result = Mentat_edit.apply ~io:(io t) ~workspace:t.logical plan in
    (match scope with
    | Some scope when not scope.Claim_scope.closed -> record scope result
    | Some _ | None -> ());
    result
end

(* Command. *)

module Confinement = Confinement

module Command = struct
  type stream = Stdout | Stderr
  type capture = All | Limit of int | Head_tail of { head : int; tail : int }

  module Captured = struct
    type t =
      | Complete of string
      | Truncated of { head : string; omitted : int option; tail : string }

    let render = function
      | Complete s -> s
      | Truncated { head; omitted = Some n; tail } ->
          Printf.sprintf "%s\n... %d bytes omitted ...\n%s" head n tail
      | Truncated { head; omitted = None; tail } ->
          Printf.sprintf "%s\n... bytes omitted ...\n%s" head tail

    let is_complete = function Complete _ -> true | Truncated _ -> false
  end

  type termination =
    | Exited of Eio.Process.exit_status
    | Timed_out
    | Stopped
    | Output_limit of { stream : stream; limit : int }
    | Supervision_failed of Eio.Exn.err

  type outcome = {
    termination : termination;
    stdout : Captured.t;
    stderr : Captured.t;
    duration : Mtime.Span.t;
    sandbox_evidence : Mentat_sandbox.Evidence.t;
    confinement : Confinement.t option;
  }

  module Error = struct
    type t =
      | Spawn of Eio.Process.error
      | Sandbox of Mentat_sandbox.Error.t
      | Unknown_cwd_root of Mentat_workspace.Root.Key.t
      | Io of Eio.Exn.err

    let pp ppf = function
      | Spawn (Eio.Process.Executable_not_found program) ->
          Format.fprintf ppf "executable %S not found" program
      | Spawn (Eio.Process.Child_error status) ->
          Format.fprintf ppf "child failed: %a" Eio.Process.pp_status status
      | Spawn Eio.Process.Argument_list_too_long ->
          Format.fprintf ppf "argument list too long"
      | Spawn (Eio.Process.Permission_denied program) ->
          Format.fprintf ppf "executable %S not runnable: permission denied"
            program
      | Spawn (Eio.Process.Executable_format_error program) ->
          Format.fprintf ppf "executable %S is not in a runnable format" program
      | Sandbox error -> Mentat_sandbox.Error.pp ppf error
      | Unknown_cwd_root key ->
          Format.fprintf ppf
            "cwd names workspace root %a, which is not admitted"
            Mentat_workspace.Root.Key.pp key
      | Io err -> Format.fprintf ppf "launch failed: %a" Eio.Exn.pp_err err

    let message t = Format.asprintf "%a" pp t
  end

  (* Combine one stream's captured parts with its drain completeness into the
     public structural value: a stream that did not reach clean EOF is
     truncated with an unknown-length missing suffix (a limit stop, or a
     descendant still writing past the drain grace). *)
  let captured (parts : Subprocess.Capture.parts) ~complete =
    match parts with
    | Subprocess.Capture.Whole s ->
        if complete then Captured.Complete s
        else Captured.Truncated { head = s; omitted = None; tail = "" }
    | Subprocess.Capture.Split { head; omitted; tail } ->
        if complete then
          if omitted = 0 then Captured.Complete (head ^ tail)
          else Captured.Truncated { head; omitted = Some omitted; tail }
        else Captured.Truncated { head; omitted = None; tail }

  let capture_policy = function
    | All -> Subprocess.Capture.All
    | Limit limit -> Subprocess.Capture.Limit limit
    | Head_tail { head; tail } -> Subprocess.Capture.Head_tail { head; tail }

  (* Resolve an implicit program against the private environment's PATH — the
     directories the child's own PATH names, never the ambient PATH — so
     boundary resolution and child-side resolution agree. A candidate resolves
     only if it is a regular file executable by this process, so a directory or
     a non-executable file of the same name never shadows a real executable
     later on PATH (a bare existence check trusts both). *)
  let resolve_executable t program =
    if String.contains program '/' then Some program
    else
      List.find_map
        (fun dir ->
          let candidate = Filename.concat dir program in
          if Derive.is_executable_file candidate then Some candidate else None)
        t.path_dirs

  type prepared = {
    lowered : string list;
    executable : string;
    cwd : Eio.Fs.dir_ty Eio.Path.t;
    child_environment : string array;
  }

  (* [PWD] is the one binding a launch owns rather than the resolution: it names
     the directory this command actually starts in. It is written on every
     route because Bubblewrap assigns it itself after entering the sandbox, so
     leaving it out would give the confined child a binding the escalated and
     direct children lack — a route-dependent environment the capability
     promises never to serve. The array stays sorted by name. *)
  let with_pwd environment directory =
    let binding = "PWD=" ^ Lpath.Abs.to_string directory in
    let others =
      Array.to_list environment
      |> List.filter (fun item -> not (String.starts_with ~prefix:"PWD=" item))
    in
    List.merge String.compare others [ binding ] |> Array.of_list

  (* Validate, bind and open the cwd, discharge every obligation, lower — one
     private sequence no caller can reorder or skip. *)
  let prepare t ~sandbox ~cwd argv =
    let cwd_path =
      match cwd with
      | Some path -> path
      | None -> Mentat_workspace.cwd t.logical
    in
    let* bound =
      match bind t cwd_path with
      | Ok bound -> Ok bound
      | Error key -> Error (Error.Unknown_cwd_root key)
    in
    let* () =
      (* B7 witness recheck: the bound cwd root's pathname must still name the
         inode opened at resolution. The external backends bind the cwd by
         pathname (Bubblewrap [--chdir], Seatbelt policy), so a root swapped
         between resolution and exec could redirect the wrapper; a cheap
         [(st_dev, st_ino)] mismatch is a stale-policy refusal. It narrows, but
         does not close, that pathname-bind window. *)
      let stale () =
        Error
          (Error.Sandbox
             (Mentat_sandbox.Error.Stale_policy { path = bound.broot.canonical }))
      in
      match Unix.stat (Lpath.Abs.to_string bound.broot.canonical) with
      | stat when (stat.Unix.st_dev, stat.Unix.st_ino) = bound.broot.identity ->
          Ok ()
      | _ -> stale ()
      | exception Unix.Unix_error _ -> stale ()
    in
    let* () =
      match discharge t sandbox with
      | Ok () -> Ok ()
      | Error path ->
          Error (Error.Sandbox (Mentat_sandbox.Error.Stale_policy { path }))
    in
    match Mentat_sandbox.lower_argv sandbox ~cwd:bound.abs argv with
    | Error error -> Error (Error.Sandbox error)
    | Ok lowered -> (
        let head =
          match lowered with
          | head :: _ -> head
          | [] -> assert false (* a lowering never returns an empty argv *)
        in
        match resolve_executable t head with
        | Some executable ->
            Ok
              {
                lowered;
                executable;
                cwd = bound_eio bound;
                child_environment = with_pwd t.environment bound.abs;
              }
        | None -> Error (Error.Spawn (Eio.Process.Executable_not_found head)))

  let coerce_source (source : _ Eio.Flow.source) =
    (source :> Eio.Flow.source_ty Eio.Std.r)

  let is_launch_failure = function
    | Eio.Exn.Io _ | Unix.Unix_error _ -> true
    | _ -> false

  let launch_failure = function
    | Eio.Exn.Io (Eio.Process.E error, _) -> Error.Spawn error
    | Eio.Exn.Io (err, _) -> Error.Io err
    | Unix.Unix_error (code, name, argument) ->
        Error.Io (Eio.Exn.X (Eio_unix.Unix_error (code, name, argument)))
    | exn -> raise exn

  let run_route t ~sandbox ~cwd ~stdin ~capture ~timeout ~cancelled argv =
    let* prepared = prepare t ~sandbox ~cwd argv in
    let sandbox_evidence = Mentat_sandbox.evidence sandbox in
    match
      Subprocess.run ~proc_mgr:t.proc_mgr ~mono:t.mono ~fs:t.fs
        ~cwd:prepared.cwd ~env:prepared.child_environment
        ~executable:prepared.executable ?stdin ~capture:(capture_policy capture)
        ~timeout ~cancelled prepared.lowered
    with
    | result ->
        let termination =
          match result.Subprocess.termination with
          | Subprocess.Exited status -> Exited status
          | Subprocess.Timed_out -> Timed_out
          | Subprocess.Stopped -> Stopped
          | Subprocess.Output_limit { stream; limit } ->
              let stream =
                match stream with `Stdout -> Stdout | `Stderr -> Stderr
              in
              Output_limit { stream; limit }
          | Subprocess.Supervision_failed err -> Supervision_failed err
        in
        Ok
          {
            termination;
            stdout =
              captured result.Subprocess.stdout
                ~complete:result.Subprocess.stdout_complete;
            stderr =
              captured result.Subprocess.stderr
                ~complete:result.Subprocess.stderr_complete;
            duration = result.Subprocess.duration;
            sandbox_evidence;
            confinement =
              Confinement.observe ~sandbox ~evidence:sandbox_evidence
                ~transcript:
                  (Captured.render
                     (captured result.Subprocess.stdout
                        ~complete:result.Subprocess.stdout_complete)
                  ^ "\n"
                  ^ Captured.render
                      (captured result.Subprocess.stderr
                         ~complete:result.Subprocess.stderr_complete));
          }
    | exception Subprocess.Launch exn -> Error (launch_failure exn)

  let run t ?cwd ?stdin ~capture ~timeout ?cancelled argv =
    run_route t ~sandbox:t.sandbox ~cwd
      ~stdin:(Option.map coerce_source stdin)
      ~capture ~timeout ~cancelled argv

  (* The escalated seal is built here and discarded with the command, exactly as
     a grant is — the two are one mechanism now, differing only in how wide they
     open. Because it is an ordinary seal, the command lowers through the
     ordinary route and its evidence names the profile that really ran, instead
     of a route reporting that nothing confined it. *)
  let run_escalated t ?cwd ?stdin ~capture ~timeout ?cancelled argv =
    match Mentat_sandbox.escalated t.sandbox with
    | Error error -> Error (Error.Sandbox error)
    | Ok sandbox ->
        run_route t ~sandbox ~cwd
          ~stdin:(Option.map coerce_source stdin)
          ~capture ~timeout ~cancelled argv

  (* A grant is the one path into the policy that does not come from the
     resolver, so the two things the resolver would have done for it have to
     happen here.

     It is canonicalized, because the profile names canonical paths and the
     backends match by the name in the profile: on macOS a grant spelled
     [/tmp/x] would never match the [/private/tmp/x] the policy carries, and the
     command would be refused exactly as if nothing had been granted — the worst
     shape of failure, a widening that reports success and changes nothing.

     And it is required to be a directory, because a grant becomes a writable
     clause and a writable clause is obliged to be one. Left to the discharge,
     granting a file answers [Stale_policy] — "disappeared or changed kind after
     sealing" — which is untrue and, worse, unactionable: the caller is told
     something moved rather than that it should have named the containing
     directory. The refused path is reported as the caller spelled it. *)
  let admissible_grants t grants =
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | (path, access) :: rest -> (
          let target = Eio.Path.( / ) t.fs (Lpath.Abs.to_string path) in
          match Eio.Path.stat ~follow:true target with
          | stat when stat.Eio.File.Stat.kind = `Directory ->
              loop ((Derive.canonical path, access) :: acc) rest
          | _ | (exception Eio.Exn.Io _) ->
              Error (Mentat_sandbox.Error.Grant_not_a_directory { path }))
    in
    loop [] grants

  (* The widened seal is built here and discarded when the command returns:
     nothing stores it, which is what makes the grant expire. It lowers through
     the ordinary confined route, so a granted command is still an enforced one
     and reports enforced evidence — unlike an escalation, which reports having
     left the sandbox. Every grant path is an ordinary obligation, so one that
     does not exist is refused by the discharge already standing in [prepare]
     rather than conjured into being. *)
  let run_granted t ?cwd ?stdin ~capture ~timeout ?cancelled ~grants argv =
    match admissible_grants t grants with
    | Error error -> Error (Error.Sandbox error)
    | Ok grants -> (
        match Mentat_sandbox.grant t.sandbox grants with
        | Error error -> Error (Error.Sandbox error)
        | Ok sandbox ->
            run_route t ~sandbox ~cwd
              ~stdin:(Option.map coerce_source stdin)
              ~capture ~timeout ~cancelled argv)

  module Session = struct
    (* A bounded in-memory ring over one stream's raw bytes. [total] counts
       every byte ever appended (monotonic, the cursor space); the retained
       window is the last [min total capacity] bytes, stored circularly ending
       just before [write]. Older bytes roll off the head and are reported as
       dropped, never silently.

       Concurrency: each ring is written only by its own drain fiber and read
       only by the tool-call fiber. Both run in one Eio domain under cooperative
       scheduling, and neither [add] nor [read] has a fiber yield point, so no
       reader observes a half-written append and the ring needs no lock. Moving
       a drain to [run_in_systhread] would break this — the drains stay
       fiber-native. *)
    module Ring = struct
      type t = {
        data : Bytes.t;
        capacity : int;
        mutable len : int; (* retained bytes, [0 <= len <= capacity] *)
        mutable write : int; (* next write index, [0 <= write < capacity] *)
        mutable total : int; (* total bytes ever appended (monotonic) *)
      }

      let create ~capacity =
        {
          data = Bytes.create capacity;
          capacity;
          len = 0;
          write = 0;
          total = 0;
        }

      let total t = t.total

      let add t s =
        let n = String.length s in
        if n = 0 then ()
        else if n >= t.capacity then begin
          (* Only the last [capacity] bytes survive; they fill the buffer and
             the write cursor wraps a whole turn back to where it stood. *)
          Bytes.blit_string s (n - t.capacity) t.data 0 t.capacity;
          t.write <- 0;
          t.len <- t.capacity;
          t.total <- t.total + n
        end
        else begin
          let first = min n (t.capacity - t.write) in
          Bytes.blit_string s 0 t.data t.write first;
          if n > first then Bytes.blit_string s first t.data 0 (n - first);
          t.write <- (t.write + n) mod t.capacity;
          t.len <- min t.capacity (t.len + n);
          t.total <- t.total + n
        end

      (* Bytes in [(from, total]] and the count that rolled off below [from].
         A [from] past the retained window resumes at the window start with the
         gap counted, never dropped silently. *)
      let read t ~from =
        let window_start = t.total - t.len in
        let dropped = if from < window_start then window_start - from else 0 in
        let effective = if from < window_start then window_start else from in
        let count = t.total - effective in
        if count <= 0 then ("", dropped)
        else begin
          let start =
            (((t.write - count) mod t.capacity) + t.capacity) mod t.capacity
          in
          let out = Bytes.create count in
          let first = min count (t.capacity - start) in
          Bytes.blit t.data start out 0 first;
          if count > first then Bytes.blit t.data 0 out first (count - first);
          (Bytes.unsafe_to_string out, dropped)
        end
    end

    module Cursor = struct
      type t = { stdout : int; stderr : int }

      let zero : t = { stdout = 0; stderr = 0 }
      let equal (a : t) (b : t) = a.stdout = b.stdout && a.stderr = b.stderr
    end

    type status = Running | Exited of Eio.Process.exit_status | Terminated

    type chunk = {
      stdout : string;
      stderr : string;
      dropped : int;
      next : Cursor.t;
      status : status;
      since : Mtime.Span.t;
    }

    let max_buffer_bytes = 131072

    type t = {
      proc : [ `Generic ] Eio.Process.ty Eio.Std.r;
      child_pid : int;
      out_ring : Ring.t;
      err_ring : Ring.t;
      clock : Eio.Time.Mono.ty Eio.Std.r;
      started_at : Mtime.t;
      mutable live : status;
      mutable signalled : bool;
      out_done : unit Eio.Promise.t;
      err_done : unit Eio.Promise.t;
      changed : Eio.Condition.t;
    }

    (* How long the drains may flush a signalled child's final tail before
       [signal] settles. Bounded so a descendant holding a pipe past the grace
       cannot stall the settle. *)
    let signal_drain_grace = 0.2

    (* How often a waiting [await] re-reads the caller's cooperative stop. The
       predicate is a plain read the engine owns and broadcasts nothing about,
       so it is the one input to the wait that has to be sampled rather than
       awaited. *)
    let stop_poll = 0.05

    (* Spawn [argv] with captured stdout/stderr and a null stdin, then wire the
       two drain daemons and the waiter under [sw]. Raises the same launch
       failures as [Command.run]; the caller classifies them. Not exposed:
       [start_session] is the capability-consuming constructor. *)
    let launch ~sw ~proc_mgr ~fs ~env ~mono ~cwd ~executable argv =
      let out_r, out_w = Eio.Process.pipe ~sw proc_mgr in
      let err_r, err_w = Eio.Process.pipe ~sw proc_mgr in
      let null = Eio.Path.open_in ~sw (Eio.Path.( / ) fs "/dev/null") in
      let child =
        Subprocess.spawn_leader ~sw ~proc_mgr ~cwd ~env ~executable ~stdin:null
          ~stdout:out_w ~stderr:err_w argv
      in
      (* The parent's copies of the child-held ends close right after spawn, so
         a drain reaches EOF only when the child, and any descendant the group
         signal did not reach, has released the last write end. *)
      Eio.Flow.close null;
      Eio.Flow.close out_w;
      Eio.Flow.close err_w;
      let out_done, resolve_out = Eio.Promise.create () in
      let err_done, resolve_err = Eio.Promise.create () in
      let session =
        {
          proc = (child :> [ `Generic ] Eio.Process.ty Eio.Std.r);
          child_pid = Eio.Process.pid child;
          out_ring = Ring.create ~capacity:max_buffer_bytes;
          err_ring = Ring.create ~capacity:max_buffer_bytes;
          clock = mono;
          started_at = Eio.Time.Mono.now mono;
          live = Running;
          signalled = false;
          out_done;
          err_done;
          changed = Eio.Condition.create ();
        }
      in
      (* Every fiber that appends bytes or settles the status broadcasts, so a
         waiting [await] re-reads exactly when there is something new to read
         and never on a timer. *)
      let drain source ring resolve_done =
        Eio.Fiber.fork_daemon ~sw (fun () ->
            let buffer = Cstruct.create 8192 in
            let rec loop () =
              match Eio.Flow.single_read source buffer with
              | n ->
                  Ring.add ring (Cstruct.to_string (Cstruct.sub buffer 0 n));
                  Eio.Condition.broadcast session.changed;
                  loop ()
              | exception End_of_file -> ()
              | exception Eio.Exn.Io _ -> ()
            in
            loop ();
            Eio.Promise.resolve resolve_done ();
            `Stop_daemon)
      in
      drain out_r session.out_ring resolve_out;
      drain err_r session.err_ring resolve_err;
      (* The waiter reaps a self-exit and records it — unless we signalled, in
         which case [signal] records [Terminated]. Fiber-native [await]; never a
         systhread [waitpid], which would pin the owning switch's release. *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
          let status = Eio.Process.await child in
          (match session.live with
          | Running when not session.signalled -> session.live <- Exited status
          | Running | Exited _ | Terminated -> ());
          Eio.Condition.broadcast session.changed;
          `Stop_daemon);
      session

    let read t ~from =
      let out, out_dropped = Ring.read t.out_ring ~from:from.Cursor.stdout in
      let err, err_dropped = Ring.read t.err_ring ~from:from.Cursor.stderr in
      {
        stdout = out;
        stderr = err;
        dropped = out_dropped + err_dropped;
        next =
          {
            Cursor.stdout = Ring.total t.out_ring;
            stderr = Ring.total t.err_ring;
          };
        status = t.live;
        since = Mtime.span t.started_at (Eio.Time.Mono.now t.clock);
      }

    (* [await] is [read] given a deadline: it returns the instant the session
       appends output, settles, or is stopped, and otherwise when [seconds]
       elapse. The rings and the status are re-read on a broadcast rather than
       on a tick, so a busy session costs one wake per append and a silent one
       costs nothing until the deadline. The cooperative stop is the exception,
       polled on its own fiber because nothing broadcasts it. A deadline that
       expires is not a failure — it is the same chunk [read] would have
       returned, with whatever the session produced in the meantime. *)
    let await t ~from ~cancelled ~seconds =
      let fresh chunk =
        chunk.dropped > 0
        || (not (String.is_empty chunk.stdout))
        || not (String.is_empty chunk.stderr)
      in
      let settled chunk =
        match chunk.status with
        | Running -> false
        | Exited _ | Terminated -> true
      in
      let poll () =
        let chunk = read t ~from in
        if fresh chunk || settled chunk then Some chunk else None
      in
      match poll () with
      | Some chunk -> chunk
      | None -> (
          let waited =
            Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock seconds)
              (fun () ->
                Ok
                  (Eio.Fiber.first
                     (fun () -> Eio.Condition.loop_no_mutex t.changed poll)
                     (fun () ->
                       let rec stop () =
                         if cancelled () then read t ~from
                         else begin
                           Eio.Time.Mono.sleep t.clock stop_poll;
                           stop ()
                         end
                       in
                       stop ())))
          in
          match waited with Ok chunk -> chunk | Error `Timeout -> read t ~from)

    let signal ?grace t =
      match t.live with
      | Exited _ | Terminated -> ()
      | Running ->
          t.signalled <- true;
          Subprocess.terminate ~mono:t.clock ?grace t.proc;
          (* The reap (above) is complete and protected; settle the status now,
             so a cancellation during the best-effort tail drain still leaves a
             correct [Terminated] rather than a stale [Running]. *)
          t.live <- Terminated;
          Eio.Condition.broadcast t.changed;
          ignore
            (Eio.Time.Timeout.run
               (Eio.Time.Timeout.seconds t.clock signal_drain_grace) (fun () ->
                 Eio.Promise.await t.out_done;
                 Eio.Promise.await t.err_done;
                 Ok ())
              : (unit, [ `Timeout ]) result)

    let pid t = t.child_pid
    let status t = t.live
    let since t = Mtime.span t.started_at (Eio.Time.Mono.now t.clock)
  end

  (* Per-session overrides over the one private environment. The capability's
     environment is constructed once and served byte-for-byte to every launch;
     a supervised session that needs a binding of its own — a build watch's
     private [XDG_RUNTIME_DIR] — gets it applied here, to this child alone,
     never to the capability. An override replaces any binding of the same
     name and otherwise appends. *)
  let override_environment environment overrides =
    match overrides with
    | [] -> environment
    | overrides ->
        List.iter
          (fun (name, value) ->
            if
              String.equal name "" || String.contains name '='
              || String.contains name '\000' || String.contains value '\000'
            then invalid_arg "start_session: malformed environment override")
          overrides;
        let overridden binding =
          List.exists
            (fun (name, _) ->
              String.starts_with ~prefix:(name ^ "=") binding)
            overrides
        in
        let kept =
          List.filter
            (fun binding -> not (overridden binding))
            (Array.to_list environment)
        in
        Array.of_list
          (kept @ List.map (fun (name, value) -> name ^ "=" ^ value) overrides)

  let start_session t ~sw ?cwd ?runtime_dir argv =
    let* prepared = prepare t ~sandbox:t.sandbox ~cwd argv in
    let overrides =
      match runtime_dir with
      | None -> []
      | Some dir -> [ ("XDG_RUNTIME_DIR", dir) ]
    in
    let env = override_environment prepared.child_environment overrides in
    match
      Session.launch ~sw ~proc_mgr:t.proc_mgr ~fs:t.fs ~env ~mono:t.mono
        ~cwd:prepared.cwd ~executable:prepared.executable prepared.lowered
    with
    | session -> Ok session
    | exception exn when is_launch_failure exn -> Error (launch_failure exn)
end

(* The claim window. *)

let open_claim_scope t =
  (* A still-open predecessor is sealed, never a permanent wedge: a claim
     cancelled before it could [close] must not poison the capability. The
     sealed window stops recording; its holder can still [close] it and
     harvest what it collected up to this supersession. *)
  (match t.claim_scope with
  | Some scope when not scope.Claim_scope.closed ->
      scope.Claim_scope.sealed <- true
  | Some _ | None -> ());
  let scope =
    { Claim_scope.sealed = false; closed = false; applies = []; observed = [] }
  in
  t.claim_scope <- Some scope;
  scope
