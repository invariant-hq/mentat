(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-facing non-interactive shell command runner.

    [Shell] is the command escape hatch for builds, tests, Git, package
    managers, project binaries, and diagnostics that do not have a narrower
    tool. Each call starts one independent shell invocation; shell state does
    not persist between calls. File reads, searches, listings, and edits should
    use their dedicated tools.

    {1 Input contract}

    The strict input object has these members:

    - [command], required non-empty shell source;
    - [workdir], an optional non-empty workspace-relative or workspace-contained
      absolute directory, defaulting to the workspace capability's fixed current
      directory;
    - [timeout_ms], an optional positive integer, defaulting to
      {!default_timeout_ms} and bounded by {!max_timeout_ms};
    - [description], optional non-empty reviewer metadata with no execution
      semantics;
    - [escalate], an optional boolean that defaults to [false];
    - [background], an optional boolean that defaults to [false];
    - [grant_write], an optional array of absolute paths, empty by default.

    When [background] is [true] the command is started as a supervised
    background process and the call returns {e immediately} with a handle to
    poll with {!Shell_output} and stop with {!Shell_kill}; the process keeps
    running across turns until it exits or is killed. [timeout_ms] is ignored —
    a background process's lifetime is the session, not a turn-bounded timeout.
    A background command runs the ordinary confined route and {e cannot} be
    widened: [background:true] with either [escalate:true] or a non-empty
    [grant_write] fails [`Invalid_input] with a message steering the caller to
    the foreground or to dropping the request — a widened profile outliving the
    turn is the open sandbox question v1 does not pre-empt. A background start
    needs a [registry] (see {!make}): without one it fails [`Unavailable].
    Background execution is unavailable to subagents, whose catalog omits
    [shell] entirely.

    String members may not contain NUL, because neither OS argv nor filesystem
    paths can represent it faithfully. Numeric strings, fractional timeouts,
    non-positive timeouts, unknown members, and duplicate members are rejected.
    A timeout above {!max_timeout_ms} is well-formed input but fails as
    [`Invalid_input] before workdir observation or process launch. The declared
    schema publishes that ceiling as the member's maximum, so a caller planning
    against the declaration plans against the bound that is enforced.

    {1 Shell and command boundary}

    The host supplies [shell] to {!make} as a required argument: the resolved
    configuration owns the user's shell choice, while selecting the shell
    executable belongs to this module rather than the workspace capability. On
    POSIX, [Shell] constructs:

    {[
    [ shell; "-lc"; command ]
    ]}

    Windows [cmd] and PowerShell executables use their native non-interactive
    command flags.

    Execution goes exclusively through {!Mentat_workspace_io.Command.run} or,
    for an available and separately approved request,
    {!Mentat_workspace_io.Command.run_granted} or
    {!Mentat_workspace_io.Command.run_escalated}. Every route uses the
    capability's private stripped environment, and none restores ambient secrets
    or agent sockets. The two widenings differ in what survives them: a grant
    keeps the enforcing profile and adds the named paths for this command only,
    so the command is still confined and its evidence still enforced; an
    escalation drops the profile entirely. The returned sandbox evidence reports
    the route that actually ran.

    [grant_write] and [escalate] cannot be combined: an escalated command has no
    policy left for a grant to widen, so the pair fails [`Invalid_input] rather
    than resolving to one of them. A grant naming a path Mentat denies outright
    is refused, and a grant naming a path that does not exist fails the ordinary
    obligation discharge — grants are admitted, never created.

    The command receives null stdin. Its stdout and stderr are drained
    concurrently by the workspace capability with a
    {!Mentat_workspace_io.Command.Head_tail} policy retaining at most
    {!max_output_bytes} bytes per stream. A literal child string resembling an
    elision marker remains distinguishable until rendering because completeness
    and omitted-byte counts are structural capability facts.

    {1 Permission and escalation contract}

    Construction projects the immutable confined command-execution fact once
    from the workspace capability. Decoding a lexically resolvable workdir
    requests one coarse {!Mentat_permission.Access.shell} fact for the exact
    command and cwd. Even simple-looking source is not reclassified as argv,
    because a partial parser cannot prove what a shell will execute.

    Under workspace-write confinement, [escalate = true] changes that command
    fact to the direct execution route and adds the reviewable [shell.escalate]
    custom fact. A non-empty [grant_write] instead {e keeps} the confined
    command fact — the command really does stay confined — and adds a reviewable
    [shell.grant] custom fact whose subject is the paths, because the paths are
    what the approval is for.

    Read-only confinement denies both and produces no request: the sealed
    posture promises no mutation, and a write grant is a mutation. Under direct
    or declared-external execution both are ignored because the requested
    authority already exists. Permission planning is pure and performs no
    filesystem I/O. A workdir that cannot be lexically resolved produces no
    request and fails before launch. A denied widening fails before workdir
    observation: a request that cannot run does not inspect a path merely to
    rediscover the sealed read-only posture.

    {1 Results, output, and cancellation}

    Exit status zero completes. Non-zero exit and signal termination fail as
    [`Failed], timeout as [`Timed_out], and cooperative stop is a cancelled
    interruption. Spawn, sandbox, and pre-supervision I/O refusals fail without
    output because no child ran. Once a child is spawned, every terminal cause
    retains both captured streams in authoritative output text, including
    timeout, stop, output-limit, and supervision failure.

    Durable JSON is the compact {!Mentat_tools_output.Process} projection:
    termination and duration only. The authoritative text is the head/tail
    transcript with command, workdir, status, effective timeout, duration,
    sandbox route, stdout, and stderr. The command capability retains raw
    process bytes and computes completeness and omitted-byte counts from them.
    Before embedding a rendered stream in model-visible text, [Shell] replaces
    every malformed UTF-8 sequence with [U+FFFD]; this repair does not change
    the structural completeness facts or the raw-byte omission count. The output
    truncation flag is true iff either structural stream is incomplete. JSON
    contains no command, argv, stream body, sandbox evidence, or mutation
    evidence. Shell is an opaque writer: the engine attributes its workspace
    effects through the surrounding {!Mentat_workspace_io.Claim_scope}, never by
    inspecting tool output.

    Cancellation is polled before workdir resolution and by the command
    supervisor. A cooperative stop terminates and reaps the child and returns
    its retained bytes. Parent-fiber cancellation remains Eio cancellation after
    bounded cleanup and is not converted into a tool result. Cleanup signals the
    child's process group, so the workers a command forks stop with it; a worker
    that left the group, or that ignores a SIGTERM the command itself obeys, may
    survive and keep writing after timeout, stop, or parent cancellation.
    Callers must not infer descendant quiescence from the terminal result. *)

