(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The workspace filesystem and process capability.

    This library is the guarded boundary where mentat performs workspace IO —
    file, edit, and process effects beneath opened workspace roots — carrying
    and discharging the sealed [mentat.sandbox] at its launch edge: one abstract
    capability, {!type:t}, and three operation families over it. {!File}
    observes the workspace, {!Edit} applies native writes (the native-write
    enforcer), and {!Command} launches children (the single sealed process-spawn
    boundary). Of the two values the engine consumes over its workspace port,
    the notice vocabulary is {!Mentat_workspace.Notice} — pure data, owned by
    the pure workspace library — while {!Claim_scope}, the tool-claim
    attribution window opened with {!open_claim_scope}, is this library's own,
    because the window lives on the capability the native-write enforcer does.
    The library's one invariant:

    {e only this library can unwrap resolved workspace roots, perform native
       workspace writes, or lower a sealed sandbox and argv into a child
       process.}

    {b What this library does not own.} Path vocabulary — root keys,
    workspace-relative addresses, the protected-meta names — is
    [mentat.workspace]'s. Policy and seal — what a command may touch, profile
    generation, evidence, identity — are [mentat.sandbox]'s; this library only
    carries the sealed value and discharges its obligations at the launch edge.
    Blob and event persistence belong to the store, which consumes the results
    produced here. Scheduling belongs to the engine: this library never creates
    the turn's switch or cancellation context, and every child it spawns is
    owned by the switch the caller passes.

    {b Resolution binds everything together.} {!resolve} — the only constructor
    — canonicalizes each admitted root once and opens it as an Eio directory
    capability under the resolve switch, constructs the exact child environment
    (allow-list inheritance; ambient secrets and agent sockets stripped; nothing
    rewritten, so every variable a root is derived from is the one the child
    reads), and — for a confined mode — probes the platform backend once and
    seals the {!Mentat_sandbox.t} with the probe outcome injected; an unconfined
    mode seals the direct or declared-external route and probes nothing. Resume
    is resolution: a resumed session resolves again and compares {!identity}
    with {!Mentat_sandbox.Identity.equal}.

    {b Paths bind to opened roots.} Every workspace path — read target, edit
    target, command cwd — is re-bound to the {e most-specific opened root}
    containing it before any writability or protected-meta check, and then
    resolved beneath that root's opened capability, never through a fresh native
    spelling. There is no check-then-use window: roots are opened once, at
    resolution, and every later operation interprets its path beneath an
    already-opened capability. The strength of the launched cwd guarantee is
    tiered by backend, not rounded up: on the direct route the cwd handed to
    spawn is the opened capability itself, which Eio's backends open and
    [fchdir] before exec, so a pathname swapped between check and exec cannot
    redirect the child; Seatbelt runs the child in that same opened cwd but its
    policy binds by pathname; Bubblewrap re-derives the cwd from a [--chdir]
    pathname and pathname binds, so a swap between check and exec could redirect
    the wrapper. Before every launch the bound cwd root's [(st_dev, st_ino)] is
    re-checked against the inode opened at resolution, and a mismatch is a
    stale-policy refusal — a cheap witness that narrows, but does not close, the
    pathname-bind window on the external backends.

    {b Launches are inseparable sequences.} Every launch validates argv
    (non-empty, NUL-free), binds and opens the cwd, discharges every sealed
    obligation (a stale path is a structured refusal naming it, and no child),
    lowers through the sealed sandbox, and spawns — in one private sequence no
    caller can reorder or skip. One private child environment serves every
    route; escalation escapes the profile, never the environment, and an
    escalated command's [Command.outcome.sandbox_evidence] is
    {!Mentat_sandbox.escalated_evidence}.

    {b Cleanup reaches the child's process group.} Every child is spawned as the
    leader of a new process group, and cancellation, timeout, and an explicit
    kill signal that group before the child, so the workers a command forks are
    stopped with it. Only the child is reaped.
    {b Two descendants still survive}: one that put itself in another process
    group or session, and one that ignores a SIGTERM its own leader obeys —
    after the leader is reaped the group has no name this library will trust, so
    nothing escalates it. A survivor may keep writing the workspace; no caller
    may assume descendant quiescence. Switch release is Eio's own kill-and-reap
    and stays on the child alone. *)

module Resolve_error = Resolve_error
(** Workspace capability resolution errors. *)

module File_error = File_error
(** Workspace file observation errors. *)

type t
(** A resolved workspace capability. Binds, privately and inseparably: the
    logical {!Mentat_workspace.t}; one opened Eio directory capability per
    admitted root, opened once under the resolve switch; the exact child
    environment; and the sealed {!Mentat_sandbox.t} with its identity. The only
    constructor is {!resolve}. No accessor returns an opened root, a physical
    root inventory, the child environment, a lowered command, or the sealed
    sandbox value itself — only projections of it — so the sandbox's lowering
    bridges are unreachable from a holder. *)

val process_environment : unit -> (string * string) list
(** [process_environment ()] is this process's environment as bindings — the
    default answer to whose environment is ambient: what a local run passes to
    {!resolve}, and what an attaching client snapshots for the daemon. First
    occurrence wins for a duplicated name, as [execve] readers resolve it. *)

module Env_policy = Child_env.Policy
(** The child-environment inheritance policy — [sandbox.env_inherit],
    [sandbox.env_exclude], [sandbox.env_include_only]. *)

val resolve :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  logical:Mentat_workspace.t ->
  environment:(string * string) list ->
  ?env_policy:Env_policy.t ->
  mode:Mentat_config.Mode.t ->
  read:Mentat_config.Read.t ->
  readable_roots:string list ->
  writable_roots:string list ->
  mentat_dirs:Lpath.Abs.t list ->
  network:Mentat_sandbox.Policy.Network.t ->
  unit ->
  (t, Resolve_error.t) result
(** [resolve ~sw ~stdenv ~logical ~environment ?env_policy ~mode ~read
     ~readable_roots ~writable_roots ~mentat_dirs ~network ()] resolves the
    capability, in one fallible call.

    [environment] is the ambient environment every derivation reads — the roots,
    the child environment, the backend probe. The caller decides whose
    environment that is: the process's own snapshot for a local run, the
    invoking client's snapshot for a daemon-hosted one. A daemon resolving from
    its own environment would configure every confined child from whichever
    shell happened to spawn the daemon first, which is exactly the disagreement
    the exact-child-environment design exists to prevent.

    [mentat_dirs] are Mentat's own user directories. They are denied to every
    confined command on every route and in every mode, because the session store
    they hold carries the very confinement identity a resume revalidates
    against. The read-only route is included: it grants no configured or
    toolchain writes and carves out no protected paths, but it is still granted
    shared scratch space, so a denial is what keeps Mentat's own state out of
    it.

    It owns: root canonicalization (each configured spelling canonicalized once;
    broad roots — [/], the account home, a workspace ancestor — rejected),
    capability opening (each admitted root opened once as an Eio subtree under
    [sw]), toolchain/platform/git-worktree/git-config read-root derivation,
    existence-filtered protected-meta resolution (only existing protected paths
    enter the policy), exact child-environment construction (the ambient
    environment is read once, here), and — for a confined [mode] — the bounded
    backend probe and the sealing of the sandbox with the probe outcome
    injected; an unconfined [mode] seals the direct or declared-external route
    and probes nothing.

    [mode] is mandatory: there is no default posture, so a caller cannot resolve
    a writable capability by omission. [readable_roots] is consulted only when
    [read] is [Project] under a confined [mode]; [writable_roots] is validated
    on every route. The labels reuse the config and sandbox domain vocabulary;
    this library mints no second [mode], [read], or [network] type. Opened roots
    live until [sw] is released. Resolution creates only the directories it
    owns, each guarded against being handed a symlink or another user's
    directory, so a failed constructor leaves nothing a later run must clean up.
*)

val identity : t -> Mentat_sandbox.Identity.t
(** [identity t] is the durable confinement identity the session seals into the
    turn contract; resume compares it against a fresh resolution with
    {!Mentat_sandbox.Identity.equal}. *)

val policy : t -> Mentat_sandbox.Policy.t option
(** [policy t] is the sealed confined policy — the pure fact base tools project
    permission facts from and status surfaces read the sealed posture through.
    [None] on the direct and declared-external routes, which carry no policy. A
    projection, not the seal: holders can read what confines a command but can
    never lower or launch through it. *)

val evidence : t -> Mentat_sandbox.Evidence.t
(** [evidence t] is the sealed confinement evidence for the ordinary route —
    whether the resolved backend enforces, refused, or was not requested. *)

val escalation : t -> Mentat_sandbox.escalation
(** [escalation t] is the sealed per-command escalation stance: [Available] when
    a command may run unconfined after a separate approval, [Denied] for the
    read-only posture that admits none, or [Ignored] on an unconfined route
    where escalation asks for what is already true. It is the posture's own
    stated answer, not one read back off the writable roots — a read-only route
    is granted scratch space, so that inference would now report [Available]. It
    gates a write {!Command.run_granted} for the same reason it gates an
    escalation. Independent of the enforcement outcome. A projection, not the
    seal: a holder reads the stance but can never lower or launch through it. *)

val check :
  t ->
  requirement:Mentat_sandbox.Requirement.t ->
  (unit, Mentat_sandbox.Requirement.Rejection.t) result
(** [check t ~requirement] is the startup gate: the pure
    {!Mentat_sandbox.admits} decision composed with one obligation discharge for
    this exact capability. The executable runs it once,
    {e before any credential or session effect}, so an unavailable backend or an
    already-stale root fails the run there, not at the first command. A failed
    discharge is reported as an unenforceable rejection carrying [Stale_policy]
    with the exact path. Every later launch re-runs the discharge privately as
    its per-command TOCTOU guard. *)

val child_program : t -> string -> string option
(** [child_program t name] is where the child's [PATH] resolves the bare program
    [name] — a diagnostic projection for parity reporting (the doctor row
    comparing the child's [dune] with the launcher's), never a launch surface:
    launches resolve internally, at spawn. [None] for a name carrying a
    separator, or one no child-[PATH] directory holds executable. *)

val describe_roots : t -> (string * Lpath.Abs.t) list
(** [describe_roots t] is the display-ordered, origin-labeled readable roots for
    the one status consumer, [mentat sandbox status]/[explain]. Labels are
    stable diagnostic spellings — ["project"], ["user-configured"],
    ["platform"], ["executable:PATH"], ["executable:PATH runtime"],
    ["toolchain:<name>"], ["git-worktree"], ["git-config"], in that display
    order. Only roots
    the sealed policy actually reads appear, so an unscoped route lists nothing.
    This is a rendering projection sized to that surface — not a programmatic
    root inventory. No caller may branch on it. *)

val resolve_path :
  t ->
  string ->
  (Mentat_workspace.Path.t, Mentat_workspace.Resolve_error.t) result
(** [resolve_path t input] resolves raw absolute or relative [input] against the
    logical workspace carried by [t]. It is the capability-bound form of
    {!Mentat_workspace.resolve_string}: relative input uses the workspace's
    construction-fixed current directory, and absolute input must lie within an
    admitted root.

    This operation is pure. Success proves logical lexical containment only; the
    operations in {!File} perform filesystem containment checks while resolving
    beneath the opened roots. *)

val cwd : t -> Mentat_workspace.Path.t
(** [cwd t] is [t]'s construction-fixed current directory as a workspace path.
    It is the total form of [resolve_path t "."]: ["."] resolves against the
    logical root by construction, so unlike {!resolve_path} it cannot fail and
    carries the same most-specific-root attribution a [resolve_path t "."]
    would. *)

val to_abs :
  t ->
  Mentat_workspace.Path.t ->
  (Lpath.Abs.t, Mentat_workspace.Resolve_error.t) result
(** [to_abs t path] is [path]'s canonical absolute address under the
    most-specific opened root to which [t] binds it. Unlike
    {!Mentat_workspace.to_abs}, this projection uses the canonical root captured
    when the capability was resolved, so it is suitable for unambiguous display
    of paths outside the logical current root.

    This operation is pure and performs no filesystem access. It errors with
    {!Mentat_workspace.Resolve_error.Unknown_root} when [path] names a root not
    admitted by [t]. Success proves logical lexical containment only; operations
    in {!File} still enforce filesystem containment beneath the opened root. *)

(** Workspace observation beneath the opened roots.

    Resolution is confined per bound root: symlinks — intermediate and final —
    are followed only while their targets stay within the root the path binds
    to, at the honesty tier of the platform backend. A resolution that leaves
    the bound root is {!File_error.Escapes_workspace},
    {e even when the target lies within another admitted root}. *)
module File : sig
  type slice = private { contents : string; eof : bool }
  (** A bounded positioned read.

      [contents] contains at most the requested byte count. [eof] is [true] when
      the returned window reached the file size observed through the same opened
      descriptor immediately before the read, or the positioned read itself
      encountered an earlier end of file. *)

  val stat :
    t -> Mentat_workspace.Path.t -> (Eio.File.Stat.t, File_error.t) result
  (** [stat t path] is the metadata of the entry at [path], resolved beneath its
      opened root, following symlinks within it — the metadata of a final
      in-root symlink's target, not of the link. *)

  val lstat :
    t -> Mentat_workspace.Path.t -> (Eio.File.Stat.t, File_error.t) result
  (** [lstat t path] is the metadata of the entry at [path], resolved beneath
      its opened root without following the final symlink. Intermediate symlinks
      are resolved with the same confined containment checks as {!stat}. *)

  val read :
    t ->
    Mentat_workspace.Path.t ->
    offset:int ->
    max_bytes:int ->
    (slice, File_error.t) result
  (** [read t path ~offset ~max_bytes] reads at most [max_bytes] bytes starting
      at zero-based byte [offset], through one opened file descriptor. It
      returns empty [contents] with [eof = true] when [offset] is at or beyond
      the size observed on that descriptor. It follows symlinks under the same
      containment rules as {!load}.

      The size observation and positioned read are not an atomic snapshot: an
      external concurrent writer may change the file between them. [eof]
      therefore describes either the size observed before this read or an
      earlier end encountered while reading, not a stability guarantee. The
      operation never allocates a byte buffer larger than [max_bytes].

      Raises [Invalid_argument] if [offset < 0] or [max_bytes < 0]. *)

  val load :
    t ->
    Mentat_workspace.Path.t ->
    max_bytes:int ->
    (string, File_error.t) result
  (** [load t path ~max_bytes] is the complete contents of the file at [path],
      resolved beneath its opened root, when it is at most [max_bytes] bytes. A
      larger file is {!File_error.Too_large} carrying its size — the bound is
      mandatory so an observation read cannot exhaust memory. It follows
      symlinks, including a final symlink to an in-root regular file; a
      resolution that escapes the root — including through a symlink — is
      {!File_error.Escapes_workspace}. *)

  val read_dir :
    t ->
    Mentat_workspace.Path.t ->
    (Mentat_workspace.Path.t list, File_error.t) result
  (** [read_dir t path] is the entries of the directory at [path], as workspace
      paths beneath [path], in name order. Entries whose names are not
      representable as path components are omitted. *)

  val read_dir_entries :
    t ->
    Mentat_workspace.Path.t ->
    ((Eio.File.Stat.kind * Mentat_workspace.Path.t) list, File_error.t) result
  (** [read_dir_entries t path] is {!read_dir} with each entry's kind, as a
      walking directory needs it — the kind of a symlink itself, never its
      target, so it agrees with {!lstat} rather than {!stat}.

      The kind is always decisive: [`Unknown] is never returned. A filesystem
      that records the kind in the directory answers without a further syscall;
      one that does not is resolved here with the per-entry [lstat] the caller
      would otherwise have spent, and a failure to resolve one entry — it was
      removed between the read and the resolution — fails the call, exactly as
      an explicit {!lstat} of that entry would. *)
end

(** Native workspace writes — D4's native-write enforcer. *)
module Edit : sig
  val observe :
    t ->
    Mentat_workspace.Path.t ->
    (Mentat_edit.Observed.t, Mentat_edit.Error.t) result
  (** [observe t path] reads the current edit target through the native-write
      boundary's no-follow traversal. It returns [Missing] for an absent target,
      [Text contents] for a complete editable UTF-8 regular file, and [Other]
      for a final symlink or a non-regular filesystem target. Binary and invalid
      UTF-8 regular files, intermediate symlinks, protected metadata, read-only
      roots, oversized files, and I/O failures are structured
      {!Mentat_edit.Error.t} values. An intermediate symlink or non-directory
      error names the offending component and is classified as invalid input
      rather than an opaque I/O failure.

      Observation holds the native edit lock, enforces the same posture and
      one-MiB complete-read bound as {!apply}, and records no mutation evidence.
      A later {!apply} re-observes the plan's before state under the lock, so a
      target changed between observation and application fails stale instead of
      being overwritten. This seam is for write tools that must construct a
      content-addressed edit plan; ordinary reads use {!File}. *)

  val apply :
    t ->
    Mentat_edit.t ->
    (Mentat_edit.Result.t, Mentat_edit.Apply_error.t) result
  (** [apply t plan] applies a planned, stale-safe {!Mentat_edit.t} transition
      through the capability and returns the authoritative
      {!Mentat_edit.Result.t} — the only value carrying the before/after bytes
      the store persists.

      {b The boundary enforces its own sealed posture on every route.} Under a
      {!Mentat_config.Mode.Read_only} resolution every native write refuses with
      [Read_only_path], before any read or commit. Beyond posture, each target
      is re-bound to its most-specific opened root and refused if it lies in a
      read-only root ([Read_only_path]) or under
      {!Mentat_workspace.protected_meta_names} ([Protected_path]), using the
      same {!Mentat_workspace.protected_meta_component} predicate the command
      sandbox resolves its carveouts from. Permission gating still decides
      whether to call; this boundary confines what a call can do.

      {b Writes are no-follow.} Every commit-path traversal from the opened root
      to the target — parent directories, temporary entries, the final component
      — is fd-relative and refuses symlinks instead of following them, so an
      in-root symlink cannot launder a native write into protected metadata or a
      read-only root. The write-side preflight read observes through the same
      traversal: a final symlink reads as un-editable, an intermediate one
      refuses the apply. Writes are deliberately stricter than {!File} reads,
      which follow symlinks within the bound root. A tool that reads a target
      with {!File.load} and then edits it therefore meets a refusal when that
      target resolves through a symlink although the read succeeded: the two
      seams resolve symlinks oppositely by design, so a symlink refusal is the
      confined-resolution posture and final, not a stale-plan conflict to retry.

      {b Commits are atomic, not crash-durable.} Creation writes a
      same-directory temporary and publishes it with an atomic no-replace link;
      replacement writes a temporary, restores the target's exact permission
      bits through the open descriptor, and renames over the target; removal
      unlinks the entry. A failed commit leaves no partial target. Committed
      transitions are {e not} synced to stable storage: by the decided crash
      contract, a crash may lose a transition the mutation ledger already calls
      confirmed, and resume-time recovery reconciles the ledger against the
      observed workspace rather than paying a sync per edit.

      Creation makes missing parent directories; complete reads are bounded at 1
      MiB. Application is serialized per physical workspace within this process
      — capabilities resolved over the same primary root share one write lock.
      External writers take no lock: a concurrent non-Mentat write is an
      ambiguous race the contract does not decide. *)
end

(** Child process launches — the single sealed process-spawn boundary. *)
module Confinement = Confinement
(** What confined a command, observed once at the spawn boundary. *)

module Command : sig
  type stream = Stdout | Stderr  (** The stream a bound applies to. *)

  (** One output policy for both captured streams.

      [All] captures everything (git, one-shot [dune describe]). [Limit n]
      bounds each stream at [n] bytes and terminates the child on the first
      excess (bounded search tools). [Head_tail] keeps the first [head] and last
      [tail] bytes of each stream, eliding the middle without stopping the child
      (the shell tool's transcript discipline).

      A negative [Limit], [head], or [tail] bound is a programmer error: the run
      raises [Invalid_argument]. *)
  type capture = All | Limit of int | Head_tail of { head : int; tail : int }

  (** One captured stream, structurally, so completeness is a fact the caller
      reads rather than a marker it must parse out of the bytes. *)
  module Captured : sig
    type t = private
      | Complete of string
          (** the whole stream: the child produced no more than the policy kept
          *)
      | Truncated of { head : string; omitted : int option; tail : string }
          (** bytes were dropped. [omitted = Some n] is a [Head_tail] elision
              with a known [n]-byte gap between [head] and [tail];
              [omitted = None] means an unknown-length suffix was lost — a
              [Limit] stop, or a descendant that outlived the child still
              writing when the drain grace expired. A [Limit] or [All]
              truncation has an empty [tail]. *)

    val render : t -> string
    (** [render t] flattens the bytes. A truncated stream renders with the
        elision marker ["\n... N bytes omitted ...\n"]
        (["\n... bytes omitted ...\n"] when the count is unknown) between the
        halves. Because the marker is inserted at render time, a literal child
        string equal to it stays distinguishable in the structural value. *)

    val is_complete : t -> bool
    (** [is_complete t] is [true] iff no bytes were dropped. *)
  end

  (** The terminal cause of a run whose child was spawned. Every cause carries
      the captured bytes (B6b); only a pre-spawn refusal is an {!Error.t}. *)
  type termination =
    | Exited of Eio.Process.exit_status
        (** the child exited on its own — so nothing was signalled, and its
            process group was left alone. Both streams are {!Captured.Complete}
            unless a descendant held a pipe open past the bounded drain grace,
            which marks that stream {!Captured.Truncated}. *)
    | Timed_out
        (** the timeout won the race; the child's process group was signalled
            and the child terminated and reaped. [duration] is the measured
            elapsed time. *)
    | Stopped
        (** the cooperative stop predicate won the race. Distinct from parent
            fiber cancellation, which propagates as cancellation and never
            appears as an outcome. *)
    | Output_limit of { stream : stream; limit : int }
        (** [stream] exceeded its [Limit] capture bound; the child was
            terminated. A pending excess is observed before a concurrent exit is
            finalized, so it is never silently reported as {!Exited} (B6a). *)
    | Supervision_failed of Eio.Exn.err
        (** a drain read, or the stdin feeder on a non-EPIPE error, failed; the
            child was terminated. The bytes captured so far are retained and the
            affected stream reads truncated. A child that merely closed its own
            stdin is not this — it ends the feed cleanly. *)

  type outcome = private {
    termination : termination;
    stdout : Captured.t;
    stderr : Captured.t;
    duration : Mtime.Span.t;
    sandbox_evidence : Mentat_sandbox.Evidence.t;
    confinement : Confinement.t option;
  }
  (** The result of a run whose child was spawned. [stdout] and [stderr] are the
      captured bytes under the {!capture} policy; [duration] is monotonic;
      [sandbox_evidence] records the actual ordinary or escalated route selected
      before this child was spawned; [confinement] is what guarded it, observed
      once here so every spawn site has the same diagnosis instead of the one
      tool that grew a scan of its own. Read [termination] to learn how the run
      ended and {!Captured.is_complete} to learn whether the bytes are whole. *)

  (** Pre-spawn launch refusals — the only failures that erase output, because
      no child ran. Once a child is spawned, every terminal cause is an
      {!outcome}. *)
  module Error : sig
    type t =
      | Spawn of Eio.Process.error
          (** The child could not be started (for example the program was not
              found on the private environment's [PATH]). *)
      | Sandbox of Mentat_sandbox.Error.t
          (** A sandbox-vocabulary refusal: an unrepresentable argv — empty, an
              empty program ({!Mentat_sandbox.Error.Empty_program}), or a NUL
              byte in a token ({!Mentat_sandbox.Error.Nul_in_argv}) — a failed
              lowering, a cwd outside scope, unavailable escalation, or an
              obligation discharge or cwd witness recheck that found a stale
              path ([Stale_policy]). In every case, no child was started.

              The argv NUL check is load-bearing, not cosmetic: OCaml's [exec]
              family passes C strings, so an unvalidated NUL byte would silently
              truncate the token at the first NUL and launch a different command
              than the one permission authorized. It is enforced here, at the
              launch boundary, and must never be relaxed on the assumption the
              sandbox profile covers it. *)
      | Unknown_cwd_root of Mentat_workspace.Root.Key.t
          (** The [cwd] names a root key the resolved workspace does not admit.
              The workspace library's own contract classifies unknown-root as
              recoverable, so a persisted cwd from a resumed session refuses
              here rather than crashing. No child was started. *)
      | Io of Eio.Exn.err
          (** The launch machinery itself failed before supervision started —
              opening the null device, creating a pipe, or the exec. No child
              ever started. A failure once a child is running is a
              {!Supervision_failed} termination, not this. *)

    val message : t -> string
    (** [message e] is [e]'s human-readable diagnostic. Not a stable matching
        surface; branch on the constructor. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf e] formats {!message} [e]. *)
  end

  val run :
    t ->
    ?cwd:Mentat_workspace.Path.t ->
    ?stdin:_ Eio.Flow.source ->
    capture:capture ->
    timeout:Eio.Time.Timeout.t ->
    ?cancelled:(unit -> bool) ->
    string list ->
    (outcome, Error.t) result
  (** [run t ~capture ~timeout argv] runs one command through the sealed
      confined route: validate, bind the cwd, discharge obligations, lower,
      spawn, supervise to a single terminal cause.

      [capture] and [timeout] are mandatory: a caller states its output policy
      and its bound explicitly, never inheriting an unbounded [All] or [none] by
      omission. Pass [Eio.Time.Timeout.none] for a deliberately unbounded run.

      [cwd] is logical and defaults to the workspace's fixed current directory;
      it is bound beneath the opened root and handed to spawn as the opened
      capability, with the inode witness recheck the facade documents. Omitted
      [stdin] is an explicit null source, never the parent's stdin. [cancelled]
      is the engine-owned cooperative stop predicate, polled during the run —
      when it reports [true], the child is terminated and the outcome is
      {!Stopped}. Parent fiber cancellation is the other, distinct signal: it
      propagates as cancellation after the same bounded cleanup and never
      appears as an outcome. The child runs in the private environment on every
      route.

      Raises [Invalid_argument] if a [capture] bound is negative — a programmer
      error, never a run outcome. *)

  val run_escalated :
    t ->
    ?cwd:Mentat_workspace.Path.t ->
    ?stdin:_ Eio.Flow.source ->
    capture:capture ->
    timeout:Eio.Time.Timeout.t ->
    ?cancelled:(unit -> bool) ->
    string list ->
    (outcome, Error.t) result
  (** [run_escalated t ~capture ~timeout argv] is {!run} on the
      approved-escalation route: the enforcing profile is dropped, the
      environment is not. It exists solely for the engine's permission decision
      to inject; it fails with [Sandbox Escalation_denied]-class errors unless
      the sealed {!Mentat_sandbox.escalation} is [Available]. The resulting
      {!outcome.sandbox_evidence} reports {!Mentat_sandbox.escalated_evidence}.
      Ordinary producers receive a closure over {!run} and never see this entry.

      Raises [Invalid_argument] if a [capture] bound is negative — a programmer
      error, never a run outcome. *)

  val run_granted :
    t ->
    ?cwd:Mentat_workspace.Path.t ->
    ?stdin:_ Eio.Flow.source ->
    capture:capture ->
    timeout:Eio.Time.Timeout.t ->
    ?cancelled:(unit -> bool) ->
    grants:(Lpath.Abs.t * Mentat_sandbox.Policy.Access.t) list ->
    string list ->
    (outcome, Error.t) result
  (** [run_granted t ~capture ~timeout ~grants argv] is {!run} on a seal widened
      by [grants] for this command alone — the narrow answer to what
      {!run_escalated} answers by leaving the sandbox entirely.

      The command stays confined. Every clause the posture derived still
      applies, the deny set still wins beneath a granted tree, and
      {!outcome.sandbox_evidence} reports enforced evidence naming the profile
      that actually ran — not {!Mentat_sandbox.escalated_evidence}, because
      nothing was escaped. The widening lives exactly as long as the call: the
      capability's own seal is untouched, so no grant accumulates and the
      session's {!Mentat_sandbox.identity} never moves.

      A grant at or beneath a denied path fails with
      {!Mentat_sandbox.Error.Grant_denied} rather than being silently lost, and
      a grant naming a path that does not exist fails the ordinary obligation
      discharge — grants are admitted, never materialized. Like {!run_escalated}
      this exists for the engine's permission decision to inject; ordinary
      producers receive a closure over {!run}.

      Raises [Invalid_argument] if a [capture] bound is negative — a programmer
      error, never a run outcome. *)

  (** A live, sandboxed, long-lived child with two live-readable capture buffers
      — the supervised shape behind background terminals (a dev server, a
      watcher, a log tail). Spawned under a caller switch by {!start_session};
      teardown on switch release is Eio's own and stays on the child: releasing
      the switch kills and reaps the child, its drain daemons, and its pipes,
      without widening to the group {!Session.signal} reaches.

      Unlike {!run}, no tool callback is long-lived — {!start_session} returns
      the handle at once and the process outlives the call, and its output is
      captured into bounded live rings a reader polls incrementally while a
      waiter fiber flips {!Session.status} when the child exits. *)
  module Session : sig
    type t

    (** A monotonic read cursor over one session's captured output. It snapshots
        the raw byte counts ever written to the two buffers, so a later {!read}
        learns both the new bytes and whether the ring rolled bytes off below
        it. Stdout and stderr advance independently within one cursor. *)
    module Cursor : sig
      type t

      val zero : t
      (** The cursor before any output: {!read} from [zero] returns everything
          still buffered. *)

      val equal : t -> t -> bool
      (** [equal a b] is [true] iff [a] and [b] name the same position in both
          streams. *)
    end

    (** The liveness of a session at read time — ephemeral, never persisted.

        [Terminated] means {e we} signalled it ({!signal} or switch release); a
        child that exits on a signal from elsewhere is [Exited (`Signaled n)].
        The two overlap at the OS level — a child we SIGKILL also waits
        [`Signaled] — so the distinction is not read off the wait status; it is
        that the session {e recorded that it signalled}. *)
    type status =
      | Running
      | Exited of Eio.Process.exit_status
      | Terminated  (** killed by us: SIGTERM→SIGKILL, group then child *)

    type chunk = {
      stdout : string;
      stderr : string;
      dropped : int;
      next : Cursor.t;
      status : status;
      since : Mtime.Span.t;
    }
    (** One incremental read. [stdout] and [stderr] are the raw bytes appended
        to each stream since the cursor; [dropped] is the raw bytes (combined
        across both streams) the head-drop cap rolled off below the cursor
        before this read; [next] is the cursor to poll from next; [status] is
        the liveness at read time; [since] is the process age, monotonic. The
        bytes are raw — UTF-8 repair, ANSI stripping, and any per-read cap are
        the reader's concern, not the buffer's. *)

    val max_buffer_bytes : int
    (** [131072] — 128 KiB retained per stream in the live ring. When a stream
        exceeds it the oldest bytes roll off the head, and a {!read} that had
        not yet consumed them counts them in {!chunk.dropped}. Stdout and stderr
        are bounded separately, so a chatty stderr never evicts stdout. *)

    val read : t -> from:Cursor.t -> chunk
    (** [read t ~from] is the output appended since [from], with the next cursor
        and the live status. Non-blocking: it reads the rings and the recorded
        status, never the child, and never raises. If [from] is below a ring's
        retained window (the ring rolled past it) the lost bytes are counted in
        {!chunk.dropped} and the read resumes at the window start — never a
        silent gap, the same discipline as {!Captured.Truncated}. *)

    val await :
      t -> from:Cursor.t -> cancelled:(unit -> bool) -> seconds:float -> chunk
    (** [await t ~from ~cancelled ~seconds] is {!read} under a deadline: it
        returns the moment the session appends output past [from], settles, or
        [cancelled] reports [true], and otherwise when [seconds] elapse. A
        cursor that already has output behind it returns without waiting.

        An expired deadline is not a failure: the result is the chunk {!read}
        would have returned, so an empty chunk from a still-[Running] session
        means the session produced nothing for the whole wait. [cancelled] is
        the engine-owned cooperative stop, sampled during the wait because
        nothing announces it; the caller decides what an interrupted wait means.
        Parent fiber cancellation propagates as cancellation, as everywhere
        else. *)

    val signal : t -> unit
    (** [signal t] cooperatively terminates the child: SIGTERM, a bounded grace,
        then SIGKILL, each sent to the child's process group before the child,
        reaps the child under [Eio.Cancel.protect], drains the final tail within
        a bounded grace, and settles {!status} to [Terminated]. Idempotent:
        signalling an already-settled session is a no-op that leaves its
        recorded status — including a child that already exited on its own,
        whose descendants are therefore never signalled.

        The workers a command forked go with it; a descendant that left the
        group, or that ignores a SIGTERM the child itself obeys, does not. *)

    val pid : t -> int
    (** [pid t] is the child's process id, and the id of the process group it
        leads. *)

    val status : t -> status
    (** [status t] is the liveness recorded so far, without blocking. It is
        [Running] until the waiter fiber reaps a self-exit ([Exited]) or
        {!signal}/switch release terminates it ([Terminated]). *)

    val since : t -> Mtime.Span.t
    (** [since t] is the process age — the monotonic span since it was spawned —
        without consuming output. It is the same clock {!chunk.since} reports.
    *)
  end

  val start_session :
    t ->
    sw:Eio.Switch.t ->
    ?cwd:Mentat_workspace.Path.t ->
    ?env_override:(string * string) list ->
    string list ->
    (Session.t, Error.t) result
  (** [start_session t ~sw argv] spawns [argv] as a supervised background child
      under [sw] and returns at once with a live {!Session.t} — the same
      validate/bind/discharge/lower/launch sequence as {!run}, on the ordinary
      confined route. Stdin is an explicit [/dev/null]; stdout and stderr are
      captured into the session's live rings, never inherited. The child leads a
      new process group, which {!Session.signal} reaches. Two drain daemons and
      a waiter fiber run under [sw]; releasing [sw] kills and reaps the child —
      the session's lifetime {e is} [sw].

      [env_override] rebinds names in the private child environment for this
      session's child alone: an override replaces any existing binding of the
      same name and otherwise appends, and the capability's own environment is
      untouched — every other launch still receives it byte-for-byte. It
      exists for a supervised child that must be handed a private runtime
      handle of its own, such as a build watch's session-scoped
      [XDG_RUNTIME_DIR]; it is not a general configuration channel, and the
      sandbox policy is not consulted about the values. Raises
      [Invalid_argument] on an empty name, a name containing ['='], or a name
      or value containing a NUL — a programmer error, never a launch outcome.

      The waiter and reaper are cancellation-safe fibers on Eio's own
      [Process.await]/[signal], never a systhread [waitpid] — a systhread
      blocked on wait would pin the owning switch's release. [Error.t] is the
      same pre-spawn refusal as {!run} ([Sandbox], [Unknown_cwd_root], [Spawn],
      [Io]); once the child is spawned there is no launch error, only a live
      session whose {!Session.status} tells its fate. *)
end

(** The attribution window for one tool claim — the claim-scope half of RFC
    0011's [WORKSPACE] port. The window lives on this capability because the
    native-write enforcer does: while a window is open, every {!Edit.apply}
    records its workspace effect into it, in application order — the
    authoritative {!Mentat_edit.Result.t} of a successful apply, and the
    confirmed committed prefix plus uncertain commit target of a failed one.
    Recording is complete by construction: a partially-failed plan's committed
    transitions are evidence, not discardable noise.

    {b Recording order relies on the engine's serialized drain.} The per-apply
    commit-and-record is one uncancellable step (so a confirmed transition is
    never lost between the commit and its evidence), but the workspace write
    lock serializes only writes to a target, not two {!Edit.apply} calls against
    each other. Recorded order therefore equals application order because the
    engine drives one tool callback at a time under its serialized drain; the
    capability does not itself serialize concurrent applies into a total order,
    and a caller that violated that single-callback discipline would observe
    interleaved recording. *)
module Claim_scope : sig
  type t
  (** An open attribution window for one tool claim. *)

  val observe : t -> Mentat_workspace.Path.t -> unit
  (** [observe scope path] records [path] as observationally attributed — the
      intake for the executable's observational-attribution adapter (watcher
      batches, checkpoint diffs). Raises [Invalid_argument] if [scope] is closed
      or superseded: observation into a spent window is a programmer error,
      never a silent drop. *)

  val close : t -> Mentat_edit.Apply_evidence.t
  (** [close scope] closes the window and returns its evidence — the pure
      {!Mentat_edit.Apply_evidence.t} the port crosses on: one chronological
      [applies] list (a successful apply's authoritative
      {!Mentat_edit.Result.t}, or a failed apply's committed prefix plus
      uncertain commit target, in the order they occurred) and the
      observationally attributed paths. Observation covers what the native path
      could not: a path an apply already recorded — a confirmed transition or
      the uncertain commit target — is dropped from [observed], so evidence for
      one path is native or observational, never both. It is called exactly
      once, after the tool callback's worker scope has quiesced — {e when} is
      the engine's serialized-drain contract; the engine lowers the evidence
      into the store's mutation appends and never inspects tool output. A window
      superseded by a later {!open_claim_scope} still yields, on its own
      [close], everything recorded up to the supersession. Raises
      [Invalid_argument] on a second close — a programmer error. *)
end

val open_claim_scope : t -> Claim_scope.t
(** [open_claim_scope t] opens the attribution window for one tool claim.
    Windows bracket exactly one tool callback under the engine's serialized
    drain. Opening while a window is still open {e supersedes} it: the old
    window stops recording and the new one becomes current. Supersession is the
    recovery path for a claim cancelled before it could {!Claim_scope.close} —
    cancellation is not a programmer error and must not wedge the capability —
    not a license to interleave windows. An {!Edit.apply} outside any open
    window is enforced identically and yields no claim evidence. Correlation to
    the tool claim id stays on the adapter side — this library never links the
    session. *)
