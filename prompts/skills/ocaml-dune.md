---
description: Guides authoring dune build logic well - custom rules, actions, dependency specs, aliases, promotion, env stanzas, and build workflow etiquette. Use when writing or editing dune files beyond basic stanzas, adding a custom rule or alias, wiring generated code into the build, tuning flags per profile, or diagnosing a failing or flaky build. Triggers on phrases like "add a dune rule", "generate this file at build time", "attach it to runtest", "custom alias", "dune promote", "why doesn't dune rebuild this", "release profile flags", or "unbound module". For dune-project and opam metadata, load ocaml-project-setup; for writing tests, ocaml-testing; for C stubs, ocaml-ffi.
---

# OCaml Dune Build Logic

This skill covers authoring build logic and running builds: rules,
aliases, promotion, environments, and the etiquette around invoking
dune. Project scaffolding (`dune-project`, opam metadata, formatting
setup) is the `ocaml-project-setup` skill; test suites are
`ocaml-testing`; foreign stubs are `ocaml-ffi`.

## 1. Custom Rules

A rule tells dune how to produce targets from dependencies:

```dune
(rule
 (target schema.ml)
 (deps (:gen gen/gen.exe))
 (action (run %{gen} -o %{target} %{dep:schema.json})))
```

The invariants that make rules reliable:

- **Declare every dependency.** Dune only guarantees that declared
  deps are built and up to date before the action runs, and recent
  dune releases sandbox user actions in a directory containing only
  the declared deps. An undeclared dependency either fails outright
  in the sandbox or, worse, produces a rule that reads stale files
  and caches wrong results. If an action genuinely cannot enumerate
  its inputs, `(deps (universe))` exists, but it disables caching for
  that action — treat it as a last resort.
- **Targets are static and local.** Dune must know target names
  without running the action — `(targets b.%{read:file})` is
  rejected, and there are no `%.x -> %.y` pattern rules. Targets
  live in the rule's own directory (use the `subdir` stanza to place
  a rule elsewhere, or a directory target `(targets (dir out))` for
  a whole tree); writing anywhere else in `_build` is forbidden.
- When deps and targets are obvious from the action, the short form
  `(rule (copy a b))` infers both.

### Actions

`(action ...)` is a small DSL interpreted by dune itself — no shell
involved. The workhorses: `(run prog args...)`, `(progn a b ...)` for
sequencing, `(with-stdout-to file ...)` (also `stderr`/`outputs`),
`(chdir dir ...)`, `(setenv VAR v ...)`, `(diff a b)`, `(copy a b)`,
`(write-file f contents)`. `(bash ...)`/`(system ...)` shell out;
use them only when the DSL cannot express the step, because dune
cannot see through a shell string. For anything more complicated,
write a small OCaml executable and `run` it.

Actions run in the build context directory of their dune file. Wrap
compile-like steps in `(chdir %{workspace_root} ...)` so tools report
paths relative to the root and editors can resolve error locations,
instead of bare basenames from deep inside `_build`.

### Percent forms

- `%{dep:path}` expands to `path` and adds it as a dependency ---
  prefer it over repeating a file in both `deps` and the action.
- `%{bin:prog}` resolves to a locally built binary if the workspace
  installs one, otherwise `PATH` (`(run prog ...)` already resolves
  this way; `%{bin:...}` matters inside `bash`/`system`).
  `%{exe:path}` and `%{libexec:...}` pick the host context under
  cross-compilation — use them for build-time generators.
- `%{lib:pub_name:file}` / `%{lib-private:name:file}` locate library
  files whether installed or local. `%{project_root}` follows the
  `dune-project`; `%{workspace_root}` moves when vendored.
- `%{deps}`, `%{targets}`, `%{target}` expand to the rule's lists
  (aliases in `deps` are excluded). List forms expand to multiple
  arguments; quote (`"%{deps}"`) for one space-joined argument.
- `%{ocaml-config:v}`, `%{profile}`, `%{env:VAR=default}`, and
  `%{read-lines:path}` cover configuration probing without a
  configure script.

A contrast that captures most rule mistakes:

```dune
; Bad: undeclared input, shell glob, writes into the source tree.
; Breaks under sandboxing, never retriggers when inputs change,
; and dune has no target to hash or cache.
(rule
 (alias gen)
 (action (system "./gen.sh *.json > ../src/tables.ml")))

; Good: inputs declared, target owned by the rule, no shell.
(rule
 (targets tables.ml)
 (deps (:gen gen.exe) (:json (glob_files data/*.json)))
 (action (with-stdout-to %{targets} (run %{gen} %{json}))))
```

## 2. Dependency Specs Worth Knowing

Beyond plain filenames:

- `(:name dep...)` binds a group usable as `%{name}` in the action.
  Named groups keep multi-input commands readable and are the only
  way to pass two different globs to two different flags.
