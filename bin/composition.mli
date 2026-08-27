(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The composition root.

    [mentat]'s sole composition root and the only place effects are wired.
    {!with_base} performs the fail-closed startup staging — user config, trust,
    provider runtime, and the session store — inside one Eio run and switch, and
    hands a command a {!t}. The heavier engine assembly (the sandbox seal, the
    workspace capability, the engine, and the full {!Mentat_client.t}) is built
    on demand by {!client}: a command that needs only config, credentials, the
    catalog, or the store never pays for it, and a platform that cannot seal a
    sandbox still runs those commands.

    The multi-source client driver is assembled here: the engine fills the
    session cone ({!Mentat_agent.driver}); this root fills the account,
    settings, and lifecycle cones over the provider runtime, an executable-owned
    per-session model/review overlay, and the store's metadata surface. The
    overlays are process-local: successful fork and rewind copy them, archive
    and restore preserve them, successful create and delete clear them, and a
    new process starts from resolved configuration. *)

type t
(** The staged base: directories, resolved config, provider runtime, the opened
    session store, one captured process environment, and the ambient Eio
    capabilities. The provider catalog is derived from the runtime; the
    credential store is read only by account-consuming operations. *)

val with_base :
  cwd:string option ->
  overrides:Mentat_config.t list ->
  ?data_home:string ->
  ?review_base:string ->
  (t -> Exit_status.t) ->
  Exit_status.t
(** [with_base ~cwd ~overrides ?data_home ?review_base f] stages the base for a
    workspace rooted at [cwd] (the process directory when [None]), runs [f]
    under one Eio switch, and returns its exit status. A staging failure
    (unresolvable directories, malformed user config, an unopenable store) is a
    {!Exit_status.Runtime_error} and [f] never runs.

    [data_home] overrides the account data home the session store opens under —
    the seam an ephemeral run uses to place its throwaway store beneath a
    caller-owned temporary directory. Absent, the store lives under the resolved
    data home like every other command. Only the store root moves; config,
    trust, and credentials still resolve from the account home.

    [review_base] is the base revision spec the review cone diffs the worktree
    against — the [mentat review BASE] argument. Absent, the review base falls
    back to [MENTAT_REVIEW_BASE] and then [HEAD]. It is the clean threading path
    for a review command, so callers need not set an environment variable. *)

(** {1:daemon Daemon composition}

    A daemon composes per-user {!shared} state once, then one {!t} instance per
    workspace over it. {!with_base} above is the equivalent single-workspace
    fusion — it stages the same things in the same order and packs the two
    records over one switch — so every existing command is unaffected by this
    split. *)

type shared = {
  dirs : User_dirs.t;
  runtime : Mentat_provider_runtime.t;
  store : Mentat_store.t;
  environment : (string * string) list;
  stdenv : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
}
(** The per-user state a daemon opens once and shares across every workspace
    instance: the captured process environment, the resolved user directories,
    the provider runtime, {b the single opened session store}, the ambient
    stdenv, and the switch that owns them.

    {b One-store-handle invariant.} Exactly one [Mentat_store.t] is ever opened
    on a given store root within one process, and it is this one. The run lock's
    same-process fence half is a reservation per opened root handle, so two
    handles in one process would each [lockf] the same inode — which POSIX
    record locks never conflict between — and the fence would be void. The raw
    store-opening stage is private to {!stage_shared}, so a second same-root
    open is unrepresentable from outside this module; hold this [store] and
    reuse it. *)

val stage_shared :
  stdenv:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  ?data_home:string ->
  unit ->
  (shared, Exit_status.t) result
(** [stage_shared ~stdenv ~sw ?data_home ()] stages the shared state under the
    owning switch [sw]: the user directories, the provider runtime, and the one
    opened store — the same dirs, runtime, and store stages {!with_base} runs,
    in that order. [data_home] overrides the store root exactly as
    {!with_base}'s does. A staging failure (unresolvable directories, an
    unopenable store) is an {!Exit_status.Runtime_error}. *)

val instance :
  shared ->
  sw:Eio.Switch.t ->
  cwd:string option ->
  overrides:Mentat_config.t list ->
  ?environment:(string * string) list ->
  ?review_base:string ->
  unit ->
  (t, Exit_status.t) result