val name : string
(** [name] is ["shell"]. *)

val default_timeout_ms : int
(** [default_timeout_ms] is [60000]. *)

val max_timeout_ms : int
(** [max_timeout_ms] is [600000], the largest accepted requested timeout. *)

val max_output_bytes : int
(** [max_output_bytes] is [65536], the maximum retained bytes per captured
    stream. Head and tail divide this budget equally. *)

val make :
  ?registry:Registry.t ->
  ?on_timeout:(command:string -> unit) ->
  Mentat_workspace_io.t ->
  clock:_ Eio.Time.Mono.t ->
  shell:string ->
  Mentat_tool.t
(** [make ?registry ?on_timeout workspace_io ~clock ~shell] is the immutable
    [shell] tool definition. Constructing it starts no process, observes no
    path, and projects the sealed command-confinement posture once.

    [registry] is the per-session background-process registry a
    [background:true] command spawns into; the driver supplies it (bound to its
    per-session switch) when it builds the per-turn catalog. Omitted — as in the
    process-wide composition where no per-session switch exists — a background
    command fails [`Unavailable]; foreground behavior is unchanged.

    [on_timeout] is called after a foreground command's timeout settles, with
    the command text as written (default: nothing). It exists for the one
    observer of stalled commands — a build-watch supervisor listening for a
    forwarded [dune] build that hung — and runs after the child is reaped, so
    it must not block. Background commands and cancellations never report.

    Raises [Invalid_argument] if [shell] is empty or contains NUL. *)

module Registry = Registry
(** The per-session background-process registry the three background surfaces
    share; the driver creates it and threads it into {!make},
    {!Shell_output.make}, and {!Shell_kill.make}. *)

module Shell_output = Shell_output
(** Read new output from a background command. *)

module Shell_kill = Shell_kill
(** Stop a background command. *)
