(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Fresh-process OCaml evaluation in a Dune project context.

    [Eval] provides the stable ["ocaml_eval"] model tool. It evaluates OCaml
    toplevel phrases with the libraries and compiler selected by Dune for one
    project directory. Each call obtains fresh load directives and starts a
    fresh bytecode toplevel; definitions, installed printers, module state, and
    other process-local effects never survive into a later call.

    {1:input Input contract}

    Provider input is a strict JSON object with:

    - required ["code"], non-empty, NUL-free OCaml toplevel phrase text;
    - optional ["dir"], a non-empty, NUL-free workspace-relative or
      workspace-contained absolute directory;
    - optional ["timeout_ms"], a positive exact integer in JSON's safe integer
      range.

    Every member name may occur at most once. Repeated required or optional
    members are rejected rather than resolved by member order.

    ["dir"] defaults to the root that owns the workspace capability's fixed
    current directory. A relative explicit directory is resolved from that
    current directory. ["timeout_ms"] defaults to {!default_timeout_ms} and
    values above {!max_timeout_ms} fail as [`Invalid_input] before directory
    observation or process launch. Non-object input, repeated or unknown
    members, fractional values, numeric strings, unsafe integers, empty strings,
    and NUL are rejected during call decoding, before permissions or effects.

    The input is phrase text, not an implementation file. If its trimmed form
    does not end in [;;], one terminator is appended; otherwise the original
    bytes are preserved. The generated standard input ends with [#quit;;]. A
    whitespace-only string is therefore a valid empty phrase, preserving the
    legacy evaluator's distinction between an absent provider value and toplevel
    whitespace.

    {1:execution Project and process semantics}

    Evaluation has two sequential one-shot command phases. From the selected
    directory, the tool first runs:

    {[
    program @ [ "ocaml"; "top"; "." ]
    ]}

    It then feeds those complete Dune load directives, the framed provider
    phrase, and [#quit;;] to:

    {[
    program @ [ "exec"; "--"; "ocaml"; "-stdin"; "-noinit" ]
    ]}

    [program] is supplied by the host to {!make} and is normally [["dune"]] or a
    boot-resolved wrapper prefix. Both invocations go exclusively through
    {!Mentat_workspace_io.Command.run}. This module never uses a shell,
    discovers an executable, reads an ambient environment, retains a process
    manager, lowers a sandbox, or opens a filesystem path directly. The
    capability supplies its private environment and binds the logical working
    directory to its opened root.

    [-noinit] prevents a user's toplevel startup file and printers from making
    results depend on ambient home state. Dune's directives remain authoritative
    for project libraries and package-managed compiler selection. The tool
    deliberately does not build, clean, or start a Dune watch. A supervised
    build watch is paused for the call's duration (the lease) and respawns
    after it; only a foreign watch — another session's, not ours to pause —
    makes the tool refuse up front ([`Unavailable], naming the
    Merlin-backed alternatives) rather than letting the setup command fail
    with Dune's own lock advice.

    One wall-clock budget covers both phases, including feeding standard input.
    The first phase captures at most {!max_directive_bytes} per stream and must
    return complete stdout before it can be used as OCaml source. The evaluation
    phase retains at most {!max_output_bytes} per stream with structural
    head/tail capture; excess middle bytes do not allocate unbounded memory and
    do not stop the toplevel. A call never reuses a process or a directive
    response from another call. Successful setup stdout is protocol input to the
    evaluator, not model-visible transcript, and successful setup stderr is
    discarded. If setup ends the call, both of its bounded streams are reported
    instead.

    {1:diagnostics Diagnostics and result status}

    Compiler warnings, type errors, exceptions printed by the toplevel, custom
    printer output, and provider-written output remain in stdout or stderr. The
    tool does not search human-readable diagnostics for words such as ["Error"]
    or ["Warning"]: those strings are not a stable success protocol, and user
    code can print them. Process termination is the status boundary.
    Consequently an OCaml toplevel that reports a rejected phrase but exits zero
    yields a completed call whose transcript contains the diagnostic, as the
    legacy tool did.

    A zero setup exit continues only with complete stdout; a zero evaluation
    exit completes the call. A non-zero exit, signal, directive overflow,
    incomplete directive response, or supervision failure is [`Failed]. A
    timeout is [`Timed_out]. Cooperative stop is a cancelled interruption.
    Spawn, sandbox, and pre-supervision I/O refusals produce [`Unavailable]
    without output because no child ran. A malformed, escaping, or non-directory
    [dir] is [`Invalid_input], while a well-formed absent directory follows the
    shared filesystem classification as [`Not_found].

    {1:output Durable output}

    The child outcome that ends the call produces authoritative text and the
    compact {!Mentat_tools_output.Process} JSON projection: termination and
    total duration only. A successful setup outcome is replaced by the
    evaluation outcome; cancellation between phases has no process output. A
    timeout exhausted immediately before either spawn is represented as a
    timed-out process result.

    Paths at or below the capability's logical current directory are ["."] or
    relative to it. A sibling, ancestor, or auxiliary-root directory is stored
    as its canonical capability absolute address, so the value is unambiguous
    and can be supplied to another provider call. Arbitrary process bytes are
    repaired to valid UTF-8 when projected into model-visible text; structural
    omitted-byte counts continue to describe the original bytes. The output
    truncation flag is true iff either captured stream is incomplete. JSON
    contains no code, directory, phase, timeout, stream body, diagnostic, or
    framing detail. Output carries no process handle, sandbox capability, edit
    result, receipt, checkpoint, or mutation evidence.

    {1:permissions Permissions and cancellation}

    Permission planning is pure over the decoded input. Every call produces one
    request containing only the shared ["command.confinement"] custom fact. Its
    subject is the stable
    {!Mentat_permission.Access.Command.execution_to_string} projection computed
    once from the immutable workspace capability when {!make} constructs the
    tool. Fixed Dune argv is an implementation detail, and the model-authored
    phrase is not mislabeled as shell source. Directory validation performs no
    native write and requires no additional path permission.

    Cancellation is checked before directory observation, between setup and
    evaluation, and continuously by the command supervisor. A stopped child is
    terminated and reaped before the cancelled interruption is returned.
    Parent-fiber cancellation remains Eio cancellation after capability cleanup
    and is not converted into a tool result. *)

val name : string
(** [name] is ["ocaml_eval"]. *)

val default_timeout_ms : int
(** [default_timeout_ms] is [10000]. *)

val max_timeout_ms : int
(** [max_timeout_ms] is [120000], the largest accepted requested total timeout.
*)

val max_directive_bytes : int
(** [max_directive_bytes] is [65536], the complete-output bound applied to each
    [dune ocaml top] stream. *)

val max_output_bytes : int
(** [max_output_bytes] is [65536], the maximum retained bytes per evaluation
    stream. Head and tail divide this budget equally. *)

val make :
  Mentat_workspace_io.t ->
  clock:_ Eio.Time.Mono.t ->
  program:string list ->
  ?dune_lease:(unit -> [ `Free | `Held | `Leased of unit -> unit ]) ->
  unit ->
  Mentat_tool.t
(** [make workspace_io ~clock ~program ()] is the immutable OCaml-eval tool
    definition. It closes the workspace capability, monotonic clock, and
    boot-resolved Dune program prefix for the definition's lifetime, and
    projects command confinement once. Construction starts no process and
    observes no path.

    [program] is an argv prefix, for example [["dune"]] or a resolved wrapper
    prefix. Each token must be non-empty and NUL-free.

    [dune_lease] is consulted at the lock-taking moment (default: [`Free],
    run as-is). [`Leased release] means a supervised watch was paused for
    this call — the tool runs and returns the lease via [release], failure
    included. [`Held] means a foreign watch holds Dune's build lock: the
    call fails [`Unavailable] with text naming the lock and the
    Merlin-backed alternatives — never Dune's own lock advice, which
    suggests deleting [_build/.lock].

    Raises [Invalid_argument] if [program] is empty or contains an invalid
    token. *)
