(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_workspace_io], the workspace filesystem and
   process capability. Unlike its pure sandbox twin, this library
   is all effect: every test resolves a real capability over its own fresh
   temp directories, and the process tests run real, bounded children
   ([/bin/sh], [/bin/sleep], [/usr/bin/printf], [/usr/bin/yes] — never the
   network, never an unbounded wait; a test that terminates a child asserts
   the leader is gone before returning).

   Supervision and boundary mechanics (capture policies, terminal causes,
   argv validation, cwd binding, the private environment) run on the direct
   route so they hold on hosts without an enforcing backend. Laws that only
   an enforcing backend can prove (OS-level write refusal, escalation
   dropping the profile, obligation staleness, the startup gate) run on the
   confined route and skip gracefully when the resolved evidence is not
   [Enforced]. Cleanup signals the child's process group and reaps only the
   child, so descendant liveness is asserted through what a descendant does to
   an inherited pipe — never through a pid the OS may still be reaping. *)

open Windtrap
module Wio = Mentat_workspace_io
module Command = Mentat_workspace_io.Command
module Session = Mentat_workspace_io.Command.Session
module File_error = Mentat_workspace_io.File_error
module Resolve_error = Mentat_workspace_io.Resolve_error
module Sandbox = Mentat_sandbox
module Workspace = Mentat_workspace
module Edit = Mentat_edit
module Mode = Mentat_config.Mode
module Read = Mentat_config.Read
module Abs = Lpath.Abs
module Rel = Lpath.Rel

(* {2 Helpers} *)

let abs = Abs.of_string_exn
let rel = Rel.of_string_exn
let abs_value = Testable.make ~pp:Abs.pp ~equal:Abs.equal
let path_value = Testable.make ~pp:Workspace.Path.pp ~equal:Workspace.Path.equal

let key_value =
  Testable.make ~pp:Workspace.Root.Key.pp ~equal:Workspace.Root.Key.equal

let status_value = Testable.make ~pp:Eio.Process.pp_status ~equal:( = )

let sandbox_error_value =
  Testable.make ~pp:Sandbox.Error.pp ~equal:Sandbox.Error.equal

let evidence_value =
  Testable.make ~pp:Sandbox.Evidence.pp ~equal:Sandbox.Evidence.equal

let resolve_error_value =
  Testable.make ~pp:Workspace.Resolve_error.pp
    ~equal:Workspace.Resolve_error.equal

let ws_path root text =
  Workspace.Path.make ~root_key:(Workspace.Root.key root) (rel text)

let write_file path contents =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel contents)

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* [File.load] takes a mandatory read bound; the general observation tests read
   small files, so a generous bound keeps them focused on containment. The
   bound itself is exercised by [file_load_bounds_large_files]. *)
let load io path = Wio.File.load io path ~max_bytes:(1024 * 1024)

