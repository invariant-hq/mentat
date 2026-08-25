(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Cfg = Mentat_config
module Runtime = Mentat_provider_runtime
module Store = Mentat_store
module Catalog = Mentat_provider.Catalog
module Selection = Mentat_provider.Selection
module Provider_model = Mentat_provider.Model
module Account = Mentat_provider.Account
module Engine = Mentat_agent
module Engine_config = Mentat_agent.Config
module Client = Mentat_client
module Protocol_error = Mentat_protocol.Error
module Tools = Mentat_tools

let apply_patch_capability = Provider_model.Capability.extension "apply-patch"

let tool_boot_log =
  Logs.Src.create "mentat.next.tool-boot" ~doc:"Executable tool boot resolution"

module Tool_boot_log = (val Logs.src_log tool_boot_log : Logs.LOG)

type model_overlay = {
  selector : Mentat_provider.Selector.t;
  reasoning_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
}

module Editor_family = struct
  type t = Apply_patch | String_replace

  type decision =
    | Configured of t
    | Auto_capable
    | Auto_incapable
    | Auto_no_model

  let family = function
    | Configured f -> f
    | Auto_capable -> Apply_patch
    | Auto_incapable | Auto_no_model -> String_replace
end

(* The per-user shared composition state: the process environment snapshot, the
   resolved user directories, the provider runtime, THE single opened session
   store, the ambient stdenv, and the switch that owns them. One daemon opens
   this once and shares it across every workspace instance it serves.

   One-store-handle invariant: never open a second [Mentat_store.t] on the same
   root in one process. The run lock's same-process fence half is a reservation
   per opened root handle, so two handles in one process would both [lockf] the
   same inode — which POSIX record locks never conflict between — and the fence
   would be void. The raw store-opening stage is private to construction here
   ({!stage_shared}), so a second same-root open is unrepresentable from outside
   this module. *)
type shared = {
  dirs : User_dirs.t;
  runtime : Runtime.t;
  store : Store.t;
  environment : (string * string) list;
  stdenv : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
}

type t = {
  shared : shared;
  root : Lpath.Abs.t;
  trusted : bool;
  config : Cfg.Resolved.t;
  (* The ambient environment this instance resolves against: the process's own
     snapshot on the single-workspace CLI path, the invoking client's snapshot
     for a daemon-hosted instance. Everything instance-scoped — config env
     overrides, toolchain discovery, account discovery, and above all the
     workspace resolution that constructs the exact child environment — reads
     this, never [shared.environment], so a daemon does not configure every
     child from whichever shell happened to spawn it first. *)
  ambient : (string * string) list;
  (* The per-instance switch: the engine, watch lane, and dune-RPC producer live
     under it, so instance eviction is one switch close after {!shutdown}. In the
     single-workspace CLI it is the same switch as {!shared}'s. *)
  switch : Eio.Switch.t;
  owner : Store.Run_lock.Owner.t;
  (* The review base revision spec, when a command names one (the [mentat review
     BASE] argument). [None] falls back to [MENTAT_REVIEW_BASE], then [HEAD]. *)
  review_base : string option;
  (* Executable-owned per-session setting overlays, keyed by
     session id text. The engine's per-turn config callback reads them. *)
  model_overlay : (string, model_overlay) Hashtbl.t;
  review_overlay : (string, Mentat_permission.Review_behavior.t) Hashtbl.t;
  (* The process-local config overrides captured at boot, retained so the A5
     re-stage below re-applies them over the re-read disk layers rather than
     losing them. *)
  overrides : Cfg.t list;
  (* A5: the user-config-file default re-staged from disk, cached by the file's
     mtime. [config] stays the immutable boot resolution; only the default-model
     resolution in {!config_callback} consults this, re-staging when a durable
     [set_default_model] or an offline [config set] advances the file's mtime. *)
  mutable staged_default : (float * Cfg.Resolved.t) option;
  (* Miss-path listing refreshes are rate-limited per provider: a selector
     that keeps missing must not probe the network on every resolution. *)
  listing_refresh_at : (string, float) Hashtbl.t;
  mutable engine : Engine.t option;
  mutable assembled :
    (Client.Driver.t * Mentat_workspace_io.t * Mentat_tool.t) option;
  (* The shared dune-RPC observer: one per instance, created and attached on
     first demand — a projection layer that never drains or glances also never
     starts the fiber — and shared by the notice producer and the status
     glance so both read one store. *)
  mutable dune_rpc : Mentat_ocaml_dune_rpc.Instance.t option;
  (* The build-watch supervisor: one per instance, created beside the observer
     on first demand and engaged at the first drain — never at boot, so a
     frontend opened on a cold workspace starts no build. *)
  mutable dune_watch : Dune_watch.t option;
  mutable dune_lint : Dune_lint.t option;
}

let dirs t = t.shared.dirs
let root t = t.root
let trusted t = t.trusted
let config t = t.config
let runtime t = t.shared.runtime
let catalog t = Runtime.catalog t.shared.runtime
let store t = t.shared.store

(* The per-workspace content-addressed capture store, keyed by the workspace
   root: the same store the engine's checkpoint captures write into, so the
   offline revert's [Before_revert] capture and the engine's turn captures share
   one keyed home. It resolves under the already-opened store root ([snapshots/]
   there), not a second native-path capability. Construction is pure —
   directories are minted under the root on first capture. *)
let snapshot_store t =
  let key =
    Mentat_digest.key ~length:24 ~domain:"mentat.workspace-snapshot.v1"
      [ Lpath.Abs.to_string t.root ]
  in
  Store.Capture.Store.create t.shared.store ~key

(* When the data home lives inside the workspace (the workspace-local store),
   its workspace-relative path is pruned from every capture so the capture
   system never snapshots its own sidecar. *)
let snapshot_self_prefix t =
  match Lpath.Abs.of_string (User_dirs.data_home t.shared.dirs) with
  | Ok abs -> Lpath.Abs.relativize ~root:t.root abs
  | Error _ -> None

let environment t = t.ambient
let stdenv t = t.shared.stdenv
let sw t = t.switch
let owner t = t.owner

(* [Unix.environment] is the sole process-environment observation for one
   composition. Although ordinary process environments have unique names,
   [execve] permits duplicates; matching [getenv]'s conventional scan, the
   first assignment in the captured array wins. Every later lookup, including
   configuration defaults and provider resolution, derives from this value. *)
let environment_get environment name =
  List.find_map
    (fun (found, value) -> if String.equal found name then Some value else None)
    environment

let getenv t name = environment_get t.ambient name
let clock_seconds t = Eio.Time.now (Eio.Stdenv.clock t.shared.stdenv)

(* [MENTAT_NOW] (Unix ms) pins the reference clock, so session timestamps and the
   [session list] AGE column are deterministic for tests and goldens (F10);
   absent or malformed, the real clock is used. *)
let now_time t =
  match Option.bind (getenv t "MENTAT_NOW") Int64.of_string_opt with
  | Some ms -> Mentat_session.Time.of_unix_ms ms
  | None -> Mentat_session.Time.of_unix_seconds_float (clock_seconds t)

let cred_now t = Int64.of_float (clock_seconds t)

let toolchain t =
  let env =
    t.ambient
    |> List.map (fun (name, value) -> name ^ "=" ^ value)
    |> Array.of_list
  in
  Mentat_ocaml_toolchain.discover ~env
    ~workspace_root:(Some (Lpath.Abs.to_string t.root))

(* The system and machine this process runs on, as the model-visible
   environment block reports it. [Sys.os_type] answers "Unix" for Linux and
   macOS alike, and the difference between them decides which commands, paths,
   and package manager the agent should reach for — so the block would state a
   platform while withholding the only part of it worth knowing. [uname -sm] is
   the portable system/architecture pair; it cannot change while the process
   lives, so it is read once and shared by every turn. A host that cannot
   answer falls back to [Sys.os_type] rather than dropping the fact. *)
let platform =
  lazy
    (let uname =
       match Unix.open_process_in "uname -sm 2>/dev/null" with
       | channel ->
           let line =
             try Some (input_line channel) with End_of_file -> None
           in
           ignore (Unix.close_process_in channel);
           line
       | exception (Unix.Unix_error _ | Sys_error _) -> None
     in
     match Option.map String.trim uname with
     | Some reported when not (String.equal reported "") -> reported
     | Some _ | None -> Sys.os_type)

(* Startup staging. *)

(* The sandbox posture pieces shared by the run path ([resolve_workspace]) and
   the doctor's parity probe, factored so the two cannot drift. [sandbox.mode]
   is deliberately optional in config; the product default is this
   executable's, stated once here. *)
let mentat_dirs_of dirs =
  List.filter_map
    (fun spelling -> Lpath.Abs.of_string spelling |> Result.to_option)
    [
      User_dirs.config_home dirs;
      User_dirs.data_home dirs;
      User_dirs.state_home dirs;
      User_dirs.daemon_socket_dir dirs;
    ]

let product_default_mode = Cfg.Mode.Workspace_write

type sandbox_posture = {
  posture_mode : Cfg.Mode.t;
  posture_read : Cfg.Read.t;
  posture_readable_roots : string list;
  posture_writable_roots : string list;
  posture_network : Mentat_sandbox.Policy.Network.t;
  posture_env_policy : Mentat_workspace_io.Env_policy.t;
}

let env_policy_of_config config =
  {
    Mentat_workspace_io.Env_policy.inherit_all =
      (match Cfg.Resolved.get Cfg.Field.sandbox_env_inherit config with
      | Cfg.Env_inherit.All -> true
      | Cfg.Env_inherit.Allowlist -> false);
    exclude = Cfg.Resolved.get Cfg.Field.sandbox_env_exclude config;
    include_only = Cfg.Resolved.get Cfg.Field.sandbox_env_include_only config;
  }

let sandbox_posture_of_config config =
  {
    posture_mode =
      Option.value
        (Cfg.Resolved.find Cfg.Field.sandbox_mode config)
        ~default:product_default_mode;
    posture_read = Cfg.Resolved.get Cfg.Field.sandbox_read config;
    posture_readable_roots =
      Cfg.Resolved.get Cfg.Field.sandbox_readable_roots config;
    posture_writable_roots =
      Cfg.Resolved.get Cfg.Field.sandbox_writable_roots config;
    posture_network = Cfg.Resolved.get Cfg.Field.sandbox_network config;
    posture_env_policy = env_policy_of_config config;
  }

(* Doctor's parity verdict — the ping-pong advisory. The dune mentat resolves
   and the dune a confined command's PATH resolves must be one binary: two
   dunes sharing one _build invalidate each other's work on every alternation,
   and the divergence is silent until a build takes ten minutes. The child
   PATH is a derivation of its own — an active opam switch is deliberately put
   ahead of it — so the check resolves the workspace the way a run would
   (posture and roots included, so the resolution side effects are a run's
   too) and compares physically. *)
let parity_check ~sw ~stdenv ~environment ~dirs ~config ~root ~ambient_dune =
  let posture = sandbox_posture_of_config config in
  let logical = Mentat_workspace.single (Mentat_workspace.Root.of_dir root) in
  match
    Mentat_workspace_io.resolve ~sw ~stdenv ~logical ~environment
      ~env_policy:posture.posture_env_policy ~mode:posture.posture_mode
      ~read:posture.posture_read ~readable_roots:posture.posture_readable_roots
      ~writable_roots:posture.posture_writable_roots
      ~mentat_dirs:(mentat_dirs_of dirs) ~network:posture.posture_network ()
  with
  | Error e ->
      Error
        (Format.asprintf "workspace did not resolve: %a"
           Mentat_workspace_io.Resolve_error.pp e)
  | Ok capability -> (
      let physical path =
        match Unix.realpath path with
        | resolved -> resolved
        | exception Unix.Unix_error _ -> path
      in
      match Mentat_workspace_io.child_program capability "dune" with
      | None ->
          Error
            (Printf.sprintf
               "commands find no dune on their PATH, but mentat resolves %s"
               ambient_dune)
      | Some child_dune
        when String.equal (physical child_dune) (physical ambient_dune) ->
          Ok (Printf.sprintf "commands resolve the same dune (%s)" child_dune)
      | Some child_dune ->
          Error
            (Printf.sprintf
               "commands resolve dune at %s but mentat resolves %s; builds \
                inside and outside will re-execute each other's work"
               child_dune ambient_dune))


let resolve_root ~cwd =
  let raw =
    match cwd with
    | Some dir when Filename.is_relative dir ->
        Filename.concat (Sys.getcwd ()) dir
    | Some dir -> dir
    | None -> Sys.getcwd ()
  in
  let canonical = try Unix.realpath raw with Unix.Unix_error _ -> raw in
  match Lpath.Abs.of_string canonical with
  | Ok abs -> Ok abs
  | Error e -> Error (canonical ^ ": " ^ Lpath.Error.message e)

(* Staging is defined once as a chain of individually observable named stages.
   [build_base] consumes them fail-closed for every normal command;
   {!with_probe} consumes each as a check for [doctor], so a broken config or
   store surfaces as a reported failure instead of aborting the command that
   exists to diagnose it. *)

let stage_dirs ~getenv = User_dirs.resolve ~getenv
let stage_root ~cwd = resolve_root ~cwd

let stage_trust ~dirs ~root =
  Trust_store.is_trusted
    ~path:(User_dirs.trust_file dirs)
    ~root:(Lpath.Abs.to_string root)

let stage_config ~dirs ~root ~trusted ~getenv ~overrides =
  Config_io.resolve ~dirs ~root ~trusted ~getenv ~overrides

let stage_runtime ~stdenv ~dirs =
  let config_dir =
    Eio.Path.( / ) (Eio.Stdenv.fs stdenv) (User_dirs.config_home dirs)
  in
  Runtime.create ~config_dir

(* Create the data home over {e every} [Unix_error] via [Fs.mkdir_p] (an
   [EEXIST]-only guard would let other errors crash to exit 125), then validate
   the [sessions/] layout: a non-directory where the store's sessions live is a
   corrupt store, not a healthy one. *)
let stage_store ~stdenv ~sw ~dirs ?data_home () =
  let ( let* ) = Result.bind in
  (* [data_home] overrides the account data home for an ephemeral run's
     throwaway store root; absent, the store lives under the resolved data home
     like every other command. *)
  let data_home = Option.value data_home ~default:(User_dirs.data_home dirs) in
  let* () = Fs.mkdir_p data_home in
  let sessions = Filename.concat data_home "sessions" in
  let* () =
    if Sys.file_exists sessions && not (Sys.is_directory sessions) then
      Error (sessions ^ ": not a directory")
    else Ok ()
  in
  let data_dir = Eio.Path.( / ) (Eio.Stdenv.fs stdenv) data_home in
  Result.map_error Store.Error.message (Store.open_ ~sw data_dir)

(* A store that cannot open is crash-grade — without it the process cannot
   function — so the stderr one-liner is backed by a crash report carrying the
   store's captured raise context when the failure came from a converted
   exception. The other stages' failures are user-fixable and stay bare. *)
let stage_store_reported ~stdenv ~sw ~dirs ~getenv ?data_home () =
  match stage_store ~stdenv ~sw ~dirs ?data_home () with
  | Ok _ as ok -> ok
  | Error message ->
      Error
        (match
           Log_setup.write_boot_failure_report ~message
             ~diagnostic:(Store.last_exn_diagnostic ())
             ~getenv
         with
        | Some path -> Printf.sprintf "%s (report saved: %s)" message path
        | None -> message)

let make_instance ~shared ~sw ~root ~trusted ~config ~environment ~overrides
    ~review_base : t =
  {
    shared;
    root;
    trusted;
    config;
    ambient = environment;
    switch = sw;
    owner = Store.Run_lock.Owner.make ();
    review_base;
    model_overlay = Hashtbl.create 8;
    review_overlay = Hashtbl.create 8;
    overrides;
    staged_default = None;
    listing_refresh_at = Hashtbl.create 4;
    engine = None;
    assembled = None;
    dune_rpc = None;
    dune_watch = None;
    dune_lint = None;
  }

(* The single-workspace CLI path: the exact staging sequence [with_base]
   has always run — dirs, root, trust, config, runtime, store — with its stage
   functions called directly and in order, so its observable failures and their
   text are unchanged. The shared/instance records are packed only afterward,
   over one switch that owns both, keeping this a record-level factoring rather
   than a resequencing. The daemon path sequences shared-then-instance below. *)
let build_base ~stdenv ~sw ~cwd ~overrides ?data_home ?review_base () :
    (t, Exit_status.t) result =
  let ( let* ) = Result.bind in
  let environment = Mentat_workspace_io.process_environment () in
  let getenv = environment_get environment in
  let stage r = Result.map_error Exit_status.runtime r in
  let* dirs = stage (stage_dirs ~getenv) in
  let* root = stage (stage_root ~cwd) in
  let trusted = stage_trust ~dirs ~root in
  let* config = stage (stage_config ~dirs ~root ~trusted ~getenv ~overrides) in
  let runtime = stage_runtime ~stdenv ~dirs in
  let* store =
    stage (stage_store_reported ~stdenv ~sw ~dirs ~getenv ?data_home ())
  in
  let shared = { dirs; runtime; store; environment; stdenv; sw } in
  Ok
    (make_instance ~shared ~sw ~root ~trusted ~config
       ~environment:shared.environment ~overrides ~review_base)

(* The daemon path: the per-user shared stage opened once under the owning
   switch. It stages the same dirs/runtime/store the CLI path does, in that
   order, and opens exactly one store handle (the one-handle invariant). *)
let stage_shared ~stdenv ~sw ?data_home () : (shared, Exit_status.t) result =
  let ( let* ) = Result.bind in
  let environment = Mentat_workspace_io.process_environment () in
  let getenv = environment_get environment in
  let stage r = Result.map_error Exit_status.runtime r in
  let* dirs = stage (stage_dirs ~getenv) in
  let runtime = stage_runtime ~stdenv ~dirs in
  let* store =
    stage (stage_store_reported ~stdenv ~sw ~dirs ~getenv ?data_home ())
  in
  Ok { dirs; runtime; store; environment; stdenv; sw }

(* A per-workspace instance over an already-opened [shared]: root, trust, and
   config staged against the shared dirs and environment, under the instance's
   own switch [sw] (the engine and watch lane live under it, so eviction closes
   one switch). No store is opened here — the shared handle is reused, which is
   what keeps the fence's same-process half honest. *)
let instance shared ~sw ~cwd ~overrides ?environment ?review_base () :
    (t, Exit_status.t) result =
  let ( let* ) = Result.bind in
  let environment = Option.value environment ~default:shared.environment in
  let getenv = environment_get environment in
  let stage r = Result.map_error Exit_status.runtime r in
  let* root = stage (stage_root ~cwd) in
  let trusted = stage_trust ~dirs:shared.dirs ~root in
  let* config =
    stage (stage_config ~dirs:shared.dirs ~root ~trusted ~getenv ~overrides)
  in
  Ok
    (make_instance ~shared ~sw ~root ~trusted ~config ~environment ~overrides
       ~review_base)

(* The engine's drivers are long-lived fibers under the instance switch; shut
   them down so the switch can close instead of blocking on idle drivers. The
   registry calls this before closing an evicted instance's switch. *)
let shutdown t =
  (* The watch first, before the instance switch releases: an explicit
     SIGTERM lets dune's own exit handlers unlink its socket and private
     registry entry, where the switch's teardown of still-running children
     would SIGKILL past them. *)
  (match t.dune_watch with
  | Some supervisor -> Dune_watch.stop supervisor
  | None -> ());
  match t.engine with Some engine -> Engine.shutdown engine | None -> ()

let retained_hub_count t =
  match t.engine with
  | Some engine -> Engine.retained_hub_count engine
  | None -> 0

let with_base ~cwd ~overrides ?data_home ?review_base f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  match build_base ~stdenv ~sw ~cwd ~overrides ?data_home ?review_base () with
  | Error status -> status
  | Ok t ->
      let status = f t in
      shutdown t;
      status

(* Model resolution. *)

let discover_accounts t =
  Runtime.discover_accounts t.shared.runtime ~environment:t.ambient ()

(* Base-URL and issuer overrides are per-provider, read from config and env. *)
let base_url_for t provider =
  Cfg.Resolved.find (Cfg.Field.provider_base_url provider) t.config

let auth_base_url_for t provider =
  let var =
    "MENTAT_"
    ^ String.uppercase_ascii
        (String.map
           (fun c ->
             if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then c else '_')
           (Mentat_llm.Provider.id provider))
    ^ "_AUTH_BASE_URL"
  in
  match getenv t var with
  | Some v when String.length v > 0 -> Some v
  | _ -> None

(* Server-listed models. A provider whose model set is server-owned publishes
   it through its driver check; the runtime retains the last good listing per
   provider. Selector resolution and the readiness picker share one synthesis
   — the declaration's listed-model rule — so a pickable row cannot die at
   resolution time. *)

let provider_listings ?providers t =
  match
    Runtime.listings t.shared.runtime ?providers ~base_url:(base_url_for t)
      ~auth_base_url:(auth_base_url_for t) ~environment:t.ambient ()
  with
  | Ok listings -> listings
  | Error _ -> []

(* Only providers with a listed-model (or dynamic) rule can gain models from
   a listing; every other provider skips the fallback and its refresh. *)
let listing_capable t provider =
  match Catalog.declaration (catalog t) provider with
  | Some declaration -> Mentat_provider.interprets_listings declaration
  | None -> false

let listing_capable_providers t =
  Catalog.declarations (catalog t)
  |> List.filter Mentat_provider.interprets_listings
  |> List.map Mentat_provider.id

let listed_model t selector =
  let ( let*? ) = Option.bind in
  let provider = Mentat_provider.Selector.provider selector in
  let*? declaration = Catalog.declaration (catalog t) provider in
  let*? listing =
    Option.map snd
      (List.find_opt
         (fun (p, _) -> Mentat_llm.Provider.equal p provider)
         (provider_listings ~providers:[ provider ] t))
  in
  let*? listed =
    Mentat_provider.Listing.find listing (Mentat_provider.Selector.id selector)
  in
  Mentat_provider.resolve_listed declaration listed

let refresh_listings t ?providers () =
  match
    Runtime.refresh_listings t.shared.runtime ~sw:t.switch ~env:t.shared.stdenv
      ?providers ~base_url:(base_url_for t) ~auth_base_url:(auth_base_url_for t)
      ~environment:t.ambient ()
  with
  | Ok () -> ()
  | Error _ ->
      (* A store failure already surfaces through account discovery; here it
         only means no fresher listing. *)
      ()

(* Miss-path refreshes are rate-limited per provider: a selector that keeps
   missing must not probe the network on every resolution. *)
let listing_refresh_cooldown_s = 60.

let refresh_listing_once t provider =
  let key = Mentat_llm.Provider.id provider in
  let now = Unix.gettimeofday () in
  let due =
    match Hashtbl.find_opt t.listing_refresh_at key with
    | Some at -> now -. at >= listing_refresh_cooldown_s
    | None -> true
  in
  if due then begin
    Hashtbl.replace t.listing_refresh_at key now;
    refresh_listings t ~providers:[ provider ] ()
  end

(* [find_model_cached] resolves against the catalog and the retained listings
   without any network; [find_model] additionally refreshes the provider's
   listing once on a miss and retries — so a configured server-listed model
   survives a process restart, while a path whose slot already answers never
   reaches the network. *)
let find_model_cached t selector =
  match Catalog.find (catalog t) selector with
  | Ok model -> Ok model
  | Error (Catalog.Error.Unknown_model _ as error) -> (
      match listed_model t selector with
      | Some model -> Ok model
      | None -> Error (Catalog.Error.message error))
  | Error error -> Error (Catalog.Error.message error)

let listed_fallback t selector error =
  let provider = Mentat_provider.Selector.provider selector in
  if not (listing_capable t provider) then Error (Catalog.Error.message error)
  else
    match listed_model t selector with
    | Some model -> Ok model
    | None -> (
        refresh_listing_once t provider;
        match listed_model t selector with
        | Some model -> Ok model
        | None -> Error (Catalog.Error.message error))

let find_model t selector =
  match Catalog.find (catalog t) selector with
  | Ok model -> Ok model
  | Error (Catalog.Error.Unknown_model _ as error) ->
      listed_fallback t selector error
  | Error error -> Error (Catalog.Error.message error)

(* The string-entry twin of [find_model], for CLI input. *)
let resolve_model t input =
  match Catalog.resolve (catalog t) input with
  | Ok model -> Ok model
  | Error (Catalog.Error.Unknown_model _ as error) -> (
      match Mentat_provider.Selector.of_string input with
      | Error _ -> Error (Catalog.Error.message error)
      | Ok selector -> listed_fallback t selector error)
  | Error error -> Error (Catalog.Error.message error)

let accounts discoveries =
  List.filter_map
    (function
      | Account.Discovery.Known account -> Some account
      | Account.Discovery.Resolution_failed _ -> None)
    discoveries

(* Selection consumes a preference, not an execution gate. A provider is
   preferred only when its independently resolved account is connected;
   optional authentication is evaluated later by the selected-route gate. *)
let provider_preferred discoveries provider =
  List.exists
    (fun account ->
      Mentat_llm.Provider.equal (Account.provider account) provider
      && Account.connected account)
    (accounts discoveries)

let credential_optional ~catalog provider =
  match Catalog.declaration catalog provider with
  | None -> false
  | Some declaration ->
      not (Mentat_provider.Auth.required (Mentat_provider.auth declaration))

(* A configured or per-session model is resolved through the catalog and then
   passed to [Selection.main] as its preferred model, so its lifecycle
   eligibility gates the run: a deprecated or unavailable configured model
   surfaces the structured requirement mismatch (with a same-provider hint)
   instead of being run. Provider preference is deliberately not consulted for
   an explicit preference. *)
let selection_requirements ?reasoning_effort () =
  Selection.Requirement.make ?reasoning_effort ()

let select_preferred ~catalog ~requirements model =
  Result.map_error Selection.Error.message
    (Selection.main ~catalog
       ~provider_preferred:(fun _ -> false)
       ~preferred:model ~requirements ())

let resolve_preferred_catalog_model ~catalog ~find ~selector ~reasoning_effort
    =
  let ( let* ) = Result.bind in
  let requirements = selection_requirements ?reasoning_effort () in
  let* model = find selector in
  select_preferred ~catalog ~requirements model

(* Auto-default (no model configured) must not pick an auth-free provider merely
   because it needs no credential: an unconfigured local endpoint (ollama) is
   "usable" by that rule yet blocks when probed. Eligibility for the default is a
   connected account; with none, {!Selection.main}'s provider-default tier falls
   through to the flagship provider (openai), whose credential gate then reports
   honestly instead of hanging. A local provider is chosen explicitly via `config
   set model` — the [Some] branch, which keeps the auth-free shortcut. *)
let resolve_default_catalog_model ~catalog ~find ~load_discoveries ~config =
  let ( let* ) = Result.bind in
  let requirements =
    selection_requirements
      ?reasoning_effort:(Cfg.Resolved.find Cfg.Field.reasoning config)
      ()
  in
  match Cfg.Resolved.find Cfg.Field.model config with
  | Some selector ->
      let* model = find selector in
      select_preferred ~catalog ~requirements model
  | None ->
      let* discoveries = load_discoveries () in
      Result.map_error
        (fun _ ->
          "no model configured and no usable provider; set a model with \
           `mentat config set model <provider>/<model>` or log in with `mentat \
           auth login <provider>`")
        (Selection.main ~catalog
           ~provider_preferred:(provider_preferred discoveries)
           ~requirements ())

let default_model t =
  Result.map Provider_model.llm
    (resolve_default_catalog_model ~catalog:(catalog t) ~find:(find_model t)
       ~config:t.config
       ~load_discoveries:(fun () ->
         Result.map_error Runtime.Store_error.message (discover_accounts t)))

let default_catalog_model t =
  resolve_default_catalog_model ~catalog:(catalog t) ~find:(find_model t)
    ~config:t.config
    ~load_discoveries:(fun () ->
      Result.map_error Runtime.Store_error.message (discover_accounts t))

(* The auxiliary small-model role (session auto-titling and other cheap side
   calls). It layers over the resolved main model: a configured [small_model]
   whose selector resolves and stays selectable wins, and anything else — no
   configured value, an unresolvable selector, an unavailable model — falls back
   to the main model. The small role therefore never blocks a run that the main
   model itself can start. *)
let resolve_small_catalog_model ~catalog ~find ~load_discoveries ~config =
  let ( let* ) = Result.bind in
  let* main =
    resolve_default_catalog_model ~catalog ~find ~load_discoveries ~config
  in
  match Cfg.Resolved.find Cfg.Field.small_model config with
  | None -> Ok (Selection.small ~main ())
  | Some selector -> (
      match find selector with
      | Error _ -> Ok (Selection.small ~main ())
      | Ok preferred -> Ok (Selection.small ~main ~preferred ()))

let small_model t =
  Result.map Provider_model.llm
    (resolve_small_catalog_model ~catalog:(catalog t) ~find:(find_model t)
       ~config:t.config
       ~load_discoveries:(fun () ->
         Result.map_error Runtime.Store_error.message (discover_accounts t)))

(* A provider whose declaration marks a credential as not required (local,
   ollama) can run after an honest Missing discovery. This fact never
   rewrites the account's phase and never bypasses a resolution failure. *)
let provider_credential_optional t provider =
  credential_optional ~catalog:(catalog t) provider

let provider_auth_satisfied t provider =
  match discover_accounts t with
  | Error error -> Error (Runtime.Error.Store error)
  | Ok discoveries -> (
      match
        List.find_opt
          (function
            | Account.Discovery.Known account ->
                Mentat_llm.Provider.equal (Account.provider account) provider
            | Account.Discovery.Resolution_failed { provider = found; _ } ->
                Mentat_llm.Provider.equal found provider)
          discoveries
      with
      | Some (Account.Discovery.Known account) ->
          Ok
            (Account.connected account
            || provider_credential_optional t provider)
      | Some (Account.Discovery.Resolution_failed { error; _ }) ->
          Error (Runtime.Error.Credential { provider; error })
      | None -> Error (Runtime.Error.Unknown_provider provider))

(* Doctor's probe over the same stages. *)

module Probe = struct
  type t = {
    config : (string, string) result;
    storage : (string, string) result;
    sessions : (int * int, string) result;
    toolchain : (string, string) result;
    parity : (string, string) result;
    project : (string, string) result;
    trusted : bool;
    accounts : (Account.Discovery.t list, string) result;
    default_model : (Mentat_llm.Model.t, string) result;
    state : (string, string) result;
    dune_lane : (string, string) result;
    lint : (string, string) result;
  }

  let config (p : t) = p.config
  let storage (p : t) = p.storage
  let state (p : t) = p.state
  let sessions (p : t) = p.sessions
  let toolchain (p : t) = p.toolchain
  let parity (p : t) = p.parity
  let project (p : t) = p.project
  let trusted (p : t) = p.trusted
  let accounts (p : t) = p.accounts
  let default_model (p : t) = p.default_model
  let dune_lane (p : t) = p.dune_lane
  let lint (p : t) = p.lint
end

(* Run every stage independently, catching each failure into a field rather than
   aborting. A stage whose prerequisite failed (config
   or the default model with no resolved config) carries that reason. *)
let probe ~stdenv ~sw ~cwd : Probe.t =
  let environment = Mentat_workspace_io.process_environment () in
  let getenv = environment_get environment in
  match stage_dirs ~getenv with
  | Error message ->
      {
        Probe.config = Error message;
        storage = Error message;
        sessions = Error message;
        toolchain = Error message;
        parity = Error message;
        project = Error message;
        trusted = false;
        accounts = Error message;
        default_model = Error message;
        state = Error message;
        dune_lane = Error message;
        lint = Error message;
      }
  | Ok dirs ->
      let root_result = stage_root ~cwd in
      let trusted =
        match root_result with
        | Ok root -> stage_trust ~dirs ~root
        | Error _ -> false
      in
      let config_resolved =
        match root_result with
        | Error message -> Error message
        | Ok root -> stage_config ~dirs ~root ~trusted ~getenv ~overrides:[]
      in
      let config =
        Result.map (fun _ -> User_dirs.config_file dirs) config_resolved
      in
      (* One store open serves two checks: the [storage] structural verdict and
         the [sessions] corrupt scan over the same handle. *)
      let store_result = stage_store ~stdenv ~sw ~dirs () in
      let storage =
        Result.map (fun _ -> User_dirs.data_home dirs) store_result
      in
      let sessions =
        match store_result with
        | Error message -> Error message
        | Ok store -> (
            match Store.Session.scan store with
            | Ok (docs, corrupt) -> Ok (List.length docs, List.length corrupt)
            | Error e -> Error (Store.Session.Error.message e))
      in
      (* The OCaml toolchain ladder ([MENTAT_DUNE] override, PATH, opam switch,
         local [_opam]) walked once for two rows: [toolchain] reports presence,
         [parity] compares the answer with the child's PATH. *)
      let dune_resolution =
        match root_result with
        | Error message -> Error message
        | Ok root ->
            let env =
              environment
              |> List.map (fun (name, value) -> name ^ "=" ^ value)
              |> Array.of_list
            in
            let tc =
              Mentat_ocaml_toolchain.discover ~env
                ~workspace_root:(Some (Lpath.Abs.to_string root))
            in
            Ok (root, Mentat_ocaml_toolchain.find tc "dune")
      in
      let toolchain =
        match dune_resolution with
        | Error message -> Error message
        | Ok (_, Some (abs, source)) ->
            Ok
              (Printf.sprintf "dune at %s (via %s)" abs
                 (Mentat_ocaml_toolchain.Source.to_string source))
        | Ok (_, None) -> Error "dune not found on PATH or opam switch"
      in
      let parity =
        match (dune_resolution, config_resolved) with
        | Error message, _ | _, Error message -> Error message
        | Ok (_, None), _ -> Error "no dune to compare (see toolchain)"
        | Ok (root, Some (ambient_dune, _)), Ok config ->
            parity_check ~sw ~stdenv ~environment ~dirs ~config ~root
              ~ambient_dune
      in
      (* Project detection reads the workspace root directly — doctor is a
         local-state diagnostic, not a sealed run — for the same [dune-project]/
         [dune-workspace] marker the tooling gate keys on. *)
      let project =
        match root_result with
        | Error message -> Error message
        | Ok root ->
            let is_regular name =
              let path = Filename.concat (Lpath.Abs.to_string root) name in
              match Unix.stat path with
              | stat -> stat.Unix.st_kind = Unix.S_REG
              | exception Unix.Unix_error _ -> false
            in
            if is_regular "dune-project" || is_regular "dune-workspace" then
              Ok "dune project"
            else Error "no dune-project (OCaml tooling inactive)"
      in
      (* The dune-lane posture: every rung the composition gates on —
         trust, the workspace.tooling knob, the project marker, dune.watch,
         and the read-only demotion — read here without an instance, so
         the row and the running lane cannot disagree. *)
      let dune_lane =
        match config_resolved with
        | Error message -> Error message
        | Ok config ->
            if not trusted then Error "lane off: workspace not trusted"
            else (
              let tooling =
                match
                  Cfg.Resolved.get Cfg.Field.workspace_tooling config
                with
                | "on" -> Ok ()
                | "off" -> Error "lane off: workspace.tooling = off"
                | "auto" | _ -> (
                    match project with
                    | Ok _ -> Ok ()
                    | Error reason -> Error reason)
              in
              match tooling with
              | Error _ as off -> off
              | Ok () -> (
                  match Cfg.Resolved.get Cfg.Field.dune_watch config with
                  | "off" -> Error "lane off: dune.watch = off"
                  | "observe" ->
                      Ok "observe — attaches to a running watch only"
                  | "auto" -> (
                      let read_only =
                        match
                          Cfg.Resolved.find Cfg.Field.sandbox_mode config
                        with
                        | Some Cfg.Mode.Read_only -> true
                        | Some _ | None -> false
                      in
                      if read_only then
                        Ok
                          "observe — auto demoted by sandbox.mode = \
                           read-only"
                      else
                        Ok
                          (Printf.sprintf
                             "auto — spawns and supervises `dune build \
                              --watch %s`"
                             (String.concat " "
                                (Cfg.Resolved.get Cfg.Field.dune_targets
                                   config))))
                  | other -> Error ("unknown dune.watch value: " ^ other)))
      in
      (* The lint command's reachability, answered on the ambient toolchain
         ladder — doctor is a local diagnostic, and the sealed child PATH
         the gate itself resolves on can differ (the parity row exists for
         exactly that divergence, for dune). The fallback order matches the
         gate's: directly, else through dune exec — whose first run, not
         this probe, answers whether the lock provides it. *)
      let lint =
        match (config_resolved, dune_lane) with
        | Error message, _ -> Error message
        | _, Error reason -> Error ("lint rides the dune lane: " ^ reason)
        | Ok config, Ok _ -> (
            match Cfg.Resolved.get Cfg.Field.dune_lint_command config with
            | [] -> Error "disabled (dune.lint_command = [])"
            | program :: _ as command -> (
                let rendered = String.concat " " command in
                let env =
                  environment
                  |> List.map (fun (name, value) -> name ^ "=" ^ value)
                  |> Array.of_list
                in
                let tc =
                  Mentat_ocaml_toolchain.discover ~env
                    ~workspace_root:
                      (match root_result with
                      | Ok root -> Some (Lpath.Abs.to_string root)
                      | Error _ -> None)
                in
                match Mentat_ocaml_toolchain.find tc program with
                | Some (_, source) ->
                    Ok
                      (Printf.sprintf "%s — resolves via %s" rendered
                         (Mentat_ocaml_toolchain.Source.to_string source))
                | None -> (
                    match Mentat_ocaml_toolchain.find tc "dune" with
                    | Some _ ->
                        Ok
                          (Printf.sprintf
                             "%s — via dune exec; its first run answers \
                              whether the project provides it"
                             rendered)
                    | None ->
                        Error
                          (Printf.sprintf "%s not found (lint lane off)"
                             program))))
      in
      let runtime = stage_runtime ~stdenv ~dirs in
      let catalog = Runtime.catalog runtime in
      let accounts =
        Runtime.discover_accounts runtime ~environment ()
        |> Result.map_error Runtime.Store_error.message
      in
      let default_model =
        match config_resolved with
        | Error message -> Error message
        | Ok config ->
            Result.map Provider_model.llm
              (resolve_default_catalog_model ~catalog
                 ~find:(fun selector ->
                   Result.map_error Catalog.Error.message
                     (Catalog.find catalog selector))
                 ~config
                 ~load_discoveries:(fun () -> accounts))
      in
      {
        Probe.config;
        storage;
        sessions;
        toolchain;
        parity;
        project;
        trusted;
        accounts;
        default_model;
        state = Ok (User_dirs.state_home dirs);
        dune_lane;
        lint;
      }

let with_probe ~cwd f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw -> f (probe ~stdenv ~sw ~cwd)

(* Error mapping onto the protocol. *)

let runtime_error_to_protocol (e : Runtime.Error.t) : Protocol_error.t =
  Protocol_error.Unavailable (Runtime.Error.diagnostic e)

(* Session-metadata error classification and the fenced commit live in
   {!Session_meta} — the one implementation the online cone (below) and the
   offline [cli_session] twin share. *)

(* The exe-filled driver cones. *)

let make_provider_call t =
  Provider_adapter.make ~sw:t.switch ~env:t.shared.stdenv
    ~now:(fun () -> cred_now t)
    ~runtime:t.shared.runtime ~base_url:(base_url_for t)
    ~auth_base_url:(auth_base_url_for t) ~environment:t.ambient ()

let small_model_completion t ~system ~user =
  let ( let* ) = Result.bind in
  let* model = small_model t in
  let* prelude =
    Mentat_llm.Request.Prelude.make [ Mentat_llm.Message.system system ]
    |> Result.map_error Mentat_llm.Request.Error.message
  in
  let* transcript =
    Mentat_llm.Transcript.of_list [ Mentat_llm.Message.user_text user ]
    |> Result.map_error Mentat_llm.Transcript.Error.message
  in
  let options = Mentat_llm.Request.Options.make ~max_output_tokens:128 () in
  let* request =
    Mentat_llm.Request.make ~model ~prelude ~options transcript
    |> Result.map_error Mentat_llm.Request.Error.message
  in
  let provider_call = make_provider_call t in
  match
    provider_call request
      ~on_event:(fun _ -> ())
      ~on_download:(fun _ -> ())
      ~cancelled:(fun () -> false)
  with
  | Ok response -> Ok (Mentat_llm.Response.text response)
  | Error error -> Error (Mentat_llm.Error.message error)

let accounts_cone t : Client.Driver.Accounts.t =
  let login ~provider ~method_ =
    let pending = Queue.create () in
    let changed = Eio.Condition.create () in
    let cancelled, cancel_resolver = Eio.Promise.create () in
    let push step =
      Queue.add step pending;
      Eio.Condition.broadcast changed
    in
    let next () =
      Eio.Condition.loop_no_mutex changed (fun () -> Queue.take_opt pending)
    in
    let cancel () = Eio.Promise.resolve cancel_resolver () in
    Eio.Fiber.fork ~sw:t.switch (fun () ->
        let settled =
          Runtime.Login.run t.shared.runtime ~sw:t.switch ~env:t.shared.stdenv
            ~provider ~method_id:method_ ?base_url:(base_url_for t provider)
            ?auth_base_url:(auth_base_url_for t provider)
            ~cancel:cancelled
            ~progress:(fun progress ->
              push (Ok (Client.Login.Progress progress)))
            ()
        in
        push
          (match settled with
          | Ok (Runtime.Login.Saved account) -> Ok (Client.Login.Saved account)
          | Ok Runtime.Login.Cancelled -> Ok Client.Login.Cancelled
          | Error error -> Error (runtime_error_to_protocol error)));
    Ok { Client.Login.next; cancel }
  in
  {
    Client.Driver.Accounts.login;
    save_api_key =
      (fun ~provider ~key ->
        match
          Runtime.Login.save_api_key t.shared.runtime ~sw:t.switch
            ~env:t.shared.stdenv ~provider ?base_url:(base_url_for t provider)
            ?auth_base_url:(auth_base_url_for t provider)
            ~key ()
        with
        | Error error -> Error (runtime_error_to_protocol error)
        | Ok account -> Ok account);
    logout =
      (fun ?(revoke = false) provider ->
        match
          Runtime.Login.logout t.shared.runtime ~sw:t.switch
            ~env:t.shared.stdenv ~provider ~revoke
            ?auth_base_url:(auth_base_url_for t provider)
            ~environment:t.ambient ()
        with
        | Ok settlement -> Ok settlement
        | Error e -> Error (runtime_error_to_protocol e));
    account_readiness =
      (fun () ->
        match discover_accounts t with
        | Error error ->
            Error (runtime_error_to_protocol (Runtime.Error.Store error))
        | Ok discoveries -> Ok discoveries);
    model_readiness =
      (fun ?(refresh = false) () ->
        if refresh then
          refresh_listings t ~providers:(listing_capable_providers t) ();
        match discover_accounts t with
        | Error error ->
            Error (runtime_error_to_protocol (Runtime.Error.Store error))
        | Ok discoveries ->
            Ok
              (Mentat_provider.Model_readiness.of_catalog
                 ~listings:(provider_listings t) (catalog t) ~discoveries));
  }

let overlay_key session = Mentat_session.Id.to_string session

let check_live_session t session =
  match Store.Session.load t.shared.store session with
  | Error error ->
      Error (Session_meta.session_store_error_to_protocol session error)
  | Ok document -> (
      let saved = Store.Session.Document.session document in
      match Mentat_session.Metadata.status (Mentat_session.metadata saved) with
      | Mentat_session.Metadata.Status.Active -> Ok ()
      | Mentat_session.Metadata.Status.Archived ->
          Error (Protocol_error.Archived session)
      | Mentat_session.Metadata.Status.Deleted ->
          Error (Protocol_error.Deleted session))

let copy_overlay table ~source ~target =
  match Hashtbl.find_opt table (overlay_key source) with
  | Some value -> Hashtbl.replace table (overlay_key target) value
  | None -> Hashtbl.remove table (overlay_key target)

let copy_overlays t ~source ~target =
  copy_overlay t.model_overlay ~source ~target;
  copy_overlay t.review_overlay ~source ~target

let clear_overlays t session =
  Hashtbl.remove t.model_overlay (overlay_key session);
  Hashtbl.remove t.review_overlay (overlay_key session)

let settings_cone t : Client.Driver.Settings.t =
  let unavailable message = Error (Protocol_error.unavailable message) in
  {
    Client.Driver.Settings.set_model =
      (fun ~session ?reasoning_effort selector ->
        match check_live_session t session with
        | Error error -> Error error
        | Ok () -> (
            match
              resolve_preferred_catalog_model ~catalog:(catalog t)
                ~find:(find_model t) ~selector ~reasoning_effort
            with
            | Error message -> unavailable message
            | Ok _ ->
                Hashtbl.replace t.model_overlay (overlay_key session)
                  { selector; reasoning_effort };
                Ok ()));
    set_permission_review =
      (fun ~session review ->
        match check_live_session t session with
        | Error error -> Error error
        | Ok () ->
            Hashtbl.replace t.review_overlay (overlay_key session) review;
            Ok ());
    (* The values-with-origins snapshot of the effective config resolved at
       startup. Redaction is by construction at the config owner. The
       disk-reread refinement matters only once
       disk-writing settings commands are wired; v1's writes are session-scoped
       overlays, so serving the resolved snapshot is faithful. *)
    configuration = (fun () -> Ok (Cfg.Resolved.view t.config));
    (* The durable, sessionless default-model write: validate the
       selection through the catalog, then atomically write [model] — and, when
       given, [reasoning] — to the user config layer in one plan, the same write
       path [mentat config set] uses. A5's mtime-gated re-stage in
       {!config_callback} makes the new default take effect at every live
       session's next turn, so there is no mutable in-memory config to swap; an
       omitted reasoning effort leaves the existing value untouched. *)
    set_default_model =
      (fun ?reasoning_effort selector ->
        match
          resolve_preferred_catalog_model ~catalog:(catalog t)
            ~find:(find_model t) ~selector ~reasoning_effort
        with
        | Error message -> unavailable message
        | Ok _ -> (
            let write config =
              let ( let* ) = Result.bind in
              let* config = Cfg.set Cfg.Field.model selector config in
              match reasoning_effort with
              | None -> Ok config
              | Some effort -> Cfg.set Cfg.Field.reasoning effort config
            in
            match
              Config_io.plan_write ~dirs:(dirs t) ~root:(root t) Config_io.User
                ~f:write
            with
            | Ok _ -> Ok ()
            | Error message -> unavailable message));
    (* The durable, sessionless UI-theme write: atomically write [tui.theme] to
       the user config layer, the same write path [config set] uses. The name is
       not catalog-validated — an unknown theme falls back at TUI launch — and
       the mtime-gated re-stage takes it into effect at the next launch. *)
    set_ui_theme =
      (fun ~theme ->
        let write config = Cfg.set Cfg.Field.tui_theme theme config in
        match
          Config_io.plan_write ~dirs:(dirs t) ~root:(root t) Config_io.User
            ~f:write
        with
        | Ok _ -> Ok ()
        | Error message -> unavailable message);
  }

(* The store scan stays exact and policy-free. [Mentat_session.Listing.select]
   is the one pure interpreter of listing request data shared with the offline
   CLI. *)
let summaries_of_scan docs =
  List.map
    (fun d ->
      Mentat_session.Summary.of_session (Store.Session.Document.session d))
    docs

let scan_summaries_error (e : Store.Session.Error.t) : Protocol_error.t =
  Protocol_error.Unavailable (Store.Session.Error.diagnostic e)

let lifecycle_cone t : Client.Driver.Lifecycle.t =
  (* Engine-first metadata commit (4a): a session {b this} process drives commits
     under its held fence at the engine's idle point, so a post-turn rename
     succeeds while the engine holds the fence rather than returning [Busy]. A
     session no live
     driver holds ([`Not_driven]) — the common case for an idle session, and every
     session under the offline CLI — falls back to the offline metadata twin,
     which acquires its own fence. One implementation of the transform, two commit
     paths. *)
  let commit session ~transform =
    let offline () =
      Session_meta.commit_transform ~store:t.shared.store ~sw:t.switch
        ~owner:t.owner ~now:(now_time t) session ~transform
    in
    match t.engine with
    | Some engine -> (
        match Engine.commit_metadata engine session ~transform with
        | `Committed result -> result
        | `Not_driven -> offline ())
    | None -> offline ()
  in
  {
    Client.Driver.Lifecycle.create =
      (fun ~id ~title ->
        let session =
          Mentat_session.create ~id ?title ~cwd:t.root ~created_at:(now_time t)
            ()
        in
        match Store.Session.create t.shared.store session with
        | Ok _ ->
            clear_overlays t id;
            Ok ()
        | Error e -> Error (Session_meta.session_store_error_to_protocol id e));
    rename =
      (fun ~session ~title ->
        commit session ~transform:(fun s ->
            Ok (Mentat_session.set_title (Some title) s)));
    archive =
      (fun ~session ->
        commit session ~transform:(fun s ->
            Result.map_error
              (Session_meta.session_error_to_protocol session)
              (Mentat_session.archive s)));
    restore =
      (fun ~session ->
        commit session ~transform:(fun s ->
            Result.map_error
              (Session_meta.session_error_to_protocol session)
              (Mentat_session.restore s)));
    delete =
      (fun ~session ->
        match
          commit session ~transform:(fun s ->
              Result.map_error
                (Session_meta.session_error_to_protocol session)
                (Mentat_session.delete s))
        with
        | Error error -> Error error
        | Ok () ->
            clear_overlays t session;
            Ok ());
    (* A scan-level failure surfaces as [Unavailable]. A successful scan keeps
       every healthy selected row and converts each corrupt fact once at its
       store owner for report-only remote consumers. *)
    sessions =
      (fun ~listing ->
        match Store.Session.scan t.shared.store with
        | Error e -> Error (scan_summaries_error e)
        | Ok (docs, corrupt) ->
            Ok
              ( Mentat_session.Listing.select ~cwd:t.root listing
                  (summaries_of_scan docs),
                List.map Store.Session.Corrupt.diagnostic corrupt ));
    session =
      (fun id ->
        match Store.Session.load t.shared.store id with
        | Ok doc ->
            Ok
              (Mentat_session.Session_view.of_session
                 (Store.Session.Document.session doc))
        | Error e -> Error (Session_meta.session_store_error_to_protocol id e));
  }

(* The exe-filled review cone. *)

(* The workspace review is over the diff from a base revision to the worktree.
   [base_spec] defaults to [HEAD] (uncommitted work) and is overridable — the CLI
   review command threads its optional [BASE] argument here, and
   [MENTAT_REVIEW_BASE] overrides it out of band. The review is workspace-scoped:
   the persisted marks/verdict/cursor record is keyed by the workspace root and
   the resolved base, restored against freshly loaded content on every read so
   stale marks drop rather than mislead. [capability] must be a
   writable workspace so the CR-compose flow can author source comments; reads
   run under it too. *)
let default_review_base_spec = "HEAD"

let review_base_spec t =
  (* An explicit [mentat review BASE] argument wins; [MENTAT_REVIEW_BASE] is the
     out-of-band override; [HEAD] is the default. *)
  match t.review_base with
  | Some spec when String.length (String.trim spec) > 0 -> String.trim spec
  | Some _ | None -> (
      match getenv t "MENTAT_REVIEW_BASE" with
      | Some spec when String.length (String.trim spec) > 0 -> String.trim spec
      | Some _ | None -> default_review_base_spec)

(* Project-tooling gate: whether a workspace marker file is a regular file, and
   the [trust + workspace.tooling] verdict the dune build-health surfaces key on.
   Shared by the notice producer and the workspace status-glance cone
   so they engage on one rule. The marker check reads through the passed
   capability. *)
let project_marker_is_regular capability marker =
  match Mentat_workspace_io.resolve_path capability marker with
  | Error (Mentat_workspace.Resolve_error.Outside_workspace _)
  | Error (Mentat_workspace.Resolve_error.Invalid_input _)
  | Error (Mentat_workspace.Resolve_error.Unknown_root _) ->
      false
  | Ok path -> (
      match Mentat_workspace_io.File.stat capability path with
      | Ok stat -> stat.Eio.File.Stat.kind = `Regular_file
      | Error (Mentat_workspace_io.File_error.Unknown_root _)
      | Error (Mentat_workspace_io.File_error.Not_found _)
      | Error (Mentat_workspace_io.File_error.Escapes_workspace _)
      | Error (Mentat_workspace_io.File_error.Too_large _)
      | Error (Mentat_workspace_io.File_error.Io _) ->
          false)

let project_tools_enabled t capability =
  t.trusted
  &&
  match Cfg.Resolved.get Cfg.Field.workspace_tooling t.config with
  | "on" -> true
  | "off" -> false
  | "auto" ->
      project_marker_is_regular capability "dune-project"
      || project_marker_is_regular capability "dune-workspace"
  | tooling -> invalid_arg ("unknown workspace.tooling value: " ^ tooling)

(* The [dune.watch] posture for one capability: [None] for an untrusted or
   tooling-disabled workspace and for the knob's [off] — off constructs no
   supervisor at all; otherwise the knob's mode, with a read-only build
   posture demoted to observe — a watch that could not write [_build] would
   only die at startup. The notice flag is a separate, narrower gate:
   [notices.dune_diagnostics] silences the model's build notices without
   turning the watch or its status row off. *)
let dune_watch_mode t capability =
  if not (project_tools_enabled t capability) then None
  else
    let mode =
      match Cfg.Resolved.get Cfg.Field.dune_watch t.config with
      | "off" -> None
      | "observe" -> Some Dune_watch.Mode.Observe
      | "auto" -> Some Dune_watch.Mode.Auto
      | mode -> invalid_arg ("unknown dune.watch value: " ^ mode)
    in
    let sandbox_mode =
      Option.value
        (Cfg.Resolved.find Cfg.Field.sandbox_mode t.config)
        ~default:product_default_mode
    in
    match (mode, sandbox_mode) with
    | Some Dune_watch.Mode.Auto, Cfg.Mode.Read_only ->
        Some Dune_watch.Mode.Observe
    | mode, _ -> mode

(* The shared observer, created on first demand under the instance switch. The
   attach loop holds the watch's diagnostic and progress subscriptions on its
   own fiber; every consumer — the drain-time producer, the glance — reads its
   snapshot without IO. The accessor owns its own gate: an untrusted,
   tooling-off, or watch-off workspace never constructs an observer, so no
   future caller can attach one around the gate by accident. *)
(* The one logical-workspace value the dune lane resolves paths against:
   the observer's stream diagnostics and the lint runner's parsed output
   must agree on it, or the "resolved exactly as stream diagnostics are"
   parity silently breaks. *)
let dune_workspace t =
  Mentat_workspace.single (Mentat_workspace.Root.of_dir t.root)

let dune_rpc_instance t capability =
  match dune_watch_mode t capability with
  | None -> None
  | Some _ -> (
      match t.dune_rpc with
      | Some instance -> Some instance
      | None ->
          let stdenv = t.shared.stdenv in
          (* [Instance.create] never suspends, so the slot is filled before
             any other fiber can observe it empty; the re-check makes the
             once-ness structural rather than incidental should that ever
             change. *)
          let instance =
            Mentat_ocaml_dune_rpc.Instance.create ~fs:(Eio.Stdenv.fs stdenv)
              ~net:(Eio.Stdenv.net stdenv)
              ~mono:(Eio.Stdenv.mono_clock stdenv)
              ~workspace:(dune_workspace t) ~env:(getenv t) ()
          in
          (match t.dune_rpc with
          | Some raced -> Some raced
          | None ->
              t.dune_rpc <- Some instance;
              (* A daemon fiber: the attach loop must never hold the instance
                 switch open past its main flow — teardown cancels it. *)
              Eio.Fiber.fork_daemon ~sw:t.switch (fun () ->
                  Mentat_ocaml_dune_rpc.Instance.attach instance;
                  `Stop_daemon);
              Some instance))

(* The build-watch supervisor, one per instance beside the observer. Creation
   is pure and idempotent; {!Dune_watch.engage} is the caller's, at the first
   drain, so the projection layers that only read {!Dune_watch.health} never
   spawn anything. The spawn route is the sealed build capability — the watch
   runs under the same confinement as every other command. *)
let dune_watch_supervisor t capability ~mode ~instance =
  match t.dune_watch with
  | Some supervisor -> supervisor
  | None ->
      (* Resolvability is probed on the sealed child PATH so [No_dune] can be
         reported without spawning; the launch itself resolves the bare name
         again, as every launch does — the watch is the same dune the
         confined shell's [dune build] finds and forwards to. *)
      let program =
        Option.map
          (fun _ -> [ "dune" ])
          (Mentat_workspace_io.child_program capability "dune")
      in
      let supervisor =
        Dune_watch.make ~rpc:instance ~capability
          ~mono:(Eio.Stdenv.mono_clock t.shared.stdenv)
          ~sw:t.switch ~root:t.root
          ~run_id:(Printf.sprintf "watch-%d" (Unix.getpid ()))
          ~mode ~program
          ~targets:(Cfg.Resolved.get Cfg.Field.dune_targets t.config)
      in
      t.dune_watch <- Some supervisor;
      supervisor

(* The lint runner, one per instance beside the supervisor. Its gate
   mirrors the watch's ladder: the dune lane must be live at all (the
   trigger is the observer's readings — auto or observe alike, since a
   foreign watch's green settle is as good as our own), the
   [dune.lint_command] knob non-empty, and the command reachable — in
   either of the two worlds a project keeps its linter in. A program that
   resolves on the sealed child PATH runs directly (the opam world; no
   dune in the lint path). One that does not is reached through
   [dune exec] (the dune-pkg world: a dev-dependency's binary lives in the
   lock universe, not on the PATH — and may not be built yet, which
   [dune exec] also answers by building it). Either way the resolution
   goes through the project's own environment, so the linter found is
   version-matched to the compiler that wrote the artifacts it reads. With
   neither the program nor dune reachable there is no runner at all;
   whether the reached command actually exists is the first run's answer
   ({!Dune_lint}), never a parse of anything. A missing linter is a normal
   state: the lane stays silently lint-absent, and doctor is where the
   reason lives. Creation is pure; {!Dune_lint.engage} is the caller's, at
   the first drain. *)
let dune_lint_runner t capability ~instance =
  match t.dune_lint with
  | Some runner -> Some runner
  | None -> (
      match Cfg.Resolved.get Cfg.Field.dune_lint_command t.config with
      | [] -> None
      | program :: _ as command -> (
          let command =
            match Mentat_workspace_io.child_program capability program with
            | Some _ -> Some command
            | None -> (
                match
                  Mentat_workspace_io.child_program capability "dune"
                with
                | Some _ -> Some ([ "dune"; "exec"; "--" ] @ command)
                | None -> None)
          in
          match command with
          | None -> None
          | Some command ->
              let runner =
                Dune_lint.make ~rpc:instance ~capability
                  ~mono:(Eio.Stdenv.mono_clock t.shared.stdenv)
                  ~sw:t.switch
                  ~workspace:(dune_workspace t) ~command
              in
              t.dune_lint <- Some runner;
              Some runner))

(* The review git loader wiring: the effect closures that adapt the workspace
   capability's sealed boundaries into the [run]/[read]/[write] the pure
   {!Review_git} loader takes. This is the executable-side half of the review
   projection — the projection itself lives in [Review_git], and workspace_io
   carries no review domain. *)

(* A worktree file at most this large is read whole for review content; a larger
   file surfaces as a loader read failure. *)
let git_read_max_bytes = 16 * 1024 * 1024

(* A single git subprocess exceeding this bound is treated as stuck: the child is
   terminated and the loader reports an honest failure rather than an unbounded
   stall. Normal review git operations complete in well under a second; the
   review responder caches the loaded snapshot so ordinary interaction never
   respawns git. *)
let git_spawn_timeout_s = 60.

(* Git spawns cross the one sealed process boundary: full capture, no shell, the
   workspace root as cwd, and the private child environment. A non-zero exit is
   returned as its trimmed stderr so [resolve_base] can classify a bad revision;
   a run exceeding [timeout] is terminated and reported, never left to hang.
   [stdin], when present, feeds the child — [git cat-file --batch] reads its
   object list that way. *)
let git_run capability ~timeout ?stdin argv =
  let stdin = Option.map Eio.Flow.string_source stdin in
  match
    Mentat_workspace_io.Command.run capability
      ~capture:Mentat_workspace_io.Command.All ~timeout ?stdin argv
  with
  | Error error ->
      Error (Format.asprintf "%a" Mentat_workspace_io.Command.Error.pp error)
  | Ok outcome -> (
      match outcome.Mentat_workspace_io.Command.termination with
      | Mentat_workspace_io.Command.Exited (`Exited 0) -> (
          match outcome.Mentat_workspace_io.Command.stdout with
          | Mentat_workspace_io.Command.Captured.Complete text -> Ok text
          | Mentat_workspace_io.Command.Captured.Truncated _ ->
              Error "git output was truncated")
      | Mentat_workspace_io.Command.Exited (`Exited code) ->
          let stderr =
            String.trim
              (Mentat_workspace_io.Command.Captured.render
                 outcome.Mentat_workspace_io.Command.stderr)
          in
          Error
            (if String.length stderr > 0 then stderr
             else Printf.sprintf "git exited with status %d" code)
      | Mentat_workspace_io.Command.Exited (`Signaled signal) ->
          Error (Printf.sprintf "git terminated by signal %d" signal)
      | Mentat_workspace_io.Command.Stopped -> Error "git run was cancelled"
      | Mentat_workspace_io.Command.Timed_out -> Error "git run timed out"
      | Mentat_workspace_io.Command.Output_limit _ ->
          Error "git output exceeded the capture limit"
      | Mentat_workspace_io.Command.Supervision_failed err ->
          Error (Format.asprintf "%a" Eio.Exn.pp_err err))

let git_read capability rel =
  match
    Mentat_workspace_io.resolve_path capability (Lpath.Rel.to_string rel)
  with
  | Error error ->
      Error (Format.asprintf "%a" Mentat_workspace.Resolve_error.pp error)
  | Ok path -> (
      match
        Mentat_workspace_io.File.load capability path
          ~max_bytes:git_read_max_bytes
      with
      | Ok text -> Ok text
      | Error error ->
          Error (Format.asprintf "%a" Mentat_workspace_io.File_error.pp error))

(* A CR edit is a stale-safe full-file rewrite through the native-write enforcer,
   so it refuses protected metadata and read-only roots exactly as an agent edit
   would, and fails loud if the file moved between the loader's read and here. *)
let git_write capability rel ~before ~after =
  match
    Mentat_workspace_io.resolve_path capability (Lpath.Rel.to_string rel)
  with
  | Error error ->
      Error (Format.asprintf "%a" Mentat_workspace.Resolve_error.pp error)
  | Ok path -> (
      match Mentat_edit.rewrite ~path ~before ~after with
      | Error error -> Error (Format.asprintf "%a" Mentat_edit.Error.pp error)
      | Ok plan -> (
          match Mentat_workspace_io.Edit.apply capability plan with
          | Ok _ -> Ok ()
          | Error error ->
              Error (Format.asprintf "%a" Mentat_edit.Apply_error.pp error)))

(* The review git loader over [capability]: its git subprocess runs through the
   sealed [Command.run] (full capture, workspace-root cwd, private child
   environment) and its worktree reads through [File.load], so every git effect
   crosses the capability's sealed boundary. Each git spawn is bounded by a
   monotonic timeout off [clock], so a stuck git fails honestly rather than
   hanging. The loader owns no processes; it reads the worktree state on demand. *)
let open_review_git capability ~clock =
  let timeout = Eio.Time.Timeout.seconds clock git_spawn_timeout_s in
  Review_git.make
    ~run:(git_run capability ~timeout)
    ~read:(git_read capability) ~write:(git_write capability)

(* The loaded review session held across a review's queries and commands: the git
   loader, the resolved base, the current review value, and its store document
   (for the next CAS commit). CR mutations pull the current worktree fresh on
   each action, so no loaded-snapshot fingerprint is cached here. *)
type review_session = {
  loader : Review_git.t;
  base : string;
  review : Mentat_review.t;
  doc : Store.Review.Document.t option;
}

let review_cone t capability ~base_spec : Client.Driver.Review.t =
  let root_key =
    Mentat_workspace.Root.key (Mentat_workspace.Root.of_dir t.root)
  in
  let clock = Eio.Stdenv.mono_clock t.shared.stdenv in
  let unavailable message = Protocol_error.unavailable message in
  let git_error e = unavailable (Review_git.Error.message e) in
  let store_error e =
    Protocol_error.Unavailable (Store.Review.Error.diagnostic e)
  in
  (* The review is loaded once and cached: navigation, marks, and reads reuse the
     held snapshot rather than respawning git per operation (the server-side
     pull-on-action model). The lock serializes concurrent queries
     so an open that fires [review_state] and [review_crs] together loads once. A
     CR-compose or a first load is the only path that spawns git; a subsequent
     external worktree change is picked up when compose's fingerprint guard trips
     or on a fresh review invocation. *)
  let lock = Eio.Mutex.create () in
  let cache : review_session option ref = ref None in
  (* Load the current review: the git snapshot restored against the persisted
     record for the same base, if one exists. *)
  let load_fresh () =
    let loader = open_review_git capability ~clock in
    match Review_git.resolve_base loader base_spec with
    | Error e -> Error (git_error e)
    | Ok base -> (
        match Review_git.load loader ~base with
        | Error e -> Error (git_error e)
        | Ok loaded -> (
            let base_review =
              Mentat_review.v ~feature:loaded.Mentat_review.Live.feature
                ~crs:loaded.Mentat_review.Live.crs
            in
            let key = Store.Review.Key.make ~root:root_key ~base in
            match Store.Review.load t.shared.store key with
            | Error e -> Error (store_error e)
            | Ok doc ->
                let review =
                  match doc with
                  | Some doc ->
                      Mentat_review.Persist.restore
                        (Store.Review.Document.value doc)
                        base_review
                  | None -> base_review
                in
                Ok { loader; base; review; doc }))
  in
  (* Run [f] under the lock over the loaded session, loading and caching it on
     first use. [f] may replace the cache (a command does; a read does not). *)
  let with_session f =
    Eio.Mutex.use_rw ~protect:true lock (fun () ->
        let ensured =
          match !cache with
          | Some session -> Ok session
          | None -> (
              match load_fresh () with
              | Ok session ->
                  cache := Some session;
                  Ok session
              | Error _ as error -> error)
        in
        match ensured with Error _ as error -> error | Ok session -> f session)
  in
  (* Commit a review state and return the fresh document so the cache carries the
     new CAS revision for the next command. *)
  let persist doc review =
    let record = Mentat_review.Persist.of_review review in
    match
      match doc with
      | Some doc -> Store.Review.commit t.shared.store doc record
      | None -> Store.Review.create t.shared.store ~root:root_key record
    with
    | Ok new_doc -> Ok new_doc
    | Error e -> Error (store_error e)
  in
  {
    Client.Driver.Review.state =
      (fun ~scope ->
        with_session (fun session ->
            Ok (Mentat_review.View.of_review session.review ~focus:scope)));
    diff =
      (fun ~path ->
        with_session (fun session ->
            Ok
              (Option.map Mentat_review.File_diff.of_file
                 (Mentat_review.Feature.find_file
                    (Mentat_review.feature session.review)
                    ~path))));
    crs =
      (fun () ->
        with_session (fun session ->
            Ok (Mentat_review.Cr.views (Mentat_review.crs session.review))));
    apply =
      (fun command ->
        with_session (fun session ->
            (* A mark, verdict, or cursor move is a pure transform over the held
               review — no git respawn — then a store commit. *)
            match Mentat_review.Command.apply session.review command with
            | Error e -> Error (unavailable (Mentat_review.Error.message e))
            | Ok updated -> (
                match persist session.doc updated with
                | Error _ as error -> error
                | Ok new_doc ->
                    cache :=
                      Some { session with review = updated; doc = Some new_doc };
                    Ok ())));
    compose =
      (fun edit ->
        with_session (fun session ->
            (* Pull-on-action: [apply_edit] reads the target file fresh and
               re-resolves the edit's ref against a fresh scan, so staleness is
               judged against the commented CR alone. An unrelated worktree edit
               never blocks the action; only the commented CR changing does
               (surfaced as [Content_changed]). *)
            match
              Review_git.apply_edit session.loader ~base:session.base edit
            with
            | Error Review_git.Content_changed ->
                Error
                  (unavailable
                     "the comment you are editing changed on disk; reopen the \
                      review to see the current comments")
            | Error (Review_git.Apply_failed message) ->
                Error (unavailable message)
            | Ok reloaded -> (
                (* The CR edit changed the worktree, so refresh over the new
                   snapshot and cache it for subsequent operations. *)
                let refreshed =
                  Mentat_review.refresh session.review
                    ~feature:reloaded.Mentat_review.Live.feature
                    ~crs:reloaded.Mentat_review.Live.crs
                in
                match persist session.doc refreshed with
                | Error _ as error -> error
                | Ok new_doc ->
                    cache :=
                      Some
                        { session with review = refreshed; doc = Some new_doc };
                    Ok ())));
  }

(* The workspace status-glance cone: the ambient side-pane pull the frontend
   polls at session start and turn settle. Both signals are re-read per call —
   the cone caches no verdict, honoring the derived-on-demand law; the frontend
   holds the answer as a last observation. Git errors and a non-repository both
   degrade to [None] worktree stats rather than a loud failure, so an absent
   glance is honest, never an error dialog. *)
let workspace_cone t capability ~base_spec : Client.Driver.Workspace.t =
  let clock = Eio.Stdenv.mono_clock t.shared.stdenv in
  let worktree_stats () =
    let loader = open_review_git capability ~clock in
    match Review_git.resolve_base loader base_spec with
    | Error _ -> None
    | Ok base -> (
        match Review_git.stats loader ~base with
        | Ok stats -> Some stats
        | Error _ -> None)
  in
  (* The glance's dune half is a memory read, never IO and never a drain: the
     transition notices are the notice producer's business, and a read that
     consumed them would eat the model's observations. Once the first drain
     engages the supervisor, its machine speaks — until then the glance
     reports the attach observer's view alone, so a frontend opened before
     any turn spawns nothing. A tooling-disabled, untrusted, or watch-off
     workspace reports [Off Disabled], which the frontend renders as an
     absent row. *)
  let tooling_health () =
    match dune_watch_mode t capability with
    | None -> Mentat_workspace.Health.Off Mentat_workspace.Health.Off.Disabled
    | Some _ -> (
        match t.dune_watch with
        | Some supervisor -> Dune_watch.health supervisor
        | None -> (
            match dune_rpc_instance t capability with
            | None ->
                Mentat_workspace.Health.Off
                  Mentat_workspace.Health.Off.Disabled
            | Some instance ->
                Mentat_ocaml_dune_rpc.Instance.Snapshot.health
                  (Mentat_ocaml_dune_rpc.Instance.snapshot instance)))
  in
  {
    Client.Driver.Workspace.glance =
      (fun () -> Ok (worktree_stats (), tooling_health ()));
    dune = (fun () -> Ok (tooling_health ()));
    (* The user's verb over the supervised watch. Before the first drain
       nothing is engaged yet, but the verb must still stick — a stop
       issued from a fresh frontend holds through the drain's engage, and
       a restart is the eager engage a user asking for a watch plainly
       wants — so the verb constructs the supervisor on demand exactly as
       the drain would (construction is pure and memoized; the lane's gate
       still decides whether there is one to construct). With the lane off
       the verb is an observation only. *)
    dune_control =
      (fun ~op ->
        let supervisor =
          match t.dune_watch with
          | Some supervisor -> Some supervisor
          | None -> (
              match dune_watch_mode t capability with
              | None -> None
              | Some mode ->
                  Option.map
                    (fun instance ->
                      let supervisor =
                        dune_watch_supervisor t capability ~mode ~instance
                      in
                      Dune_watch.engage supervisor;
                      supervisor)
                    (dune_rpc_instance t capability))
        in
        (match (supervisor, op) with
        | Some supervisor, `Restart -> Dune_watch.restart supervisor
        | Some supervisor, `Stop -> Dune_watch.stop supervisor
        | None, (`Restart | `Stop) -> ());
        Ok (tooling_health ()));
  }

(* The engine config callback. *)

(* Current Mentat's documented compaction policy reserves an output buffer of at
   most 20k tokens below the selected catalog model's context window. Next's
   agent config owns only the resulting pressure threshold, so composition
   projects that established product law without introducing another policy
   carrier. *)
let compaction_pressure_tokens config model =
  if not (Cfg.Resolved.get Cfg.Field.compaction_auto config) then None
  else
    match Provider_model.context_window model with
    | None -> None
    | Some context_window ->
        let output_buffer =
          match Provider_model.max_output_tokens model with
          | None -> 20_000
          | Some tokens -> min 20_000 tokens
        in
        if context_window > output_buffer then
          Some (context_window - output_buffer)
        else None

(* Curated read-only documentation hosts a web fetch may reach without review.
   These are permission-layer facts and do not open a shell command's network
   namespace. *)
let web_docs_allowlist =
  [
    "docs.rs";
    "doc.rust-lang.org";
    "developer.mozilla.org";
    "pkg.go.dev";
    "docs.python.org";
    "ocaml.org";
    "v2.ocaml.org";
    "man7.org";
    "www.gnu.org";
  ]

(* The fixed product policy a Build turn contract composes after the durable
   rules. It reviews
   plainly high-impact commands before crediting narrow execution, credits
   sealed project-read restricted commands and an explicitly selected external
   boundary, credits the sealed confined execution the OCaml tools record,
   allows native workspace file operations because their typed tools enforce the
   workspace boundary, and allows web fetches of curated documentation hosts.
   Durable rules precede it, so a matching durable review or deny still wins, and
   session grants are consulted only for accesses no rule matches. The read-only
   modes use [read_only_policy] instead; this is the [workspace-write] posture. *)
let product_rules build_capability =
  let module Policy = Mentat_permission.Policy in
  let command_execution_rule execution =
    Policy.Rule.allow
      (Policy.Match.command (Policy.Match.Command.execution execution))
  in
  let project_execution write =
    Mentat_permission.Access.Command.Enforced
      Mentat_permission.Access.Command.Confinement.
        { read = Project; write; network = Restricted }
  in
  let workspace_rule op =
    Policy.Rule.allow (Policy.Match.path ~op Policy.Match.Path.workspace)
  in
  let documentation_rule host =
    Policy.Rule.allow (Policy.Match.network_host ~host ())
  in
  let confinement =
    Tools.Confinement.confined build_capability
    |> Tools.Confinement.custom_access
  in
  Policy.Rule.review (Policy.Match.command Policy.Match.Command.high_impact)
  :: List.map command_execution_rule
       [
         project_execution
           Mentat_permission.Access.Command.Confinement.Read_only;
         project_execution
           Mentat_permission.Access.Command.Confinement.Workspace;
         Mentat_permission.Access.Command.External;
       ]
  @ Policy.Rule.allow (Policy.Match.exact confinement)
    :: List.map workspace_rule [ `Read; `Create; `Modify; `Delete ]
  @ List.map documentation_rule web_docs_allowlist

(* A5: the config the per-turn default-model resolution reads, re-staged from the
   user layer file when its mtime advanced since the last stage — so a durable
   [set_default_model] or an offline [config set] takes effect at the next turn
   without a mutable in-memory config swap. Only the user layer is mtime-gated; a
   project-layer mid-life edit stays out of scope (a fresh process picks it up). A
   re-stage failure keeps the immutable boot config. *)
let staged_default_config t =
  let user_path =
    Config_io.layer_path ~dirs:(dirs t) ~root:(root t) Config_io.User
  in
  let mtime = try (Unix.stat user_path).Unix.st_mtime with _ -> 0.0 in
  match t.staged_default with
  | Some (cached, config) when Float.equal cached mtime -> config
  | _ -> (
      match
        stage_config ~dirs:(dirs t) ~root:(root t) ~trusted:t.trusted
          ~getenv:(getenv t) ~overrides:t.overrides
      with
      | Ok config ->
          t.staged_default <- Some (mtime, config);
          config
      | Error _ -> t.config)

let config_callback t ~product_rules :
    Mentat_session.Id.t ->
    latest_model:Mentat_llm.Model.t option ->
    (Engine_config.t, Mentat_diagnostic.t) result =
 fun session ~latest_model ->
  let provider_catalog = catalog t in
  (* Next-turn model precedence: process-local overlay > session latest_model >
     config default. The overlay is a live, process-only preference set this run
     (e.g. the TUI model picker) and wins outright. With no overlay, a resumed
     session must honor the model its own journal last recorded — the durable
     fact the engine owns and replays into [latest_model] — before falling back
     to the global config default. Only this callback can decide it: the overlay
     is visible here alone, the engine supplies the durable [latest_model] it
     owns but cannot see the overlay, and the config default sees neither. If the
     seeded model is no longer in the catalog (it was removed or deconfigured
     since that turn), resolution falls through to the config default. *)
  let seeded_model_result =
    match latest_model with
    | None -> None
    | Some model -> (
        let selector = Mentat_provider.Selector.of_model model in
        match
          resolve_preferred_catalog_model ~catalog:provider_catalog
            ~find:(find_model t) ~selector ~reasoning_effort:None
        with
        | Ok _ as ok -> Some ok
        | Error _ -> None)
  in
  let model_result, reasoning_effort =
    match
      Hashtbl.find_opt t.model_overlay (Mentat_session.Id.to_string session)
    with
    | Some { selector; reasoning_effort } ->
        ( resolve_preferred_catalog_model ~catalog:provider_catalog
            ~find:(find_model t) ~selector ~reasoning_effort,
          reasoning_effort )
    | None -> (
        match seeded_model_result with
        (* The seeded model carries no stored reasoning effort; [None] defers to
           the resolved model's own default below (mirrors the overlay path). *)
        | Some model_result -> (model_result, None)
        | None ->
            (* A5: read the mtime-gated re-staged config, so a durable default
               written this process (or by an offline [config set]) takes effect
               at this turn boundary. *)
            let staged = staged_default_config t in
            ( resolve_default_catalog_model ~catalog:provider_catalog
                ~find:(find_model t) ~config:staged
                ~load_discoveries:(fun () ->
                  Result.map_error Runtime.Store_error.message
                    (discover_accounts t)),
              Cfg.Resolved.find Cfg.Field.reasoning staged ))
  in
  match model_result with
  | Error message -> Error (Mentat_diagnostic.of_text message)
  | Ok catalog_model ->
      let model = Provider_model.llm catalog_model in
      let reasoning_effort =
        match reasoning_effort with
        | Some _ as requested -> requested
        | None -> Provider_model.default_reasoning catalog_model
      in
      let options = Mentat_llm.Request.Options.make ?reasoning_effort () in
      (* Resolved groups are already ordered by effective first-match
         precedence. [permission.unattended] controls the headless responder;
         it is not a review bypass and therefore does not alter [review]. *)
      let policy =
        (Cfg.Resolved.permission_rules t.config |> List.concat_map snd)
        @ product_rules
        |> Mentat_permission.Policy.make
      in
      let max_steps = Cfg.Resolved.find Cfg.Field.run_max_steps t.config in
      let compaction_pressure_tokens =
        compaction_pressure_tokens t.config catalog_model
      in
      let max_spawn_depth =
        Cfg.Resolved.get Cfg.Field.run_subagent_max_depth t.config
      in
      let max_exchanges =
        Cfg.Resolved.get Cfg.Field.run_subagent_max_exchanges t.config
      in
      let review =
        Option.value
          (Hashtbl.find_opt t.review_overlay
             (Mentat_session.Id.to_string session))
          ~default:Mentat_permission.Review_behavior.Enforce
      in
      (* [continuation_turn_limit] caps goal-driven continuation turns; the
         engine requires an explicit bound so an unbounded goal is never
         accidental (agent/config.mli). The next CLI wires no [--goal] surface
         yet, so no headless turn consumes it; a conservative non-runaway
         default of 50 stands until a goal surface lands and threads a config
         value through. *)
      Ok
        (Engine_config.make ~model ~options ~policy ~review ?max_steps
           ?compaction_pressure_tokens ~continuation_turn_limit:(Some 50)
           ~max_spawn_depth ~max_exchanges ())

(* The Build editor-tool family decision, declared once here (the composition
   root owns product policy) and consumed by the real assembly below and by the
   [debug model] inspector. [tools.editor] pins the family outright; [auto]
   resolves it from the resolved model's apply-patch capability. The human-facing
   "reason" strings stay with the inspector's renderer; this returns the decision
   with a machine reason so the value and its explanation cannot drift. *)
let editor_family t model =
  match Cfg.Resolved.get Cfg.Field.tools_editor t.config with
  | "apply-patch" -> Editor_family.Configured Editor_family.Apply_patch
  | "string-replace" -> Editor_family.Configured Editor_family.String_replace
  | "auto" -> (
      match model with
      | Some model
        when Provider_model.has_capability apply_patch_capability model ->
          Editor_family.Auto_capable
      | Some _ -> Editor_family.Auto_incapable
      | None -> Editor_family.Auto_no_model)
  | editor -> invalid_arg ("unknown tools.editor value: " ^ editor)

(* The workspace capability. *)

let configured_revert_merge t = Cfg.Resolved.get Cfg.Field.revert_merge t.config

let configured_sandbox_mode t =
  match Cfg.Resolved.find Cfg.Field.sandbox_mode t.config with
  | Some mode -> mode
  (* The config library deliberately leaves [sandbox.mode] optional. This
     executable owns the product default ([product_default_mode], stated once
     beside the posture record); capability resolution, status, and the TUI
     all consume this operation. Safety on an unenforceable posture comes from
     the startup gate below, not from the default. *)
  | None -> product_default_mode

let resolve_workspace t ~mode ~network :
    (Mentat_workspace_io.t, Exit_status.t) result =
  let logical = Mentat_workspace.single (Mentat_workspace.Root.of_dir t.root) in
  let posture = sandbox_posture_of_config t.config in
  (* Mentat's own config, data and state homes. A confined command must not
     read them — the session store holds every transcript — and must not write
     them, because that store carries the sealed confinement identity a resume
     revalidates against, so a command that could rewrite it could approve
     itself.

     The daemon's socket directory is the fourth, and it is the one that would
     hurt most. It sits under [/tmp], which is granted writable so ordinary
     tools have somewhere to work, and the socket authorizes any local peer
     without a token — so without this denial a confined command could hand the
     daemon a request and drive Mentat instead of being confined by it. A
     denial nested inside a writable root is exactly the shape the ordered
     policy resolves correctly. *)
  let mentat_dirs = mentat_dirs_of t.shared.dirs in
  match
    Mentat_workspace_io.resolve ~sw:t.switch ~stdenv:t.shared.stdenv ~logical
      ~environment:t.ambient ~env_policy:posture.posture_env_policy ~mode
      ~read:posture.posture_read
      ~readable_roots:posture.posture_readable_roots
      ~writable_roots:posture.posture_writable_roots ~mentat_dirs ~network ()
  with
  | Ok capability -> Ok capability
  | Error e ->
      Error
        (Exit_status.runtime
           (Format.asprintf "%a" Mentat_workspace_io.Resolve_error.pp e))

(* The full client. *)

let session_cone t engine : Client.Driver.Session.t =
  let cone = Engine.driver engine in
  {
    cone with
    Client.Driver.Session.fork =
      (fun ~session ~into ->
        Result.map
          (fun () -> copy_overlays t ~source:session ~target:into)
          (cone.Client.Driver.Session.fork ~session ~into));
    rewind =
      (fun ~session ~into ~anchor ->
        Result.map
          (fun () -> copy_overlays t ~source:session ~target:into)
          (cone.Client.Driver.Session.rewind ~session ~into ~anchor));
  }

(* The [web_search] backend and its optional key resolved from config. The
   provider selector ([exa]|[parallel]|[off]) chooses the remote MCP backend, or
   withholds the tool when [off]. Both backends search keyless; a per-backend key
   only raises limits. *)
let web_search t =
  match
    Tools.Web.Search_service.of_string
      (Cfg.Resolved.get Cfg.Field.web_search_provider t.config)
  with
  | None -> None
  | Some backend ->
      let api_key =
        match backend with
        | Tools.Web.Search_service.Exa ->
            Cfg.Resolved.find Cfg.Field.web_exa_api_key t.config
        | Tools.Web.Search_service.Parallel ->
            Cfg.Resolved.find Cfg.Field.web_parallel_api_key t.config
      in
      Some (backend, api_key)

(* The offline execution layer: the sealed workspace capabilities, the per-mode
   execution assembly the engine consumes, and the per-mode tool declarations an
   inspector reads. Built without the engine, provider, or store adapters, so
   {!tool_declarations} projects the boot-fixed catalogs a run seals without ever
   opening a client. *)
type execution_layer = {
  build_capability : Mentat_workspace_io.t;
  read_capability : Mentat_workspace_io.t;
  shell : Mentat_tool.t;
  execution_for_mode : Engine.Execution.factory;
  delegated_execution : Engine.Execution.delegated_factory;
  declarations_for :
    mode:Mentat_session.Contract.Mode.t ->
    model:Mentat_llm.Model.t ->
    Mentat_llm.Tool.t list;
}

(* The catalog and execution assembly, factored from {!build_client} so [debug
   tools] can project the sealed tool declarations offline. It seals the
   workspaces, resolves the toolchain programs, and builds every boot-fixed
   catalog family, but constructs no engine, provider, or store adapter — those
   are {!build_client}'s alone. *)
let build_execution_layer t : (execution_layer, Exit_status.t) result =
  let ( let* ) = Result.bind in
  let build_mode = configured_sandbox_mode t in
  let build_network = Cfg.Resolved.get Cfg.Field.sandbox_network t.config in
  let* build_capability =
    resolve_workspace t ~mode:build_mode ~network:build_network
  in
  let* read_capability =
    resolve_workspace t ~mode:Cfg.Mode.Read_only
      ~network:Mentat_sandbox.Policy.Network.Restricted
  in
  (* The startup gate: after sealing the workspace, before any
     credential or session effect, refuse a run whose sealed confinement cannot
     meet [sandbox.require] — an unenforceable posture fails closed here, not at
     the first command. *)
  let check capability =
    let requirement = Cfg.Resolved.get Cfg.Field.sandbox_require t.config in
    match Mentat_workspace_io.check capability ~requirement with
    | Ok () -> Ok ()
    | Error r ->
        Error
          (Exit_status.runtime (Mentat_sandbox.Requirement.Rejection.message r))
  in
  let* () = check build_capability in
  let* () = check read_capability in
  let clock = Eio.Stdenv.mono_clock t.shared.stdenv in
  let tool_boot = Tool_boot.make read_capability ~toolchain:(toolchain t) in
  let merlin_program =
    let configured = Cfg.Resolved.get Cfg.Field.ocaml_merlin_program t.config in
    match Tool_boot.resolve_merlin tool_boot ~configured with
    | Ok program -> program
    | Error error ->
        (* A [dune tools exec] prefix must never escape lookup and build during
           a claimed tool call. Report the typed observation failure once, then
           let each Merlin tool surface Unavailable if the plain binary is
           absent from the sealed child PATH. *)
        Tool_boot_log.warn (fun log ->
            log "%s; falling back to ocamlmerlin"
              (Tool_boot.error_message error));
        [ "ocamlmerlin" ]
  in
  let dune_program = Tool_boot.resolve_program tool_boot "dune" in
  let ocamlfind_program = Tool_boot.resolve_program tool_boot "ocamlfind" in
  (* Classic-switch source fallback remains disabled until the logical
     workspace admits the switch's [lib/] as a root: command-policy readability
     alone is not authority for WIO [File] operations. Project-tree dependency
     lookup remains available through Dune. *)
  let opam_switch_prefix = None in
  let* web_tools =
    if not (Cfg.Resolved.get Cfg.Field.web_enabled t.config) then Ok []
    else
      match
        Tools.Web.Policy.make
          ~allow_private_network:
            (Cfg.Resolved.get Cfg.Field.web_allow_private_network t.config)
          ~max_fetch_bytes:
            (Cfg.Resolved.get Cfg.Field.web_fetch_max_bytes t.config)
          ~max_output_chars:
            (Cfg.Resolved.get Cfg.Field.web_output_max_chars t.config)
          ~default_timeout_ms:
            (Cfg.Resolved.get Cfg.Field.web_timeout_ms t.config)
          ~max_timeout_ms:
            (Cfg.Resolved.get Cfg.Field.web_max_timeout_ms t.config)
          ()
      with
      | Error error ->
          Error (Exit_status.runtime (Tools.Web.Policy.Error.message error))
      | Ok policy ->
          Ok
            (Tools.Web.tools ~policy
               ~net:(Eio.Stdenv.net t.shared.stdenv)
               ~mono_clock:clock ?search:(web_search t) ())
  in
  let image_max_bytes = Cfg.Resolved.get Cfg.Field.image_max_bytes t.config in
  let image_max_dimension =
    Cfg.Resolved.get Cfg.Field.image_max_dimension t.config
  in
  let build_read_tools =
    [
      Tools.Fs.Read_file.make build_capability ~image_max_bytes
        ~image_max_dimension;
      Tools.Fs.Glob.make build_capability;
      Tools.Fs.Search_text.make build_capability ~clock;
    ]
  in
  let string_replace_tools =
    [
      Tools.Fs.Write_file.make build_capability;
      Tools.Fs.Edit_file.make build_capability;
    ]
  in
  let apply_patch_tools = [ Tools.Fs.Apply_patch.make build_capability ] in
  (* A dune command's tool timeout is a hang's only witness — the forwarded
     build traverses the watch's event loop — so it is reported to the
     supervisor, which verifies before restarting; other programs' timeouts
     are their own business. The lexical rule is the pure
     {!Mentat_ocaml_dune_rpc.Watch.forwards_into_watch}; this closure only
     wires it to the one supervisor that can act on it. *)
  let dune_stall_report ~command =
    if Mentat_ocaml_dune_rpc.Watch.forwards_into_watch ~command then
      match t.dune_watch with
      | Some supervisor -> Dune_watch.report_stall supervisor
      | None -> ()
  in
  let shell =
    Tools.Shell.make ~on_timeout:dune_stall_report build_capability ~clock
      ~shell:(Cfg.Resolved.get Cfg.Field.shell t.config)
  in
  (* The declaration-only background family: a process-lifetime registry backs
     the shell_output/shell_kill declarations the boot-fixed Build catalog
     carries (for recovery matching and the inspector projection). Its tools are
     never run — the runtime uses the per-session family built over the driver's
     switch in [execution_for_mode]. The [shell] tool above (registryless) is the
     TUI's foreground seam and already carries the background declaration, so a
     boot catalog reads identically to a session one. *)
  let boot_registry = Tools.Shell.Registry.create ~sw:(sw t) in
  let boot_shell_tools =
    [
      shell;
      Tools.Shell.Shell_output.make boot_registry;
      Tools.Shell.Shell_kill.make boot_registry;
    ]
  in
  let structural_ocaml_read_tools =
    [ Tools.Ocaml.Search_expressions.make build_capability ]
  in
  let structural_ocaml_edit_tools =
    [
      Tools.Ocaml.Ocaml_ast_edit.make build_capability;
      Tools.Ocaml.Replace_expressions.make build_capability;
    ]
  in
  let project_ocaml_edit_tools =
    [ Tools.Ocaml.Rename.make build_capability ~clock ~program:merlin_program ]
  in
  (* The lock-taking one-shots' moment of truth. A supervised watch is
     paused for the call — the lease — and respawns after it; a foreign
     watch cannot be paused, so the honest refusal stands there (dune's
     delete-the-lock advice is byte-identical whoever holds the lock, and a
     foreign watch is the common case for a developer running their own
     [dune build -w]). The closure reads the instance field so tool
     construction never engages the supervisor. *)
  let dune_lease () =
    match t.dune_watch with
    | None -> `Free
    | Some supervisor -> Dune_watch.lease supervisor
  in
  let project_ocaml_nonediting_tools =
    [
      Tools.Ocaml.Type_at.make build_capability ~clock ~program:merlin_program;
      Tools.Ocaml.Eval.make build_capability ~clock ~program:dune_program
        ~dune_lease ();
      Tools.Ocaml.Find_definitions.make build_capability ~clock
        ~program:merlin_program;
      Tools.Ocaml.Find_references.make build_capability ~clock
        ~program:merlin_program;
      Tools.Ocaml.Docs.make build_capability ~clock ~merlin_program
        ~dune_program ~ocamlfind_program ~opam_switch_prefix ~dune_lease ();
    ]
  in
  let read_core_tools =
    [
      Tools.Fs.Read_file.make read_capability ~image_max_bytes
        ~image_max_dimension;
      Tools.Fs.Glob.make read_capability;
      Tools.Fs.Search_text.make read_capability ~clock;
      Tools.Ocaml.Search_expressions.make read_capability;
    ]
  in
  let read_project_tools =
    [
      Tools.Ocaml.Type_at.make read_capability ~clock ~program:merlin_program;
      Tools.Ocaml.Find_definitions.make read_capability ~clock
        ~program:merlin_program;
      Tools.Ocaml.Find_references.make read_capability ~clock
        ~program:merlin_program;
    ]
  in
  let make_catalog ~verbs tools =
    match Engine.Catalog.make ~verbs tools with
    | Ok catalog -> catalog
    | Error e -> failwith (Engine.Catalog.Error.message e)
  in
  let module Verb = Engine.Catalog.Verb in
  let collaboration =
    [ Verb.Spawn; Verb.Wait; Verb.Send_message; Verb.Follow_up ]
  in
  let build_verbs =
    [ Verb.Todo_write; Verb.Update_goal; Verb.Ask_user ] @ collaboration
  in
  let plan_verbs = [ Verb.Ask_user; Verb.Propose_plan ] @ collaboration in
  let review_verbs = Verb.Ask_user :: collaboration in
  let snapshot_store = snapshot_store t in
  let snapshot_self_prefix = snapshot_self_prefix t in
  (* The dune lane is gated by {!dune_watch_mode} (trust, [workspace.tooling],
     [dune.watch]): for a trusted, tooling-engaged workspace the first engine
     drain engages the supervisor — under [auto] it probes and attaches or
     spawns the confined watch; under [observe] it only records that nothing
     is spawned while the observer attaches — and never at boot, so the
     offline tool and capability listings neither create the observer nor
     start a fiber. The drain itself stays a memory read of the shared
     observer plus the pure change law — no IO on the driver fiber — and
     [notices.dune_diagnostics] silences only the model's notices: the watch
     and its status row outlive the opt-out. Spawning rides the sealed build
     capability — build breakage is a build-mode concern. *)
  let build_health_notices =
    match dune_watch_mode t read_capability with
    | None -> None
    | Some mode ->
        let notices_enabled =
          Cfg.Resolved.get Cfg.Field.notices_dune_diagnostics t.config
        in
        (* Both lazily, so a projection layer that never drains — the offline
           tool and capability listings — neither creates the observer nor
           engages the supervisor. The first engine drain does both. *)
        let engaged =
          lazy
            (match dune_rpc_instance t read_capability with
            | None -> ()
            | Some instance ->
                let supervisor =
                  dune_watch_supervisor t build_capability ~mode ~instance
                in
                Dune_watch.engage supervisor;
                Option.iter Dune_lint.engage
                  (dune_lint_runner t build_capability ~instance))
        in
        let producer =
          lazy
            (Option.map
               (fun instance -> Workspace_notices.make ~instance ())
               (dune_rpc_instance t read_capability))
        in
        Some
          (fun () ->
            Lazy.force engaged;
            (* The supervisor's word first — a restart or a blocked file
               watcher explains the readings that follow it — and outside
               the [notices.dune_diagnostics] opt-out: a restart advisory
               explains a failed tool call, not a build change, so a user
               silencing build chatter still hears it. *)
            (match t.dune_watch with
            | Some supervisor -> Dune_watch.drain_notices supervisor
            | None -> [])
            @
            if notices_enabled then
              match Lazy.force producer with
              | None -> []
              | Some producer -> Workspace_notices.drain producer
            else [])
  in
  (* The watch lane is attached to the build workspace alone: its poll
     boundaries advance on the root driver's fiber (claim brackets and
     drains), and the read twin serves concurrent delegated
     drivers, which must not touch the single-consumer watcher. *)
  let watch =
    if not (Cfg.Resolved.get Cfg.Field.notices_fswatch t.config) then None
    else
      Some
        (Workspace_watch.start ~sw:t.switch
           ~clock:(Eio.Stdenv.clock t.shared.stdenv)
           ?ignore_prefix:snapshot_self_prefix ~root:t.root ())
  in
  let build_notices =
    match (build_health_notices, watch) with
    | None, None -> None
    | health, watch ->
        (* Cause before consequence: what changed on disk, then what the build
           made of it. *)
        Some
          (fun () ->
            Option.fold ~none:[] ~some:Workspace_watch.drain watch
            @ Option.fold ~none:[] ~some:(fun drain -> drain ()) health)
  in
  let build_workspace =
    Workspace_adapter.make ~store:snapshot_store
      ?self_prefix:snapshot_self_prefix ?notices:build_notices ?watch
      build_capability
  in
  let read_workspace =
    Workspace_adapter.make ~store:snapshot_store
      ?self_prefix:snapshot_self_prefix read_capability
  in
  (* The write twin of the build workspace that delegated children write
     through: the same sealed build capability and snapshot store, but no
     watch/notices lane. The single-consumer file watcher stays with the root
     build driver alone (it advances the watch lane on its own fiber); a
     concurrent child shares the write capability without touching that watcher.
     Children are not isolated from one another or the parent — they share this
     one workspace — so a spawner must give each a disjoint file set. *)
  let delegated_build_workspace =
    Workspace_adapter.make ~store:snapshot_store
      ?self_prefix:snapshot_self_prefix build_capability
  in
  let read_only_policy =
    let module Policy = Mentat_permission.Policy in
    let confinement =
      Tools.Confinement.confined read_capability
      |> Tools.Confinement.custom_access
    in
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.path ~op:`Read Policy.Match.Path.workspace);
        Policy.Rule.allow (Policy.Match.exact confinement);
        Policy.Rule.deny_all;
      ]
  in
  (* The catalog-resolved editor family for a run's model: resolve the catalog
     model (an unresolved selector counts as no model, exactly [auto]'s fallback)
     and consult the one editor-family decision. *)
  let editor_family_for model =
    let catalog_model =
      Result.to_option
        (find_model_cached t (Mentat_provider.Selector.of_model model))
    in
    editor_family t catalog_model |> Editor_family.family
  in
  let user_config_file =
    Lpath.Abs.of_string_exn (User_dirs.config_file t.shared.dirs)
  in
  (* One workspace root: the canonicalized cwd is both the discovery root and
     the run directory, so context and skills load against [t.root]. *)
  let load_skills () =
    Mentat_context.Skills.load ~stdenv:t.shared.stdenv
      ~builtins:Mentat_prompts.Skills.all ~config:t.config ~trusted:t.trusted
      ~root:t.root ~cwd:t.root ~user_config_file
  in
  (* The [skill] tool is boot-fixed so the sealed catalog family stays finite
     for recovery; its declaration is static and its handler re-discovers skills
     per call. It is present only when skills are enabled and at least one is
     active at boot, and it joins every catalog family identically. *)
  let skill_tools =
    Option.to_list
      (Mentat_context.Skills.tool ~stdenv:t.shared.stdenv ~discover:load_skills)
  in
  let full_build_catalog ~shell_tools ~editor ~project_tools =
    let editor_tools =
      match editor with
      | Editor_family.Apply_patch -> apply_patch_tools
      | Editor_family.String_replace -> string_replace_tools
    in
    make_catalog ~verbs:build_verbs
      (build_read_tools @ editor_tools @ shell_tools
     @ structural_ocaml_read_tools @ structural_ocaml_edit_tools
      @ (if project_tools then
           project_ocaml_edit_tools @ project_ocaml_nonediting_tools
         else [])
      @ web_tools @ skill_tools)
  in
  let read_only_workspace_build_catalog ~shell_tools ~project_tools =
    make_catalog ~verbs:build_verbs
      (build_read_tools @ shell_tools @ structural_ocaml_read_tools
      @ (if project_tools then project_ocaml_nonediting_tools else [])
      @ web_tools @ skill_tools)
  in
  let read_catalog ~verbs ~project_tools =
    make_catalog ~verbs
      (read_core_tools
      @ (if project_tools then read_project_tools else [])
      @ skill_tools)
  in
  (* The build-catalog family is a function of the shell tools it carries: the
     boot family (declaration-only) and each session family (registry-backed,
     built in [execution_for_mode]) instantiate it. Tool {e declarations} are
     registry-independent, so every instantiation carries the same sealed
     identity — recovery matches a session catalog against the boot declarations. *)
  let full_build_catalogs ~shell_tools =
    [
      ( (Editor_family.Apply_patch, false),
        full_build_catalog ~shell_tools ~editor:Editor_family.Apply_patch
          ~project_tools:false );
      ( (Editor_family.Apply_patch, true),
        full_build_catalog ~shell_tools ~editor:Editor_family.Apply_patch
          ~project_tools:true );
      ( (Editor_family.String_replace, false),
        full_build_catalog ~shell_tools ~editor:Editor_family.String_replace
          ~project_tools:false );
      ( (Editor_family.String_replace, true),
        full_build_catalog ~shell_tools ~editor:Editor_family.String_replace
          ~project_tools:true );
    ]
  in
  let read_only_workspace_build_catalogs ~shell_tools =
    [
      ( false,
        read_only_workspace_build_catalog ~shell_tools ~project_tools:false );
      (true, read_only_workspace_build_catalog ~shell_tools ~project_tools:true);
    ]
  in
  let read_catalogs verbs =
    [
      (false, read_catalog ~verbs ~project_tools:false);
      (true, read_catalog ~verbs ~project_tools:true);
    ]
  in
  let plan_catalogs = read_catalogs plan_verbs in
  let review_catalogs = read_catalogs review_verbs in
  let delegated_catalogs = read_catalogs collaboration in
  let declarations_equal catalog declarations =
    List.equal Mentat_llm.Tool.equal
      (Engine.Catalog.declarations catalog)
      declarations
  in
  let build_catalogs ~shell_tools =
    List.map snd (full_build_catalogs ~shell_tools)
    @ List.map snd (read_only_workspace_build_catalogs ~shell_tools)
  in
  let rec ensure_distinct_build_catalogs = function
    | [] -> ()
    | catalog :: rest ->
        let declarations = Engine.Catalog.declarations catalog in
        if List.exists (fun other -> declarations_equal other declarations) rest
        then invalid_arg "Build catalogs have duplicate tool declarations"
        else ensure_distinct_build_catalogs rest
  in
  (* The distinctness invariant is over declarations, which are registry-
     independent, so it holds for every session family iff it holds for the boot
     family; check it once at boot. *)
  let () =
    ensure_distinct_build_catalogs
      (build_catalogs ~shell_tools:boot_shell_tools)
  in
  (* Recovery never re-runs model/config/marker selection. The durable
     declaration snapshot identifies exactly one member of the finite catalog
     family constructed above; accepting anything else could dispatch a sealed
     call through authority that did not exist when its turn was admitted. *)
  let recover_catalog ~kind ~model ~sealed_declarations catalogs =
    match
      List.filter
        (fun catalog -> declarations_equal catalog sealed_declarations)
        catalogs
    with
    | [ catalog ] -> catalog
    | [] ->
        invalid_arg
          (Format.asprintf
             "cannot recover %s execution for model %a: sealed tool \
              declarations match no executable catalog"
             kind Mentat_llm.Model.pp model)
    | _ ->
        invalid_arg
          (Format.asprintf
             "cannot recover %s execution for model %a: sealed tool \
              declarations match multiple executable catalogs"
             kind Mentat_llm.Model.pp model)
  in
  (* The [~shell_tools] application builds the Build catalog family {e once} —
     the four full catalogs, the two read-only-workspace ones, and their union —
     so a caller that partial-applies it once (each driver's factory, the boot
     projection) reuses them across every turn instead of reconstructing them. *)
  let build_catalog_for ~shell_tools =
    let full = full_build_catalogs ~shell_tools in
    let read_only = read_only_workspace_build_catalogs ~shell_tools in
    let all = List.map snd full @ List.map snd read_only in
    fun ~model ~sealed_declarations ->
      match sealed_declarations with
      | Some declarations ->
          recover_catalog ~kind:"Build" ~model ~sealed_declarations:declarations
            all
      | None -> (
          let project_tools = project_tools_enabled t read_capability in
          match build_mode with
          | Cfg.Mode.Read_only -> List.assoc project_tools read_only
          | Cfg.Mode.Workspace_write | Cfg.Mode.Danger_full_access
          | Cfg.Mode.External_sandbox ->
              let wanted = (editor_family_for model, project_tools) in
              snd (List.find (fun (selection, _) -> selection = wanted) full))
  in
  (* The boot projection reads declarations only; build its catalog family once. *)
  let boot_build_catalog_for =
    build_catalog_for ~shell_tools:boot_shell_tools
  in
  let read_catalog_for ~kind ~model ~sealed_declarations catalogs =
    match sealed_declarations with
    | Some declarations ->
        recover_catalog ~kind ~model ~sealed_declarations:declarations
          (List.map snd catalogs)
    | None -> List.assoc (project_tools_enabled t read_capability) catalogs
  in
  (* The mode prompt is a host-provided developer instruction; Build carries
     none. Delegated executions carry no mode prompt; a delegated role slots its
     own subagent prompt at the same position (see [role_fragment]). *)
  let mode_fragment = function
    | Mentat_session.Contract.Mode.Build -> []
    | Mentat_session.Contract.Mode.Plan ->
        [ Mentat_llm.Message.developer Mentat_prompts.Modes.plan ]
    | Mentat_session.Contract.Mode.Review ->
        [ Mentat_llm.Message.developer Mentat_prompts.Modes.review ]
  in
  (* The environment facts rendered into the workspace fragment. The date reads
     the [MENTAT_NOW]-aware reference clock (deterministic under the env pin);
     the model label resolves the catalog display name; the platform is the
     process-wide {!platform} pair. All are sourced here at the composition
     root, never inside the engine. *)
  let environment_for ~model =
    let date =
      let ms = Mentat_session.Time.to_unix_ms (now_time t) in
      let tm = Unix.gmtime (Int64.to_float ms /. 1000.) in
      Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900)
        (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    in
    let model_label, model_cutoff =
      let id = Mentat_llm.Model.id model in
      match find_model_cached t (Mentat_provider.Selector.of_model model) with
      | Ok catalog_model ->
          let label =
            match Provider_model.display_name catalog_model with
            | Some name -> Printf.sprintf "%s (%s)" name id
            | None -> id
          in
          let cutoff =
            Option.map Provider_model.Month.to_string
              (Provider_model.knowledge_cutoff catalog_model)
          in
          (label, cutoff)
      | Error _ -> (id, None)
    in
    Mentat_context.Context.Environment.make ~date ~model:model_label
      ?model_cutoff ~platform:(Lazy.force platform) ()
  in
  (* Assemble the per-turn model-visible context: the loaded workspace context
     (system prompt, workspace block, AGENTS.md instructions), the mode prompt,
     then the skills catalog. Recomputed per selection, so a mid-session edit to
     AGENTS.md or the skill set takes effect at the next turn. *)
  let context_prelude ~model ~mode_fragments =
    let skills = load_skills () in
    (* [Context.prelude] is the one assembly shared with the offline prompt
       inspector. A load failure (impossible here, where cwd and root are the
       same canonical path) degrades to no workspace context rather than
       aborting the turn, keeping only the mode and skills fragments. *)
    let fragments =
      match
        Mentat_context.Context.load ~environment:(environment_for ~model)
          ~stdenv:t.shared.stdenv ~nested_scan:false ~config:t.config
          ~trusted:t.trusted ~root:t.root ~cwd:t.root ~user_config_file
      with
      | Ok context ->
          Mentat_context.Context.prelude context ~developer:mode_fragments
            ~skills
      | Error _ ->
          mode_fragments
          @ Option.to_list (Mentat_context.Skills.catalog_fragment skills)
    in
    match Mentat_llm.Request.Prelude.make fragments with
    | Ok prelude -> prelude
    | Error _ -> Mentat_llm.Request.Prelude.empty
  in
  (* The between-turns reminder: an ephemeral, engine-authored prelude
     fragment listing the session's running background processes, so the model
     knows what it left running and can stop what it no longer needs. It states
     the running set and nothing more: a standing instruction to read output
     turns every request into an invitation to poll a handle that usually has
     nothing new, which spends the turn's steps without advancing the task.
     Read from the per-session registry at turn preparation (below), it is
     never journaled — a resumed session's empty registry emits nothing, so a
     dropped note changes no durable projection. *)
  let reminder_fragments registry =
    match Tools.Shell.Registry.running registry with
    | [] -> []
    | views ->
        let elide command =
          if String.length command <= 60 then command
          else String.sub command 0 57 ^ "..."
        in
        let line (view : Tools.Shell.Registry.View.t) =
          Printf.sprintf "- %s: %s" view.Tools.Shell.Registry.View.handle
            (elide view.Tools.Shell.Registry.View.command)
        in
        [
          Mentat_llm.Message.developer
            (Printf.sprintf
               "Background shell processes still running in this session. Stop \
                one with shell_kill(handle) when you no longer need it.\n\
                %s"
               (String.concat "\n" (List.map line views)));
        ]
  in
  (* The live background-process view for a session's shell registry: its
     running set, mapped from the workspace-io liveness to the protocol view.
     Derived on demand, never persisted; shared by the root and delegated
     execution factories, each over its own per-session registry. *)
  let running_view registry () =
    List.map
      (fun (view : Tools.Shell.Registry.View.t) ->
        let status =
          match view.Tools.Shell.Registry.View.status with
          | Mentat_workspace_io.Command.Session.Running ->
              Mentat_protocol.Process.Status.Running
          | Mentat_workspace_io.Command.Session.Exited (`Exited code) ->
              Mentat_protocol.Process.Status.Exited code
          | Mentat_workspace_io.Command.Session.Exited (`Signaled signal) ->
              Mentat_protocol.Process.Status.Signaled signal
          | Mentat_workspace_io.Command.Session.Terminated ->
              Mentat_protocol.Process.Status.Terminated
        in
        let age_ms =
          max 0
            (int_of_float
               (Mtime.Span.to_float_ns view.Tools.Shell.Registry.View.since
               /. 1_000_000.))
        in
        Mentat_protocol.Process.View.make
          ~handle:view.Tools.Shell.Registry.View.handle
          ~command:view.Tools.Shell.Registry.View.command ~status ~age_ms)
      (Tools.Shell.Registry.running registry)
  in
  (* A session's shell tool family, bound to a per-session registry over the
     sealed [build_capability]: the foreground [shell] and the two background
     [shell_output]/[shell_kill] tools that close over the registry. Built by
     both the root and delegated factories so each session's background
     processes are supervised on its own switch. *)
  let session_shell_tools_over registry =
    [
      Tools.Shell.make ~registry ~on_timeout:dune_stall_report
        build_capability ~clock
        ~shell:(Cfg.Resolved.get Cfg.Field.shell t.config);
      Tools.Shell.Shell_output.make registry;
      Tools.Shell.Shell_kill.make registry;
    ]
  in
  (* The Build-family per-turn selector shared by the root factory and the
     generic delegated factory: identical catalogs, policies, and prelude across
     the three modes, differing only in the write-mode workspace capability the
     caller passes — the root's watched {!build_workspace} versus the generic
     delegate's watchless {!delegated_build_workspace} twin, the sole Build-arm
     difference. The session's Build catalog family is built once over [registry],
     not per turn. *)
  let build_selector ~build_workspace ~registry =
    let session_shell_tools = session_shell_tools_over registry in
    let session_build_catalog_for =
      build_catalog_for ~shell_tools:session_shell_tools
    in
    fun ~configured ~model ~sealed_declarations mode ->
      let catalog, workspace, policy =
        match mode with
        | Mentat_session.Contract.Mode.Build ->
            ( session_build_catalog_for ~model ~sealed_declarations,
              build_workspace,
              configured.Engine_config.policy )
        | Mentat_session.Contract.Mode.Plan ->
            ( read_catalog_for ~kind:"Plan" ~model ~sealed_declarations
                plan_catalogs,
              read_workspace,
              read_only_policy )
        | Mentat_session.Contract.Mode.Review ->
            ( read_catalog_for ~kind:"Review" ~model ~sealed_declarations
                review_catalogs,
              read_workspace,
              read_only_policy )
      in
      Engine.Execution.make ~catalog ~workspace ~policy
        ~prelude:
          (context_prelude ~model
             ~mode_fragments:(mode_fragment mode @ reminder_fragments registry))
  in
  (* Per-session factory: the driver applies this to its own nested
     per-session switch once. The background-process registry and the three
     background tools that close over it are built here, so they live for the
     session and die leader-only when the driver's switch releases. The spawn
     stays tool-side over the sealed [build_capability]; the engine supplies only
     the scope (the switch) and, through the registry, the handle namespace. *)
  let execution_for_mode ~background:session_sw =
    let registry = Tools.Shell.Registry.create ~sw:session_sw in
    let select = build_selector ~build_workspace ~registry in
    (select, running_view registry)
  in
  (* A delegated child's role, when present, slots its specialized subagent
     prompt as a developer fragment at the mode-prompt position (fragment 4:
     after the workspace context, before the skills catalog). A roleless child
     is a generic delegate with no such fragment, exactly today's behavior. *)
  let role_fragment role =
    match role with
    | None -> []
    | Some role ->
        let prompt =
          match role with
          | Mentat_session.Delegation.Role.Explore ->
              Mentat_prompts.Subagents.explore
          | Mentat_session.Delegation.Role.Review ->
              Mentat_prompts.Subagents.review
          | Mentat_session.Delegation.Role.Verify ->
              Mentat_prompts.Subagents.verify
        in
        [ Mentat_llm.Message.developer prompt ]
  in
  (* The delegated execution factory. Like {!execution_for_mode} the driver
     applies it to its own nested per-session switch once, yielding a per-turn
     selector and a background-process view.

     A roleless (generic) delegate is a peer of a top-level Build session: the
     same Build catalog family (write tools, shell, background processes) over a
     per-child registry on its own switch, the same sealed [build_capability]
     (through the watchless {!delegated_build_workspace} write twin), and the
     same configured permission policy — so it edits the workspace directly and
     its high-impact actions reach the same review the parent's would. Parallel
     generic children share one workspace and are not isolated; a spawner must
     give each a disjoint file set.

     A role delegate (explore/review/verify) stays a read-only specialist: the
     read-only catalog, the read twin, and the read-only policy, with its
     subagent prompt slotted at the mode-prompt position. It runs no background
     processes, so its registry stays empty and its view is empty. *)
  let delegated_execution ~role ~background:session_sw =
    match role with
    | Some _ ->
        let select ~configured:_ ~model ~sealed_declarations _mode =
          Engine.Execution.make
            ~catalog:
              (read_catalog_for ~kind:"delegated" ~model ~sealed_declarations
                 delegated_catalogs)
            ~workspace:read_workspace ~policy:read_only_policy
            ~prelude:
              (context_prelude ~model ~mode_fragments:(role_fragment role))
        in
        (select, fun () -> [])
    | None ->
        let registry = Tools.Shell.Registry.create ~sw:session_sw in
        let select =
          build_selector ~build_workspace:delegated_build_workspace ~registry
        in
        (select, running_view registry)
  in
  (* The per-mode declaration projection an inspector reads: the boot-fixed
     catalog for a mode and model, with no sealed snapshot to recover against. *)
  let declarations_for ~mode ~model =
    match mode with
    | Mentat_session.Contract.Mode.Build ->
        Engine.Catalog.declarations
          (boot_build_catalog_for ~model ~sealed_declarations:None)
    | Mentat_session.Contract.Mode.Plan ->
        Engine.Catalog.declarations
          (read_catalog_for ~kind:"Plan" ~model ~sealed_declarations:None
             plan_catalogs)
    | Mentat_session.Contract.Mode.Review ->
        Engine.Catalog.declarations
          (read_catalog_for ~kind:"Review" ~model ~sealed_declarations:None
             review_catalogs)
  in
  Ok
    {
      build_capability;
      read_capability;
      shell;
      execution_for_mode;
      delegated_execution;
      declarations_for;
    }

(* User-command discovery for the client's completion and expansion queries. A
   fresh snapshot per call so a just-added command file appears immediately, over
   the same config/trust/root inputs the run's engine sees. The two responders
   are injected into [Client.make] rather than the [Driver.t] record so a backend
   that builds a driver without command support links unchanged. *)
let commands_snapshot t =
  let user_config_file =
    Lpath.Abs.of_string_exn (User_dirs.config_file t.shared.dirs)
  in
  Mentat_context.Commands.load ~stdenv:t.shared.stdenv ~config:t.config
    ~trusted:t.trusted ~root:t.root ~user_config_file

let user_command_scope = function
  | Mentat_context.Commands.Command.Project
  | Mentat_context.Commands.Command.Compat_agents
  | Mentat_context.Commands.Command.Compat_claude ->
      Mentat_protocol.User_command.Project
  | Mentat_context.Commands.Command.User -> Mentat_protocol.User_command.User

let user_commands_responder t () =
  let summaries =
    Mentat_context.Commands.commands (commands_snapshot t)
    |> List.filter_map (fun command ->
        match Mentat_context.Commands.Command.status command with
        | Mentat_context.Commands.Command.Active content -> (
            match
              Mentat_protocol.User_command.Name.of_string
                (Mentat_context.Commands.Command.name command)
            with
            | Error _ -> None
            | Ok name ->
                Some
                  {
                    Mentat_protocol.User_command.name;
                    description =
                      content.Mentat_context.Commands.Command.description;
                    argument_hint =
                      content.Mentat_context.Commands.Command.argument_hint;
                    scope =
                      user_command_scope
                        (Mentat_context.Commands.Command.kind command);
                  })
        | Mentat_context.Commands.Command.Shadowed _
        | Mentat_context.Commands.Command.Disabled _
        | Mentat_context.Commands.Command.Invalid _ ->
            None)
  in
  let scope_rank = function
    | Mentat_protocol.User_command.Project -> 0
    | Mentat_protocol.User_command.User -> 1
  in
  Ok
    (List.stable_sort
       (fun a b ->
         let by_scope =
           Int.compare
             (scope_rank a.Mentat_protocol.User_command.scope)
             (scope_rank b.Mentat_protocol.User_command.scope)
         in
         if by_scope <> 0 then by_scope
         else
           Mentat_protocol.User_command.Name.compare
             a.Mentat_protocol.User_command.name
             b.Mentat_protocol.User_command.name)
       summaries)

let expand_command_responder t ~name ~arguments =
  (* Frontends intercept only known (valid) command tokens, so a malformed name
     never reaches here; the parse guards are defensive. *)
  match Mentat_protocol.User_command.Name.of_string name with
  | Error message -> Error (Mentat_protocol.Error.unavailable message)
  | Ok wire_name -> (
      match Mentat_context.Commands.Name.of_string name with
      | Error message -> Error (Mentat_protocol.Error.unavailable message)
      | Ok command_name -> (
          match
            Mentat_context.Commands.expand (commands_snapshot t)
              ~name:command_name ~arguments
          with
          | Ok content -> Ok content
          | Error (`Unknown _) ->
              Error (Mentat_protocol.Error.Unknown_command wire_name)
          | Error
              (`File_unresolved
                 (file_error : Mentat_context.Commands.file_error)) ->
              Error
                (Mentat_protocol.Error.File_unresolved
                   {
                     path = file_error.Mentat_context.Commands.path;
                     reason = file_error.Mentat_context.Commands.reason;
                   })))

(* The raw multi-source driver record and the two execution-layer handles the
   TUI needs alongside it, built once and cached in [t.assembled]. It assembles
   the engine (cached in [t.engine]) and fills the composition-root cones. The
   [Client.Driver.t] it yields is the construction seam, not a frontend API: only
   [bin] and (the daemon's) [mentat.server] ever hold it, and both wrap or serve
   it — a frontend only ever sees a {!Mentat_client.t}. *)
let build_driver t :
    ( Client.Driver.t * Mentat_workspace_io.t * Mentat_tool.t,
      Exit_status.t )
    result =
  let ( let* ) = Result.bind in
  let* {
         build_capability;
         read_capability;
         shell;
         execution_for_mode;
         delegated_execution;
         declarations_for = _;
       } =
    build_execution_layer t
  in
  let build_product_rules = product_rules build_capability in
  (* The store adapter's online revert cone applies through the build capability
     and captures a [Before_revert] boundary into the same snapshot store the
     engine's turn checkpoints use. A notice-free workspace value is enough — the
     checkpoint is all revert needs from it. *)
  let revert_workspace =
    Workspace_adapter.make ~store:(snapshot_store t)
      ?self_prefix:(snapshot_self_prefix t) build_capability
  in
  let store_port =
    Store_adapter.make ~sw:t.switch ~root:t.shared.store ~owner:t.owner
      ~now:(fun () -> now_time t)
      ~merge:(configured_revert_merge t)
      ~capability:build_capability
      ~checkpoint:revert_workspace.Mentat_agent.Ports.checkpoint
      ~new_id:Session_meta.fresh_revert_id
  in
  let base_provider_call = make_provider_call t in
  (* Vision gate (backstop to the frontend pre-warning): strip a media block the
     active (channel, API, model) cannot carry to a text placeholder, so a
     non-vision model or a media-incapable channel degrades gracefully instead of
     hard-failing at the provider. The catalog and encodability table live here,
     not in the ports-only engine. *)
  let provider_call request ~on_event ~on_download ~cancelled =
    let request = Media_strip.apply ~catalog:(catalog t) request in
    base_provider_call request ~on_event ~on_download ~cancelled
  in
  let max_children =
    Cfg.Resolved.get Cfg.Field.run_subagent_max_concurrent t.config
  in
  let engine =
    Engine.create ~sw:t.switch ~store:store_port ~provider:provider_call
      ~config:(config_callback t ~product_rules:build_product_rules)
      ~now:(fun () -> now_time t)
      ~max_children ~execution_for_mode ~delegated_execution ()
  in
  t.engine <- Some engine;
  let driver_record : Client.Driver.t =
    {
      Client.Driver.session = session_cone t engine;
      accounts = accounts_cone t;
      settings = settings_cone t;
      lifecycle = lifecycle_cone t;
      review = review_cone t build_capability ~base_spec:(review_base_spec t);
      workspace =
        workspace_cone t build_capability ~base_spec:(review_base_spec t);
    }
  in
  Ok (driver_record, read_capability, shell)

let assemble t =
  match t.assembled with
  | Some assembled -> Ok assembled
  | None -> (
      match build_driver t with
      | Ok assembled ->
          t.assembled <- Some assembled;
          Ok assembled
      | Error status -> Error status)

let driver t = Result.map (fun (driver, _, _) -> driver) (assemble t)

(* The executable's half of the image-attach flow: it holds the file read, the
   platform downscale spawn, and the fence-free attachment store the pure App and
   the engine lack. Reads the configured caps from this instance's resolved
   config (image caps are user-owned, so process-global). *)
let attach_responder t ~session source =
  let caps =
    {
      Mentat_protocol.Attach.max_bytes =
        Cfg.Resolved.get Cfg.Field.image_max_bytes t.config;
      max_dimension = Cfg.Resolved.get Cfg.Field.image_max_dimension t.config;
      max_count = Cfg.Resolved.get Cfg.Field.image_max_count t.config;
    }
  in
  let read_path path =
    let abs =
      Filename.concat
        (Lpath.Abs.to_string t.root)
        (Lpath.Rel.to_string (Mentat_workspace.Path.rel path))
    in
    match Fs.read_capped ~max_bytes:(64 * 1024 * 1024) abs with
    | Ok (Some bytes) -> Some bytes
    | Ok None | Error _ -> None
  in
  Image_attach.attach ~store:t.shared.store ~caps
    ~downscale:(Image_downscale.run ~stdenv:t.shared.stdenv)
    ~read_path ~session source

(* A client attached to a remote daemon cannot store into the daemon's store from
   here; image attach over the wire is the daemon campaign's to wire. *)
let attach_declined ~session:_ _source =
  Error
    (Mentat_protocol.Attach.Error.Unavailable
       (Mentat_diagnostic.make
          "image attach is not supported over a remote daemon connection"))

let client_with_tui_capabilities t =
  Result.map
    (fun (driver, read_capability, shell) ->
      ( Client.make
          ~user_commands:(user_commands_responder t)
          ~expand_command:(expand_command_responder t)
          ~attach:(attach_responder t) driver,
        read_capability,
        shell ))
    (assemble t)

let client t =
  Result.map (fun (client, _, _) -> client) (client_with_tui_capabilities t)

(* Wrap a driver the daemon filled over the wire with this workspace's {b local}
   command expansion, so an attached client's [/name] completion and expansion
   read the same local command files an in-process client would. The responders
   are engine-free (they read the command snapshot), so they hold for a remote
   engine. *)
let attach_client t driver =
  Client.make
    ~user_commands:(user_commands_responder t)
    ~expand_command:(expand_command_responder t)
    ~attach:attach_declined driver

(* The execution-layer-only projection the [--attach] path needs: the read-only
   workspace capability (root-relative file completion) and the local-user shell
   definition, with no engine — the engine is remote when attached, but
   completion and the local shell stay local. Like {!tool_declarations} it
   re-seals the execution layer per call and caches nothing, and the same
   authority-boundary discipline as {!client_with_tui_capabilities} applies:
   callers project the narrow operations they need and never pass either
   capability into a frontend model. *)
let tui_capabilities t :
    (Mentat_workspace_io.t * Mentat_tool.t, Exit_status.t) result =
  Result.map
    (fun layer -> (layer.read_capability, layer.shell))
    (build_execution_layer t)

(* Offline: the execution layer seals the workspaces and builds the catalog
   families, but no engine, provider, store adapter, or client. Each call
   re-seals; a debug command pays that once and never caches a client. *)
let tool_declarations t ~mode ~model =
  Result.map
    (fun layer -> layer.declarations_for ~mode ~model)
    (build_execution_layer t)