(** [instance shared ~sw ~cwd ~overrides ?environment ?review_base ()] stages
    one workspace instance over [shared]: the canonical root for [cwd] (the
    process directory when [None]), its trust verdict, and its config with
    [overrides] layered, under the instance's own switch [sw]. No store is
    opened — the shared handle is reused, which is what keeps the fence's
    same-process half honest. The engine, watch lane, and dune-RPC producer
    built on demand live under [sw], so evicting the instance is one {!shutdown}
    then closing [sw]. [environment] is the ambient environment the instance
    resolves against — config env overrides, toolchain and account discovery,
    and the workspace resolution that constructs the exact child environment; it
    defaults to [shared]'s process snapshot, and a daemon passes the invoking
    client's snapshot instead so the child is configured from the shell that
    asked for the run, not the shell that spawned the daemon. [review_base] is
    the review cone's base spec, as in {!with_base}. A staging failure (an
    unresolvable root, malformed config) is an {!Exit_status.Runtime_error}. *)

val shutdown : t -> unit
(** [shutdown t] shuts down [t]'s engine drivers when the client was built,
    settling durable-first and leaving parked decisions intact; a no-op when no
    engine was assembled. {!with_base} calls it before its switch closes; a
    daemon's eviction sweep calls it before closing an instance's switch. *)

val retained_hub_count : t -> int
(** [retained_hub_count t] is the number of sessions [t]'s engine currently
    retains a hub for (a driver attached or a feed open); [0] when no engine was
    assembled. The daemon's eviction sweep reads it as the third of the three
    zeros — an instance with no bound connections, no in-flight call, and no
    retained hub is idle and evictable. *)

(** {1:accessors Base accessors} *)

val dirs : t -> User_dirs.t
val root : t -> Lpath.Abs.t
val trusted : t -> bool
val config : t -> Mentat_config.Resolved.t
val runtime : t -> Mentat_provider_runtime.t