let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> (
      Array.iter
        (fun name -> rm_rf (Filename.concat path name))
        (Sys.readdir path);
      try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> ( try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

(* Scoped ambient-environment override: the capability reads the ambient
   environment exactly once, inside [resolve], so the bindings only need to
   hold across that call. [None] unsets. *)
let with_env bindings fn =
  let saved =
    List.map (fun (name, _) -> (name, Sys.getenv_opt name)) bindings
  in
  let install (name, value) =
    match value with
    | Some value -> Unix.putenv name value
    | None -> Unix.unsetenv name
  in
  List.iter install bindings;
  Fun.protect ~finally:(fun () -> List.iter install saved) fn

(* {2 Worlds}

   Every test builds its own physical world under a fresh temp base —
   [ws/] the primary root, [out/] a never-admitted outside directory,
   [tmp/] the scratch base ([TMPDIR] during resolution) — removed on the
   way out. Paths handed to tests are physical ([realpath]'d), so they
   compare equal to the capability's canonical spellings. *)

(* Fixtures live beside the build, never under the temp directory. Every
   confined posture grants [/tmp] and the temp-dir family writable, so a control
   directory created there is inside the sandbox rather than outside it, and
   every test that proves a write is refused would instead prove that [/tmp] is
   writable. It reads as a pass on macOS, where the ambient [TMPDIR] is a
   per-user bucket the policy does not grant, and as a failure on Linux, where
   it is [/tmp] itself. *)
let fixture_root =
  let root = Filename.concat (Sys.getcwd ()) "wio-fixtures" in
  (try Unix.mkdir root 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  root

let in_dirs name fn =
  Eio_main.run @@ fun stdenv ->
  let stdenv = (stdenv :> Eio_unix.Stdenv.base) in
  let raw =
    Filename.temp_dir ~temp_dir:fixture_root ("mentat-wio-" ^ name) ""
  in
  Fun.protect ~finally:(fun () -> rm_rf raw) @@ fun () ->
  let base = Unix.realpath raw in
  let subdir sub =
    let dir = Filename.concat base sub in
    Unix.mkdir dir 0o755;
    dir
  in
  let ws_dir = subdir "ws" in
  let out_dir = subdir "out" in
  let tmp_base = subdir "tmp" in
  fn ~stdenv ~base ~ws_dir ~out_dir ~tmp_base

let resolve_capability ~stdenv ~sw ~tmp_base ?(env = []) ?env_policy
    ?(mode = Mode.Workspace_write) ?(read = Read.All) ?(readable_roots = [])
    ?(writable_roots = []) logical =
  with_env (("TMPDIR", Some tmp_base) :: env) @@ fun () ->
  (* The capability takes its ambient environment from the caller (the daemon
     passes the invoking client's); the suite hands it this process's
     snapshot, taken inside the [with_env] scope so the overrides hold. *)
  let environment = Wio.process_environment () in
  Wio.resolve ~sw ~stdenv ~logical ~environment ?env_policy ~mode ~read
    ~readable_roots ~writable_roots ~mentat_dirs:[]
    ~network:Sandbox.Policy.Network.Restricted ()

let capability_exn ~stdenv ~sw ~tmp_base ?env ?env_policy ?mode ?read
    ?readable_roots ?writable_roots logical =
  match
    resolve_capability ~stdenv ~sw ~tmp_base ?env ?env_policy ?mode ?read
      ?readable_roots ?writable_roots logical
  with
  | Ok io -> io
  | Error e -> fail (Format.asprintf "resolve failed: %a" Resolve_error.pp e)

type world = {
  io : Wio.t;
  stdenv : Eio_unix.Stdenv.base;
  base : string;
  ws_dir : string;
  out_dir : string;
  tmp_base : string;
  primary : Workspace.Root.t;
  aux : Workspace.Root.t list;
}

(* [aux] and [writable] are subdirectory names beneath the base, created here;
   [aux] entries are admitted as read-only workspace roots and [writable]
   entries as configured sandbox writable roots. *)
let with_capability ?mode ?read ?readable_roots ?(writable = []) ?(aux = [])
    ?env ?env_policy name fn =
  in_dirs name @@ fun ~stdenv ~base ~ws_dir ~out_dir ~tmp_base ->
  let mk sub =
    let dir = Filename.concat base sub in
    Unix.mkdir dir 0o755;
    dir
  in
  let aux_dirs = List.map mk aux in
  let writable_roots = List.map mk writable in
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let aux = List.map (fun dir -> Workspace.Root.of_dir (abs dir)) aux_dirs in
  let logical = Workspace.make ~primary ~read_only:aux () |> Result.get_ok in
  Eio.Switch.run @@ fun sw ->
  let io =
    capability_exn ~stdenv ~sw ~tmp_base ?env ?env_policy ?mode ?read
      ?readable_roots ~writable_roots logical
  in
  fn { io; stdenv; base; ws_dir; out_dir; tmp_base; primary; aux }

let enforced io =
  match Wio.evidence io with Sandbox.Evidence.Enforced _ -> true | _ -> false

let require_enforced io =
  if not (enforced io) then
    skip ~reason:"no enforcing sandbox backend on this host" ()

(* POSIX mode bits do not constrain the superuser: uid 0 reads a mode-000 file
   and writes below a mode-0500 directory on both Linux (CAP_DAC_OVERRIDE) and
   macOS. A refusal fixture built from mode bits therefore has no precondition
   to assert against when the suite runs as root, so those cases are skipped
   with their reason rather than weakened into something root cannot deny. *)
let require_denying_mode_bits () =
  if Unix.geteuid () = 0 then
    skip ~reason:"the superuser bypasses POSIX mode bits" ()

let sh script = [ "/bin/sh"; "-c"; script ]

(* [capture] and [timeout] are mandatory on the library surface; the test
   helper keeps the convenient trusted defaults ([All], no timeout). *)
let run_ok ?cwd ?stdin ?(capture = Command.All)
    ?(timeout = Eio.Time.Timeout.none) ?cancelled io argv =
  match Command.run io ?cwd ?stdin ~capture ~timeout ?cancelled argv with
  | Ok outcome ->
      equal evidence_value ~msg:"ordinary outcome carries its actual route"
        (Wio.evidence io) outcome.Command.sandbox_evidence;
      outcome
  | Error e -> fail (Format.asprintf "run failed: %a" Command.Error.pp e)

(* Every process outcome now carries a termination reason and structural
   captured streams; these read the common projections tests assert on. *)
let exit_status outcome =
  match outcome.Command.termination with
  | Command.Exited status -> status
  | _ -> fail "expected the child to exit, got a non-exit termination"

let stdout_str outcome = Command.Captured.render outcome.Command.stdout
let stderr_str outcome = Command.Captured.render outcome.Command.stderr

(* Raw-result variants for the refusal and escalation tests, with the same
   convenient trusted defaults as [run_ok]. *)
let run_res ?cwd ?stdin ?(capture = Command.All)
    ?(timeout = Eio.Time.Timeout.none) ?cancelled io argv =
  Command.run io ?cwd ?stdin ~capture ~timeout ?cancelled argv

let run_escalated_res ?cwd ?stdin ?(capture = Command.All)
    ?(timeout = Eio.Time.Timeout.none) ?cancelled io argv =
  Command.run_escalated io ?cwd ?stdin ~capture ~timeout ?cancelled argv

(* The probe is reaped under an installed SIGCHLD handler, which interrupts the
   wait before it runs: its own exit is the signal that arrives. *)
let rec waitpid_nointr pid =
  match Unix.waitpid [] pid with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr pid

(* The direct child (and nothing else this process spawned) carries [name];
   a clean [pgrep] proves it was terminated and reaped before the run
   returned. Descendants are deliberately not scanned: they are reparented
   away from this process the moment their own leader dies, so [pgrep -P] can
   say nothing about them either way.

   [pgrep] is spawned directly rather than through [Sys.command]: the C library
   runs a shell command as a real [/bin/sh] child of this process, so a
   shell-mediated probe is itself a direct child and would answer questions
   about process names the shell can carry. *)
let assert_leader_gone name =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let argv = [| "pgrep"; "-P"; string_of_int (Unix.getpid ()); "-x"; name |] in
  let status =
    Fun.protect
      ~finally:(fun () -> Unix.close devnull)
      (fun () ->
        let pid = Unix.create_process "pgrep" argv devnull devnull devnull in
        snd (waitpid_nointr pid))
  in
  equal int
    ~msg:(name ^ ": the direct child is terminated and reaped")
    1
    (match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> -signal)

(* The exact leader identity, free of any name collision: the pid the session
   reported must no longer resolve. A reaped child answers ESRCH; a surviving
   or unreaped (zombie) one is still signallable and fails here. *)
let assert_session_gone session =
  let pid = Session.pid session in
  match Unix.kill pid 0 with
  | () -> failf "the session leader %d survived its termination" pid
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let escalation_projects_the_sealed_stance () =
  with_capability "escalation-available" (fun w ->
      match Wio.escalation w.io with
      | Sandbox.Available -> ()
      | Sandbox.Denied _ | Sandbox.Ignored ->
          fail "a workspace-write seal projects an available escalation stance");
  with_capability "escalation-denied" ~mode:Mode.Read_only (fun w ->
      match Wio.escalation w.io with
      | Sandbox.Denied _ -> ()
      | Sandbox.Available | Sandbox.Ignored ->
          fail "a read-only seal projects a denied escalation stance");
  with_capability "escalation-ignored" ~mode:Mode.Danger_full_access (fun w ->
      match Wio.escalation w.io with
      | Sandbox.Ignored -> ()
      | Sandbox.Available | Sandbox.Denied _ ->
          fail "a direct route projects an ignored escalation stance")

(* Resume compares the identity a fresh resolution projects against the one the
   suspended contract stored, so a resolution that is not a function of the
   workspace refuses a pending invocation with nothing having changed. The pure
   direction — a changed policy changes the digest — is pinned in the sandbox
   suite; this is the direction only a real resolution can answer, and it is
   load-bearing now that no normalization step stands between the derivation and
   the digest. *)
let resolving_twice_agrees_on_the_identity () =
  in_dirs "identity-stable"
  @@ fun ~stdenv ~base:_ ~ws_dir ~out_dir:_ ~tmp_base ->
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  let resolve () =
    Eio.Switch.run @@ fun sw ->
    Wio.identity
      (capability_exn ~stdenv ~sw ~tmp_base ~writable_roots:[] logical)
  in
  let first = resolve () in
  let second = resolve () in
  is_true ~msg:"two resolutions of one unchanged workspace project one identity"
    (Sandbox.Identity.equal first second)

let resolve_path_uses_the_capability_workspace () =
  with_capability "resolve-path" ~aux:[ "vendor" ] @@ fun w ->
  let auxiliary = List.hd w.aux in
  equal path_value ~msg:"relative input resolves beneath the primary cwd"
    (ws_path w.primary "src/main.ml")
    (Result.get_ok (Wio.resolve_path w.io "src/main.ml"));
  let auxiliary_file =
    Filename.concat (Abs.to_string (Workspace.Root.dir auxiliary)) "pkg/a.ml"
  in
  equal path_value ~msg:"absolute auxiliary input selects its own root"
    (ws_path auxiliary "pkg/a.ml")
    (Result.get_ok (Wio.resolve_path w.io auxiliary_file));
  equal
    (result path_value resolve_error_value)
    ~msg:"malformed input stays a structured logical error"
    (Error
       (Workspace.Resolve_error.Invalid_input
          (Lpath.Error.Malformed_component "a\000b")))
    (Wio.resolve_path w.io "a\000b");
  equal
    (result path_value resolve_error_value)
    ~msg:"an absolute path under no admitted root is refused"
    (Error (Workspace.Resolve_error.Outside_workspace (abs w.out_dir)))
    (Wio.resolve_path w.io w.out_dir)

let describe_roots_labels_scoped_reads () =
  in_dirs "describe" @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  let extra_read = Filename.concat base "extra-read" in
  Unix.mkdir extra_read 0o755;
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  Eio.Switch.run @@ fun sw ->
  let io =
    capability_exn ~stdenv ~sw ~tmp_base
      ~env:
        [
          ("PATH", Some "/usr/bin:/bin");
          ("OPAM_SWITCH_PREFIX", None);
          ("MENTAT_DUNE", None);
          ("CAML_LD_LIBRARY_PATH", None);
          ("OCAMLPATH", None);
          ("OCAML_TOPLEVEL_PATH", None);
          ("OCAMLLIB", None);
          ("DUNE_OCAML_STDLIB", None);
        ]
      ~read:Read.Project ~readable_roots:[ extra_read ] logical
  in
  let described = Wio.describe_roots io in
  (match described with
  | ("project", dir) :: _ ->
      equal abs_value ~msg:"the project root leads, canonically" (abs ws_dir)
        dir
  | _ -> fail "describe_roots must lead with the project root");
  is_true ~msg:"the configured read root is labeled user-configured"
    (List.exists
       (fun (label, dir) ->
         String.equal label "user-configured" && Abs.equal dir (abs extra_read))
       described);
  let fixed =
    [
      "project";
      "user-configured";
      "platform";
      "executable:PATH";
      "executable:PATH runtime";
      "git-worktree";
      "git-config";
    ]
  in
  List.iter
    (fun (label, _) ->
      is_true
        ~msg:(label ^ " is a documented display label")
        (List.mem label fixed || String.starts_with ~prefix:"toolchain:" label))
    described;
  List.iter
    (fun (_, dir) ->
      is_false ~msg:"the scratch is never described"
        (String.starts_with ~prefix:tmp_base (Abs.to_string dir)))
    described

let describe_roots_carries_user_toolchain_dirs () =
  in_dirs "carried" @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  (* A fake real home whose opam and XDG directories exist: with HOME redirected
     to the scratch, the resolver still admits them as read roots so opam finds
     its root (F3) and dune finds its shared cache. *)
  let home = Filename.concat base "home" in
  Unix.mkdir home 0o755;
  let mk sub =
    let dir = Filename.concat home sub in
    Unix.mkdir dir 0o755;
    Unix.realpath dir
  in
  let mk_path sub =
    let dir = Filename.concat home sub in
    let rec create path =
      if not (Sys.file_exists path) then (
        create (Filename.dirname path);
        Unix.mkdir path 0o755)
    in
    create dir;
    Unix.realpath dir
  in
  let opam = mk ".opam" and cache = mk ".cache" and config = mk ".config" in
  let config_dune = mk_path (Filename.concat ".config" "dune")
  and data = mk_path (Filename.concat ".local" "share")
  and state = mk_path (Filename.concat ".local" "state")
  and cache_dune = mk_path (Filename.concat ".cache" "dune")
  and cache_db =
    mk_path (Filename.concat ".cache" (Filename.concat "dune" "db"))
  and cache_toolchains =
    mk_path (Filename.concat ".cache" (Filename.concat "dune" "toolchains"))
  in
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  Eio.Switch.run @@ fun sw ->
  (* Hermetic: [resolve] reads the ambient environment, and a runner may leak a
     malformed toolchain value ([dune exec] injects an unexpanded
     [OCAML_TOPLEVEL_PATH=%{toplevel}%]) that the fail-closed root parse would
     reject. Pin a benign PATH and unset every toolchain and XDG variable the
     derivation reads, so the fixture depends only on the [$HOME]-relative
     directories it creates. *)
  let io =
    capability_exn ~stdenv ~sw ~tmp_base
      ~env:
        [
          ("HOME", Some home);
          ("PATH", Some "/usr/bin:/bin");
          ("OPAM_SWITCH_PREFIX", None);
          ("MENTAT_DUNE", None);
          ("CAML_LD_LIBRARY_PATH", None);
          ("OCAMLPATH", None);
          ("OCAML_TOPLEVEL_PATH", None);
          ("OCAMLLIB", None);
          ("DUNE_OCAML_STDLIB", None);
          ("OPAMROOT", None);
          ("XDG_CACHE_HOME", None);
          ("XDG_CONFIG_HOME", None);
          ("XDG_STATE_HOME", None);
          ("XDG_DATA_HOME", None);
        ]
      ~read:Read.Project logical
  in
  let described = Wio.describe_roots io in
  let admitted label dir =
    List.exists
      (fun (l, d) -> String.equal l label && Abs.equal d (abs dir))
      described
  in
  is_true ~msg:"the real opam root is admitted, labeled OPAMROOT"
    (admitted "toolchain:OPAMROOT" opam);
  is_true ~msg:"dune's own cache is admitted, labeled XDG_CACHE_HOME"
    (admitted "toolchain:XDG_CACHE_HOME" cache_dune);
  is_true
    ~msg:"dune's own config directory is admitted, labeled XDG_CONFIG_HOME"
    (admitted "toolchain:XDG_CONFIG_HOME" config_dune);
  (* The variable still binds to the base directory the tool resolves against,
     but the read scope stops at the subdirectory the build reads. The base is
     shared with every other tool on the machine, Mentat's own credentials among
     them, and none of it is a build input. *)
  let read_roots =
    match Wio.policy io with
    | Some policy -> (
        match Sandbox.Policy.reads_default policy with
        | Sandbox.Policy.Denied -> Sandbox.Policy.readable_roots policy
        | Sandbox.Policy.All -> fail "expected a project-scoped read policy")
    | None -> fail "expected a confined seal carrying a policy"
  in
  let readable dir = List.exists (Abs.equal (abs dir)) read_roots in
  is_true ~msg:"the narrowed config subpath is a read root"
    (readable config_dune);
  is_false
    ~msg:
      "the shared XDG config base is not a read root, so neighbouring tools' \
       credentials stay outside the read scope"
    (readable config);
  is_false ~msg:"the session store is not a read root" (readable data);
  is_false ~msg:"the log directory is not a read root" (readable state);
  (* The carry decides an access per variable, and the sealed policy must agree
     with what the child environment names: the cache the build writes is a
     writable root, and the directories holding Mentat's own durable state are
     not. A carried directory that is named but not usable for what the tool
     needs it for is the defect this pairing exists to make unrepresentable. *)
  let writable =
    match Wio.policy io with
    | Some policy -> Sandbox.Policy.writable_roots policy
    | None -> fail "expected a confined seal carrying a policy"
  in
  let grants dir = List.exists (Abs.equal (abs dir)) writable in
  is_true ~msg:"dune's cache is writable, so it can take its rev-store lock"
    (grants cache_dune);
  is_false
    ~msg:
      "the shared XDG cache base is not writable — its neighbours hold other \
       tools' executables"
    (grants cache);
  is_false ~msg:"the opam root stays read-only" (grants opam);
  is_false ~msg:"the carried XDG config stays read-only" (grants config);
  (* The XDG state and data directories are not carried at all: no build tool
     resolves them and they hold Mentat's own session store and logs. *)
  is_false ~msg:"the session store is not writable" (grants data);
  is_false ~msg:"the log directory is not writable" (grants state);
  (* Dune's shared cache and downloaded toolchains are replayed and executed by
     builds outside the sandbox, so the lock grant does not reach them. *)
  let protected =
    match Wio.policy io with
    | Some policy ->
        (* A carveout is now a [Read] clause; the enclosing grant is [Write]. *)
        List.filter_map
          (fun (path, access) ->
            match access with
            | Sandbox.Policy.Access.Read -> Some path
            | Sandbox.Policy.Access.Write | Sandbox.Policy.Access.Deny -> None)
          (Sandbox.Policy.entries policy)
    | None -> fail "expected a confined seal carrying a policy"
  in
  let carved dir = List.exists (Abs.equal (abs dir)) protected in
  is_true ~msg:"the dune build cache is carved out of the cache grant"
    (carved cache_db);
  is_true ~msg:"the dune toolchains are carved out of the cache grant"
    (carved cache_toolchains)

(* Dune resolves its cache root from [DUNE_CACHE_ROOT] before the XDG cache
   base, and the child inherits the variable, so the grant must follow the same
   resolution: the named directory is the writable cache, with the same
   carveouts secured beneath it, and the XDG default is not granted at all. *)
let describe_roots_follows_dune_cache_root () =
  in_dirs "cache-root" @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  let home = Filename.concat base "home" in
  Unix.mkdir home 0o755;
  let mk_path sub =
    let dir = Filename.concat home sub in
    let rec create path =
      if not (Sys.file_exists path) then (
        create (Filename.dirname path);
        Unix.mkdir path 0o755)
    in
    create dir;
    Unix.realpath dir
  in
  let xdg_cache_dune = mk_path (Filename.concat ".cache" "dune") in
  let cache_root = mk_path "dune-cache" in
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  Eio.Switch.run @@ fun sw ->
  let io =
    capability_exn ~stdenv ~sw ~tmp_base
      ~env:
        [
          ("HOME", Some home);
          ("PATH", Some "/usr/bin:/bin");
          ("DUNE_CACHE_ROOT", Some cache_root);
          ("OPAM_SWITCH_PREFIX", None);
          ("MENTAT_DUNE", None);
          ("CAML_LD_LIBRARY_PATH", None);
          ("OCAMLPATH", None);
          ("OCAML_TOPLEVEL_PATH", None);
          ("OCAMLLIB", None);
          ("DUNE_OCAML_STDLIB", None);
          ("OPAMROOT", None);
          ("XDG_CACHE_HOME", None);
          ("XDG_CONFIG_HOME", None);
          ("XDG_STATE_HOME", None);
          ("XDG_DATA_HOME", None);
        ]
      ~read:Read.Project logical
  in
  let policy =
    match Wio.policy io with
    | Some policy -> policy
    | None -> fail "expected a confined seal carrying a policy"
  in
  is_true ~msg:"the named cache root is admitted, labeled DUNE_CACHE_ROOT"
    (List.exists
       (fun (label, dir) ->
         String.equal label "toolchain:DUNE_CACHE_ROOT"
         && Abs.equal dir (abs cache_root))
       (Wio.describe_roots io));
  let writable = Sandbox.Policy.writable_roots policy in
  let grants dir = List.exists (Abs.equal (abs dir)) writable in
  is_true ~msg:"the named cache root is writable" (grants cache_root);
  is_false ~msg:"the XDG default is not granted when the variable names another"
    (grants xdg_cache_dune);
  let carved dir =
    List.exists
      (fun (path, access) ->
        Sandbox.Policy.Access.equal access Sandbox.Policy.Access.Read
        && Abs.equal path (abs dir))
      (Sandbox.Policy.entries policy)
  in
  is_true ~msg:"the build cache is carved out beneath the named root"
    (carved (Filename.concat cache_root "db"));
  is_true ~msg:"the toolchains are carved out beneath the named root"
    (carved (Filename.concat cache_root "toolchains"))

let describe_roots_admits_git_config () =
  in_dirs "gitcfg" @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  (* A fake real home holding git's global configuration next to the state that
     must stay unreachable: the credential file and the shared XDG config base.
     Git aborts on a denied config read where a missing file is fine, so the
     resolver admits exactly the files git resolves, read-only. *)
  let home = Filename.concat base "home" in
  Unix.mkdir home 0o755;
  let mk_dir sub =
    let dir = Filename.concat home sub in
    let rec create path =
      if not (Sys.file_exists path) then (
        create (Filename.dirname path);
        Unix.mkdir path 0o755)
    in
    create dir;
    Unix.realpath dir
  in
  let mk_file path =
    Out_channel.with_open_text path (fun oc ->
        Out_channel.output_string oc "# fixture\n");
    Unix.realpath path
  in
  let gitconfig = mk_file (Filename.concat home ".gitconfig") in
  let config_git = mk_dir (Filename.concat ".config" "git") in
  let credentials = mk_file (Filename.concat home ".git-credentials") in
  let config = Unix.realpath (Filename.concat home ".config") in
  let named = mk_file (Filename.concat base "work.gitconfig") in
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  let env ~global =
    [
      ("HOME", Some home);
      ("PATH", Some "/usr/bin:/bin");
      ("GIT_CONFIG_GLOBAL", global);
      ("OPAM_SWITCH_PREFIX", None);
      ("MENTAT_DUNE", None);
      ("CAML_LD_LIBRARY_PATH", None);
      ("OCAMLPATH", None);
      ("OCAML_TOPLEVEL_PATH", None);
      ("OCAMLLIB", None);
      ("DUNE_OCAML_STDLIB", None);
      ("OPAMROOT", None);
      ("XDG_CACHE_HOME", None);
      ("XDG_CONFIG_HOME", None);
      ("XDG_STATE_HOME", None);
      ("XDG_DATA_HOME", None);
    ]
  in
  let read_roots io =
    match Wio.policy io with
    | Some policy -> (
        match Sandbox.Policy.reads_default policy with
        | Sandbox.Policy.Denied -> Sandbox.Policy.readable_roots policy
        | Sandbox.Policy.All -> fail "expected a project-scoped read policy")
    | None -> fail "expected a confined seal carrying a policy"
  in
  (Eio.Switch.run @@ fun sw ->
   let io =
     capability_exn ~stdenv ~sw ~tmp_base ~env:(env ~global:None)
       ~read:Read.Project logical
   in
   let described = Wio.describe_roots io in
   let admitted dir =
     List.exists
       (fun (l, d) -> String.equal l "git-config" && Abs.equal d (abs dir))
       described
   in
   is_true ~msg:"the global gitconfig is admitted, labeled git-config"
     (admitted gitconfig);
   is_true ~msg:"the XDG git directory is admitted, labeled git-config"
     (admitted config_git);
   let readable dir = List.exists (Abs.equal (abs dir)) (read_roots io) in
   is_true ~msg:"the global gitconfig is a read root" (readable gitconfig);
   is_true ~msg:"the XDG git directory is a read root" (readable config_git);
   is_false
     ~msg:
       "the credential file next to the config is not a read root — the admit \
        covers configuration, never credentials"
     (readable credentials);
   is_false
     ~msg:
       "the shared XDG config base is not a read root, so neighbouring tools' \
        credentials stay outside the read scope"
     (readable config));
  (* [GIT_CONFIG_GLOBAL] replaces both default paths, so the admitted roots
     follow it: the named file alone is readable. *)
  Eio.Switch.run @@ fun sw ->
  let io =
    capability_exn ~stdenv ~sw ~tmp_base
      ~env:(env ~global:(Some named))
      ~read:Read.Project logical
  in
  let readable dir = List.exists (Abs.equal (abs dir)) (read_roots io) in
  is_true ~msg:"the named config file is a read root" (readable named);
  is_false ~msg:"the replaced global gitconfig is not admitted"
    (readable gitconfig);
  is_false ~msg:"the replaced XDG git directory is not admitted"
    (readable config_git)

let toolchain_placeholder_is_skipped_not_fatal () =
  in_dirs "toolchain-placeholder"
  @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  let hermetic value =
    [
      ("PATH", Some "/usr/bin:/bin");
      ("OPAM_SWITCH_PREFIX", None);
      ("MENTAT_DUNE", None);
      ("CAML_LD_LIBRARY_PATH", None);
      ("OCAMLPATH", None);
      ("OCAML_TOPLEVEL_PATH", value);
      ("OCAMLLIB", None);
      ("DUNE_OCAML_STDLIB", None);
    ]
  in
  (* [dune exec] — the standard mentat dev loop — leaks an unexpanded placeholder
     into a toolchain variable ([OCAML_TOPLEVEL_PATH=%{toplevel}%]) that names no
     absolute path. Ambient recovery is best-effort, so the derivation skips it
     with a logged warning and the run proceeds, rather than refusing on an
     artifact the user never set. *)
  ( Eio.Switch.run @@ fun sw ->
    match
      resolve_capability ~stdenv ~sw ~tmp_base
        ~env:(hermetic (Some "%{toplevel}%"))
        ~read:Read.Project logical
    with
    | Error e ->
        failf "a placeholder toolchain value must not refuse resolution: %a"
          Resolve_error.pp e
    | Ok io ->
        is_true ~msg:"the placeholder is not admitted as a toolchain read root"
          (not
             (List.exists
                (fun (label, _) ->
                  String.equal label "toolchain:OCAML_TOPLEVEL_PATH")
                (Wio.describe_roots io))) );
  (* A toolchain value that resolves to a broad root still fails closed: skipping
     it would silently widen the derived read scope past the project. *)
  Eio.Switch.run @@ fun sw ->
  match
    resolve_capability ~stdenv ~sw ~tmp_base ~env:(hermetic (Some base))
      ~read:Read.Project logical
  with
  | Error (Resolve_error.Broad_root { field; _ }) ->
      equal string ~msg:"a broad toolchain root names its variable"
        "OCAML_TOPLEVEL_PATH" field
  | Ok _ -> fail "a broad toolchain root must refuse resolution"
  | Error e ->
      failf "wrong resolve error for a broad toolchain root: %a"
        Resolve_error.pp e

let resolve_refuses_a_missing_workspace_root () =
  in_dirs "missing-root" @@ fun ~stdenv ~base ~ws_dir:_ ~out_dir:_ ~tmp_base ->
  let primary =
    Workspace.Root.of_dir (abs (Filename.concat base "not-there"))
  in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  Eio.Switch.run @@ fun sw ->
  (match resolve_capability ~stdenv ~sw ~tmp_base logical with
  | Ok _ -> fail "resolving a missing workspace root must fail"
  | Error (Resolve_error.Missing_root root) ->
      equal key_value ~msg:"the missing root names the primary"
        (Workspace.Root.key primary)
        (Workspace.Root.key root)
  | Error e -> failf "wrong resolve error: %a" Resolve_error.pp e);
  equal (list string)
    ~msg:"a resolution that fails before minting leaves no scratch litter" []
    (Array.to_list (Sys.readdir tmp_base))

let resolve_refuses_broad_writable_roots () =
  in_dirs "broad" @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  let broad spelling label =
    Eio.Switch.run @@ fun sw ->
    match
      resolve_capability ~stdenv ~sw ~tmp_base ~writable_roots:[ spelling ]
        logical
    with
    | Ok _ -> failf "%s: broad root %s must be refused" label spelling
    | Error (Resolve_error.Broad_root { field; spelling = reported }) ->
        equal string
          ~msg:(label ^ ": the refusal names the configuration surface")
          "sandbox.writable_roots" field;
        equal string
          ~msg:(label ^ ": the refusal preserves the spelling")
          spelling reported
    | Error e -> failf "%s: wrong resolve error: %a" label Resolve_error.pp e
  in
  broad "/" "the filesystem root";
  broad base "an ancestor of the workspace root"

let resolve_refuses_invalid_configured_roots () =
  in_dirs "invalid" @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  let invalid spelling expected label =
    Eio.Switch.run @@ fun sw ->
    match
      resolve_capability ~stdenv ~sw ~tmp_base ~writable_roots:[ spelling ]
        logical
    with
    | Ok _ -> failf "%s: %s must be refused" label spelling
    | Error (Resolve_error.Invalid_root { spelling = reported; reason }) ->
        equal string
          ~msg:(label ^ ": the refusal preserves the spelling")
          spelling reported;
        is_true
          ~msg:(label ^ ": the refusal reason is structured")
          (reason = expected)
    | Error e -> failf "%s: wrong resolve error: %a" label Resolve_error.pp e
  in
  invalid
    (Filename.concat base "absent")
    Resolve_error.Does_not_exist "a missing directory";
  invalid "relative/root" Resolve_error.Not_accessible "a relative spelling";
  let file = Filename.concat base "plain-file" in
  write_file file "not a directory\n";
  invalid file Resolve_error.Not_a_directory "a file where a directory must be";
  (* A read root admits directories and regular files; a FIFO (or socket,
     device node) is the wrong kind for that role and gets its own reason. *)
  let fifo = Filename.concat base "pipe" in
  Unix.mkfifo fifo 0o600;
  Eio.Switch.run @@ fun sw ->
  match
    resolve_capability ~stdenv ~sw ~tmp_base
      ~env:[ ("PATH", Some "/usr/bin:/bin") ]
      ~read:Read.Project ~readable_roots:[ fifo ] logical
  with
  | Ok _ -> fail "a fifo read root must be refused"
  | Error (Resolve_error.Invalid_root { spelling; reason }) ->
      equal string ~msg:"the fifo refusal preserves the spelling" fifo spelling;
      is_true ~msg:"a wrong-kind read root is Not_a_directory_or_file"
        (reason = Resolve_error.Not_a_directory_or_file)
  | Error e ->
      failf "fifo read root: wrong resolve error: %a" Resolve_error.pp e

let load_and_stat_inside_the_root () =
  with_capability "file-read" @@ fun w ->
  write_file (Filename.concat w.ws_dir "file.txt") "hello\n";
  Unix.symlink "file.txt" (Filename.concat w.ws_dir "link-in");
  (match load w.io (ws_path w.primary "file.txt") with
  | Ok contents ->
      equal string ~msg:"load returns the complete bytes" "hello\n" contents
  | Error e -> failf "load failed: %a" File_error.pp e);
  (match Wio.File.stat w.io (ws_path w.primary "file.txt") with
  | Ok stat ->
      is_true ~msg:"stat reports a regular file"
        (stat.Eio.File.Stat.kind = `Regular_file)
  | Error e -> failf "stat failed: %a" File_error.pp e);
  (match load w.io (ws_path w.primary "link-in") with
  | Ok contents ->
      equal string ~msg:"a final in-root symlink is followed to its bytes"
        "hello\n" contents
  | Error e -> failf "symlink load failed: %a" File_error.pp e);
  match Wio.File.stat w.io (ws_path w.primary "link-in") with
  | Ok stat ->
      is_true ~msg:"stat follows the in-root symlink to the target's metadata"
        (stat.Eio.File.Stat.kind = `Regular_file)
  | Error e -> failf "symlink stat failed: %a" File_error.pp e

let symlink_escapes_are_refused () =
  with_capability "file-escape" ~aux:[ "aux" ] @@ fun w ->
  let aux_root = List.hd w.aux in
  let aux_dir = Filename.concat w.base "aux" in
  write_file (Filename.concat w.out_dir "secret.txt") "TOPSECRET\n";
  write_file (Filename.concat aux_dir "aux.txt") "aux\n";
  Unix.symlink
    (Filename.concat w.out_dir "secret.txt")
    (Filename.concat w.ws_dir "link-abs");
  Unix.symlink "../out/secret.txt" (Filename.concat w.ws_dir "link-up");
  Unix.symlink
    (Filename.concat aux_dir "aux.txt")
    (Filename.concat w.ws_dir "link-aux");
  let escapes name label =
    let target = ws_path w.primary name in
    match load w.io target with
    | Error (File_error.Escapes_workspace reported) ->
        equal path_value
          ~msg:(label ^ ": the refusal names the requested path")
          target reported
    | Ok contents -> failf "%s: escaped the root and read %S" label contents
    | Error e -> failf "%s: wrong error: %a" label File_error.pp e
  in
  escapes "link-abs" "an absolute symlink out of every root";
  escapes "link-up" "a dot-dot traversal out of the root";
  escapes "link-aux" "a symlink into a different admitted root (per-bound-root)";
  match load w.io (ws_path aux_root "aux.txt") with
  | Ok contents ->
      equal string ~msg:"the same bytes read fine through their own root"
        "aux\n" contents
  | Error e -> failf "aux load failed: %a" File_error.pp e

let missing_and_foreign_targets_are_structured () =
  with_capability "file-misc" @@ fun w ->
  let missing = ws_path w.primary "missing.txt" in
  (match load w.io missing with
  | Error (File_error.Not_found reported) ->
      equal path_value ~msg:"a missing file is Not_found with its path" missing
        reported
  | Ok _ -> fail "a missing file must not load"
  | Error e -> failf "wrong error: %a" File_error.pp e);
  (match Wio.File.stat w.io (ws_path w.primary "missing/deep.txt") with
  | Error (File_error.Not_found _) -> ()
  | Ok _ -> fail "a missing intermediate directory must not stat"
  | Error e -> failf "wrong error: %a" File_error.pp e);
  let ghost = Workspace.Root.Key.of_string_exn "ghost" in
  match load w.io (Workspace.Path.make ~root_key:ghost (rel "x.txt")) with
  | Error (File_error.Unknown_root key) ->
      equal key_value ~msg:"a foreign root key is Unknown_root" ghost key
  | Ok _ -> fail "a foreign root key must not load"
  | Error e -> failf "wrong error: %a" File_error.pp e

let permission_refusals_keep_their_io_class () =
  require_denying_mode_bits ();
  with_capability "file-io" @@ fun w ->
  let file = Filename.concat w.ws_dir "noperm.txt" in
  write_file file "secret\n";
  Unix.chmod file 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod file 0o600) @@ fun () ->
  let target = ws_path w.primary "noperm.txt" in
  match load w.io target with
  | Error (File_error.Io { path; cause = _ }) ->
      equal path_value ~msg:"a genuine EACCES stays Io, not containment" target
        path
  | Ok _ -> fail "an unreadable file must not load"
  | Error e -> failf "wrong error class: %a" File_error.pp e

let read_dir_lists_workspace_paths_in_order () =
  with_capability "file-dir" @@ fun w ->
  Unix.mkdir (Filename.concat w.ws_dir "subdir") 0o755;
  write_file (Filename.concat w.ws_dir "subdir/b.txt") "b";
  write_file (Filename.concat w.ws_dir "subdir/a.txt") "a";
  match Wio.File.read_dir w.io (ws_path w.primary "subdir") with
  | Ok entries ->
      equal (list path_value)
        ~msg:"entries are name-ordered workspace paths beneath the directory"
        [ ws_path w.primary "subdir/a.txt"; ws_path w.primary "subdir/b.txt" ]
        entries
  | Error e -> failf "read_dir failed: %a" File_error.pp e

(* The kind travels with the entry, and it is the entry's own kind: a symlink
   reports as a symlink rather than as whatever it points at, so a walk reading
   a directory sees what [lstat] would have told it and not what [stat] would.
   [`Unknown] is never returned — a filesystem that does not record the kind is
   resolved behind this call, so no caller has to mistake "unrecorded" for "not
   a file I want". *)
let read_dir_entries_carries_each_entry_kind () =
  with_capability "file-dir-kinds" @@ fun w ->
  let dir = Filename.concat w.ws_dir "kinds" in
  Unix.mkdir dir 0o755;
  write_file (Filename.concat dir "regular.txt") "r";
  Unix.mkdir (Filename.concat dir "child") 0o755;
  Unix.symlink "regular.txt" (Filename.concat dir "link");
  Unix.mkfifo (Filename.concat dir "pipe") 0o600;
  let kind_name = function
    | `Regular_file -> "regular"
    | `Directory -> "directory"
    | `Symbolic_link -> "symlink"
    | `Fifo -> "fifo"
    | `Unknown -> "unknown"
    | `Character_special | `Block_device | `Socket -> "other"
  in
  match Wio.File.read_dir_entries w.io (ws_path w.primary "kinds") with
  | Ok entries ->
      let named =
        List.map
          (fun (kind, path) ->
            ( Option.value (Mentat_workspace.Path.basename path) ~default:"?",
              kind_name kind ))
          entries
      in
      equal
        (list (pair string string))
        ~msg:"every entry carries its own resolved kind, in name order"
        [
          ("child", "directory");
          ("link", "symlink");
          ("pipe", "fifo");
          ("regular.txt", "regular");
        ]
        named
  | Error e -> failf "read_dir_entries failed: %a" File_error.pp e

(* Exhaustive binding matrix over symlink targets: [ups] dot-dot components
   followed by a known suffix. The space is small enough to enumerate
   completely, which beats sampling it: any dot-dot traversal escapes the
   bound root (even one that lexically re-enters it), and an in-root target
   resolves to exactly the in-root bytes or Not_found — never to bytes from
   outside the root prefix. *)
let binding_never_escapes_the_bound_root () =
  with_capability "file-matrix" @@ fun w ->
  write_file (Filename.concat w.ws_dir "inside.txt") "INSIDE\n";
  write_file (Filename.concat w.out_dir "leak.txt") "OUTSIDE\n";
  let suffixes =
    [ "inside.txt"; "ws/inside.txt"; "out/leak.txt"; "ws"; "out" ]
  in
  List.iter
    (fun ups ->
      List.iteri
        (fun i suffix ->
          let target =
            String.concat "" (List.init ups (fun _ -> "../")) ^ suffix
          in
          let name = Printf.sprintf "matrix-%d-%d" ups i in
          Unix.symlink target (Filename.concat w.ws_dir name);
          let case = Printf.sprintf "link -> %s" target in
          match load w.io (ws_path w.primary name) with
          | Ok contents ->
              is_true
                ~msg:(case ^ ": only the in-root target may resolve")
                (ups = 0 && String.equal suffix "inside.txt");
              equal string
                ~msg:(case ^ ": resolves to the in-root bytes")
                "INSIDE\n" contents
          | Error (File_error.Escapes_workspace _) ->
              is_true
                ~msg:(case ^ ": escape verdicts exactly for dot-dot traversals")
                (ups >= 1)
          | Error (File_error.Not_found _) ->
              is_true
                ~msg:(case ^ ": in-root misses are Not_found")
                (ups = 0 && not (String.equal suffix "inside.txt"))
          | Error e -> failf "%s: wrong error: %a" case File_error.pp e)
        suffixes)
    [ 0; 1; 2; 3 ]

(* An observation read is bounded — a file over [max_bytes] is a
   structured [Too_large] carrying its size, never an unbounded read. *)
let file_load_bounds_large_files () =
  with_capability "file-bound" @@ fun w ->
  write_file (Filename.concat w.ws_dir "big.txt") (String.make 4096 'x');
  let target = ws_path w.primary "big.txt" in
  (match Wio.File.load w.io target ~max_bytes:4096 with
  | Ok contents ->
      equal int ~msg:"a file exactly at the bound loads whole" 4096
        (String.length contents)
  | Error e -> failf "at-bound load failed: %a" File_error.pp e);
  match Wio.File.load w.io target ~max_bytes:4095 with
  | Error (File_error.Too_large { path; size; max_bytes }) ->
      equal path_value ~msg:"the refusal names the requested path" target path;
      is_true ~msg:"the refusal carries the true size" (Int64.equal 4096L size);
      equal int ~msg:"the refusal carries the bound" 4095 max_bytes
  | Ok _ -> fail "a file over the bound must not load"
  | Error e -> failf "wrong error: %a" File_error.pp e

(* The Permission_denied classifier, pinned against the eio_posix backend.
   An out-of-subtree resolution is refused with the backend's Outside_sandbox
   permission-denied marker, which the boundary classifies as
   [Escapes_workspace]; a genuine in-root [EACCES] keeps its [Io] class. The
   two are never conflated. *)
let permission_denied_classifier_is_backend_pinned () =
  with_capability "classifier" @@ fun w ->
  write_file (Filename.concat w.out_dir "secret.txt") "SECRET\n";
  Unix.symlink
    (Filename.concat w.out_dir "secret.txt")
    (Filename.concat w.ws_dir "escape");
  (match load w.io (ws_path w.primary "escape") with
  | Error (File_error.Escapes_workspace _) -> ()
  | Ok _ -> fail "an out-of-root escape must be refused, not read"
  | Error e ->
      failf "an escape must classify as Escapes_workspace, got %a" File_error.pp
        e);
  (* The escape half above holds for every identity; only the EACCES half needs
     mode bits the kernel will honour. *)
  require_denying_mode_bits ();
  let locked = Filename.concat w.ws_dir "locked.txt" in
  write_file locked "in-root\n";
  Unix.chmod locked 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod locked 0o600) @@ fun () ->
  match load w.io (ws_path w.primary "locked.txt") with
  | Error (File_error.Io _) -> ()
  | Error (File_error.Escapes_workspace _) ->
      fail "a genuine in-root EACCES must not be misclassified as an escape"
  | Ok _ -> fail "an unreadable in-root file must not load"
  | Error e -> failf "wrong error: %a" File_error.pp e

(* Edit: the native-write enforcer. *)

let plan_exn = function
  | Ok plan -> plan
  | Error e -> failf "plan construction failed: %a" Edit.Error.pp e

let edit_creates_with_parent_directories () =
  with_capability "edit-create" @@ fun w ->
  let target = ws_path w.primary "a/b/created.txt" in
  let plan = plan_exn (Edit.create ~path:target ~contents:"fresh\n") in
  match Wio.Edit.apply w.io plan with
  | Error e -> failf "apply failed: %a" Edit.Apply_error.pp e
  | Ok result ->
      (match Edit.Result.entries result with
      | [ entry ] ->
          is_true ~msg:"the entry is a creation"
            (Edit.Result.Entry.kind entry = `Create);
          is_true ~msg:"the entry saw the missing before state"
            (Edit.Observed.equal
               (Edit.Result.Entry.before entry)
               Edit.Observed.Missing);
          is_true ~msg:"the entry carries the after bytes"
            (Edit.Observed.equal
               (Edit.Result.Entry.after entry)
               (Edit.Observed.Text "fresh\n"))
      | entries -> failf "expected one entry, got %d" (List.length entries));
      equal string ~msg:"the bytes are on disk beneath the created parents"
        "fresh\n"
        (read_file (Filename.concat w.ws_dir "a/b/created.txt"))

let edit_rewrites_and_deletes () =
  with_capability "edit-cycle" @@ fun w ->
  let file = Filename.concat w.ws_dir "target.txt" in
  write_file file "old\n";
  let target = ws_path w.primary "target.txt" in
  (match
     Wio.Edit.apply w.io
       (plan_exn (Edit.rewrite ~path:target ~before:"old\n" ~after:"new\n"))
   with
  | Error e -> failf "rewrite failed: %a" Edit.Apply_error.pp e
  | Ok result ->
      (match Edit.Result.entries result with
      | [ entry ] ->
          is_true ~msg:"a rewrite is a modify"
            (Edit.Result.Entry.kind entry = `Modify);
          is_true ~msg:"the entry carries the authoritative before bytes"
            (Edit.Observed.equal
               (Edit.Result.Entry.before entry)
               (Edit.Observed.Text "old\n"));
          is_true ~msg:"the entry carries the authoritative after bytes"
            (Edit.Observed.equal
               (Edit.Result.Entry.after entry)
               (Edit.Observed.Text "new\n"))
      | entries -> failf "expected one entry, got %d" (List.length entries));
      equal string ~msg:"the rewrite landed" "new\n" (read_file file));
  match
    Wio.Edit.apply w.io (plan_exn (Edit.delete ~path:target ~before:"new\n"))
  with
  | Error e -> failf "delete failed: %a" Edit.Apply_error.pp e
  | Ok result ->
      (match Edit.Result.entries result with
      | [ entry ] ->
          is_true ~msg:"a delete is a delete"
            (Edit.Result.Entry.kind entry = `Delete)
      | entries -> failf "expected one entry, got %d" (List.length entries));
      is_false ~msg:"the file is gone" (Sys.file_exists file)

let edit_stale_expectation_stops_in_preflight () =
  with_capability "edit-stale" @@ fun w ->
  let file = Filename.concat w.ws_dir "stale.txt" in
  write_file file "actual\n";
  let target = ws_path w.primary "stale.txt" in
  let plan =
    plan_exn (Edit.rewrite ~path:target ~before:"expected\n" ~after:"x\n")
  in
  match Wio.Edit.apply w.io plan with
  | Ok _ -> fail "a stale expectation must not apply"
  | Error err ->
      is_true ~msg:"the failure stops in preflight, before any mutation"
        (Edit.Apply_error.Phase.equal
           (Edit.Apply_error.phase err)
           Edit.Apply_error.Phase.Preflight);
      is_true ~msg:"no entry was applied" (Edit.Apply_error.applied err = []);
      (match Edit.Apply_error.error err with
      | Edit.Error.Conflict { path; expected; actual } ->
          equal path_value ~msg:"the conflict names the target" target path;
          is_true ~msg:"the conflict carries the planned before state"
            (Edit.State.equal expected (Edit.State.Text "expected\n"));
          is_true ~msg:"the conflict carries the observed bytes"
            (Edit.Observed.equal actual (Edit.Observed.Text "actual\n"))
      | e -> failf "wrong error: %a" Edit.Error.pp e);
      equal string ~msg:"the target is untouched" "actual\n" (read_file file)

let edit_binds_to_the_most_specific_root_first () =
  with_capability "edit-nested" ~aux:[ "ws/sub" ] @@ fun w ->
  let planned = ws_path w.primary "sub/blocked.txt" in
  let plan = plan_exn (Edit.create ~path:planned ~contents:"nope\n") in
  match Wio.Edit.apply w.io plan with
  | Ok _ -> fail "a target beneath a nested read-only root must refuse"
  | Error err ->
      (match Edit.Apply_error.error err with
      | Edit.Error.Read_only_path reported ->
          equal path_value
            ~msg:
              "the nested root binds before writability and the refusal names \
               the planned path"
            planned reported
      | e -> failf "wrong error: %a" Edit.Error.pp e);
      is_false ~msg:"nothing was written beneath the nested root"
        (Sys.file_exists (Filename.concat w.ws_dir "sub/blocked.txt"))

let edit_refuses_protected_metadata () =
  with_capability "edit-protected" @@ fun w ->
  let refuse relpath name =
    let planned = ws_path w.primary relpath in
    let plan = plan_exn (Edit.create ~path:planned ~contents:"owned\n") in
    match Wio.Edit.apply w.io plan with
    | Ok _ -> failf "%s: a protected path must refuse" relpath
    | Error err -> (
        match Edit.Apply_error.error err with
        | Edit.Error.Protected_path (reported, meta) ->
            equal path_value
              ~msg:(relpath ^ ": the refusal names the planned path")
              planned reported;
            equal string
              ~msg:(relpath ^ ": the refusal names the protected component")
              name meta;
            is_false
              ~msg:(relpath ^ ": nothing was committed")
              (Sys.file_exists (Filename.concat w.ws_dir relpath))
        | e -> failf "%s: wrong error: %a" relpath Edit.Error.pp e)
  in
  refuse ".git/hooks/pre-commit" ".git";
  refuse ".mentat/grant.json" ".mentat"

let edit_with_a_foreign_root_key_is_a_workspace_error () =
  with_capability "edit-ghost" @@ fun w ->
  let ghost = Workspace.Root.Key.of_string_exn "ghost" in
  let planned = Workspace.Path.make ~root_key:ghost (rel "x.txt") in
  let plan = plan_exn (Edit.create ~path:planned ~contents:"x\n") in
  match Wio.Edit.apply w.io plan with
  | Ok _ -> fail "a foreign root key must not apply"
  | Error err -> (
      match Edit.Apply_error.error err with
      | Edit.Error.Workspace
          (Some reported, Mentat_workspace.Resolve_error.Unknown_root key) ->
          equal path_value ~msg:"the error names the planned path" planned
            reported;
          equal key_value ~msg:"the error carries the foreign key" ghost key
      | e -> failf "wrong error: %a" Edit.Error.pp e)

(* The boundary enforces its own sealed posture on every route: a read-only
   resolution refuses native writes at [Edit.apply] itself, not merely
   through engine tool-gating. *)
let read_only_posture_refuses_native_edits () =
  with_capability "edit-readonly" ~mode:Mode.Read_only @@ fun w ->
  let planned = ws_path w.primary "blocked.txt" in
  let plan = plan_exn (Edit.create ~path:planned ~contents:"nope\n") in
  match Wio.Edit.apply w.io plan with
  | Ok _ -> fail "a read-only capability must refuse native writes"
  | Error err ->
      is_true ~msg:"the refusal stops in preflight, before any mutation"
        (Edit.Apply_error.Phase.equal
           (Edit.Apply_error.phase err)
           Edit.Apply_error.Phase.Preflight);
      (match Edit.Apply_error.error err with
      | Edit.Error.Read_only_path reported ->
          equal path_value ~msg:"the refusal names the planned path" planned
            reported
      | e -> failf "wrong error: %a" Edit.Error.pp e);
      is_false ~msg:"nothing was written"
        (Sys.file_exists (Filename.concat w.ws_dir "blocked.txt"))

(* The protected-meta and read-only refusals check the lexical path; the
   write path itself must therefore refuse to follow symlinks, or an in-root
   [alias -> .git] would launder a native write past both (the command
   sandbox protects [.git] contents but cannot stop link creation). *)
let native_writes_refuse_symlink_laundering () =
  with_capability "edit-nofollow" @@ fun w ->
  Unix.mkdir (Filename.concat w.ws_dir ".git") 0o755;
  Unix.symlink ".git" (Filename.concat w.ws_dir "alias");
  let laundered = ws_path w.primary "alias/config" in
  (match
     Wio.Edit.apply w.io
       (plan_exn (Edit.create ~path:laundered ~contents:"[core]\n"))
   with
  | Ok _ -> fail "a symlink-laundered protected write must refuse"
  | Error err -> (
      is_true ~msg:"the refusal stops in preflight, before any mutation"
        (Edit.Apply_error.Phase.equal
           (Edit.Apply_error.phase err)
           Edit.Apply_error.Phase.Preflight);
      match Edit.Apply_error.error err with
      | Edit.Error.Invalid_target
          { path = reported; reason = Edit.Error.Target_error.Symlink } ->
          equal path_value ~msg:"the refusal names the offending component"
            (ws_path w.primary "alias")
            reported
      | e -> failf "wrong error: %a" Edit.Error.pp e));
  is_false ~msg:"nothing landed in the protected directory"
    (Sys.file_exists (Filename.concat w.ws_dir ".git/config"));
  (* A final-component symlink is un-editable, never followed: the write-side
     read observes [Other], so the plan's text precondition cannot hold. *)
  write_file (Filename.concat w.ws_dir "real.txt") "real\n";
  Unix.symlink "real.txt" (Filename.concat w.ws_dir "link.txt");
  (match
     Wio.Edit.apply w.io
       (plan_exn
          (Edit.rewrite
             ~path:(ws_path w.primary "link.txt")
             ~before:"real\n" ~after:"changed\n"))
   with
  | Ok _ -> fail "a rewrite through a final symlink must refuse"
  | Error _ -> ());
  equal string ~msg:"the symlink's referent is untouched" "real\n"
    (read_file (Filename.concat w.ws_dir "real.txt"))

let native_writes_name_non_directory_ancestors () =
  with_capability "edit-nondirectory" @@ fun w ->
  write_file (Filename.concat w.ws_dir "parent-file") "not a directory\n";
  let target = ws_path w.primary "parent-file/child.txt" in
  match
    Wio.Edit.apply w.io
      (plan_exn (Edit.create ~path:target ~contents:"unreachable\n"))
  with
  | Ok _ -> fail "a native write through a file ancestor must refuse"
  | Error err -> (
      match Edit.Apply_error.error err with
      | Edit.Error.Invalid_target
          { path = reported; reason = Edit.Error.Target_error.Not_a_directory }
        ->
          equal path_value ~msg:"the refusal names the offending component"
            (ws_path w.primary "parent-file")
            reported
      | e -> failf "wrong error: %a" Edit.Error.pp e)

(* Workspace port types: the claim scope (the notice datum is pure data and
   is tested with its owner, [mentat_workspace]). *)

let apply_exn w plan =
  match Wio.Edit.apply w.io (plan_exn plan) with
  | Ok result -> result
  | Error e -> failf "apply failed: %a" Edit.Apply_error.pp e

let claim_scope_yields_edits_and_observations_in_order () =
  with_capability "claim-scope" @@ fun w ->
  let target = ws_path w.primary "claimed.txt" in
  let scope = Wio.open_claim_scope w.io in
  let created = apply_exn w (Edit.create ~path:target ~contents:"one\n") in
  let rewritten =
    apply_exn w (Edit.rewrite ~path:target ~before:"one\n" ~after:"two\n")
  in
  let watched = ws_path w.primary "watched.txt" in
  Wio.Claim_scope.observe scope watched;
  let evidence = Wio.Claim_scope.close scope in
  (match evidence.Edit.Apply_evidence.applies with
  | [ Edit.Apply_evidence.Applied first; Edit.Apply_evidence.Applied second ] ->
      is_true
        ~msg:
          "the evidence carries the exact authoritative results, in \
           application order (and no failed attempts)"
        (first == created && second == rewritten)
  | applies ->
      failf "expected two recorded successful applies, got %d"
        (List.length applies));
  equal (list path_value)
    ~msg:"the observed paths are the intake, in intake order" [ watched ]
    evidence.Edit.Apply_evidence.observed

(* Observation covers what the native path could not: a path an apply already
   recorded is authoritative evidence, so a duplicate observation is dropped
   at close rather than demoting the transition to an unexplained window
   change. *)
let claim_scope_close_drops_natively_recorded_observations () =
  with_capability "claim-observe-native" @@ fun w ->
  let target = ws_path w.primary "claimed.txt" in
  let scope = Wio.open_claim_scope w.io in
  let (_ : Edit.Result.t) =
    apply_exn w (Edit.create ~path:target ~contents:"one\n")
  in
  let watched = ws_path w.primary "watched.txt" in
  Wio.Claim_scope.observe scope target;
  Wio.Claim_scope.observe scope watched;
  let evidence = Wio.Claim_scope.close scope in
  equal (list path_value)
    ~msg:"a natively recorded target is dropped from the observations"
    [ watched ] evidence.Edit.Apply_evidence.observed

(* A claim cancelled before it could close must not wedge the capability:
   opening the next window supersedes the abandoned one, which stops
   recording but still yields its own collection on its own close. *)
let a_new_claim_scope_supersedes_an_abandoned_one () =
  with_capability "claim-supersede" @@ fun w ->
  let abandoned = Wio.open_claim_scope w.io in
  let first =
    apply_exn w
      (Edit.create ~path:(ws_path w.primary "one.txt") ~contents:"1\n")
  in
  let current = Wio.open_claim_scope w.io in
  let second =
    apply_exn w
      (Edit.create ~path:(ws_path w.primary "two.txt") ~contents:"2\n")
  in
  raises (Invalid_argument "claim scope is closed") (fun () ->
      Wio.Claim_scope.observe abandoned (ws_path w.primary "late.txt"));
  let abandoned_evidence = Wio.Claim_scope.close abandoned in
  (match abandoned_evidence.Edit.Apply_evidence.applies with
  | [ Edit.Apply_evidence.Applied only ] ->
      is_true ~msg:"the superseded window kept what it recorded before"
        (only == first)
  | applies ->
      failf "expected one superseded apply, got %d" (List.length applies));
  raises (Invalid_argument "claim scope is closed") (fun () ->
      Wio.Claim_scope.close abandoned);
  let evidence = Wio.Claim_scope.close current in
  (match evidence.Edit.Apply_evidence.applies with
  | [ Edit.Apply_evidence.Applied only ] ->
      is_true ~msg:"the superseding window records only its own edits"
        (only == second)
  | applies -> failf "expected one current apply, got %d" (List.length applies));
  let reopened = Wio.open_claim_scope w.io in
  is_true ~msg:"a closed window no longer blocks a fresh open"
    ((Wio.Claim_scope.close reopened).Edit.Apply_evidence.applies = [])

let edits_outside_a_scope_are_not_attributed () =
  with_capability "claim-isolation" @@ fun w ->
  let create name contents =
    apply_exn w (Edit.create ~path:(ws_path w.primary name) ~contents)
  in
  let (_ : Edit.Result.t) = create "before.txt" "before\n" in
  let scope = Wio.open_claim_scope w.io in
  let inside = create "inside.txt" "inside\n" in
  let evidence = Wio.Claim_scope.close scope in
  let (_ : Edit.Result.t) = create "after.txt" "after\n" in
  (match evidence.Edit.Apply_evidence.applies with
  | [ Edit.Apply_evidence.Applied only ] ->
      is_true ~msg:"only the in-window edit is attributed" (only == inside)
  | applies ->
      failf "expected one attributed apply, got %d" (List.length applies));
  let failing = Wio.open_claim_scope w.io in
  (match
     Wio.Edit.apply w.io
       (plan_exn
          (Edit.rewrite
             ~path:(ws_path w.primary "inside.txt")
             ~before:"stale\n" ~after:"x\n"))
   with
  | Ok _ -> fail "a stale expectation must not apply"
  | Error _ -> ());
  let failing_evidence = Wio.Claim_scope.close failing in
  is_true
    ~msg:
      "a preflight refusal commits nothing and records no apply — successful \
       or attempted"
    (failing_evidence.Edit.Apply_evidence.applies = [])

(* A partially-failed plan's committed transitions are durable evidence: the
   window retains the confirmed prefix and marks the stopping commit target
   uncertain, exactly as [Mentat_edit.Apply_error] classifies them. *)
let failed_applies_leave_their_committed_evidence () =
  require_denying_mode_bits ();
  with_capability "claim-failed" @@ fun w ->
  let locked_dir = Filename.concat w.ws_dir "locked" in
  Unix.mkdir locked_dir 0o500;
  Fun.protect ~finally:(fun () -> Unix.chmod locked_dir 0o755) @@ fun () ->
  let committed = ws_path w.primary "one.txt" in
  let blocked = ws_path w.primary "locked/two.txt" in
  let plan =
    match
      Edit.concat
        [
          plan_exn (Edit.create ~path:committed ~contents:"one\n");
          plan_exn (Edit.create ~path:blocked ~contents:"two\n");
        ]
    with
    | Ok plan -> plan
    | Error e -> failf "concat failed: %a" Edit.Error.pp e
  in
  let scope = Wio.open_claim_scope w.io in
  (match Wio.Edit.apply w.io plan with
  | Ok _ -> fail "the unwritable second target must fail the apply"
  | Error err ->
      is_true ~msg:"the failure stops while committing the blocked target"
        (Edit.Apply_error.Phase.equal
           (Edit.Apply_error.phase err)
           (Edit.Apply_error.Phase.Commit { target = blocked })));
  let evidence = Wio.Claim_scope.close scope in
  match evidence.Edit.Apply_evidence.applies with
  | [ Edit.Apply_evidence.Attempted attempt ] ->
      (match attempt.Edit.Apply_evidence.Attempt.applied with
      | [ entry ] ->
          equal path_value
            ~msg:"the confirmed committed prefix survives the failure" committed
            (Edit.Result.Entry.target_path entry)
      | entries ->
          failf "expected one committed entry, got %d" (List.length entries));
      (match attempt.Edit.Apply_evidence.Attempt.uncertain with
      | Some target ->
          equal path_value ~msg:"the stopping commit target is uncertain"
            blocked target
      | None -> fail "the stopping commit target must be marked uncertain");
      equal string ~msg:"the committed bytes are on disk" "one\n"
        (read_file (Filename.concat w.ws_dir "one.txt"))
  | applies ->
      failf
        "expected exactly one failed attempt and no successful apply, got %d \
         applies"
        (List.length applies)

(* Success, then an effectful commit failure, then success, under one window:
   the applies list records all three in the order they occurred, so netting
   reads the true occurrence order across successes and failures alike. *)
let a_claim_scope_records_successes_and_failures_in_one_order () =
  require_denying_mode_bits ();
  with_capability "claim-interleave" @@ fun w ->
  let locked_dir = Filename.concat w.ws_dir "locked" in
  Unix.mkdir locked_dir 0o500;
  Fun.protect ~finally:(fun () -> Unix.chmod locked_dir 0o755) @@ fun () ->
  let scope = Wio.open_claim_scope w.io in
  let first =
    apply_exn w
      (Edit.create ~path:(ws_path w.primary "first.txt") ~contents:"1\n")
  in
  let committed = ws_path w.primary "second.txt" in
  let blocked = ws_path w.primary "locked/blocked.txt" in
  let failing_plan =
    match
      Edit.concat
        [
          plan_exn (Edit.create ~path:committed ~contents:"2\n");
          plan_exn (Edit.create ~path:blocked ~contents:"3\n");
        ]
    with
    | Ok plan -> plan
    | Error e -> failf "concat failed: %a" Edit.Error.pp e
  in
  (match Wio.Edit.apply w.io failing_plan with
  | Ok _ -> fail "the unwritable target must fail the apply"
  | Error _ -> ());
  let third =
    apply_exn w
      (Edit.create ~path:(ws_path w.primary "third.txt") ~contents:"4\n")
  in
  let evidence = Wio.Claim_scope.close scope in
  match evidence.Edit.Apply_evidence.applies with
  | [
   Edit.Apply_evidence.Applied a;
   Edit.Apply_evidence.Attempted attempt;
   Edit.Apply_evidence.Applied c;
  ] -> (
      is_true ~msg:"the first success is recorded first" (a == first);
      is_true ~msg:"the last success is recorded last" (c == third);
      (match attempt.Edit.Apply_evidence.Attempt.applied with
      | [ entry ] ->
          equal path_value
            ~msg:"the failure's committed prefix is its own confirmed target"
            committed
            (Edit.Result.Entry.target_path entry)
      | entries ->
          failf "expected one committed entry, got %d" (List.length entries));
      match attempt.Edit.Apply_evidence.Attempt.uncertain with
      | Some target ->
          equal path_value
            ~msg:"the failure's uncertain target is the blocked path" blocked
            target
      | None -> fail "the stopping commit target must be marked uncertain")
  | applies ->
      failf "expected [ success; attempt; success ], got %d applies"
        (List.length applies)

(* Command: supervision and the launch boundary (direct route — these
   mechanics are backend-independent and must hold on every host). *)

let with_direct ?env ?env_policy name fn =
  with_capability ?env ?env_policy name ~mode:Mode.Danger_full_access fn

let run_captures_both_streams () =
  with_direct "run-capture" @@ fun w ->
  let outcome = run_ok w.io (sh "printf out; printf err >&2") in
  equal status_value ~msg:"exit status" (`Exited 0) (exit_status outcome);
  equal string ~msg:"stdout is captured completely under All" "out"
    (stdout_str outcome);
  equal string ~msg:"stderr is captured completely under All" "err"
    (stderr_str outcome);
  is_true ~msg:"a fully-drained stream reads complete"
    (Command.Captured.is_complete outcome.Command.stdout
    && Command.Captured.is_complete outcome.Command.stderr)

let run_reports_exit_codes () =
  with_direct "run-exit" @@ fun w ->
  equal status_value ~msg:"success is Exited 0" (`Exited 0)
    (exit_status (run_ok w.io (sh "exit 0")));
  equal status_value ~msg:"a failing exit code is preserved" (`Exited 3)
    (exit_status (run_ok w.io (sh "exit 3")))

let run_binds_logical_cwds () =
  with_direct "run-cwd" @@ fun w ->
  Unix.mkdir (Filename.concat w.ws_dir "subdir") 0o755;
  equal string ~msg:"the default cwd is the workspace's fixed root"
    (w.ws_dir ^ "\n")
    (stdout_str (run_ok w.io [ "/bin/pwd" ]));
  equal string ~msg:"a logical cwd binds beneath the opened root"
    (Filename.concat w.ws_dir "subdir" ^ "\n")
    (stdout_str (run_ok w.io ~cwd:(ws_path w.primary "subdir") [ "/bin/pwd" ]))

let stdin_defaults_to_null_and_sources_feed () =
  with_direct "run-stdin" @@ fun w ->
  equal string ~msg:"omitted stdin is a null source, never the parent's" ""
    (stdout_str (run_ok w.io [ "/bin/cat" ]));
  equal string ~msg:"a caller source is fed to the child" "fed bytes"
    (stdout_str
       (run_ok w.io ~stdin:(Eio.Flow.string_source "fed bytes") [ "/bin/cat" ]))

(* A limit is a deterministic Output_limit termination that {e preserves} the
   captured bytes marked truncated (B6a, B6b) — never a silently short Ok. *)
let limit_terminates_the_child () =
  with_direct "run-limit" @@ fun w ->
  (match
     Command.run w.io ~capture:(Command.Limit 1000)
       ~timeout:Eio.Time.Timeout.none [ "/usr/bin/yes" ]
   with
  | Ok outcome -> (
      equal evidence_value ~msg:"output-limit retains the ordinary route"
        (Wio.evidence w.io) outcome.Command.sandbox_evidence;
      (match outcome.Command.termination with
      | Command.Output_limit { stream = Command.Stdout; limit } ->
          equal int ~msg:"the termination names the configured bound" 1000 limit
      | _ -> fail "an over-limit stream must terminate as Output_limit");
      match outcome.Command.stdout with
      | Command.Captured.Truncated { head; omitted = None; tail = "" } ->
          equal int ~msg:"the preserved bytes are exactly the limit" 1000
            (String.length head)
      | _ -> fail "a limited stream is Truncated with an unknown omission")
  | Error e -> failf "wrong error: %a" Command.Error.pp e);
  assert_leader_gone "yes"

let alphabet n = String.init n (fun i -> Char.chr (Char.code 'a' + (i mod 26)))

let elided ~head ~tail payload =
  let n = String.length payload in
  if n <= head + tail then payload
  else
    String.sub payload 0 head
    ^ Printf.sprintf "\n... %d bytes omitted ...\n" (n - head - tail)
    ^ String.sub payload (n - tail) tail

let head_tail_boundary_math () =
  with_direct "run-headtail" @@ fun w ->
  let capture = Command.Head_tail { head = 4; tail = 3 } in
  let stdout payload =
    stdout_str (run_ok w.io ~capture [ "/usr/bin/printf"; "%s"; payload ])
  in
  equal string ~msg:"exactly head+tail bytes pass through unmarked" "abcdefg"
    (stdout (alphabet 7));
  equal string
    ~msg:"one byte over elides exactly one byte with the exact marker"
    "abcd\n... 1 bytes omitted ...\nfgh"
    (stdout (alphabet 8))

(* The elision law over one capability. The fixed edge triples pin the
   truncation boundaries deterministically — no output, one-byte-over, both
   halves elided, only head, only tail — each spawning the child once. The
   expected string is computed independently of the library. *)
let head_tail_elision_law () =
  with_direct "run-headtail-law" @@ fun w ->
  let case (n, head, tail) =
    let payload = alphabet n in
    let outcome =
      run_ok w.io
        ~capture:(Command.Head_tail { head; tail })
        [ "/usr/bin/printf"; "%s"; payload ]
    in
    let label = Printf.sprintf "n=%d head=%d tail=%d" n head tail in
    equal string
      ~msg:(label ^ ": marker iff truncation, halves exact")
      (elided ~head ~tail payload)
      (stdout_str outcome);
    equal status_value
      ~msg:(label ^ ": head_tail never stops the child")
      (`Exited 0) (exit_status outcome)
  in
  List.iter case
    [ (0, 4, 3); (7, 4, 3); (8, 4, 3); (10, 0, 0); (5, 3, 0); (5, 0, 2) ]

let negative_capture_bounds_raise () =
  with_direct "run-negative" @@ fun w ->
  let none = Eio.Time.Timeout.none in
  raises (Invalid_argument "capture limit must be non-negative") (fun () ->
      Command.run w.io ~capture:(Command.Limit (-1)) ~timeout:none (sh "exit 0"));
  raises (Invalid_argument "capture head and tail must be non-negative")
    (fun () ->
      Command.run w.io
        ~capture:(Command.Head_tail { head = -1; tail = 0 })
        ~timeout:none (sh "exit 0"))

(* A timeout is now a termination that carries the partial capture and the
   measured duration, not an error that erases both. *)
let timeout_terminates_the_leader () =
  with_direct "run-timeout" @@ fun w ->
  let timeout =
    Eio.Time.Timeout.seconds (Eio.Stdenv.mono_clock w.stdenv) 0.15
  in
  (* [exec sleep] makes the leader itself hold stdout — no surviving
     descendant — so the partial output drains cleanly after the kill. *)
  (match
     Command.run w.io ~capture:Command.All ~timeout
       [ "/bin/sh"; "-c"; "printf partial; exec sleep 5" ]
   with
  | Ok outcome ->
      equal evidence_value ~msg:"timeout retains the ordinary route"
        (Wio.evidence w.io) outcome.Command.sandbox_evidence;
      (match outcome.Command.termination with
      | Command.Timed_out -> ()
      | _ -> fail "a sleeping child must time out");
      is_true
        ~msg:"the duration is the measured elapsed time, at least the budget"
        (Mtime.Span.to_float_ns outcome.Command.duration >= 0.149e9);
      equal string ~msg:"the partial output before the timeout is preserved"
        "partial" (stdout_str outcome)
  | Error e -> failf "wrong error: %a" Command.Error.pp e);
  assert_leader_gone "sleep"

let cooperative_stop_yields_stopped () =
  with_direct "run-cancel" @@ fun w ->
  (match
     Command.run w.io ~capture:Command.All ~timeout:Eio.Time.Timeout.none
       ~cancelled:(fun () -> true)
       [ "/bin/sleep"; "5" ]
   with
  | Ok outcome -> (
      equal evidence_value ~msg:"cooperative stop retains the ordinary route"
        (Wio.evidence w.io) outcome.Command.sandbox_evidence;
      match outcome.Command.termination with
      | Command.Stopped -> ()
      | _ -> fail "a cooperative stop must terminate as Stopped")
  | Error e -> failf "wrong error: %a" Command.Error.pp e);
  assert_leader_gone "sleep"

(* Parent-fiber cancellation is the signal distinct from the cooperative stop
   predicate: the mli documents that it propagates as cancellation after the
   same bounded leader-only cleanup and is {e never} translated into a
   termination. So a run whose parent fiber is cancelled mid-supervision must
   not reach any [outcome] — neither [Ok] nor [Error] — and the direct child is
   still killed and reaped before the run fiber unwinds. *)
let parent_cancellation_propagates_never_an_outcome () =
  with_direct "run-parent-cancel" @@ fun w ->
  let mono = Eio.Stdenv.mono_clock w.stdenv in
  let settled = ref false in
  (* [Fiber.first] runs both fibers and, when the second returns, cancels the
     first and waits for it to unwind. The second sleeps just long enough for
     the child to have spawned, so the cancellation lands mid-run. *)
  Eio.Fiber.first
    (fun () ->
      match
        Command.run w.io ~capture:Command.All ~timeout:Eio.Time.Timeout.none
          [ "/bin/sleep"; "5" ]
      with
      | Ok _ | Error _ -> settled := true)
    (fun () -> Eio.Time.Mono.sleep mono 0.1);
  is_false
    ~msg:"parent cancellation propagates as cancellation, never as an outcome"
    !settled;
  assert_leader_gone "sleep"

(* Leader-only cleanup, told honestly: a child that forks a grandchild which
   inherits stdout and holds it open, then exits on its own, cannot stall the
   return. The drain never reaches EOF while the descendant keeps a write end
   open, so after the bounded drain grace the run settles [Exited] with the
   still-open stream reported not complete — never silently short, and never
   blocked on the descendant. This pins the "descendants may survive" honesty
   without asserting anything about the grandchild's own fate. *)
let a_surviving_descendant_marks_the_stream_not_complete () =
  with_direct "run-descendant" @@ fun w ->
  let outcome =
    run_ok w.io [ "/bin/sh"; "-c"; "printf partial; sleep 2 & exit 0" ]
  in
  (match outcome.Command.termination with
  | Command.Exited (`Exited 0) -> ()
  | _ -> fail "the leader exited on its own; the outcome must be Exited 0");
  is_true
    ~msg:"the run returns within the bounded drain grace, not after the sleep"
    (Mtime.Span.to_float_ns outcome.Command.duration < 1.5e9);
  match outcome.Command.stdout with
  | Command.Captured.Truncated { head = "partial"; omitted = None; tail = "" }
    ->
      is_false
        ~msg:"a descendant holding the pipe marks the stream not complete"
        (Command.Captured.is_complete outcome.Command.stdout)
  | _ ->
      fail
        "a descendant still holding stdout past the grace must report the \
         stream truncated with the bytes produced before the fork"

(* The linearization law from the other side: a child that writes far more than
   one pipe buffer then exits forces the drains to run concurrently with the
   child and to keep reading after the exit is observed. An [Exited] outcome may
   only be finalized once the drains have finished, so every produced byte is
   captured whole — never a short read from finalizing the exit ahead of the
   drain. (The tiny-output capture test cannot exercise this: it all fits in one
   pipe buffer and is read in a single pass.) *)
let drain_completes_before_the_exit_is_finalized () =
  with_direct "run-drain-complete" @@ fun w ->
  let n = 256 * 1024 in
  let outcome = run_ok w.io [ "/usr/bin/printf"; "%*s"; string_of_int n; "" ] in
  equal status_value ~msg:"the child exits cleanly" (`Exited 0)
    (exit_status outcome);
  is_true ~msg:"the fully-drained stream reads complete"
    (Command.Captured.is_complete outcome.Command.stdout);
  equal int ~msg:"every byte produced before the exit is captured, none lost" n
    (String.length (stdout_str outcome))

(* B6a: the drain observes any pending excess before a concurrent exit is
   finalized. Exactly-limit bytes then exit is a clean, complete Exited; one
   byte past the limit then exit is deterministically Output_limit, never a
   silently short Exited — the child has exited, yet the buffered excess still
   wins the linearization. *)
let exit_and_limit_linearize_deterministically () =
  with_direct "run-limit-race" @@ fun w ->
  let run_bytes n =
    (* [printf %*s N ""] writes exactly N spaces then exits at once. *)
    Command.run w.io ~capture:(Command.Limit 1000)
      ~timeout:Eio.Time.Timeout.none
      [ "/usr/bin/printf"; "%*s"; string_of_int n; "" ]
  in
  (match run_bytes 1000 with
  | Ok outcome ->
      equal evidence_value ~msg:"exit retains the ordinary route"
        (Wio.evidence w.io) outcome.Command.sandbox_evidence;
      (match outcome.Command.termination with
      | Command.Exited (`Exited 0) -> ()
      | _ -> fail "exactly-limit bytes then exit is a clean Exited");
      is_true ~msg:"exactly-limit output reads complete"
        (Command.Captured.is_complete outcome.Command.stdout);
      equal int ~msg:"all limit bytes are present" 1000
        (String.length (stdout_str outcome))
  | Error e -> failf "exactly-limit run failed: %a" Command.Error.pp e);
  match run_bytes 1001 with
  | Ok outcome -> (
      equal evidence_value ~msg:"output limit retains the ordinary route"
        (Wio.evidence w.io) outcome.Command.sandbox_evidence;
      match outcome.Command.termination with
      | Command.Output_limit { stream = Command.Stdout; limit = 1000 } -> ()
      | _ ->
          fail
            "over-limit bytes then exit must be Output_limit, never a silently \
             short Exited")
  | Error e -> failf "over-limit run failed: %a" Command.Error.pp e

(* B6d: a child that closes its own stdin is EPIPE, tolerated — the feed ends
   and the run completes as the child's own exit, not a supervision failure,
   even while a large source is still being fed. *)
let stdin_epipe_is_tolerated () =
  with_direct "run-epipe" @@ fun w ->
  let source = Eio.Flow.string_source (String.make 262144 'x') in
  match
    Command.run w.io ~capture:Command.All ~timeout:Eio.Time.Timeout.none
      ~stdin:source
      [ "/bin/sh"; "-c"; "exit 0" ]
  with
  | Ok outcome -> (
      equal evidence_value ~msg:"stdin-close exit retains the ordinary route"
        (Wio.evidence w.io) outcome.Command.sandbox_evidence;
      match outcome.Command.termination with
      | Command.Exited (`Exited 0) -> ()
      | _ -> fail "a child closing stdin (EPIPE) is tolerated, not a failure")
  | Error e -> failf "epipe run failed: %a" Command.Error.pp e

(* A source that a custom flow makes fail on read raises [Eio.Io], which the
   feeder does not swallow: it is a supervision failure distinct from the
   child's clean stdin close. *)
let failing_source () : Eio.Flow.source_ty Eio.Std.r =
  let module M = struct
    type t = unit

    let read_methods = []

    let single_read () _buffer =
      raise
        (Eio.Exn.create
           (Eio.Exn.X
              (Eio_unix.Unix_error (Unix.EIO, "single_read", "failing-source"))))
  end in
  Eio.Resource.T ((), Eio.Flow.Pi.source (module M))

let stdin_read_failure_is_a_supervision_failure () =
  with_direct "run-feed-fail" @@ fun w ->
  match
    Command.run w.io ~capture:Command.All ~timeout:Eio.Time.Timeout.none
      ~stdin:(failing_source ()) [ "/bin/cat" ]
  with
  | Ok outcome -> (
      equal evidence_value ~msg:"supervision failure retains the ordinary route"
        (Wio.evidence w.io) outcome.Command.sandbox_evidence;
      match outcome.Command.termination with
      | Command.Supervision_failed _ -> ()
      | _ -> fail "a source read failure must be a Supervision_failed")
  | Error e -> failf "feed-failure run failed: %a" Command.Error.pp e

(* A non-executable file earlier on the private PATH must not shadow a
   real executable later on it — the boundary resolves against the executable
   bit, not bare existence. *)
let executable_resolution_checks_the_exec_bit () =
  in_dirs "exec-bit" @@ fun ~stdenv ~base ~ws_dir ~out_dir:_ ~tmp_base ->
  let dir1 = Filename.concat base "bin1"
  and dir2 = Filename.concat base "bin2" in
  Unix.mkdir dir1 0o755;
  Unix.mkdir dir2 0o755;
  let shadow = Filename.concat dir1 "mentat-tool" in
  write_file shadow "not executable\n";
  Unix.chmod shadow 0o644;
  let real = Filename.concat dir2 "mentat-tool" in
  write_file real "#!/bin/sh\nprintf real\n";
  Unix.chmod real 0o755;
  let primary = Workspace.Root.of_dir (abs ws_dir) in
  let logical = Workspace.make ~primary ~read_only:[] () |> Result.get_ok in
  Eio.Switch.run @@ fun sw ->
  let io =
    with_env [ ("TMPDIR", Some tmp_base); ("PATH", Some (dir1 ^ ":" ^ dir2)) ]
    @@ fun () ->
    let environment = Wio.process_environment () in
    match
      Wio.resolve ~sw ~stdenv ~logical ~environment
        ~mode:Mode.Danger_full_access ~read:Read.All ~readable_roots:[]
        ~writable_roots:[] ~mentat_dirs:[]
        ~network:Sandbox.Policy.Network.Restricted ()
    with
    | Ok io -> io
    | Error e -> failf "resolve failed: %a" Resolve_error.pp e
  in
  equal string
    ~msg:"the executable tool is chosen over the non-executable shadow" "real"
    (stdout_str (run_ok io [ "mentat-tool" ]))

let argv_is_validated_at_the_boundary () =
  with_direct "run-argv" @@ fun w ->
  let sandbox_error argv label =
    match run_res w.io argv with
    | Error (Command.Error.Sandbox error) -> error
    | Ok _ -> failf "%s: the argv must be refused" label
    | Error e -> failf "%s: wrong error: %a" label Command.Error.pp e
  in
  equal sandbox_error_value ~msg:"an empty argv is Empty_program"
    Sandbox.Error.Empty_program
    (sandbox_error [] "empty argv");
  equal sandbox_error_value ~msg:"an empty program is Empty_program"
    Sandbox.Error.Empty_program
    (sandbox_error [ "" ] "empty program");
  equal sandbox_error_value ~msg:"a NUL in the program indexes token 0"
    (Sandbox.Error.Nul_in_argv { index = 0 })
    (sandbox_error [ "/bin/ec\000ho" ] "NUL in program");
  equal sandbox_error_value ~msg:"a NUL in an argument indexes its token"
    (Sandbox.Error.Nul_in_argv { index = 2 })
    (sandbox_error [ "/bin/echo"; "ok"; "a\000b" ] "NUL in argument")

let unknown_cwd_root_refuses_structurally () =
  with_direct "run-ghost-cwd" @@ fun w ->
  let ghost = Workspace.Root.Key.of_string_exn "ghost" in
  let cwd = Workspace.Path.make ~root_key:ghost Rel.root in
  match run_res w.io ~cwd (sh "exit 0") with
  | Error (Command.Error.Unknown_cwd_root key) ->
      equal key_value ~msg:"the refusal is returned, never raised, with the key"
        ghost key
  | Ok _ -> fail "a foreign cwd root must refuse"
  | Error e -> failf "wrong error: %a" Command.Error.pp e

let missing_program_is_a_spawn_error () =
  with_direct "run-missing" @@ fun w ->
  match run_res w.io [ "mentat-wio-definitely-missing" ] with
  | Error (Command.Error.Spawn (Eio.Process.Executable_not_found program)) ->
      equal string ~msg:"the spawn error names the program"
        "mentat-wio-definitely-missing" program
  | Ok _ -> fail "a missing program must not run"
  | Error e -> failf "wrong error: %a" Command.Error.pp e

let child_environment_is_private_on_every_route () =
  with_direct "run-env" ~env:[ ("MENTAT_WIO_PARENT_ONLY", Some "leak") ]
  @@ fun w ->
  let outcome =
    run_ok w.io
      (sh
         {|printf '%s\n%s\n%s' "$HOME" "$TMPDIR" "${MENTAT_WIO_PARENT_ONLY:-ABSENT}"|})
  in
  match String.split_on_char '\n' (stdout_str outcome) with
  | [ home; tmpdir; parent_only ] ->
      (* HOME is inherited: the resolver derives the toolchain's $HOME-relative
         roots from the same value the child reads, so a directory cannot be
         named to a tool without the grant that makes it usable. The temp family
         is still the private per-run scratch. *)
      equal string ~msg:"the child HOME is the launcher's own"
        (Option.value (Sys.getenv_opt "HOME") ~default:"")
        home;
      equal string ~msg:"the child TMPDIR is the launcher's own"
        (Unix.realpath w.tmp_base) (Unix.realpath tmpdir);
      equal string ~msg:"a parent-only ambient variable is stripped" "ABSENT"
        parent_only
  | _ -> fail "unexpected env probe output"

(* Dune folds its configuration — the shared-cache mode, the profile, the
   sandboxing mode, every [DUNE_CONFIG__*] override — into the digest of every
   rule, so a child configured differently from the launcher's shell would
   re-execute the user's whole build and have its own re-executed back. The
   dune and OCaml families reach the child verbatim; the handles dune assigns
   to its own actions, and [INSIDE_DUNE] with them, do not. *)
let child_environment_carries_dune_configuration () =
  with_direct "run-dune-env"
    ~env:
      [
        ("DUNE_CACHE", Some "enabled-except-user-rules");
        ("DUNE_CONFIG__BACKGROUND_DIGESTS", Some "disabled");
        ("OCAMLPARAM", Some "_,w=+a");
        ("DUNE_ACTION_TRACE_DIR", Some "/nope/trace");
        ("INSIDE_DUNE", Some "1");
      ]
  @@ fun w ->
  let outcome =
    run_ok w.io
      (sh
         {|printf '%s\n%s\n%s\n%s\n%s' "${DUNE_CACHE:-ABSENT}" "${DUNE_CONFIG__BACKGROUND_DIGESTS:-ABSENT}" "${OCAMLPARAM:-ABSENT}" "${DUNE_ACTION_TRACE_DIR:-ABSENT}" "${INSIDE_DUNE:-ABSENT}"|})
  in
  match String.split_on_char '\n' (stdout_str outcome) with
  | [ cache; override; ocamlparam; trace; inside ] ->
      equal string ~msg:"the shared-cache mode reaches the child"
        "enabled-except-user-rules" cache;
      equal string ~msg:"a DUNE_CONFIG__ override reaches the child" "disabled"
        override;
      equal string ~msg:"OCAMLPARAM reaches the child" "_,w=+a" ocamlparam;
      equal string ~msg:"dune's action-trace handle is stripped" "ABSENT" trace;
      equal string ~msg:"INSIDE_DUNE is stripped" "ABSENT" inside
  | _ -> fail "unexpected env probe output"

(* The curated build-tool set — C toolchain, pkg-config, proxies in both
   spellings, TLS trust, git identity — reaches the child verbatim: each is
   configuration a command must read exactly as the user's shell would, and
   stripping one fails silently (a dead proxy fetch, a differently built
   stub) rather than loudly. *)
let child_environment_carries_build_tool_configuration () =
  with_direct "run-tool-env"
    ~env:
      [
        ("PKG_CONFIG_PATH", Some "/opt/pc/lib/pkgconfig");
        ("https_proxy", Some "http://127.0.0.1:3128");
        ("GIT_AUTHOR_EMAIL", Some "g@example.org");
        ("CC", Some "cc -pipe");
      ]
  @@ fun w ->
  let outcome =
    run_ok w.io
      (sh
         {|printf '%s\n%s\n%s\n%s' "${PKG_CONFIG_PATH:-ABSENT}" "${https_proxy:-ABSENT}" "${GIT_AUTHOR_EMAIL:-ABSENT}" "${CC:-ABSENT}"|})
  in
  match String.split_on_char '\n' (stdout_str outcome) with
  | [ pc; proxy; email; cc ] ->
      equal string ~msg:"pkg-config's search path reaches the child"
        "/opt/pc/lib/pkgconfig" pc;
      equal string ~msg:"the lowercase proxy spelling reaches the child"
        "http://127.0.0.1:3128" proxy;
      equal string ~msg:"git identity reaches the child" "g@example.org" email;
      equal string ~msg:"the C compiler choice reaches the child" "cc -pipe" cc
  | _ -> fail "unexpected env probe output"

(* [sandbox.env_inherit=all]: the remaining ambient names reach the child —
   except the floor, which no setting subtracts from: secret-shaped names and
   agent handles stay behind even under the widest posture. *)
let child_environment_policy_inherit_all () =
  with_direct "run-env-all"
    ~env_policy:
      { Wio.Env_policy.inherit_all = true; exclude = []; include_only = [] }
    ~env:
      [
        ("ARBITRARY_SETTING", Some "zesty");
        ("MY_API_KEY", Some "hunter2");
        ("SSH_AUTH_SOCK", Some "/nope/agent");
      ]
  @@ fun w ->
  let outcome =
    run_ok w.io
      (sh
         {|printf '%s
%s
%s' "${ARBITRARY_SETTING:-ABSENT}" "${MY_API_KEY:-ABSENT}" "${SSH_AUTH_SOCK:-ABSENT}"|})
  in
  match String.split_on_char '
' (stdout_str outcome) with
  | [ arbitrary; key; agent ] ->
      equal string ~msg:"an arbitrary ambient variable reaches the child"
        "zesty" arbitrary;
      equal string ~msg:"a secret-shaped name stays behind the floor" "ABSENT"
        key;
      equal string ~msg:"the agent handle stays behind the floor" "ABSENT"
        agent
  | _ -> fail "unexpected env probe output"

(* [exclude] and [include_only] govern the inheritable sets; the structural
   core — HOME and the directories the resolver derives grants from — is not
   governable, so the pair cannot be configured into disagreement. *)
let child_environment_policy_exclude_and_include_only () =
  with_direct "run-env-gov"
    ~env_policy:
      {
        Wio.Env_policy.inherit_all = false;
        exclude = [ "OCAMLPARAM" ];
        include_only = [ "DUNE_*"; "OCAML*" ];
      }
    ~env:
      [
        ("DUNE_CACHE", Some "enabled");
        ("OCAMLPARAM", Some "_,w=+a");
        ("GIT_AUTHOR_EMAIL", Some "g@example.org");
      ]
  @@ fun w ->
  let outcome =
    run_ok w.io
      (sh
         {|printf '%s
%s
%s
%s' "${DUNE_CACHE:-ABSENT}" "${OCAMLPARAM:-ABSENT}" "${GIT_AUTHOR_EMAIL:-ABSENT}" "${HOME:-ABSENT}"|})
  in
  match String.split_on_char '
' (stdout_str outcome) with
  | [ cache; param; email; home ] ->
      equal string ~msg:"a name passing include_only reaches the child"
        "enabled" cache;
      equal string ~msg:"an excluded name stays behind even inside a family"
        "ABSENT" param;
      equal string
        ~msg:"a curated name outside include_only stays behind" "ABSENT" email;
      is_true ~msg:"the structural core is not governable"
        (not (String.equal home "ABSENT"))
  | _ -> fail "unexpected env probe output"

(* Root-derivation variables — GIT_CONFIG_GLOBAL, DUNE_CACHE_ROOT, the OCaml
   toolchain paths — are immune to the policy even under the hard mode: the
   resolver derives grants from them, so a child reading different values
   would resolve files the policy never admitted (confined git aborts on
   exactly that). A governable name under the same posture stays behind. *)
let child_environment_root_derivation_is_immune () =
  with_direct "run-env-roots"
    ~env_policy:
      {
        Wio.Env_policy.inherit_all = false;
        exclude = [];
        include_only = [ "NOTHING_MATCHES_*" ];
      }
    ~env:
      [
        ("GIT_CONFIG_GLOBAL", Some "/x/work.gitconfig");
        ("DUNE_CACHE_ROOT", Some "/x/dune-cache");
        ("OCAMLPATH", Some "/opt/site-lib");
        ("DUNE_CACHE", Some "enabled");
      ]
  @@ fun w ->
  let outcome =
    run_ok w.io
      (sh
         {|printf '%s
%s
%s
%s' "${GIT_CONFIG_GLOBAL:-ABSENT}" "${DUNE_CACHE_ROOT:-ABSENT}" "${OCAMLPATH:-ABSENT}" "${DUNE_CACHE:-ABSENT}"|})
  in
  match String.split_on_char '
' (stdout_str outcome) with
  | [ gitconfig; cache_root; ocamlpath; governable ] ->
      equal string ~msg:"the git-config override reaches the child"
        "/x/work.gitconfig" gitconfig;
      equal string ~msg:"the dune cache root reaches the child" "/x/dune-cache"
        cache_root;
      equal string ~msg:"the toolchain path reaches the child" "/opt/site-lib"
        ocamlpath;
      equal string ~msg:"a governable name under the same posture stays behind"
        "ABSENT" governable
  | _ -> fail "unexpected env probe output"

(* Command.Session: the supervised background primitive behind background
   terminals (direct route — the ring, cursor, drain, and waiter mechanics are
   backend-independent). Long-lived children are driven to determinism through
   the primitive's own poll/read/signal seams and observable output markers —
   never a fixed wall-clock wait — so the suite stays fast and honest. *)

let mono_of w = Eio.Stdenv.mono_clock w.stdenv

let start_bg ?cwd w ~sw argv =
  match Command.start_session w.io ~sw ?cwd argv with
  | Ok session -> session
  | Error e -> failf "start_session failed: %a" Command.Error.pp e

(* Poll a session's [read] until [ready] holds of the latest chunk, ticking the
   drain and waiter fibers between reads. It synchronizes on observable output
   and status, not on elapsed time; the outer timeout is only a safety net so a
   genuine hang fails the test fast rather than blocking the suite. *)
let poll_read ?(from = Session.Cursor.zero) ~mono ~ready session =
  match
    Eio.Time.Timeout.run (Eio.Time.Timeout.seconds mono 10.0) (fun () ->
        let rec loop () =
          let chunk = Session.read session ~from in
          if ready chunk then Ok chunk
          else begin
            Eio.Time.Mono.sleep mono 0.001;
            loop ()
          end
        in
        loop ())
  with
  | Ok chunk -> chunk
  | Error `Timeout -> fail "poll_read timed out waiting for the session"

(* A read from [zero] returns everything still buffered; a read from a returned
   cursor returns only the bytes appended since it. A fixed-payload self-exit
   pins the contract deterministically: the whole payload, then nothing new and
   a stable cursor. *)
let session_reads_are_incremental_over_a_cursor () =
  with_direct "bg-incremental" @@ fun w ->
  let mono = mono_of w in
  Eio.Switch.run @@ fun sw ->
  let session = start_bg w ~sw [ "/bin/sh"; "-c"; "printf abcdefghij" ] in
  let first =
    poll_read ~mono session ~ready:(fun c ->
        String.equal c.Session.stdout "abcdefghij")
  in
  is_true ~msg:"the first read advanced past the start cursor"
    (not (Session.Cursor.equal first.Session.next Session.Cursor.zero));
  equal int ~msg:"a read from zero drops nothing" 0 first.Session.dropped;
  let second = Session.read session ~from:first.Session.next in
  equal string ~msg:"the second read returns only new bytes — here, none" ""
    second.Session.stdout;
  is_true ~msg:"with no new output the cursor is stable"
    (Session.Cursor.equal second.Session.next first.Session.next);
  equal int ~msg:"and reports no drop" 0 second.Session.dropped

(* Live reads over a running flood: each read from the previous cursor yields
   fresh output and the cursor keeps advancing, never re-returning consumed
   bytes. *)
let session_cursor_advances_across_live_reads () =
  with_direct "bg-advance" @@ fun w ->
  let mono = mono_of w in
  let all_yes s = String.for_all (fun ch -> ch = 'y' || ch = '\n') s in
  Eio.Switch.run @@ fun sw ->
  let session = start_bg w ~sw [ "/usr/bin/yes" ] in
  let first =
    poll_read ~mono session ~ready:(fun c ->
        String.length c.Session.stdout >= 100)
  in
  is_true ~msg:"the first live read carries fresh yes output and left zero"
    (all_yes first.Session.stdout
    && not (Session.Cursor.equal first.Session.next Session.Cursor.zero));
  let second =
    poll_read ~from:first.Session.next ~mono session ~ready:(fun c ->
        String.length c.Session.stdout >= 100)
  in
  is_true ~msg:"the second read carries only output past the first cursor"
    (all_yes second.Session.stdout && String.length second.Session.stdout >= 100);
  is_true ~msg:"the cursor advanced again"
    (not (Session.Cursor.equal second.Session.next first.Session.next));
  equal int ~msg:"live incremental reads within the window drop nothing" 0
    second.Session.dropped;
  Session.signal session;
  assert_leader_gone "yes"

(* The ring retains at most [max_buffer_bytes] per stream. A flood past that
   rolls the oldest bytes off the head, and a cursor below the retained window
   (here, [zero]) reads from the window start with the gap counted — never a
   silent short read. *)
let session_head_drop_counts_the_gap () =
  with_direct "bg-headdrop" @@ fun w ->
  let mono = mono_of w in
  let cap = Session.max_buffer_bytes in
  Eio.Switch.run @@ fun sw ->
  let session = start_bg w ~sw [ "/usr/bin/yes" ] in
  (* [dropped] is exposed and unbounded; [stdout] length saturates at [cap]. *)
  let (_ : Session.chunk) =
    poll_read ~mono session ~ready:(fun c ->
        String.length c.Session.stdout + c.Session.dropped >= 2 * cap)
  in
  Session.signal session;
  let final = Session.read session ~from:Session.Cursor.zero in
  let total = String.length final.Session.stdout + final.Session.dropped in
  is_true ~msg:"the flood emitted well past one buffer" (total >= 2 * cap);
  equal int ~msg:"the ring retains exactly one buffer of the newest bytes" cap
    (String.length final.Session.stdout);
  is_true ~msg:"the rolled-off head is counted, not dropped silently"
    (final.Session.dropped > 0);
  let after = Session.read session ~from:final.Session.next in
  equal string ~msg:"a read at the head returns no further bytes" ""
    after.Session.stdout;
  equal int ~msg:"and reports no new drop" 0 after.Session.dropped;
  assert_leader_gone "yes"

(* The two streams are bounded separately: a stderr flood rolls its own ring
   and never evicts a quiet stdout. *)
let session_streams_are_independent () =
  with_direct "bg-streams" @@ fun w ->
  let mono = mono_of w in
  let cap = Session.max_buffer_bytes in
  Eio.Switch.run @@ fun sw ->
  (* [printf OUT] lands three bytes on stdout, then [exec yes 1>&2] floods
     stderr and closes stdout, so stdout reaches EOF holding exactly [OUT]. The
     quiet stdout produces no drop, so a read's [dropped] is all stderr's. *)
  let session =
    start_bg w ~sw [ "/bin/sh"; "-c"; "printf OUT; exec yes 1>&2" ]
  in
  let (_ : Session.chunk) =
    poll_read ~mono session ~ready:(fun c ->
        String.length c.Session.stderr + c.Session.dropped >= 2 * cap)
  in
  Session.signal session;
  let final = Session.read session ~from:Session.Cursor.zero in
  equal string ~msg:"the quiet stdout is intact despite the stderr flood" "OUT"
    final.Session.stdout;
  equal int ~msg:"stderr rolled to exactly one buffer" cap
    (String.length final.Session.stderr);
  is_true ~msg:"the stderr flood rolled bytes off its own head"
    (final.Session.dropped > 0);
  assert_leader_gone "yes"

(* Output is captured raw: the reader receives the exact bytes the child wrote,
   ANSI escapes and invalid UTF-8 included, and the byte accounting is on those
   raw bytes. Repair and stripping are the reader's concern, never the
   buffer's. *)
let session_captures_raw_bytes () =
  with_direct "bg-raw" @@ fun w ->
  let mono = mono_of w in
  let expected = "\027[31mred\255" in
  Eio.Switch.run @@ fun sw ->
  let session =
    start_bg w ~sw [ "/bin/sh"; "-c"; {|printf '\033[31mred\377'|} ]
  in
  let chunk =
    poll_read ~mono session ~ready:(fun c ->
        String.equal c.Session.stdout expected)
  in
  equal string ~msg:"the raw bytes pass through byte-identical" expected
    chunk.Session.stdout;
  equal int ~msg:"nothing was dropped" 0 chunk.Session.dropped

(* [env_override] rebinds a name for one session's child alone: the override
   session reads the injected value, and a plain session spawned from the same
   capability still sees the private environment untouched. *)
let session_env_override_is_per_session () =
  with_direct "bg-env-override" @@ fun w ->
  let mono = mono_of w in
  let probe = [ "/bin/sh"; "-c"; {|printf '%s' "${XDG_RUNTIME_DIR:-ABSENT}"|} ] in
  Eio.Switch.run @@ fun sw ->
  let overridden =
    match
      Command.start_session w.io ~sw
        ~env_override:[ ("XDG_RUNTIME_DIR", "/work/.mentat/run/session") ]
        probe
    with
    | Ok session -> session
    | Error e -> failf "start_session failed: %a" Command.Error.pp e
  in
  let chunk =
    poll_read ~mono overridden ~ready:(fun c ->
        match c.Session.status with Session.Running -> false | _ -> true)
  in
  equal string ~msg:"the override reaches the overridden session's child"
    "/work/.mentat/run/session" chunk.Session.stdout;
  let plain = start_bg w ~sw probe in
  let chunk =
    poll_read ~mono plain ~ready:(fun c ->
        match c.Session.status with Session.Running -> false | _ -> true)
  in
  equal string ~msg:"a plain session still sees the private environment"
    "ABSENT" chunk.Session.stdout

(* A child that exits on its own flips [Running -> Exited status] through the
   waiter fiber, carrying the true exit code; the final output is readable. *)
let session_self_exit_flips_to_exited () =
  with_direct "bg-exit" @@ fun w ->
  let mono = Eio.Stdenv.mono_clock w.stdenv in
  Eio.Switch.run @@ fun sw ->
  let session = start_bg w ~sw [ "/bin/sh"; "-c"; "printf bye; exit 7" ] in
  let chunk =
    poll_read ~mono session ~ready:(fun c ->
        String.equal c.Session.stdout "bye"
        && match c.Session.status with Session.Running -> false | _ -> true)
  in
  (match chunk.Session.status with
  | Session.Exited status ->
      equal status_value ~msg:"the waiter records the true exit code"
        (`Exited 7) status
  | _ -> fail "a self-exit must settle Exited, never Terminated");
  equal status_value ~msg:"status agrees with the last read" (`Exited 7)
    (match Session.status session with
    | Session.Exited status -> status
    | _ -> fail "status must be Exited after a self-exit")

(* [signal] is our kill: it flips [Running -> Terminated], reaps the child,
   and is idempotent — a second signal is a no-op that keeps the recorded
   status. *)
let session_signal_terminates_and_is_idempotent () =
  with_direct "bg-signal" @@ fun w ->
  Eio.Switch.run @@ fun sw ->
  let session = start_bg w ~sw [ "/bin/sleep"; "30" ] in
  is_true ~msg:"a fresh session is running"
    (match Session.status session with Session.Running -> true | _ -> false);
  Session.signal session;
  is_true ~msg:"our signal settles Terminated, not Exited"
    (match Session.status session with
    | Session.Terminated -> true
    | _ -> false);
  assert_session_gone session;
  Session.signal session;
  is_true ~msg:"a second signal is a no-op that keeps the status"
    (match Session.status session with
    | Session.Terminated -> true
    | _ -> false)

(* A background command's workers stop with it: [signal] reaches the process
   group the session leads, not the session's own process alone. The worker
   here exists only to prove that — it announces itself a second after being
   forked, on the stdout it inherited, so its output is a marker that can only
   appear if it outlived the kill. The read after the kill consumes the settled
   tail; anything appended past that is the worker still running. *)
let session_signal_reaches_the_forked_workers () =
  with_direct "bg-group" @@ fun w ->
  let mono = mono_of w in
  Eio.Switch.run @@ fun sw ->
  let session =
    start_bg w ~sw
      [ "/bin/sh"; "-c"; "(sleep 1; printf late) & printf ready; sleep 30" ]
  in
  let ready =
    poll_read ~mono session ~ready:(fun c ->
        String.equal c.Session.stdout "ready")
  in
  Session.signal session;
  let settled = Session.read session ~from:ready.Session.next in
  Eio.Time.Mono.sleep mono 1.5;
  let after = Session.read session ~from:settled.Session.next in
  equal string
    ~msg:"the worker the session forked is signalled with it and never speaks"
    ""
    (settled.Session.stdout ^ after.Session.stdout)

(* A SIGTERM-ignoring child is escalated to SIGKILL after the bounded grace, so
   [signal] still terminates and reaps it — teardown stays bounded. *)
let session_signal_escalates_past_sigterm () =
  with_direct "bg-escalate" @@ fun w ->
  let mono = mono_of w in
  Eio.Switch.run @@ fun sw ->
  (* The shell ignores SIGTERM, announces readiness, then blocks; only SIGKILL
     can stop it. Its [sleep] child inherits the ignored disposition across the
     exec, so the group's SIGTERM passes over both and the escalation is what
     ends them. *)
  let session =
    start_bg w ~sw [ "/bin/sh"; "-c"; "trap '' TERM; printf ready; sleep 5" ]
  in
  let (_ : Session.chunk) =
    poll_read ~mono session ~ready:(fun c ->
        String.equal c.Session.stdout "ready")
  in
  let start = Eio.Time.Mono.now mono in
  Session.signal session;
  let elapsed =
    Mtime.Span.to_float_ns (Mtime.span start (Eio.Time.Mono.now mono))
  in
  is_true ~msg:"the SIGTERM-ignoring child is escalated and reaped, bounded"
    (elapsed < 3.0e9);
  is_true ~msg:"the escalated kill still settles Terminated"
    (match Session.status session with
    | Session.Terminated -> true
    | _ -> false);
  assert_session_gone session

(* The session's lifetime is its switch: releasing it kills and reaps every
   registered child, promptly, without an explicit signal. Release is Eio's own
   teardown and stays on the child; only {!Session.signal} widens to the
   group. *)
let sessions_die_on_switch_release () =
  with_direct "bg-release" @@ fun w ->
  let mono = Eio.Stdenv.mono_clock w.stdenv in
  let start = Eio.Time.Mono.now mono in
  let pids =
    Eio.Switch.run @@ fun sw ->
    let a = start_bg w ~sw [ "/bin/sleep"; "30" ] in
    let b = start_bg w ~sw [ "/bin/sleep"; "30" ] in
    [ Session.pid a; Session.pid b ]
  in
  let elapsed =
    Mtime.Span.to_float_ns (Mtime.span start (Eio.Time.Mono.now mono))
  in
  is_true ~msg:"switch release returns promptly, not after the sleeps"
    (elapsed < 3.0e9);
  List.iter
    (fun pid ->
      match Unix.kill pid 0 with
      | () -> failf "the child %d survived its owning switch" pid
      | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ())
    pids;
  assert_leader_gone "sleep"

(* Sandbox integration: the confined and escalated routes (skip without a
   real enforcing backend — Seatbelt here, Bubblewrap on Linux). *)

let confined_commands_are_enforced_by_the_backend () =
  with_capability "enforce" @@ fun w ->
  require_enforced w.io;
  let outside = Filename.concat w.out_dir "blocked.txt" in
  let inside = Filename.concat w.ws_dir "allowed.txt" in
  let write file = sh (Printf.sprintf {|printf x > "%s"|} file) in
  let refused = run_ok w.io (write outside) in
  is_false ~msg:"the OS refuses a write outside the writable roots"
    (exit_status refused = `Exited 0);
  is_false ~msg:"no file appears outside the sandbox" (Sys.file_exists outside);
  let allowed = run_ok w.io (write inside) in
  equal status_value ~msg:"a write inside the workspace root succeeds"
    (`Exited 0) (exit_status allowed);
  equal string ~msg:"the bytes landed inside the root" "x" (read_file inside)

let escalation_opens_the_profile_never_the_environment () =
  with_capability "escalate" @@ fun w ->
  require_enforced w.io;
  let outside = Filename.concat w.out_dir "escalated.txt" in
  (match
     run_escalated_res w.io (sh (Printf.sprintf {|printf y > "%s"|} outside))
   with
  | Ok outcome ->
      (* An escalation is a widening now, not a discard: the command still runs
         under a profile — everything open except the denied paths — so its
         evidence names the profile that ran rather than claiming nothing did. *)
      (match outcome.Command.sandbox_evidence with
      | Sandbox.Evidence.Enforced _ -> ()
      | _ -> fail "an escalated outcome reports the floor it ran under");
      equal status_value ~msg:"the approved escalation drops the profile"
        (`Exited 0) (exit_status outcome);
      equal string ~msg:"the escalated write landed" "y" (read_file outside)
  | Error e -> failf "escalated run failed: %a" Command.Error.pp e);
  let confined_env = run_ok w.io [ "/usr/bin/env" ] in
  (* Nothing is rewritten any more: the confined child sees the launcher's own
     temp directory, and the profile is what confines it. *)
  is_true ~msg:"the confined child TMPDIR is the launcher's own"
    (String.includes
       ~affix:("TMPDIR=" ^ w.tmp_base ^ "\n")
       (stdout_str confined_env));
  match run_escalated_res w.io [ "/usr/bin/env" ] with
  | Ok escalated ->
      (match escalated.Command.sandbox_evidence with
      | Sandbox.Evidence.Enforced _ -> ()
      | _ -> fail "every escalated outcome reports its route");
      equal string
        ~msg:"escalation receives the byte-identical private environment"
        (stdout_str confined_env) (stdout_str escalated)
  | Error e -> failf "escalated env probe failed: %a" Command.Error.pp e

(* The narrow widening, end to end: a path the posture refuses is granted for
   one command, the command writes it, and the sandbox is still in force
   everywhere else — including for the very next command, because nothing
   stored the grant. *)
let a_grant_widens_one_command_and_no_more () =
  with_capability "grant" @@ fun w ->
  require_enforced w.io;
  let outside = Filename.concat w.out_dir "granted.txt" in
  let write file = sh (Printf.sprintf {|printf g > "%s"|} file) in
  let refused = run_ok w.io (write outside) in
  is_false ~msg:"the path is outside the writable roots to begin with"
    (exit_status refused = `Exited 0);
  let grants = [ (abs w.out_dir, Sandbox.Policy.Access.Write) ] in
  (match
     Command.run_granted w.io ~capture:Command.All
       ~timeout:Eio.Time.Timeout.none ~grants (write outside)
   with
  | Ok outcome -> (
      equal status_value ~msg:"the granted write succeeds" (`Exited 0)
        (exit_status outcome);
      equal string ~msg:"the bytes landed" "g" (read_file outside);
      (* Unlike an escalation, a grant never left the sandbox. *)
      match outcome.Command.sandbox_evidence with
      | Sandbox.Evidence.Enforced _ -> ()
      | _ -> fail "a granted command is still an enforced one")
  | Error e -> failf "granted run failed: %a" Command.Error.pp e);
  Sys.remove outside;
  let after = run_ok w.io (write outside) in
  is_false ~msg:"the grant expired with the command it was made for"
    (exit_status after = `Exited 0)

(* A grant the posture would defeat is refused, not quietly dropped: the deny
   set outranks every grant, so admitting it would look like it worked. *)
let a_grant_of_a_denied_path_is_refused () =
  with_capability "grant-denied" @@ fun w ->
  require_enforced w.io;
  match Wio.policy w.io with
  | None -> skip ~reason:"no sealed policy to read a denied path from" ()
  | Some policy -> (
      match Sandbox.Policy.denied_paths policy with
      | [] -> skip ~reason:"this host derived no denied paths" ()
      | denied :: _ -> (
          match
            Command.run_granted w.io ~capture:Command.All
              ~timeout:Eio.Time.Timeout.none
              ~grants:[ (denied, Sandbox.Policy.Access.Write) ]
              (sh "exit 0")
          with
          | Error
              (Command.Error.Sandbox (Sandbox.Error.Grant_denied { path; _ }))
            ->
              equal abs_value ~msg:"the refusal names the path asked for" denied
                path
          | Ok _ -> fail "a grant of a denied path must be refused"
          | Error e -> failf "wrong error: %a" Command.Error.pp e))

(* A write grant is a mutation, so the posture that refuses an escalation
   refuses it too — the two are one promise, not two knobs. *)
let read_only_refuses_a_write_grant () =
  with_capability "grant-read-only" ~mode:Mode.Read_only @@ fun w ->
  require_enforced w.io;
  match
    Command.run_granted w.io ~capture:Command.All ~timeout:Eio.Time.Timeout.none
      ~grants:[ (abs w.out_dir, Sandbox.Policy.Access.Write) ]
      (sh (Printf.sprintf {|printf n > "%s/x.txt"|} w.out_dir))
  with
  | Ok outcome ->
      is_false ~msg:"a read-only route grants no write, however it is asked"
        (exit_status outcome = `Exited 0)
  | Error _ -> ()

(* A grant lowers to a writable root, and a writable root is obliged to be a
   directory — so a grant naming a file must be refused where the caller can act
   on it, not through the discharge, which would report that something changed
   after sealing when nothing did. *)
let a_grant_must_name_a_directory () =
  with_capability "grant-file" @@ fun w ->
  require_enforced w.io;
  let file = Filename.concat w.out_dir "not-a-dir.txt" in
  write_file file "x";
  match
    Command.run_granted w.io ~capture:Command.All ~timeout:Eio.Time.Timeout.none
      ~grants:[ (abs file, Sandbox.Policy.Access.Write) ]
      (sh "exit 0")
  with
  | Error (Command.Error.Sandbox (Sandbox.Error.Grant_not_a_directory { path }))
    ->
      equal abs_value ~msg:"the refusal names the path the caller spelled"
        (abs file) path
  | Ok _ -> fail "a grant naming a file must be refused"
  | Error e -> failf "wrong error: %a" Command.Error.pp e

let read_only_escalation_is_denied () =
  with_capability "escalate-denied" ~mode:Mode.Read_only @@ fun w ->
  match run_escalated_res w.io (sh "exit 0") with
  | Error (Command.Error.Sandbox Sandbox.Error.Escalation_denied) -> ()
  | Ok _ -> fail "a read-only capability must deny escalation"
  | Error e -> failf "wrong error: %a" Command.Error.pp e

let direct_mode_runs_unconfined () =
  with_direct "direct" @@ fun w ->
  (match Wio.evidence w.io with
  | Sandbox.Evidence.Not_requested -> ()
  | _ -> fail "danger-full-access seals the direct route");
  let outside = Filename.concat w.out_dir "direct.txt" in
  let outcome = run_ok w.io (sh (Printf.sprintf {|printf z > "%s"|} outside)) in
  equal status_value ~msg:"an unconfined write outside the roots succeeds"
    (`Exited 0) (exit_status outcome);
  equal string ~msg:"the bytes landed" "z" (read_file outside)

let stale_policy_refuses_before_launch () =
  with_capability "run-stale" ~writable:[ "extra" ] @@ fun w ->
  require_enforced w.io;
  let extra = Filename.concat w.base "extra" in
  Unix.rmdir extra;
  (match run_res w.io (sh "exit 0") with
  | Error (Command.Error.Sandbox error) ->
      equal sandbox_error_value ~msg:"the refusal names the exact stale path"
        (Sandbox.Error.Stale_policy { path = abs extra })
        error
  | Ok _ -> fail "a stale writable root must refuse the launch"
  | Error e -> failf "wrong error: %a" Command.Error.pp e);
  match Wio.check w.io ~requirement:Sandbox.Requirement.Off with
  | Error
      (Sandbox.Requirement.Rejection.Unenforceable
         (Sandbox.Error.Stale_policy { path })) ->
      equal abs_value ~msg:"the startup gate reports the same stale path"
        (abs extra) path
  | Ok () -> fail "the startup gate must fail on a stale root"
  | Error _ -> fail "wrong rejection class for a stale root"

let unavailable_backend_fails_closed () =
  with_capability "run-unavailable"
    ~env:[ ("_MENTAT_TEST_SANDBOX_UNAVAILABLE", Some "1") ]
  @@ fun w ->
  (match Wio.evidence w.io with
  | Sandbox.Evidence.Refused _ -> ()
  | _ -> fail "the seam must seal a refused confinement");
  ignore
    (require_ok ~msg:"requirement off admits a refused seal"
       (Wio.check w.io ~requirement:Sandbox.Requirement.Off));
  (match Wio.check w.io ~requirement:Sandbox.Requirement.Enforced with
  | Error
      (Sandbox.Requirement.Rejection.Unenforceable (Sandbox.Error.Unavailable _))
    ->
      ()
  | Ok () -> fail "the startup gate must reject an unavailable backend"
  | Error _ -> fail "wrong rejection class for an unavailable backend");
  match run_res w.io (sh "exit 0") with
  | Error (Command.Error.Sandbox (Sandbox.Error.Unavailable _)) -> ()
  | Ok _ -> fail "a refused confinement must never launch"
  | Error e -> failf "wrong error: %a" Command.Error.pp e

let startup_gate_admits_an_enforced_capability () =
  with_capability "check" @@ fun w ->
  require_enforced w.io;
  List.iter
    (fun requirement ->
      ignore
        (require_ok
           ~msg:"a fresh enforced capability passes every requirement level"
           (Wio.check w.io ~requirement)))
    Sandbox.Requirement.all

(* Suite. *)

let () =
  run "mentat.workspace_io"
    [
      (* Resolution *)
      test "escalation projects the sealed stance per mode"
        escalation_projects_the_sealed_stance;
      test "resolving twice agrees on the identity"
        resolving_twice_agrees_on_the_identity;
      test "resolve_path is bound to the capability workspace"
        resolve_path_uses_the_capability_workspace;
      test "describe_roots labels the scoped read roots"
        describe_roots_labels_scoped_reads;
      test "describe_roots carries the user toolchain directories"
        describe_roots_carries_user_toolchain_dirs;
      test "describe_roots follows DUNE_CACHE_ROOT the way dune does"
        describe_roots_follows_dune_cache_root;
      test "describe_roots admits git's global configuration"
        describe_roots_admits_git_config;
      test "a placeholder toolchain value is skipped, not fatal"
        toolchain_placeholder_is_skipped_not_fatal;
      test "resolve refuses a missing workspace root"
        resolve_refuses_a_missing_workspace_root;
      test "resolve refuses broad writable roots"
        resolve_refuses_broad_writable_roots;
      test "resolve refuses invalid configured roots"
        resolve_refuses_invalid_configured_roots;
      (* File *)
      test "load and stat observe inside the opened root"
        load_and_stat_inside_the_root;
      test "symlink escapes are refused per bound root"
        symlink_escapes_are_refused;
      test "missing and foreign targets are structured errors"
        missing_and_foreign_targets_are_structured;
      test "permission refusals keep their Io class"
        permission_refusals_keep_their_io_class;
      test "read_dir lists workspace paths in name order"
        read_dir_lists_workspace_paths_in_order;
      test "read_dir_entries carries each entry kind"
        read_dir_entries_carries_each_entry_kind;
      test "path binding never escapes the bound root (matrix)"
        binding_never_escapes_the_bound_root;
      test "File.load bounds large files with Too_large"
        file_load_bounds_large_files;
      test "the permission-denied classifier is pinned to the backend"
        permission_denied_classifier_is_backend_pinned;
      (* Edit *)
      test "edit creates files with parent directories"
        edit_creates_with_parent_directories;
      test "edit rewrites and deletes through the capability"
        edit_rewrites_and_deletes;
      test "a stale expectation stops in preflight"
        edit_stale_expectation_stops_in_preflight;
      test "edits bind to the most-specific root before writability"
        edit_binds_to_the_most_specific_root_first;
      test "edits refuse protected metadata" edit_refuses_protected_metadata;
      test "an edit with a foreign root key is a workspace error"
        edit_with_a_foreign_root_key_is_a_workspace_error;
      test "a read-only posture refuses native edits at the boundary"
        read_only_posture_refuses_native_edits;
      test "native writes refuse symlink laundering (no-follow)"
        native_writes_refuse_symlink_laundering;
      test "native writes name non-directory ancestors"
        native_writes_name_non_directory_ancestors;
      (* Workspace port types *)
      test "the claim scope yields edits and observations in order"
        claim_scope_yields_edits_and_observations_in_order;
      test "close drops natively recorded observations"
        claim_scope_close_drops_natively_recorded_observations;
      test "a new claim scope supersedes an abandoned one"
        a_new_claim_scope_supersedes_an_abandoned_one;
      test "edits outside an open scope are not attributed"
        edits_outside_a_scope_are_not_attributed;
      test "failed applies leave their committed evidence"
        failed_applies_leave_their_committed_evidence;
      test "a claim scope records successes and failures in one order"
        a_claim_scope_records_successes_and_failures_in_one_order;
      (* Command *)
      test "run captures both streams completely" run_captures_both_streams;
      test "run reports exit codes" run_reports_exit_codes;
      test "run binds logical cwds beneath opened roots" run_binds_logical_cwds;
      test "omitted stdin is null and caller sources feed"
        stdin_defaults_to_null_and_sources_feed;
      test "an exceeded limit terminates the child" limit_terminates_the_child;
      test "exit and limit linearize deterministically"
        exit_and_limit_linearize_deterministically;
      test "head_tail boundary math is exact" head_tail_boundary_math;
      test "head_tail elision law over generated sizes" head_tail_elision_law;
      test "negative capture bounds raise Invalid_argument"
        negative_capture_bounds_raise;
      test "a timeout terminates the leader and measures elapsed"
        timeout_terminates_the_leader;
      test "a cooperative stop yields Stopped" cooperative_stop_yields_stopped;
      test "parent-fiber cancellation propagates, never an outcome"
        parent_cancellation_propagates_never_an_outcome;
      test "a surviving descendant marks the stream not complete"
        a_surviving_descendant_marks_the_stream_not_complete;
      test "the drain completes before the exit is finalized"
        drain_completes_before_the_exit_is_finalized;
      test "stdin EPIPE (child closes stdin) is tolerated"
        stdin_epipe_is_tolerated;
      test "a stdin source read failure is a supervision failure"
        stdin_read_failure_is_a_supervision_failure;
      test ~tags:[ "slow" ]
        "executable resolution checks the exec bit, not existence"
        executable_resolution_checks_the_exec_bit;
      test "argv is validated at the launch boundary"
        argv_is_validated_at_the_boundary;
      test "an unknown cwd root refuses structurally"
        unknown_cwd_root_refuses_structurally;
      test "a missing program is a structured spawn error"
        missing_program_is_a_spawn_error;
      test "the child environment is private on every route"
        child_environment_is_private_on_every_route;
      test "the child environment carries the dune and OCaml configuration"
        child_environment_carries_dune_configuration;
      test "the child environment carries the curated build-tool set"
        child_environment_carries_build_tool_configuration;
      test "env_inherit=all inherits the rest, floor excepted"
        child_environment_policy_inherit_all;
      test "env exclude and include_only govern, the core stays"
        child_environment_policy_exclude_and_include_only;
      test "root-derivation variables are immune to the env policy"
        child_environment_root_derivation_is_immune;
      (* Session: the supervised background primitive *)
      test "session reads are incremental over a cursor"
        session_reads_are_incremental_over_a_cursor;
      test "the session cursor advances across live reads"
        session_cursor_advances_across_live_reads;
      test "session head-drop counts the rolled-off gap"
        session_head_drop_counts_the_gap;
      test "session stdout and stderr roll independently"
        session_streams_are_independent;
      test "session captures raw bytes (ANSI, invalid UTF-8)"
        session_captures_raw_bytes;
      test "an env override reaches one session's child alone"
        session_env_override_is_per_session;
      test "a self-exit flips the session to Exited via the waiter"
        session_self_exit_flips_to_exited;
      test "signal terminates the session and is idempotent"
        session_signal_terminates_and_is_idempotent;
      test ~tags:[ "slow" ] "signal reaches the workers the session forked"
        session_signal_reaches_the_forked_workers;
      test "signal escalates past a SIGTERM-ignoring child"
        session_signal_escalates_past_sigterm;
      test "sessions die on switch release" sessions_die_on_switch_release;
      (* Sandbox integration *)
      test "confined commands are enforced by the backend"
        confined_commands_are_enforced_by_the_backend;
      test "escalation opens the profile, never the environment"
        escalation_opens_the_profile_never_the_environment;
      test "a grant widens one command and no more"
        a_grant_widens_one_command_and_no_more;
      test "a grant of a denied path is refused"
        a_grant_of_a_denied_path_is_refused;
      test "read-only refuses a write grant" read_only_refuses_a_write_grant;
      test "a grant must name a directory" a_grant_must_name_a_directory;
      test "read-only escalation is denied" read_only_escalation_is_denied;
      test "a direct capability runs unconfined" direct_mode_runs_unconfined;
      test "a stale policy refuses before launch and at the gate"
        stale_policy_refuses_before_launch;
      test "an unavailable backend fails closed"
        unavailable_backend_fails_closed;
      test "the startup gate admits a fresh enforced capability"
        startup_gate_admits_an_enforced_capability;
    ]