- `(glob_files *.txt)` / `(glob_files_rec *.txt)` match source files
  and buildable targets alike, so you can depend on generated files.
- `(source_tree dir)` pulls a whole subtree — but names starting
  with `.` are excluded by default, which silently breaks vendored
  builds needing `.cargo/` or similar; fix with
  `(dirs :standard .cargo)` in that subtree's dune file.
- `(package pkg)` depends on everything the package installs ---
  right for testing a tool as installed. `(env_var VAR)` retriggers
  the rule when the variable changes; without it, reading the
  environment is an invisible input.
- `(alias name)` / `(alias_rec name)` make a rule wait on an alias.
- `(sandbox always|none|preserve_file_kind)` pins the sandboxing an
  action needs. Prefer fixing the action over `(sandbox none)`.

## 3. Aliases

Aliases are named build targets not tied to a file. `dune build @x`
builds alias `x` recursively from the current directory; `@@x` is
this directory only; `@sub/dir/x` scopes to a subtree.

Built-ins to respect rather than reinvent: `@default` (what bare
`dune build` builds; implicitly `(alias_rec all)` unless a directory
defines its own `default` alias), `@all` (every file target in a
directory), `@check` (types everything without linking — the
fastest "does it compile" loop), `@runtest`, `@fmt`, `@doc`.

Attach a rule to an alias with the `alias` field — this is how
checks, generators, and test steps join `dune build @x`:

```dune
(rule
 (alias runtest)
 (action (diff expected.txt actual.txt)))
```

Any new name creates the alias; no declaration needed. The separate
`alias` stanza is for aggregation only (an alias depending on other
aliases or files); putting an action in it is a removed legacy form:

```dune
(alias
 (name ci)
 (deps (alias fmt) (alias runtest)))
```

A rule with an alias but no targets exists only through that alias,
so a typo'd alias name fails silently — misspell it and the rule
simply never runs; re-check the stanza spelling when a check
"does nothing".

## 4. Promotion

`(diff expected actual)` compares a committed file against a built
one: equal means success, different prints the diff and fails, and
`dune promote` then copies the built file over the source one. This
one mechanism powers golden/expect tests, formatting, and generated
code review. `(diff? a b)` tolerates `b` not being produced — for
tools that only emit a `.corrected` file on disagreement; `(cmp a b)`
is for binary files.

`(mode promote)` on a rule skips the failing step: the target is
copied back into the source tree on every build. Use it when the
generated file must be committed — reviewable output, or to spare
release builds the generator dependency (`-p` implies
`--ignore-promoted-rules`: promote rules are dropped and committed
sources used). `(promote (until-clean))`, `(into dir)`, and
`(only <pred>)` narrow the behavior. `(mode fallback)` is the
inverse: the rule runs only when the target is absent from the
source tree — default-config generation.

To generate build logic itself, use the generate-include-commit
pattern: a generator emits `dune.inc`, the dune file has
`(include dune.inc)` plus a `(diff dune.inc dune.inc.gen)` rule on
`@runtest`, and the file is committed (seed with `touch dune.inc`,
build, promote). Included files must exist in the source tree;
`dynamic_include` lifts that, but the generating rule must live in a
different directory (a `(subdir ...)` works) because rules load per
directory and cycles are forbidden.

## 5. Flags, env, and Profiles

Flag fields (`flags`, `ocamlc_flags`, `ocamlopt_flags`,
`link_flags`, ...) use the ordered set language, and this is the
footgun: `(flags -O3)` **replaces** the default flag set, silently
dropping the warning configuration; `(flags (:standard -O3))`
extends it. Always start from `:standard` unless discarding the
defaults is the point. `\` subtracts: `(:standard \ -short-paths)`.
`(:include file)` splices a generated s-expression when flags must
be computed by a script.

The `env` stanza sets per-profile defaults for a directory subtree;
the first clause matching the active profile applies, `_` matches
any:

```dune
(env
 (dev (flags (:standard -w +a-4-42)))
 (release (ocamlopt_flags (:standard -O3)))
 (_ (env-vars (TZ UTC))))