val catalog : t -> Mentat_provider.Catalog.t
(** [catalog t] is the declaration catalog owned by [t]'s provider runtime. *)

val store : t -> Mentat_store.t

val snapshot_store : t -> Mentat_store.Capture.Store.t
(** [snapshot_store t] is the per-workspace content-addressed capture store,
    keyed by the workspace root and resolved under the opened session store root
    — the same keyed home the engine's checkpoint captures write into, so an
    offline revert's [Before_revert] capture and the engine's turn captures
    share one store. Construction is pure. *)

val snapshot_self_prefix : t -> Lpath.Rel.t option
(** [snapshot_self_prefix t] is the workspace-relative path of the data home
    when it lies inside the workspace, pruned from every capture so the capture
    system never captures its own sidecar; [None] otherwise. *)

val getenv : t -> string -> string option
(** [getenv t name] looks up [name] in [t]'s captured environment. If an
    [execve]-supplied environment contains duplicate assignments, the first
    assignment in the captured array wins. It never observes later process
    environment mutation. *)

val environment : t -> (string * string) list
(** [environment t] is the one process-environment snapshot used for startup
    configuration, provider discovery, and issuer routing. *)

val stdenv : t -> Eio_unix.Stdenv.base
val sw : t -> Eio.Switch.t
val owner : t -> Mentat_store.Run_lock.Owner.t
val now_time : t -> Mentat_session.Time.t

val discover_accounts :
  t ->
  ( Mentat_provider.Account.Discovery.t list,
    Mentat_provider_runtime.Store_error.t )
  result
(** [discover_accounts t] reads the current credential store and resolves one
    discovery value per provider against [t]'s captured process environment.
    Provider-local failures remain entries; a shared store failure is the outer
    [Error]. No startup account cache is consulted. *)

(** {1:overrides Per-provider base-URL and issuer overrides}

    The executable-owned reads: the single place a provider's base URL and
    issuer override are resolved, from config and environment. *)

val base_url_for : t -> Mentat_llm.Provider.t -> string option
(** [base_url_for t provider] is [provider]'s configured API base URL, if any.
*)

val auth_base_url_for : t -> Mentat_llm.Provider.t -> string option
(** [auth_base_url_for t provider] is [provider]'s issuer override from
    [MENTAT_<PROVIDER>_AUTH_BASE_URL], if set to a non-empty value. *)

(** {1:client The assembled client} *)

val client : t -> (Mentat_client.t, Exit_status.t) result
(** [client t] is the full frontend client, engine included, built once and
    cached. [Error] when the workspace capability cannot resolve (an unsupported
    sandbox posture, an inadmissible root) — the engine-coupled commands then
    fail while the base commands keep working. Derived model selection is not
    cached here: the engine resolves it from live account discovery at each turn
    boundary. *)

val attach_client : t -> Mentat_client.Driver.t -> Mentat_client.t
(** [attach_client t driver] wraps a [driver] the daemon filled over the wire
    (via [--attach]) into a frontend client, giving it [t]'s {b local} command
    expansion — [/name] listing and expansion read this workspace's own command
    files, exactly as an in-process client's do. The engine behind [driver] is
    remote; the command responders are engine-free, so they stay local. Used
    only on the attach path; the in-process path builds its client through
    {!client}. *)

val driver : t -> (Mentat_client.Driver.t, Exit_status.t) result
(** [driver t] is the raw multi-source driver record — the construction seam,
    {b not} a frontend API. It builds and caches the same engine and cones
    {!client} does (they share the one assembly), but yields the
    {!Mentat_client.Driver.t} unwrapped. Only [bin] and (the daemon's)
    [mentat.server] ever hold it: [bin] wraps it with {!Mentat_client.make} and
    the daemon serves it over the wire, so a frontend only ever receives a
    {!Mentat_client.t}. [Error] exactly as {!client}'s prefix. *)

val tool_declarations :
  t ->
  mode:Mentat_session.Contract.Mode.t ->
  model:Mentat_llm.Model.t ->
  (Mentat_llm.Tool.t list, Exit_status.t) result
(** [tool_declarations t ~mode ~model] is the boot-fixed, provider-facing tool
    declarations a run in [mode] with [model] would seal — the same catalog
    family {!client} builds — projected offline. It seals the workspace
    capabilities and resolves the toolchain, but constructs no engine, provider,
    store adapter, or client, and never caches one. [Error] when the workspace
    cannot seal, exactly as {!client}'s prefix does. The declarations reflect
    boot-time program resolution but do not depend on the resolved program
    paths, which live in the tool handlers rather than the declarations. *)

val client_with_tui_capabilities :
  t ->
  ( Mentat_client.t * Mentat_workspace_io.t * Mentat_tool.t,
    Exit_status.t )
  result
(** [client_with_tui_capabilities t] is the cached client together with the
    exact read-only workspace capability and shell tool definition assembled for
    that client. This executable-private projection exists for the TUI's
    root-relative file completion and local-user shell closures: callers must
    project the narrow operations they need and must not pass either capability
    into a frontend model. It never resolves a second workspace authority,
    rebuilds the shell definition, or copies a root spelling into an authority
    interface. *)

val tui_capabilities :
  t -> (Mentat_workspace_io.t * Mentat_tool.t, Exit_status.t) result
(** [tui_capabilities t] is the execution-layer-only projection the [--attach]
    path needs: the read-only workspace capability for root-relative file
    completion and the local-user shell tool definition, with {b no} engine —
    when attached the engine is remote, but completion and the local shell stay
    local. It is exactly the two handles {!client_with_tui_capabilities} returns
    beyond the client. Like {!tool_declarations} it re-seals the execution layer
    per call and caches nothing, and the same authority-boundary discipline as
    {!client_with_tui_capabilities} applies: project the narrow operations you
    need and never pass either capability into a frontend model. *)

val find_model :
  t -> Mentat_provider.Selector.t -> (Mentat_provider.Model.t, string) result
(** [find_model t selector] resolves [selector] against the catalog and, for a
    provider whose model set is server-owned, against the provider's retained
    server listing through the declaration's listed-model rule — the same
    synthesis readiness rows use, so a pickable row cannot die at resolution
    time. A miss on a checkable provider refreshes the listing once and
    retries; a path whose retained listing already answers never reaches the
    network. *)

val resolve_model : t -> string -> (Mentat_provider.Model.t, string) result
(** [resolve_model t input] is {!find_model} for CLI selector text, sharing
    [Mentat_provider.Catalog.resolve]'s parse and candidate diagnostics. *)

val default_model : t -> (Mentat_llm.Model.t, string) result
(** [default_model t] is the resolved main model for [t]. A configured [model]
    selector is resolved through the catalog and then passed to
    {!Mentat_provider.Selection.main} as its preferred model, so a deprecated or
    unavailable configured model surfaces the structured requirement mismatch
    instead of being run; with no configured model, selection reads live
    discoveries and prefers a connected provider. The configured [reasoning]
    effort is part of the selection requirement, so an unsupported explicit
    combination fails before a provider request. A configured model does not
    read the credential store here because preference selection never consults
    provider connectivity. Used for headless model resolution and the engine
    config callback. *)

val default_catalog_model : t -> (Mentat_provider.Model.t, string) result
(** [default_catalog_model t] is {!default_model}'s catalog model — the same
    resolution, before projecting to the [mentat.llm] identity — so the caller
    can read the effective model's advertised capabilities. Used by the headless
    [--output-schema] capability gate. *)

val small_model : t -> (Mentat_llm.Model.t, string) result
(** [small_model t] is the resolved auxiliary small model for [t]: the model the
    cheap side-call roles (session auto-titling) run on. A configured
    [small_model] selector is resolved through the catalog and adopted when it
    stays selectable; a missing selector, an unresolvable one, or an unavailable
    model all fall back to {!default_model}, so the small role never fails a run
    that the main model itself can start. The error case is exactly
    {!default_model}'s: the small role has no model only when the main role has
    none either. Used by the executable-side auto-title flow. *)

val small_model_completion :
  t -> system:string -> user:string -> (string, string) result
(** [small_model_completion t ~system ~user] runs one non-streaming completion
    on the resolved {!small_model}: [system] is the sole prelude message and
    [user] the sole transcript message. It declares no tools, caps output
    tokens, does not stream, and returns the assistant's concatenated text. It
    is the cheap side-call primitive behind session auto-titling. The error is a
    human-readable message — a small-model resolution failure, a
    request-construction diagnostic, or the provider error's message — and a
    caller treats any error as "no result" and keeps its own fallback rather
    than surfacing it. *)

val provider_credential_optional : t -> Mentat_llm.Provider.t -> bool
(** [provider_credential_optional t provider] is [true] iff [provider]'s
    declaration does not require a credential (local, ollama), so a missing one
    is not a failure. *)

val provider_auth_satisfied :
  t -> Mentat_llm.Provider.t -> (bool, Mentat_provider_runtime.Error.t) result
(** [provider_auth_satisfied t provider] always performs live discovery for the
    selected provider. It is [Ok true] for a connected account, and also for an
    honestly [Missing] account when the provider declaration makes credentials
    optional; it is [Ok false] for a mandatory credential that is absent. A
    provider-local resolution failure is [Error (Credential _)] and a shared
    store failure is [Error (Store _)], so optional authentication never lowers
    an invalid candidate to absence. *)

(** {1:editor The Build editor-tool family}

    The [tools.editor] + model decision, declared once at the composition root
    and consumed by the real assembly and the [debug model] inspector, so the
    sealed catalog and its explanation cannot drift. *)

module Editor_family : sig
  type t =
    | Apply_patch
    | String_replace
        (** The Build editor-tool family a run seals: the whole-file
            [apply-patch] tool, or the [write_file]/[edit_file] string-replace
            pair. *)

  (** Why a family was chosen. The variant carries the machine reason; a
      renderer maps it to a human string, keeping the presentation out of the
      policy. *)
  type decision =
    | Configured of t  (** [tools.editor] pinned the family outright. *)
    | Auto_capable  (** [auto]: the resolved model supports apply-patch. *)
    | Auto_incapable  (** [auto]: the resolved model lacks apply-patch. *)
    | Auto_no_model  (** [auto]: no model resolved. *)

  val family : decision -> t
  (** [family d] is the editor family [d] resolves to. *)
end

val editor_family :
  t -> Mentat_provider.Model.t option -> Editor_family.decision
(** [editor_family t model] is the Build editor-family decision for [model] (a
    resolved catalog model, or [None] when none resolved). [tools.editor] pins
    the family for the [apply-patch]/[string-replace] values; [auto] resolves it
    from [model]'s apply-patch capability, treating an absent model as
    incapable. Raises [Invalid_argument] on an out-of-vocabulary [tools.editor]
    (the config field's closed vocabulary makes this unreachable). *)

val configured_revert_merge : t -> bool
(** [configured_revert_merge t] is the [revert.merge] config value: whether a
    revert of a superseded selection three-way merges rather than refusing.
    Defaults to [true]. *)

val configured_sandbox_mode : t -> Mentat_config.Mode.t
(** [configured_sandbox_mode t] is the configured Build sandbox posture,
    defaulting an absent [sandbox.mode] to
    {!Mentat_config.Mode.Workspace_write}. Build capability resolution and
    CLI/TUI posture rendering consume this single product default. It is not the
    mode of the separately resolved read-only capability used by Plan, Review,
    delegated execution, and TUI file completion. *)

val resolve_workspace :
  t ->
  mode:Mentat_config.Mode.t ->
  network:Mentat_sandbox.Policy.Network.t ->
  (Mentat_workspace_io.t, Exit_status.t) result
(** [resolve_workspace t ~mode ~network] seals a workspace capability for the
    exact authority pair supplied by the caller, together with the configured
    read scope and roots. The explicit pair keeps the configured build
    capability and the forced read-only capability distinguishable at their call
    sites. [sandbox status] and [sandbox explain] pass the configured pair and
    render the resulting identity, policy, evidence, and roots without
    assembling the engine. [Error] on a platform that cannot seal (a broad or
    inadmissible root), rendered as a clean runtime error (exit 1), never a
    crash. *)

(** {1:probe Doctor's probe}

    The same staging as {!with_base}, consumed per-stage instead of fail-closed.
    Each stage runs independently and a failure is a field, not an abort — so
    [doctor] reports a broken config or store rather than dying on it. *)

module Probe : sig
  type t
  (** The outcome of running every startup stage in probe mode. *)

  val config : t -> (string, string) result
  (** [config t] is [Ok config_file] if configuration resolved, else
      [Error reason]. *)

  val storage : t -> (string, string) result
  (** [storage t] is [Ok data_home] if the store staged (dir created over every
      [Unix_error], [sessions/] a directory), else [Error reason]. *)

  val state : t -> (string, string) result
  (** [state t] is [Ok state_home] — the root holding diagnostics logs and crash
      reports — or the reason the directory roots did not resolve. Reported so a
      user asked for their diagnostics trail can find it without knowing the XDG
      ladder; the directory is not staged, since nothing needs it to exist. *)

  val sessions : t -> (int * int, string) result
  (** [sessions t] is [Ok (stored, corrupt)] — the counts from a full store scan
      over the staged handle — or [Error reason] when the store did not stage. A
      non-zero [corrupt] is a genuine failure. *)

  val toolchain : t -> (string, string) result

  val parity : t -> (string, string) result
  (** [toolchain t] is [Ok detail] naming the resolved [dune] and its ladder
      rung when the OCaml toolchain resolves it, else [Error reason]. Absence is
      a warning, not a failure: a non-OCaml workspace needs no toolchain. *)

  val project : t -> (string, string) result
  (** [project t] is [Ok "dune project"] when a [dune-project] or
      [dune-workspace] marker is a regular file at the workspace root, else
      [Error reason]. It is the marker the tooling gate keys on, reported as
      project detection; the live build-health verdict is not read here. *)

  val trusted : t -> bool
  (** [trusted t] is whether the workspace is trusted (fail-closed to [false]).
  *)

  val accounts : t -> (Mentat_provider.Account.Discovery.t list, string) result
  (** [accounts t] is the live per-provider discovery batch, or the failed
      prerequisite/store diagnostic. *)

  val default_model : t -> (Mentat_llm.Model.t, string) result
  (** [default_model t] is the resolved main model, or the reason it could not
      resolve (including an unresolved configuration). *)

  val dune_lane : t -> (string, string) result
  (** [dune_lane t] is the build-watch posture the composition would gate —
      the mode and its targets — or the reason the lane is off (untrusted,
      no project marker, the knob). *)

  val lint : t -> (string, string) result
  (** [lint t] is the lint command and how it is reached — a path-shaped
      program as a workspace file, else the lock universe's built binary,
      else the sealed PATH, re-resolved by the runner at every settle — or
      why the lane is off or the command unreachable (settles are then
      skipped, never a lane death). *)
end

val with_probe :
  cwd:string option -> (Probe.t -> Exit_status.t) -> Exit_status.t
(** [with_probe ~cwd f] stages the base in probe mode (never aborting) and hands
    [f] the {!Probe.t}. Used by [doctor], which must diagnose the very
    conditions [with_base] fails closed on. *)
