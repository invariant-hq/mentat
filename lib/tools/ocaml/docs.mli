(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Bounded OCaml API documentation by source path, library, module, or item.

    [Docs] provides the stable ["ocaml_docs"] model tool. A single query selects
    one of four views: a workspace source-file outline, a library overview, a
    module outline, or one focused declaration. Name queries cover the current
    Dune project's local libraries and locked dependencies; path queries cover
    any source admitted by the workspace capability.

    {1:input Input contract}

    Provider input is a strict JSON object with required ["query"] and these
    optional members:

    - ["scope"] is ["workspace"], ["deps"], or ["any"], defaulting to ["any"].
      It is ignored for path queries. An ["any"] name that resolves both locally
      and as a dependency is rejected as ambiguous.
    - ["package"] is a non-empty findlib-library hint for a module whose root
      name does not identify its containing library.
    - ["depth"] is the non-negative nested-module expansion depth, defaulting to
      [0]. Collapsed modules report their direct member count.
    - ["offset"] is the one-based first preorder item, defaulting to [1].
    - ["limit"] is the page size in \[[1];[max_limit]\], defaulting to
      {!default_limit}.
    - ["max_source_bytes"] is the complete-source bound in
      \[[1];[max_source_bytes]\], defaulting to {!default_max_source_bytes}.

    [query] is classified syntactically. Text containing ['/'] or ending in
    [.ml] or [.mli] is a path. An all-lowercase dotted name such as ["eio"] or
    ["eio.unix"] is a library. A dotted name ending in a capitalized segment,
    such as ["Eio.Path"], is a module path; one ending in a lowercase segment,
    such as ["Eio.Path.load"], focuses that declaration. Unknown or duplicate
    members, empty or NUL-containing strings, fractional numbers, numeric
    strings, infinities, unsafe JSON integers, and values outside the documented
    bounds are rejected during call decoding, before permissions or I/O.

    {1:resolution Resolution and source provenance}

    Path queries completely load the resolved regular file through
    {!Mentat_workspace_io.File.load}. The compiler parser produces the primary
    outline, preserving declaration source spans and attached odoc comments. If
    a mid-edit file does not parse, one Merlin [outline] query is attempted with
    the same complete source; a Merlin failure leaves the compiler diagnostic as
    an [`Invalid_input] failure.

    Name queries run one bounded [dune describe workspace --root . --with-deps]
    command and decode its normalized project universe. Local-library sources
    and dependency sources materialized beneath the project build tree are read
    through the workspace capability. An external dependency with no readable
    project-tree source falls back to [ocamlfind query] only when
    [opam_switch_prefix] was supplied to {!make}. The returned library directory
    and selected [.mli] or [.ml] must resolve beneath that explicitly admitted
    switch [lib/] root; the final source entry must be a regular file at the
    capability's no-follow observation immediately before the bounded load. With
    no configured switch prefix, that fallback is [`Unavailable] rather than an
    ambient-environment read.

    Dependency sources are always parsed as [.mli] or [.ml] text, never compiler
    artifacts whose format is tied to a compiler build. Each completed result
    carries source provenance: workspace file, workspace library, locked [.pkg]
    package/version/build when recoverable from the path, or package/version and
    configured opam-switch prefix. A [.mli] is preferred; falling back to [.ml]
    sets [interface_available] to [false]. Standard-library and compiler-library
    names remain explicitly out of scope, matching the established tool. An
    unknown nested module or focused identifier completes with the nearest
    enclosing outline and its available member names, providing a structured
    recovery surface rather than discarding the resolved source.

    {1:bounds Bounds and pagination}

    A source is read completely only below the requested cap, whose absolute
    maximum is {!max_source_bytes}. Each attached odoc comment is shortened at
    the longest valid UTF-8 prefix not exceeding {!max_doc_bytes}; the text
    marks whether it was shortened. The page contains at most {!max_limit}
    declarations in preorder. A partial page or any shortened documentation sets
    the erased output truncation bit; a partial page also includes a canonical
    next-call input in text.

    Dune and ocamlfind each have a 30-second command timeout and an eight-MiB
    limit on each captured stream. Merlin uses its shared 30-second, one-MiB
    transport bounds. Successful command output must be complete. No source,
    command transcript, capability, sandbox value, process handle, mutation
    fact, edit receipt, or checkpoint survives in the completed output.

    {1:output Durable output}

    Text begins with the provenance stamp, then the resolved level, source,
    interface availability, optional synopsis, module and sublibrary hints, page
    counts, declaration lines, bounded documentation, and continuation.
    Declaration signatures preserve source text; expanded items carry qualified
    paths, while a focused item is rooted at the requested declaration.

    Compact JSON is the version-1 {!Mentat_tools_output.Ocaml.Docs.t}
    projection: counts of returned values, types, and modules. Exceptions count
    as values, class types count as types, and classes and module types count as
    modules. Source addresses, provenance, signatures, documentation, metadata,
    and continuation remain solely in authoritative text. Text, compact JSON,
    and the output truncation bit are durable; replay never reconstructs an
    authority-bearing OCaml value.

    {1:permissions Errors and cancellation}

    Permission planning is pure over decoded input. A resolvable path query
    requests that source read plus the shared ["command.confinement"] fact,
    because malformed source may invoke Merlin. A name query requests the root
    containing the capability's logical current directory, the configured switch
    [lib/] root when admitted, and the same confinement fact. The fact's subject
    is the stable {!Mentat_permission.Access.Command.execution_to_string}
    projection computed once when {!make} constructs the tool. Fixed argv and
    source bytes are not represented as model-authored shell permissions.

    Missing paths, libraries, and installed source are [`Not_found]. Invalid
    paths, non-regular or binary source, ambiguous names, source-size
    violations, and compiler parse failures without a usable Merlin outline are
    [`Invalid_input]. In particular, any non-cancellation Merlin failure during
    the parser fallback preserves the compiler's [`Invalid_input] diagnostic.

    A Dune or ocamlfind launch failure, or an unconfigured external-source seam,
    is [`Unavailable]; a Dune or ocamlfind timeout is [`Timed_out]. Malformed
    Dune output and Dune non-zero exit, signal, output overflow, incomplete
    capture, or supervision failure are [`Failed]. Ocamlfind non-UTF-8 output or
    a directory outside the configured switch is also [`Failed]. For parity with
    the established lookup contract, ocamlfind non-zero exit, signal, output
    overflow, incomplete capture, and supervision failure mean that the library
    was not located and complete as [`Not_found]. Backend diagnostics are
    repaired to valid UTF-8, stripped of ANSI CSI and OSC sequences, trimmed,
    and bounded before becoming visible.

    Cancellation is checked before observation, after complete path reads,
    during every child, after Dune resolution, and after external resolution.
    Once observed, the call is a cancelled interruption with no completed or
    partial output. Parent-fiber cancellation remains Eio cancellation after
    command cleanup and is not converted into a tool result. *)

val name : string
(** [name] is ["ocaml_docs"]. *)

val default_limit : int
(** [default_limit] is [100]. *)

val max_limit : int
(** [max_limit] is [1000], the largest accepted declaration page. *)

val max_doc_bytes : int
(** [max_doc_bytes] is [500], the maximum retained bytes of one odoc comment.
    Truncation preserves a valid UTF-8 prefix. *)

val default_max_source_bytes : int
(** [default_max_source_bytes] is two MiB. *)

val max_source_bytes : int
(** [max_source_bytes] is eight MiB, the largest accepted complete source read.
*)

val make :
  Mentat_workspace_io.t ->
  clock:_ Eio.Time.Mono.t ->
  merlin_program:string list ->
  dune_program:string list ->
  ocamlfind_program:string list ->
  opam_switch_prefix:string option ->
  ?dune_lock_held:(unit -> bool) ->
  unit ->
  Mentat_tool.t
(** [make workspace_io ~clock ~merlin_program ~dune_program ~ocamlfind_program
     ~opam_switch_prefix ()] is the immutable OCaml-docs tool definition.

    [dune_lock_held] reports whether a build watch — supervised or foreign —
    currently holds Dune's build lock (default: never). While it does, name
    queries — which
    resolve the project universe through [dune describe workspace] — fail
    [`Unavailable] with text naming the lock and the Merlin-backed
    alternatives, never Dune's own lock advice; path queries are unaffected.

    It closes
    the capability, monotonic clock, boot-resolved program prefixes, and
    optional switch prefix for the definition's lifetime, and projects command
    confinement once. Construction starts no process, observes no path, and
    reads no environment variable.

    Each program is an argv prefix, for example [["ocamlmerlin"]], [["dune"]],
    and [["ocamlfind"]]. The composition root owns executable discovery and
    supplies [opam_switch_prefix] only when its [lib/] is admitted as a readable
    root of [workspace_io]. [None] deliberately disables the classic-switch
    source fallback while preserving project-tree dependencies.

    Raises [Invalid_argument] if a program prefix is empty; a program token is
    empty or contains NUL; or [opam_switch_prefix] is empty, contains NUL, or is
    not an absolute normalized path. *)