```

Useful `env` fields beyond flags: `(env-vars ...)` (visible to build
actions and `dune exec`), and `(binaries bin/tool.exe)` to make local
executables callable by bare name in actions.

The default profile is `dev`; `--profile release` selects
release-appropriate options (notably non-fatal warnings) and is what
opam uses. Anything else conditioned on the profile can read
`%{profile}` in an `(enabled_if ...)`.

## 6. Modules, Directories, and Wrapping

- A stanza consumes the modules of its own directory only, and
  `(modules ...)` defaults to all of them — including ones
  generated by rules there. Stanzas sharing a directory must
  partition modules explicitly (`(modules (:standard \ main))`).
  `modules_without_implementation` (mli-only) and `private_modules`
  do not add to `(modules ...)`; an explicit list must still
  include them.
- `(include_subdirs unqualified)` merges subdirectories into one
  flat module space — no duplicate module names anywhere in the
  tree, and no `library`/`executable`/`test` stanzas in the
  subdirectories. `qualified` maps directories to submodules
  (`sub/other.ml` becomes `Sub.Other`; `sub/sub.ml` optionally acts
  as `Sub`'s interface). `ocamllex`/`menhir` stanzas still go next
  to their sources either way.
- Wrapped libraries (the default) expose a library named `foo` as
  `Foo.Xxx`; writing your own `foo.ml` makes it the library
  interface, controlling exactly what is exposed. When editing code:
  inside the library, modules refer to each other unprefixed;
  consumers go through `Foo.`. `(wrapped false)` pollutes the
  top-level namespace and exists for porting — fix qualification
  rather than unwrap.
- `name` is the OCaml-level name; `public_name` (which must start
  with the package name) is the findlib name and is what makes the
  library installable at all.
- `copy_files` imports files from another directory into this one's
  build (globs allowed); `subdir` injects stanzas into a
  subdirectory — the way to add rules to generated or vendored
  directories without editing their dune files.

## 7. Build Workflow Etiquette

- `dune build @check` for the fast type-checking loop; plain
  `dune build` for `@default`; `dune runtest dir` (equivalent to
  `dune build @dir/runtest`) to scope tests to what changed.
- One dune owns `_build` at a time. If a watch-mode server
  (`dune build -w`) is running, do not kill it and do not touch its
  lock: a concurrent `dune build` detects the server and forwards the
  request to it over RPC (`dune rpc build .` does the same
  explicitly). When the lock is held by another one-shot build
  instead, a concurrent build aborts with "Another Dune instance is
  currently running" — wait for it to finish; never delete the lock
  or kill the other build.
- Run project and toolchain executables through
  `dune exec -- tool args`: it builds the tool if needed and runs it
  in an install-like environment, exercising current sources rather
  than a stale binary on `PATH`.
- After a `diff` failure, inspect with `dune promotion diff` and
  accept with `dune promote` (it takes paths). Promote deliberately;
  it rewrites the source tree.
- `dune fmt` is `dune build @fmt --auto-promote`; custom formatters
  join it by attaching a `diff` rule to the `fmt` alias.
- Benchmark and profile under `--profile release`; `dev` lacks the
  optimizations you are trying to measure.

## 8. Diagnosing Build Failures

Read the error first — dune points at the stanza or file — then
reach for introspection instead of guessing:

- "Unbound module X" in code that looks right usually means a
  missing entry in `(libraries ...)`, a module not covered by this
  stanza's `(modules ...)` partition, or a filename/module mismatch
  (dune derives module names from filenames: `Foo_bar` lives in
  `foo_bar.ml`).
- A rule that "doesn't run" is usually attached to nothing: no alias
  requests it and nothing depends on its targets — re-read the
  stanza's `(alias ...)` and `(deps ...)` wiring.
- `dune rules [target]` dumps the rule dune actually computed ---
  deps, targets, action — settling most "why did/didn't this
  rebuild" questions.
- `dune printenv dir` shows the effective flags after `env` stanzas
  and profiles apply — check it before concluding a flag is
  ignored.
- `--verbose` prints the commands run and the actual target
  expansion; `-j1 --no-buffer` streams command output live, for
  hanging or interactively failing actions.
- Everything buildable lives under `_build/<context>/`. To demand a
  single artifact: `dune build _build/default/bin/prog.exe`, or the
  variable form `dune build '%{cmxa:src/foo/mylib}'`.
- A dependency cycle mentioning `%{read:...}` means a file is read
  while loading the very directory that generates it — move the
  generated file to another directory (a `(subdir ...)` stanza keeps
  the logic in one dune file).

## Checklist

- [ ] Every rule input declared (`deps`, `%{dep:...}`, `glob_files`,
      `env_var`); nothing read from outside the sandbox
- [ ] Targets statically named, in the rule's own directory; source
      tree written only via promotion
- [ ] Actions use the DSL, not `bash`/`system`; compile-like steps
      `chdir` to `%{workspace_root}` for sane error paths
- [ ] Generated-then-checked files go through `diff` + promotion;
      generated dune logic uses include + `dune.inc`
- [ ] Checks and generators attached to the right alias, spelled
      exactly as the alias is defined
- [ ] Flag customizations extend `(:standard ...)`, never replace
      it; profile-specific settings live in `env`
- [ ] Multi-stanza directories partition `(modules ...)` explicitly;
      `include_subdirs` mode chosen consciously
- [ ] Builds scoped: `@check` for iteration, `dune runtest dir` for
      tests, `--profile release` for performance work
- [ ] Watch-mode server left running; concurrent builds go through
      it, never around it
- [ ] Failures diagnosed with `dune rules` and `dune printenv`
      before editing stanzas speculatively
